/* BL808 D0/C906 native XIP image at the 0x100000 flash slot.
 *
 * The C906 fetches this through the MM flash remap alias 0xD8000000. M0
 * verifies the first word through its own 0x58000000 alias before releasing
 * D0 at 0xD8100000. Writable state remains private in D0 DRAM. This layout
 * is an opt-in build/boot path until the Ox64 verifies concurrent XIP.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0xD8100000, LENGTH = 1M
    DRAM  (rwx) : ORIGIN = 0x3EF80000, LENGTH = 512K
}

_stack_size = DEFINED(__bl808_d0_stack_bytes) ? __bl808_d0_stack_bytes : 8K;

PROVIDE(__d0_sdh_adma_desc = 0x2204CC00);
PROVIDE(__d0_sdh_adma_data = 0x2204CC20);
PROVIDE(__d0_sdh_adma_data_len = 0x1000);

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
        . = ALIGN(8);
    } > FLASH

    _sidata = LOADADDR(.data);

    .data : ALIGN(8)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        _edata = .;
    } > DRAM AT > FLASH

    .bss (NOLOAD) : ALIGN(8)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        _ebss = .;
    } > DRAM

    .heap (NOLOAD) : ALIGN(8)
    {
        _sheap = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM) - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > DRAM

    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM);
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > DRAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

ASSERT(_sidata >= ORIGIN(FLASH) && _sidata + SIZEOF(.data) <= ORIGIN(FLASH) + LENGTH(FLASH),
       "D0 XIP load image exceeds flash slot")
ASSERT(_eheap >= _sheap, "D0 DRAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(DRAM) + LENGTH(DRAM) - _stack_size,
       "D0 stack is not placed at top of DRAM")
ASSERT(_stack_size >= 8K && _stack_size <= 64K && (_stack_size & 15) == 0,
       "D0 stack reservation is invalid")
