#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <inttypes.h>
#include <time.h>
#include <signal.h>

/* ============================================================
 * Global counters for message types
 * ============================================================ */

static uint64_t count_adds = 0;
static uint64_t count_cancels = 0;
static uint64_t count_deletes = 0;
static uint64_t count_executes = 0;
static uint64_t count_replaces = 0;

/* ============================================================
 * Signal handler for SIGINT (Ctrl+C)
 * ============================================================ */

void sigint_handler(int sig) {
    printf("Operations: adds=%" PRIu64 " cancels=%" PRIu64 " deletes=%" PRIu64 " executes=%" PRIu64 " replaces=%" PRIu64 "\n",
           count_adds, count_cancels, count_deletes, count_executes, count_replaces);
    exit(0);
}

/* ============================================================
 * Configuration
 * ============================================================ */
#define LISTEN_PORT     12345
#define MAX_UDP_SIZE    2048
#define WARMUP_PACKETS  0
#define AVG_INTERVAL    50
#define ITCH_PKT_HEADER 20

/* ============================================================
 * ITCH validation table
 * ============================================================ */

struct itch_msg_def {
    char type;
    int  length;
};

static const struct itch_msg_def itch_table[] = {
    { 'F', 40 },
    { 'A', 36 },
    { 'E', 31 },
    { 'X', 23 },
    { 'D', 19 },
    { 'C', 36 },
    { 'U', 35 },
};

static int get_itch_msg_length(uint8_t type)
{
    for (size_t i = 0; i < sizeof(itch_table)/sizeof(itch_table[0]); i++) {
        if (itch_table[i].type == (char)type)
            return itch_table[i].length;
    }
    return -1;
}

/* ============================================================
 * Avalon FIFO (LW bridge)
 * ============================================================ */

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x1000
#define FIFO_DATA_OFFSET 0x00
#define FIFO_CSR_OFFSET  0x20

#define WRITE_FIFO_FILL_LEVEL (*FIFO_write_status_ptr)
#define WRITE_FIFO_FULL       ((*(FIFO_write_status_ptr+1))& 1 ) 
#define WRITE_FIFO_EMPTY      ((*(FIFO_write_status_ptr+1))& 2 ) 

volatile unsigned int * FIFO_write_status_ptr = NULL ;

#define FIFO_DATA_REG   0
#define FIFO_META_REG   1
#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)

static void fifo_write_update64(volatile uint32_t *fifo, uint64_t update)
{
    fifo[FIFO_META_REG] = META_SOP;
    fifo[FIFO_DATA_REG] = (uint32_t)(update & 0xFFFFFFFF);
    fifo[FIFO_META_REG] = META_EOP;
    fifo[FIFO_DATA_REG] = (uint32_t)(update >> 32);
}

/* ============================================================
 * OB HPS interface (from ordermap.c)
 * ============================================================ */

typedef uint64_t ob_update;
typedef struct {
    ob_update del_upd;
    ob_update add_upd;
} ob_replace_updates;

extern ob_update order_add(uint64_t id,
                           uint32_t price,
                           uint32_t qty,
                           uint8_t  side);

extern ob_update order_cancel_execute(uint64_t id,
                                      uint32_t qty);
extern ob_update order_delete(uint64_t id);

extern ob_replace_updates order_replace(uint64_t old_id,
                                        uint64_t new_id,
                                        uint32_t new_price,
                                        uint32_t new_qty);

/* ============================================================
 * UDP helpers
 * ============================================================ */

static int udp_open_and_bind(int port)
{
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return -1;
    }

    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return -1;
    }

    printf("UDP socket bound to port %d\n", port);
    return sock;
}

/* ============================================================
 * FIFO mapping
 * ============================================================ */

static volatile uint32_t *fifo_map(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open(/dev/mem)");
        return NULL;
    }

    void *base = mmap(NULL, LW_BRIDGE_SPAN,
                      PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, LW_BRIDGE_BASE);
    close(fd);

    if (base == MAP_FAILED) {
        perror("mmap");
        return NULL;
    }

    //printf("FIFO mapped at %p\n", base);
    return (volatile uint32_t *)base;
}

/* ============================================================
 * Time helpers
 * ============================================================ */

static inline uint64_t timespec_to_ns(const struct timespec *ts)
{
    return (uint64_t)ts->tv_sec * 1000000000ULL + (uint64_t)ts->tv_nsec;
}

/* ============================================================
 * Main
 * ============================================================ */

int main(void)
{
    uint8_t buf[MAX_UDP_SIZE];

    uint32_t expected_seq = 0;
    uint64_t dropped_pkts = 0;
    bool seq_initialized = false;

    int sock = udp_open_and_bind(LISTEN_PORT);
    if (sock < 0)
        return 1;

    struct timeval tv;
    tv.tv_sec  = 1;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    volatile uint32_t *fifo = fifo_map();
    if (!fifo) {
        close(sock);
        return 1;
    }

    FIFO_write_status_ptr = (unsigned int *)((char*)fifo + 0x20);

    // Set up signal handler for SIGINT
    signal(SIGINT, sigint_handler);

    printf("NetIO: listening for ITCH UDP on port %d\n", LISTEN_PORT);

    int warmup = 0;

    uint64_t tot_latency_rx = 0;
    uint64_t tot_latency_parse = 0;
    uint64_t tot_latency_ordermap = 0;
    uint64_t tot_latency_fifo = 0;

    uint64_t total_received = 0;
    uint64_t total_measured = 0;

    while (1) {
        struct timespec t_rx_start, t_rx_end;
        struct timespec t_after_parse, t_after_ordermap, t_after_fifo;

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_rx_start);

        ssize_t n = recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);
        //printf("recvfrom returned %zd bytes\n", n);

        if (n < 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
               // printf("[STALL] recv timeout\n");
            } else {
               // perror("recvfrom");
            }
            continue;
        }

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_rx_end);
        total_received++;
        //printf("Packet %llu received, size=%zd\n", total_received, n);

        if (n <= ITCH_PKT_HEADER) {
            printf("Packet too small, ignoring\n");
            continue;
        }

        char session[11];
        memcpy(session, buf, 10);
        session[10] = 0;

        uint64_t pkt_seq;
        memcpy(&pkt_seq, buf + 10, 8);
        pkt_seq = be64toh(pkt_seq);

        uint16_t msg_count;
        memcpy(&msg_count, buf + 18, 2);
        msg_count = ntohs(msg_count);

        //printf("Session='%s', pkt_seq=%" PRIu64 ", msg_count=%u\n",
        //       session, pkt_seq, msg_count);

        uint8_t *cursor = buf + ITCH_PKT_HEADER;
        int remaining = n - ITCH_PKT_HEADER;

        for (int m = 0; m < msg_count && remaining > 0; m++) {
            if (remaining < 3) {
                printf("Remaining <3 bytes, breaking\n");
                break;
            }

            uint16_t msg_len;
            memcpy(&msg_len, cursor, 2);
            msg_len = ntohs(msg_len);

            int total_len = msg_len + 2;

            if (remaining < total_len) {
                printf("Incomplete message: remaining=%d, total_len=%d\n", remaining, total_len);
                break;
            }

            uint8_t type = cursor[2];
            //printf("Message %d: type='%c', msg_len=%u\n", m, type, msg_len);

            int expected_len = get_itch_msg_length(type);
            if (expected_len < 0 || msg_len != expected_len) {
                printf("Skipping unknown or mismatched message type\n");
                cursor += total_len;
                remaining -= total_len;
                continue;
            }

            uint8_t *msg = cursor + 2;

            if (warmup < WARMUP_PACKETS) {
                warmup++;
                cursor += total_len;
                remaining -= total_len;
                continue;
            }

            uint64_t order_id;
            uint64_t old_id;
            uint64_t new_id;
            uint32_t price;
            uint32_t quantity;
            uint8_t side;
            ob_update upd;

            ob_replace_updates rep;
            bool is_replace = false;

            switch (type) {
                case 'A': // Add Order – No MPID Attribution
                case 'F': { // Add Order with MPID Attribution
                    count_adds++;
                    memcpy(&order_id, &msg[11], 8);
                    memcpy(&quantity, &msg[20], 4);
                    memcpy(&price, &msg[32], 4);
                    side = msg[19];

                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    upd = order_add(order_id, price, quantity, side);

                    //printf("order_add: id=0x%016" PRIx64 ", price=0x%" PRIx32
                    //       ", qty=0x%" PRIx32 ", side=%c\n",
                    //       order_id, price, quantity, side);
                    break;
                    }
                case 'C': // Order Executed with Price
                    count_executes++;
                    memcpy(&order_id, &msg[11], 8);
                    memcpy(&quantity, &msg[19], 4);

                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    upd = order_cancel_execute(order_id, quantity);
                    //printf("order_execute_w_price: id=0x%016" PRIx64 ", qty=0x%" PRIx32 "\n",
                    //       order_id, quantity);
                    break;
                case 'E': // Order Executed
                    count_executes++;
                    memcpy(&order_id, &msg[11], 8);
                    memcpy(&quantity, &msg[19], 4);

                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    upd = order_cancel_execute(order_id, quantity);
                    //printf("order_execute: id=0x%016" PRIx64 ", qty=0x%" PRIx32 "\n",
                    //       order_id, quantity);
                    break;

                case 'X': // Order Cancel
                    count_cancels++;
                    memcpy(&order_id, &msg[11], 8);
                    memcpy(&quantity, &msg[19], 4);
                    
                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    upd = order_cancel_execute(order_id, quantity);
                    //printf("order_cancel: id=0x%016" PRIx64 ", qty=0x%" PRIx32 "\n",
                    //      order_id, quantity);
                    break;

                case 'D': // Order Delete
                    count_deletes++;
                    memcpy(&order_id, &msg[11], 8);

                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    upd = order_delete(order_id);
                    //printf("order_delete: id=0x%016" PRIx64 "\n",
                    //      order_id);
                    break;

                case 'U': // Order Replace
                    count_replaces++;
                    is_replace = true;

                    memcpy(&old_id, &msg[11], 8);
                    memcpy(&new_id, &msg[19], 8);
                    memcpy(&quantity, &msg[27], 4);
                    memcpy(&price, &msg[31], 4);

                    clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);

                    rep = order_replace(old_id, new_id, price, quantity);
                    //printf("order_replace: old_id=0x%016" PRIx64 ", new_id=0x%016" PRIx64
                    //    ", new_qty=0x%" PRIx32 ", new_price=0x%" PRIx32 "\n",
                    //    old_id, new_id, quantity, price);
                    break;

                default:
                    printf("Unknown message type '%c'\n", type);
                    cursor += total_len;
                    remaining -= total_len;
                    continue;
            }

            clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_ordermap);

            //printf("ordermap output=0x%016" PRIx64 "\n", upd);

            while (WRITE_FIFO_FILL_LEVEL >= (8192 - 64)) {
                printf("FIFO full, waiting...\n");
            }
            if (is_replace) 
            {
                fifo_write_update64(fifo, rep.del_upd);
                fifo_write_update64(fifo, rep.add_upd);
                //printf("ordermap output del=0x%016" PRIx64 "\n", rep.del_upd);
                //printf("ordermap output add=0x%016" PRIx64 "\n", rep.add_upd);
            }
            else 
            {
                fifo_write_update64(fifo, upd);
                //printf("ordermap output=0x%016" PRIx64 "\n", upd);
            }

            volatile uint32_t dummy = FIFO_write_status_ptr[0];
            (void)dummy;

            clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_fifo);

            total_measured++;

            tot_latency_rx       += timespec_to_ns(&t_rx_end) - timespec_to_ns(&t_rx_start);
            tot_latency_parse    += timespec_to_ns(&t_after_parse) - timespec_to_ns(&t_rx_end);
            tot_latency_ordermap += timespec_to_ns(&t_after_ordermap) - timespec_to_ns(&t_after_parse);
            tot_latency_fifo     += timespec_to_ns(&t_after_fifo) - timespec_to_ns(&t_after_ordermap);

            /*
            if (total_measured % AVG_INTERVAL == 0) {
                printf("Latency avg over %d pkts: rx=%" PRIu64
                       " ns, parse=%" PRIu64
                       " ns, ordermap=%" PRIu64
                       " ns, fifo=%" PRIu64 " ns\n",
                       AVG_INTERVAL,
                       tot_latency_rx / AVG_INTERVAL,
                       tot_latency_parse / AVG_INTERVAL,
                       tot_latency_ordermap / AVG_INTERVAL,
                       tot_latency_fifo / AVG_INTERVAL);

                tot_latency_rx = 0;
                tot_latency_parse = 0;
                tot_latency_ordermap = 0;
                tot_latency_fifo = 0;
            }
                */

            cursor += total_len;
            remaining -= total_len;
        }
    }

    return 0;
}