# doomacracy top-level Makefile.
#
# The RTL side owns everything outside the marked software section below and
# can add its own targets (sim, synth, ...) in a separate section.

.PHONY: all
all: sw emu

# ======================================================================
# BEGIN software section (owner: sw side; covers sw/, emu/, tools/)
# ======================================================================
#
# Targets:
#   make sw        boot ROM + firmware + flash image (build/flash.bin, .hex)
#   make wad       stripped WAD (build/doom1-stripped.wad)
#   make emu       host emulator (build/emu)
#   make run-emu   boot to the title screen, dump a few frames (build/frames/title-*)
#   make demo-emu  menu, new game, gameplay from a key script (build/frames/play-*)
#   make attract-emu  title and attract-mode demos (build/frames/attract-*)
#   make bench-emu timedemo demo1 (instructions per frame)
#   make sw-clean  remove software build outputs
#
# Toolchain: riscv32-none-elf-gcc whose newlib/libgcc are built for
# rv32im/ilp32 (see flake.nix). Override CROSS to use another prefix.

CROSS    ?= riscv32-none-elf-
CC_RV    := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size
PYTHON   ?= python3
HOSTCC   ?= cc
MAGICK   ?= magick

BUILD    := build
SWB      := sw/build
DG       := third_party/doomgeneric/doomgeneric
WAD_IN   ?= wad/doom1.wad

RV_ARCH  := -march=rv32im -mabi=ilp32
RV_OPT   ?= -O2

# ---------------------------------------------------------------- boot ROM

BOOT_CFLAGS := $(RV_ARCH) -Os -ffreestanding -nostdlib -fno-pic -mstrict-align \
               -Wall -Wextra -Isw/include

$(SWB)/boot/boot.elf: sw/boot/start.S sw/boot/boot.c sw/boot/boot.ld sw/include/doomacracy_hw.h
	@mkdir -p $(@D)
	$(CC_RV) $(BOOT_CFLAGS) -T sw/boot/boot.ld -Wl,--gc-sections -o $@ sw/boot/start.S sw/boot/boot.c

$(SWB)/boot.bin: $(SWB)/boot/boot.elf
	$(OBJCOPY) -O binary $< $@
	@$(SIZE) $<

$(BUILD)/boot.bin: $(SWB)/boot.bin
	@mkdir -p $(@D)
	cp $< $@

$(BUILD)/boot_rom_init.txt: $(SWB)/boot.bin tools/rom_init.py
	@mkdir -p $(@D)
	$(PYTHON) tools/rom_init.py $< $@

# ---------------------------------------------------------------- firmware

# upstream doomgeneric sources we use unchanged (i_video.c, doomgeneric.c and
# w_file_stdc.c are replaced by our own files in sw/doom/)
DG_SRCS := dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop \
  d_main d_mode d_net f_finale f_wipe g_game hu_lib hu_stuff info i_cdmus \
  i_endoom i_joystick i_scale i_sound i_system i_timer memio m_argv m_bbox \
  m_cheat m_config m_controls m_fixed m_menu m_misc m_random p_ceilng p_doors \
  p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr \
  p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data \
  r_draw r_main r_plane r_segs r_sky r_things sha1 sounds statdump st_lib \
  st_stuff s_sound tables v_video wi_stuff w_checksum w_file w_main w_wad \
  z_zone i_input

FW_SRCS := doomgeneric_doomacracy i_video_doomacracy w_file_flash syscalls

FW_OBJS := $(addprefix $(SWB)/doom/dg/,$(addsuffix .o,$(DG_SRCS))) \
           $(addprefix $(SWB)/doom/,$(addsuffix .o,$(FW_SRCS))) \
           $(SWB)/doom/crt0.o

DOOM_CFLAGS := $(RV_ARCH) $(RV_OPT) -mstrict-align -fno-pic -ffunction-sections \
  -fdata-sections -fno-strict-aliasing -g \
  -DNORMALUNIX -D_DEFAULT_SOURCE -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 \
  -Isw/include -Isw/doom -I$(DG)

$(SWB)/doom/dg/%.o: $(DG)/%.c
	@mkdir -p $(@D)
	$(CC_RV) $(DOOM_CFLAGS) -w -c $< -o $@

$(SWB)/doom/%.o: sw/doom/%.c sw/doom/doomacracy.h sw/include/doomacracy_hw.h
	@mkdir -p $(@D)
	$(CC_RV) $(DOOM_CFLAGS) -Wall -Wno-unused-parameter -c $< -o $@

$(SWB)/doom/crt0.o: sw/doom/crt0.S
	@mkdir -p $(@D)
	$(CC_RV) $(RV_ARCH) -c $< -o $@

$(SWB)/doom.elf: $(FW_OBJS) sw/doom/doom.ld
	$(CC_RV) $(RV_ARCH) -nostartfiles -T sw/doom/doom.ld -Wl,--gc-sections \
	  -Wl,--no-warn-rwx-segments -Wl,-Map,$(SWB)/doom.map -o $@ $(FW_OBJS) -lm -lc -lgcc
	@$(SIZE) $@

# SRAM image (copied by the boot ROM) and cold image (copied from flash to
# SDRAM by crt0), see sw/doom/doom.ld
$(SWB)/doom.bin: $(SWB)/doom.elf
	$(OBJCOPY) -O binary -j .text.boot -j .text -j .init_array -j .rodata -j .data $< $(SWB)/doom.bin
	$(OBJCOPY) -O binary -j .cold $< $(SWB)/doom-cold.bin
	@ls -l $(SWB)/doom.bin $(SWB)/doom-cold.bin | awk '{print $$9 ": " $$5 " bytes"}'

$(SWB)/doom-cold.bin: $(SWB)/doom.bin
	@true

# ---------------------------------------------------------------- wad + flash

$(BUILD)/doom1-stripped.wad: $(WAD_IN) tools/wad_strip.py
	@mkdir -p $(@D)
	$(PYTHON) tools/wad_strip.py $< $@

$(BUILD)/flash.bin: $(SWB)/doom.bin $(SWB)/doom-cold.bin $(BUILD)/doom1-stripped.wad tools/mkflash.py
	$(PYTHON) tools/mkflash.py --firmware $(SWB)/doom.bin --cold $(SWB)/doom-cold.bin \
	  --wad $(BUILD)/doom1-stripped.wad \
	  --load 0x10000000 --entry 0x10000000 --out $(BUILD)/flash.bin --hex $(BUILD)/flash.hex

$(BUILD)/flash.hex: $(BUILD)/flash.bin
	@true

# ---------------------------------------------------------------- emulator

$(BUILD)/emu: emu/doomacracy_emu.c
	@mkdir -p $(@D)
	$(HOSTCC) -O2 -Wall -Wextra -o $@ $<

# ---------------------------------------------------------------- phony

.PHONY: sw wad emu run-emu demo-emu attract-emu bench-emu sw-clean boot firmware

boot: $(SWB)/boot.bin $(BUILD)/boot.bin $(BUILD)/boot_rom_init.txt
firmware: $(SWB)/doom.bin $(SWB)/doom-cold.bin
sw: boot firmware $(BUILD)/flash.bin
wad: $(BUILD)/doom1-stripped.wad
emu: $(BUILD)/emu

EMU_RUN = $(BUILD)/emu --boot $(BUILD)/boot.bin --flash $(BUILD)/flash.bin
PPM2PNG = cd $(BUILD)/frames && for f in $(1)*.ppm; do $(MAGICK) $$f $${f%.ppm}.png && rm $$f; done

# boot to the title screen and dump the first few frames (640x400 PNG)
run-emu: sw emu
	@mkdir -p $(BUILD)/frames && rm -f $(BUILD)/frames/title-*
	$(EMU_RUN) --dump $(BUILD)/frames --dump-prefix title- --scale 2 --max-flips 8
	$(call PPM2PNG,title-)
	@ls $(BUILD)/frames/title-*

# menu, new game, gameplay (keys from sw/doom/keys-demo.txt), every 10th flip
demo-emu: sw emu
	@mkdir -p $(BUILD)/frames && rm -f $(BUILD)/frames/play-*
	$(EMU_RUN) --keys sw/doom/keys-demo.txt --dump $(BUILD)/frames --dump-prefix play- \
	  --dump-every 10 --scale 2 --max-flips 400
	$(call PPM2PNG,play-)

# no input: title, then the attract-mode demos, every 50th flip
attract-emu: sw emu
	@mkdir -p $(BUILD)/frames && rm -f $(BUILD)/frames/attract-*
	$(EMU_RUN) --dump $(BUILD)/frames --dump-prefix attract- --dump-every 50 --scale 2 \
	  --max-flips 1500
	$(call PPM2PNG,attract-)

# SW0 up: -timedemo demo1, as fast as possible; prints instructions between flips
bench-emu: sw emu
	$(EMU_RUN) --switches 1

sw-clean:
	rm -rf $(SWB) $(BUILD)/boot.bin $(BUILD)/boot_rom_init.txt $(BUILD)/flash.bin \
	  $(BUILD)/flash.hex $(BUILD)/doom1-stripped.wad $(BUILD)/emu $(BUILD)/frames

# ======================================================================
# END software section
# ======================================================================

# ======================================================================
# RTL section
# ======================================================================
#
#   make rtl-check  analyze all VHDL (nvc)
#   make rom        boot ROM image -> rtl/boot_rom_data.vhd
#   make cpu-test   CPU alone against an ideal memory, runs sim/cputest
#   make soc-test   whole board with chip models running sim/soctest
#   make soc-boot   whole board booting the real firmware from build/flash.hex,
#                   writing a CPU trace and comparing it with the emulator's
#
# soc-test and soc-boot swap the boot ROM, so run `make rom` before Quartus.

NVC   ?= nvc
NVCW  := $(NVC) --std=1993 --work=work:$(BUILD)/work -M 512m -H 1g
RTL   := rtl/boot_rom_data.vhd rtl/sdpram.vhd rtl/cpu.vhd rtl/icache.vhd rtl/dcache.vhd \
         rtl/membus.vhd rtl/boot_rom.vhd rtl/sram_ctrl.vhd rtl/sdram_ctrl.vhd rtl/flash_ctrl.vhd \
         rtl/io.vhd rtl/video.vhd rtl/uart.vhd rtl/ps2_rx.vhd rtl/doomacracy.vhd
SIM   := sim/models.vhd sim/tb_soc.vhd sim/tb_cpu.vhd
SOCT  := sim/soctest
TRACE_N ?= 3000000

.PHONY: rtl-check rom cpu-test soc-test soc-boot

rtl-check:
	@mkdir -p $(BUILD)
	$(NVCW) -a $(RTL) $(SIM)

rom: $(BUILD)/boot_rom_init.txt
	$(PYTHON) tools/gen_rom.py $< rtl/boot_rom_data.vhd

cpu-test:
	@mkdir -p $(BUILD)
	$(MAKE) -C sim/cputest
	$(NVCW) -a $(RTL) $(SIM) -e tb_cpu -r
	@cat sim/cputest/expected.txt

soc-test:
	@mkdir -p $(BUILD) sim/out
	$(MAKE) -C $(SOCT)
	$(PYTHON) tools/gen_rom.py $(SOCT)/soctest_rom.txt rtl/boot_rom_data.vhd
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=$(SOCT)/flash_test.hex \
	    -gKEYS=$(SOCT)/keys.txt -gMAX_MS=120 -gDUMP_FIRST=2 -gDUMP_EVERY=1000 -r
	$(PPM2PNG_SIM)

soc-boot: rom sw emu
	@mkdir -p sim/out
	$(EMU_RUN) --trace $(BUILD)/emu_trace.txt --trace-count $(TRACE_N) --max-instr $(TRACE_N) --quiet
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=$(BUILD)/flash.hex \
	    -gTRACE=$(BUILD)/rtl_trace.txt -gTRACE_MAX=$(TRACE_N) -gMAX_MS=1000 -gDUMP_EVERY=10 -r
	$(PYTHON) tools/cmptrace.py $(BUILD)/emu_trace.txt $(BUILD)/rtl_trace.txt

PPM2PNG_SIM = cd sim/out && for f in *.ppm; do [ -f "$$f" ] && $(MAGICK) $$f $${f%.ppm}.png && rm $$f; done; true
