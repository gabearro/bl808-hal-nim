proc vendorPrintChar(c: char)
proc vendorPutsRaw(s: cstring)
proc vendorPrintU32(value: uint32; base: uint32)
proc vendorPollOnce()
proc osMsleep(ms: clong): cint {.cdecl.}
proc bl_wifi_clock_enable*(): cint {.exportc, cdecl.}
proc bl_wifi_enable_irq*(): cint {.exportc, cdecl.}
proc bl_wifi_mac_addr_get*(mac: ptr uint8): cint {.exportc, cdecl.}
when defined(bl808WifiRealLwip):
  proc pbuf_free*(p: ptr Pbuf): uint8 {.importc: "pbuf_free", header: "<lwip/pbuf.h>", cdecl.}
else:
  proc pbuf_free*(p: ptr Pbuf): uint8 {.exportc, cdecl.}
proc bl_pm_init*(): cint {.exportc, cdecl.}
proc bl_pm_deinit*(): cint {.exportc, cdecl.}
proc bl_pm_state_run*(): cint {.exportc, cdecl.}
proc bl_pm_capacity_set*(level: PmLevel): cint {.exportc, cdecl.}
proc bl_pm_event_register*(event: PmEvent; code, capBit: uint32; priority: uint16; ops: PmCb; arg: pointer; enable: PmEventAble): cint {.exportc, cdecl.}
proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint {.exportc, cdecl.}
proc bl_pm_event_switch*(event: PmEvent; code: uint32; enable: PmEventAble): cint {.exportc, cdecl.}
