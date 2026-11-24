const HostDataTxTraceEntries = 24  # Fit the HTTP image's OCRAM stack guard.
type HostDataTxTraceEntry = array[5, uint32]

var hostDataTxConfirmCount {.exportc: "nimfw_dbg_host_data_cfm_count".}: uint32
var hostDataTxConfirmLog {.exportc: "nimfw_dbg_host_data_cfm_log".}:
  array[HostDataTxTraceEntries, HostDataTxTraceEntry]

proc noteHostDataTxConfirm(frame: pointer; length: uint; status: uint32;
                           repush: uint8; macTick: uint32) =
  ## The detail word carries TCP sequence or the UDP host-confirmation tick.
  if frame == nil or length < 34:
    return
  let bytes = cast[ptr UncheckedArray[uint8]](frame)
  if loadBe16(bytes, 12) != 0x0800 or (bytes[14] shr 4) != 4 or
      (loadBe16(bytes, 20) and 0x3FFF) != 0:
    return
  let ipHeaderLen = (bytes[14] and 0xF).uint * 4
  let ipLen = loadBe16(bytes, 16).uint
  if ipHeaderLen < 20 or ipLen < ipHeaderLen or ipLen > length - 14:
    return
  let l4 = 14 + ipHeaderLen
  let l4Len = ipLen - ipHeaderLen
  let protocol = bytes[23]
  var flags = 0'u32
  var detail: uint32
  case protocol
  of 6:
    if l4Len < 20:
      return
    let tcpHeaderLen = (bytes[l4 + 12] shr 4).uint * 4
    if tcpHeaderLen < 20 or tcpHeaderLen > l4Len:
      return
    flags = bytes[l4 + 13].uint32
    detail = (loadBe16(bytes, l4 + 4).uint32 shl 16) or loadBe16(bytes, l4 + 6).uint32
  of 17:
    if l4Len < 8 or loadBe16(bytes, l4 + 4).uint != l4Len:
      return
    detail = macTick
  else:
    return
  let tupleWord = loadBe16(bytes, l4).uint32 or (loadBe16(bytes, l4 + 2).uint32 shl 16)
  let ipWord = loadBe16(bytes, 18).uint32 or (ipLen.uint32 shl 16)
  let slot = (hostDataTxConfirmCount mod HostDataTxTraceEntries.uint32).int
  let meta = protocol.uint32 or (flags shl 8) or (repush.uint32 shl 16)
  hostDataTxConfirmLog[slot] = [tupleWord, ipWord, meta, detail, status]
  hostDataTxConfirmCount += 1
