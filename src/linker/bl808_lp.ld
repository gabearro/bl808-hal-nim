/*
 * BL808 LP (E902) linker script
 *
 * The LP core shares MCU subsystem RAM with M0.
 * We allocate the upper portion of WRAM for LP.
 *
 * WRAM total: 160 KB at 0x62030000 (cached)
 * LP allocation: upper 16 KB (0x62054000 - 0x62058000)
 *
 * LP firmware can be XIP from flash or loaded into RAM by M0.
 */

ENTRY(_start)

MEMORY
{
    /* LP code in flash after M0 firmware */
    FLASH (rx)  : ORIGIN = 0x58080000, LENGTH = 512K
    /* LP gets the upper 16 KB of WRAM. */
    RAM   (rwx) : ORIGIN = 0x62054000, LENGTH = 16K
}

_stack_size = 2K;

SECTIONS
{
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

    _sidata = LOADADDR(.data);

    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

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

ASSERT(_eheap >= _sheap, "LP RAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "LP stack is not placed at top of RAM")
