/*
 * BL808 M0 (E907) SRAM-PUF capture linker script.
 *
 * To capture OCRAM's pristine power-up fingerprint, NOTHING the firmware does
 * may touch OCRAM (0x2202_0000): code runs from flash XIP, and all .data/.bss/
 * .heap/.stack live in WRAM (0x2203_0000, which the BootROM also avoids). The
 * startup bss-zero only covers WRAM, so OCRAM is read back exactly as it
 * powered up.
 *
 * WRAM is addressed uncached here to avoid any cache-alias interaction with the
 * OCRAM window during the capture.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x22030000, LENGTH = 128K   /* WRAM (uncached) */
}

_stack_size = 8K;
_stack_top_reserve = 512;

SECTIONS
{
    .init : ALIGN(4) { KEEP(*(.init)) } > FLASH

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

ASSERT(_eheap >= _sheap, "M0 PUF RAM overflow")
