/* doomacracy port of EEMBC CoreMark. The benchmark sources
 * (third_party/coremark) are used unchanged; only this directory is ours. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

/* soft double, used only by CoreMark's own timing and report */
#define HAS_FLOAT 1
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 1
#define HAS_PRINTF 1

#define COMPILER_VERSION "GCC " __VERSION__
#define COMPILER_FLAGS FLAGS_STR      /* the real flags, from the Makefile */
#define MEM_LOCATION "SRAM (code and static data)"

typedef int16_t   ee_s16;
typedef uint16_t  ee_u16;
typedef int32_t   ee_s32;
typedef uint32_t  ee_u32;
typedef uint8_t   ee_u8;
typedef double    ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t    ee_size_t;
#define align_mem(x) ((void *)(((ee_ptr_int)(x) + 3u) & ~(ee_ptr_int)3u))

/* microseconds, from TIMER_US */
typedef ee_u32 CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

/* 0: CoreMark picks a count that runs for at least 10 seconds */
#ifndef ITERATIONS
#define ITERATIONS 0
#endif

/* our main() calls upstream's once per seed set */
#define main coremark_main
int coremark_main(void);

extern volatile ee_s32 seed1_volatile, seed2_volatile, seed3_volatile;
extern volatile ee_s32 seed4_volatile, seed5_volatile;
extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#endif
