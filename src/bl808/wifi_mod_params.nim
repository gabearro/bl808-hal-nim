## Nim replacement for the small BL808 WiFi host-driver mod-params unit.
##
## The SDK C driver still owns `struct bl_hw`; this module only exports the
## global `bl_mod_params` object and writes the same HT capability fields as
## Bouffalo's bl_mod_params.c for the CFG_STA_MAX=1/CFG_VIRT_DEV_MAX=2 build.

const
  RwnxTxLifetimeMs = 100'i32
  NxTxPayloadMax = 6'i32

  BlHwModParamsOff = 0x0dc'u
  BlHwHtCapOff = 0x0e0'u

  HtCapCapOff = 0'u
  HtCapHtSupportedOff = 2'u
  HtCapMcsRxMaskOff = 6'u
  HtCapMcsRxHighestOff = 16'u

  BlModParamsPhyCfgOff = 8'u
  BlModParamsMcsMapOff = 4'u
  BlModParamsSgiOff = 16'u
  BlModParamsHtOnOff = 0'u

  Ieee80211HtCapRxStbcShift = 8
  Ieee80211HtCapSgi20 = 0x0020'u16
  Ieee80211HtCapSmPs = 0x000c'u16

type
  BlModParams {.bycopy.} = object
    ht_on: uint8
    vht_on: uint8
    pad0: array[2, uint8]
    mcs_map: int32
    phy_cfg: int32
    uapsd_timeout: int32
    sgi: uint8
    sgi80: uint8
    use_2040: uint8
    pad1: uint8
    listen_itv: int32
    listen_bcmc: uint8
    pad2: array[3, uint8]
    lp_clk_ppm: int32
    ps_on: uint8
    pad3: array[3, uint8]
    tx_lft: int32
    amsdu_maxnb: int32
    uapsd_queues: int32

var bl_mod_params* {.exportc.}: BlModParams = BlModParams(
  ht_on: 1'u8,
  vht_on: 0'u8,
  mcs_map: 0'i32,
  phy_cfg: 2'i32,
  uapsd_timeout: 3000'i32,
  sgi: 0'u8,
  sgi80: 0'u8,
  use_2040: 0'u8,
  listen_itv: 1'i32,
  listen_bcmc: 1'u8,
  lp_clk_ppm: 20'i32,
  ps_on: 0'u8,
  tx_lft: RwnxTxLifetimeMs,
  amsdu_maxnb: NxTxPayloadMax,
  uapsd_queues: 0'i32
)

template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc loadI32(base: pointer; off: uint): int32 {.inline.} =
  cast[ptr int32](ptrAt(base, off))[]

proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, off))[] = value

proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[]

proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[] = value

proc bl_handle_dynparams*(blHw: pointer): cint {.exportc, cdecl.} =
  if blHw == nil:
    return -1

  let modParams = loadPtr(blHw, BlHwModParamsOff)
  if modParams == nil:
    return -1

  let phyCfg = loadI32(modParams, BlModParamsPhyCfgOff)
  if phyCfg < 0'i32 or phyCfg > 5'i32:
    storeI32(modParams, BlModParamsPhyCfgOff, 2'i32)

  let mcsMap = loadI32(modParams, BlModParamsMcsMapOff)
  if mcsMap < 0'i32 or mcsMap > 2'i32:
    storeI32(modParams, BlModParamsMcsMapOff, 0'i32)

  let htCap = ptrAt(blHw, BlHwHtCapOff)
  var cap = loadU16(htCap, HtCapCapOff)
  cap = cap or (1'u16 shl Ieee80211HtCapRxStbcShift)
  storeU16(htCap, HtCapMcsRxHighestOff, 65'u16)
  storeU8(htCap, HtCapMcsRxMaskOff, 0xff'u8)

  if loadU8(modParams, BlModParamsSgiOff) != 0'u8:
    cap = cap or Ieee80211HtCapSgi20
    storeU16(htCap, HtCapMcsRxHighestOff, 72'u16)

  cap = cap or Ieee80211HtCapSmPs
  storeU16(htCap, HtCapCapOff, cap)

  if loadU8(modParams, BlModParamsHtOnOff) == 0'u8:
    storeU8(htCap, HtCapHtSupportedOff, 0'u8)

  0
