/* Ox64 M0 WiFi application profile: bl808_m0_wifi_http.ld with a 1 MB PSRAM
 * heap and the application's zero-initialised globals in PSRAM, which leaves
 * the 64 KB of cached on-chip RAM to the HAL, WiFi, lwIP and the stack.
 *
 * On-chip partitions are the same as in the HTTP profile: cached OCRAM is
 * 0x62020000..0x6202ffff; uncached WRAM is 0x22030000..0x22057fff. Never
 * extend OCRAM into the 0x6203xxxx WRAM alias: it overlaps the WiFi DMA
 * region at 0x2203xxxx.
 *
 * PSRAM (64 MB at 0x50000000) is not usable at reset and startup clears only
 * the on-chip .bss, so main() must begin with:
 *
 *     psramInit(psram64mb, psramBurst64); psramEnable()
 *     zero __psram_bss_start ..< __psram_bss_end
 *     heapInit()                      (the heap is _sheap ..< _eheap)
 *
 * Until then nothing may touch the heap or a zero-initialised global (.bss)
 * of a Nim module in the project directory: those are all placed in the
 * 128 KB PSRAM window below, with no annotation in the source. Globals with
 * a non-zero initialiser (.data) and everything in the HAL stay on-chip.
 * `.psrambss.*` sections land in the same window, as in the HTTP profile.
 *
 * 1 MB is the largest heap kernel/tlsf.c can manage. The stack is 8 KB at
 * the top of OCRAM plus whatever .bss leaves below it (at least 4 KB);
 * -Wl,--defsym=__bl808_app_stack_bytes=<n> changes the 8 KB.
 *
 * The D0 SDH bounce window and the SD DMA scratch keep their HTTP-profile
 * addresses. A D0 image that uses PSRAM itself must stay clear of
 * 0x50100000..0x5021ffff.
 */

ENTRY(_start)

MEMORY
{
    FLASH       (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAM         (rwx) : ORIGIN = 0x62020000, LENGTH = 64K
    WIFI_RAM    (rw)  : ORIGIN = 0x22030000, LENGTH = 115K
    D0_SDH_DMA  (rw)  : ORIGIN = 0x2204CC00, LENGTH = 8K
    SD_DMA      (rw)  : ORIGIN = 0x2204EC00, LENGTH = 5K
    PSRAM_BSS   (rw)  : ORIGIN = 0x50100000, LENGTH = 128K
    HEAP_RAM    (rw)  : ORIGIN = 0x50120000, LENGTH = 1M
}

PROVIDE(__bl808_app_stack_bytes = 8K);
_stack_size = __bl808_app_stack_bytes;

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
        /* The application's own Nim modules: nimcache names them
         * "@m<path>.nim.c.o". "@m..@s..." are files outside the project
         * directory (HAL and vendor sources reached by a relative path);
         * those stay on-chip. */
        "*/@m[!.]*.nim.c.o"(COMMON .bss .bss.* .sbss .sbss.*)
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
       "M0 WiFi app cached OCRAM must stay within its physical 64 KB")
ASSERT(ORIGIN(RAM) - 0x40000000 + LENGTH(RAM) <= ORIGIN(WIFI_RAM),
       "M0 WiFi app cached RAM aliases uncached WiFi WRAM")
ASSERT(ORIGIN(WIFI_RAM) == 0x22030000 &&
       ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM) <= ORIGIN(D0_SDH_DMA),
       "M0 WiFi app DMA overlaps D0 SDH bounce window")
ASSERT(ORIGIN(D0_SDH_DMA) == 0x2204CC00 &&
       ORIGIN(D0_SDH_DMA) + LENGTH(D0_SDH_DMA) <= ORIGIN(SD_DMA),
       "M0 WiFi app SD DMA overlaps D0 SDH bounce window")
ASSERT(ORIGIN(SD_DMA) + LENGTH(SD_DMA) <= 0x22050000,
       "M0 WiFi app SD DMA overlaps LP boot gate")
ASSERT(__wifi_bss_end <= ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM),
       "M0 WiFi app shared RAM overflow")
ASSERT(__sddma_end <= ORIGIN(SD_DMA) + LENGTH(SD_DMA),
       "M0 WiFi app SD DMA scratch overflow")
ASSERT(_ebss <= ORIGIN(RAM) + LENGTH(RAM) - _stack_size - 4K,
       "M0 WiFi app OCRAM BSS leaves less than 4 KB stack guard")
ASSERT(__psram_bss_end <= ORIGIN(PSRAM_BSS) + LENGTH(PSRAM_BSS),
       "M0 WiFi app PSRAM BSS overflow")
ASSERT(ORIGIN(PSRAM_BSS) + LENGTH(PSRAM_BSS) <= ORIGIN(HEAP_RAM),
       "M0 WiFi app PSRAM BSS overlaps heap")
ASSERT(LENGTH(HEAP_RAM) <= 1M,
       "kernel/tlsf.c indexes free blocks below 1 MB (FL_INDEX_MAX)")
ASSERT(_sheap == ORIGIN(HEAP_RAM) &&
       _eheap == ORIGIN(HEAP_RAM) + LENGTH(HEAP_RAM),
       "M0 WiFi app heap outside reserved PSRAM")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_size,
       "M0 WiFi app stack is not at the top of OCRAM")
