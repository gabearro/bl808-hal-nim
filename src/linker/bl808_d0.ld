/*
 * BL808 D0 (C906) linker script
 *
 * D0 firmware is loaded into DRAM at 0x3EF80000 by the M0 bootloader.
 * RAM: DRAM 512 KB + VRAM 32 KB = 544 KB, plus 64 MB pSRAM.
 *
 * For XIP execution: flash remap at 0xD8000000 + D0 boot offset.
 * For RAM execution: M0 copies D0 firmware to DRAM and jumps.
 *
 * This script targets RAM execution in DRAM (typical for D0 lowload).
 */

ENTRY(_start)

MEMORY
{
    /* D0 firmware loaded at DRAM base + offset for D0 lowload */
    DRAM  (rwx) : ORIGIN = 0x3EF80000, LENGTH = 512K
    VRAM  (rwx) : ORIGIN = 0x3F000000, LENGTH = 32K
    PSRAM (rwx) : ORIGIN = 0x50000000, LENGTH = 64M
}

_stack_size = 8K;

SECTIONS
{
    .init : ALIGN(4)
    {
        KEEP(*(.init))
    } > DRAM

    .text : ALIGN(4)
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > DRAM

    _sidata = LOADADDR(.data);

    .data : ALIGN(8)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        _edata = .;
    } > DRAM

    .bss (NOLOAD) : ALIGN(8)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        _ebss = .;
    } > DRAM

    .stack (NOLOAD) : ALIGN(16)
    {
        . = . + _stack_size;
        . = ALIGN(16);
        _sp = .;
    } > DRAM

    .heap (NOLOAD) : ALIGN(8)
    {
        _sheap = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM) - _stack_size;
        _eheap = .;
    } > DRAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}
