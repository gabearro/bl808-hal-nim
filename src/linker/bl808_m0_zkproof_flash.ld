/* Isolated M0 proof-gated loader test. Code executes from flash; the whole
 * 224 KiB M0 RAM/WRAM range is reserved for this image. No concurrent LP image. */
ENTRY(_start)
MEMORY {
  FLASH (rx) : ORIGIN = 0x58000000, LENGTH = 1M
  RAM (rwx) : ORIGIN = 0x62020000, LENGTH = 224K
}
_stack_size = 60K;
SECTIONS
{
  .init : ALIGN(4) { KEEP(*(.init)) } > FLASH
  .text : ALIGN(4) {
    *(.text .text.*) *(.rodata .rodata.*) *(.srodata .srodata.*)
    . = ALIGN(4);
  } > FLASH
  _sidata = LOADADDR(.data);
  .data : ALIGN(4) {
    _sdata = .; *(.ramfunc .ramfunc.*) *(.data .data.*) *(.sdata .sdata.*)
    . = ALIGN(4); _edata = .;
  } > RAM AT > FLASH
  .bss (NOLOAD) : ALIGN(4) {
    _sbss = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(4); _ebss = .;
  } > RAM
  .heap (NOLOAD) : ALIGN(16) {
    _sheap = .;
    . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
    _eheap = .;
  } > RAM
  .stack (NOLOAD) : ALIGN(16) {
    _sstack = .; . = ORIGIN(RAM) + LENGTH(RAM); _estack = .; _sp = .;
  } > RAM
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
ASSERT(_eheap >= _sheap + 32K, "proof loader test needs at least 32 KiB heap")
