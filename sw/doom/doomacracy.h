/* doomacracy platform helpers shared by the firmware files */
#ifndef DOOMACRACY_H
#define DOOMACRACY_H

#include <stddef.h>
#include <stdint.h>

uint64_t doomacracy_time_us(void);
uint32_t doomacracy_wad_offset(void);
uint32_t doomacracy_wad_length(void);
void doomacracy_flash_read(void *dst, uint32_t flash_off, size_t n);
int doomacracy_is_wad_path(const char *path);

#endif
