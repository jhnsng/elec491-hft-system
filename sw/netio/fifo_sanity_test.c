#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

/*
 * Cyclone V HPS LW bridge
 */
#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x1000

/*
 * FIFO base offset in Qsys
 * (Qsys shows base = 0)
 */
#define FIFO_OFFSET      0x00000000

/*
 * FIFO register offsets (32-bit words)
 * Packet-enabled Avalon-MM → Avalon-ST FIFO
 */
#define FIFO_DATA_REG    0   // offset +0
#define FIFO_META_REG    1   // offset +4

/*
 * Packet metadata bit positions (per Intel spec)
 */
#define META_SOP   (1 << 0)
#define META_EOP   (1 << 1)
#define META_EMPTY_SHIFT 2   // bits [6:2]

int main(void)
{
    int fd;
    void *lw_base;
    volatile uint32_t *fifo;

    /* 1. Open /dev/mem */
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open(/dev/mem)");
        return 1;
    }

    /* 2. Map LW bridge */
    lw_base = mmap(NULL,
                   LW_BRIDGE_SPAN,
                   PROT_READ | PROT_WRITE,
                   MAP_SHARED,
                   fd,
                   LW_BRIDGE_BASE);

    if (lw_base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    /* 3. Get FIFO base pointer */
    fifo = (volatile uint32_t *)((uint8_t *)lw_base + FIFO_OFFSET);

    printf("LW bridge mapped at %p\n", lw_base);
    printf("FIFO base at        %p\n", fifo);

    /*
     * 4. Write packet metadata: SOP=1, EOP=0, EMPTY=0
     * This sets up the start of a packet.
     */
    uint32_t meta = META_SOP;
    fifo[FIFO_META_REG] = meta;

    /*
     * 5. Write one 32-bit data word
     * ASCII 'A' 'B' 'C' 'D'
     */
    fifo[FIFO_DATA_REG] = 0x41424344;

    /*
     * 6. Mark end-of-packet (EOP=1)
     * EMPTY=0 → all 4 bytes valid
     */
    meta = META_EOP;
    fifo[FIFO_META_REG] = meta;

    /*
     * 7. Write final data word (could be same or different)
     * This beat will assert EOP on the Avalon-ST side.
     */
    fifo[FIFO_DATA_REG] = 0x45464748; // 'E''F''G''H'

    printf("Sanity packet written:\n");
    printf("  SOP beat: 0x41424344 ('ABCD')\n");
    printf("  EOP beat: 0x45464748 ('EFGH')\n");

    /* 8. Cleanup */
    munmap(lw_base, LW_BRIDGE_SPAN);
    close(fd);

    return 0;
}
