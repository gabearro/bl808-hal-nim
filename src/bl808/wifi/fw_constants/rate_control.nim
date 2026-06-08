## Rate-control table and algorithm constants.

const
  RC_STATS_SIZE*       = 200    # sizeof(rc_sta_stats) = 0xC8
  RC_RATE_ENTRY_SIZE*  = 12     # sizeof(rc_rate_entry) per rate
  RC_MAX_RATE_ENTRIES* = 10     # max supported rates in table
  RC_PRNG_MULT*        = 0x41C64E6D'u32  # LCG multiplier
  RC_PRNG_INCR*        = 0x3039'u32      # LCG increment
  RC_UPDATE_INTERVAL*  = 100000'u32      # ~100ms in MAC ticks (0x186A0)

  # Format mod constants for rate_config packed field bits[12:11]
  RC_FORMATMOD_NON_HT*      = 0'u8
  RC_FORMATMOD_NON_HT_DUP*  = 1'u8
  RC_FORMATMOD_HT_MF*       = 2'u8
  RC_FORMATMOD_HT_GF*       = 3'u8
  RC_FORMATMOD_VHT*         = 4'u8
