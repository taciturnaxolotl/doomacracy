//
// doomacracy video: replacement for upstream i_video.c.
//
// Doom draws 8-bit palette indices into I_VideoBuffer (320x200). It is a
// separate buffer that persists between frames the way Doom expects (the
// status bar and view border are only redrawn when they change), placed in
// SRAM (.sram_bss, see doom.ld) so the renderer's byte stores do not go to
// SDRAM. I_FinishUpdate copies it into the hardware back buffer and page
// flips by writing FB_BASE.
// I_SetPalette writes the 256 entries through the PALETTE register.
// No DG_ScreenBuffer, no 32-bit conversion, no scaling (hardware doubles).
//

#include <stdint.h>
#include <string.h>
#include <limits.h>

#include "config.h"
#include "doomtype.h"
#include "i_video.h"
#include "i_system.h"
#include "tables.h"
#include "v_video.h"
#include "z_zone.h"

#include "doomacracy_hw.h"

// globals other modules expect from i_video.c
int fb_scaling = 1;
int usemouse = 0;
byte *I_VideoBuffer = NULL;
boolean screensaver_mode = false;
boolean screenvisible;
float mouse_acceleration = 2.0;
int mouse_threshold = 10;
int usegamma = 0;

static uint8_t cur_palette[256][3];   // after gamma, for I_GetPaletteIndex
static int back;                      // 0: FB A is the back buffer, 1: FB B
static uint32_t flip_frame;           // FRAME_COUNT read right after the last flip

static const uint32_t fb_offset[2] = { FB_A_OFFSET, FB_B_OFFSET };

static byte video_buffer[SCREENWIDTH * SCREENHEIGHT]
    __attribute__((section(".sram_bss"), aligned(16)));

static void FB_Clear(int which)
{
    uint32_t *p = (uint32_t *)(SRAM_BASE + fb_offset[which]);
    int i;

    for (i = 0; i < FB_WIDTH * FB_HEIGHT / 4; ++i)
    {
        p[i] = 0;
    }
}

void I_InitGraphics(void)
{
    extern void I_InitInput(void);

    I_VideoBuffer = video_buffer;
    memset(I_VideoBuffer, 0, SCREENWIDTH * SCREENHEIGHT);

    // show a black buffer A, draw into B next
    FB_Clear(0);
    FB_Clear(1);
    FB_BASE = fb_offset[0];
    flip_frame = FRAME_COUNT;
    back = 1;

    printf("I_InitGraphics: 320x200 8bpp, framebuffers at SRAM+0x%x/0x%x\n",
           (unsigned) fb_offset[0], (unsigned) fb_offset[1]);

    screenvisible = true;

    I_InitInput();
}

void I_ShutdownGraphics(void)
{
}

void I_StartFrame(void)
{
}

void I_StartTic(void)
{
    extern void I_GetEvent(void);

    I_GetEvent();
}

void I_UpdateNoBlit(void)
{
}

void I_FinishUpdate(void)
{
    uint32_t *dst = (uint32_t *)(SRAM_BASE + fb_offset[back]);
    const uint32_t *src = (const uint32_t *) I_VideoBuffer;
    int i;

    // The buffer we are about to overwrite was the displayed one until the
    // last flip; FB_BASE is latched once per VGA frame, so make sure a frame
    // boundary has passed since then. Rendering a frame normally takes much
    // longer than 16.7 ms, so this rarely waits.
    while (FRAME_COUNT == flip_frame)
    {
    }

    if (((uintptr_t) src & 3) == 0)
    {
        for (i = 0; i < SCREENWIDTH * SCREENHEIGHT / 4; i += 8)
        {
            uint32_t a = src[i + 0], b = src[i + 1], c = src[i + 2], d = src[i + 3];
            uint32_t e = src[i + 4], f = src[i + 5], g = src[i + 6], h = src[i + 7];
            dst[i + 0] = a; dst[i + 1] = b; dst[i + 2] = c; dst[i + 3] = d;
            dst[i + 4] = e; dst[i + 5] = f; dst[i + 6] = g; dst[i + 7] = h;
        }
    }
    else
    {
        memcpy(dst, src, SCREENWIDTH * SCREENHEIGHT);
    }

    FB_BASE = fb_offset[back];
    flip_frame = FRAME_COUNT;
    back ^= 1;
}

void I_ReadScreen(byte *scr)
{
    memcpy(scr, I_VideoBuffer, SCREENWIDTH * SCREENHEIGHT);
}

void I_SetPalette(byte *palette)
{
    int i;

    for (i = 0; i < 256; ++i)
    {
        uint32_t r = gammatable[usegamma][*palette++];
        uint32_t g = gammatable[usegamma][*palette++];
        uint32_t b = gammatable[usegamma][*palette++];

        cur_palette[i][0] = r;
        cur_palette[i][1] = g;
        cur_palette[i][2] = b;
        PALETTE = ((uint32_t) i << 24) | (r << 16) | (g << 8) | b;
    }
}

// Given an RGB value, find the closest matching palette index.
int I_GetPaletteIndex(int r, int g, int b)
{
    int best = 0, best_diff = INT_MAX, i;

    for (i = 0; i < 256; ++i)
    {
        int dr = r - cur_palette[i][0];
        int dg = g - cur_palette[i][1];
        int db = b - cur_palette[i][2];
        int diff = dr * dr + dg * dg + db * db;

        if (diff < best_diff)
        {
            best = i;
            best_diff = diff;
            if (diff == 0)
            {
                break;
            }
        }
    }

    return best;
}

void I_BeginRead(void)
{
}

void I_EndRead(void)
{
}

void I_SetWindowTitle(char *title)
{
    extern void DG_SetWindowTitle(const char *title);

    DG_SetWindowTitle(title);
}

void I_GraphicsCheckCommandLine(void)
{
}

void I_SetGrabMouseCallback(grabmouse_callback_t func)
{
    (void) func;
}

void I_EnableLoadingDisk(void)
{
}

void I_BindVideoVariables(void)
{
}

void I_DisplayFPSDots(boolean dots_on)
{
    (void) dots_on;
}

void I_CheckIsScreensaver(void)
{
}
