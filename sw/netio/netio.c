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
 * FIFO debug / verification
 * ============================================================ */

/*
 * When enabled:
 *   - injects a monotonically increasing sequence number
 *     into the upper bits of the 64-bit upd
 *   - used ONLY for FIFO integrity testing
 *
 * Disable once FIFO correctness is proven.
 */
#define FIFO_DEBUG_ENABLE  1

#if FIFO_DEBUG_ENABLE
#define FIFO_DEBUG_SEQ_BITS 16
#define FIFO_DEBUG_SEQ_SHIFT (64 - FIFO_DEBUG_SEQ_BITS)
#endif


/* ============================================================
 * Configuration
 * ============================================================ */
#define LISTEN_PORT     12345
#define MAX_UDP_SIZE    512
#define WARMUP_PACKETS  200
#define AVG_INTERVAL    50

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
// FIFO Data is at offset 0x00 relative to LW_BRIDGE_BASE
// FIFO CSR is at offset 0x20 relative to LW_BRIDGE_BASE
#define FIFO_DATA_OFFSET 0x00
#define FIFO_CSR_OFFSET  0x20

// FIFO status registers
// base address is current fifo fill-level
// base+1 address is status: 
// --bit0 signals "full"
// --bit1 signals "empty"
#define WRITE_FIFO_FILL_LEVEL (*FIFO_write_status_ptr)
#define WRITE_FIFO_FULL		  ((*(FIFO_write_status_ptr+1))& 1 ) 
#define WRITE_FIFO_EMPTY	  ((*(FIFO_write_status_ptr+1))& 2 ) 

// HPS_to_FPGA FIFO status address = 0
volatile unsigned int * FIFO_write_status_ptr = NULL ;

#define FIFO_DATA_REG   0
#define FIFO_META_REG   1

#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)

/* ============================================================
 * Debug FIFO wrapper
 * ============================================================ */

/* #if FIFO_DEBUG_ENABLE
static uint16_t fifo_dbg_seq = 0;
#endif

static inline void fifo_write_debug_update64(volatile uint32_t *fifo,
                                             uint64_t upd)
{
#if FIFO_DEBUG_ENABLE
    uint64_t dbg_upd = upd;

    // Inject sequence into upper bits 
    dbg_upd &= ~(((uint64_t)((1ULL << FIFO_DEBUG_SEQ_BITS) - 1))
                 << FIFO_DEBUG_SEQ_SHIFT);

    dbg_upd |= ((uint64_t)fifo_dbg_seq << FIFO_DEBUG_SEQ_SHIFT);
    fifo_dbg_seq++;
    
    fifo_write_update64(fifo, dbg_upd);
#else
    fifo_write_update64(fifo, upd);
#endif
} */

#if FIFO_DEBUG_ENABLE
static uint16_t fifo_dbg_seq = 0;
#endif

static void fifo_write_update64(volatile uint32_t *fifo, uint64_t update);


static inline void fifo_write_debug_update64(volatile uint32_t *fifo,
                                             uint64_t upd)
{
#if FIFO_DEBUG_ENABLE
    /* ZERO everything */
    uint64_t dbg_upd = 0;

    /* Inject sequence into upper bits */
    dbg_upd |= ((uint64_t)fifo_dbg_seq << FIFO_DEBUG_SEQ_SHIFT);
    fifo_dbg_seq++;

    fifo_write_update64(fifo, dbg_upd);
    //usleep(10);
#else
    fifo_write_update64(fifo, upd);
#endif
}



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

    /* ------------------------------
     * Increase UDP receive buffer
     * ------------------------------ */
    int rcvbuf = 4 * 1024 * 1024;   // NEW
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF,
               &rcvbuf, sizeof(rcvbuf));   // NEW

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

    printf("NetIO: listening for ITCH UDP on port %d\n", LISTEN_PORT);

    FIFO_write_status_ptr = (unsigned int *)((char*)fifo + 0x20);

    //volatile uint32_t *fifo_data = (volatile uint32_t *)((char *)fifo + FIFO_DATA_OFFSET);
    //volatile uint32_t *fifo_csr  = (volatile uint32_t *)((char *)fifo + FIFO_CSR_OFFSET);

    int warmup = 0;

    uint64_t tot_latency_rx = 0;
    uint64_t tot_latency_parse = 0;
    uint64_t tot_latency_ordermap = 0;
    uint64_t tot_latency_fifo = 0;

    uint64_t total_received = 0;
    uint64_t total_measured = 0;

    /*
    printf("Bridge base: %p\n", (void*)LW_BRIDGE_BASE);
    printf("CSR pointer: %p\n", (void*)FIFO_write_status_ptr);
    printf("Expected CSR address: 0x%lx\n", (unsigned long)((char*)LW_BRIDGE_BASE + 0x20));

    // Sanity test: Write 1 packet, check if fill_level increments
    printf("Fill level before write: %u\n", WRITE_FIFO_FILL_LEVEL);

    fifo_write_debug_update64(fifo, 0xDEADBEEF);

    printf("Fill level after 1 write: %u\n", WRITE_FIFO_FILL_LEVEL);
    */
    while (1) {
        struct timespec t_rx_start, t_rx_end;
        struct timespec t_after_parse, t_after_ordermap, t_after_fifo;

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_rx_start);

        ssize_t n = recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);

        if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) {
            if (total_received > 0) {
                printf("[STALL] recv timeout\n");
                printf("Final counts: received=%" PRIu64
                       " measured=%" PRIu64
                       " dropped=%" PRIu64 "\n",
                       total_received, total_measured, dropped_pkts);
            }
            continue;
        }

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_rx_end);
        total_received++;

        if (n <= 0)
            continue;

        uint8_t type = buf[0];
        int expected_len = get_itch_msg_length(type);
        if (expected_len < 0 || n != expected_len)
            continue;

        if (warmup < WARMUP_PACKETS) {
            warmup++;
            continue;
        }

        /* ------------------------------
         * Sequence check (A1)
         * ------------------------------ */
        uint32_t seq;
        memcpy(&seq, &buf[1], 4);
        seq = ntohl(seq);

        if (!seq_initialized) {
            expected_seq = seq + 1;
            seq_initialized = true;
        } else if (seq != expected_seq) {
            if (seq > expected_seq) {
                dropped_pkts += (seq - expected_seq);
                printf("[DROP] expected=%u got=%u (lost %u)\n",
                       expected_seq, seq, seq - expected_seq);
            } else {
                printf("[REORDER] expected=%u got=%u\n",
                       expected_seq, seq);
            }
            expected_seq = seq + 1;
        } else {
            expected_seq++;
        }

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

            clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);
            upd = order_add(order_id, price, quantity, side);
            break;

        case 'E':
        case 'X':
            memcpy(&order_id, &buf[11], 8);
            memcpy(&quantity, &buf[19], 4);

            clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_parse);
            upd = order_cancel_execute(order_id, quantity);
            break;

        default:
            continue;
        }

        clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_ordermap);
        //fifo_write_update64(fifo, upd);



        // Register Map for "in_csr":
        // Offset 0: fill_level (How many words are currently in the FIFO)
        // Offset 1: status (Bit 0 = Full, Bit 1 = Empty, etc.)
        //uint32_t fill_level = fifo_csr[0]; 

        // If FIFO is nearly full (e.g., depth 8192), wait.
        // We leave a safety margin (e.g., 50 words) to account for skid.
        while (WRITE_FIFO_FILL_LEVEL >= (8192 - 64)) {
            //printf("fill level=%d\n", WRITE_FIFO_FILL_LEVEL);
        }
        //printf("fill level=%d\n", WRITE_FIFO_FILL_LEVEL);

        fifo_write_debug_update64(fifo, upd);

        // 2. READ BARRIER (Crucial Step)
        // Force the bridge to flush writes by reading the Status Register.
        // We don't even need to check the value, just the ACT of reading acts as a fence.
        volatile uint32_t dummy = FIFO_write_status_ptr[0];
        (void)dummy; // Prevent unused variable warning
        clock_gettime(CLOCK_MONOTONIC_RAW, &t_after_fifo);

        total_measured++;

        tot_latency_rx       += timespec_to_ns(&t_rx_end) - timespec_to_ns(&t_rx_start);
        tot_latency_parse    += timespec_to_ns(&t_after_parse) - timespec_to_ns(&t_rx_end);
        tot_latency_ordermap += timespec_to_ns(&t_after_ordermap) - timespec_to_ns(&t_after_parse);
        tot_latency_fifo     += timespec_to_ns(&t_after_fifo) - timespec_to_ns(&t_after_ordermap);

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
    }

    return 0;
}
