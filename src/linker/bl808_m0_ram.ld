/*
 * BL808 M0 (E907) RAM linker script for JTAG load/run.
 *
 * This image is not a bootable flash image. OpenOCD loads it directly into
 * MCU OCRAM/WRAM and resumes at _start, which lets hardware validation avoid
 * UART boot mode for RAM-resident tests.
 */

ENTRY(_start)

MEMORY
{
    /*
     * Leave the top 32 KB of WRAM (0x22050000-0x22058000) free for LP
     * JTAG RAM images. M0 keeps OCRAM plus the lower 192 KB of WRAM.
     */
    RAM (rwx) : ORIGIN = 0x22020000, LENGTH = 192K
}

PHDRS
{
    text PT_LOAD FLAGS(5); /* R + X */
    data PT_LOAD FLAGS(6); /* R + W */
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
