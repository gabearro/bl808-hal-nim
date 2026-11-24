ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M }
SECTIONS
{
  .init : ALIGN(4) { KEEP(*(.init)) } > RAM
  .text : ALIGN(4) { *(.text .text.*) *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  .data : ALIGN(16) {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss (NOLOAD) : ALIGN(16) {
    _sbss = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(4); _ebss = .;
  } > RAM
  .heap (NOLOAD) : ALIGN(16) { _sheap = .; . += 256K; _eheap = .; } > RAM
  .stack (NOLOAD) : ALIGN(16) { _sstack = .; . += 32K; _estack = .; } > RAM
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
ASSERT(_estack < ORIGIN(RAM) + LENGTH(RAM), "D0 JIT QEMU RAM overflow")
