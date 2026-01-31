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

/* ============================================================
 * Configuration
 * ============================================================ */
#define LISTEN_PORT     12345
#define MAX_UDP_SIZE    512
#define WARMUP_PACKETS  10   // Ignore first 10 packets for cold-start
#define AVG_INTERVAL    50   // Running average every 50 packets

/* ============================================================
 * ITCH validation table
 * ============================================================ */

struct itch_msg_def {
    char type;
    int  length;
};

static const struct itch_msg_def itch_table[] = {
    { 'A', 36 },
    { 'E', 31 },
    { 'X', 23 },
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

extern ob_update order_add(uint64_t id,
                           uint32_t price,
                           uint32_t qty,
                           uint8_t  side);

extern ob_update order_cancel_execute(uint64_t id,
                                      uint32_t qty);

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

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return -1;
    }

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

    return (volatile uint32_t *)base;
}

/* ============================================================
 * Time helpers
 * ============================================================ */

static inline uint64_t timespec_to_us(const struct timespec *ts)
{
    return ts->tv_sec * 1000000ULL + ts->tv_nsec / 1000;
}

/* ============================================================
 * Main
 * ============================================================ */

int main(void)
{
    uint8_t buf[MAX_UDP_SIZE];

    int sock = udp_open_and_bind(LISTEN_PORT);
    if (sock < 0)
        return 1;

    volatile uint32_t *fifo = fifo_map();
    if (!fifo) {
        close(sock);
        return 1;
    }

    printf("NetIO: listening for ITCH UDP on port %d\n", LISTEN_PORT);

    int warmup = 0;
    uint64_t total_us = 0;
    int pkt_count = 0;

    while (1) {
        struct timespec t_start, t_end;
        ssize_t n = recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_start);

        if (n <= 0)
            continue;

        uint8_t type = buf[0];
        int expected_len = get_itch_msg_length(type);

        if (expected_len < 0 || n != expected_len)
            continue;

        uint64_t order_id;
        uint32_t price;
        uint32_t quantity;
        uint8_t side;

        ob_update upd;


        switch (type) {

        case 'A':
            memcpy(&order_id, &buf[11], 8);
            memcpy(&quantity, &buf[20], 4);
            memcpy(&price, &buf[32], 4);
            side = buf[19];

            upd = order_add(order_id, price, quantity, side);

           // printf("ITCH A: id=%" PRIu64 " upd=0x%016" PRIx64 "\n",
               //    order_id, upd);
            break;

        case 'E':
            memcpy(&order_id, &buf[11], 8);
            memcpy(&quantity, &buf[19], 4);

            upd = order_cancel_execute(order_id, quantity);

            //printf("ITCH E: id=%" PRIu64 " upd=0x%016" PRIx64 "\n",
             //    order_id, upd);
            break;

        case 'X':
            memcpy(&order_id, &buf[11], 8);
            memcpy(&quantity, &buf[19], 4);

            upd = order_cancel_execute(order_id, quantity);

            //printf("ITCH X: id=%" PRIu64 " upd=0x%016" PRIx64 "\n",
             //     order_id, upd);
            break;

        default:
            continue;
        }

        fifo_write_update64(fifo, upd);
        clock_gettime(CLOCK_MONOTONIC_RAW, &t_end);

        uint64_t latency_us = timespec_to_us(&t_end) - timespec_to_us(&t_start);

        if (warmup < WARMUP_PACKETS) {
            warmup++;
            continue; // skip first few packets
        }

        total_us += latency_us;
        pkt_count++;
        printf("Packet %d latency: %" PRIu64 " us\n", pkt_count, latency_us);

        if (pkt_count % AVG_INTERVAL == 0) {
            printf("Average latency over %d packets: %" PRIu64 " us\n",
                   AVG_INTERVAL, total_us / AVG_INTERVAL);
            total_us = 0;
        }
    }

    return 0;
}
