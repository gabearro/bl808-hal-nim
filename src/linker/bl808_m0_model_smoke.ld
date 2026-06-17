/*
 * BL808 M0 (E907) linker script for stack-heavy NPU model validation images.
 *
 * The model smoke test carries many typed fixture records at once so it can
 * validate oracle, workspace, configured-live, and output evidence in one run.
 * Keep normal M0 firmware on bl808_m0.ld; this script uses WRAM for the stack
 * and test scratch for that validation image only.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
    WRAM  (rwx) : ORIGIN = 0x62030000, LENGTH = 160K
}

_stack_size = 60K;
_stack_top_reserve = 512;

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

    .jtaglog (NOLOAD) : ALIGN(4)
    {
        *(.jtaglog .jtaglog.*)
        . = ALIGN(4);
    } > WRAM

    .npuworkspace (NOLOAD) : ALIGN(16)
    {
        *(.npuworkspace .npuworkspace.*)
        . = ALIGN(16);
    } > WRAM

    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(16)
    {
        . = ORIGIN(WRAM) + LENGTH(WRAM) - _stack_top_reserve - _stack_size;
        . = ALIGN(16);
        _sstack = .;
        . = ORIGIN(WRAM) + LENGTH(WRAM) - _stack_top_reserve;
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > WRAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

ASSERT(_eheap >= _sheap, "M0 model-smoke RAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(WRAM) + LENGTH(WRAM) - _stack_top_reserve - _stack_size,
       "M0 model-smoke stack is not placed at top of WRAM")
ASSERT(_sstack >= ADDR(.npuworkspace) + SIZEOF(.npuworkspace),
       "M0 model-smoke WRAM stack overlaps NPU workspace")
