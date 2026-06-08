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
  let fallback = [0x18'u8, 0xB9'u8, 0x05'u8, 0x00'u8, 0x00'u8, 0x01'u8]
  if mac != nil:
    copyMem(mac, unsafeAddr fallback[0], 6)
  0
