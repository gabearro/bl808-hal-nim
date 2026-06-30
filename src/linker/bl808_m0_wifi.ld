/*
 * BL808 M0 (E907) linker script for WiFi firmware builds.
 *
 * The Bouffalo WiFi firmware has two linker requirements that the small
 * generic M0 script does not satisfy:
 *   - .wifi.cfg.entry must be retained and exposed through
 *     _ld_bl_static_cfg_entry_start/end.
 *   - the shared WiFi/IPCMAC descriptor BSS must live in the uncached OCRAM
 *     alias so the MAC/DMA side sees coherent buffers.
 */

ENTRY(_start)

MEMORY
{
    FLASH    (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM      (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
    WIFI_RAM (rw)  : ORIGIN = 0x22030000, LENGTH = 144K
}

_stack_size = 8K;

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

	    .wifibss (NOLOAD) : ALIGN(16)
	    {
	        PROVIDE(__wifi_bss_start = .);
	        *ipc_shared.o(COMMON)
        *sdu_shared.o(COMMON)
        *hal_desc.o(COMMON)
        *txl_buffer_shared.o(COMMON)
        *txl_frame_shared.o(COMMON)
        *scan_shared.o(COMMON)
        *scanu_shared.o(COMMON)
        *mfp_bip.o(COMMON)
        *me_mic.o(COMMON)
        *bl_sta_mgmt_others.o(COMMON)
        *bl_pmk_mgmt.o(COMMON)
        *bl_pmk_mgmt_internal.o(COMMON)
	        *libwifi_drv.a:bl_utils.o(COMMON)
	        *libwifi_drv.a:bl_utils.o(.bss*)
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.0_hd))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.1_pd))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.2_sw))
	        . = ALIGN(16);
	        KEEP(*(.wifibss.rx_dma.3_buf))
	        . = ALIGN(16);
	        *swifi_fw.nim.c.o(COMMON)
	        *swifi_fw.nim.c.o(.bss*)
	        *(.wifi_ram*)
	        *(.wifibss .wifibss.*)
	        . = ALIGN(16);
	        PROVIDE(__wifi_bss_end = .);
	    } > WIFI_RAM

    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
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

ASSERT(_eheap >= _sheap, "M0 WiFi RAM overflow: no space left for heap")
ASSERT(__wifi_bss_end <= ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM),
       "M0 WiFi shared RAM overflow")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 WiFi stack is not placed at top of RAM")
