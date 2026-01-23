#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x1000

#define FIFO_OFFSET     0x00000000
#define FIFO_DATA_REG   0
#define FIFO_META_REG   1

#define META_SOP        (1 << 0)
#define META_EOP        (1 << 1)
#define META_EMPTY_SHIFT 2

static void send_packet(volatile uint32_t *fifo,
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

int main(void)
{
    int fd;
    void *lw_base;
    volatile uint32_t *fifo;

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    lw_base = mmap(NULL, LW_BRIDGE_SPAN,
                   PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, LW_BRIDGE_BASE);

    if (lw_base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    fifo = (volatile uint32_t *)((uint8_t *)lw_base + FIFO_OFFSET);

    /* ---------------- ITCH messages ---------------- */

    uint8_t itch_A[36];
    uint8_t itch_E[31];
    uint8_t itch_X[23];

    itch_A[0] = 'A';
    itch_E[0] = 'E';
    itch_X[0] = 'X';

    for (int i = 1; i < 36; i++)
        itch_A[i] = (uint8_t)i;

    for (int i = 1; i < 31; i++)
        itch_E[i] = (uint8_t)i;

    for (int i = 1; i < 23; i++)
        itch_X[i] = (uint8_t)i;

    /* ---------------- Send back-to-back ---------------- */

    send_packet(fifo, itch_A, sizeof(itch_A));
    send_packet(fifo, itch_E, sizeof(itch_E));
    send_packet(fifo, itch_X, sizeof(itch_X));

    printf("Sent ITCH packets A(36), E(31), X(23)\n");

    munmap(lw_base, LW_BRIDGE_SPAN);
    close(fd);
    return 0;
}
