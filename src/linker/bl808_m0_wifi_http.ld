/* Ox64 M0 WiFi HTTP profile. All addresses below are physical partitions:
 * cached OCRAM is 0x62020000..0x6202ffff; uncached WRAM is
 * 0x22030000..0x22057fff. Never extend OCRAM into the 0x6203xxxx WRAM
 * alias: it overlaps the WiFi DMA region at 0x2203xxxx.
 *
 * The HTTP/WASM manager uses the same isolated PSRAM windows as the
 * all-core HTTP image. Its example initializes PSRAM and clears .psrambss
 * before heapInit(). WiFi DMA/shared state remains in uncached WRAM.
 */

ENTRY(_start)

MEMORY
{
    FLASH       (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM         (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
    WIFI_RAM    (rw)  : ORIGIN = 0x22030000, LENGTH = 115K
    D0_SDH_DMA  (rw)  : ORIGIN = 0x2204CC00, LENGTH = 8K
    SD_DMA      (rw)  : ORIGIN = 0x2204EC00, LENGTH = 5K
    PSRAM_BSS   (rw)  : ORIGIN = 0x50100000, LENGTH = 64K
    HEAP_RAM    (rw)  : ORIGIN = 0x50120000, LENGTH = 64K
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

    .sddma (NOLOAD) : ALIGN(32)
    {
        __sddma_start = .;
        KEEP(*(.sddma .sddma.*))
        . = ALIGN(32);
        __sddma_end = .;
    } > SD_DMA

    .wifibss (NOLOAD) : ALIGN(16)
    {
        PROVIDE(__wifi_bss_start = .);
        *ipc_shared.o(COMMON .bss .bss.*)
        *sdu_shared.o(COMMON .bss .bss.*)
        *hal_desc.o(COMMON .bss .bss.*)
        *txl_buffer_shared.o(COMMON .bss .bss.*)
        *txl_frame_shared.o(COMMON .bss .bss.*)
        *scan_shared.o(COMMON .bss .bss.*)
        *scanu_shared.o(COMMON .bss .bss.*)
        *mfp_bip.o(COMMON .bss .bss.*)
        *me_mic.o(COMMON .bss .bss.*)
        *bl_sta_mgmt_others.o(COMMON .bss .bss.*)
        *bl_pmk_mgmt.o(COMMON .bss .bss.*)
        *bl_pmk_mgmt_internal.o(COMMON .bss .bss.*)
        *libwifi_drv.a:bl_utils.o(COMMON .bss .bss.*)
        . = ALIGN(16);
        KEEP(*(.wifibss.rx_dma.0_hd))
        . = ALIGN(16);
        KEEP(*(.wifibss.rx_dma.1_pd))
        . = ALIGN(16);
        KEEP(*(.wifibss.rx_dma.2_sw))
        . = ALIGN(16);
        KEEP(*(.wifibss.rx_dma.3_buf))
        . = ALIGN(16);
        *swifi_fw.nim.c.o(COMMON .bss .bss.*)
        *(.wifi_ram*)
        *(.wifibss .wifibss.*)
        . = ALIGN(16);
        PROVIDE(__wifi_bss_end = .);
    } > WIFI_RAM

    .psrambss (NOLOAD) : ALIGN(16)
    {
        __psram_bss_start = .;
        *swasm_scheduler.nim.c.o(COMMON .bss .bss.*)
        *swasm_http.nim.c.o(COMMON .bss .bss.*)
        *swasm_os.nim.c.o(COMMON .bss .bss.*)
        *sos_storage.nim.c.o(COMMON .bss .bss.*)
        *mm0_wifi_http_server.nim.c.o(COMMON .bss .bss.*)
        *(.psrambss .psrambss.*)
        . = ALIGN(16);
        __psram_bss_end = .;
    } > PSRAM_BSS

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

    .heap (NOLOAD) : ALIGN(16)
    {
        _sheap = .;
        . = ORIGIN(HEAP_RAM) + LENGTH(HEAP_RAM);
        _eheap = .;
    } > HEAP_RAM

    .stack (NOLOAD) : ALIGN(16)
    {
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM);
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

ASSERT(ORIGIN(RAM) == 0x62020000 && LENGTH(RAM) <= 64K,
       "M0 HTTP cached OCRAM must stay within its physical 64 KB")
ASSERT(ORIGIN(RAM) - 0x40000000 + LENGTH(RAM) <= ORIGIN(WIFI_RAM),
       "M0 HTTP cached RAM aliases uncached WiFi WRAM")
ASSERT(ORIGIN(WIFI_RAM) == 0x22030000 &&
       ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM) <= ORIGIN(D0_SDH_DMA),
       "M0 HTTP WiFi DMA overlaps D0 SDH bounce window")
ASSERT(ORIGIN(D0_SDH_DMA) == 0x2204CC00 &&
       ORIGIN(D0_SDH_DMA) + LENGTH(D0_SDH_DMA) <= ORIGIN(SD_DMA),
       "M0 HTTP SD DMA overlaps D0 SDH bounce window")
ASSERT(ORIGIN(SD_DMA) + LENGTH(SD_DMA) <= 0x22050000,
       "M0 HTTP SD DMA overlaps LP boot gate")
ASSERT(__wifi_bss_end <= ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM),
       "M0 HTTP WiFi shared RAM overflow")
ASSERT(__sddma_end <= ORIGIN(SD_DMA) + LENGTH(SD_DMA),
       "M0 HTTP SD DMA scratch overflow")
ASSERT(_ebss <= ORIGIN(RAM) + LENGTH(RAM) - _stack_size - 4K,
       "M0 HTTP OCRAM BSS leaves less than 4 KB stack guard")
ASSERT(__psram_bss_end <= ORIGIN(PSRAM_BSS) + LENGTH(PSRAM_BSS),
       "M0 HTTP PSRAM BSS overflow")
ASSERT(ORIGIN(PSRAM_BSS) + LENGTH(PSRAM_BSS) <= ORIGIN(HEAP_RAM),
       "M0 HTTP PSRAM BSS overlaps heap")
ASSERT(_sheap == ORIGIN(HEAP_RAM) &&
       _eheap == ORIGIN(HEAP_RAM) + LENGTH(HEAP_RAM),
       "M0 HTTP heap outside reserved PSRAM")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 HTTP stack is not at the top of OCRAM")
