CROSS ?= riscv32-none-elf-
soctest_rom.txt: soctest.c crt0.S link.ld
	$(CROSS)gcc -march=rv32im -mabi=ilp32 -Os -nostdlib -ffreestanding -T link.ld crt0.S soctest.c -lgcc -o soctest.elf
	$(CROSS)objcopy -O binary soctest.elf soctest.bin
	python3 ../../tools/bin2words.py soctest.bin soctest_rom.txt
	python3 -c "open('flash_test.hex','w').write(''.join('%02x\n' % b for b in bytes(range(16)) * 4))"
