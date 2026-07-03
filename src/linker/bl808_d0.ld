/*
 * BL808 D0 (C906) linker script
 *
 * D0 firmware is loaded into DRAM at 0x3EF80000 by the M0 bootloader.
 * RAM: DRAM 512 KB + VRAM 32 KB = 544 KB, plus 64 MB pSRAM.
 *
 * For XIP execution: flash remap at 0xD8000000 + D0 boot offset.
 * For RAM execution: M0 copies D0 firmware to DRAM and jumps.
 *
 * This script targets RAM execution in DRAM (typical for D0 lowload).
 */

ENTRY(_start)

MEMORY
{
    /* D0 firmware loaded at DRAM base + offset for D0 lowload */
    DRAM  (rwx) : ORIGIN = 0x3EF80000, LENGTH = 512K
    VRAM  (rwx) : ORIGIN = 0x3F000000, LENGTH = 32K
    PSRAM (rwx) : ORIGIN = 0x50000000, LENGTH = 64M
}

PHDRS
{
    text PT_LOAD FLAGS(5); /* R + X */
    data PT_LOAD FLAGS(6); /* R + W */
}

_stack_size = 8K;

/*
 * D0 SDH ADMA cannot reliably DMA into D0 DRAM/XRAM on current Ox64 hardware.
 * Reserve an MCU WRAM bounce window by symbol so the HAL and validation probes
 * do not duplicate raw addresses.
 *
 * This base MUST equal ORIGIN(D0_SDH_DMA) in the M0 image that runs alongside
 * this D0 image (src/linker/bl808_m0_allcore_http.ld = 0x2204CC00). The earlier
 * 0x22033000 sat 12 KB inside M0's live WIFI_RAM, so D0 SDH reads DMA-clobbered
 * M0 WiFi descriptors and crashed the M0 boot handoff. Keep the two in sync.
 */
PROVIDE(__d0_sdh_adma_desc = 0x2204CC00);
PROVIDE(__d0_sdh_adma_data = 0x2204CC20);
PROVIDE(__d0_sdh_adma_data_len = 0x1000);

SECTIONS
{
    .init : ALIGN(4)
    {
        KEEP(*(.init))
    } > DRAM :text

    .text : ALIGN(4)
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > DRAM :text

    _sidata = LOADADDR(.data);

    .data : ALIGN(8)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
        _edata = .;
    } > DRAM :data

    .bss (NOLOAD) : ALIGN(8)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        _ebss = .;
    } > DRAM :data

    .heap (NOLOAD) : ALIGN(8)
    {
        _sheap = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM) - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > DRAM :data

    .stack (NOLOAD) : ALIGN(16)
    {
        _sstack = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM);
        . = ALIGN(16);
        _estack = .;
        _sp = .;
    } > DRAM :data

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }

}

ASSERT(_eheap >= _sheap, "D0 DRAM overflow: no space left for heap")
ASSERT(_sstack == ORIGIN(DRAM) + LENGTH(DRAM) - _stack_size,
       "D0 stack is not placed at top of DRAM")
