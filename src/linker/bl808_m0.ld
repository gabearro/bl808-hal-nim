/*
 * BL808 M0 (E907) linker script
 *
 * M0 boots from flash XIP at 0x58000000, with RAM at 0x62020000 (cached).
 * Flash: 16 MB SPI NOR (Ox64)
 * RAM:   OCRAM 64 KB + WRAM 160 KB = 224 KB total
 *
 * Stack is placed at the top of WRAM.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x62020000, LENGTH = 224K
}

_stack_size = 4K;

SECTIONS
{
    /* Code in flash (XIP) */
    .init : ALIGN(4)
    {
        KEEP(*(.init))
    } > FLASH

    .text : ALIGN(4)
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > FLASH

    /* Initialized data: stored in flash, copied to RAM at startup */
    _sidata = LOADADDR(.data);

    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

    /* Uninitialized data (BSS): zeroed at startup */
    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /* Stack at top of RAM */
    .stack (NOLOAD) : ALIGN(16)
    {
        . = . + _stack_size;
        . = ALIGN(16);
        _sp = .;
    } > RAM

    /* Heap fills remaining RAM */
    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        _eheap = .;
    } > RAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}
