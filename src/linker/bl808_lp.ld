/*
 * BL808 LP (E902) linker script
 *
 * The LP core shares MCU subsystem RAM with M0.
 * We allocate the upper 16 KB of WRAM for LP, accessed through the NON-CACHED
 * window at 0x22054000 (WRAM total: 160 KB, non-cached base 0x22030000).
 *
 * CACHE-ALIAS HAZARD (why non-cached matters): the CACHED WRAM window folds onto
 * M0's cached OCRAM. Per bl808_m0.ld, cached WRAM 0x6205xxxx aliases cached OCRAM
 * 0x6202xxxx (delta -0x30000) because the OCRAM cache only decodes a 64 KB range.
 * An earlier LP linker placed LP RAM at CACHED 0x62054000; LP's stack writes and
 * M0's WiFi-fw OCRAM writes then hit the SAME cache lines, corrupting whichever
 * core touched them second -> the all-core boot fault at the smoke->WiFi handoff.
 * WRAM and OCRAM are DISTINCT physical memories; only the cached window aliased
 * them. Accessing LP RAM through the NON-CACHED window (0x22054000, direct AHB)
 * removes the fold entirely. Note the LP boot gate (0x22050000..0x22053fff) is
 * already non-cached, confirming the E902 uses this window fine.
 *
 * LP firmware .text is XIP from flash; only data/bss/heap/stack live in RAM.
 */

ENTRY(_start)

MEMORY
{
    /* LP code in flash after M0 firmware */
    FLASH   (rx)  : ORIGIN = 0x58080000, LENGTH = 512K
    /* LP gets the upper 16 KB of WRAM via the NON-CACHED window (no OCRAM
     * cache-alias). Physically the same cells as cached 0x62054000, but the
     * direct-AHB path does not fold onto M0's OCRAM. */
    RAM     (rwx) : ORIGIN = 0x22054000, LENGTH = 16K
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

    /* RAM-resident routines that must keep running after enclave TZC lock. */
    _siramfunc = LOADADDR(.ramfunc);

    .ramfunc : ALIGN(4)
    {
        _sramfunc = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(4);
        _eramfunc = .;
    } > RAM AT > FLASH

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
/* LP RAM must stay in the NON-CACHED WRAM window (0x22030000..0x22058000). The
 * CACHED window (0x6203xxxx/0x6205xxxx) folds onto M0 OCRAM and corrupts the
 * boot handoff (see the header comment). Keeping LP non-cached is the fix. */
ASSERT(ORIGIN(RAM) >= 0x22030000 && ORIGIN(RAM) + LENGTH(RAM) <= 0x22058000,
       "LP RAM must be in the non-cached WRAM window (0x22030000..0x22058000)")
