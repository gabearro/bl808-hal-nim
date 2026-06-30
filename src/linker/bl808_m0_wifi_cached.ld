/*
 * BL808 M0 WiFi diagnostic linker script.
 *
 * Keeps Bouffalo .wifi.cfg.entry records, but leaves WiFi COMMON/BSS in the
 * normal cached M0 RAM window. This isolates config-table retention from the
 * uncached shared-BSS placement used by bl808_m0_wifi.ld.
 */

ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x62020000, LENGTH = 208K
}

_stack_size = 4K;

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
        _bl_static_fw_cfg_entry_start = .;
        KEEP(*(.wifi.cfg.entry))
        _bl_static_fw_cfg_entry_end = .;

        . = ALIGN(4);
    } > FLASH

    PROVIDE(_ld_bl_static_cfg_entry_start = _bl_static_fw_cfg_entry_start);
    PROVIDE(_ld_bl_static_cfg_entry_end = _bl_static_fw_cfg_entry_end);
    PROVIDE(__wifi_bss_start = 0);
    PROVIDE(__wifi_bss_end = 0);

    _sidata = LOADADDR(.data);

    .data : ALIGN(4)
    {
        _sdata = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(4);
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

	    .bss (NOLOAD) : ALIGN(4)
	    {
	        _sbss = .;
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.0_hd))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.1_pd))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.2_sw))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.3_buf))
	        . = ALIGN(16);
	        *(.wifibss .wifibss.*)
	        *(.ram_wifi_ctrl*)
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

ASSERT(_eheap >= _sheap, "M0 WiFi cached RAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 WiFi cached stack is not placed at top of RAM")
