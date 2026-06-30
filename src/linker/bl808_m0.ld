/*
 * BL808 M0 (E907) linker script
 *
 * M0 boots from flash XIP at 0x58000000, with RAM at 0x62020000 (cached).
 * Flash: 16 MB SPI NOR (Ox64)
 * RAM:   the cached flash-XIP image uses the 64 KB OCRAM window starting at
 *        0x62020000.  Do not model WRAM aliases as contiguous with this
 *        window: hardware traces show addresses such as 0x62053xxx can alias
 *        back over OCRAM state at 0x62023xxx and corrupt the live stack.
 *
 * Stack is placed near the top of this OCRAM window.
 */

ENTRY(_start)

MEMORY
{
    FLASH   (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAMFUNC (rwx) : ORIGIN = 0x22030000, LENGTH = 8K
    RAM     (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
}

_stack_size = 8K;
_stack_top_reserve = 512;

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

    /* RAM-resident routines that must run while flash XIP is unavailable. */
    _siramfunc = LOADADDR(.ramfunc);

    .ramfunc : ALIGN(4)
    {
        _sramfunc = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(4);
        _eramfunc = .;
    } > RAMFUNC AT > FLASH

    .sddma (NOLOAD) : ALIGN(32)
    {
        _ssddma = .;
        *(.sddma .sddma.*)
        . = ALIGN(32);
        _esddma = .;
    } > RAMFUNC

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
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

    /* Stack near top of RAM, growing down below a small hardware/ROM scratch margin. */
    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve;
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
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size,
       "M0 stack is not placed at top of RAM")
ASSERT(_esddma <= ORIGIN(RAMFUNC) + LENGTH(RAMFUNC),
       "M0 SD DMA buffers overflow RAMFUNC/WRAM")
