/*
 * BL808 M0 all-core WASM + enclave + WiFi HTTP linker script.
 *
 * This combines the expanded WRAM enclave profile with the native WiFi stack.
 * The important split is physical:
 *   - PSRAM: M0 allocator heap and large HTTP/SD scratch buffers.
 *   - WRAM 0x22030000..0x2204cbff: uncached WiFi DMA/shared descriptors,
 *     RX payload pool, and small WiFi state. The MAC/RX path is sensitive to
 *     the descriptor base used by the validated standalone WiFi image.
 *   - WRAM 0x2204cc00..0x2204ebff: D0 SDH ADMA bounce window (desc + 4K data).
 *     D0 SDH cannot DMA into D0 DRAM/XRAM on Ox64, so it bounces through this
 *     MCU WRAM region. The D0 linkers (bl808_d0.ld / bl808_d0_ram.ld) PROVIDE
 *     __d0_sdh_adma_desc at ORIGIN(D0_SDH_DMA); the ASSERT below pins them
 *     together so M0's WiFi allocator never reclaims D0's live DMA target.
 *   - WRAM 0x2204f000..0x2204ffff: ramfunc.
 *   - OCRAM low 56 KB: secure M-mode runtime and stack.
 *   - OCRAM top 8 KB: enclave U-mode and shared service buffers.
 *   - WRAM 0x22050000..0x22053fff: LP boot gate scratch.
 *   - WRAM top 16 KB: LP runtime, owned by bl808_lp.ld.
 *
 * WiFi RX payloads stay in WRAM rather than PSRAM because the MAC/RX path has
 * only been validated with internal memory. Ordinary M0 heap pressure is moved
 * to PSRAM instead.
 */

ENTRY(_start)

MEMORY
{
    FLASH    (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    /* Heap + psram bss RELOCATED to +1MB with a 64K guard hole between them,
     * away from the D0 WASM-image stage (0x50010000) and anything else that
     * touches the bottom of PSRAM. The M0 heap previously lived at
     * 0x50000000..0x50010000 and its objects were intermittently corrupted
     * (JTAG-confirmed: a Table entry's string pointer read back 0xA ->
     * misaligned-load fault in =destroy during HTTP dispatch). Separating the
     * regions discriminates adjacent-overrun corruption from PSRAM
     * instability and keeps a red zone below the heap either way. */
    PSRAM_BSS (rw) : ORIGIN = 0x50100000, LENGTH = 64K
    HEAP_RAM (rw)  : ORIGIN = 0x50120000, LENGTH = 64K
    WASM_STAGE (rw): ORIGIN = 0x50010000, LENGTH = 64K
    WIFI_RAM (rw)  : ORIGIN = 0x22030000, LENGTH = 115K
    D0_SDH_DMA (rw): ORIGIN = 0x2204CC00, LENGTH = 8K
    URAM     (rwx) : ORIGIN = 0x6202E000, LENGTH = 4K
    SHARED   (rw)  : ORIGIN = 0x6202F000, LENGTH = 4K
    RAMFUNC  (rwx) : ORIGIN = 0x2204F000, LENGTH = 4K
    RAM      (rwx) : ORIGIN = 0x62020000, LENGTH = 56K
}

_stack_size = 10K;
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
        _bl_static_fw_cfg_entry_start = .;
        KEEP(*(.wifi.cfg.entry))
        _bl_static_fw_cfg_entry_end = .;

        . = ALIGN(4);
    } > FLASH

    PROVIDE(_ld_bl_static_cfg_entry_start = _bl_static_fw_cfg_entry_start);
    PROVIDE(_ld_bl_static_cfg_entry_end = _bl_static_fw_cfg_entry_end);

    _siramfunc = LOADADDR(.ramfunc);

    .ramfunc : ALIGN(4)
    {
        _sramfunc = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(4);
        _eramfunc = .;
    } > RAMFUNC AT > FLASH

    _sidata = LOADADDR(.data);

    .data : ALIGN(4)
    {
        _sdata = .;
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
        PROVIDE(__wifi_rx_ram_start = .);
        KEEP(*(.wifirxram .wifirxram.*))
        . = ALIGN(16);
        PROVIDE(__wifi_rx_ram_end = .);
        *swifi_fw.nim.c.o(COMMON)
        *swifi_fw.nim.c.o(.bss*)
        *(.wifi_ram*)
        *(.wifibss .wifibss.*)
        . = ALIGN(16);
        PROVIDE(__wifi_bss_end = .);
    } > WIFI_RAM

    .bss (NOLOAD) : ALIGN(16)
    {
        _sbss = .;
        *(.ram_wifi_ctrl*)
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    .psrambss (NOLOAD) : ALIGN(16)
    {
        PROVIDE(__psram_bss_start = .);
        *(.psrambss .psrambss.*)
        . = ALIGN(16);
        KEEP(*(.jtaglog .jtaglog.*))
        . = ALIGN(16);
        PROVIDE(__psram_bss_end = .);
    } > PSRAM_BSS

    .heap (NOLOAD) : ALIGN(4)
    {
        _sheap = .;
        . = ORIGIN(HEAP_RAM) + LENGTH(HEAP_RAM);
        . = ALIGN(16);
        _eheap = .;
    } > HEAP_RAM

    .stack (NOLOAD) : ALIGN(16)
    {
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size;
        _sstack = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve;
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > RAM

    .udata (NOLOAD) : ALIGN(16)
    {
        _su_data = .;
        *(.udata .udata.*)
        *(.ubss .ubss.*)
        . = ORIGIN(URAM) + LENGTH(URAM);
        _u_sp = .;
    } > URAM

    .shared (NOLOAD) : ALIGN(16)
    {
        *(.shared .shared.*)
        . = ORIGIN(SHARED) + LENGTH(SHARED);
    } > SHARED

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

__secure_ram_start = ORIGIN(RAM);
__secure_ram_end   = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(__umode_ram_start  = ORIGIN(URAM));
PROVIDE(__umode_ram_end    = ORIGIN(URAM) + LENGTH(URAM));
PROVIDE(__umode_sp         = ORIGIN(URAM) + LENGTH(URAM));
PROVIDE(__shared_buf_start = ORIGIN(SHARED));
PROVIDE(__shared_buf_end   = ORIGIN(SHARED) + LENGTH(SHARED));
PROVIDE(__enclave_flash_start = ORIGIN(FLASH));
PROVIDE(__enclave_flash_len   = LENGTH(FLASH));

ASSERT(_eheap >= _sheap, "M0 all-core HTTP secure WRAM overflow: no space left for heap")
/* Heap and psram bss now live ABOVE the WASM stage with a 64K guard hole
 * between psrambss and heap; keep all three regions disjoint. */
ASSERT(ORIGIN(WASM_STAGE) + LENGTH(WASM_STAGE) <= ORIGIN(PSRAM_BSS),
       "M0 all-core HTTP WASM staging RAM overlaps psram bss")
ASSERT(ORIGIN(PSRAM_BSS) + LENGTH(PSRAM_BSS) <= ORIGIN(HEAP_RAM),
       "M0 all-core HTTP psram bss overlaps heap")
ASSERT(__wifi_bss_end <= ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM),
       "M0 all-core HTTP WiFi WRAM overflow")
ASSERT(ORIGIN(WIFI_RAM) + LENGTH(WIFI_RAM) <= ORIGIN(D0_SDH_DMA),
       "M0 all-core HTTP WiFi RAM overlaps D0 SDH DMA window")
ASSERT(ORIGIN(D0_SDH_DMA) + LENGTH(D0_SDH_DMA) <= ORIGIN(RAMFUNC),
       "D0 SDH DMA window overlaps M0 ramfunc")
/* Contract: D0 (bl808_d0.ld / bl808_d0_ram.ld) PROVIDEs
 *   __d0_sdh_adma_desc = ORIGIN(D0_SDH_DMA)            (0x2204CC00)
 *   __d0_sdh_adma_data = ORIGIN(D0_SDH_DMA) + 0x20
 *   __d0_sdh_adma_data_len = 0x1000
 * so D0's SDH ADMA bounce target (0x20 desc + 0x1000 data = 0x1020 bytes) must
 * fit inside this reserved window. If you move the window, move D0's PROVIDEs to
 * match — both must name the same base or D0 DMA corrupts M0 WiFi RAM. */
ASSERT(LENGTH(D0_SDH_DMA) >= 0x1020,
       "D0 SDH DMA window too small for D0 ADMA desc + 4K data")
ASSERT(__wifi_rx_ram_end <= __wifi_bss_end,
       "M0 all-core HTTP WiFi RX pool escaped WiFi WRAM")
ASSERT(_eramfunc <= ORIGIN(RAMFUNC) + LENGTH(RAMFUNC),
       "M0 all-core HTTP ramfunc overflow")
ASSERT(_ebss <= _sstack - 1024,
       "M0 all-core HTTP secure BSS leaves less than 1 KB stack guard")
ASSERT(_sstack == ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size,
       "M0 all-core HTTP stack is not placed below reserve at top of secure WRAM")
