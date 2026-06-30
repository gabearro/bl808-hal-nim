import ../../efuse

proc bl_wifi_clock_enable*(): cint {.exportc, cdecl.} =
  bl808WifiBackendPrepareWirelessDomain()
  let reg = GlbBase + 0x3b0'u32
  regWrite32(reg, (regRead32(reg) and not 0x0f'u32) or 1)
  0

proc bl_wifi_enable_irq*(): cint {.exportc, cdecl.} =
  bl808_register_trap_handler(Bl808IrqWifi, bl808WifiBackendMacIrqTrampoline)
  bl808_register_trap_handler(Bl808IrqWifiIpcPublic, bl808WifiBackendIpcIrqTrampoline)
  bl808_enable_peripheral_irq(Bl808IrqWifi, 1)
  bl808_enable_peripheral_irq(Bl808IrqWifiIpcPublic, 1)
  0

proc bl_wifi_mac_addr_get*(mac: ptr uint8): cint {.exportc, cdecl.} =
  if mac != nil:
    when defined(bl808WifiForceExpectedEfuseMac):
      let expected = [0x34'u8, 0xCB'u8, 0xB8'u8, 0x02'u8, 0x33'u8, 0x2E'u8]
      copyMem(mac, unsafeAddr expected[0], 6)
      return 0
    when defined(bl808WifiForceLegacyMac):
      let fallback = [0x18'u8, 0xB9'u8, 0x05'u8, 0x00'u8, 0x00'u8, 0x01'u8]
      copyMem(mac, unsafeAddr fallback[0], 6)
      return 0
    let macBytes = cast[ptr UncheckedArray[uint8]](mac)
    var efuseMac: array[6, uint8]
    efuseReadMacAddress(efuseMac)
    copyMem(mac, addr efuseMac[0], 6)
    template macInvalid(): bool =
      var allZero = true
      var allOneSentinel = true
      for macByteIndex in 0 ..< 6:
        let b = macBytes[macByteIndex]
        if b != 0:
          allZero = false
        if b != 1:
          allOneSentinel = false
      allZero or allOneSentinel or (macBytes[0] and 1'u8) != 0
    if macInvalid():
      let chipId = efuseReadChipId()
      var mix = uint32(chipId) xor uint32(chipId shr 32) xor 0xB180_8001'u32
      mix = mix xor (mix shr 16)
      mix = mix * 0x7FEB_352D'u32
      mix = mix xor (mix shr 15)
      let fallback = [
        0x02'u8, 0xB8'u8,
        uint8((mix shr 0) and 0xFF'u32),
        uint8((mix shr 8) and 0xFF'u32),
        uint8((mix shr 16) and 0xFF'u32),
        uint8((mix shr 24) and 0xFF'u32)
      ]
      copyMem(mac, unsafeAddr fallback[0], 6)
  0
