//
// doomacracy WAD backend: reads the IWAD straight out of memory-mapped flash.
//
// Replaces upstream w_file_stdc.c in the build. It defines the symbol
// stdc_wad_file because that is the class upstream w_file.c always uses
// (without -mmap), so w_file.c needs no patch.
//
// Reads copy into the caller's (zone) buffer; we never hand out pointers into
// flash (mapped stays NULL) because flash is uncached and slow.
//

#include <stdio.h>

#include "doomacracy.h"
#include "w_file.h"
#include "z_zone.h"

extern wad_file_class_t stdc_wad_file;

static wad_file_t *W_Flash_OpenFile(char *path)
{
    wad_file_t *result;

    if (!doomacracy_is_wad_path(path))
    {
        return NULL;
    }

    result = Z_Malloc(sizeof(wad_file_t), PU_STATIC, 0);
    result->file_class = &stdc_wad_file;
    result->mapped = NULL;
    result->length = doomacracy_wad_length();

    return result;
}

static void W_Flash_CloseFile(wad_file_t *wad)
{
    Z_Free(wad);
}

static size_t W_Flash_Read(wad_file_t *wad, unsigned int offset,
                           void *buffer, size_t buffer_len)
{
    if (offset >= wad->length)
    {
        return 0;
    }
    if (buffer_len > wad->length - offset)
    {
        buffer_len = wad->length - offset;
    }

    doomacracy_flash_read(buffer, doomacracy_wad_offset() + offset, buffer_len);

    return buffer_len;
}

wad_file_class_t stdc_wad_file =
{
    W_Flash_OpenFile,
    W_Flash_CloseFile,
    W_Flash_Read,
};
