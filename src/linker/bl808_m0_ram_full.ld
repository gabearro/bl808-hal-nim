/*
 * BL808 M0 (E907) full RAM linker script for isolated JTAG load/run.
 *
 * This variant uses the full MCU OCRAM/WRAM window and must not be used for
 * tests that also place an LP RAM image in upper WRAM.
 */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x22020000, LENGTH = 224K
}

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

_stack_size = 4K;

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

    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM :data

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM :data

    .heap (NOLOAD) : ALIGN(4)
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

ASSERT(_eheap >= _sheap, "M0 RAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 stack is not placed at top of RAM")
