CROSS ?= riscv32-none-elf-
CFLAGS := -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O1 -nostdlib -ffreestanding -fno-builtin -Wall
ps2test.bin: ../traptest/start.S ps2test.c ../traptest/link.ld
	$(CROSS)gcc $(CFLAGS) -T ../traptest/link.ld ../traptest/start.S ps2test.c -o ps2test.elf
	$(CROSS)objcopy -O binary ps2test.elf ps2test.bin
