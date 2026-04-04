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
#include <sys/socket.h>
#include <sys/mman.h>

/* ============================================================
 * Configuration
 * ============================================================ */

#define EXCH_IP        "192.168.1.10"
#define EXCH_PORT      9000

#define ENABLE_FIFO 1

#define LW_BRIDGE_BASE 0xFF200000
#define LW_BRIDGE_SPAN 0x1000

/* WRITE (HPS -> FPGA) */
#define FIFO_WRITE_DATA_OFFSET 0x10
#define FIFO_WRITE_CSR_OFFSET  0x60

/* READ (FPGA -> HPS) */
#define FIFO_READ_DATA_OFFSET  0x08
#define FIFO_READ_CSR_OFFSET   0x40

#define MAX_OUCH_MSG 256
#define RECV_BUF     4096

/* ============================================================
 * FIFO defs
 * ============================================================ */

#define FIFO_DATA_REG 0
#define FIFO_META_REG 1

#define META_SOP (1 << 0)
#define META_EOP (1 << 1)
#define META_EMPTY_MASK  (0x3 << 2)
#define META_EMPTY_SHIFT 2

volatile unsigned int *fifo_write = NULL;
volatile unsigned int *fifo_write_status = NULL;

volatile unsigned int *fifo_read = NULL;
volatile unsigned int *fifo_read_status = NULL;

#define WRITE_FIFO_FILL_LEVEL (*fifo_write_status)
#define READ_FIFO_EMPTY       ((*(fifo_read_status+1)) & 2)

/* ============================================================
 * OUCH definitions
 * ============================================================ */

struct ouch_msg_def {
    char type;
    int length;
};

static const struct ouch_msg_def ouch_table[] = {
    { 'A', 62 },
    { 'C', 18 },
    { 'E', 34 },
};

static int get_ouch_msg_len(uint8_t type)
{
    for (size_t i = 0; i < sizeof(ouch_table)/sizeof(ouch_table[0]); i++)
        if (ouch_table[i].type == type)
            return ouch_table[i].length;
    return -1;
}

static void print_bytes(const uint8_t *buf, int len)
{
    for (int i = 0; i < len; i++)
        printf("%02X ", buf[i]);
    printf("\n");
}

/* ============================================================
 * FIFO WRITE (to FPGA)
 * ============================================================ */

static void fifo_write_msg(uint8_t *msg, int len)
{
#if ENABLE_FIFO
    int words = (len + 3) / 4;
    int empty = words*4 - len;

    for (int i = 0; i < words; i++)
    {
        uint32_t data = 0;
        memcpy(&data, &msg[i*4], (len - i*4 >= 4) ? 4 : (len - i*4));

        uint32_t meta = 0;
        if (i == 0) meta |= META_SOP;

        if (i == words-1) {
            meta |= META_EOP;
            meta |= (empty << META_EMPTY_SHIFT);
        }

        while (WRITE_FIFO_FILL_LEVEL >= (8192 - 64));

        fifo_write[FIFO_META_REG] = meta;
        fifo_write[FIFO_DATA_REG] = data;
    }
#endif
}

/* ============================================================
 * FIFO MAP
 * ============================================================ */

static volatile uint32_t *fifo_map(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return NULL; }

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
 * TCP CONNECT
 * ============================================================ */

static int tcp_connect(const char *ip, int port)
{
    int sock = socket(AF_INET, SOCK_STREAM, 0);

    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return -1;
    }

    printf("Connected to exchange %s:%d\n", ip, port);
    return sock;
}

/* ============================================================
 * MAIN
 * ============================================================ */

int main()
{
    uint8_t recv_buf[RECV_BUF];
    uint8_t frame_buf[4096];
    int frame_len = 0;

    uint8_t msg_buf[MAX_OUCH_MSG];
    size_t msg_len = 0;
    bool first_sop_seen = false;

    /* Map FIFO */
    volatile uint32_t *lw_base = fifo_map();
    if (!lw_base) return 1;

    volatile char *base_ptr = (volatile char *)lw_base;

    fifo_write = (volatile unsigned int*)(base_ptr + FIFO_WRITE_DATA_OFFSET);
    fifo_write_status = (volatile unsigned int*)(base_ptr + FIFO_WRITE_CSR_OFFSET);

    fifo_read = (volatile unsigned int*)(base_ptr + FIFO_READ_DATA_OFFSET);
    fifo_read_status = (volatile unsigned int*)(base_ptr + FIFO_READ_CSR_OFFSET);

    int sock = tcp_connect(EXCH_IP, EXCH_PORT);
    if (sock < 0) return 1;

    // Flush stale data
	while (!READ_FIFO_EMPTY) {
		volatile uint32_t junk_data = fifo_read[FIFO_DATA_REG];
		volatile uint32_t junk_meta = fifo_read[FIFO_META_REG];
		(void)junk_data; (void)junk_meta;
	}
	printf("F2H FIFO Flushed. Waiting for data...\n");

    while (1)
    {
        /* ================================
         * 1. TCP RX → FPGA
         * ================================ */

        int n = recv(sock, recv_buf, sizeof(recv_buf), MSG_DONTWAIT);

        if (n > 0)
        {
            memcpy(frame_buf + frame_len, recv_buf, n);
            frame_len += n;

            int pos = 0;

            while (1)
            {
                if (frame_len - pos < 2) break;

                uint16_t msg_len_tcp =
                    ((uint16_t)frame_buf[pos] << 8) |
                    (uint16_t)frame_buf[pos+1];

                if (frame_len - pos < 2 + msg_len_tcp)
                    break;

                uint8_t *msg = &frame_buf[pos + 2];

                fifo_write_msg(msg, msg_len_tcp);

                printf("EXCHANGE -> FPGA MSG:");
                print_bytes(msg, msg_len_tcp);

                pos += 2 + msg_len_tcp;
            }

            if (pos > 0) {
                memmove(frame_buf, frame_buf + pos, frame_len - pos);
                frame_len -= pos;
            }
        }

        /* ================================
         * 2. FPGA → TCP TX
         * ================================ */

        if (!READ_FIFO_EMPTY)
        {
            uint32_t data = fifo_read[FIFO_DATA_REG];
            uint32_t meta = fifo_read[FIFO_META_REG];

            if (!first_sop_seen) {
                if (meta & META_SOP) {
                    first_sop_seen = true;
                    msg_len = 0;
                } else {
                    continue;
                }
            }

            memcpy(&msg_buf[msg_len], &data, 4);
            msg_len += 4;

            if (meta & META_EOP)
            {
                uint32_t empty =
                    (meta & META_EMPTY_MASK) >> META_EMPTY_SHIFT;

                if (empty)
                    msg_len -= empty;

                /* send length prefix */
                uint16_t len_prefix = htons(msg_len);
                send(sock, &len_prefix, 2, 0);

                /* send payload */
                send(sock, msg_buf, msg_len, 0);

                printf("FPGA -> EXCHANGE MSG:");
                print_bytes(msg_buf, msg_len);

                msg_len = 0;
            }
        }
    }

    close(sock);
    return 0;
}