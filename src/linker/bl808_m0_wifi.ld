/*
 * BL808 M0 (E907) linker script for WiFi firmware builds.
 *
 * The Bouffalo WiFi firmware has two linker requirements that the small
 * generic M0 script does not satisfy:
 *   - .wifi.cfg.entry must be retained and exposed through
 *     _ld_bl_static_cfg_entry_start/end.
 *   - the shared WiFi/IPCMAC descriptor BSS must live in uncached WRAM so
 *     the MAC/DMA side sees coherent buffers. Cached 0x6203xxxx is an alias
 *     of this same physical WRAM, not an extension of cached OCRAM.
 */

ENTRY(_start)

MEMORY
{
    FLASH    (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM      (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
    WIFI_RAM (rw)  : ORIGIN = 0x22030000, LENGTH = 115K
    /* D0 SDH ADMA bounce window. Must match ORIGIN(D0_SDH_DMA) in
     * bl808_m0_allcore_http.ld and __d0_sdh_adma_desc in bl808_d0*.ld
     * (0x2204CC00); sized for D0's desc + 4K data (0x1020 bytes). */
    D0_SDH_DMA (rw): ORIGIN = 0x2204CC00, LENGTH = 8K
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
ASSERT(ORIGIN(RAM) == 0x62020000 && LENGTH(RAM) <= 64K,
       "M0 WiFi cached OCRAM must stay within its physical 64 KB")
ASSERT(ORIGIN(RAM) - 0x40000000 + LENGTH(RAM) <= ORIGIN(WIFI_RAM),
       "M0 WiFi cached RAM aliases uncached WiFi WRAM")
ASSERT(__wifi_bss_end <= ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM),
       "M0 WiFi shared RAM overflow")
ASSERT(ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM) <= ORIGIN(D0_SDH_DMA),
       "M0 WiFi shared RAM overlaps D0 SDH DMA window")
ASSERT(ORIGIN(D0_SDH_DMA) == 0x2204CC00 && LENGTH(D0_SDH_DMA) == 8K &&
       ORIGIN(D0_SDH_DMA) + LENGTH(D0_SDH_DMA) <= 0x22050000,
       "M0 WiFi D0 SDH DMA reservation changed or overlaps LP boot gate")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 WiFi stack is not placed at top of RAM")
