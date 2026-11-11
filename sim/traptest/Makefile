CROSS ?= riscv32-none-elf-
CFLAGS := -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O1 -nostdlib -ffreestanding -fno-builtin -Wall
traptest.bin: start.S traptest.c link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld start.S traptest.c -o traptest.elf
	$(CROSS)objcopy -O binary traptest.elf traptest.bin

reboot.bin: reboot.S link.ld
	$(CROSS)gcc -march=rv32i -mabi=ilp32 -nostdlib -T link.ld reboot.S -o reboot.elf
	$(CROSS)objcopy -O binary reboot.elf reboot.bin
