/* doomacracy hardware definitions (spec.md). Shared by boot ROM and firmware. */
#ifndef DOOMACRACY_HW_H
#define DOOMACRACY_HW_H

#include <stdint.h>

#define ROM_BASE    0x00000000u
#define SRAM_BASE   0x10000000u
#define SRAM_SIZE   0x00080000u
#define SDRAM_BASE  0x20000000u
#define SDRAM_SIZE  0x00800000u
#define FLASH_BASE  0x30000000u
#define FLASH_SIZE  0x00400000u
#define IO_BASE     0xF0000000u

#define IO_REG(off) (*(volatile uint32_t *)(IO_BASE + (off)))
#define UART_DATA   IO_REG(0x00)
#define UART_STATUS IO_REG(0x04)
#define TIMER_US    IO_REG(0x08)
#define TIMER_CYCLES IO_REG(0x0C)
#define KBD         IO_REG(0x10)
#define SWITCHES    IO_REG(0x14)
#define LEDR        IO_REG(0x18)
#define LEDG        IO_REG(0x1C)
#define HEX         IO_REG(0x20)
#define FB_BASE     IO_REG(0x30)
#define FRAME_COUNT IO_REG(0x34)
#define PALETTE     IO_REG(0x38)
#define JTAG_DATA   IO_REG(0x40)   /* read pops the next word from the JTAG loader */
#define JTAG_STATUS IO_REG(0x44)   /* bit 0 word waiting, bit 1 overflow (sticky) */

#define SW_JTAG_LOAD  (1u << 9)    /* SW9 up at reset: load flash over JTAG */
#define JTAG_MAGIC    0x4A544147u  /* "JTAG": first word of a load stream */

#define UART_TX_READY 1u
#define KBD_VALID     0x100u

/* framebuffers: byte offsets into SRAM */
#define FB_A_OFFSET 0x60000u
#define FB_B_OFFSET 0x70000u
#define FB_WIDTH    320
#define FB_HEIGHT   200

/* flash header */
#define FLASH_MAGIC 0x4D4F4F44u
typedef struct {
    uint32_t magic;
    uint32_t load_addr;
    uint32_t length;
    uint32_t entry;
    uint32_t wad_offset;
    uint32_t wad_length;
} flash_header_t;
#define FLASH_HEADER ((volatile flash_header_t *)FLASH_BASE)
#define FLASH_FW_OFFSET 0x100u

#endif
