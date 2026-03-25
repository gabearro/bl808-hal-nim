/*
 * BL808 LP (E902) linker script
 *
 * The LP core shares MCU subsystem RAM with M0.
 * We allocate the upper portion of WRAM for LP.
 *
 * WRAM total: 160 KB at 0x62030000 (cached)
 * LP allocation: upper 32 KB (0x62054000 - 0x6205C000)
 *
 * LP firmware can be XIP from flash or loaded into RAM by M0.
 */

ENTRY(_start)

MEMORY
{
    /* LP code in flash after M0 firmware */
    FLASH (rx)  : ORIGIN = 0x58080000, LENGTH = 512K
    /* LP gets upper 32 KB of WRAM */
    RAM   (rwx) : ORIGIN = 0x62054000, LENGTH = 32K
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

    .stack (NOLOAD) : ALIGN(16)
    {
        . = . + _stack_size;
        . = ALIGN(16);
        _sp = .;
    } > RAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}
