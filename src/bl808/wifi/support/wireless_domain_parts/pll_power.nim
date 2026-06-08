proc bl808WifiBackendPowerOnXtalWifiPll() =
  let aon = 0x2000_F000'u32
  let hbn = 0x2000_F000'u32
  let mmGlb = 0x3000_7000'u32
  regWrite32(aon + 0x880'u32, regRead32(aon + 0x880'u32) or 0x37'u32)
  arch_delay_us(120)
  regWrite32(hbn + 0x10c'u32, (regRead32(hbn + 0x10c'u32) and 0xffff_0000'u32) or 0x5804'u32)
  if (regRead32(GlbBase + 0x810'u32) and (1'u32 shl 10)) != 0:
    regWrite32(GlbBase + 0x824'u32, regRead32(GlbBase + 0x824'u32) or (1'u32 shl 12))
    regWrite32(GlbBase + 0x830'u32, regRead32(GlbBase + 0x830'u32) or 0x8000_003e'u32)
    regWrite32(GlbBase + 0x090'u32, regRead32(GlbBase + 0x090'u32) or 1)
    regWrite32(mmGlb, regRead32(mmGlb) or 1)
    return
  regUpdate32(GlbBase + 0x810'u32, (1'u32 shl 10) or (1'u32 shl 9), 0)
  regUpdate32(GlbBase + 0x814'u32, (0x0f'u32 shl 8) or (0x03'u32 shl 16), (2'u32 shl 8) or (1'u32 shl 16))
  regUpdate32(GlbBase + 0x818'u32, (1'u32 shl 8) or (0x03'u32 shl 6) or (0x03'u32 shl 4), 2'u32 shl 4)
  regUpdate32(GlbBase + 0x81c'u32, (1'u32 shl 0) or (1'u32 shl 8) or (0x03'u32 shl 12) or (0x03'u32 shl 14) or (0x07'u32 shl 16), (1'u32 shl 8) or (2'u32 shl 12) or (1'u32 shl 14) or (3'u32 shl 16))
  regUpdate32(GlbBase + 0x820'u32, 0x03, 1)
  regUpdate32(GlbBase + 0x824'u32, 0x07, 5)
  regUpdate32(GlbBase + 0x828'u32, 0x03ff_ffff'u32 or (1'u32 shl 28) or (1'u32 shl 31), 0x0180_0000'u32 or (1'u32 shl 28) or (1'u32 shl 31))
  regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl 9))
  arch_delay_us(3)
  regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl 10))
  arch_delay_us(3)
  for bit in [0'u32, 2'u32]:
    regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl bit))
    arch_delay_us(2)
    regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) and not (1'u32 shl bit))
    arch_delay_us(2)
    regWrite32(GlbBase + 0x810'u32, regRead32(GlbBase + 0x810'u32) or (1'u32 shl bit))
  regWrite32(GlbBase + 0x824'u32, regRead32(GlbBase + 0x824'u32) or (1'u32 shl 12))
  regWrite32(GlbBase + 0x830'u32, regRead32(GlbBase + 0x830'u32) or 0x8000_003e'u32)
  arch_delay_us(75)
  regWrite32(GlbBase + 0x090'u32, regRead32(GlbBase + 0x090'u32) or 1)
  regWrite32(mmGlb, regRead32(mmGlb) or 1)
