proc notifyEventChannelSwitch(channel: cint) =
  var buffer: array[8, uint8]
  zero(addr buffer[0], buffer.len.uint)
  storeU32(addr buffer[0], 0, WifiEventChannelSwitch)
  storeI32(addr buffer[0], 4, channel.int32)
  if cbEvent != nil:
    cbEvent(cbEventEnv, cast[ptr WifiEvent](addr buffer[0]))

proc notifyEventScanDone(joinScan: bool) =
  var buffer: array[8, uint8]
  zero(addr buffer[0], buffer.len.uint)
  storeU32(addr buffer[0], 0, if joinScan: WifiEventScanDoneOnJoin else: WifiEventScanDone)
  storeU32(addr buffer[0], 4, 272'u32)
  if cbEvent != nil:
    cbEvent(cbEventEnv, cast[ptr WifiEvent](addr buffer[0]))
