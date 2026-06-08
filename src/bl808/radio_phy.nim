## Shared BL808 radio/PHY mode policy.
##
## Keep the WiFi/BLE coexistence API-mode mapping outside the firmware body so
## WiFi RF bring-up and BLE controller integration can use one definition.

from std/volatile import volatileLoad, volatileStore

const
  WlApiModeWlan* = 1'u8
  WlApiModeBle* = 2'u8
  WlApiModeAll* = 3'u8

type
  RadioPhyMode* = enum
    wifiOnly = 1'u8
    bleOnly = 2'u8
    wifiBleCoex = 3'u8

proc radioPhyModeFromApi*(apiMode: uint8): RadioPhyMode {.inline.} =
  case apiMode
  of WlApiModeBle:
    bleOnly
  of WlApiModeAll:
    wifiBleCoex
  else:
    wifiOnly

proc apiFromRadioPhyMode*(mode: RadioPhyMode): uint8 {.inline.} =
  case mode
  of bleOnly:
    WlApiModeBle
  of wifiBleCoex:
    WlApiModeAll
  else:
    WlApiModeWlan

proc updateReg32*(reg: ptr uint32, clearMask, setMask: uint32) {.inline.} =
  volatileStore(reg, (volatileLoad(reg) and clearMask) or setMask)

proc radioWaitRegMaskClear*(reg: ptr uint32; mask, limit: uint32): bool {.inline.} =
  var remaining = limit
  while (volatileLoad(reg) and mask) != 0'u32:
    if remaining == 0'u32:
      return false
    dec remaining
  true

proc radioWaitRegMaskSet*(reg: ptr uint32; mask, limit: uint32): bool {.inline.} =
  var remaining = limit
  while (volatileLoad(reg) and mask) == 0'u32:
    if remaining == 0'u32:
      return false
    dec remaining
  true

proc radioWaitRegMaskClear*(reg: uint; mask, limit: uint32): bool {.inline.} =
  radioWaitRegMaskClear(cast[ptr uint32](reg), mask, limit)

proc radioWaitRegMaskSet*(reg: uint; mask, limit: uint32): bool {.inline.} =
  radioWaitRegMaskSet(cast[ptr uint32](reg), mask, limit)
