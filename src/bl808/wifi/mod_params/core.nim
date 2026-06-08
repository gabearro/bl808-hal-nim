import
  accessors,
  layout

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
