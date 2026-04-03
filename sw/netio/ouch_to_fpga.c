#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <inttypes.h>
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

#define LISTEN_PORT 12345

#define ENABLE_FIFO 1

#define LW_BRIDGE_BASE 0xFF200000
#define LW_BRIDGE_SPAN 0x1000

#define FIFO_DATA_OFFSET 0x10
#define FIFO_CSR_OFFSET  0x60

#define MAX_OUCH_MSG 128
#define RECV_BUF     4096

/* ============================================================
 * Avalon FIFO registers
 * ============================================================ */

#define FIFO_DATA_REG 0
#define FIFO_META_REG 1

#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)

#define META_EMPTY_MASK  (0x3 << 2)
#define META_EMPTY_SHIFT 2


#define WRITE_FIFO_FILL_LEVEL (*fifo_write_status_ptr)
#define WRITE_FIFO_FULL		  ((*(fifo_write_status_ptr+1))& 1 ) 
#define WRITE_FIFO_EMPTY	  ((*(fifo_write_status_ptr+1))& 2 ) 

volatile unsigned int *fifo = NULL;
volatile unsigned int * fifo_write_status_ptr = NULL ;

/* ============================================================
 * OUCH message definitions
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

static void print_bytes(const uint8_t *buf, int len)
{
    for (int i = 0; i < len; i++)
        printf("%02X ", buf[i]);
    printf("\n");
}

static int get_ouch_msg_len(uint8_t type)
{
    for (size_t i = 0; i < sizeof(ouch_table)/sizeof(ouch_table[0]); i++)
        if (ouch_table[i].type == type)
            return ouch_table[i].length;

    return -1;
}

/* ============================================================
 * FIFO write
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

        if (i == 0)
            meta |= META_SOP;

        if (i == words-1)
        {
            meta |= META_EOP;
            meta |= (empty << META_EMPTY_SHIFT);
        }

        while (WRITE_FIFO_FILL_LEVEL >= (8192 - 64));

        fifo[FIFO_META_REG] = meta;
        fifo[FIFO_DATA_REG] = data;
    }

#endif
}

/* ============================================================
 * FIFO mapping
 * ============================================================ */

static volatile uint32_t *fifo_map(void)
{
#if ENABLE_FIFO

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0)
    {
        perror("open");
        return NULL;
    }

    void *base = mmap(NULL, LW_BRIDGE_SPAN,
                      PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, LW_BRIDGE_BASE);

    close(fd);

    if (base == MAP_FAILED)
    {
        perror("mmap");
        return NULL;
    }

    return (volatile uint32_t *)base;

#else
    return NULL;
#endif
}

/* ============================================================
 * TCP Server
 * ============================================================ */

static int tcp_server_listen(int port)
{
    int srv = socket(AF_INET, SOCK_STREAM, 0);

    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0)
    {
        perror("bind");
        return -1;
    }

    if (listen(srv, 1) < 0)
    {
        perror("listen");
        return -1;
    }

    printf("Listening on port %d...\n", port);

    struct sockaddr_in client;
    socklen_t len = sizeof(client);

    int sock = accept(srv, (struct sockaddr*)&client, &len);

    printf("Connection accepted\n");

    close(srv);

    return sock;
}

/* ============================================================
 * Main
 * ============================================================ */

int main()
{
    uint8_t recv_buf[RECV_BUF];
    uint8_t frame_buf[4096];
    int frame_len = 0;

    uint64_t msg_count = 0;
    uint64_t count_A = 0;
    uint64_t count_C = 0;
    uint64_t count_E = 0;
    uint64_t fifo_msgs = 0;

#if ENABLE_FIFO

    volatile uint32_t *lw_base = fifo_map();
    if (!lw_base)
        return 1;

    volatile char *base_ptr = (volatile char *)lw_base;

    fifo = (volatile unsigned int*)(base_ptr + FIFO_DATA_OFFSET); //0x10
    fifo_write_status_ptr = (volatile unsigned int*)(base_ptr + FIFO_CSR_OFFSET); //0x60

#endif

    int sock = tcp_server_listen(LISTEN_PORT);
    if (sock < 0) return 1;

   while (1)
    {
        int n = recv(sock, recv_buf, sizeof(recv_buf), 0);

        if (n <= 0)
        {
            printf("TCP closed\n");
            break;
        }

        printf("\nReceived %d bytes:\n", n);
        print_bytes(recv_buf, n);

        memcpy(frame_buf + frame_len, recv_buf, n);
        frame_len += n;

        int pos = 0;

        while (1)
        {
            /* Need at least 2 bytes for length */
            if (frame_len - pos < 2)
                break;

            /* Parse 2-byte big-endian length */
            uint16_t msg_len = ((uint16_t)frame_buf[pos] << 8) |
                   (uint16_t)frame_buf[pos + 1];

            if (msg_len == 0 || msg_len > MAX_OUCH_MSG)
            {
                printf("Invalid length %u\n", msg_len);
                pos += 1;  // resync
                continue;
            }

            /* Wait until full message is available */
            if (frame_len - pos < 2 + msg_len)
                break;

            uint8_t *msg = &frame_buf[pos + 2];
            uint8_t type = msg[0];

            int expected_len = get_ouch_msg_len(type);

            if (expected_len > 0 && expected_len == msg_len)
                {
                    /* Send ONLY payload (no length prefix) to FPGA */
                    fifo_write_msg(msg, msg_len);
                }
            else
                {
                    printf("Dropping invalid message\n");
                }

            printf("Parsed message (type=%c, len=%u):\n", type, msg_len);
            print_bytes(msg, msg_len);

            /* Counters */
            if (type == 'A') count_A++;
            else if (type == 'C') count_C++;
            else if (type == 'E') count_E++;

            fifo_msgs++;
            msg_count++;

            pos += 2 + msg_len;
        }

        if (pos > 0)
        {
            memmove(frame_buf, frame_buf + pos, frame_len - pos);
            frame_len -= pos;
        }
    }

    close(sock);

    return 0;
}