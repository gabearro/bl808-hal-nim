/* JTAG-loaded RF SRAM capture. Keep all M0 code and state above the
 * 0x22028000..0x22030000 dump destination. No LP RAM image may coexist. */
ENTRY(_start)

MEMORY
{
    CSI (rw)  : ORIGIN = 0x22028000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x22030000, LENGTH = 160K
}

_stack_size = 8K;
_stack_top_reserve = 512;
PROVIDE(__csi_capture_start = ORIGIN(CSI));
PROVIDE(__csi_capture_end = ORIGIN(CSI) + LENGTH(CSI));

SECTIONS
{
    .init : ALIGN(4) { KEEP(*(.init)) } > RAM
    .text : ALIGN(4)
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > RAM

    _sidata = LOADADDR(.data);
    .data : ALIGN(4)
    {
        _sdata = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(4);
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.ram_wifi_ctrl .ram_wifi_ctrl.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(.wifibss .wifibss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve;
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > RAM

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}

ASSERT(_eheap >= _sheap, "M0 CSI RAM image has no heap")
ASSERT(ORIGIN(CSI) + LENGTH(CSI) <= ORIGIN(RAM), "CSI buffer overlaps M0 image")
