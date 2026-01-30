#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/mman.h>

/* ============================================================
 * UDP / ITCH
 * ============================================================ */

#define LISTEN_PORT    12345
#define MAX_MSG_SIZE  512

struct itch_msg_def {
    char type;
    int  length;
};

static const struct itch_msg_def itch_table[] = {
    { 'S', 12 }, { 'R', 39 }, { 'A', 36 }, { 'F', 40 },
    { 'E', 31 }, { 'C', 36 }, { 'X', 23 }, { 'D', 19 },
    { 'U', 35 }, { 'P', 44 },
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
 * Avalon-ST FIFO (LW bridge)
 * ============================================================ */

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x1000

#define FIFO_OFFSET     0x00000000
#define FIFO_DATA_REG   0
#define FIFO_META_REG   1

#define META_SOP         (1 << 0)
#define META_EOP         (1 << 1)
#define META_EMPTY_SHIFT 2

/*
 * Sends a single ITCH message as an Avalon-ST packet:
 *  - 32-bit data beats
 *  - SOP on first beat
 *  - EOP + EMPTY on last beat
 */
static void fifo_send_packet(volatile uint32_t *fifo,
                             const uint8_t *buf,
                             int len)
{
    int beats = (len + 3) / 4;
    int empty = (4 - (len % 4)) % 4;

    for (int i = 0; i < beats; i++) {
        uint32_t meta = 0;

        if (i == 0)
            meta |= META_SOP;

        if (i == beats - 1) {
            meta |= META_EOP;
            meta |= (empty << META_EMPTY_SHIFT);
        }

        if (meta)
            fifo[FIFO_META_REG] = meta;

        uint32_t word = 0;
        for (int b = 0; b < 4; b++) {
            int idx = i * 4 + b;
            if (idx < len)
                word |= ((uint32_t)buf[idx]) << (8 * b);
        }

        fifo[FIFO_DATA_REG] = word;
    }
}

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
 * LW bridge mapping
 * ============================================================ */

static volatile uint32_t *map_fifo(void)
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

    return (volatile uint32_t *)((uint8_t *)base + FIFO_OFFSET);
}

/* ============================================================
 * Main
 * ============================================================ */

int main(void)
{
    uint8_t buf[MAX_MSG_SIZE];

    int sock = udp_open_and_bind(LISTEN_PORT);
    if (sock < 0)
        return 1;

    volatile uint32_t *fifo = map_fifo();
    if (!fifo) {
        close(sock);
        return 1;
    }

    printf("NetIO: listening for ITCH UDP on port %d\n", LISTEN_PORT);

    while (1) {
        ssize_t n = recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);
        if (n < 0) {
            perror("recvfrom");
            break;
        }

        if (n < 1) {
            printf("Empty UDP packet ignored\n");
            continue;
        }

        uint8_t type = buf[0];
        int expected_len = get_itch_msg_length(type);

        if (expected_len < 0) {
            printf("Unknown ITCH type 0x%02X\n", type);
            continue;
        }

        if (n != expected_len) {
            printf("Length mismatch for ITCH %c: got %zd, expected %d\n",
                   type, n, expected_len);
            continue;
        }

        /* ====================================================
         * Integration point:
         * raw ITCH bytes -> Avalon-ST FIFO
         * ==================================================== */
        fifo_send_packet(fifo, buf, n);

        printf("Forwarded ITCH '%c' (%d bytes) to FIFO\n",
               type, expected_len);
    }

    close(sock);
    return 0;
}
