/* Isolated M0 proof-verification RAM test. Reserves a 32 KiB stack.
 * Do not combine with an LP image occupying upper WRAM. */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x22020000, LENGTH = 224K }
PHDRS { text PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
_stack_size = 32K;
SECTIONS
{
  .init : ALIGN(4) { KEEP(*(.init)) } > RAM :text
  .text : ALIGN(4) {
    *(.text .text.*) *(.rodata .rodata.*) *(.srodata .srodata.*)
    . = ALIGN(4);
  } > RAM :text
  _sidata = LOADADDR(.data);
  .data : ALIGN(4) {
    _sdata = .; *(.data .data.*) *(.sdata .sdata.*)
    . = ALIGN(4); _edata = .;
  } > RAM :data
  .bss (NOLOAD) : ALIGN(4) {
    _sbss = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(4); _ebss = .;
  } > RAM :data
  .heap (NOLOAD) : ALIGN(16) {
    _sheap = .;
    . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
    _eheap = .;
  } > RAM :data
  .stack (NOLOAD) : ALIGN(16) {
    _sstack = .; . = ORIGIN(RAM) + LENGTH(RAM); _estack = .; _sp = .;
  } > RAM :data
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
ASSERT(_eheap >= _sheap + 16K, "proof test needs at least 16 KiB heap")
