CROSS ?= riscv32-none-elf-
stream.hex: hello.c link.ld mkimage.py
	$(CROSS)gcc -march=rv32im -mabi=ilp32 -Os -nostdlib -ffreestanding -T link.ld hello.c -o hello.elf
	$(CROSS)objcopy -O binary hello.elf hello.bin
	python3 mkimage.py
	python3 ../../tools/jtag_stream.py image.bin stream.bin stream.hex
