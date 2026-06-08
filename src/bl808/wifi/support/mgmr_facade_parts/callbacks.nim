proc connectCb(env, ind: pointer) {.cdecl.} =
  discard env
  lastStatusCode = loadU16(ind, WifiConnStatusOff).int32
  lastReasonCode = loadU16(ind, WifiConnReasonOff).int32
  connectDone = lastStatusCode
  let stat = ptrAt(mgmrRaw(), MgmrStatInfoOff)
  storeU16(stat, StatStatusOff, lastStatusCode.uint16)
  storeU16(stat, StatReasonOff, lastReasonCode.uint16)

proc disconnectCb(env, ind: pointer) {.cdecl.} =
  discard env
  disconnectDone = 1
  connectDone = -1
  if ind != nil:
    lastStatusCode = loadU16(ind, WifiDiscStatusOff).int32
    lastReasonCode = loadU16(ind, WifiDiscReasonOff).int32

proc beaconCb(env, ind: pointer) {.cdecl.} =
  discard env
  scanDiagStore(ind)
  inc scanItemCount
  vendorPutsRaw("[WIFI] scan item ch=")
  vendorPrintU32(if ind != nil: loadU8(ind, WifiBeaconChannelOff).uint32 else: 0, 10)
  vendorPutsRaw(" rssi=")
  if ind != nil and loadI8(ind, WifiBeaconRssiOff) < 0:
    vendorPutsRaw("-")
    vendorPrintU32(uint32(-loadI8(ind, WifiBeaconRssiOff).int), 10)
  else:
    vendorPrintU32(if ind != nil: loadI8(ind, WifiBeaconRssiOff).uint32 else: 0, 10)
  vendorPutsRaw("\r\n")

proc eventCb(env, event: pointer) {.cdecl.} =
  discard env
  if event != nil and loadU32(event, 0) == WifiEventScanDone:
    inc scanDoneCount
    vendorPutsRaw("[WIFI] scan done\r\n")
