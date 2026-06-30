/*
 * BL808 M0 all-core WASM + WiFi HTTP linker script.
 *
 * This keeps the enclave WRAM profile used by the all-core WASM smoke while
 * retaining the WiFi static config table required by the native WiFi stack.
 */

ENTRY(_start)

MEMORY
{
    FLASH   (rx)  : ORIGIN = 0x58000000, LENGTH = 1M
    RAMFUNC (rwx) : ORIGIN = 0x22030000, LENGTH = 8K
    RAM     (rwx) : ORIGIN = 0x62032000, LENGTH = 120K
    URAM    (rwx) : ORIGIN = 0x6202E000, LENGTH = 4K
    SHARED  (rw)  : ORIGIN = 0x6202F000, LENGTH = 4K
}

_stack_size = 16K;
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
    PROVIDE(__wifi_bss_start = 0);
    PROVIDE(__wifi_bss_end = 0);

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

    .bss (NOLOAD) : ALIGN(16)
    {
        _sbss = .;
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
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_top_reserve - _stack_size;
        . = ALIGN(16);
        _eheap = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(16)
    {
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
        __secure_ram_start = .;
    } > SHARED

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
    }
}

__secure_ram_end   = ORIGIN(RAM) + LENGTH(RAM);
PROVIDE(__umode_ram_start  = ORIGIN(URAM));
PROVIDE(__umode_ram_end    = ORIGIN(URAM) + LENGTH(URAM));
PROVIDE(__umode_sp         = ORIGIN(URAM) + LENGTH(URAM));
PROVIDE(__shared_buf_start = ORIGIN(SHARED));
PROVIDE(__shared_buf_end   = ORIGIN(SHARED) + LENGTH(SHARED));
PROVIDE(__enclave_flash_start = ORIGIN(FLASH));
PROVIDE(__enclave_flash_len   = LENGTH(FLASH));

ASSERT(_eheap >= _sheap, "M0 all-core HTTP WRAM overflow: no space left for heap")
