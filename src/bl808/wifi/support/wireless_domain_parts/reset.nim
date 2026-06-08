proc bl808WifiBackendSwResetCfg0(bit: uint32) =
  let reg = GlbBase + 0x540'u32
  let mask = 1'u32 shl bit
  regWrite32(reg, regRead32(reg) and not mask)
  discard regRead32(reg)
  regWrite32(reg, regRead32(reg) or mask)
  discard regRead32(reg)
  regWrite32(reg, regRead32(reg) and not mask)
  discard regRead32(reg)
