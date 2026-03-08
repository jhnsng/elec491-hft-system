#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>

/* ============================================================
 * Configuration
 * ============================================================ */

#define ENABLE_TCP     1   /* <-- toggle this */

#define EXCH_IP        "192.168.1.10"
#define EXCH_PORT      9000

#define LW_BRIDGE_BASE 0xFF200000
#define LW_BRIDGE_SPAN 0x1000

#define FIFO_DATA_OFFSET 0x08

#define MAX_OUCH_MSG   256

/* ============================================================
 * FIFO registers (Avalon-ST to MM)
 * ============================================================ */

#define FIFO_DATA_REG  0
#define FIFO_META_REG  1

/* FIFO read-status CSR (LW bridge) */
#define READ_FIFO_FILL_LEVEL  (*fifo_read_status)
#define READ_FIFO_FULL        ((*(fifo_read_status + 1)) & 1)
#define READ_FIFO_EMPTY       ((*(fifo_read_status + 1)) & 2)

/* META fields */
#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)

#define META_EMPTY_MASK  (0x3 << 2)
#define META_EMPTY_SHIFT 2

volatile unsigned int *fifo = NULL;
volatile unsigned int *fifo_read_status = NULL;

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

#if ENABLE_TCP
/* ============================================================
 * TCP helpers
 * ============================================================ */

static int tcp_connect(const char *ip, int port)
{
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return -1;
    }

    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);

    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        perror("inet_pton");
        close(sock);
        return -1;
    }

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(sock);
        return -1;
    }

    return sock;
}
#endif

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
    struct timespec t_start, t_end;
    volatile uint32_t *lw_base = fifo_map();
    if (!lw_base)
        return 1;

    // OLD BROKEN CODE:
    // fifo = (unsigned int *)(lw_base + 0x08); 
    // fifo_read_status = (unsigned int *)(lw_base + 0x40);

    // NEW FIXED CODE:
    // Cast to char* or void* to perform byte-level arithmetic
   // void *base_ptr = (void *)lw_base;
    
    // --- FIX STARTS HERE ---
    // Cast to (char *) so that + 0x08 means + 8 bytes, not 8 words
    volatile char *base_ptr = (volatile char *)lw_base;

    fifo = (volatile unsigned int *)(base_ptr + FIFO_DATA_OFFSET); // 0x08 bytes
    fifo_read_status = (volatile unsigned int *)(base_ptr + 0x40); // 0x40 bytes
    // --- FIX ENDS HERE ---

   //fifo = (unsigned int *)(lw_base + 0x08);   // FIFO data/meta
    //fifo_read_status = (unsigned int *)(lw_base + 0x40); // read CSR

#if ENABLE_TCP
    int sock = tcp_connect(EXCH_IP, EXCH_PORT);
    if (sock < 0)
        return 1;

    printf("TCP enabled: connected to %s:%d\n", EXCH_IP, EXCH_PORT);
#else
    printf("TCP disabled: FIFO-only test mode\n");
#endif

    uint8_t msg_buf[MAX_OUCH_MSG];
    size_t  msg_len = 0;

    // Flush stale data
    while (!READ_FIFO_EMPTY) {
        volatile uint32_t junk_data = fifo[FIFO_DATA_REG];
        volatile uint32_t junk_meta = fifo[FIFO_META_REG];
        (void)junk_data; (void)junk_meta;
    }
    printf("FIFO Flushed. Waiting for data...\n");

    while (1) {

        /* ----------------------------------------------
         * Non-blocking FIFO read (Cornell-style guard)
         * ---------------------------------------------- */
        if (READ_FIFO_EMPTY) {
          //  printf("read fifo empty when blocked=%d\n", READ_FIFO_EMPTY);
            continue;
        }

        //if (msg_len == 0) {
        //     clock_gettime(CLOCK_MONOTONIC, &t_start);
        //}

        // Pop data first
        uint32_t data = fifo[FIFO_DATA_REG];   // offset 0

        // Then read the sideband for that popped word
        uint32_t meta = fifo[FIFO_META_REG];   // offset 1 (SOP/EOP/EMPTY...) [file:51]

        printf("[RAW] Meta: %08X | Data: %08X | SOP:%d | EOP:%d\n",
              meta, data, !!(meta & META_SOP), !!(meta & META_EOP));

        uint32_t level   = fifo_read_status[0];  // fill_level [page:0]
        uint32_t i_stat  = fifo_read_status[1];  // i_status (EMPTY bit=1) [page:0]
        printf("level=%u i_status=0x%08X empty=%u\n", level, i_stat, (i_stat>>1)&1);


        if (meta & META_SOP) {
            msg_len = 0;
        }

        memcpy(&msg_buf[msg_len], &data, 4);
        msg_len += 4;

        if (meta & META_EOP) {

            uint32_t empty =
                (meta & META_EMPTY_MASK) >> META_EMPTY_SHIFT;

            if (empty)
                msg_len -= empty;

            if (msg_len == 0 || msg_len > MAX_OUCH_MSG) {
                fprintf(stderr,
                        "[ERROR] Invalid packet length: %zu\n",
                        msg_len);
                msg_len = 0;
                continue;
            }

#if ENABLE_TCP
            ssize_t sent = send(sock, msg_buf, msg_len, 0);
            if (sent < 0) {
                perror("send");
                break;
            }

            if ((size_t)sent != msg_len) {
                fprintf(stderr,
                        "[WARN] Partial TCP send (%zd/%zu)\n",
                        sent, msg_len);
            }
#else
            /* FIFO-only visibility */
            printf("RX packet (%zu bytes): ", msg_len);
            for (size_t i = 0; i < msg_len; i++)
                printf("%02X ", msg_buf[i]);
            printf("\n");
#endif
            msg_len = 0;
        }
    }

#if ENABLE_TCP
    close(sock);
#endif
    return 0;
}
