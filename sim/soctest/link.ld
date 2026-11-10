ENTRY(_start)
MEMORY { ROM (rx) : ORIGIN = 0, LENGTH = 4K
         RAM (rw) : ORIGIN = 0x10000000, LENGTH = 64K }
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) . = ALIGN(4); } > ROM
  .data : { _data_start = .; *(.data*) *(.sdata*) . = ALIGN(4); _data_end = .; } > RAM AT > ROM
  _data_load = LOADADDR(.data);
  .bss : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
}
