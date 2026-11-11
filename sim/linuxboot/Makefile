CROSS ?= riscv32-none-elf-
stub_rom.txt: stub.S
	$(CROSS)gcc -march=rv32i -mabi=ilp32 -nostdlib -Ttext=0 stub.S -o stub.elf
	$(CROSS)objcopy -O binary stub.elf stub.bin
	python3 ../../tools/bin2words.py stub.bin stub_rom.txt
