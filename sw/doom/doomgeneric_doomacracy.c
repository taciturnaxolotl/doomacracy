//
// doomgeneric platform layer for doomacracy (spec.md I/O registers).
//
// Provides main(), DG_Init/DG_DrawFrame/DG_SleepMs/DG_GetTicksMs/DG_GetKey/
// DG_SetWindowTitle, and a PS/2 set-2 scancode decoder (E0 prefix, F0 break,
// E1 pause) that turns raw KBD bytes into doomkeys.h keys.
//
// Video does not go through DG_ScreenBuffer/DG_DrawFrame at all; see
// i_video_doomacracy.c.
//

#include <stdio.h>
#include <stdint.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "m_argv.h"

#include "doomacracy.h"
#include "doomacracy_hw.h"

pixel_t *DG_ScreenBuffer = NULL;   // unused on this platform

void M_FindResponseFile(void);
void D_DoomMain(void);

// ---------------------------------------------------------------- keyboard

// set-2 make code -> doom key, no prefix. doomgeneric's default bindings
// (m_controls.c) use KEY_FIRE/KEY_USE/KEY_STRAFE_L/KEY_STRAFE_R rather than
// ctrl/space/comma/period, so those keys map to the doomgeneric codes.
static const unsigned char ps2_normal[0x88] = {
    [0x1c] = 'a', [0x32] = 'b', [0x21] = 'c', [0x23] = 'd', [0x24] = 'e',
    [0x2b] = 'f', [0x34] = 'g', [0x33] = 'h', [0x43] = 'i', [0x3b] = 'j',
    [0x42] = 'k', [0x4b] = 'l', [0x3a] = 'm', [0x31] = 'n', [0x44] = 'o',
    [0x4d] = 'p', [0x15] = 'q', [0x2d] = 'r', [0x1b] = 's', [0x2c] = 't',
    [0x3c] = 'u', [0x2a] = 'v', [0x1d] = 'w', [0x22] = 'x', [0x35] = 'y',
    [0x1a] = 'z',
    [0x45] = '0', [0x16] = '1', [0x1e] = '2', [0x26] = '3', [0x25] = '4',
    [0x2e] = '5', [0x36] = '6', [0x3d] = '7', [0x3e] = '8', [0x46] = '9',
    [0x0e] = '`', [0x4e] = KEY_MINUS, [0x55] = KEY_EQUALS, [0x54] = '[',
    [0x5b] = ']', [0x5d] = '\\', [0x4c] = ';', [0x52] = '\'',
    [0x41] = KEY_STRAFE_L, [0x49] = KEY_STRAFE_R,   // , and . strafe
    [0x4a] = '/',
    [0x29] = KEY_USE,                               // space: use
    [0x0d] = KEY_TAB, [0x5a] = KEY_ENTER, [0x76] = KEY_ESCAPE,
    [0x66] = KEY_BACKSPACE,
    [0x12] = KEY_RSHIFT, [0x59] = KEY_RSHIFT,   // both shifts: run
    [0x14] = KEY_FIRE,                          // left ctrl: fire
    [0x11] = KEY_RALT,                          // left alt: strafe
    [0x58] = KEY_CAPSLOCK, [0x77] = KEY_NUMLOCK, [0x7e] = KEY_SCRLCK,
    [0x05] = KEY_F1, [0x06] = KEY_F2, [0x04] = KEY_F3, [0x0c] = KEY_F4,
    [0x03] = KEY_F5, [0x0b] = KEY_F6, [0x83] = KEY_F7, [0x0a] = KEY_F8,
    [0x01] = KEY_F9, [0x09] = KEY_F10, [0x78] = KEY_F11, [0x07] = KEY_F12,
    // keypad (num lock ignored, like DOS Doom)
    [0x70] = KEY_INS, [0x71] = KEY_DEL, [0x69] = KEY_END, [0x72] = KEY_DOWNARROW,
    [0x7a] = KEY_PGDN, [0x6b] = KEY_LEFTARROW, [0x73] = '5',
    [0x74] = KEY_RIGHTARROW, [0x6c] = KEY_HOME, [0x75] = KEY_UPARROW,
    [0x7d] = KEY_PGUP, [0x79] = '+', [0x7b] = KEY_MINUS, [0x7c] = '*',
};

// set-2 make code after E0
static unsigned char ps2_extended(unsigned char code)
{
    switch (code)
    {
        case 0x14: return KEY_FIRE;     // right ctrl: fire
        case 0x11: return KEY_RALT;
        case 0x75: return KEY_UPARROW;
        case 0x72: return KEY_DOWNARROW;
        case 0x6b: return KEY_LEFTARROW;
        case 0x74: return KEY_RIGHTARROW;
        case 0x70: return KEY_INS;
        case 0x71: return KEY_DEL;
        case 0x6c: return KEY_HOME;
        case 0x69: return KEY_END;
        case 0x7d: return KEY_PGUP;
        case 0x7a: return KEY_PGDN;
        case 0x5a: return KEY_ENTER;    // keypad enter
        case 0x4a: return '/';          // keypad divide
        case 0x7c: return KEY_PRTSCR;   // print screen (E0 12 E0 7C)
        default:   return 0;            // E0 12 / E0 59 fake shifts, GUI keys...
    }
}

#define KEYQ_SIZE 32
static struct { unsigned char pressed, key; } keyq[KEYQ_SIZE];
static unsigned keyq_head, keyq_tail;

static void keyq_put(int pressed, unsigned char key)
{
    if (key == 0 || keyq_tail - keyq_head >= KEYQ_SIZE)
    {
        return;
    }
    keyq[keyq_tail % KEYQ_SIZE].pressed = pressed;
    keyq[keyq_tail % KEYQ_SIZE].key = key;
    keyq_tail++;
}

static int ps2_e0, ps2_f0, ps2_e1_skip;

static void ps2_byte(unsigned char b)
{
    if (ps2_e1_skip)
    {
        // E1 14 77 E1 F0 14 F0 77 is Pause; it has no break code
        if (--ps2_e1_skip == 0)
        {
            keyq_put(1, KEY_PAUSE);
            keyq_put(0, KEY_PAUSE);
        }
        return;
    }

    switch (b)
    {
        case 0xe0: ps2_e0 = 1; return;
        case 0xf0: ps2_f0 = 1; return;
        case 0xe1: ps2_e1_skip = 7; ps2_e0 = ps2_f0 = 0; return;
        case 0x00: case 0xaa: case 0xee: case 0xfa:
        case 0xfc: case 0xfd: case 0xfe: case 0xff:
            // keyboard self test / ack / error: not a key
            ps2_e0 = ps2_f0 = 0;
            return;
    }

    {
        unsigned char key;

        if (ps2_e0)
            key = ps2_extended(b);
        else
            key = b < sizeof(ps2_normal) ? ps2_normal[b] : 0;

        keyq_put(!ps2_f0, key);
        ps2_e0 = ps2_f0 = 0;
    }
}

static void ps2_poll(void)
{
    uint32_t v;

    while ((v = KBD) & KBD_VALID)
    {
        ps2_byte(v & 0xff);
    }
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    ps2_poll();

    if (keyq_head == keyq_tail)
    {
        return 0;
    }
    *pressed = keyq[keyq_head % KEYQ_SIZE].pressed;
    *key = keyq[keyq_head % KEYQ_SIZE].key;
    keyq_head++;
    return 1;
}

// ---------------------------------------------------------------- the rest

void DG_Init(void)
{
    LEDG = 0x0f;
    HEX = 0xD000;
}

void DG_DrawFrame(void)
{
    // not used: I_FinishUpdate page flips directly
}

void DG_SleepMs(uint32_t ms)
{
    uint64_t end = doomacracy_time_us() + (uint64_t) ms * 1000;

    while (doomacracy_time_us() < end)
    {
        ps2_poll();   // keep the 16-byte hardware FIFO drained
    }
}

uint32_t DG_GetTicksMs(void)
{
    return (uint32_t) (doomacracy_time_us() / 1000);
}

void DG_SetWindowTitle(const char *title)
{
    printf("doomacracy: %s\n", title);
}

// Doom (chocolate) assumes a v1.9 executable for the shareware IWAD, and then
// refuses to play the attract-mode demos of older IWADs (the v1.8 shareware
// demos are version 108). Look at the version byte of DEMO1 in the WAD
// directory and pick the matching -gameversion.
static const char *DetectGameVersion(void)
{
    uint32_t base = doomacracy_wad_offset();
    uint32_t hdr[3], i;

    doomacracy_flash_read(hdr, base, sizeof(hdr));
    for (i = 0; i < hdr[1]; ++i)
    {
        uint32_t ent[4];
        unsigned char ver;

        doomacracy_flash_read(ent, base + hdr[2] + 16 * i, sizeof(ent));
        if (ent[2] != 0x4f4d4544 || ent[3] != 0x31)   // "DEMO" "1"
        {
            continue;
        }
        if (ent[1] == 0)
        {
            return NULL;
        }
        doomacracy_flash_read(&ver, base + ent[0], 1);
        switch (ver)
        {
            case 106: return "1.666";
            case 107: return "1.7";
            case 108: return "1.8";
            default:  return NULL;
        }
    }
    return NULL;
}

int main(void)
{
    static char *args[] = { "doom", "-iwad", "doom1.wad", NULL, NULL, NULL, NULL, NULL };
    const char *version;
    uint32_t frames = 0;

    printf("doomacracy firmware: wad at flash+0x%x, %u bytes\n",
           (unsigned) doomacracy_wad_offset(), (unsigned) doomacracy_wad_length());

    myargc = 3;
    myargv = args;

    version = DetectGameVersion();
    if (version != NULL)
    {
        printf("doomacracy: demos are from Doom %s, using -gameversion %s\n",
               version, version);
        args[myargc++] = "-gameversion";
        args[myargc++] = (char *) version;
    }

    // SW0 up: benchmark, run demo1 as fast as possible and quit
    if (SWITCHES & 1)
    {
        printf("doomacracy: SW0 set, running -timedemo demo1\n");
        args[myargc++] = "-timedemo";
        args[myargc++] = "demo1";
    }

    M_FindResponseFile();
    DG_Init();
    D_DoomMain();

    for (;;)
    {
        doomgeneric_Tick();
        LEDR = ++frames & 0x3ff;
    }
}
