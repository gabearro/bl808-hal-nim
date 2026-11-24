ENTRY(_start)
__qemu_lp_stack_bytes = DEFINED(__qemu_lp_stack_override) ? __qemu_lp_stack_override : 4096;
__qemu_lp_ram_bytes = DEFINED(__qemu_lp_ram_override) ? __qemu_lp_ram_override : 16384;
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M }
SECTIONS
{
  .init : ALIGN(4) { KEEP(*(.init)) } > RAM
  .text : ALIGN(4) { *(.text .text.*) *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  .data : ALIGN(16) {
    _sdata = .;
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss (NOLOAD) : ALIGN(16) {
    _sbss = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
    . = ALIGN(4); _ebss = .;
  } > RAM
  .heap (NOLOAD) : ALIGN(16) {
    _sheap = .;
    . += __qemu_lp_ram_bytes - __qemu_lp_stack_bytes - (_sheap - _sdata) - 16;
    _eheap = .;
  } > RAM
  .stack (NOLOAD) : ALIGN(16) { _sstack = .; . += __qemu_lp_stack_bytes; _estack = .; } > RAM
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
ASSERT(_estack < ORIGIN(RAM) + LENGTH(RAM), "QEMU test RAM overflow")
ASSERT(_estack - _sdata <= __qemu_lp_ram_bytes, "LP writable budget overflow")
