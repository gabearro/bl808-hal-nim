/* Keep the existing flash-service ramfunc on the uncached alias. */
SECTIONS
{
    .wifi_cached_hot : ALIGN(32)
    {
        __wifi_cached_hot_exec = .;
        *(.ramfunc.libc.* .ramfunc.mbedtls.* .ramfunc.sha1 .ramfunc.sha1.*)
        . = ALIGN(4);
        __wifi_cached_hot_exec_end = .;
    } > WIFI_CACHED_EXEC AT > FLASH
}
INSERT BEFORE .ramfunc;

__wifi_cached_hot_src = LOADADDR(.wifi_cached_hot);
__wifi_cached_hot_dst = ADDR(.wifi_cached_hot) - 0x40000000;
ASSERT(SIZEOF(.wifi_cached_hot) > 0, "No Mbed TLS hot code in the cached WRAM section")
ASSERT(__wifi_cached_hot_dst >= _eramfunc, "Cached WRAM code overlaps flash-service ramfunc")
ASSERT(__wifi_cached_hot_dst + SIZEOF(.wifi_cached_hot) <= ORIGIN(RAMFUNC) + LENGTH(RAMFUNC),
       "Cached WRAM code extends beyond the physical RAMFUNC bank")
