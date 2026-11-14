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
#   make coremark      EEMBC CoreMark firmware (build/coremark-flash.bin)
#   make coremark-emu  run CoreMark in the emulator's cycle model
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

# ---------------------------------------------------------------- CoreMark

# EEMBC CoreMark as a second firmware (sw/coremark). The benchmark sources
# are not in this repo: the first build fetches them into
# third_party/coremark at a pinned commit, and they are compiled unchanged.
#
#   make coremark       build/coremark-flash.bin (load it like flash.bin)
#   make coremark-emu   run it in the emulator's cycle model of the RTL
#   make coremark-sim   a short run in the RTL simulation (see the RTL section)
#
# CM_ITER=N fixes the iteration count; 0 lets CoreMark pick one that runs for
# the 10 seconds a valid score needs. CM_OPT changes the optimisation flags.
CM        := third_party/coremark
CM_COMMIT := 1f483d5b8316753a742cbf5590caf5bd0a4e4777
CM_OPT    ?= -O2
CM_ITER   ?= 0
CM_TAG    := coremark$(if $(filter 0,$(CM_ITER)),,-i$(CM_ITER))
CM_B      := $(SWB)/$(CM_TAG)
CM_FLASH  := $(BUILD)/$(CM_TAG)-flash
CM_FLAGS  := $(RV_ARCH) $(CM_OPT) -mstrict-align -fno-pic
CM_CFLAGS := $(CM_FLAGS) -DFLAGS_STR='"$(CM_FLAGS)"' -DITERATIONS=$(CM_ITER) \
             -Isw/coremark -I$(CM) -Isw/include
CM_OBJS   := $(addprefix $(CM_B)/,core_main.o core_list_join.o core_matrix.o core_state.o \
               core_util.o core_portme.o syscalls.o crt0.o)

$(CM)/.pinned:
	@mkdir -p third_party
	[ -d $(CM)/.git ] || git clone -q https://github.com/eembc/coremark.git $(CM)
	git -C $(CM) checkout -q $(CM_COMMIT)
	@touch $@

$(CM_B)/core_portme.o $(CM_B)/syscalls.o: $(CM_B)/%.o: sw/coremark/%.c sw/coremark/core_portme.h \
    sw/include/doomacracy_hw.h $(CM)/.pinned
	@mkdir -p $(@D)
	$(CC_RV) $(CM_CFLAGS) -Wall -c $< -o $@

$(CM_B)/crt0.o: sw/doom/crt0.S
	@mkdir -p $(@D)
	$(CC_RV) $(RV_ARCH) -c $< -o $@

$(CM_B)/core_%.o: $(CM)/.pinned sw/coremark/core_portme.h
	@mkdir -p $(@D)
	$(CC_RV) $(CM_CFLAGS) -c $(CM)/core_$*.c -o $@

$(CM_B)/coremark.elf: $(CM_OBJS) sw/coremark/coremark.ld
	$(CC_RV) $(RV_ARCH) -nostartfiles -T sw/coremark/coremark.ld -Wl,--gc-sections \
	  -Wl,--no-warn-rwx-segments -Wl,-Map,$(CM_B)/coremark.map -o $@ $(CM_OBJS) -lm -lc -lgcc
	@$(SIZE) $@

$(CM_B)/coremark.bin: $(CM_B)/coremark.elf
	$(OBJCOPY) -O binary -j .text -j .init_array -j .rodata -j .data $< $@

$(CM_FLASH).bin: $(CM_B)/coremark.bin tools/mkflash.py
	@mkdir -p $(BUILD)
	$(PYTHON) tools/mkflash.py --firmware $< --wad /dev/null --load 0x10000000 \
	  --entry 0x10000000 --out $@ --hex $(CM_FLASH).hex

.PHONY: coremark coremark-emu
coremark: $(CM_FLASH).bin

# the cache sizes are the RTL's (512 lines each)
coremark-emu: boot emu $(CM_FLASH).bin
	$(BUILD)/emu --boot $(BUILD)/boot.bin --flash $(CM_FLASH).bin --timing \
	  --icache-bits 9 --dcache-bits 9 --quiet | tee $(BUILD)/$(CM_TAG)-emu.txt
	@awk '/^CoreMark 1.0/ { printf "\nCoreMark %.2f, %.3f CoreMark/MHz (emulator cycle model)\n", $$4, $$4 / 50; exit }' \
	  $(BUILD)/$(CM_TAG)-emu.txt

sw-clean:
	rm -rf $(SWB) $(BUILD)/boot.bin $(BUILD)/boot_rom_init.txt $(BUILD)/flash.bin \
	  $(BUILD)/flash.hex $(BUILD)/doom1-stripped.wad $(BUILD)/emu $(BUILD)/frames \
	  $(BUILD)/coremark*

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
# Quartus gets rtl/vjtag_port.vhd in place of the simulation stand-in
VJTAG := sim/vjtag_port_sim.vhd
NVCW  := $(NVC) --std=1993 --work=work:$(BUILD)/work -M 512m -H 1g
RTL   := $(VJTAG) rtl/boot_rom_data.vhd rtl/sdpram.vhd rtl/cpu.vhd rtl/icache.vhd rtl/dcache.vhd \
         rtl/membus.vhd rtl/boot_rom.vhd rtl/sram_ctrl.vhd rtl/sdram_ctrl.vhd rtl/flash_ctrl.vhd \
         rtl/io.vhd rtl/video.vhd rtl/uart.vhd rtl/ps2_rx.vhd rtl/jtag_console.vhd rtl/jtag_rx.vhd \
         rtl/doomacracy.vhd
QRTL  := $(RTL:sim/vjtag_port_sim.vhd=rtl/vjtag_port.vhd)
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
	    -gKEYS=$(SOCT)/keys.txt -gMAX_MS=300 -gDUMP_FIRST=2 -gDUMP_EVERY=1000 -r
	$(PPM2PNG_SIM)

soc-boot: rom sw emu
	@mkdir -p sim/out
	$(EMU_RUN) --trace $(BUILD)/emu_trace.txt --trace-count $(TRACE_N) --max-instr $(TRACE_N) --quiet
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=$(BUILD)/flash.hex \
	    -gTRACE=$(BUILD)/rtl_trace.txt -gTRACE_MAX=$(TRACE_N) -gMAX_MS=1000 -gDUMP_EVERY=10 -r
	$(PYTHON) tools/cmptrace.py $(BUILD)/emu_trace.txt $(BUILD)/rtl_trace.txt

# CoreMark in the RTL simulation. It runs only CM_SIM_ITER iterations, so
# CoreMark rejects the score as too short, but the cycle and instruction
# counts are the RTL's own. `make coremark-emu CM_ITER=<same>` gives the
# emulator's figures for the same binary.
CM_SIM_ITER ?= 10
.PHONY: coremark-sim coremark-sim-run
coremark-sim: rom
	$(MAKE) CM_ITER=$(CM_SIM_ITER) coremark-sim-run
coremark-sim-run: $(CM_FLASH).bin
	@mkdir -p sim/out
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=$(CM_FLASH).hex -gMAX_MS=3000 \
	    -gDUMP_EVERY=1000000 -r | grep -v '^\[tb\] [0-9]' | tee $(BUILD)/$(CM_TAG)-sim.txt

# JTAG loader end to end: flash holding something else (so the changed
# sector has to be erased), SW9 up, the stand-in JTAG port plays
# sim/jtagtest/stream.hex; the real boot ROM must program the flash and then
# boot the image it wrote, which prints "hello from flash".
.PHONY: jtag-test
jtag-test: rom
	$(MAKE) -C sim/jtagtest
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=sim/soctest/flash_test.hex -gSWITCHES=512 -gMAX_MS=60 -gDUMP_FIRST=100000 -r

# KEY0 in the middle of soctest's SDRAM test: the program must start over
# and pass, and the SDRAM chip model must see no protocol errors (rows left
# open across a reset broke refresh and corrupted data)
.PHONY: reset-test
reset-test:
	@mkdir -p sim/out
	$(MAKE) -C $(SOCT)
	$(PYTHON) tools/gen_rom.py $(SOCT)/soctest_rom.txt rtl/boot_rom_data.vhd
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=$(SOCT)/flash_test.hex -gKEY0_AT_US=4500 -gKEYS=$(SOCT)/keys.txt \
	    -gMAX_MS=320 -gDUMP_FIRST=100000 -r > $(BUILD)/reset_test.log 2>&1 || true
	@if grep -q "SDRAM .*\(violated\|bank\)" $(BUILD)/reset_test.log; then \
	    grep -m3 "SDRAM" $(BUILD)/reset_test.log; echo "reset-test: SDRAM protocol errors"; exit 1; fi
	@grep -q "^PASS" $(BUILD)/reset_test.log || { tail -5 $(BUILD)/reset_test.log; echo "reset-test: no PASS"; exit 1; }
	@echo "reset-test: board restarted cleanly after KEY0"

PPM2PNG_SIM = cd sim/out && for f in *.ppm; do [ -f "$$f" ] && $(MAGICK) $$f $${f%.ppm}.png && rm $$f; done; true

# Quartus archive: everything flat in one folder, the way the lab's projects
# are. Builds the real boot ROM first so the archive never carries a test one.
QAR_FILES := doomacracy.qpf doomacracy.qsf doomacracy.sdc $(notdir $(QRTL)) jtag_flash.tcl jtag_console.tcl flash.bin linux-flash.bin
.PHONY: qar
qar: rom $(BUILD)/flash.bin $(BUILD)/linux-flash.bin
	@rm -rf $(BUILD)/qar && mkdir -p $(BUILD)/qar
	cp quartus/doomacracy.qpf quartus/doomacracy.sdc $(QRTL) tools/jtag_flash.tcl tools/jtag_console.tcl $(BUILD)/flash.bin $(BUILD)/linux-flash.bin $(BUILD)/qar/
	sed 's|\.\./rtl/||' quartus/doomacracy.qsf > $(BUILD)/qar/doomacracy.qsf
	$(PYTHON) tools/qar.py pack $(BUILD)/doomacracy.qar $(BUILD)/qar $(QAR_FILES)

# ---------------------------------------------------------------- Linux platform
#
#   make trap-test     sim/traptest (CSRs, traps, U-mode, AMOs, fence.i,
#                      CLINT timer, 16550) in the emulator and in nvc: the
#                      console output must be identical and the traces agree
#   make linux-sim     boot LINUX_IMAGE in nvc from preloaded SDRAM, console
#                      over the simulated JTAG, trace compared with the emulator
#   make reboot-test   syscon reboot then power off, in nvc
#   make console-dry   tools/jtag_console.tcl against its fake board (tclsh)
#
# Both simulations use sim/linuxboot as the boot ROM (a0 = 0, a1 = DTB, jump
# to 0x80000000, like emu --kernel) and a device tree for 8 MB, made with
# dtc (nix shell nixpkgs#dtc). Run `make rom` before Quartus.

# the device tree for the DE1's 8 MB, at 8 MB - 16 KB; LINUX_MS is simulated time
RTL_DTB    := $(BUILD)/rtl-8mb.dtb
DTB_AT     := 8372224
LINUX_MS   ?= 300
LINUX_TRACE_N ?= 3000000
# typed into the trap test's console after "ok": longer than the RX FIFO
TRAP_LINE  := Thequickbrownfoxjumpsoverthelazydog0123456789
SIM_UART   = grep -v '^\[tb\]\|^\[jtag\]\|^\*\*\|^   ' $(1)
SIM_JTAG   = sed -n 's/^\[jtag\] //p' $(1)

.PHONY: trap-test linux-sim console-dry linuxboot-rom reboot-test
$(RTL_DTB): tools/gen_dts.py
	@mkdir -p $(BUILD)
	$(PYTHON) tools/gen_dts.py 8 > $(BUILD)/rtl-8mb.dts
	dtc -q -I dts -O dtb -o $@ $(BUILD)/rtl-8mb.dts

linuxboot-rom:
	$(MAKE) -C sim/linuxboot
	$(PYTHON) tools/gen_rom.py sim/linuxboot/stub_rom.txt rtl/boot_rom_data.vhd

# PS/2 bytes through the PLIC as interrupts: the emulator and the RTL must
# print the same bytes
.PHONY: ps2-test
ps2-test: emu linuxboot-rom $(RTL_DTB)
	@mkdir -p sim/out
	$(MAKE) -C sim/ps2test
	$(BUILD)/emu --kernel sim/ps2test/ps2test.bin --dtb $(RTL_DTB) --sdram-mb 8 --keys sim/ps2test/keys.txt \
	    --quiet < /dev/null 2>/dev/null > $(BUILD)/ps2_emu_out.txt
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=none -gSDRAM_IMG0=sim/ps2test/ps2test.bin \
	    -gSDRAM_IMG1=$(RTL_DTB) -gSDRAM_IMG1_AT=$(DTB_AT) -gKEYS=sim/ps2test/keys.txt \
	    -gMAX_MS=120 -gDUMP_FIRST=100000 -r > $(BUILD)/ps2_rtl_log.txt
	$(call SIM_UART,$(BUILD)/ps2_rtl_log.txt) > $(BUILD)/ps2_rtl_uart.txt
	diff $(BUILD)/ps2_emu_out.txt $(BUILD)/ps2_rtl_uart.txt && echo "ps2-test: RTL matches the emulator"

trap-test: emu linuxboot-rom $(RTL_DTB)
	@mkdir -p sim/out
	$(MAKE) -C sim/traptest
	printf 'ok\r$(TRAP_LINE)\r' | $(BUILD)/emu --kernel sim/traptest/traptest.bin --dtb $(RTL_DTB) --sdram-mb 8 \
	    --trace $(BUILD)/trap_emu_trace.txt --trace-count 10000000 --quiet > $(BUILD)/trap_emu_out.txt
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=none -gSDRAM_IMG0=sim/traptest/traptest.bin \
	    -gSDRAM_IMG1=$(RTL_DTB) -gSDRAM_IMG1_AT=$(DTB_AT) -gCON_POLL_US=20 -gCON_IN=ok~$(TRAP_LINE)~ \
	    -gTRACE=$(BUILD)/trap_rtl_trace.txt -gTRACE_MAX=10000000 -gMAX_MS=40 -gDUMP_FIRST=100000 \
	    -r > $(BUILD)/trap_rtl_log.txt
	$(call SIM_UART,$(BUILD)/trap_rtl_log.txt) > $(BUILD)/trap_rtl_uart.txt
	$(call SIM_JTAG,$(BUILD)/trap_rtl_log.txt) > $(BUILD)/trap_rtl_jtag.txt
	diff $(BUILD)/trap_emu_out.txt $(BUILD)/trap_rtl_uart.txt && echo "trap-test: RS-232 output matches the emulator"
	diff $(BUILD)/trap_emu_out.txt $(BUILD)/trap_rtl_jtag.txt && echo "trap-test: JTAG console output matches the emulator"
	@# the pipelined core spins thousands of times per character waiting on the
	@# real UART, so resyncs need a wide window
	$(PYTHON) tools/cmptrace.py $(BUILD)/trap_emu_trace.txt $(BUILD)/trap_rtl_trace.txt --window 100000 --quiet

linux-sim: emu linuxboot-rom $(RTL_DTB)
	@mkdir -p sim/out
	$(BUILD)/emu --kernel $(LINUX_IMAGE) --dtb $(RTL_DTB) --sdram-mb 8 --trace $(BUILD)/linux_emu_trace.txt \
	    --trace-count $(LINUX_TRACE_N) --max-instr $(LINUX_TRACE_N) --quiet < /dev/null > $(BUILD)/linux_emu_out.txt
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=none -gSDRAM_IMG0=$(LINUX_IMAGE) \
	    -gSDRAM_IMG1=$(RTL_DTB) -gSDRAM_IMG1_AT=$(DTB_AT) -gCON_POLL_US=5 \
	    -gTRACE=$(BUILD)/linux_rtl_trace.txt -gTRACE_MAX=$(LINUX_TRACE_N) -gMAX_MS=$(LINUX_MS) \
	    -gDUMP_FIRST=100000000 -r > $(BUILD)/linux_rtl_log.txt
	$(call SIM_UART,$(BUILD)/linux_rtl_log.txt) > $(BUILD)/linux_rtl_uart.txt
	$(call SIM_JTAG,$(BUILD)/linux_rtl_log.txt) > $(BUILD)/linux_rtl_jtag.txt
	@echo "--- console (RS-232 mirror) ---"; cat $(BUILD)/linux_rtl_uart.txt
	diff $(BUILD)/linux_rtl_uart.txt $(BUILD)/linux_rtl_jtag.txt && echo "linux-sim: JTAG console and RS-232 agree"
	@# whole lines the emulator printed in its LINUX_TRACE_N instructions, timestamps stripped
	tr -d '\r' < $(BUILD)/linux_emu_out.txt | sed 's/^\[ *[0-9.]*\] //' > $(BUILD)/linux_emu_text.txt
	sed 's/^\[ *[0-9.]*\] //' $(BUILD)/linux_rtl_uart.txt > $(BUILD)/linux_rtl_text.txt
	n=$$(wc -l < $(BUILD)/linux_emu_text.txt); \
	    head -n $$n $(BUILD)/linux_emu_text.txt > $(BUILD)/linux_emu_head.txt; \
	    head -n $$n $(BUILD)/linux_rtl_text.txt > $(BUILD)/linux_rtl_head.txt
	diff $(BUILD)/linux_emu_head.txt $(BUILD)/linux_rtl_head.txt \
	    && echo "linux-sim: console text matches the emulator (timestamps aside)"
	$(PYTHON) tools/cmptrace.py $(BUILD)/linux_emu_trace.txt $(BUILD)/linux_rtl_trace.txt --window 100000 --quiet

# syscon: a reboot (0x7777) resets the whole board and leaves SDRAM alone,
# a power off (0x5555) halts the CPU
reboot-test: linuxboot-rom $(RTL_DTB)
	$(MAKE) -C sim/traptest reboot.bin
	$(NVCW) -a $(RTL) $(SIM) -e tb_soc -gFLASH=none -gSDRAM_IMG0=sim/traptest/reboot.bin \
	    -gMAX_MS=10 -gDUMP_FIRST=100000 -r > $(BUILD)/reboot_log.txt
	$(call SIM_UART,$(BUILD)/reboot_log.txt) > $(BUILD)/reboot_out.txt
	printf 'boot 1\nboot 2\n' | diff - $(BUILD)/reboot_out.txt
	grep -q 'CPU halted' $(BUILD)/reboot_log.txt
	@echo "reboot-test: rebooted once, then powered off"

console-dry:
	printf 'Linux says hi\r\nsecond line\r\n' > $(BUILD)/console_fake.txt
	printf 'ls -l\nuname\n' | DOOMACRACY_JTAG_DRYRUN=$(BUILD)/console_dry.txt \
	    DOOMACRACY_JTAG_FAKE_OUT=$(BUILD)/console_fake.txt tclsh tools/jtag_console.tcl > $(BUILD)/console_out.txt
	cmp $(BUILD)/console_fake.txt $(BUILD)/console_out.txt
	grep -q '^80 6e750d6c2d20736c0018$$' $(BUILD)/console_dry.txt
	grep -q '^80 000000000d656d610014$$' $(BUILD)/console_dry.txt
	@echo "console-dry: frames and output as expected"

# ======================================================================
# Linux (emulator only for now)
# ======================================================================
#   make linux-emu        boot LINUX_IMAGE in the emulator, console on this terminal
#   make linux-emu MB=64  more memory than the board has (emulator only)
LINUX_IMAGE ?= $(BUILD)/linux-Image
MB ?= 8
.PHONY: linux-emu
$(BUILD)/doomacracy-$(MB)mb.dtb: tools/gen_dts.py
	@mkdir -p $(BUILD)
	$(PYTHON) tools/gen_dts.py $(MB) > $(BUILD)/doomacracy-$(MB)mb.dts
	dtc -q -I dts -O dtb -o $@ $(BUILD)/doomacracy-$(MB)mb.dts
linux-emu: emu $(BUILD)/doomacracy-$(MB)mb.dtb
	$(BUILD)/emu --kernel $(LINUX_IMAGE) --dtb $(BUILD)/doomacracy-$(MB)mb.dtb --sdram-mb $(MB)

# Linux flash image (kernel + device tree), written with jtag_flash.tcl like flash.bin
$(BUILD)/linux-flash.bin: $(LINUX_IMAGE) $(BUILD)/doomacracy-8mb.dtb tools/mklinuxflash.py
	$(PYTHON) tools/mklinuxflash.py $(LINUX_IMAGE) $(BUILD)/doomacracy-8mb.dtb $@
.PHONY: linux-flash
linux-flash: $(BUILD)/linux-flash.bin

# ======================================================================
# Hardware reference manual (docs/book, LaTeX)
# ======================================================================
#   make book   build docs/book/doomacracy.pdf (needs latexmk and TeX Live)
.PHONY: book
book:
	cd docs/book && latexmk -pdf -interaction=nonstopmode -halt-on-error -output-directory=build main.tex
	cp docs/book/build/main.pdf docs/book/doomacracy.pdf
	@echo "-> docs/book/doomacracy.pdf"
