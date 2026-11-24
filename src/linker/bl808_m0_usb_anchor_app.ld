/* Fixed-address cooperative application loaded by the resident M0 anchor. */
ENTRY(anchor_app_init)
INCLUDE src/linker/bl808_usb_anchor_stack.ld

PROVIDE(_sstack = __usb_anchor_stack_start);
PROVIDE(_estack = __usb_anchor_stack_end);

MEMORY
{
    APP (rwx) : ORIGIN = 0x22030000, LENGTH = 112K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.anchor_app_init))
        KEEP(*(.text.anchor_app_poll))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > APP

    .data : ALIGN(4)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > APP

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > APP

    .heap (NOLOAD) : ALIGN(8)
    {
        _sheap = .;
        . = ORIGIN(APP) + LENGTH(APP);
        _eheap = .;
    } > APP

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

ASSERT(_ebss <= ORIGIN(APP) + LENGTH(APP), "USB anchor app exceeds WRAM slot")
ASSERT(_eheap >= _sheap, "USB anchor app has no WRAM heap")
