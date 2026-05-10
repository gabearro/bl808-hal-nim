/*
 * BL808 M0 (E907) linker script
 *
 * M0 boots from flash XIP at 0x58000000, with RAM at 0x62020000 (cached).
 * Flash: 16 MB SPI NOR (Ox64)
 * RAM:   OCRAM 64 KB + WRAM 160 KB = 224 KB total.
 *        The upper 16 KB of WRAM is reserved for LP firmware when the E902
 *        core is used, so M0 owns 0x62020000 - 0x62054000.
 *
 * Stack is placed at the top of WRAM.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x62020000, LENGTH = 208K
}

_stack_size = 8K;

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

    /* Heap fills RAM up to the reserved top-of-RAM stack window */
    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

    /* Stack at top of RAM, growing down into its reserved window */
    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM);
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > RAM

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
