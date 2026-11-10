ENTRY(_start)
SECTIONS {
  . = 0x10000000;
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) *(.data*) *(.sdata*) . = ALIGN(4); }
}
