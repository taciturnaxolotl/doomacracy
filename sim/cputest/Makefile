CROSS ?= riscv32-none-elf-
torture.hex: torture.c link.ld
	$(CROSS)gcc -march=rv32im -mabi=ilp32 -O2 -nostdlib -ffreestanding -T link.ld torture.c -lgcc -o torture.elf
	$(CROSS)objcopy -O binary torture.elf torture.bin
	python3 ../../tools/bin2words.py torture.bin torture.hex
	cc -DHOST -O1 torture.c -o torture_host && ./torture_host > expected.txt
