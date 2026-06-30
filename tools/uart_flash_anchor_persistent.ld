ENTRY(_start)

MEMORY
{
    XIP (rx) : ORIGIN = 0x58000000, LENGTH = 64K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > XIP

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
