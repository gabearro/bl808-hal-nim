/*
 * BL808 D0 (C906) RAM linker script for JTAG load/run.
 *
 * Low D0 DRAM at 0x3EF80000 is not reliable for OpenOCD memory writes on the
 * current Ox64 JTAG path. The top 64 KB of D0 DRAM does retain D0 JTAG writes,
 * so RAM-loaded validation images live here and resume directly at _start.
 */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x3EFF0000, LENGTH = 64K
}

PHDRS
{
    text PT_LOAD FLAGS(5); /* R + X */
    data PT_LOAD FLAGS(6); /* R + W */
}

_stack_size = 8K;

SECTIONS
{
    .init : ALIGN(4)
    {
        KEEP(*(.init))
    } > RAM :text

    .text : ALIGN(4)
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > RAM :text

    _sidata = LOADADDR(.data);

    .data : ALIGN(8)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        _edata = .;
    } > RAM :data

    .bss (NOLOAD) : ALIGN(8)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        _ebss = .;
    } > RAM :data

    .heap (NOLOAD) : ALIGN(8)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM :data

    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM);
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > RAM :data

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

ASSERT(_eheap >= _sheap, "D0 JTAG RAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "D0 JTAG RAM stack is not placed at top of RAM")
