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

/* ============================================================
 * Configuration
 * ============================================================ */

#define LISTEN_PORT     12345
#define MAX_UDP_SIZE    512

/* ============================================================
 * ITCH validation table (NOT parsing)
 * ============================================================ */

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
 * Avalon FIFO (LW bridge)
 * ============================================================ */

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x1000

#define FIFO_DATA_REG   0
#define FIFO_META_REG   1

#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)

/* Semantic FIFO payload:
 * [63:32] price
 * [31:1]  delta_quantity (signed)
 * [0]     side (0=buy, 1=sell)
 */
static void fifo_write_update(volatile uint32_t *fifo,
                              uint32_t price,
                              int32_t  delta_qty,
                              uint8_t  side)
{
    uint64_t word =
        ((uint64_t)price << 32) |
        ((uint64_t)(delta_qty & 0x7FFFFFFF) << 1) |
        (side & 0x1);

    /* Single-beat packet: SOP + EOP together */
    fifo[FIFO_META_REG] = META_SOP | META_EOP;
    fifo[FIFO_DATA_REG] = (uint32_t)(word & 0xFFFFFFFF);
    fifo[FIFO_DATA_REG] = (uint32_t)(word >> 32);
}

/* ============================================================
 * OB HPS program interface (implemented elsewhere)
 * ============================================================ */

struct ob_update {
    uint32_t price;
    int32_t  delta_qty;
    uint8_t  side;
};

/*
 * Returns true if this ITCH message produces an order-book update.
 * Must be fast, bounded, non-blocking.
 */
extern bool ob_process_itch(const uint8_t *buf,
                            size_t len,
                            struct ob_update *out);

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

static ssize_t udp_recv_packet(int sock, uint8_t *buf, size_t maxlen)
{
    ssize_t n = recvfrom(sock, buf, maxlen, 0, NULL, NULL);
    if (n < 0) {
        perror("recvfrom");
        return -1;
    }
    return n;
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

    while (1) {
        ssize_t n = udp_recv_packet(sock, buf, sizeof(buf));
        if (n <= 0)
            continue;

        uint8_t type = buf[0];
        int expected_len = get_itch_msg_length(type);

        if (expected_len < 0 || n != expected_len) {
            printf("Dropped malformed ITCH: type=%c len=%zd\n",
                   type, n);
            continue;
        }

        struct ob_update upd;
        if (ob_process_itch(buf, n, &upd)) {
            fifo_write_update(fifo,
                              upd.price,
                              upd.delta_qty,
                              upd.side);
        }
    }

    return 0;
}
