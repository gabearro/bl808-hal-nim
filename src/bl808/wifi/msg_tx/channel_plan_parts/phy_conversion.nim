proc phy_channel_to_freq*(band: uint8; channel: cint): uint16 {.exportc, cdecl.} =
  if band == PHY_BAND_2G4:
    if channel < 1 or channel > 14:
      0xffff'u16
    elif channel == 14:
      2484'u16
    else:
      (2407 + channel * 5).uint16
  else:
    0xffff'u16

proc phy_freq_to_channel*(band: uint8; freq: uint16): uint8 {.exportc, cdecl.} =
  if band == PHY_BAND_2G4:
    if freq < 2412'u16 or freq > 2484'u16:
      0'u8
    elif freq == 2484'u16:
      14'u8
    else:
      ((freq - 2407'u16) div 5'u16).uint8
  else:
    0'u8
