proc bl808WifiBackendEnableWirelessClocks() =
  regWrite32(GlbBase + 0x580'u32, regRead32(GlbBase + 0x580'u32) or ((1'u32 shl 5) or (1'u32 shl 6) or (1'u32 shl 7)))
  regWrite32(GlbBase + 0x584'u32, regRead32(GlbBase + 0x584'u32) or (1'u32 shl 1))
  regWrite32(GlbBase + 0x588'u32, regRead32(GlbBase + 0x588'u32) or ((1'u32 shl 4) or (1'u32 shl 8) or (1'u32 shl 10)))
  regUpdate32(GlbBase + 0x3B0'u32, 0x0f, 1)

proc bl808WifiBackendConfigureDigClock() =
  let reg = GlbBase + 0x250'u32
  var v = regRead32(reg)
  let dig32 = v and (1'u32 shl 12)
  v = v and not ((1'u32 shl 24) or (1'u32 shl 12))
  regWrite32(reg, v)
  v = regRead32(reg)
  v = (v and not (3'u32 shl 28)) or (1'u32 shl 28)
  regWrite32(reg, v)
  v = regRead32(reg)
  v = (v and not (0x7f'u32 shl 16)) or (0x4e'u32 shl 16) or (1'u32 shl 25) or (1'u32 shl 24) or dig32
  regWrite32(reg, v)
