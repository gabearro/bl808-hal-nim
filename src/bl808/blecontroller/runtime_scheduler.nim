# Memset/memcpy from C (linked externally)
proc c_memset(s: pointer, c: cint, n: csize_t): pointer {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest: pointer, src: pointer, n: csize_t): pointer {.importc: "memcpy", header: "<string.h>", cdecl.}
proc c_memcmp(a: pointer, b: pointer, n: csize_t): cint {.importc: "memcmp", header: "<string.h>", cdecl.}

proc bflbip_us_2_lpcycles*(us: uint32): uint32 {.exportc, cdecl.}
proc bflbip_wakeup_delay_set*(delay: uint32) {.exportc, cdecl.}
proc lld_sleep_init*() {.exportc, cdecl.}

proc read16(regAddr: uint32): uint16 {.inline.} =
  volatileLoad(cast[ptr uint16](regAddr.uint))

proc read8(regAddr: uint32): uint8 {.inline.} =
  volatileLoad(cast[ptr uint8](regAddr.uint))

proc read32(regAddr: uint32): uint32 {.inline.} =
  volatileLoad(cast[ptr uint32](regAddr.uint))

proc write16(regAddr: uint32, value: uint16) {.inline.} =
  volatileStore(cast[ptr uint16](regAddr.uint), value)

proc write8(regAddr: uint32, value: uint8) {.inline.} =
  volatileStore(cast[ptr uint8](regAddr.uint), value)

template bleEmBytes(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](BLE_EM_BASE)

template btbleEmBytes(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](BTBLE_EM_BASE)

proc bleEmPointer(offset: uint16): pointer {.inline.} =
  cast[pointer](addr bleEmBytes()[offset])

proc btbleEmBytePtr(offset: uint16): ptr uint8 {.inline.} =
  addr btbleEmBytes()[offset]

proc btbleEmPayload(offset: uint16): ptr UncheckedArray[uint8] {.inline.} =
  cast[ptr UncheckedArray[uint8]](btbleEmBytePtr(offset))

template btbleAdvPduAt(buf: uint16): ptr BtbleAdvPduView =
  cast[ptr BtbleAdvPduView](BTBLE_EM_BASE + buf.uint32)

proc btbleEmRead8(offset: uint16): uint8 {.inline.} =
  volatileLoad(btbleEmBytePtr(offset))

proc btbleEmWrite8(offset: uint16, value: uint8) {.inline.} =
  volatileStore(btbleEmBytePtr(offset), value)

proc copyBytes(dstAddr: uint32, src: ptr uint8, len: int) =
  if src == nil or len <= 0:
    return
  let raw = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< len:
    write8(dstAddr + i.uint32, raw[i])

proc copyBtbleEmBytes(dstOffset: uint16, src: ptr uint8, len: int) =
  if src == nil or len <= 0:
    return
  let raw = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< len:
    btbleEmWrite8(dstOffset + i.uint16, raw[i])

proc writeBtbleInterruptMask(mask: uint32) =
  ## BTBLE's mask register gates the hardware status sources that the
  ## cooperative M0 poller reads.  In polled M0 builds keep M-mode interrupts
  ## globally disabled while the foreground poller owns BLE; E907 CLIC can
  ## still enter the trap path for pending-disabled sources if MIE stays set.
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    nim_btble_polled_intmask = mask
    quiesceM0PolledBleClicSources()
    regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, mask)
    quiesceM0PolledBleClicSources()
  else:
    regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, mask)

proc enableBtbleInterruptMaskBits(mask: uint32) =
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    nim_btble_polled_intmask = nim_btble_polled_intmask or mask
    quiesceM0PolledBleClicSources()
    regOr(BLE_BASE + BTBLE_INTMASK_OFFSET, mask)
    quiesceM0PolledBleClicSources()
  else:
    regOr(BLE_BASE + BTBLE_INTMASK_OFFSET, mask)

proc invokeOnChipHci(pktType: uint8, srcId: uint16, payload: ptr uint8,
                     len: uint8): bool =
  let cb = onchiphci_recv_cb
  nim_hci_debug_cb = cast[uint32](cast[uint](cb))
  if cb == nil:
    return false
  if len.int > onchiphci_cb_payload.len:
    return false

  var cbPayload: ptr uint8 = nil
  if len != 0'u8:
    if payload == nil:
      return false
    let src = cast[ptr UncheckedArray[uint8]](payload)
    for i in 0 ..< len.int:
      onchiphci_cb_payload[i] = src[i]
    cbPayload = addr onchiphci_cb_payload[0]

  nim_hci_debug_stage = 0x4010'u32
  cb(pktType, srcId, cbPayload, len)
  nim_hci_debug_stage = 0x4020'u32
  true

proc sendCmdComplete(opcode: uint16, status: uint8) =
  nim_hci_debug_stage = 0x4000'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_status = status.uint32
  nim_hci_debug_len = 1
  bleCentralDebugMark(0x900'u32, uint32(opcode))
  var cc = [status]
  if invokeOnChipHci(HciPktCmdComplete, opcode, addr cc[0], 1):
    bleCentralDebugMark(0x902'u32, uint32(opcode))

proc sendCmdComplete2(opcode: uint16, status: uint8, value: uint8) =
  var cc = [status, value]
  discard invokeOnChipHci(HciPktCmdComplete, opcode, addr cc[0],
                          cc.len.uint8)

proc sendCmdCompletePayload(opcode: uint16, payload: ptr uint8, len: uint8) =
  nim_hci_debug_stage = 0x4030'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = len.uint32
  discard invokeOnChipHci(HciPktCmdComplete, opcode, payload, len)
  nim_hci_debug_stage = 0x4031'u32

proc sendCmdStatus(opcode: uint16, status: uint8) =
  var cs = [status]
  discard invokeOnChipHci(HciPktCmdStatus, opcode, addr cs[0], 1)

proc sendHostEvent(eventCode: uint16, payload: ptr uint8, len: uint8) =
  discard invokeOnChipHci(HciPktEvent, eventCode, payload, len)

proc sendLeMetaPayload(payload: ptr uint8, len: uint8) =
  discard invokeOnChipHci(HciPktLeMeta, 0, payload, len)

proc sendNumberOfCompletedPackets(handle, count: uint16) =
  var evt = [1'u8, uint8(handle and 0x00FF'u16),
             uint8((handle shr 8) and 0x00FF'u16),
             uint8(count and 0x00FF'u16),
             uint8((count shr 8) and 0x00FF'u16)]
  sendHostEvent(HciEvtNumberOfCompletedPackets, addr evt[0], evt.len.uint8)

proc sendHostAclBytes(handle: uint16, llid: uint8,
                      data: ptr uint8, len: uint8): bool =
  if onchiphci_recv_cb == nil:
    return false
  if data == nil or len == 0'u8 or len.uint16 > NimBleLeMaxDataOctets:
    return false
  var pkt: array[4 + NimBleLeMaxDataOctets.int, uint8]
  let acl = cast[ptr HciAclHostPacketView](addr pkt[0])
  let pbFlag =
    if llid == 0x01'u8:
      0x01'u16
    else:
      0x02'u16
  let hciHandle = (handle and 0x0FFF'u16) or (pbFlag shl 12)
  acl.handleFlags = hciHandle
  acl.length = len.uint16
  let src = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< len.int:
    acl.payload[i] = src[i]
  invokeOnChipHci(BtHciAclData, handle, addr pkt[0], len + 4'u8)

proc sendHostAclData(handle: uint16, llid: uint8,
                     dataOff: uint16, len: uint8): bool =
  let data = btbleEmBytePtr(dataOff)
  sendHostAclBytes(handle, llid, data, len)

proc sendLeEncryptComplete(opcode: uint16, params: ptr uint8,
                           paramLen: uint8): uint8
proc sendLeRandComplete(opcode: uint16, paramLen: uint8): uint8
proc sendReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8
proc sendLeReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8
proc sendLeReadLocalSupportedFeaturesComplete(opcode: uint16,
                                              paramLen: uint8): uint8
proc sendLeReadLocalP256Complete(opcode: uint16, paramLen: uint8): uint8
proc sendLeGenerateDhKeyComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8
proc sendLeDataLengthChange(handle: uint16)
proc sendLeRemoteFeaturesComplete(handle: uint16, status: uint8)
proc sendRemoteVersionInfoComplete(handle: uint16, status: uint8)
proc sendLeConnectionUpdateCompleteValues(handle: uint16, status: uint8,
                                          interval, latency,
                                          timeout: uint16)
proc sendLeReadRemoteFeaturesCommand(opcode: uint16, params: ptr uint8,
                                     paramLen: uint8): uint8
proc sendReadRemoteVersionInfoCommand(opcode: uint16, params: ptr uint8,
                                      paramLen: uint8): uint8
proc sendLeConnectionUpdateCommand(opcode: uint16, params: ptr uint8,
                                   paramLen: uint8): uint8
proc sendLeSetDataLengthComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8
proc sendLeReadSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                  paramLen: uint8): uint8
proc sendLeWriteSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                   params: ptr uint8,
                                                   paramLen: uint8): uint8
proc sendLeReadMaximumDataLengthComplete(opcode: uint16,
                                         paramLen: uint8): uint8
proc nimBleCurrentChannelMap(dst: ptr UncheckedArray[uint8])
proc bleFillRandomBytes(dst: ptr uint8, len: int): bool
proc ble_util_buf_acl_tx_free*(buf: pointer) {.exportc, cdecl.}
proc llc_llcp_feats_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.}
proc ble_util_buf_rx_free*(buf: pointer) {.exportc, cdecl.}

proc connDataPayloadLen(header: uint16): uint8 {.inline.} =
  uint8((header shr 8) and 0x00FF'u16)

proc advPayloadLen(header: uint16): uint8 {.inline.} =
  uint8((header shr 8) and 0x003F'u16)

template hciRawCmd(data: pointer): ptr HciRawCmdView =
  cast[ptr HciRawCmdView](data)

proc hciRawOpcode(data: pointer): uint16 {.inline.} =
  hciRawCmd(data).opcode

proc hciRawParamLen(data: pointer): uint8 {.inline.} =
  hciRawCmd(data).paramLen

proc hciRawParams(data: pointer): ptr uint8 {.inline.} =
  addr hciRawCmd(data).params[0]

template hciLeCreateConnReq(params: ptr uint8): ptr HciLeCreateConnReqView =
  cast[ptr HciLeCreateConnReqView](params)

template nimVendorLlcStartParams(params: pointer): ptr NimVendorLlcStartParamsView =
  cast[ptr NimVendorLlcStartParamsView](params)

template nimLldConStartParams(params: pointer): ptr NimLldConStartParamsView =
  cast[ptr NimLldConStartParamsView](params)

template hciLeConnUpdateReq(params: ptr uint8): ptr HciLeConnUpdateReqView =
  cast[ptr HciLeConnUpdateReqView](params)

template hciLeSetPhyReq(params: ptr uint8): ptr HciLeSetPhyReqView =
  cast[ptr HciLeSetPhyReqView](params)

template hciLeSetDataLenReq(params: ptr uint8): ptr HciLeSetDataLenReqView =
  cast[ptr HciLeSetDataLenReqView](params)

template hciLeSuggestedDataLenReq(params: ptr uint8): ptr HciLeSuggestedDataLenReqView =
  cast[ptr HciLeSuggestedDataLenReqView](params)

template hciLeSetAdvRandomAddrReq(params: ptr uint8): ptr HciLeSetAdvSetRandomAddressReqView =
  cast[ptr HciLeSetAdvSetRandomAddressReqView](params)

template hciConnHandleReq(params: ptr uint8): ptr HciConnHandleReqView =
  cast[ptr HciConnHandleReqView](params)

template hciConnHandle(params: ptr uint8): uint16 =
  if params == nil: 0'u16 else: hciConnHandleReq(params).handle

template hciDisconnectReq(params: ptr uint8): ptr HciDisconnectReqView =
  cast[ptr HciDisconnectReqView](params)

template hciLeSetRandomAddressReq(params: ptr uint8): ptr HciLeSetRandomAddressReqView =
  cast[ptr HciLeSetRandomAddressReqView](params)

template hciLeSetAdvParamsReq(params: ptr uint8): ptr HciLeSetAdvParamsReqView =
  cast[ptr HciLeSetAdvParamsReqView](params)

template hciLeDataPayloadReq(params: ptr uint8): ptr HciLeDataPayloadReqView =
  cast[ptr HciLeDataPayloadReqView](params)

template hciLeSetAdvEnableReq(params: ptr uint8): ptr HciLeSetAdvEnableReqView =
  cast[ptr HciLeSetAdvEnableReqView](params)

template hciLeSetScanParamsReq(params: ptr uint8): ptr HciLeSetScanParamsReqView =
  cast[ptr HciLeSetScanParamsReqView](params)

template hciLeSetScanEnableReq(params: ptr uint8): ptr HciLeSetScanEnableReqView =
  cast[ptr HciLeSetScanEnableReqView](params)

template hciWriteAuthPayloadTimeoutReq(params: ptr uint8): ptr HciWriteAuthPayloadTimeoutReqView =
  cast[ptr HciWriteAuthPayloadTimeoutReqView](params)

proc connParamStatus(params: ptr uint8, handle: uint16): uint8 =
  if params == nil:
    return HciStatusInvalidParams
  if not nim_conn_active or handle != nim_conn_handle:
    return HciStatusUnknownConnection
  return HciStatusSuccess

proc sendLeConnectionCompleteStatusHandle(params: ptr uint8, paramLen: uint8,
                                          status: uint8, handle: uint16,
                                          role: uint8) =
  if onchiphci_recv_cb == nil or params == nil or paramLen != 25:
    return
  let req = hciLeCreateConnReq(params)
  var evt: array[19, uint8]
  let body = cast[ptr HciLeConnectionCompleteEventView](addr evt[0])
  body.subevent = 0x01'u8
  body.status = status
  body.handle = handle
  body.role = role
  body.peerAddrType = req.peerAddrType
  body.peerAddr = req.peerAddr
  body.interval = req.connIntervalMin
  body.latency = req.connLatency
  body.timeout = req.supervisionTimeout
  body.accuracy = 0
  if status == 0'u8:
    nim_conn_active = true
    nim_conn_handle = handle
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeConnectionCompleteStatus(params: ptr uint8, paramLen: uint8,
                                    status: uint8) =
  sendLeConnectionCompleteStatusHandle(params, paramLen, status, 0'u16, 0'u8)

proc sendLeConnectionComplete(params: ptr uint8, paramLen: uint8) =
  sendLeConnectionCompleteStatus(params, paramLen, 0'u8)

proc drainNimInitPeerComplete(): bool =
  false

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc clearNimConnectionStateForDisconnect(reason: uint8)

proc sendDisconnectComplete(handle: uint16, reason: uint8) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    clearNimConnectionStateForDisconnect(reason)
  nim_conn_active = false
  nim_conn_handle = 0
  if onchiphci_recv_cb == nil:
    return
  var evt: array[4, uint8]
  let body = cast[ptr HciDisconnectCompleteEventView](addr evt[0])
  body.status = 0'u8
  body.handle = handle
  body.reason = reason
  sendHostEvent(HciEvtDisconnectComplete, addr evt[0], evt.len.uint8)

when defined(bl808m0):
  const NimPendingScanReportSlots = 8

  type NimPendingScanReport = object
    len: uint8
    payload: array[43, uint8]

  var nim_pending_scan_reports: array[NimPendingScanReportSlots,
                                      NimPendingScanReport]
  var nim_pending_scan_report_head: uint8
  var nim_pending_scan_report_tail: uint8
  var nim_pending_scan_report_count: uint8
  var nim_pending_scan_report_dropped* {.exportc.}: uint32
  var nim_scan_unsupported_count* {.exportc.}: uint32
  var nim_scan_unsupported_header* {.exportc.}: uint32
  var nim_scan_unsupported_len* {.exportc.}: uint32
  var nim_scan_unsupported_buf* {.exportc.}: uint32
  var nim_scan_unsupported_data* {.exportc.}: array[40, uint8]

  proc enqueueLeAdvertisingReport(payload: ptr uint8, len: uint8): bool =
    if payload == nil or len == 0'u8 or len.int > 43:
      return false
    if nim_pending_scan_report_count >= NimPendingScanReportSlots.uint8:
      inc nim_pending_scan_report_dropped
      return false
    let src = cast[ptr UncheckedArray[uint8]](payload)
    let slot = nim_pending_scan_report_tail.int
    nim_pending_scan_reports[slot].len = len
    for i in 0 ..< len.int:
      nim_pending_scan_reports[slot].payload[i] = src[i]
    nim_pending_scan_report_tail =
      uint8((nim_pending_scan_report_tail.uint32 + 1'u32) mod
      NimPendingScanReportSlots.uint32)
    inc nim_pending_scan_report_count
    true

  proc pendingScanReportsReady(): bool {.inline.} =
    nim_pending_scan_report_count != 0'u8 and onchiphci_recv_cb != nil

  proc bleControllerDrainScanReports*() {.exportc, cdecl.} =
    discard drainNimInitPeerComplete()
    var drained = 0'u32
    while pendingScanReportsReady() and drained < BleScanReportDrainLimit:
      let slot = nim_pending_scan_report_head.int
      let reportLen = nim_pending_scan_reports[slot].len
      sendLeMetaPayload(addr nim_pending_scan_reports[slot].payload[0],
                        reportLen)
      nim_pending_scan_report_head =
        uint8((nim_pending_scan_report_head.uint32 + 1'u32) mod
              NimPendingScanReportSlots.uint32)
      dec nim_pending_scan_report_count
      inc drained
    if pendingScanReportsReady():
      inc nim_ble_scan_report_yield_count
      nim_ble_scan_report_yield_pending = nim_pending_scan_report_count.uint32

  proc scanEventTypeFromPdu(pduType: uint8): uint8 =
    case pduType
    of 0x00'u8: 0x00'u8 # ADV_IND
    of 0x02'u8: 0x03'u8 # ADV_NONCONN_IND
    of 0x04'u8: 0x04'u8 # SCAN_RSP
    of 0x06'u8: 0x02'u8 # ADV_SCAN_IND
    else: 0xFF'u8

  proc sendLeAdvertisingReportFromRxDesc(header: uint16, buf: uint16) =
    if onchiphci_recv_cb == nil or not nim_scan_enabled:
      return
    let pduType = uint8(header and 0x000F'u16)
    let eventType = scanEventTypeFromPdu(pduType)
    if eventType == 0xFF'u8:
      return
    let pduLen = int((header shr 8) and 0x003F'u16)
    if pduLen < 6:
      return
    let dataLen = pduLen - 6
    if dataLen > 31:
      return
    let advPdu = btbleAdvPduAt(buf)
    var evt: array[43, uint8]
    evt[0] = 0x02'u8 # LE Advertising Report
    evt[1] = 0x01'u8 # one report
    evt[2] = eventType
    evt[3] = uint8((header shr 6) and 0x0001'u16)
    for i in 0 ..< 6:
      evt[4 + i] = advPdu.advA.data[i]
    evt[10] = dataLen.uint8
    for i in 0 ..< dataLen:
      evt[11 + i] = advPdu.data[i]
    evt[11 + dataLen] = 0x7F'u8 # RSSI unavailable.
    when bl808BleNimPureCentral:
      if (nim_scan_params[0] and 0x01'u8) != 0'u8 and
          (pduType == 0x00'u8 or pduType == 0x04'u8 or pduType == 0x06'u8):
        nim_scan_req_peer_addr_type =
          uint32((header shr 6) and 0x0001'u16)
      let hintSlot =
        (nim_scan_peer_hint_write_index mod NimScanPeerHintSlots.uint32).int
      nim_scan_peer_hint_addr0[hintSlot] =
        uint32(evt[4]) or
        (uint32(evt[5]) shl 8) or
        (uint32(evt[6]) shl 16) or
        (uint32(evt[7]) shl 24)
      nim_scan_peer_hint_addr1[hintSlot] =
        uint32(evt[8]) or (uint32(evt[9]) shl 8)
      nim_scan_peer_hint_type[hintSlot] = uint32(evt[3] and 0x01'u8)
      nim_scan_peer_hint_channel_index[hintSlot] =
        nim_scan_last_channel_index mod 3'u32
      nim_scan_peer_hint_adv_channel[hintSlot] = nim_scan_last_adv_channel
      nim_scan_peer_hint_write_index = nim_scan_peer_hint_write_index + 1'u32
    discard enqueueLeAdvertisingReport(addr evt[0], uint8(12 + dataLen))
when defined(bl808m0):
  proc noteUnsupportedScanPdu(header: uint16, buf: uint16) =
    let pduLen = int((header shr 8) and 0x003F'u16)
    let copyLen =
      if pduLen > nim_scan_unsupported_data.len:
        nim_scan_unsupported_data.len
      else:
        pduLen
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    inc nim_scan_unsupported_count
    nim_scan_unsupported_header = header.uint32
    nim_scan_unsupported_len = copyLen.uint32
    nim_scan_unsupported_buf = buf.uint32
    for i in 0 ..< copyLen:
      nim_scan_unsupported_data[i] = read8(payloadBase + i.uint32)

proc initBtbleTimeRegisters() =
  regWrite((BLE_BASE + 0x000'u32).uint,
           regRead((BLE_BASE + 0x000'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x000'u32).uint)
  # Core reset initializes timekeeping only; activity-specific code arms the
  # BTBLE status sources when advertising or connection scheduling starts.
  writeBtbleInterruptMask(0)
  regWrite((BLE_BASE + 0x020'u32).uint, 0xFFFFFFFF'u32)
  regWrite((BLE_BASE + 0x03C'u32).uint, 0x14829015'u32)
  regWrite((BLE_BASE + 0x0E0'u32).uint, 0x011800C8'u32)

proc currentBtbleTime(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
  regRead((BLE_BASE + 0x100'u32).uint) and 0x0FFFFFFF'u32

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  var nim_lld_rx_desc_idx* {.exportc.}: uint8
  var nim_lld_rx_desc_active* {.exportc.}: uint8
  var nim_lld_rx_check_count* {.exportc.}: uint32
  var nim_lld_rx_check_hit_count* {.exportc.}: uint32
  var nim_lld_rx_check_miss_count* {.exportc.}: uint32
  var nim_lld_rx_free_count* {.exportc.}: uint32
  var nim_lld_rx_last_idx* {.exportc.}: uint32
  var nim_lld_rx_last_env_idx* {.exportc.}: uint32
  var nim_lld_rx_last_status* {.exportc.}: uint32
  var nim_lld_rx_last_header* {.exportc.}: uint32
  var nim_lld_rx_last_meta* {.exportc.}: uint32

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  var nim_sch_prog_fifo_count* {.exportc: "nim_vendor_sch_prog_fifo_count".}: uint32
  var nim_sch_prog_skip_count* {.exportc: "nim_vendor_sch_prog_skip_count".}: uint32
  var nim_arb_sw_count* {.exportc.}: uint32
  var nim_arb_event_start_count* {.exportc.}: uint32
  when defined(bl808BleBridgeDiag):
    var nim_bridge_stage* {.exportc.}: uint32
    var nim_sch_call_count* {.exportc.}: uint32
    var nim_sch_call_last_slot* {.exportc.}: uint32
    var nim_sch_call_last_event* {.exportc.}: uint32
    var nim_sch_call_last_cb* {.exportc.}: uint32
    var nim_sch_call_last_ctx* {.exportc.}: uint32
    var nim_sch_call_return_count* {.exportc.}: uint32
const
  RwipDefaultProgramDelaySlots = 3'u16
  RwipDefaultMaxDriftPpm = 500'u32

when defined(bl808m0) and
    bl808BleNimPureCentral and
    not bl808BleNimConnectionEnabled:
  var co_rate_to_phy* {.exportc.}: array[5, uint8] =
    [1'u8, 2, 3, 3, 0]
  var co_sca2ppm* {.exportc.}: array[8, uint16] =
    [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
  var lld_env* {.exportc.}: array[56, uint8]
  var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16]
  var rwip_priority* {.exportc.}: array[32, uint8] =
    [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x08,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = RwipDefaultProgramDelaySlots

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  var co_rate_to_phy* {.exportc.}: array[5, uint8] =
    [1'u8, 2, 3, 3, 0]
  var co_sca2ppm* {.exportc.}: array[8, uint16] =
    [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
  var lld_env* {.exportc.}: array[56, uint8]
  var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16] =
    [0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16,
     0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16]
  var rwip_priority* {.exportc.}: array[32, uint8] =
    [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x08,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = RwipDefaultProgramDelaySlots
  var nim_rand_state: uint32 = 0x12345678'u32

  proc rand*(): cint {.exportc, cdecl.} =
    nim_rand_state = nim_rand_state * 1103515245'u32 + 12345'u32
    cint((nim_rand_state shr 16) and 0x7FFF'u32)

  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    result = currentBtbleTime()
  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    RwipDefaultMaxDriftPpm

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    RwipDefaultMaxDriftPpm

  proc lld_rx_timing_compute*(baseClock: uint32, clock: ptr uint32,
                              fine: ptr uint32, peerDrift: uint32,
                              rate: uint8, winSize: uint32): uint32
      {.exportc, cdecl.} =
    if clock == nil or fine == nil:
      return winSize
    const btClockMask = 0x0FFFFFFF'u32
    let clockNow = clock[]
    let elapsedSlots = (clockNow - baseClock) and btClockMask
    let drift = rwip_current_drift_get() + peerDrift
    let driftHalfUs = ((elapsedSlots * drift) div 1600'u32) + 32'u32
    var adjustedWin = winSize + (driftHalfUs shl 1)
    if adjustedWin < 28'u32:
      adjustedWin = 28'u32

    let halfWin = adjustedWin shr 1
    let coarseAdjust = halfWin div 625'u32
    clock[] = (clockNow - coarseAdjust) and btClockMask
    var fineValue =
      int32(fine[]) - int32(halfWin) + int32(coarseAdjust * 625'u32)
    fine[] = cast[uint32](fineValue)
    if fineValue < 0'i32:
      clock[] = (clock[] - 1'u32) and btClockMask
      fineValue += 625'i32
      fine[] = cast[uint32](fineValue)

    let phy =
      if rate.int < co_rate_to_phy.len: co_rate_to_phy[rate.int]
      else: co_rate_to_phy[0]
    if phy == 3'u8:
      adjustedWin + 196'u32
    else:
      adjustedWin

  proc rwip_channel_assess_ble*(channel: uint8, rssi: int8) {.exportc, cdecl.} =
    discard channel
    discard rssi

  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when defined(bl808m0) and bl808BleNimPureCentral and
    not bl808BleNimConnectionEnabled:
  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  proc initNimRwipRfTable() =
    discard c_memset(addr rwip_rf[0], 0, rwip_rf.len.csize_t)
    btble_rf_init(addr rwip_rf[0])

const
  BtbleRxDescRingBaseOffset = 0x458'u32
  BtbleRxDescRingStride = 0x20'u32
  BtbleRxDescRingCount = 8'u32
  BtbleRxDescDone = 0x8000'u16
  BtbleRxDescLinkMask = 0x7FFF'u16

proc btbleRxDescOffset(idx: uint32): uint32 {.inline.} =
  BtbleRxDescRingBaseOffset +
    (idx and (BtbleRxDescRingCount - 1'u32)) * BtbleRxDescRingStride

template btbleRxDescAt(descAddr: uint32): ptr BtbleRxDescView =
  cast[ptr BtbleRxDescView](descAddr.uint)

proc btbleRxDescStatus(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).status)

proc btbleRxDescHeader(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).header)

proc btbleRxDescClock(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).rxClock)

proc btbleRxDescMeta(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).meta)

proc btbleRxDescDataOffset(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).dataOffset)

proc btbleRxDescSetStatus(descAddr: uint32; status: uint16) {.inline.} =
  volatileStore(addr btbleRxDescAt(descAddr).status, status)

proc btbleRxDescSetDataOffset(descAddr: uint32; offset: uint16) {.inline.} =
  volatileStore(addr btbleRxDescAt(descAddr).dataOffset, offset)

proc btbleRxDescReset(descAddr, nextOffset, dataOffset: uint32) {.inline.} =
  let desc = btbleRxDescAt(descAddr)
  volatileStore(addr desc.status, uint16((nextOffset shr 2) and 0xFFFF'u32))
  volatileStore(addr desc.reserved02, 0'u16)
  volatileStore(addr desc.header, 0'u16)
  volatileStore(addr desc.timing0, 0'u16)
  volatileStore(addr desc.rxClock, 0'u16)
  volatileStore(addr desc.timing1, 0'u16)
  volatileStore(addr desc.meta, 0'u16)
  for i in 0 ..< desc.reserved0E.len:
    volatileStore(addr desc.reserved0E[i], 0'u8)
  volatileStore(addr desc.dataOffset, uint16(dataOffset and 0xFFFF'u32))
  for i in 0 ..< desc.reserved16.len:
    volatileStore(addr desc.reserved16[i], 0'u8)

proc btbleRxDescClearDone(descAddr: uint32; status: uint16) {.inline.} =
  btbleRxDescSetStatus(descAddr, status and not BtbleRxDescDone)

proc btbleRxDescReleaseLink(descAddr: uint32; status: uint16) {.inline.} =
  btbleRxDescSetStatus(descAddr, status and BtbleRxDescLinkMask)

proc btbleRxDescPtr(idx: uint32): uint32 {.inline.} =
  btbleRxDescOffset(idx) shr 2

template btbleLegacyTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView =
  cast[ptr BtbleConnTxDescView](descAddr.uint)

proc btbleLegacyTxDescProgram(descAddr: uint32; status, header,
                              dataOffset: uint16) {.inline.} =
  let desc = btbleLegacyTxDescAt(descAddr)
  volatileStore(addr desc.status, status)
  volatileStore(addr desc.header, header)
  volatileStore(addr desc.dataOffset, dataOffset)
  for i in 0 ..< desc.reserved06.len:
    volatileStore(addr desc.reserved06[i], 0'u8)

template btbleAccessWordsAt(emAddr: uint32): ptr BtbleAccessAddressWordsView =
  cast[ptr BtbleAccessAddressWordsView](emAddr.uint)

proc writeBtbleDefaultAccessWords(emAddr: uint32) {.inline.} =
  let words = btbleAccessWordsAt(emAddr)
  volatileStore(addr words.accessAddrLow, 0xBED6'u16)
  volatileStore(addr words.accessAddrHigh, 0x8E89'u16)
  volatileStore(addr words.crcInitLow, 0x5555'u16)
  volatileStore(addr words.crcInitHigh, 0x0055'u16)

proc btbleProgramSlotAddr(slot: uint32): uint32 {.inline.} =
  BTBLE_EM_BASE + slot * 0x10'u32

template btbleProgramSlotAt(slot: uint32): ptr BtbleProgramSlotView =
  cast[ptr BtbleProgramSlotView](btbleProgramSlotAddr(slot).uint)

proc btbleProgramSlotControl(slot: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleProgramSlotAt(slot).control)

proc btbleProgramSlotTarget(slot: uint32): uint32 {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileLoad(addr view.targetLow).uint32 or
    ((volatileLoad(addr view.targetHigh).uint32 and 0x0FFF'u32) shl 16)

proc btbleProgramSlotTail(slot: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleProgramSlotAt(slot).tail)

proc btbleProgramSlotSetControl(slot: uint32; value: uint16) {.inline.} =
  volatileStore(addr btbleProgramSlotAt(slot).control, value)

proc btbleProgramSlotSetDisabled(slot: uint32) {.inline.} =
  let control = btbleProgramSlotControl(slot)
  btbleProgramSlotSetControl(slot, (control and not 0x0038'u16) or 0x0018'u16)

proc btbleProgramSlotSetTail(slot: uint32; value: uint16) {.inline.} =
  volatileStore(addr btbleProgramSlotAt(slot).tail, value)

proc btbleProgramSlotClear(slot: uint32; tail: uint16) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.control, 0'u16)
  volatileStore(addr view.targetLow, 0'u16)
  volatileStore(addr view.targetHigh, 0'u16)
  volatileStore(addr view.fineBackoff, 0'u16)
  volatileStore(addr view.emPtr, 0'u16)
  volatileStore(addr view.duration, 0'u16)
  volatileStore(addr view.rates, 0'u16)
  volatileStore(addr view.tail, tail)

proc btbleProgramSlotProgram(slot: uint32; target: uint32; fineBackoff,
                             duration, rates, tail, control,
                             emPtr: uint16; writeControlAndPtr: bool) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.targetLow, uint16(target and 0xFFFF'u32))
  volatileStore(addr view.targetHigh, uint16((target shr 16) and 0x0FFF'u32))
  volatileStore(addr view.fineBackoff, fineBackoff)
  volatileStore(addr view.duration, duration)
  volatileStore(addr view.rates, rates)
  volatileStore(addr view.tail, tail)
  if writeControlAndPtr:
    volatileStore(addr view.control, control)
    volatileStore(addr view.emPtr, emPtr)

proc btbleProgramSlotProgramRaw(slot: uint32; control, targetLow, targetHigh,
                                fineBackoff, emPtr, duration, rates,
                                tail: uint16) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.control, control)
  volatileStore(addr view.targetLow, targetLow)
  volatileStore(addr view.targetHigh, targetHigh)
  volatileStore(addr view.fineBackoff, fineBackoff)
  volatileStore(addr view.emPtr, emPtr)
  volatileStore(addr view.duration, duration)
  volatileStore(addr view.rates, rates)
  volatileStore(addr view.tail, tail)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  proc clearBtbleProgramSlots() =
    for slot in 0'u32 ..< 18'u32:
      btbleProgramSlotClear(slot,
        uint16((btbleAdvSlotTail(slot) shr 16) and 0xFFFF'u32))

proc writeBtbleRxDescHeadIndex(idx: uint32) {.inline.} =
  regWrite((BLE_BASE + 0x828'u32).uint, btbleRxDescPtr(idx))

proc resetBtbleAdvRxRing() =
  ## Drop advertising-channel RX descriptors from a previous scanner,
  ## advertiser, or initiator role.  The low half-word is both the descriptor
  ## link pointer and the hardware-owned done bit, so restore the BL808 ring
  ## link value instead of blindly zeroing it.
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    lld_env[14] = 0
    lld_env[16] = 0
    nim_lld_rx_desc_idx = 0
    nim_lld_rx_desc_active = 0
  for i in 0'u32 ..< 8'u32:
    let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)
    let nextOff = btbleRxDescOffset(i + 1'u32)
    let rxBuf = 0x0B0D'u32 + i * 0x104'u32
    btbleRxDescReset(desc, nextOff, rxBuf)

proc prepareBtbleConnectionRxRingForHandoff() =
  ## The vendor lld_adv_frm_isr frees the consumed CONNECT_IND descriptor and
  ## then hands the same live RX ring to lld_con_start.  Do not reset the ring or
  ## force BTBLE+0x828 back to descriptor zero here; the hardware head may have
  ## already advanced past advertising-channel traffic.
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    nim_lld_rx_desc_idx = lld_env[14] and 0x07'u8
    nim_lld_rx_desc_active = 0

proc currentBtbleHalfUs(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
  let base = regRead((BLE_BASE + 0x100'u32).uint) and 0x0000FFFF'u32
  let fineRaw = regRead((BLE_BASE + 0x104'u32).uint) and 0x0000FFFF'u32
  let fine =
    if fineRaw <= 0x270'u32: 0x270'u32 - fineRaw
    else: 0'u32
  ((base * 625'u32 + fine) shr 1) and 0x0FFFFFFF'u32

proc requestBtbleSwInterrupt() =
  ## Queue deferred BLE work. Polled M0 builds service this from bflbble_isr()
  ## without raising a CLIC interrupt.
  nim_btble_sw_pending = true
  when not (defined(bl808m0) and not bl808BleNimRuntimeClicIrq):
    regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntSw)
    enableBtbleInterruptMaskBits(BtbleIntSw)
    regUpdate(BLE_BASE + 0x000'u32, 0x08000000'u32, 0x08000000'u32)

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  proc schProgWrite16(off: int, value: uint16) =
    nim_sch_prog[off] = uint8(value and 0x00FF'u16)
    nim_sch_prog[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc schProgWrite32(off: int, value: uint32) =
    nim_sch_prog[off] = uint8(value and 0x000000FF'u32)
    nim_sch_prog[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    nim_sch_prog[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    nim_sch_prog[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  type
    RwipParamGet = proc(param: uint8, buf: ptr uint8,
                        len: ptr uint8): uint8 {.cdecl.}
    RwipParamSet = proc(param: uint8, buf: ptr uint8,
                        len: uint8): uint8 {.cdecl.}
    RwipParamDel = proc(param: uint8): uint8 {.cdecl.}
    RwipParam = object
      get: RwipParamGet
      set: RwipParamSet
      del: RwipParamDel

  proc rwipParamDummyGet(param: uint8, buf: ptr uint8,
                         len: ptr uint8): uint8 {.cdecl.} =
    discard param
    discard buf
    if len != nil:
      len[] = 0
    1'u8

  proc rwipParamDummySet(param: uint8, buf: ptr uint8,
                         len: uint8): uint8 {.cdecl.} =
    discard param
    discard buf
    discard len
    1'u8

  proc rwipParamDummyDel(param: uint8): uint8 {.cdecl.} =
    discard param
    1'u8

  var rwip_param* {.exportc.}: RwipParam

  proc rwip_time_get*(time: pointer) {.exportc, cdecl.} =
    if time == nil:
      return
    regWrite((BLE_BASE + 0x100'u32).uint,
             regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
    discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
    let words = cast[ptr UncheckedArray[uint32]](time)
    let fineRaw = regRead((BLE_BASE + 0x104'u32).uint) and 0x0000FFFF'u32
    let fine =
      if fineRaw <= 624'u32: 624'u32 - fineRaw
      else: 0'u32
    words[0] = regRead((BLE_BASE + 0x100'u32).uint) and 0x0FFFFFFF'u32
    words[1] = fine and 0x0000FFFF'u32
    words[2] = regRead((BLE_BASE + 0x9C4'u32).uint)

  proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask.uint32

  proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask.uint32

  proc rwip_sw_int_req*() {.exportc, cdecl.}

  when bl808BleNimSchProg:
    type SchProgCb = proc(timestamp: uint32, ctx: pointer, event: uint8) {.cdecl.}

    var schProgCb: array[16, SchProgCb]
    var schProgCtx: array[16, pointer]
    var schProgActive: array[16, uint8]
    var schProgElapsedEndTarget: array[16, uint32]
    var schProgElapsedEndArmed: array[16, uint8]
    var schProgReadIdx: uint8
    var schProgWriteIdx: uint8
    var schProgCount: uint8
    var schProgLastTime* {.exportc: "last_prog_time".}: uint32
    var skipFlag* {.exportc: "skipFlag".}: uint8
    var rwip_mac_done* {.exportc.}: uint8
    var nim_sch_prog_last_stage* {.exportc.}: uint32
    var nim_sch_prog_last_cb* {.exportc.}: uint32
    var nim_sch_prog_last_ctx* {.exportc.}: uint32
    var nim_sch_prog_last_target* {.exportc.}: uint32
    var nim_sch_prog_last_now* {.exportc.}: uint32
    var nim_sch_prog_last_slot* {.exportc.}: uint32
    var nim_sch_prog_last_intmask* {.exportc.}: uint32
    var nim_sch_prog_last_intstat* {.exportc.}: uint32
    var nim_sch_prog_elapsed_count* {.exportc: "nim_vendor_sch_prog_elapsed_count".}: uint32

    proc schProgSlotTarget(slot: uint8): uint32 {.inline.} =
      btbleProgramSlotTarget(uint32(slot and 0x0F'u8))

    proc schProgClockReached(now, target: uint32): bool {.inline.} =
      (((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32)

    proc schProgDurationSlots(durationUs: uint32): uint32 {.inline.} =
      if durationUs == 0'u32:
        1'u32
      elif durationUs < 0x8000'u32:
        max(1'u32, (durationUs + 624'u32) div 625'u32)
      else:
        max(1'u32, durationUs and 0x7FFF'u32)

    const NimBleWifiTxGuardSlots = 8'u32

    proc schProgFutureDistance(now, target: uint32): uint32 {.inline.} =
      (target - now) and 0x0FFFFFFF'u32

    proc schProgCall(idx: uint8, event: uint8) =
      let slot = idx and 0x0F'u8
      if schProgActive[slot.int] == 0:
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x52F0'u32 or uint32(event)
        return
      let cb = schProgCb[slot.int]
      let timestamp = schProgSlotTarget(slot)
      when defined(bl808BleBridgeDiag):
        nim_bridge_stage = 0x5300'u32 or uint32(event)
        inc nim_sch_call_count
        nim_sch_call_last_slot = slot.uint32
        nim_sch_call_last_event = event.uint32
        nim_sch_call_last_cb = cast[uint32](cast[uint](cb))
        nim_sch_call_last_ctx =
          cast[uint32](cast[uint](schProgCtx[slot.int]))
      if cb != nil:
        cb(timestamp, schProgCtx[slot.int], event)
        when defined(bl808BleBridgeDiag):
          inc nim_sch_call_return_count
          nim_bridge_stage = 0x5400'u32 or uint32(event)
      else:
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x53F0'u32 or uint32(event)

    proc schProgFindNextRead(fromSlot: uint8, untilSlot: uint8): uint8 =
      var slot = fromSlot and 0x0F'u8
      let stop = untilSlot and 0x0F'u8
      while slot != stop:
        slot = (slot + 1'u8) and 0x0F'u8
        if schProgActive[slot.int] != 0:
          return slot
      stop

    proc schProgSetEntry(slot: uint8, cbRaw: uint32, ctxRaw: uint32) =
      let s = slot and 0x0F'u8
      schProgCb[s.int] = cast[SchProgCb](cbRaw.uint)
      schProgCtx[s.int] = cast[pointer](ctxRaw.uint)
      schProgActive[s.int] = 1

    proc sch_prog_rx_isr*(idx: uint8) {.exportc, cdecl.} =
      schProgCall(idx, 2'u8)

    proc sch_prog_tx_isr*(idx: uint8) {.exportc, cdecl.} =
      schProgCall(idx, 3'u8)

    proc sch_prog_skip_isr*(idx: uint8) {.exportc, cdecl.} =
      let slot = idx and 0x0F'u8
      if schProgActive[slot.int] != 0:
        schProgCall(slot, 4'u8)
        schProgElapsedEndArmed[slot.int] = 0
        if schProgReadIdx == slot and skipFlag == 0'u8:
          schProgReadIdx = (slot + 1'u8) and 0x0F'u8
        schProgActive[slot.int] = 0
        if schProgCount != 0:
          dec schProgCount
        if schProgCount == 1'u8 and skipFlag == 0'u8:
          schProgWriteIdx = (schProgReadIdx + 1'u8) and 0x0F'u8
          return
      elif schProgCount == 1'u8 and skipFlag == 0'u8:
        schProgWriteIdx = (schProgReadIdx + 1'u8) and 0x0F'u8
        return
      if schProgCount == 0:
        rwip_prevent_sleep_clear(64'u16)

    proc schProgFinishSlot(slot: uint8, event: uint8) =
      schProgElapsedEndArmed[slot.int] = 0
      schProgCall(slot, event)
      if schProgActive[slot.int] != 0:
        schProgActive[slot.int] = 0
        if schProgCount != 0:
          dec schProgCount
      schProgReadIdx = schProgFindNextRead(slot, schProgWriteIdx)
      if schProgCount == 0:
        rwip_prevent_sleep_clear(64'u16)

    proc sch_prog_end_isr*(idx: uint8) {.exportc, cdecl.} =
      let slot = idx and 0x0F'u8
      let rawStatus = btbleProgramSlotControl(uint32(slot))
      let status = (rawStatus shr 3) and 0x0007'u16
      let event =
        if status == 3'u16: 0'u8
        elif status == 4'u16: 1'u8
        elif status == 5'u16: 7'u8
        else: 0xFF'u8
      schProgFinishSlot(slot, event)

    proc rwip_mac_done_set*() {.exportc, cdecl.} =
      rwip_mac_done = 1'u8

    proc sch_prog_fifo_isr*() {.exportc, cdecl.} =
      let stat = regRead(BLE_BASE + 0x024'u32)
      let eventSlot = uint8((stat shr 24) and 0x0F'u32)
      let skipSlot = uint8((stat shr 28) and 0x0F'u32)
      if (stat and 0x00000008'u32) != 0:
        sch_prog_tx_isr(eventSlot)
      if (stat and 0x00000010'u32) != 0:
        sch_prog_rx_isr(eventSlot)
      if (stat and 0x00000004'u32) != 0:
        sch_prog_skip_isr(skipSlot)
      if (stat and 0x00000002'u32) != 0:
        sch_prog_end_isr(eventSlot)
        rwip_mac_done_set()

    proc sch_prog_elapsed_isr*() {.exportc, cdecl.} =
      let now = currentBtbleTime()
      for rawSlot in 0'u8 ..< 16'u8:
        let slot = rawSlot and 0x0F'u8
        if schProgActive[slot.int] == 0 or
            schProgElapsedEndArmed[slot.int] == 0:
          continue
        if not schProgClockReached(now, schProgElapsedEndTarget[slot.int]):
          continue
        inc nim_sch_prog_elapsed_count
        schProgFinishSlot(slot, 0'u8)
        rwip_mac_done_set()

    proc nim_ble_coex_wifi_tx_window_enter*(): uint32 {.exportc, cdecl.} =
      ## Called by the WiFi firmware while it owns the shared RF/PTA fabric.
      ## Return 1 only when WiFi acquires an idle BLE scheduler gap. If a BLE
      ## slot is already active, skip/reschedule it and make WiFi retry later
      ## instead of transmitting while the shared RF may still be busy.
      inc nim_ble_wifi_tx_window_enter_count
      nim_ble_wifi_tx_window_last_intmask =
        regRead(BLE_BASE + BTBLE_INTMASK_OFFSET)
      nim_ble_wifi_tx_window_last_intstat =
        regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
      if nim_ble_wlcoex_enabled == 0'u32:
        return 1'u32
      if nim_ble_wifi_tx_window_active != 0'u32:
        return 1'u32
      writeBtbleInterruptMask(0)
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint,
               regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
      let now = currentBtbleTime()
      var skipped = 0'u32
      var nearFuture = 0'u32
      for rawSlot in 0'u8 ..< 16'u8:
        let slot = rawSlot and 0x0F'u8
        if schProgActive[slot.int] != 0:
          let target = schProgSlotTarget(slot)
          let untilTarget = schProgFutureDistance(now, target)
          if untilTarget < 0x08000000'u32 and
              untilTarget > NimBleWifiTxGuardSlots:
            continue
          if untilTarget < 0x08000000'u32:
            inc nearFuture
            continue
          btbleProgramSlotSetDisabled(uint32(slot))
          schProgElapsedEndArmed[slot.int] = 0
          inc nim_ble_wifi_tx_window_skip_count
          inc skipped
          sch_prog_skip_isr(slot)
      if skipped != 0'u32 or nearFuture != 0'u32:
        writeBtbleInterruptMask(BtbleIntConnection)
        if skipped != 0'u32:
          inc nim_ble_wifi_tx_window_resume_count
          rwip_sw_int_req()
        return 0'u32
      nim_ble_wifi_tx_window_active = 1'u32
      1'u32

    proc nim_ble_coex_wifi_tx_window_leave*() {.exportc, cdecl.} =
      ## Re-enable BLE scheduling after the WiFi MAC reports TX confirmation.
      inc nim_ble_wifi_tx_window_leave_count
      if nim_ble_wifi_tx_window_active == 0'u32:
        return
      nim_ble_wifi_tx_window_active = 0'u32
      writeBtbleInterruptMask(BtbleIntConnection)
      if nim_ble_wlcoex_enabled != 0'u32:
        inc nim_ble_wifi_tx_window_resume_count
        rwip_sw_int_req()

    proc sch_prog_init*(initType: uint8) {.exportc, cdecl.} =
      if initType < 2'u8 or initType > 3'u8:
        return
      discard c_memset(addr schProgCb[0], 0, sizeof(schProgCb).csize_t)
      discard c_memset(addr schProgCtx[0], 0, sizeof(schProgCtx).csize_t)
      discard c_memset(addr schProgActive[0], 0,
                       sizeof(schProgActive).csize_t)
      discard c_memset(addr schProgElapsedEndTarget[0], 0,
                       sizeof(schProgElapsedEndTarget).csize_t)
      discard c_memset(addr schProgElapsedEndArmed[0], 0,
                       sizeof(schProgElapsedEndArmed).csize_t)
      schProgReadIdx = 0
      schProgWriteIdx = 0
      schProgCount = 0
      nimSchProgSkipIndex = 0
      schProgLastTime = 0
      skipFlag = 0
      rwip_mac_done = 0
      nim_sch_prog_last_stage = 0
      nim_sch_prog_last_cb = 0
      nim_sch_prog_last_ctx = 0
      nim_sch_prog_last_target = 0
      nim_sch_prog_last_now = 0
      nim_sch_prog_last_slot = 0
      nim_sch_prog_last_intmask = 0
      nim_sch_prog_last_intstat = 0
      nim_sch_prog_elapsed_count = 0
      for slot in 0'u32 ..< 16'u32:
        btbleProgramSlotSetDisabled(slot)

    proc sch_prog_push*(prog: pointer) {.exportc, cdecl.} =
      if prog == nil:
        return
      let irqState = btbleIrqSave()
      defer:
        btbleIrqRestore(irqState)
      nim_sch_prog_last_stage = 0x1000'u32
      let req = cast[ptr SchProgRequestView](prog)
      req.primaryType = req.primaryType shr 3
      req.rate0 = req.rate0 shr 3
      req.rate1 = req.rate1 shr 3

      let slot = schProgWriteIdx and 0x0F'u8
      let cbRaw = req.callback
      let target = req.targetTime
      let fine = req.fineTime
      let dur = req.duration
      let ctxRaw = req.context
      nim_sch_prog_last_stage = 0x1010'u32
      nim_sch_prog_last_cb = cbRaw
      nim_sch_prog_last_ctx = ctxRaw
      nim_sch_prog_last_target = target
      nim_sch_prog_last_slot = slot.uint32
      nim_sch_prog_last_intmask = regRead(BLE_BASE + BTBLE_INTMASK_OFFSET)
      nim_sch_prog_last_intstat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)

      var now: array[3, uint32]
      rwip_time_get(addr now[0])
      nim_sch_prog_last_stage = 0x1020'u32
      nim_sch_prog_last_now = now[0]
      if ((now[0] + 1'u32) >= target) or (target == schProgLastTime):
        nim_sch_prog_last_stage = 0x1100'u32
        schProgLastTime = target
        schProgSetEntry(slot, cbRaw, ctxRaw)
        nimSchProgSkipIndex = slot.uint32
        inc schProgCount
        skipFlag = 1'u8
        rwip_prevent_sleep_set(64'u16)
        nim_sch_prog_last_stage = 0x1110'u32
        rwip_sw_int_req()
        nim_sch_prog_last_stage = 0x1120'u32
        return

      nim_sch_prog_last_stage = 0x1200'u32
      let emPtr = uint16((uint32(req.eventIndex) * 0x94'u32 + 0x0120'u32) shr 2)
      let crowded =
        if ((uint32(schProgWriteIdx) - uint32(schProgReadIdx)) and 0x0F'u32) >=
            14'u32: 1'u16
        else: 0'u16
      var ctrl0 = (crowded shl 10) or
                  (uint16(req.ctrlType) shl 8)
      let primaryType =
        if req.primaryType > 31'u8: 31'u16
        else: uint16(req.primaryType)
      if req.hasAux != 0'u8:
        ctrl0 = ctrl0 or (primaryType shl 11) or
                (uint16(req.auxRate) shl 9) or
                (uint16(req.auxControl) shl 7) or 0x0042'u16
      else:
        ctrl0 = ctrl0 or (primaryType shl 11) or 0x0002'u16
      let durHalf =
        if dur < 0x8000'u32:
          uint16(((dur + 1'u32) shr 1) and 0xFFFF'u32)
        else:
          uint16((((dur + 625'u32) div 625'u32) or 0xFFFF8000'u32) and
                 0xFFFF'u32)
      let fineBackoff =
        if fine <= 624'u16: 624'u16 - fine
        else: 0'u16
      let rate0 =
        if req.rate0 > 31'u8: 31'u16
        else: uint16(req.rate0)
      let rate1 =
        if req.rate1 > 31'u8: 31'u16
        else: uint16(req.rate1)
      let slotU32 = uint32(slot)
      let tail = (btbleProgramSlotTail(slotU32) and 0xE0FF'u16) or
                 (uint16(req.tail) shl 8)

      schProgSetEntry(slot, cbRaw, ctxRaw)
      schProgLastTime = target
      nim_sch_prog_last_stage = 0x1210'u32

      btbleProgramSlotProgram(slotU32, target, fineBackoff, durHalf,
        rate0 or (rate1 shl 8), tail, ctrl0, emPtr, req.noBackoff == 0'u8)

      nim_sch_prog_last_stage = 0x1220'u32
      regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or slot.uint32)
      nim_sch_prog_last_stage = 0x1230'u32
      schProgWriteIdx = (slot + 1'u8) and 0x0F'u8
      inc schProgCount
      schProgElapsedEndTarget[slot.int] =
        (target + schProgDurationSlots(dur) + 1'u32) and 0x0FFFFFFF'u32
      schProgElapsedEndArmed[slot.int] = 1
      rwip_prevent_sleep_set(64'u16)
      if skipFlag != 0:
        nim_sch_prog_last_stage = 0x1240'u32
        rwip_sw_int_req()
        nim_sch_prog_last_stage = 0x1250'u32
      else:
        nim_sch_prog_last_stage = 0x1260'u32

    proc nimSchProgInit(initType: uint8) {.cdecl.} =
      sch_prog_init(initType)

    proc nimSchProgFifoIsr() {.cdecl.} =
      sch_prog_fifo_isr()

    proc nimSchProgSkipIsr(idx: uint8) {.cdecl.} =
      sch_prog_skip_isr(idx)

    proc nimSchProgPush(prog: pointer) {.cdecl.} =
      sch_prog_push(prog)

    proc nimSchProgElapsedIsr() {.cdecl.} =
      sch_prog_elapsed_isr()

  proc serviceNimArbTimer() =
    discard

  proc rwip_sw_int_req*() {.exportc, cdecl.} =
    inc nim_arb_sw_count
    requestBtbleSwInterrupt()

const bl808BleNimSyntheticCentral* {.booldefine.}: bool = false
const bl808BleNimSyntheticCentralComplete* {.booldefine.}: bool = false
const bl808BleNimSyntheticPeripheral* {.booldefine.}: bool = false

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  const bl808BleNimConAnchorBiasSlots* {.intdefine.}: int = 0
  const bl808BleNimConTimingClockBiasSlots* {.intdefine.}: int = 0
  const bl808BleNimConTimingPath* {.booldefine.}: bool = true
  const bl808BleNimDeferConnectInd* {.booldefine.}: bool = true
  const bl808BleNimKeepaliveAcl* {.booldefine.}: bool = true
  const bl808BleNimLlcStartInitialLlcp* {.booldefine.}: bool = false
  const bl808BleNimStartupLlcpRetries* {.intdefine.}: int = 8
  const bl808BleNimStartupLlcpDelayServices* {.intdefine.}: int = 0

  var nim_conn_started: bool
  var nim_connect_ind_pending* {.exportc.}: uint32
  var nim_connect_ind_queued_count* {.exportc.}: uint32
  var nim_connect_ind_service_count* {.exportc.}: uint32
  var nim_connect_ind_return_count* {.exportc.}: uint32
  var nim_connect_ind_pending_desc_idx: uint8
  var nim_connect_ind_pending_payload: array[34, uint8]
  var nim_connect_ind_work_payload: array[34, uint8]
  var nim_connect_ind_pending_header: uint16
  var nim_connect_ind_pending_rx_clock: uint32
  var nim_connect_ind_pending_rx_fine: uint16
  var nim_conn_params: array[64, uint8]
  var nim_llc_msg* {.exportc: "nim_vendor_llc_msg".}: array[64, uint8]
  var nim_llc_env_storage: array[0x8C, uint8]
  var nim_llc_status* {.exportc.}: uint32
  var nim_llcp_rx_count* {.exportc.}: uint32
  var nim_llcp_tx_count* {.exportc.}: uint32
  var nim_llcp_tx_pending* {.exportc.}: uint32
  var nim_llcp_tx_queued* {.exportc.}: uint32
  var nim_llcp_tx_dropped* {.exportc.}: uint32
  var nim_llcp_startup_tx_count* {.exportc.}: uint32
  var nim_llcp_startup_deferred_count* {.exportc.}: uint32
  var nim_llcp_last_opcode* {.exportc.}: uint32
  var nim_llcp_last_status* {.exportc.}: uint32
  var nim_llcp_rx_log* {.exportc.}: array[8, uint32]
  var nim_llcp_tx_log* {.exportc.}: array[8, uint32]
  var nim_llcp_rx_log_index* {.exportc.}: uint32
  var nim_llcp_tx_log_index* {.exportc.}: uint32
  var nim_llcp_peer_features* {.exportc.}: array[2, uint32]
  var nim_llcp_used_features* {.exportc.}: array[2, uint32]
  var nim_llcp_rx_malformed_count* {.exportc.}: uint32
  var nim_llcp_rx_malformed_last* {.exportc.}: uint32
  var nim_llcp_alloc_count* {.exportc.}: uint32
  var nim_llcp_free_count* {.exportc.}: uint32
  var nim_llcp_alloc_last_len* {.exportc.}: uint32
  var nim_llcp_alloc_last_ptr* {.exportc.}: uint32
  var nim_llcp_alloc_last_emoff* {.exportc.}: uint32
  var nim_llcp_alloc_last_len_field* {.exportc.}: uint32
  var nim_llcp_free_last_raw* {.exportc.}: uint32
  var nim_llcp_free_manual_count* {.exportc.}: uint32
  var nim_llcp_free_heap_count* {.exportc.}: uint32
  var nim_acl_empty_tx_count* {.exportc.}: uint32
  var nim_acl_empty_tx_pending* {.exportc.}: uint32
  var nim_acl_empty_tx_queued: uint32
  var nim_acl_empty_last_status* {.exportc.}: uint32
  var nim_acl_host_tx_count* {.exportc.}: uint32
  var nim_acl_host_tx_pending* {.exportc.}: uint32
  var nim_acl_host_tx_complete_count* {.exportc.}: uint32
  var nim_acl_host_tx_reject_count* {.exportc.}: uint32
  var nim_acl_rx_count* {.exportc.}: uint32
  var nim_acl_rx_drop_count* {.exportc.}: uint32
  var nim_conn_last_status* {.exportc.}: uint32
  var nim_conn_last_rx_clock* {.exportc.}: uint32
  var nim_conn_last_rx_fine* {.exportc.}: uint32
  var nim_conn_last_anchor* {.exportc.}: uint32
  var nim_conn_last_win_offset* {.exportc.}: uint32
  var nim_conn_last_interval* {.exportc.}: uint32
  var nim_conn_last_timeout* {.exportc.}: uint32
  var nim_conn_last_access_addr* {.exportc.}: uint32
  var nim_conn_last_crcinit* {.exportc.}: uint32
  var nim_connect_desc_fields* {.exportc.}: array[4, uint32]
  var nim_connect_timing_snapshot* {.exportc.}: array[8, uint32]
  var nim_conn_start_return_count* {.exportc.}: uint32
  when bl808BleConnStageDiag:
    var nim_conn_stage* {.exportc: "nim_vendor_conn_stage".}: uint32
    var nim_conn_stage_ra* {.exportc: "nim_vendor_conn_stage_ra".}: uint32
    var nim_conn_stage_sp* {.exportc: "nim_vendor_conn_stage_sp".}: uint32
    var nim_conn_stage_mepc* {.exportc: "nim_vendor_conn_stage_mepc".}: uint32
    var nim_conn_stage_mcause* {.exportc: "nim_vendor_conn_stage_mcause".}: uint32
  var nim_lld_con_start_count* {.exportc.}: uint32
  var nim_lld_con_start_status* {.exportc.}: uint32
  var nim_lld_con_start_param* {.exportc.}: array[48, uint8]
  var nim_conn_start_em_snapshot* {.exportc.}: array[64, uint32]
  var nim_conn_start_rx_snapshot* {.exportc.}: array[64, uint32]
  var nim_conn_start_tx_snapshot* {.exportc.}: array[16, uint32]
  var nim_conn_start_reg_snapshot* {.exportc.}: array[8, uint32]
  var nim_conn_evt_count* {.exportc.}: uint32
  var nim_conn_evt_handle* {.exportc.}: uint32
  var nim_conn_evt_peer_a0* {.exportc.}: uint32
  var nim_conn_evt_peer_a1* {.exportc.}: uint32
  var nim_conn_evt_peer_type* {.exportc.}: uint32
  var nim_conn_evt_reported: bool
  var nim_disc_evt_count* {.exportc.}: uint32
  var nim_disc_evt_reason* {.exportc.}: uint32
  var nim_disc_evt_source* {.exportc.}: uint32
  var nim_llcp_tx_buf: array[12, uint8]
  var nim_acl_host_tx_buf: array[8, uint8]
  type
    NimLlcpState = object
      versionProcedureStarted: bool
      startupAttemptsLeft: uint8
      startupDelayServices: uint8
      remoteFeaturesEventPending: bool
      peerFeaturesKnown: bool
      peerFeatures: uint64
      dataLengthKnown: bool
      localTxOctets: uint16
      localTxTime: uint16
      peerMaxRxOctets: uint16
      peerMaxRxTime: uint16
      peerMaxTxOctets: uint16
      peerMaxTxTime: uint16

    NimLlcpPdu = object
      payloadLen: uint8
      data: array[32, uint8]

    NimLlcpLengthPduView {.packed.} = object
      opcode: uint8
      maxRxOctets: uint16
      maxRxTime: uint16
      maxTxOctets: uint16
      maxTxTime: uint16

    NimLlcpConnectionUpdateIndView {.packed.} = object
      opcode: uint8
      winSize: uint8
      winOffset: uint16
      interval: uint16
      latency: uint16
      timeout: uint16
      instant: uint16

    NimLlcpChannelMapIndView {.packed.} = object
      opcode: uint8
      channelMap: array[5, uint8]
      instant: uint16

    NimLlcpVersionIndView {.packed.} = object
      opcode: uint8
      version: uint8
      companyId: uint16
      subversion: uint16

    NimLlcpPhyPairPduView {.packed.} = object
      opcode: uint8
      txPhys: uint8
      rxPhys: uint8

    NimLlcpRejectIndView {.packed.} = object
      opcode: uint8
      errorCode: uint8

    NimLlcpRejectExtIndView {.packed.} = object
      opcode: uint8
      rejectedOpcode: uint8
      errorCode: uint8

    NimLlcpUnknownRspView {.packed.} = object
      opcode: uint8
      unknownOpcode: uint8

    NimLlcpTerminateIndView {.packed.} = object
      opcode: uint8
      reason: uint8

    NimConnTxElementView {.packed.} = object
      reserved00: array[4, uint8]
      emOffset: uint16
      length: uint16

  static:
    doAssert sizeof(NimLlcpLengthPduView) == 9
    doAssert offsetof(NimLlcpLengthPduView, maxRxOctets) == 1
    doAssert offsetof(NimLlcpLengthPduView, maxRxTime) == 3
    doAssert offsetof(NimLlcpLengthPduView, maxTxOctets) == 5
    doAssert offsetof(NimLlcpLengthPduView, maxTxTime) == 7
    doAssert sizeof(NimLlcpConnectionUpdateIndView) == 12
    doAssert offsetof(NimLlcpConnectionUpdateIndView, winSize) == 1
    doAssert offsetof(NimLlcpConnectionUpdateIndView, winOffset) == 2
    doAssert offsetof(NimLlcpConnectionUpdateIndView, interval) == 4
    doAssert offsetof(NimLlcpConnectionUpdateIndView, latency) == 6
    doAssert offsetof(NimLlcpConnectionUpdateIndView, timeout) == 8
    doAssert offsetof(NimLlcpConnectionUpdateIndView, instant) == 10
    doAssert sizeof(NimLlcpChannelMapIndView) == 8
    doAssert offsetof(NimLlcpChannelMapIndView, channelMap) == 1
    doAssert offsetof(NimLlcpChannelMapIndView, instant) == 6
    doAssert sizeof(NimLlcpVersionIndView) == 6
    doAssert offsetof(NimLlcpVersionIndView, version) == 1
    doAssert offsetof(NimLlcpVersionIndView, companyId) == 2
    doAssert offsetof(NimLlcpVersionIndView, subversion) == 4
    doAssert sizeof(NimLlcpPhyPairPduView) == 3
    doAssert offsetof(NimLlcpPhyPairPduView, txPhys) == 1
    doAssert offsetof(NimLlcpPhyPairPduView, rxPhys) == 2
    doAssert sizeof(NimLlcpRejectIndView) == 2
    doAssert offsetof(NimLlcpRejectIndView, errorCode) == 1
    doAssert sizeof(NimLlcpRejectExtIndView) == 3
    doAssert offsetof(NimLlcpRejectExtIndView, rejectedOpcode) == 1
    doAssert offsetof(NimLlcpRejectExtIndView, errorCode) == 2
    doAssert sizeof(NimLlcpUnknownRspView) == 2
    doAssert offsetof(NimLlcpUnknownRspView, unknownOpcode) == 1
    doAssert sizeof(NimLlcpTerminateIndView) == 2
    doAssert offsetof(NimLlcpTerminateIndView, reason) == 1
    doAssert sizeof(NimConnTxElementView) == 8
    doAssert offsetof(NimConnTxElementView, emOffset) == 4
    doAssert offsetof(NimConnTxElementView, length) == 6

  when bl808BleNimPureConnection:
    type
      NimConnTxKind = enum
        nimConnTxEmptyData
        nimConnTxAclData
        nimConnTxLlcp

      NimConnState = object
        active: bool
        reschedulePending: bool
        centralRole: bool
        directAnchorMode: bool
        handle: uint16
        accessAddress: uint32
        crcInit: uint32
        intervalSlots: uint32
        supervisionSlots: uint32
        nextAnchor: uint32
        anchorFine: uint16
        rxWindowHalfUs: uint32
        rxTimingHalfUs: uint32
        timingReferenceClock: uint32
        peerDriftPpm: uint32
        eventCounter: uint16
        connUpdatePending: bool
        connUpdateInstant: uint16
        pendingIntervalSlots: uint32
        pendingSupervisionSlots: uint32
        pendingWinOffsetSlots: uint32
        pendingWinSizeHalfUs: uint32
        pendingIntervalUnits: uint16
        pendingLatency: uint16
        pendingTimeoutUnits: uint16
        connUpdateNotifyHost: bool
        hopIncrement: uint8
        channelSelection2: bool
        channelMap: array[5, uint8]
        pendingChannelMap: array[5, uint8]
        channelMapInstant: uint16
        channelMapPending: bool
        remap: array[37, uint8]
        usedChannelCount: uint8
        lastUnmappedChannel: uint8
        emUnmappedChannel: uint8
        rfChannelMhz: uint16
        rxObserved: bool
        rxAcquiredEvents: uint8
        lastRxEventCounter: uint16
        lastRxClock: uint32
        rxNextExpectedSeq: uint8
        rxPayloadFresh: bool
        txNesn: uint8
        txSeq: uint8
        txPendingSeq: uint8
        txAckArmed: bool
        txAckObserved: bool
        txAckEligibleEvent: uint16
        txAckDescOff: uint16
        txKind: NimConnTxKind
        txEmOffset: uint16
        txLen: uint8
        txProgrammed: bool
        txProgrammedEvent: uint16
        txDescBaseOffset: uint16
        txDescCursor: uint8
        rate: uint8
        phy: uint8
        dataFlowEnabled: bool
        peerSca: uint8
        preferredSlaveLatency: uint16
        preferredSlaveEventDuration: uint16

  var nim_llcp_tx_queue: array[8, array[32, uint8]]
  var nim_llcp_tx_queue_len: array[8, uint8]
  var nim_llcp_tx_queue_conhdl: array[8, uint16]
  var nim_llcp_tx_queue_head: uint32
  var nim_llcp_tx_queue_tail: uint32
  var nim_llcp_state: NimLlcpState
  when bl808BleNimPureConnection:
    var nim_conn_state: NimConnState
    var nim_conn_sch_prog: array[36, uint8]
    var nim_conn_sched_log_index* {.exportc.}: uint32
    var nim_conn_sched_now_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_target_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_delta_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_duration_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_event_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_channel_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_timing_log* {.exportc.}: array[8, uint32]
    var nim_conn_last_schedule_now* {.exportc.}: uint32
    var nim_conn_last_schedule_target* {.exportc.}: uint32
    var nim_conn_last_schedule_fine* {.exportc.}: uint32
    var nim_conn_last_schedule_delta* {.exportc.}: uint32
    var nim_conn_last_schedule_duration* {.exportc.}: uint32
    var nim_conn_last_rx_timing* {.exportc.}: uint32
    var nim_conn_last_channel_word* {.exportc.}: uint32
    var nim_conn_last_channel* {.exportc.}: uint32
    var nim_conn_last_unmapped_channel* {.exportc.}: uint32
    var nim_conn_last_event_counter* {.exportc.}: uint32
    var nim_conn_last_schedule_anchor* {.exportc.}: uint32
    var nim_conn_last_schedule_anchor_fine* {.exportc.}: uint32
    var nim_conn_first_schedule_snapshot* {.exportc.}: array[12, uint32]
    var nim_conn_missed_event_fallback_count* {.exportc.}: uint32
    var nim_conn_deferred_schedule_count* {.exportc.}: uint32
    var nim_conn_rx_acquire_events* {.exportc.}: uint32
    var nim_conn_rx_acquire_reset_count* {.exportc.}: uint32
    var nim_conn_rx_status_reject_count* {.exportc.}: uint32
    var nim_conn_rx_last_rejected_status* {.exportc.}: uint32
    var nim_conn_rx_last_rejected_header* {.exportc.}: uint32
    when defined(BleDebugCounters):
      var nim_conn_tx_header_log* {.exportc.}: array[16, uint32]
      var nim_conn_tx_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_tx_header_log_index* {.exportc.}: uint32
      var nim_conn_rx_seq_log* {.exportc.}: array[16, uint32]
      var nim_conn_rx_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_rx_seq_log_index* {.exportc.}: uint32
      var nim_conn_sch_event_log_index* {.exportc.}: uint32
      var nim_conn_sch_event_code_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_time_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_now_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_counts_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_int_log* {.exportc.}: array[16, uint32]

  proc activeNimConnectionHandle(): uint16 {.inline.} =
    when bl808BleNimPureConnection:
      if nim_conn_state.active:
        nim_conn_state.handle
      else:
        1'u16
    else:
      1'u16

  when bl808BleNimLlcStart:
    var nim_llc_start_env_slots: array[5, pointer]
    var nim_llc_start_env_storage: array[5, array[0x8C, uint8]]

  const
    NimLlcpTxEmOffset = 0x0788'u16
    NimAclTxEmOffset = 0x0A20'u16
    NimLlcpMaxPayloadLen = 32'u8
    NimLlcpDefaultReason = 0x13'u8
    NimLlcpLocalVersion = 0x0C'u8
    NimLlcpLocalCompanyId = 0x0060'u16
    NimLlcpLocalSubversion = 0x000A'u16
    NimLlcpMaxDataOctets = NimBleLeMaxDataOctets
    NimLlcpPhy1M = NimBleLe1MPhy
    NimRxDescDone = 0x8000'u16
    NimRxDescLinkMask = 0x7FFF'u16
    NimRxDescHeaderOffset = 0x04'u32
    NimRxDescDataOffsetOffset = 0x14'u32
    NimDataLlIdContinuation = 0x01'u8
    NimDataLlIdStart = 0x02'u8
    NimDataLlIdControl = 0x03'u8
    NimConnMaxRxPayloadLen = 0x1B'u8
    NimConnEmStride = 0x94'u32
    NimConnEmBaseOffset = 0x0120'u32
    NimConnTxDescBaseOffset = 0x0558'u16
    NimConnTxDescPerHandleStride = 0x0070'u16
    NimConnTxDescStride = 0x0010'u16
    NimConnEmptyDataEmOffset = 0x0A20'u16
    NimConnTxDescSoftwareOwned = 0x8000'u16
    NimConnDataHeaderMoreDataBit = 0x0010'u16
    NimConnPhyControlBase = 0x1100'u16
    NimConnPhyControlStep = 5'u16
    NimConnChannelSelect2Bit = 0x2000'u16
    NimConnChannelEnableBit = 0x8000'u16
    NimConnRfConfigIndex = 0x39
    # The Nim LLD connection start path seeds EM +0x1E with the expected PHY
    # sync position. lld_con_evt_start_cbk overwrites the same field from the
    # computed RX timing window when the normal CONNECT_IND timing path is
    # active.
    NimConnLe1mSyncPosition = 0x0007'u16
    NimConnCodedSyncPosition = 0x0038'u16
    NimConnRxTimingDefault = 0x00FB'u16
    NimConnEventDurationMarginUs = 290'u32
    NimConnHalfSlotsPerConnIntervalUnit = 4'u32
    NimConnHalfSlotsPerSupervisionUnit = 32'u32
    NimConnHalfUsPerConnWindowUnit = 2500'u32
    NimConnHalfUsPerHalfSlot = 625'u32
    NimConnScheduleDurationMarginHalfUs = 2500'u32
    NimConnScheduleLeadSlots = 4'u32
    NimConnTrackedRxWindowHalfUs = 2500'u32
    NimConnPeripheralAcquireRxEvents = 4'u8
    NimConnConnectIndTransmitWindowDelayHalfSlots = 4'u32
    NimConnAdvTypeTimingBit = 0x10'u16
    NimConnDefaultLegacyAdvType = 0'u8
    NimConnLegacyAdvEventProps: array[5, uint16] = [
      0x13'u16, 0x1D'u16, 0x12'u16, 0x10'u16, 0x15'u16
    ]
    # The first central event still needs the normal scheduler setup lead.  The
    # initiator chooses an anchor inside the CONNECT_IND transmit window with
    # enough margin; if handoff runs late, skip event 0 instead of programming a
    # radio event at its boundary.
    NimConnInitialCentralScheduleLeadSlots = NimConnScheduleLeadSlots
    NimConnStartCentralRoleOffset = 40
    NimConnDiscSourceSupervisionTimeout = 9'u32
    NimConnDisconnectReasonTimeout = 0x08'u8
    BleErrorPinOrKeyMissing = 0x06'u8
    BleErrorUnsupportedRemoteFeature = 0x1A'u8
    BleErrorUnsupportedLlParameter = 0x20'u8
    LlcpConnectionUpdateInd = 0x00'u8
    LlcpChannelMapInd = 0x01'u8
    LlcpTerminateInd = 0x02'u8
    LlcpEncReq = 0x03'u8
    LlcpEncRsp = 0x04'u8
    LlcpStartEncReq = 0x05'u8
    LlcpStartEncRsp = 0x06'u8
    LlcpUnknownRsp = 0x07'u8
    LlcpFeatureReq = 0x08'u8
    LlcpFeatureRsp = 0x09'u8
    LlcpPauseEncReq = 0x0A'u8
    LlcpPauseEncRsp = 0x0B'u8
    LlcpVersionInd = 0x0C'u8
    LlcpRejectInd = 0x0D'u8
    LlcpSlaveFeatureReq = 0x0E'u8
    LlcpConnectionParamReq = 0x0F'u8
    LlcpConnectionParamRsp = 0x10'u8
    LlcpRejectExtInd = 0x11'u8
    LlcpPingReq = 0x12'u8
    LlcpPingRsp = 0x13'u8
    LlcpLengthReq = 0x14'u8
    LlcpLengthRsp = 0x15'u8
    LlcpPhyReq = 0x16'u8
    LlcpPhyRsp = 0x17'u8
    LlcpPhyUpdateInd = 0x18'u8
    LlcpMinUsedChannelsInd = 0x19'u8

  proc noteNimRxDescConsumed(idx: uint32) =
    lld_env[14] = uint8((idx + 1'u32) and 0x07'u32)

  proc putLe16(dst: ptr UncheckedArray[uint8], off: int, value: uint16) =
    dst[off] = uint8(value and 0x00FF'u16)
    dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc putLe32(dst: ptr UncheckedArray[uint8], off: int, value: uint32) =
    dst[off] = uint8(value and 0x000000FF'u32)
    dst[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    dst[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    dst[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

  proc nimLlcpRecordRx(header: uint16, dataOff: uint16, pduLen: uint16) =
    let slot = nim_llcp_rx_log_index and 0x07'u32
    var word = uint32(header) shl 16
    if pduLen > 0'u16:
      word = word or uint32(btbleEmRead8(dataOff))
    if pduLen > 1'u16:
      word = word or (uint32(btbleEmRead8(dataOff + 1'u16)) shl 8)
    nim_llcp_rx_log[slot.int] = word
    nim_llcp_rx_log_index = nim_llcp_rx_log_index + 1'u32

  proc nimLlcpRecordTx(pdu: ptr UncheckedArray[uint8], len: uint8) =
    let slot = nim_llcp_tx_log_index and 0x07'u32
    var word = uint32(len) shl 24
    if pdu != nil and len > 0'u8:
      word = word or uint32(pdu[0])
    if pdu != nil and len > 1'u8:
      word = word or (uint32(pdu[1]) shl 8)
    if pdu != nil and len > 2'u8:
      word = word or (uint32(pdu[2]) shl 16)
    nim_llcp_tx_log[slot.int] = word
    nim_llcp_tx_log_index = nim_llcp_tx_log_index + 1'u32

  proc nimLlcpRecordPeerFeatures(pdu: ptr UncheckedArray[uint8],
                                pduLen: uint8): bool =
    if pdu == nil or pduLen < 9'u8:
      return
    let opcode = pdu[0]
    if opcode != LlcpFeatureReq and opcode != LlcpFeatureRsp and
        opcode != LlcpSlaveFeatureReq:
      return
    var features = 0'u64
    for i in 0 ..< 8:
      features = features or (uint64(pdu[i + 1]) shl (i * 8))
    nim_llcp_state.peerFeatures = features
    nim_llcp_state.peerFeaturesKnown = true
    nim_llcp_peer_features[0] =
      uint32(features and 0x00000000FFFFFFFF'u64)
    nim_llcp_peer_features[1] = uint32(features shr 32)
    true

  proc nimLlcpUsedFeaturesForPeer(): uint64 =
    if nim_llcp_state.peerFeaturesKnown:
      return NimBleConservativeLeFeatures and
        nim_llcp_state.peerFeatures
    NimBleConservativeLeFeatures

  proc nimLlcpRecordUsedFeatures(features: uint64) =
    nim_llcp_used_features[0] =
      uint32(features and 0x00000000FFFFFFFF'u64)
    nim_llcp_used_features[1] = uint32(features shr 32)

  proc nimLlcpClearFeatureExchangeState(clearDebug: bool = false) =
    nim_llcp_state.remoteFeaturesEventPending = false
    nim_llcp_state.peerFeaturesKnown = false
    nim_llcp_state.peerFeatures = 0
    if clearDebug:
      nim_llcp_peer_features[0] = 0
      nim_llcp_peer_features[1] = 0
      nim_llcp_used_features[0] = 0
      nim_llcp_used_features[1] = 0

  proc nimLlcpMaybeCompleteRemoteFeatures(conhdl: uint16) =
    if nim_llcp_state.remoteFeaturesEventPending and
        nim_llcp_state.peerFeaturesKnown:
      nim_llcp_state.remoteFeaturesEventPending = false
      sendLeRemoteFeaturesComplete(conhdl, HciStatusSuccess)

  proc getLe16(src: ptr UncheckedArray[uint8], off: int): uint16 =
    uint16(src[off]) or (uint16(src[off + 1]) shl 8)

  template nimLlcpLengthPduAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpLengthPduView =
    cast[ptr NimLlcpLengthPduView](pdu)

  template nimLlcpLengthPdu(pdu: var NimLlcpPdu): ptr NimLlcpLengthPduView =
    cast[ptr NimLlcpLengthPduView](addr pdu.data[0])

  template nimLlcpConnectionUpdateInd(pdu: var NimLlcpPdu): ptr NimLlcpConnectionUpdateIndView =
    cast[ptr NimLlcpConnectionUpdateIndView](addr pdu.data[0])

  template nimLlcpConnectionUpdateIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpConnectionUpdateIndView =
    cast[ptr NimLlcpConnectionUpdateIndView](pdu)

  template nimLlcpChannelMapInd(pdu: var NimLlcpPdu): ptr NimLlcpChannelMapIndView =
    cast[ptr NimLlcpChannelMapIndView](addr pdu.data[0])

  template nimLlcpChannelMapIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpChannelMapIndView =
    cast[ptr NimLlcpChannelMapIndView](pdu)

  template nimLlcpVersionInd(pdu: var NimLlcpPdu): ptr NimLlcpVersionIndView =
    cast[ptr NimLlcpVersionIndView](addr pdu.data[0])

  template nimLlcpPhyPairPdu(pdu: var NimLlcpPdu): ptr NimLlcpPhyPairPduView =
    cast[ptr NimLlcpPhyPairPduView](addr pdu.data[0])

  template nimLlcpRejectInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectIndView =
    cast[ptr NimLlcpRejectIndView](addr pdu.data[0])

  template nimLlcpRejectExtInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectExtIndView =
    cast[ptr NimLlcpRejectExtIndView](addr pdu.data[0])

  template nimLlcpUnknownRsp(pdu: var NimLlcpPdu): ptr NimLlcpUnknownRspView =
    cast[ptr NimLlcpUnknownRspView](addr pdu.data[0])

  template nimLlcpTerminateInd(pdu: var NimLlcpPdu): ptr NimLlcpTerminateIndView =
    cast[ptr NimLlcpTerminateIndView](addr pdu.data[0])

  template nimConnTxElementAt(buf: pointer): ptr NimConnTxElementView =
    cast[ptr NimConnTxElementView](buf)

  proc nimConnTxElementInit(buf: pointer; emOffset, length: uint16) =
    let tx = nimConnTxElementAt(buf)
    discard c_memset(buf, 0, sizeof(NimConnTxElementView).csize_t)
    tx.emOffset = emOffset
    tx.length = length

  proc nimLlcpResetDataLengthState() =
    nim_llcp_state.dataLengthKnown = false
    nim_llcp_state.localTxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.localTxTime = NimBleLeMaxDataTime
    nim_llcp_state.peerMaxRxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.peerMaxRxTime = NimBleLeMaxDataTime
    nim_llcp_state.peerMaxTxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.peerMaxTxTime = NimBleLeMaxDataTime

  proc nimLlcpStorePeerDataLength(maxRxOctets, maxRxTime, maxTxOctets,
                                 maxTxTime: uint16) =
    nim_llcp_state.dataLengthKnown = true
    nim_llcp_state.peerMaxRxOctets = clampBleDataOctets(maxRxOctets)
    nim_llcp_state.peerMaxRxTime = clampBleDataTime(maxRxTime)
    nim_llcp_state.peerMaxTxOctets = clampBleDataOctets(maxTxOctets)
    nim_llcp_state.peerMaxTxTime = clampBleDataTime(maxTxTime)

  proc nimLlcpRecordPeerDataLength(pdu: ptr UncheckedArray[uint8],
                                  pduLen: uint8) =
    if not nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      return
    if pdu == nil or pduLen < 9'u8:
      return
    let lengthPdu = nimLlcpLengthPduAt(pdu)
    if lengthPdu.opcode != LlcpLengthReq and lengthPdu.opcode != LlcpLengthRsp:
      return
    nimLlcpStorePeerDataLength(lengthPdu.maxRxOctets, lengthPdu.maxRxTime,
                              lengthPdu.maxTxOctets, lengthPdu.maxTxTime)

  proc nimLlcpConfigCount(value: int): uint8 {.inline.} =
    if value <= 0:
      0'u8
    elif value > 255:
      255'u8
    else:
      uint8(value)

  when defined(bl808BlePrintNimLlcMsg):
    proc nimLlcMsgWord(index: int): uint32 =
      let off = index * 4
      uint32(nim_llc_msg[off]) or
        (uint32(nim_llc_msg[off + 1]) shl 8) or
        (uint32(nim_llc_msg[off + 2]) shl 16) or
        (uint32(nim_llc_msg[off + 3]) shl 24)

    proc printNimLlcMsg(label: static[string]) =
      bleTrace("[NIMLLC] ")
      bleTrace(label)
      bleTrace(" words=")
      for i in 0 ..< 14:
        if i != 0:
          bleTrace(",")
        bleTraceHex32(nimLlcMsgWord(i))
      bleTrace("\r\n")

  when bl808BleConnStageDiag:
    template nimConnReadRa(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, ra\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    template nimConnReadSp(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, sp\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    proc nimConnMark(stage: uint32) {.inline.} =
      nim_conn_stage = stage
      nim_conn_stage_ra = nimConnReadRa()
      nim_conn_stage_sp = nimConnReadSp()
      nim_conn_stage_mepc = cast[uint32](csrReadMepc())
      nim_conn_stage_mcause = cast[uint32](csrReadMcause())
  else:
    proc nimConnMark(stage: uint32) {.inline.} =
      discard stage

  proc recordNimPeripheralPeer(conhdl: uint16,
                                  raw: ptr UncheckedArray[uint8],
                                  header: uint16) =
    nimConnMark(0x130'u32)
    nim_conn_evt_handle = conhdl.uint32
    nim_conn_evt_peer_type = (uint32(header) shr 6) and 0x01'u32
    if raw != nil:
      nim_conn_evt_peer_a0 =
        uint32(raw[0]) or (uint32(raw[1]) shl 8) or
        (uint32(raw[2]) shl 16) or (uint32(raw[3]) shl 24)
      nim_conn_evt_peer_a1 =
        uint32(raw[4]) or (uint32(raw[5]) shl 8)

  proc noteNimPeripheralConnected(conhdl: uint16) =
    if nim_conn_evt_reported:
      return
    nimConnMark(0x132'u32)
    nim_conn_evt_handle = conhdl.uint32
    nim_conn_evt_reported = true
    inc nim_conn_evt_count

  proc completeNimInitiatorHciConnection(conhdl: uint16) =
    when defined(bl808m0) and bl808BleNimPureCentral:
      if nim_init_complete_pending == 0'u32:
        return
      nim_init_complete_pending = 0
      nim_init_active = 0
      nim_init_rx_service_pending = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
      nim_init_last_status = HciStatusSuccess.uint32
      inc nim_init_hci_complete_count
      inc nim_init_total_hci_complete_count
      sendLeConnectionCompleteStatusHandle(
        addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
        HciStatusSuccess, conhdl, 0'u8)
    else:
      discard conhdl

  proc noteNimAdvertiserConnected(raw: ptr UncheckedArray[uint8],
                                     header: uint16,
                                     interval: uint32,
                                     latency: uint32,
                                     peerSca: uint8) =
    ## lld_adv_end_ind_handler records the initiator identity and marks the
    ## advertising environment as connected after llc_start succeeds.  The Nim
    ## CONNECT_IND shortcut bypasses that handler, so mirror the consumed fields
    ## for advertiser slot 0.
    let conn = llmAdvertiserConn()
    if raw != nil:
      for i in 0 ..< 6:
        conn.peerAddr.data[i] = raw[i]
    conn.peerAddrType = uint8((header shr 6) and 0x01'u16)
    conn.connected = 1'u8
    conn.state = 9'u8
    conn.intervalMinSlots = uint16(interval * 4'u32)
    conn.intervalMaxSlots = uint16(interval * 4'u32)
    conn.intervalLatencyWord = 0x00040004'u32
    conn.supervisionMinSlots = uint16((latency + 1'u32) * interval)
    conn.supervisionMaxSlots = uint16((latency + 1'u32) * interval)
    let intervalLatency = (latency + 1'u32) * interval
    let scaIdx = peerSca and 0x07'u8
    let driftPpm = uint32(co_sca2ppm[scaIdx.int]) + rwip_max_drift_get(scaIdx)
    let driftSlots = (((driftPpm * intervalLatency) div 400'u32) * 2'u32 +
                      312'u32) div 625'u32 + 1'u32
    conn.driftSlots = uint16(driftSlots and 0xFFFF'u32)

  proc clearNimConnectionStateForDisconnect(reason: uint8) =
    discard reason
    nim_conn_active = false
    nim_conn_handle = 0
    nim_conn_started = false
    nim_conn_evt_reported = false
    when defined(bl808m0) and bl808BleNimPureCentral:
      nim_init_active = 0
      nim_init_complete_pending = 0
      nim_init_rx_service_pending = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
    when bl808BleNimPureConnection:
      nim_conn_state.active = false
      nim_conn_state.reschedulePending = false
      nim_conn_state.connUpdatePending = false
      nim_conn_state.pendingIntervalSlots = 0
      nim_conn_state.pendingSupervisionSlots = 0
      nim_conn_state.pendingWinOffsetSlots = 0
      nim_conn_state.pendingWinSizeHalfUs = 0
      nim_conn_state.pendingIntervalUnits = 0
      nim_conn_state.pendingLatency = 0
      nim_conn_state.pendingTimeoutUnits = 0
      nim_conn_state.connUpdateNotifyHost = false
    nim_connect_ind_pending = 0
    nim_llcp_tx_pending = 0
    nim_llcp_tx_queued = 0
    nim_llcp_tx_queue_head = 0
    nim_llcp_tx_queue_tail = 0
    nim_llcp_state.versionProcedureStarted = false
    nimLlcpClearFeatureExchangeState()
    nim_llcp_state.startupAttemptsLeft = 0
    nim_llcp_state.startupDelayServices = 0
    nimLlcpResetDataLengthState()
    nim_acl_empty_tx_pending = 0
    nim_acl_empty_tx_queued = 0
    nim_acl_host_tx_pending = 0
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()
    regWrite(BLE_BASE + BTBLE_INTACK_OFFSET,
             regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
    writeBtbleInterruptMask(0)

  proc noteNimPeripheralDisconnectedFrom(source: uint32, reason: uint8) =
    nimConnMark(0x1D0'u32)
    let alreadyDisconnected =
      not nim_conn_active and not nim_conn_started and
      nim_disc_evt_count != 0
    clearNimConnectionStateForDisconnect(reason)
    nim_disc_evt_reason = reason.uint32
    nim_disc_evt_source = source
    if not alreadyDisconnected:
      inc nim_disc_evt_count

  proc noteNimPeripheralDisconnected(reason: uint8) =
    noteNimPeripheralDisconnectedFrom(0'u32, reason)

  proc bleNimPeripheralIdleDisconnect*(reason: uint8) {.exportc, cdecl.} =
    ## Host-side fallback disconnect for the Nim peripheral bridge.  The local
    ## host can synthesize the disconnect after the macOS central drops the
    ## link, but the vendor LLD shim still has to leave connection mode so the
    ## BTBLE interrupt line does not keep the M0 in the connection service path.
    noteNimPeripheralDisconnectedFrom(1'u32, reason)

  proc validConnDataHeader(header: uint16): bool =
    let llid = uint8(header and 0x0003'u16)
    let payloadLen = connDataPayloadLen(header)
    if llid == 0'u8:
      return false
    if payloadLen > NimConnMaxRxPayloadLen:
      return false
    if llid == NimDataLlIdControl and payloadLen == 0'u8:
      return false
    true

  proc connRxStatusAcceptsPayload(status: uint16): bool {.inline.} =
    ## Match vendor lld_rxdesc_check: descriptor word 0 is the hardware ring
    ## link pointer plus the done bit.  Values such as 0x8116/0x811e are not
    ## CRC/sync errors; the lower bits point at the next RX descriptor.
    (status and NimRxDescDone) != 0'u16

  proc rejectConnRxDescriptor(desc: uint32, status, header: uint16,
                              cur: uint32) =
    btbleRxDescReleaseLink(desc, status)
    noteNimRxDescConsumed(cur)
    inc nim_lld_rx_free_count
    when bl808BleNimPureConnection:
      inc nim_conn_rx_status_reject_count
      nim_conn_rx_last_rejected_status = status.uint32
      nim_conn_rx_last_rejected_header = header.uint32

  when bl808BleNimManualConnTx:
    var nim_acl_empty_tx_buf: array[8, uint8]

    proc nimSendEmptyAclNow(conhdl: uint16): bool =
      if nim_acl_empty_tx_pending != 0:
        return false
      if nim_acl_host_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      # lld_con_data_tx takes an LLD ACL TX element, not a raw LL PDU.
      # Offset +4 is the EM payload offset and +6 carries the pending length.
      btbleEmWrite8(NimAclTxEmOffset, 0'u8)
      nimConnTxElementInit(addr nim_acl_empty_tx_buf[0], NimAclTxEmOffset, 0'u16)
      nim_acl_empty_tx_pending = 1
      inc nim_acl_empty_tx_count
      nim_acl_empty_last_status =
        nimLldConDataTx(conhdl, addr nim_acl_empty_tx_buf[0]).uint32
      if nim_acl_empty_last_status != 0:
        nim_acl_empty_tx_pending = 0
        return false
      true

    proc nimRequestEmptyAcl(conhdl: uint16): bool =
      if nim_acl_empty_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      if nim_acl_host_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      nimSendEmptyAclNow(conhdl)

    proc nimLlcpSendPduNow(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                              len: uint8,
                              sendAclKick: bool = bl808BleNimKeepaliveAcl): bool =
      if pdu == nil or len == 0'u8 or len > NimLlcpMaxPayloadLen:
        return false
      nimLlcpRecordTx(pdu, len)
      for i in 0 ..< len.int:
        btbleEmWrite8(NimLlcpTxEmOffset + i.uint16, pdu[i])
      nimConnTxElementInit(addr nim_llcp_tx_buf[0], NimLlcpTxEmOffset, len.uint16)
      nim_llcp_tx_pending = 1
      inc nim_llcp_tx_count
      nim_llcp_last_status =
        nimLldConLlcpTx(conhdl, addr nim_llcp_tx_buf[0]).uint32
      if nim_llcp_last_status != 0:
        nim_llcp_tx_pending = 0
        return false
      when bl808BleNimPureConnection:
        discard sendAclKick
      else:
        if sendAclKick:
          discard nimRequestEmptyAcl(conhdl)
      true

    proc nimLlcpSendPduNow(conhdl: uint16, pdu: var NimLlcpPdu,
                              sendAclKick: bool = bl808BleNimKeepaliveAcl): bool =
      nimLlcpSendPduNow(conhdl,
        cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), pdu.payloadLen,
        sendAclKick)

    proc nimLlcpTrySendQueued() =
      if nim_llcp_tx_pending != 0:
        return
      if nim_llcp_tx_queued == 0:
        return
      let slot = nim_llcp_tx_queue_head and 0x07'u32
      nim_llcp_tx_queue_head =
        (nim_llcp_tx_queue_head + 1'u32) and 0x07'u32
      dec nim_llcp_tx_queued
      discard nimLlcpSendPduNow(nim_llcp_tx_queue_conhdl[slot.int],
        cast[ptr UncheckedArray[uint8]](
          addr nim_llcp_tx_queue[slot.int][0]),
        nim_llcp_tx_queue_len[slot.int])

    proc nimLlcpQueuePdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                            len: uint8): bool =
      if pdu == nil or len == 0'u8 or len > NimLlcpMaxPayloadLen:
        return false
      if nim_llcp_tx_pending == 0 and nim_llcp_tx_queued != 0:
        nimLlcpTrySendQueued()
      if nim_llcp_tx_pending == 0 and nim_llcp_tx_queued == 0:
        if nimLlcpSendPduNow(conhdl, pdu, len):
          return true
        inc nim_llcp_tx_dropped
        return false
      if nim_llcp_tx_queued >=
          nim_llcp_tx_queue_len.len.uint32:
        inc nim_llcp_tx_dropped
        return false
      let slot = nim_llcp_tx_queue_tail and 0x07'u32
      nim_llcp_tx_queue_tail =
        (nim_llcp_tx_queue_tail + 1'u32) and 0x07'u32
      nim_llcp_tx_queue_conhdl[slot.int] = conhdl
      nim_llcp_tx_queue_len[slot.int] = len
      for i in 0 ..< len.int:
        nim_llcp_tx_queue[slot.int][i] = pdu[i]
      inc nim_llcp_tx_queued
      true

    proc nimLlcpQueuePdu(conhdl: uint16,
                            pdu: var NimLlcpPdu): bool {.inline.} =
      nimLlcpQueuePdu(conhdl,
        cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), pdu.payloadLen)

    proc nimLlcpWireLength(opcode: uint8): uint8 =
      case opcode
      of LlcpConnectionUpdateInd:
        12'u8
      of LlcpChannelMapInd:
        8'u8
      of LlcpTerminateInd:
        2'u8
      of LlcpEncReq:
        23'u8
      of LlcpEncRsp:
        13'u8
      of LlcpStartEncReq, LlcpStartEncRsp, LlcpPauseEncReq, LlcpPauseEncRsp,
         LlcpPingReq, LlcpPingRsp:
        1'u8
      of LlcpUnknownRsp:
        2'u8
      of LlcpFeatureReq, LlcpFeatureRsp, LlcpSlaveFeatureReq:
        9'u8
      of LlcpVersionInd:
        6'u8
      of LlcpRejectInd:
        2'u8
      of LlcpConnectionParamReq, LlcpConnectionParamRsp:
        24'u8
      of LlcpRejectExtInd:
        3'u8
      of LlcpLengthReq, LlcpLengthRsp:
        9'u8
      of LlcpPhyReq, LlcpPhyRsp:
        3'u8
      of LlcpPhyUpdateInd:
        5'u8
      of LlcpMinUsedChannelsInd:
        3'u8
      else:
        0'u8

    proc nimLlcpRxPduValid(opcode: uint8, pduLen: uint16): bool =
      const LlcpPlausibleFutureOpcodeMax = 0x3F'u8
      if pduLen == 0'u16 or pduLen > NimConnMaxRxPayloadLen.uint16:
        return false
      let expected = nimLlcpWireLength(opcode)
      if expected != 0'u8:
        return pduLen == expected.uint16
      opcode <= LlcpPlausibleFutureOpcodeMax

    proc nimLlcpRecordMalformed(header: uint16, opcode: uint8,
                                   pduLen: uint16) =
      inc nim_llcp_rx_malformed_count
      nim_llcp_rx_malformed_last =
        (uint32(header) shl 16) or
        (uint32(pduLen and 0x00FF'u16) shl 8) or uint32(opcode)

    proc nimLlcpBuildFeaturePdu(
        opcode: uint8,
        features: uint64 = NimBleConservativeLeFeatures): NimLlcpPdu =
      result.payloadLen = 9'u8
      result.data[0] = opcode
      for i in 0 ..< 8:
        result.data[i + 1] = nimBleFeatureByte(features, i)

    proc nimLlcpBuildLengthPdu(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 9'u8
      let body = nimLlcpLengthPdu(result)
      body.opcode = opcode
      body.maxRxOctets = NimBleLeMaxDataOctets
      body.maxRxTime = NimBleLeMaxDataTime
      body.maxTxOctets = nim_llcp_state.localTxOctets
      body.maxTxTime = nim_llcp_state.localTxTime

    proc nimLlcpBuildOpcodePdu(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 1'u8
      result.data[0] = opcode

    proc nimConnStorePendingConnectionUpdate(winSize: uint8, winOffset: uint16,
                                             interval, latency,
                                             timeout, instant: uint16,
                                             notifyHost: bool) =
      when bl808BleNimPureConnection:
        nim_conn_state.pendingWinOffsetSlots =
          uint32(winOffset) * NimConnHalfSlotsPerConnIntervalUnit
        nim_conn_state.pendingWinSizeHalfUs =
          uint32(if winSize == 0'u8: 1'u8 else: winSize) *
          NimConnHalfUsPerConnWindowUnit
        nim_conn_state.pendingIntervalSlots =
          uint32(interval) * NimConnHalfSlotsPerConnIntervalUnit
        nim_conn_state.pendingSupervisionSlots =
          uint32(timeout) * NimConnHalfSlotsPerSupervisionUnit
        nim_conn_state.pendingIntervalUnits = interval
        nim_conn_state.pendingLatency = latency
        nim_conn_state.pendingTimeoutUnits = timeout
        nim_conn_state.connUpdateInstant = instant
        nim_conn_state.connUpdateNotifyHost = notifyHost
        nim_conn_state.connUpdatePending = true

    proc nimLlcpBuildConnectionUpdateInd(req: ptr HciLeConnUpdateReqView): NimLlcpPdu =
      result.payloadLen = 12'u8
      let body = nimLlcpConnectionUpdateInd(result)
      body.opcode = LlcpConnectionUpdateInd
      if req == nil:
        return
      let interval = req.connIntervalMin
      let instant =
        when bl808BleNimPureConnection:
          uint16(nim_conn_state.eventCounter + 6'u16)
        else:
          6'u16
      body.winSize = 1'u8
      body.winOffset = 0'u16
      body.interval = interval
      body.latency = req.connLatency
      body.timeout = req.supervisionTimeout
      body.instant = instant

    proc nimLlcpStartConnectionUpdate(conhdl: uint16,
                                     req: ptr HciLeConnUpdateReqView): uint8 =
      when defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx:
        when bl808BleNimPureConnection:
          if not nim_conn_state.active or conhdl != nim_conn_state.handle:
            return HciStatusUnknownConnection
          if not nim_conn_state.centralRole:
            return HciStatusCommandDisallowed
          if nim_conn_state.connUpdatePending:
            return HciStatusCommandDisallowed
        else:
          return HciStatusUnsupportedFeatureParam
        if req == nil:
          return HciStatusInvalidParams
        var pdu = nimLlcpBuildConnectionUpdateInd(req)
        if not nimLlcpQueuePdu(conhdl, pdu):
          return HciStatusCommandDisallowed
        let update = nimLlcpConnectionUpdateInd(pdu)
        nimConnStorePendingConnectionUpdate(
          update.winSize,
          update.winOffset,
          req.connIntervalMin,
          req.connLatency,
          req.supervisionTimeout,
          update.instant,
          notifyHost = true)
        HciStatusSuccess
      else:
        discard conhdl
        discard req
        HciStatusUnsupportedFeatureParam

    proc nimLlcpBuildChannelMapInd(): NimLlcpPdu =
      result.payloadLen = 8'u8
      let body = nimLlcpChannelMapInd(result)
      body.opcode = LlcpChannelMapInd
      nimBleCurrentChannelMap(cast[ptr UncheckedArray[uint8]](addr body.channelMap[0]))
      let instant =
        when bl808BleNimPureConnection:
          uint16(nim_conn_state.eventCounter + 6'u16)
        else:
          6'u16
      body.instant = instant

    proc nimLlcpBuildVersionInd(): NimLlcpPdu =
      result.payloadLen = 6'u8
      let body = nimLlcpVersionInd(result)
      body.opcode = LlcpVersionInd
      body.version = NimLlcpLocalVersion
      body.companyId = NimLlcpLocalCompanyId
      body.subversion = NimLlcpLocalSubversion

    proc nimLlcpBuildFeatureRsp(): NimLlcpPdu =
      let features = nimLlcpUsedFeaturesForPeer()
      nimLlcpRecordUsedFeatures(features)
      nimLlcpBuildFeaturePdu(LlcpFeatureRsp, features)

    proc nimLlcpBuildPhyRsp(): NimLlcpPdu =
      result.payloadLen = 3'u8
      let body = nimLlcpPhyPairPdu(result)
      body.opcode = LlcpPhyRsp
      body.txPhys = NimLlcpPhy1M
      body.rxPhys = NimLlcpPhy1M

    proc nimLlcpBuildPingRsp(): NimLlcpPdu =
      nimLlcpBuildOpcodePdu(LlcpPingRsp)

    proc nimLlcpBuildLengthRsp(): NimLlcpPdu =
      nimLlcpBuildLengthPdu(LlcpLengthRsp)

    proc nimLlcpBuildRejectInd(errorCode: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpRejectInd(result)
      body.opcode = LlcpRejectInd
      body.errorCode = errorCode

    proc nimLlcpBuildRejectExtInd(rejectedOpcode, errorCode: uint8): NimLlcpPdu =
      result.payloadLen = 3'u8
      let body = nimLlcpRejectExtInd(result)
      body.opcode = LlcpRejectExtInd
      body.rejectedOpcode = rejectedOpcode
      body.errorCode = errorCode

    proc nimLlcpBuildUnsupportedFeatureRsp(opcode: uint8): NimLlcpPdu =
      nimLlcpBuildRejectExtInd(opcode, BleErrorUnsupportedRemoteFeature)

    proc nimLlcpBuildUnknownRsp(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpUnknownRsp(result)
      body.opcode = LlcpUnknownRsp
      body.unknownOpcode = opcode

    proc nimLlcpBuildTerminateInd(reason: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpTerminateInd(result)
      body.opcode = LlcpTerminateInd
      body.reason = reason

    proc nimLlcpRespond(conhdl: uint16, opcode: uint8,
                             reason: uint8 = NimLlcpDefaultReason) =
      case opcode
      of LlcpTerminateInd:
        noteNimPeripheralDisconnectedFrom(2'u32, reason)
        sendDisconnectComplete(conhdl, reason)
      of LlcpFeatureReq:
        var rsp = nimLlcpBuildFeatureRsp()
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpSlaveFeatureReq:
        var rsp = nimLlcpBuildFeatureRsp()
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpVersionInd:
        if not nim_llcp_state.versionProcedureStarted:
          var rsp = nimLlcpBuildVersionInd()
          if nimLlcpQueuePdu(conhdl, rsp):
            nim_llcp_state.versionProcedureStarted = true
            nim_llcp_state.startupAttemptsLeft = 0
      of LlcpLengthReq:
        if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
          var rsp = nimLlcpBuildLengthRsp()
          if nimLlcpQueuePdu(conhdl, rsp):
            sendLeDataLengthChange(conhdl)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpPhyReq:
        if nimBlePhyUpdateSupported():
          var rsp = nimLlcpBuildPhyRsp()
          discard nimLlcpQueuePdu(conhdl, rsp)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpPingReq:
        if nimBleLocalFeatureSupported(NimBleFeatureLePing):
          var rsp = nimLlcpBuildPingRsp()
          discard nimLlcpQueuePdu(conhdl, rsp)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpEncReq, LlcpPauseEncReq:
        var rsp = nimLlcpBuildRejectInd(BleErrorPinOrKeyMissing)
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpConnectionParamReq:
        var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpConnectionUpdateInd, LlcpChannelMapInd, LlcpPhyUpdateInd:
        discard
      of LlcpMinUsedChannelsInd:
        discard
      of LlcpEncRsp, LlcpStartEncReq, LlcpStartEncRsp, LlcpPauseEncRsp:
        discard
      of LlcpUnknownRsp, LlcpFeatureRsp, LlcpLengthRsp, LlcpPhyRsp, LlcpPingRsp,
         LlcpConnectionParamRsp, LlcpRejectInd, LlcpRejectExtInd:
        discard
      else:
        var rsp = nimLlcpBuildUnknownRsp(opcode)
        discard nimLlcpQueuePdu(conhdl, rsp)

    proc nimLlcpPrimeStartup() =
      nim_llcp_state.versionProcedureStarted = false
      nimLlcpClearFeatureExchangeState(clearDebug = true)
      nimLlcpResetDataLengthState()
      when bl808BleNimPureConnection:
        # Prime the controller-owned version procedure.  As a central, defer
        # until a slave packet anchors the link; as a peripheral, the first
        # slave response may legally ACK the master's SN=0 packet and carry
        # LL_VERSION_IND, which is what CoreBluetooth expects when it waits for
        # the peer version procedure.
        nim_llcp_state.startupAttemptsLeft =
          nimLlcpConfigCount(bl808BleNimStartupLlcpRetries)
        nim_llcp_state.startupDelayServices = 0
      else:
        when bl808BleNimStartupLlcpRetries > 0:
          nim_llcp_state.startupAttemptsLeft =
            nimLlcpConfigCount(bl808BleNimStartupLlcpRetries)
          nim_llcp_state.startupDelayServices =
            nimLlcpConfigCount(bl808BleNimStartupLlcpDelayServices)
        else:
          nim_llcp_state.startupAttemptsLeft = 0
          nim_llcp_state.startupDelayServices = 0

    proc nimLlcpTrySendStartup(conhdl: uint16) =
      when bl808BleNimStartupLlcpRetries > 0:
        if not nim_conn_started:
          return
        if nim_llcp_state.startupAttemptsLeft == 0'u8:
          return
        when bl808BleNimPureConnection:
          if nim_conn_state.active and nim_conn_state.centralRole and
              not nim_conn_state.rxObserved:
            inc nim_llcp_startup_deferred_count
            return
        # TX-free only confirms that the vendor LLD accepted/free'd our buffer,
        # not that the peer received the control PDU. Retry only until any LLCP
        # arrives from the peer; after that, the normal LLCP responder owns it.
        if nim_llcp_rx_count != 0'u32:
          nim_llcp_state.startupAttemptsLeft = 0
          return
        if nim_llcp_tx_pending != 0'u32 or
            nim_llcp_tx_queued != 0'u32:
          inc nim_llcp_startup_deferred_count
          return
        if nim_llcp_state.startupDelayServices != 0'u8:
          dec nim_llcp_state.startupDelayServices
          inc nim_llcp_startup_deferred_count
          return
        var pdu = nimLlcpBuildVersionInd()
        dec nim_llcp_state.startupAttemptsLeft
        inc nim_llcp_startup_tx_count
        if nimLlcpSendPduNow(conhdl, pdu):
          nim_llcp_state.versionProcedureStarted = true

    when bl808BleNimPureConnection:
      proc nimConnReceiveChannelMapIndBytes(pdu: ptr UncheckedArray[uint8],
                                            pduLen: uint8)
      proc nimConnReceiveConnectionUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                                  pduLen: uint8)
      proc nimConnReceivePhyUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                           pduLen: uint8)

    proc nimLlcpObservePdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                              pduLen: uint8) =
      if pdu == nil or pduLen == 0'u8:
        return
      let peerFeaturesUpdated = nimLlcpRecordPeerFeatures(pdu, pduLen)
      nimLlcpRecordPeerDataLength(pdu, pduLen)
      if peerFeaturesUpdated:
        nimLlcpMaybeCompleteRemoteFeatures(conhdl)
      when bl808BleNimPureConnection:
        case pdu[0]
        of LlcpChannelMapInd:
          nimConnReceiveChannelMapIndBytes(pdu, pduLen)
        of LlcpConnectionUpdateInd:
          nimConnReceiveConnectionUpdateIndBytes(pdu, pduLen)
        of LlcpPhyUpdateInd:
          nimConnReceivePhyUpdateIndBytes(pdu, pduLen)
        else:
          discard

    proc nimLlcpObserveEm(conhdl: uint16, dataOff: uint16, pduLen: uint8) =
      if pduLen == 0'u8:
        return
      let pdu = cast[ptr UncheckedArray[uint8]](
        BTBLE_EM_BASE + uint32(dataOff))
      nimLlcpObservePdu(conhdl, pdu, pduLen)

    proc nimLlcpHandleConsumed(conhdl: uint16,
                                  pdu: ptr UncheckedArray[uint8],
                                  rxHeader: uint16,
                                  fallbackOpcode: uint8): uint32 =
      let pduLen = uint8((rxHeader shr 8) and 0x00FF'u16)
      let opcode =
        if pdu != nil and pduLen > 0'u8:
          pdu[0]
        else:
          fallbackOpcode
      let reason =
        if pdu != nil and pduLen > 1'u8:
          pdu[1]
        else:
          NimLlcpDefaultReason
      if not nimLlcpRxPduValid(opcode, pduLen.uint16):
        nimLlcpRecordMalformed(rxHeader, opcode, pduLen.uint16)
        return 0'u32
      let slot = nim_llcp_rx_log_index and 0x07'u32
      nim_llcp_rx_log[slot.int] =
        (uint32(rxHeader) shl 16) or (uint32(reason) shl 8) or
        uint32(opcode)
      nim_llcp_rx_log_index = nim_llcp_rx_log_index + 1'u32
      inc nim_llcp_rx_count
      nim_llcp_last_opcode =
        0xCC000000'u32 or (uint32(rxHeader) shl 8) or uint32(opcode)
      nimLlcpObservePdu(conhdl, pdu, pduLen)
      nimLlcpRespond(conhdl, opcode, reason)
      0'u32

    proc nimLlcpSendInitialNow(conhdl: uint16): bool =
      var pdu = nimLlcpBuildVersionInd()
      result = nimLlcpSendPduNow(conhdl, pdu)
      if result:
        nim_llcp_state.versionProcedureStarted = true
        nim_llcp_state.startupAttemptsLeft = 0

    proc nimSendLeConnComplete(conhdl: uint16) =
      var evt: array[19, uint8]
      evt[0] = 0x01'u8
      evt[1] = 0x00'u8
      evt[2] = uint8(conhdl and 0xFF'u16)
      evt[3] = uint8((conhdl shr 8) and 0xFF'u16)
      nim_conn_active = true
      nim_conn_handle = conhdl
      sendLeMetaPayload(addr evt[0], evt.len.uint8)

  proc addBtbleClockSlots(base: uint32, slots: int): uint32 =
    if slots >= 0:
      (base + uint32(slots)) and 0x0FFFFFFF'u32
    else:
      (base - uint32(-slots)) and 0x0FFFFFFF'u32

  proc refreshNimSyncPositions() =
    ## The LLD init path derives the RX sync-position table from these BTBLE
    ## timing registers. lld_con_start uses the table again when converting
    ## CONNECT_IND RX timing into the first connection anchor.
    lld_exp_sync_pos_tab[0] =
      uint16(((regRead((BLE_BASE + 0x890'u32).uint) shr 8) and 0xFF'u32) +
             0x28'u32)
    lld_exp_sync_pos_tab[1] =
      uint16(((regRead((BLE_BASE + 0x894'u32).uint) shr 8) and 0xFF'u32) +
             0x18'u32)
    let codedSync =
      uint16(((regRead((BLE_BASE + 0x898'u32).uint) shr 8) and 0xFF'u32) +
             0x150'u32)
    lld_exp_sync_pos_tab[2] = codedSync
    lld_exp_sync_pos_tab[3] = codedSync

  proc nimConnectTiming(baseClock: uint32, rawFine: uint16,
                           rateIdx: uint8, outClock: var uint32,
                           outFine: var uint16) =
    refreshNimSyncPositions()
    let syncPos =
      if rateIdx.int < lld_exp_sync_pos_tab.len:
        lld_exp_sync_pos_tab[rateIdx.int]
      else:
        0'u16
    var coarse = baseClock and 0x0000FFFF'u32
    var fine = 0x270'i32 - int32(rawFine and 0x03FF'u16) -
               int32(syncPos) * 2'i32
    while fine < 0'i32:
      fine += 0x271'i32
      coarse = (coarse - 1'u32) and 0x0000FFFF'u32
    outClock = coarse
    outFine = uint16(fine)

  proc nimConnLegacyAdvPropsFromHciType(advType: uint8): uint16 {.inline.} =
    if advType.int < NimConnLegacyAdvEventProps.len:
      NimConnLegacyAdvEventProps[advType.int]
    else:
      NimConnLegacyAdvEventProps[NimConnDefaultLegacyAdvType.int]

  proc nimConnLegacyAdvActiveProps(): uint16 {.inline.} =
    ## Reference llm_adv passes the properties of the scheduled advertising
    ## event.  Keep a saved pure Nim copy because the EM TX descriptor belongs
    ## to the radio program and can be rewritten before CONNECT_IND handoff.
    let advType = nim_adv_params[4]
    let fallback = nimConnLegacyAdvPropsFromHciType(advType)
    if nim_adv_event_props != 0'u16: nim_adv_event_props
    else: fallback

  proc nimConnLegacyAdvLeadSelector(): uint8 {.inline.} =
    ## Reference lld_adv_end_ind_handler stores byte 39 as the active
    ## advertising properties with the legacy timing bit toggled.
    let props = nimConnLegacyAdvActiveProps()
    uint8((props xor NimConnAdvTypeTimingBit) and 0x00FF'u16)

  proc quiesceNimAdvertisingForConnectionHandoff() =
    ## Retire the pure Nim advertiser's delayed target state before programming a
    ## connection.  The vendor CONNECT_IND path removes the advertising scheduler
    ## activity before llm_adv hands the timing message to llc_start.  Keep the
    ## BTBLE target/RF gate armed: reference llc_start snapshots still have
    ## BLE+0x9C0 bit 14 set when the first connection event is scheduled.
    nim_adv_enabled = false
    nim_adv_target_half_us = 0
    when declared(nim_adv_sch_event_active):
      nim_adv_sch_event_active = 0
    regOr(BLE_BASE + 0x9C0'u32, BtbleEventTargetEnableBit)
    regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntEventTarget)

  when bl808BleNimPureConnection:
    when bl808BleNimManualConnTx:
      proc serviceNimConnectionLlcpRxDescriptors()
      proc nimConnArmPendingHostAclTx()
    proc nimConnSchProgCb(arg0: uint32, ctx: pointer, event: uint8) {.cdecl.}

    proc nimConnEmOffset(conhdl: uint16): uint32 {.inline.} =
      NimConnEmBaseOffset + NimConnEmStride * uint32(conhdl and 0x000F'u16)

    proc nimConnEmAddr(conhdl: uint16, off: uint32): uint32 {.inline.} =
      BTBLE_EM_BASE + nimConnEmOffset(conhdl) + off

    template btbleConnEventAt(eventAddr: uint32): ptr BtbleConnEventView =
      cast[ptr BtbleConnEventView](eventAddr.uint)

    proc nimConnEventView(conhdl: uint16): ptr BtbleConnEventView {.inline.} =
      btbleConnEventAt(nimConnEmAddr(conhdl, 0))

    proc nimConnEventSetRxSync(conhdl: uint16; timing: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).rxSync, timing)

    proc nimConnEventSetPacketDurations(conhdl: uint16;
                                        duration: uint16) {.inline.} =
      let event = nimConnEventView(conhdl)
      volatileStore(addr event.txDuration, duration)
      volatileStore(addr event.rxDuration, duration)

    proc nimConnEventSetTxDescPtr(conhdl: uint16; descPtr: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).txDescPtr, descPtr)

    proc nimConnEventSetChannel(conhdl: uint16; channelWord: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).channel, channelWord)

    proc nimConnEventSetEventCounter(conhdl: uint16; eventCounter: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).eventCounter, eventCounter)

    proc nimConnDescAddr(off: uint16): uint32 {.inline.} =
      BTBLE_EM_BASE + uint32(off)

    proc nimConnDescPtr(off: uint16): uint16 {.inline.} =
      uint16((uint32(off) shr 2) and 0xFFFF'u32)

    proc nimConnDescStatus(nextOff: uint16,
                           softwareOwned: bool): uint16 {.inline.} =
      result = nimConnDescPtr(nextOff)
      if softwareOwned:
        result = result or NimConnTxDescSoftwareOwned

    template btbleConnTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView =
      cast[ptr BtbleConnTxDescView](descAddr.uint)

    proc btbleConnTxDescStatus(descAddr: uint32): uint16 {.inline.} =
      volatileLoad(addr btbleConnTxDescAt(descAddr).status)

    proc btbleConnTxDescSetStatus(descAddr: uint32; status: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).status, status)

    proc btbleConnTxDescSetHeader(descAddr: uint32; header: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).header, header)

    proc btbleConnTxDescSetDataOffset(descAddr: uint32; offset: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).dataOffset, offset)

    proc btbleConnTxDescClear(descAddr: uint32; nextOff: uint16) {.inline.} =
      let desc = btbleConnTxDescAt(descAddr)
      volatileStore(addr desc.status, nimConnDescStatus(nextOff, softwareOwned = true))
      volatileStore(addr desc.header, 0'u16)
      volatileStore(addr desc.dataOffset, 0'u16)
      for i in 0 ..< desc.reserved06.len:
        volatileStore(addr desc.reserved06[i], 0'u8)

    proc nimConnEmDescPtr(off: uint16): uint16 {.inline.} =
      nimConnDescPtr(off)

    proc nimConnTxDescBaseOffsetForHandle(handle: uint16): uint16 {.inline.} =
      ## Match vendor lld_con_start: connection TX descriptors start at
      ## 0x558 + 7 * conhdl * sizeof(tx_desc), with two descriptors per link.
      NimConnTxDescBaseOffset +
        uint16(uint32(handle and 0x00FF'u16) *
               uint32(NimConnTxDescPerHandleStride))

    proc nimConnTxDescOffset(slot: uint8): uint16 {.inline.} =
      nim_conn_state.txDescBaseOffset + uint16((slot and 1'u8) shl 4)

    proc captureNimConnStartSnapshot(conhdl: uint16) =
      let txBase = nimConnTxDescBaseOffsetForHandle(conhdl)
      for i in 0 ..< nim_conn_start_em_snapshot.len:
        nim_conn_start_em_snapshot[i] =
          read32(nimConnEmAddr(conhdl, uint32(i) * 4'u32))
      for i in 0 ..< nim_conn_start_rx_snapshot.len:
        nim_conn_start_rx_snapshot[i] =
          read32(BTBLE_EM_BASE + BtbleRxDescRingBaseOffset + uint32(i) * 4'u32)
      for i in 0 ..< nim_conn_start_tx_snapshot.len:
        nim_conn_start_tx_snapshot[i] =
          read32(BTBLE_EM_BASE + uint32(txBase) + uint32(i) * 4'u32)
      nim_conn_start_reg_snapshot[0] =
        regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
      nim_conn_start_reg_snapshot[1] =
        regRead((BLE_BASE + BTBLE_INTSTAT_OFFSET).uint)
      nim_conn_start_reg_snapshot[2] =
        regRead((BLE_BASE + BTBLE_INTDETAIL_OFFSET).uint)
      nim_conn_start_reg_snapshot[3] = regRead((BLE_BASE + 0x100'u32).uint)
      nim_conn_start_reg_snapshot[4] = regRead((BLE_BASE + 0x104'u32).uint)
      nim_conn_start_reg_snapshot[5] = regRead((BLE_BASE + 0x828'u32).uint)
      nim_conn_start_reg_snapshot[6] = regRead((BLE_BASE + 0x800'u32).uint)
      nim_conn_start_reg_snapshot[7] = regRead((BLE_BASE + 0x9C0'u32).uint)

    proc nimConnNormalizeFine(clock: var uint32, fine: var int32) =
      while fine < 0'i32:
        fine += int32(NimConnHalfUsPerHalfSlot)
        clock = (clock - 1'u32) and 0x0FFFFFFF'u32
      while fine >= int32(NimConnHalfUsPerHalfSlot):
        fine -= int32(NimConnHalfUsPerHalfSlot)
        clock = (clock + 1'u32) and 0x0FFFFFFF'u32

    proc nimConnExpandClock(rawClock, referenceClock: uint32): uint32 =
      let reference = referenceClock and 0x0FFFFFFF'u32
      let rawLow = rawClock and 0x0000FFFF'u32
      var candidate = (reference and 0x0FFF0000'u32) or rawLow
      let ahead = (candidate - reference) and 0x0FFFFFFF'u32
      if ahead < 0x08000000'u32:
        if ahead > 0x00008000'u32:
          candidate = (candidate - 0x00010000'u32) and 0x0FFFFFFF'u32
      else:
        let behind = (reference - candidate) and 0x0FFFFFFF'u32
        if behind > 0x00008000'u32:
          candidate = (candidate + 0x00010000'u32) and 0x0FFFFFFF'u32
      candidate and 0x0FFFFFFF'u32

    proc nimConnPeripheralAcquired(): bool {.inline.} =
      nim_conn_state.centralRole or
        nim_conn_state.rxAcquiredEvents >= NimConnPeripheralAcquireRxEvents

    proc nimConnCrcInit(params: ptr NimLldConStartParamsView): uint32 {.inline.} =
      uint32(params.crcInit[0]) or
        (uint32(params.crcInit[1]) shl 8) or
        (uint32(params.crcInit[2]) shl 16)

    proc nimConnLegacyLeadSelector(params: ptr NimLldConStartParamsView): uint8 {.inline.} =
      uint8(params.peerRxAddrType shr 8)

    proc nimConnChannelSelection2(params: ptr NimLldConStartParamsView): bool {.inline.} =
      (params.peerRxAddrType and 0x00FF'u16) != 0'u16

    proc nimConnAnchorFromTiming(params: ptr NimLldConStartParamsView,
                                 outFine: var uint16): uint32 =
      refreshNimSyncPositions()
      let rateIdx = params.rate
      let syncPos =
        if rateIdx.int < lld_exp_sync_pos_tab.len:
          lld_exp_sync_pos_tab[rateIdx.int]
        else:
          0'u16
      var clock = params.timingClock and 0x0FFFFFFF'u32
      var fine = int32(params.timingFine) + int32(syncPos) * 2'i32
      nimConnNormalizeFine(clock, fine)
      outFine = uint16(fine)

      let windowSizeHalfSlots =
        uint32(params.transmitWindowSize) * NimConnHalfSlotsPerConnIntervalUnit
      let windowOffsetHalfSlots =
        uint32(params.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit
      var phyLeadHalfSlots =
        if rateIdx <= 1'u8: 8'u32 else: 12'u32
      if (uint16(nimConnLegacyLeadSelector(params)) and NimConnAdvTypeTimingBit) == 0'u16:
        phyLeadHalfSlots = 4'u32
      (clock + (windowSizeHalfSlots shr 1) + windowOffsetHalfSlots +
       phyLeadHalfSlots) and 0x0FFFFFFF'u32

    proc nimConnAnchorFromRxTimestamp(rawClock: uint32, rawFine: uint16,
                                      outFine: var uint16): uint32 =
      ## Match the lld_con_frm_cbk timing recovery path: convert the RX
      ## descriptor timestamp back to the current data-channel anchor.
      refreshNimSyncPositions()
      let syncPos =
        if nim_conn_state.rate.int < lld_exp_sync_pos_tab.len:
          lld_exp_sync_pos_tab[nim_conn_state.rate.int]
        else:
          0'u16
      var clock = nimConnExpandClock(rawClock, nim_conn_state.nextAnchor)
      var fine =
        int32(NimConnHalfUsPerHalfSlot - 1'u32) -
        int32(rawFine and 0x03FF'u16) -
        int32(syncPos) * 2'i32
      nimConnNormalizeFine(clock, fine)
      outFine = uint16(fine)
      clock and 0x0FFFFFFF'u32

    proc nimConnScheduleTarget(anchor: uint32, anchorFine: uint16,
                               targetClock: var uint32,
                               targetFine: var uint16): uint32 =
      targetClock = anchor
      var fine = uint32(anchorFine)
      let windowHalfUs = nim_conn_state.rxWindowHalfUs
      if windowHalfUs != 0'u32:
        result = lld_rx_timing_compute(nim_conn_state.timingReferenceClock,
                                       addr targetClock,
                                       addr fine,
                                       nim_conn_state.peerDriftPpm,
                                       nim_conn_state.rate,
                                       windowHalfUs)
      else:
        result = 0'u32
      targetFine = uint16(fine and 0xFFFF'u32)

    proc nimConnRxSyncPosition(): uint16 =
      if nim_conn_state.phy == 3'u8:
        NimConnCodedSyncPosition
      else:
        NimConnLe1mSyncPosition

    proc nimConnRxWindowControl(rxTimingHalfUs: uint32): uint16 {.inline.} =
      ## Match lld_con_evt_start_cbk's EM +0x1E update for normal peripheral
      ## timing: small windows are programmed in half-microsecond units, while
      ## larger windows use the high-bit slot-encoded form.
      let half = (rxTimingHalfUs + 1'u32) shr 1
      if half >= 0x4000'u32:
        0x8000'u16 or
          uint16(((half + NimConnHalfUsPerHalfSlot - 1'u32) div
                  NimConnHalfUsPerHalfSlot) and 0x7FFF'u32)
      else:
        uint16((half + 1'u32) and 0xFFFF'u32)

    proc nimConnProgramRxTiming(conhdl: uint16) =
      let timing =
        if not nim_conn_state.directAnchorMode and
            nim_conn_state.rxTimingHalfUs != 0'u32:
          nimConnRxWindowControl(nim_conn_state.rxTimingHalfUs)
        else:
          nimConnRxSyncPosition()
      nimConnEventSetRxSync(conhdl, timing)

    proc nimConnTxOctets(): uint16 =
      result = NimBleLeMaxDataOctets
      if nim_llcp_state.localTxOctets != 0'u16:
        result = nim_llcp_state.localTxOctets
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxRxOctets)

    proc nimConnTxTime(): uint16 =
      result = NimBleLeMaxDataTime
      if nim_llcp_state.localTxTime != 0'u16:
        result = nim_llcp_state.localTxTime
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxRxTime)

    proc nimConnRxOctets(): uint16 =
      result = NimBleLeMaxDataOctets
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxTxOctets)

    proc nimConnRxTime(): uint16 =
      result = NimBleLeMaxDataTime
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxTxTime)

    proc nimConnEffectivePacketTimeUs(octets, maxTime: uint16,
                                      rate: uint8): uint32 =
      ## lld_con_evt_time_update clamps the configured max packet time to the
      ## actual packet airtime before writing the connection EM duration fields.
      let airtime = uint32(ble_util_pkt_dur_in_us(octets, rate))
      let limit = uint32(maxTime)
      if limit != 0'u32 and limit < airtime:
        limit
      else:
        airtime

    proc nimConnEventDurationHalfUs(txOctets, txTime, rxOctets, rxTime: uint16,
                                    rate: uint8): uint16 =
      let txUs = nimConnEffectivePacketTimeUs(txOctets, txTime, rate)
      let rxUs = nimConnEffectivePacketTimeUs(rxOctets, rxTime, rate)
      let duration = (txUs + rxUs + NimConnEventDurationMarginUs) * 2'u32
      if duration > 0xFFFF'u32:
        0xFFFF'u16
      else:
        uint16(duration)

    proc nimConnProgramPacketDurations(conhdl: uint16) =
      let durationHalfUs = nimConnEventDurationHalfUs(
        nimConnTxOctets(), nimConnTxTime(),
        nimConnRxOctets(), nimConnRxTime(),
        nim_conn_state.rate)
      nimConnEventSetPacketDurations(conhdl, durationHalfUs)

    proc nimConnPacketEventDurationHalfUs(): uint32 =
      ## Match lld_con_evt_time_update: the scheduler duration is the packet
      ## event duration written to EM. lld_con_evt_start_cbk programs the radio
      ## event for that packet duration plus the full RX timing window, while
      ## lld_con_sched positions the target earlier by half of that window.
      uint32(nimConnEventDurationHalfUs(
        nimConnTxOctets(), nimConnTxTime(),
        nimConnRxOctets(), nimConnRxTime(),
        nim_conn_state.rate))

    proc nimConnScheduleDurationHalfUs(): uint32 {.inline.} =
      nimConnPacketEventDurationHalfUs() + nim_conn_state.rxTimingHalfUs

    proc nimConnDataHeader(llid, pduLen: uint8,
                           moreData: bool = false): uint16 =
      ## Match vendor lld_con_tx_prog: TX descriptors carry LLID, MD, and
      ## payload length.  The BTBLE connection engine owns NESN/SN insertion.
      result = (uint16(pduLen) shl 8) or uint16(llid and 0x03'u8)
      if moreData:
        result = result or NimConnDataHeaderMoreDataBit

    proc nimConnResetTxDesc(off, nextOff: uint16) =
      let desc = nimConnDescAddr(off)
      btbleConnTxDescClear(desc, nextOff)

    proc nimConnArmTxDesc(off, nextOff, dataOff: uint16,
                          descHeader: uint16) =
      let desc = nimConnDescAddr(off)
      btbleConnTxDescSetHeader(desc, descHeader)
      btbleConnTxDescSetDataOffset(desc, dataOff)
      btbleConnTxDescSetStatus(desc, nimConnDescStatus(nextOff, softwareOwned = false))

    proc nimConnTxDescriptorComplete(): bool =
      ## Reference lld_con_frm_cbk treats a returned software-owned TX
      ## descriptor as the controller TX confirmation for LLCP/ACL payloads.
      if not nim_conn_state.txAckArmed or nim_conn_state.txAckDescOff == 0'u16:
        return false
      (btbleConnTxDescStatus(nimConnDescAddr(nim_conn_state.txAckDescOff)) and
        NimConnTxDescSoftwareOwned) != 0'u16

    proc nimConnInitTxDescriptors(conhdl: uint16) =
      ## Match vendor lld_con_start: initialize the descriptor ring, but leave
      ## descriptors software-owned until lld_con_tx_prog has real payload work.
      let firstOff = nimConnTxDescOffset(0'u8)
      let secondOff = nimConnTxDescOffset(1'u8)
      nimConnResetTxDesc(firstOff, secondOff)
      nimConnResetTxDesc(secondOff, firstOff)
      nimConnEventSetTxDescPtr(conhdl, nimConnEmDescPtr(firstOff))
      nim_conn_state.txDescCursor = 0'u8

    proc nimConnEventReached(target: uint16): bool {.inline.} =
      uint16(nim_conn_state.eventCounter - target) < 0x8000'u16

    proc nimConnApplyPendingConnectionUpdate() =
      if not nim_conn_state.connUpdatePending:
        return
      if not nimConnEventReached(nim_conn_state.connUpdateInstant):
        return
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.pendingWinOffsetSlots) and
        0x0FFFFFFF'u32
      if nim_conn_state.pendingIntervalSlots != 0'u32:
        nim_conn_state.intervalSlots = nim_conn_state.pendingIntervalSlots
      if nim_conn_state.pendingSupervisionSlots != 0'u32:
        nim_conn_state.supervisionSlots = nim_conn_state.pendingSupervisionSlots
      if nim_conn_state.pendingWinSizeHalfUs != 0'u32:
        nim_conn_state.rxWindowHalfUs = nim_conn_state.pendingWinSizeHalfUs
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
        nim_conn_state.rxAcquiredEvents = 0
        nim_conn_rx_acquire_events = 0
      let notifyHost = nim_conn_state.connUpdateNotifyHost
      let interval = nim_conn_state.pendingIntervalUnits
      let latency = nim_conn_state.pendingLatency
      let timeout = nim_conn_state.pendingTimeoutUnits
      nim_conn_state.connUpdatePending = false
      nim_conn_state.pendingIntervalSlots = 0
      nim_conn_state.pendingSupervisionSlots = 0
      nim_conn_state.pendingWinOffsetSlots = 0
      nim_conn_state.pendingWinSizeHalfUs = 0
      nim_conn_state.pendingIntervalUnits = 0
      nim_conn_state.pendingLatency = 0
      nim_conn_state.pendingTimeoutUnits = 0
      nim_conn_state.connUpdateNotifyHost = false
      if notifyHost:
        sendLeConnectionUpdateCompleteValues(nim_conn_state.handle,
          HciStatusSuccess, interval, latency, timeout)

    proc nimConnRecordTxHeader(header: uint16, pduLen: uint8) =
      when defined(BleDebugCounters):
        let slot = nim_conn_tx_header_log_index and 0x0F'u32
        nim_conn_tx_header_log[slot.int] =
          uint32(header) or (uint32(nim_conn_state.eventCounter) shl 16)
        var state = uint32(ord(nim_conn_state.txKind)) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 4) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 5) or
          (uint32(nim_conn_state.txPendingSeq and 1'u8) shl 6)
        if nim_llcp_tx_pending != 0'u32:
          state = state or (1'u32 shl 8)
        if nim_conn_state.txAckArmed:
          state = state or (1'u32 shl 9)
        if nim_conn_state.txAckObserved:
          state = state or (1'u32 shl 10)
        nim_conn_tx_state_log[slot.int] = state
        nim_conn_tx_header_log_index = nim_conn_tx_header_log_index + 1'u32

    proc nimConnRecordRxSeq(header: uint16, peerNesn, peerSn,
                            txSeqBefore: uint8, llcpPending,
                            llcpAcked: bool) =
      when defined(BleDebugCounters):
        let slot = nim_conn_rx_seq_log_index and 0x0F'u32
        nim_conn_rx_seq_log[slot.int] =
          uint32(header) or (uint32(nim_conn_state.eventCounter) shl 16)
        var state =
          uint32(peerNesn and 1'u8) or
          (uint32(peerSn and 1'u8) shl 1) or
          (uint32(txSeqBefore and 1'u8) shl 2) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 3) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 4) or
          (uint32(nim_conn_state.txPendingSeq and 1'u8) shl 5)
        if llcpPending:
          state = state or (1'u32 shl 8)
        if nim_conn_state.txAckArmed:
          state = state or (1'u32 shl 9)
        if nim_conn_state.txAckObserved:
          state = state or (1'u32 shl 10)
        if llcpAcked:
          state = state or (1'u32 shl 11)
        nim_conn_rx_state_log[slot.int] = state
        nim_conn_rx_seq_log_index = nim_conn_rx_seq_log_index + 1'u32

    proc nimConnRecordSchEvent(timestamp: uint32, event: uint8) =
      when defined(BleDebugCounters):
        let slot = int(nim_conn_sch_event_log_index and 0x0F'u32)
        let intStat = regRead(BLE_BASE + 0x024'u32)
        let eventSlot = (intStat shr 24) and 0x0F'u32
        let slotStatus = uint32(read16(BTBLE_EM_BASE + eventSlot * 0x10'u32))
        nim_conn_sch_event_code_log[slot] =
          event.uint32 or (eventSlot shl 8) or (slotStatus shl 16)
        nim_conn_sch_event_time_log[slot] = timestamp and 0x0FFFFFFF'u32
        nim_conn_sch_event_now_log[slot] = currentBtbleTime()
        nim_conn_sch_event_state_log[slot] =
          (if nim_conn_state.active: 1'u32 else: 0'u32) or
          (if nim_conn_state.centralRole: 2'u32 else: 0'u32) or
          (if nim_conn_state.directAnchorMode: 4'u32 else: 0'u32) or
          (if nim_conn_state.reschedulePending: 8'u32 else: 0'u32) or
          (uint32(nim_conn_state.eventCounter) shl 16)
        nim_conn_sch_event_counts_log[slot] =
          uint32(nim_conn_state.txDescCursor and 0x0F'u8) or
          (uint32(ord(nim_conn_state.txKind) and 0x0F) shl 4) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 8) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 9) or
          (uint32(nim_conn_state.rxNextExpectedSeq and 1'u8) shl 10) or
          (uint32(nim_conn_state.lastRxEventCounter) shl 16)
        nim_conn_sch_event_int_log[slot] = intStat
        nim_conn_sch_event_log_index = nim_conn_sch_event_log_index + 1'u32

    proc nimConnChannelUsed(ch: uint8): bool =
      if ch >= 37'u8:
        return false
      let bit = ch and 0x07'u8
      (nim_conn_state.channelMap[(ch shr 3).int] and (1'u8 shl bit)) != 0

    proc nimConnBuildRemap() =
      nim_conn_state.usedChannelCount = 0
      for ch in 0'u8 .. 36'u8:
        if nimConnChannelUsed(ch):
          nim_conn_state.remap[nim_conn_state.usedChannelCount.int] = ch
          inc nim_conn_state.usedChannelCount
      if nim_conn_state.usedChannelCount >= 2'u8:
        return
      nim_conn_state.channelMap = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0x1F]
      nim_conn_state.usedChannelCount = 0
      for ch in 0'u8 .. 36'u8:
        nim_conn_state.remap[nim_conn_state.usedChannelCount.int] = ch
        inc nim_conn_state.usedChannelCount

    proc nimConnPermute(value: uint16): uint16 {.inline.} =
      var x = value
      x = ((x and 0xAAAA'u16) shr 1) or ((x and 0x5555'u16) shl 1)
      x = ((x and 0xCCCC'u16) shr 2) or ((x and 0x3333'u16) shl 2)
      x = ((x and 0xF0F0'u16) shr 4) or ((x and 0x0F0F'u16) shl 4)
      ((x and 0xFF00'u16) shr 8) or ((x and 0x00FF'u16) shl 8)

    proc nimConnMam(a, b: uint16): uint16 {.inline.} =
      uint16((uint32(a) * 17'u32 + uint32(b)) and 0xFFFF'u32)

    proc nimConnCsa2Prn(counter: uint16): uint16 =
      let channelId = uint16(
        ((nim_conn_state.accessAddress shr 16) xor
         (nim_conn_state.accessAddress and 0xFFFF'u32)) and 0xFFFF'u32)
      var prn = counter xor channelId
      prn = nimConnPermute(prn)
      prn = nimConnMam(prn, channelId)
      prn = nimConnPermute(prn)
      prn = nimConnMam(prn, channelId)
      prn = nimConnPermute(prn)
      nimConnMam(prn, channelId)

    proc nimConnHopIncrement(): uint8 {.inline.} =
      if nim_conn_state.hopIncrement == 0'u8: 5'u8
      else: nim_conn_state.hopIncrement

    proc nimConnAdvanceCsa1Unmapped(unmapped: uint8,
                                    eventDelta: uint16): uint8 {.inline.} =
      let base =
        if unmapped <= 36'u8: uint32(unmapped)
        else: 0'u32
      uint8((base + uint32(nimConnHopIncrement()) * uint32(eventDelta)) mod
            37'u32)

    proc nimConnAdvanceCsa1ChannelState(eventDelta: uint16) =
      ## Mirror the vendor lld_evt_channel_next state update.  CSA#1 advances
      ## an unmapped channel state, then the event-start path writes that
      ## channel state into EM +0x18.  The BTBLE engine applies the connection
      ## channel map from EM for the actual data channel.
      if eventDelta == 0'u16 or nim_conn_state.channelSelection2:
        return
      nim_conn_state.emUnmappedChannel =
        nimConnAdvanceCsa1Unmapped(nim_conn_state.emUnmappedChannel,
                                   eventDelta)

    proc nimConnMappedChannel(unmapped: uint8): uint8 =
      if nimConnChannelUsed(unmapped):
        unmapped
      else:
        nim_conn_state.remap[
          (unmapped mod nim_conn_state.usedChannelCount).int]

    proc nimConnSelectChannel(): uint8 =
      if nim_conn_state.usedChannelCount == 0'u8:
        nim_conn_state.lastUnmappedChannel = 0'u8
        return 0'u8
      if nim_conn_state.channelSelection2:
        let prn = nimConnCsa2Prn(nim_conn_state.eventCounter)
        let unmapped = uint8((uint32(prn) * 37'u32) shr 16)
        nim_conn_state.lastUnmappedChannel = unmapped
        if nimConnChannelUsed(unmapped):
          return unmapped
        let remapIdx =
          (uint32(nim_conn_state.usedChannelCount) * uint32(prn)) shr 16
        return nim_conn_state.remap[remapIdx.int]

      nim_conn_state.lastUnmappedChannel =
        if nim_conn_state.emUnmappedChannel <= 36'u8:
          nim_conn_state.emUnmappedChannel
        else:
          0'u8
      nimConnMappedChannel(nim_conn_state.lastUnmappedChannel)

    proc nimConnApplyPendingChannelMap() =
      if not nim_conn_state.channelMapPending:
        return
      if not nimConnEventReached(nim_conn_state.channelMapInstant):
        return
      for i in 0 ..< nim_conn_state.channelMap.len:
        nim_conn_state.channelMap[i] = nim_conn_state.pendingChannelMap[i]
      nim_conn_state.channelMap[4] = nim_conn_state.channelMap[4] and 0x1F'u8
      nimConnBuildRemap()
      nim_conn_state.channelMapPending = false

    proc nimConnReceiveChannelMapIndBytes(pdu: ptr UncheckedArray[uint8],
                                          pduLen: uint8) =
      if pdu == nil or pduLen < 8'u8:
        return
      let body = nimLlcpChannelMapIndAt(pdu)
      for i in 0 ..< nim_conn_state.pendingChannelMap.len:
        nim_conn_state.pendingChannelMap[i] = body.channelMap[i]
      nim_conn_state.pendingChannelMap[4] =
        nim_conn_state.pendingChannelMap[4] and 0x1F'u8
      nim_conn_state.channelMapInstant = body.instant
      nim_conn_state.channelMapPending = true
      nimConnApplyPendingChannelMap()

    proc nimConnReceiveChannelMapInd(dataOff: uint16, pduLen: uint8) =
      nimConnReceiveChannelMapIndBytes(
        cast[ptr UncheckedArray[uint8]](BTBLE_EM_BASE + uint32(dataOff)),
        pduLen)

    proc nimConnReceiveConnectionUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                                pduLen: uint8) =
      if pdu == nil or pduLen < 12'u8:
        return
      let update = nimLlcpConnectionUpdateIndAt(pdu)
      let interval = update.interval
      let latency = update.latency
      let timeout = update.timeout
      if interval < 6'u16 or interval > 3200'u16:
        return
      if latency > 499'u16:
        return
      if timeout < 10'u16 or timeout > 3200'u16:
        return
      nimConnStorePendingConnectionUpdate(update.winSize, update.winOffset,
        interval, latency, timeout, update.instant, notifyHost = true)
      nimConnApplyPendingConnectionUpdate()

    proc nimConnReceivePhyUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                         pduLen: uint8) =
      if pdu == nil or pduLen < 5'u8:
        return
      let masterToSlave = pdu[1]
      let slaveToMaster = pdu[2]
      if (masterToSlave == 0'u8 or masterToSlave == NimLlcpPhy1M) and
          (slaveToMaster == 0'u8 or slaveToMaster == NimLlcpPhy1M):
        nim_conn_state.rate = 0'u8
        nim_conn_state.phy = NimLlcpPhy1M

    proc nimConnProgramTxDescriptors() =
      let llcpPending = nim_llcp_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxLlcp
      let aclPayloadPending = nim_acl_host_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen != 0'u8
      let aclEmptyPending = nim_acl_empty_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen == 0'u8
      if (llcpPending or aclPayloadPending) and
          nim_conn_state.txAckArmed and not nimConnTxDescriptorComplete():
        return
      if llcpPending and nim_conn_state.txProgrammed and
          nim_conn_state.txProgrammedEvent == nim_conn_state.eventCounter:
        return
      var llid = NimDataLlIdContinuation
      var emOff = NimConnEmptyDataEmOffset
      var pduLen = 0'u8
      if llcpPending:
        llid = NimDataLlIdControl
        emOff = nim_conn_state.txEmOffset
        pduLen = nim_conn_state.txLen
      elif aclPayloadPending or aclEmptyPending:
        llid =
          if nim_conn_state.txLen == 0'u8:
            NimDataLlIdContinuation
          else:
            NimDataLlIdStart
        emOff = nim_conn_state.txEmOffset
        pduLen = nim_conn_state.txLen

      let header = nimConnDataHeader(llid, pduLen)

      let descSlot = nim_conn_state.txDescCursor and 1'u8
      let descOff = nimConnTxDescOffset(descSlot)
      let nextOff = nimConnTxDescOffset(descSlot xor 1'u8)
      if pduLen == 0'u8:
        btbleEmWrite8(NimConnEmptyDataEmOffset, 0'u8)
        nimConnResetTxDesc(nextOff, descOff)
        nimConnArmTxDesc(descOff, nextOff, NimConnEmptyDataEmOffset, header)
        nimConnEventSetTxDescPtr(nim_conn_state.handle, nimConnEmDescPtr(descOff))
        nim_conn_state.txDescCursor = descSlot xor 1'u8
        nim_conn_state.txProgrammed = false
        nim_conn_state.txProgrammedEvent = 0'u16
        nim_conn_state.txAckDescOff = 0'u16
        nimConnRecordTxHeader(header, pduLen)
        return

      nimConnResetTxDesc(nextOff, descOff)
      nimConnArmTxDesc(descOff, nextOff, emOff, header)
      nimConnEventSetTxDescPtr(nim_conn_state.handle, nimConnEmDescPtr(descOff))
      nim_conn_state.txDescCursor = descSlot xor 1'u8
      if pduLen != 0'u8:
        nim_conn_state.txProgrammed = true
        nim_conn_state.txProgrammedEvent = nim_conn_state.eventCounter
        if (llcpPending or aclPayloadPending) and not nim_conn_state.txAckArmed:
          nim_conn_state.txAckArmed = true
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent =
            nim_conn_state.eventCounter + 1'u16
          nim_conn_state.txAckDescOff = descOff
      nimConnRecordTxHeader(header, pduLen)

    proc nimConnArmPendingHostAclTx() =
      if not nim_conn_state.active:
        return
      if nim_acl_host_tx_pending == 0'u32:
        return
      if nim_llcp_tx_pending != 0'u32:
        return
      if nim_acl_empty_tx_pending != 0'u32:
        return
      if nim_conn_state.txKind == nimConnTxAclData and
          nim_conn_state.txLen != 0'u8:
        return
      let tx = nimConnTxElementAt(addr nim_acl_host_tx_buf[0])
      let len = tx.length
      if len == 0'u16 or len > NimBleLeMaxDataOctets:
        nim_acl_host_tx_pending = 0
        inc nim_acl_host_tx_reject_count
        return
      nim_conn_state.txKind = nimConnTxAclData
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(len)
      nim_conn_state.txPendingSeq = nim_conn_state.txSeq
      nim_conn_state.txAckArmed = false
      nim_conn_state.txAckObserved = false
      nim_conn_state.txAckEligibleEvent = 0'u16
      nim_conn_state.txAckDescOff = 0'u16
      nim_conn_state.txProgrammed = false
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnProgramTxDescriptors()

    proc nimConnProgramEm(conhdl: uint16) =
      let base = nimConnEmAddr(conhdl, 0)
      for off in countup(0'u32, NimConnEmStride - 2'u32, 2'u32):
        write16(base + off, 0'u16)

      let activityType =
        if nim_conn_state.directAnchorMode: 0x0002'u16 else: 0x0003'u16
      let event = nimConnEventView(conhdl)
      volatileStore(addr event.activityType, activityType)
      volatileStore(addr event.control,
        uint16(((conhdl and 0x00FF'u16) shl 8) or 0x0020'u16))
      let phyControl =
        NimConnPhyControlBase or
        uint16(uint32(nim_conn_state.rate) * uint32(NimConnPhyControlStep))
      volatileStore(addr event.phyControl, phyControl)
      volatileStore(addr event.accessAddrLow,
        uint16(nim_conn_state.accessAddress and 0xFFFF'u32))
      volatileStore(addr event.accessAddrHigh,
        uint16((nim_conn_state.accessAddress shr 16) and 0xFFFF'u32))
      volatileStore(addr event.crcInitLow,
        uint16(nim_conn_state.crcInit and 0xFFFF'u32))
      let crcHigh =
        uint16((nim_conn_state.crcInit shr 16) and 0x00FF'u32)
      volatileStore(addr event.crcInitHigh, crcHigh)
      volatileStore(addr event.rfConfig, uint16(rwip_rf[NimConnRfConfigIndex]))
      volatileStore(addr event.eventCountEnable, 1'u16)
      volatileStore(addr event.rxSync, nimConnRxSyncPosition())
      volatileStore(addr event.txDescPtr, nimConnEmDescPtr(nimConnTxDescOffset(0'u8)))
      nimConnProgramPacketDurations(conhdl)
      volatileStore(addr event.channelMap01,
        uint16(nim_conn_state.channelMap[0]) or
        (uint16(nim_conn_state.channelMap[1]) shl 8))
      volatileStore(addr event.channelMap23,
        uint16(nim_conn_state.channelMap[2]) or
        (uint16(nim_conn_state.channelMap[3]) shl 8))
      volatileStore(addr event.channelMapHop,
        uint16(nim_conn_state.channelMap[4] and 0x1F'u8) or
        (uint16(nim_conn_state.hopIncrement and 0x1F'u8) shl 8))
      volatileStore(addr event.rxTiming, NimConnRxTimingDefault)
      volatileStore(addr event.reserved3A, 0'u16)
      volatileStore(addr event.eventCounter, nim_conn_state.eventCounter)
      volatileStore(addr event.eventCounterAux0, 0'u16)
      volatileStore(addr event.eventCounterAux1, 0'u16)
      volatileStore(addr event.eventCounterAux2, 0'u16)
      nimConnInitTxDescriptors(conhdl)
      nimConnProgramTxDescriptors()

    proc nimConnProgramChannel(conhdl: uint16): uint8 =
      let channel = nimConnSelectChannel()
      # Connection-event retuning is owned by the BTBLE scheduler from the EM
      # channel control word.  CSA#2 is selected by the hardware bit in the
      # control word, matching vendor lld_con_start; CSA#1 keeps the current
      # unmapped channel in the low bits.
      let emChannel =
        if nim_conn_state.channelSelection2:
          0'u8
        elif nim_conn_state.lastUnmappedChannel <= 36'u8:
          nim_conn_state.lastUnmappedChannel
        else:
          0'u8
      let channelField =
        if emChannel <= 36'u8: emChannel else: 0'u8
      var channelWord =
        NimConnChannelEnableBit or
        (uint16(nim_conn_state.hopIncrement and 0x1F'u8) shl 8) or
        uint16(channelField and 0x3F'u8)
      if nim_conn_state.channelSelection2:
        channelWord = channelWord or NimConnChannelSelect2Bit
      nimConnEventSetChannel(conhdl, channelWord)
      nimConnEventSetEventCounter(conhdl, nim_conn_state.eventCounter)
      nim_conn_last_channel = channel.uint32
      nim_conn_last_unmapped_channel = nim_conn_state.lastUnmappedChannel.uint32
      nim_conn_last_channel_word = channelWord.uint32
      nim_conn_last_event_counter = nim_conn_state.eventCounter.uint32
      channel

    proc nimConnClockAhead(target, now: uint32): bool {.inline.} =
      ((target - now) and 0x0FFFFFFF'u32) < 0x08000000'u32

    proc nimConnClockReached(target, now: uint32): bool {.inline.} =
      ((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32

    proc nimConnScheduleLeadSlotsForCurrentEvent(): uint32 {.inline.} =
      if nim_conn_state.centralRole and
          nim_conn_state.eventCounter == 0'u16:
        NimConnInitialCentralScheduleLeadSlots
      else:
        NimConnScheduleLeadSlots

    proc nimConnAdvanceEventForSchedule() =
      nimConnAdvanceCsa1ChannelState(1'u16)
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots) and
        0x0FFFFFFF'u32
      nim_conn_state.eventCounter = nim_conn_state.eventCounter + 1'u16

    proc nimConnSchedule() =
      if not nim_conn_state.active:
        return
      var now = currentBtbleTime()
      var targetClock: uint32
      var targetFine: uint16
      var scheduled = false
      while not scheduled:
        nimConnApplyPendingConnectionUpdate()
        targetClock = nim_conn_state.nextAnchor
        targetFine = nim_conn_state.anchorFine
        nim_conn_state.rxTimingHalfUs =
          nimConnScheduleTarget(nim_conn_state.nextAnchor,
                                nim_conn_state.anchorFine,
                                targetClock,
                                targetFine)
        let delta = (targetClock - now) and 0x0FFFFFFF'u32
        let leadSlots = nimConnScheduleLeadSlotsForCurrentEvent()
        if nimConnClockAhead(targetClock, now):
          if delta > leadSlots:
            nimConnApplyPendingChannelMap()
            discard nimConnProgramChannel(nim_conn_state.handle)
            scheduled = true
            continue
        nimConnAdvanceEventForSchedule()

      nimConnProgramRxTiming(nim_conn_state.handle)
      nimConnProgramTxDescriptors()

      var scheduleDuration =
        nimConnScheduleDurationHalfUs()
      let intervalDuration =
        nim_conn_state.intervalSlots * NimConnHalfUsPerHalfSlot
      if intervalDuration > NimConnScheduleDurationMarginHalfUs and
          scheduleDuration >= intervalDuration:
        scheduleDuration = intervalDuration - NimConnScheduleDurationMarginHalfUs

      if nim_conn_first_schedule_snapshot[0] == 0'u32:
        nim_conn_first_schedule_snapshot[0] =
          0x80000000'u32 or nim_conn_state.eventCounter.uint32
        nim_conn_first_schedule_snapshot[1] = now
        nim_conn_first_schedule_snapshot[2] = nim_conn_state.nextAnchor
        nim_conn_first_schedule_snapshot[3] = nim_conn_state.anchorFine.uint32
        nim_conn_first_schedule_snapshot[4] = targetClock
        nim_conn_first_schedule_snapshot[5] = targetFine.uint32
        nim_conn_first_schedule_snapshot[6] = nim_conn_state.rxTimingHalfUs
        nim_conn_first_schedule_snapshot[7] =
          (targetClock - now) and 0x0FFFFFFF'u32
        nim_conn_first_schedule_snapshot[8] = scheduleDuration
        nim_conn_first_schedule_snapshot[9] = nim_conn_state.intervalSlots
        nim_conn_first_schedule_snapshot[10] = nim_conn_state.rxWindowHalfUs
        nim_conn_first_schedule_snapshot[11] =
          nim_conn_state.timingReferenceClock

      nim_conn_last_schedule_now = now
      nim_conn_last_schedule_target = targetClock
      nim_conn_last_schedule_fine = targetFine.uint32
      nim_conn_last_schedule_delta = (targetClock - now) and 0x0FFFFFFF'u32
      nim_conn_last_schedule_duration = scheduleDuration
      nim_conn_last_rx_timing = nim_conn_state.rxTimingHalfUs
      nim_conn_last_schedule_anchor = nim_conn_state.nextAnchor
      nim_conn_last_schedule_anchor_fine = nim_conn_state.anchorFine.uint32
      let schedIdx = nim_conn_sched_log_index and 0x07'u32
      nim_conn_sched_now_log[schedIdx.int] = now
      nim_conn_sched_target_log[schedIdx.int] = targetClock
      nim_conn_sched_delta_log[schedIdx.int] = nim_conn_last_schedule_delta
      nim_conn_sched_duration_log[schedIdx.int] = scheduleDuration
      nim_conn_sched_event_log[schedIdx.int] = nim_conn_state.eventCounter.uint32
      nim_conn_sched_channel_log[schedIdx.int] =
        nim_conn_last_channel or
        (nim_conn_last_unmapped_channel shl 8) or
        (nim_conn_last_channel_word shl 16)
      nim_conn_sched_timing_log[schedIdx.int] =
        targetFine.uint32 or
        ((nim_conn_state.rxTimingHalfUs and 0xFFFF'u32) shl 16)
      nim_conn_sched_log_index = nim_conn_sched_log_index + 1'u32

      discard c_memset(addr nim_conn_sch_prog[0], 0,
                       nim_conn_sch_prog.len.csize_t)
      let req = cast[ptr SchProgRequestView](addr nim_conn_sch_prog[0])
      req.callback = cast[uint32](cast[uint](nimConnSchProgCb))
      req.targetTime = targetClock
      req.fineTime = targetFine
      req.duration = scheduleDuration
      req.context = uint32(nim_conn_state.handle)
      req.primaryType = rwip_priority[10]
      req.rate0 = 0'u8
      req.rate1 = 0'u8
      req.tail = 0x1F'u8
      req.eventIndex = uint8(nim_conn_state.handle and 0x00FF'u16)
      sch_prog_push(addr nim_conn_sch_prog[0])

    proc nimConnObserveRxHeader(header: uint16,
                                rxClock: uint32 = 0'u32,
                                rxFine: uint16 = 0'u16) =
      if not nim_conn_state.active:
        return
      noteNimPeripheralConnected(nim_conn_state.handle)
      let hadRx = nim_conn_state.rxObserved
      let prevRxEventCounter = nim_conn_state.lastRxEventCounter
      let firstRxInEvent =
        (not nim_conn_state.rxObserved) or
        nim_conn_state.lastRxEventCounter != nim_conn_state.eventCounter
      nim_conn_state.rxObserved = true
      if rxClock != 0'u32 and firstRxInEvent:
        if nim_conn_state.centralRole:
          let observedClock =
            nimConnExpandClock(rxClock, nim_conn_state.nextAnchor)
          nim_conn_state.nextAnchor = observedClock
          nim_conn_state.anchorFine = rxFine and 0x03FF'u16
          nim_conn_state.timingReferenceClock = observedClock
        else:
          let consecutive =
            hadRx and uint16(nim_conn_state.eventCounter -
                             prevRxEventCounter) == 1'u16
          if not consecutive:
            var observedFine: uint16
            let observedClock =
              nimConnAnchorFromRxTimestamp(rxClock, rxFine, observedFine)
            nim_conn_state.nextAnchor = observedClock
            nim_conn_state.anchorFine = observedFine
            nim_conn_state.timingReferenceClock = observedClock
          if consecutive:
            if nim_conn_state.rxAcquiredEvents <
                NimConnPeripheralAcquireRxEvents:
              inc nim_conn_state.rxAcquiredEvents
          else:
            if hadRx:
              inc nim_conn_rx_acquire_reset_count
            nim_conn_state.rxAcquiredEvents = 1'u8
          nim_conn_rx_acquire_events =
            nim_conn_state.rxAcquiredEvents.uint32
          if nimConnPeripheralAcquired() and
              (nim_conn_state.rxWindowHalfUs == 0'u32 or
               nim_conn_state.rxWindowHalfUs > NimConnTrackedRxWindowHalfUs):
            nim_conn_state.rxWindowHalfUs = NimConnTrackedRxWindowHalfUs
      when defined(bl808m0) and bl808BleNimPureCentral:
        if nim_conn_state.centralRole and nim_init_complete_pending != 0'u32:
          completeNimInitiatorHciConnection(nim_conn_state.handle)
      nim_conn_state.lastRxEventCounter = nim_conn_state.eventCounter
      nim_conn_state.lastRxClock = nim_conn_state.nextAnchor
      let peerNesn = uint8((header shr 2) and 1'u16)
      let peerSn = uint8((header shr 3) and 1'u16)
      let txSeqBefore = nim_conn_state.txSeq
      let payloadFresh = peerSn == nim_conn_state.rxNextExpectedSeq
      nim_conn_state.rxPayloadFresh = payloadFresh
      let llcpPending =
        nim_llcp_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxLlcp
      let aclPayloadPending =
        nim_acl_host_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen != 0'u8
      let txAckEligible =
        (llcpPending or aclPayloadPending) and nim_conn_state.txAckArmed and
        nimConnEventReached(nim_conn_state.txAckEligibleEvent)
      let txAcked =
        txAckEligible and peerNesn != nim_conn_state.txPendingSeq
      if payloadFresh:
        nim_conn_state.rxNextExpectedSeq =
          nim_conn_state.rxNextExpectedSeq xor 1'u8
      nim_conn_state.txNesn = nim_conn_state.rxNextExpectedSeq
      if txAcked:
        nim_conn_state.txSeq = peerNesn
        nim_conn_state.txAckObserved = true
      elif peerNesn != nim_conn_state.txSeq:
        nim_conn_state.txSeq = peerNesn
      nimConnRecordRxSeq(header, peerNesn, peerSn, txSeqBefore,
                         llcpPending or aclPayloadPending, txAcked)

    proc nimConnSupervisionExpired(): bool =
      if nim_conn_state.supervisionSlots == 0'u32 or
          nim_conn_state.intervalSlots == 0'u32:
        return false
      let missedEvents =
        uint32(uint16(nim_conn_state.eventCounter -
                      nim_conn_state.lastRxEventCounter))
      missedEvents * nim_conn_state.intervalSlots >=
        nim_conn_state.supervisionSlots

    proc nimConnSupervisionClockExpired(now: uint32): bool =
      if nim_conn_state.supervisionSlots == 0'u32:
        return false
      if not nimConnClockReached(nim_conn_state.lastRxClock, now):
        return false
      let elapsed = (now - nim_conn_state.lastRxClock) and 0x0FFFFFFF'u32
      elapsed >= nim_conn_state.supervisionSlots

    proc nimConnHandleSupervisionTimeout() =
      let handle = nim_conn_state.handle
      when defined(bl808m0) and bl808BleNimPureCentral:
        if nim_conn_state.centralRole and
            nim_init_complete_pending != 0'u32:
          nim_init_complete_pending = 0
          nim_init_active = 0
          nim_init_rx_service_pending = 0
          nim_init_handoff_pending = 0
          nim_init_handoff_program_count = 0
          nim_init_handoff_tx_event_count = 0
          nim_init_handoff_ready_clock = 0
          nim_init_handoff_deadline = 0
          nim_conn_state.active = false
          nim_conn_state.reschedulePending = false
          nim_conn_started = false
          nim_init_last_status = 0x3E'u32
          sendLeConnectionCompleteStatusHandle(
            addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
            0x3E'u8, 0'u16, 0'u8)
          return
      noteNimPeripheralDisconnectedFrom(
        NimConnDiscSourceSupervisionTimeout,
        NimConnDisconnectReasonTimeout)
      sendDisconnectComplete(handle, NimConnDisconnectReasonTimeout)

    proc nimConnCompleteManualTx() =
      when bl808BleNimManualConnTx:
        if nim_llcp_tx_pending != 0'u32 and
            (nim_conn_state.txAckObserved or nimConnTxDescriptorComplete()):
          nim_llcp_tx_pending = 0
          nim_conn_state.txAckArmed = false
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent = 0'u16
          nim_conn_state.txAckDescOff = 0'u16
          nim_conn_state.txProgrammed = false
          nim_conn_state.txProgrammedEvent = 0'u16
          nim_conn_state.txKind = nimConnTxEmptyData
          nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
          nim_conn_state.txLen = 0'u8
          inc nim_llcp_free_manual_count
          nimLlcpTrySendQueued()
          nimLlcpTrySendStartup(nim_conn_state.handle)
          if nim_llcp_tx_pending == 0'u32:
            nimConnArmPendingHostAclTx()
            nimConnProgramTxDescriptors()
        if nim_acl_host_tx_pending != 0'u32 and
            nim_conn_state.txKind == nimConnTxAclData and
            nim_conn_state.txLen != 0'u8 and
            (nim_conn_state.txAckObserved or nimConnTxDescriptorComplete()):
          nim_acl_host_tx_pending = 0
          nim_conn_state.txAckArmed = false
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent = 0'u16
          nim_conn_state.txAckDescOff = 0'u16
          nim_conn_state.txProgrammed = false
          nim_conn_state.txProgrammedEvent = 0'u16
          nim_conn_state.txKind = nimConnTxEmptyData
          nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
          nim_conn_state.txLen = 0'u8
          inc nim_acl_host_tx_complete_count
          sendNumberOfCompletedPackets(nim_conn_state.handle, 1'u16)
          nimLlcpTrySendQueued()
          nimLlcpTrySendStartup(nim_conn_state.handle)
          if nim_llcp_tx_pending == 0'u32:
            nimConnProgramTxDescriptors()
        if nim_acl_empty_tx_pending != 0'u32:
          nim_acl_empty_tx_pending = 0
          nimConnArmPendingHostAclTx()
          if nim_acl_empty_tx_queued != 0'u32:
            nim_acl_empty_tx_queued = 0
            discard nimSendEmptyAclNow(nim_conn_state.handle)

    proc nimConnEventDone() =
      if not nim_conn_state.active:
        return
      when bl808BleNimManualConnTx:
        serviceNimConnectionLlcpRxDescriptors()
        nimConnCompleteManualTx()
      if not nim_conn_state.active:
        return
      nimConnAdvanceCsa1ChannelState(1'u16)
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots) and
        0x0FFFFFFF'u32
      nim_conn_state.eventCounter = nim_conn_state.eventCounter + 1'u16
      if nimConnSupervisionExpired():
        nimConnHandleSupervisionTimeout()
        return
      nim_conn_state.reschedulePending = true
      requestBtbleSwInterrupt()

    proc nimConnServiceSupervisionTimeout() =
      if not nim_conn_state.active:
        return
      if nimConnSupervisionClockExpired(currentBtbleTime()):
        nimConnHandleSupervisionTimeout()

    proc nimConnServiceDeferredSchedule() =
      if not nim_conn_state.active or not nim_conn_state.reschedulePending:
        return
      if nim_ble_wlcoex_enabled != 0'u32 and
          nim_ble_wifi_tx_window_active != 0'u32:
        inc nim_ble_wifi_tx_window_defer_count
        return
      nim_conn_state.reschedulePending = false
      nimConnSchedule()

    proc nimConnServiceMissedEventFallback() =
      if not nim_conn_state.active or nim_conn_state.reschedulePending:
        return
      if nim_conn_state.intervalSlots <= NimConnScheduleLeadSlots + 1'u32:
        return
      let now = currentBtbleTime()
      let missedEventDeadline =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots -
         NimConnScheduleLeadSlots) and 0x0FFFFFFF'u32
      if not nimConnClockReached(missedEventDeadline, now):
        return
      inc nim_conn_missed_event_fallback_count
      nimConnEventDone()

    proc nimConnSchProgCb(arg0: uint32, ctx: pointer,
                          event: uint8) {.cdecl.} =
      discard ctx
      nimConnRecordSchEvent(arg0, event)
      case event
      of 2'u8:
        when bl808BleNimManualConnTx:
          # The LLD connection frame callback drains RX descriptors before the
          # terminal event schedules the next anchor.
          serviceNimConnectionLlcpRxDescriptors()
      of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:
        nimConnEventDone()
      else:
        discard

    proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.} =
      inc nim_lld_con_start_count
      if params == nil or conhdl == 0'u16:
        nim_lld_con_start_status = 0xFF'u32
        return 0xFF'u8
      if nim_conn_state.active:
        nim_lld_con_start_status = 0x0C'u32
        return 0x0C'u8

      let start = nimLldConStartParams(params)
      let snapshotBytes = cast[ptr UncheckedArray[uint8]](params)
      for i in 0 ..< nim_lld_con_start_param.len:
        nim_lld_con_start_param[i] = snapshotBytes[i]

      discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
      nim_conn_state.active = true
      nim_conn_state.dataFlowEnabled = true
      nim_conn_state.centralRole = start.centralRole != 0'u8
      nim_conn_state.directAnchorMode = start.timingSelector == 0'u8
      nim_conn_state.handle = conhdl
      nim_conn_state.txDescBaseOffset = nimConnTxDescBaseOffsetForHandle(conhdl)
      nim_conn_state.accessAddress = start.accessAddress
      nim_conn_state.crcInit = nimConnCrcInit(start)
      nim_conn_state.intervalSlots =
        uint32(start.interval) * NimConnHalfSlotsPerConnIntervalUnit
      if nim_conn_state.intervalSlots == 0'u32:
        nim_conn_state.intervalSlots =
          24'u32 * NimConnHalfSlotsPerConnIntervalUnit
      nim_conn_state.supervisionSlots =
        uint32(start.supervisionTimeout) * NimConnHalfSlotsPerSupervisionUnit
      nim_conn_state.channelMap = start.channelMap
      nim_conn_state.channelMap[4] = nim_conn_state.channelMap[4] and 0x1F'u8
      nim_conn_state.hopIncrement = start.hopIncrement and 0x1F'u8
      if nim_conn_state.hopIncrement == 0'u8:
        nim_conn_state.hopIncrement = 5'u8
      # CSA#1 starts the first data-channel event one hop after channel zero.
      # Keep emUnmappedChannel as the unmapped channel for the next scheduled
      # event; event completion and skipped-event handling advance it after use.
      nim_conn_state.emUnmappedChannel = nimConnHopIncrement()
      nim_conn_state.channelSelection2 = nimConnChannelSelection2(start)
      nim_conn_state.rate = start.rate
      nim_conn_state.phy =
        if start.rate.int < co_rate_to_phy.len:
          co_rate_to_phy[start.rate.int]
        else:
          co_rate_to_phy[0]
      if nim_conn_state.phy == 0'u8:
        nim_conn_state.phy = co_rate_to_phy[0]
      if start.timingSelector != 0'u8:
        nim_conn_state.timingReferenceClock =
          start.timingClock and 0x0FFFFFFF'u32
        nim_conn_state.nextAnchor =
          nimConnAnchorFromTiming(start, nim_conn_state.anchorFine)
        nim_conn_state.rxWindowHalfUs =
          uint32(start.transmitWindowSize) * NimConnHalfUsPerConnWindowUnit
      else:
        nim_conn_state.nextAnchor =
          start.anchorClock and 0x0FFFFFFF'u32
        nim_conn_state.anchorFine = 0'u16
        # Direct central handoff gives the exact first master-packet time we
        # selected inside the CONNECT_IND transmit window.  A peripheral only
        # knows the peer's transmit window, so keep that acquisition window if
        # this path is enabled for a peripheral build.
        nim_conn_state.rxWindowHalfUs =
          if nim_conn_state.centralRole: 0'u32
          else: uint32(start.transmitWindowSize) * NimConnHalfUsPerConnWindowUnit
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
      let scaIdx = start.peerSleepClockAccuracy and 0x07'u8
      nim_conn_state.peerSca = scaIdx
      nim_conn_state.peerDriftPpm =
        if scaIdx.int < co_sca2ppm.len:
          uint32(co_sca2ppm[scaIdx.int])
        else:
          0'u32
      if nim_conn_state.nextAnchor == 0'u32:
        nim_conn_state.nextAnchor =
          (currentBtbleTime() +
           uint32(start.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit) and
          0x0FFFFFFF'u32
        nim_conn_state.anchorFine = 0'u16
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
      nim_conn_state.lastRxClock = nim_conn_state.nextAnchor
      nim_conn_state.txKind = nimConnTxEmptyData
      nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
      nim_conn_state.txLen = 0'u8
      nim_conn_state.rxNextExpectedSeq = 0'u8
      if nim_conn_state.centralRole:
        # A central opens the link with the first master packet and has not
        # received any slave sequence number yet.
        nim_conn_state.txNesn = 0'u8
      else:
        # The peripheral descriptor is preloaded before the central opens the
        # first data-channel event.  Seed the transmit NESN for the response to
        # that first expected central SN=0 packet; subsequent RX callbacks keep
        # it aligned with rxNextExpectedSeq before the next transmit descriptor
        # use.
        nim_conn_state.txNesn = 1'u8
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnBuildRemap()
      nimConnProgramEm(conhdl)
      sch_prog_init(3'u8)
      writeBtbleInterruptMask(BtbleIntConnection)
      nimConnSchedule()
      captureNimConnStartSnapshot(conhdl)
      nim_lld_con_start_status = 0
      0'u8

    proc nimLldConLlcpTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.} =
      if not nim_conn_state.active or conhdl != nim_conn_state.handle or buf == nil:
        return 0xFF'u8
      let tx = nimConnTxElementAt(buf)
      nim_conn_state.txKind = nimConnTxLlcp
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(tx.length)
      nim_conn_state.txPendingSeq = nim_conn_state.txSeq
      nim_conn_state.txAckArmed = false
      nim_conn_state.txAckObserved = false
      nim_conn_state.txAckEligibleEvent = 0'u16
      nim_conn_state.txAckDescOff = 0'u16
      nim_conn_state.txProgrammed = false
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnProgramTxDescriptors()
      0'u8

    proc nimLldConDataTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.} =
      if not nim_conn_state.active or conhdl != nim_conn_state.handle or buf == nil:
        return 0xFF'u8
      if nim_llcp_tx_pending != 0'u32 and
          nim_conn_state.txKind == nimConnTxLlcp:
        nim_acl_empty_tx_queued = 1
        return 0'u8
      let tx = nimConnTxElementAt(buf)
      let len = tx.length
      if len > NimBleLeMaxDataOctets:
        return HciStatusInvalidParams
      if len != 0'u16 and not nim_conn_state.dataFlowEnabled:
        return HciStatusCommandDisallowed
      if len != 0'u16 and nim_acl_host_tx_pending == 0'u32:
        return HciStatusCommandDisallowed
      nim_conn_state.txKind = nimConnTxAclData
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(len)
      nim_conn_state.txProgrammed = false
      nimConnProgramTxDescriptors()
      0'u8

  proc startNimConnectionFromConnectInd(descIdx: uint8,
                                        payload: ptr UncheckedArray[uint8],
                                        header: uint16,
                                        rxClock: uint32,
                                        rxFine: uint16) =
    nimConnMark(0x100'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("\r\n[CON] start\r\n")
    if nim_conn_started:
      nimConnMark(0x101'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] already\r\n")
      return
    nim_conn_started = true
    quiesceNimAdvertisingForConnectionHandoff()

    discard c_memset(addr nim_conn_params[0], 0,
                     nim_conn_params.len.csize_t)
    discard c_memset(addr nim_llc_msg[0], 0,
                     nim_llc_msg.len.csize_t)
    let outp = cast[ptr UncheckedArray[uint8]](addr nim_conn_params[0])
    let llc = cast[ptr UncheckedArray[uint8]](addr nim_llc_msg[0])
    for i in 0 ..< nim_connect_ind_work_payload.len:
      nim_connect_ind_work_payload[i] = payload[i]
    let raw = cast[ptr UncheckedArray[uint8]](
      addr nim_connect_ind_work_payload[0])

    # Keep this handoff byte-exact. A typed packed-object rewrite produced the
    # same-looking buffers under JTAG but hard-faulted after llc_start.
    for i in 0 ..< 4:
      outp[i] = raw[12 + i]      # access address
    outp[4] = raw[16]            # CRC init
    outp[5] = raw[17]
    outp[6] = raw[18]
    outp[7] = raw[19]            # transmit window size
    putLe16(outp, 8, getLe16(raw, 20))
    putLe16(outp, 10, getLe16(raw, 22))
    putLe16(outp, 12, getLe16(raw, 24))
    putLe16(outp, 14, getLe16(raw, 26))
    for i in 0 ..< 5:
      outp[16 + i] = raw[28 + i]
    outp[21] = raw[33] and 0x1F'u8
    outp[22] = raw[33] shr 5

    let winOffset = uint32(getLe16(raw, 20))
    let interval = uint32(getLe16(raw, 22))
    let latency = uint32(getLe16(raw, 24))
    let timeout = uint32(getLe16(raw, 26))
    let baseClock =
      if rxClock != 0'u32: rxClock and 0x0FFFFFFF'u32
      else: currentBtbleTime()
    # Direct handoff bypasses lld_con_start's timing conversion, so it must pass
    # the first LE 1M transmit-window anchor explicitly. The normal timing path
    # mirrors vendor lld_adv_frm_isr: pass normalized CONNECT_IND RX timing and
    # let lld_con_start apply the transmit-window lead exactly once.
    let firstAnchor = (baseClock +
      winOffset * NimConnHalfSlotsPerConnIntervalUnit +
      NimConnConnectIndTransmitWindowDelayHalfSlots) and
      0x0FFFFFFF'u32
    let directAnchor = addBtbleClockSlots(
      firstAnchor,
      bl808BleNimConAnchorBiasSlots)
    # Vendor co_rate_to_phy maps rate enum 0 to LE 1M.  llc_start passes this
    # value through as lld_con_start byte 37, which also selects the sync-position
    # table entry used when normal advertiser timing is converted to an anchor.
    let rateIdx = 0'u8
    var timingClock = baseClock and 0x0000FFFF'u32
    var timingFine = rxFine
    when bl808BleNimConTimingPath:
      nimConnectTiming(baseClock, rxFine, rateIdx, timingClock, timingFine)
      when bl808BleNimConTimingClockBiasSlots != 0:
        timingClock = addBtbleClockSlots(timingClock,
          bl808BleNimConTimingClockBiasSlots)
      putLe16(outp, 24, timingFine)
      putLe32(outp, 28, timingClock)
      putLe32(outp, 32, directAnchor)
      outp[36] = 1'u8            # normal advertiser timing path
    else:
      putLe32(outp, 32, directAnchor)
      outp[36] = 0'u8            # direct handoff with precomputed anchor
    outp[37] = rateIdx           # vendor rate enum: 0 maps to LE 1M
    outp[38] = uint8((header shr 5) and 0x01'u16)
    outp[39] = nimConnLegacyAdvLeadSelector()

    when bl808BleNimPureConnection:
      var snapshotAnchorFine: uint16
      let snapshotAnchor =
        nimConnAnchorFromTiming(nimLldConStartParams(addr nim_conn_params[0]),
                                snapshotAnchorFine)
      nim_connect_timing_snapshot[0] = baseClock
      nim_connect_timing_snapshot[1] = rxFine.uint32
      nim_connect_timing_snapshot[2] = timingClock
      nim_connect_timing_snapshot[3] = timingFine.uint32
      nim_connect_timing_snapshot[4] = snapshotAnchor
      nim_connect_timing_snapshot[5] = snapshotAnchorFine.uint32
      nim_connect_timing_snapshot[6] =
        uint32(outp[36]) or (uint32(outp[37]) shl 8) or
        (uint32(outp[38]) shl 16) or (uint32(outp[39]) shl 24)
      nim_connect_timing_snapshot[7] = currentBtbleTime()

    nim_conn_last_rx_clock = baseClock
    nim_conn_last_rx_fine = rxFine.uint32
    nim_conn_last_anchor = directAnchor
    nim_conn_last_win_offset = winOffset
    nim_conn_last_interval = interval
    nim_conn_last_timeout = timeout
    nim_conn_last_access_addr =
      uint32(raw[12]) or (uint32(raw[13]) shl 8) or
      (uint32(raw[14]) shl 16) or (uint32(raw[15]) shl 24)
    nim_conn_last_crcinit =
      uint32(raw[16]) or (uint32(raw[17]) shl 8) or
      (uint32(raw[18]) shl 16)

    prepareBtbleConnectionRxRingForHandoff()
    writeBtbleInterruptMask(BtbleIntConnection)
    initNimRwipRfTable()
    refreshNimSyncPositions()
    clearBtbleProgramSlots()
    nimConnMark(0x110'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] before lld\r\n")
    nim_conn_last_status =
      nimLldConStart(1'u16, addr nim_conn_params[0]).uint32
    nimConnMark(0x111'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] after lld\r\n")
    if nim_conn_last_status == 0'u32:
      noteNimAdvertiserConnected(raw, header, interval, latency, raw[33] shr 5)
      recordNimPeripheralPeer(1'u16, raw, header)
      when bl808BleNimManualConnTx:
        nimLlcpPrimeStartup()
        when bl808BleNimPureConnection:
          nimLlcpTrySendStartup(1'u16)
        else:
          when bl808BleNimLlcStartInitialLlcp:
            discard nimLlcpSendInitialNow(1'u16)
          elif bl808BleNimKeepaliveAcl:
            discard nimRequestEmptyAcl(1'u16)
      nimConnMark(0x131'u32)
    when bl808BleNimManualConnTx:
      if nim_conn_last_status == 0'u32 and
          bl808BleNimSyntheticPeripheral:
        nimSendLeConnComplete(1'u16)
    writeBtbleInterruptMask(BtbleIntConnection)
    nimConnMark(0x140'u32)
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()
    when not bl808BleSkipConnEmWake:
      regOr(BTBLE_EM_BASE + 0x1B4'u32, 0x00000001'u32)
    nimConnMark(0x1FF'u32)
    bleVolatileCounterInc(addr nim_conn_start_return_count)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] done\r\n")

  proc serviceQueuedNimConnectInd() =
    when bl808BleNimDeferConnectInd:
      if nim_connect_ind_pending == 0'u32:
        return
      when declared(nim_adv_sch_event_active):
        if nim_adv_sch_event_active != 0'u32:
          if nim_adv_enabled:
            return
          nim_adv_sch_event_active = 0
      nim_connect_ind_pending = 0
      inc nim_connect_ind_service_count
      startNimConnectionFromConnectInd(
        nim_connect_ind_pending_desc_idx,
        cast[ptr UncheckedArray[uint8]](
          addr nim_connect_ind_pending_payload[0]),
        nim_connect_ind_pending_header,
        nim_connect_ind_pending_rx_clock,
        nim_connect_ind_pending_rx_fine)
      bleVolatileCounterInc(addr nim_connect_ind_return_count)
    else:
      discard

  proc handleNimConnectInd(descIdx: uint8,
                           payload: ptr UncheckedArray[uint8],
                           header: uint16,
                           rxClock: uint32,
                           rxFine: uint16) =
    if payload == nil:
      return
    inc nim_ble_dbg_rx_connect_ind_count
    when bl808BleNimDeferConnectInd:
      if nim_conn_started or nim_connect_ind_pending != 0'u32:
        return
      nim_connect_ind_pending_desc_idx = descIdx and 0x07'u8
      nim_connect_ind_pending_header = header
      nim_connect_ind_pending_rx_clock = rxClock
      nim_connect_ind_pending_rx_fine = rxFine
      for j in 0 ..< nim_connect_ind_pending_payload.len:
        nim_connect_ind_pending_payload[j] = payload[j]
      nim_connect_ind_pending = 1
      inc nim_connect_ind_queued_count
      nim_adv_enabled = false
      requestBtbleSwInterrupt()
    else:
      startNimConnectionFromConnectInd(descIdx, payload, header,
                                       rxClock, rxFine)
      bleVolatileCounterInc(addr nim_connect_ind_return_count)

proc btbleDelayTicksToSlots(delayTicks: uint32): uint32 {.inline.} =
  let slots = (delayTicks + 624'u32) div 625'u32
  if slots < 8'u32: 8'u32 else: slots

proc btbleDelayTicksCeilSlots(delayTicks: uint32): uint32 {.inline.} =
  (delayTicks + 624'u32) div 625'u32

proc nimAdvIntervalHalfUs(): uint32 {.inline.} =
  let interval =
    uint32(nim_adv_params[0]) or (uint32(nim_adv_params[1]) shl 8)
  let bounded =
    if interval == 0'u32: 0x00A0'u32 else: interval
  bounded * 1250'u32

proc nextLegacyAdvDelayHalfUs(): uint32 =
  if ble_adv_random_delay_disabled:
    return 0
  var sample =
    currentBtbleTime() xor
    (nim_ble_dbg_isr_count * 0x9E3779B9'u32) xor 0xA5A5A5A5'u32
  sample = sample xor (sample shr 7)
  sample = sample xor (sample shl 9)
  var units = sample and 0x0F'u32
  if units > 8'u32:
    units = units - 8'u32
  units * (BleLegacyAdvDelayMaxHalfUs div 8'u32)

proc pushBtbleAdvProgram(leadSlots: uint32 = 8'u32) =
  serviceBleRfCalibrationLatch()
  inc nim_ble_dbg_push_count
  let nowClock = currentBtbleTime()
  let targetClock = (nowClock + leadSlots) and 0x0FFFFFFF'u32
  let clock = targetClock and 0x0000FFFF'u32

  when defined(bl808m0) and
      bl808BleNimSchProgEnabled:
    let slot = uint32(schProgWriteIdx and 0x0F'u8)
    let slotTail = btbleAdvSlotTail(slot)
    discard c_memset(addr nim_sch_prog[0], 0, nim_sch_prog.len.csize_t)

    btbleProgramSlotProgramRaw(slot, 0x281A'u16,
      uint16(clock and 0xFFFF'u32), 0'u16, 0x0270'u16, 0x0048'u16,
      0x085A'u16, uint16(slotTail and 0xFFFF'u32),
      uint16((slotTail shr 16) and 0xFFFF'u32))

    schProgWrite32(0x00, cast[uint32](cast[uint](nimSchProgCb)))
    schProgWrite32(0x04, targetClock)    # coarse target time
    schProgWrite16(0x08, 0'u16)          # fine target time
    schProgWrite32(0x10, 0x000010B3'u32) # duration -> 0x085a half slot
    schProgWrite32(0x14, 0'u32)          # callback context
    nim_sch_prog[0x18] = 0x28'u8     # adv rate/type field, shifted by vendor code
    nim_sch_prog[0x19] = 0x00'u8
    nim_sch_prog[0x1A] = 0x60'u8     # final low half at +0x0c: 0x0c00
    nim_sch_prog[0x1B] = uint8((slotTail shr 24) and 0xFF'u32)
    nim_sch_prog[0x1C] = 0x00'u8     # advertising event index -> EM ptr 0x48
    nim_sch_prog[0x1D] = 0x00'u8     # legacy advertising control-word path
    nim_sch_prog[0x1E] = 0x00'u8
    nim_sch_prog[0x1F] = 0x00'u8
    nim_sch_prog[0x20] = 0x00'u8
    nim_sch_prog[0x21] = 0x00'u8
    nim_adv_sch_event_active = 1
    inc nim_adv_sch_program_count
    sch_prog_push(addr nim_sch_prog[0])
    nim_adv_schedule_slot = uint8((slot + 1'u32) mod 16'u32)
    return

  let directSlot = uint32(nim_adv_schedule_slot) mod 10'u32
  let directSlotTail = btbleAdvSlotTail(directSlot)
  btbleProgramSlotProgramRaw(directSlot, 0x2802'u16,
    uint16(clock and 0xFFFF'u32), 0'u16, 0x0270'u16, 0x0048'u16,
    0x085A'u16, uint16(directSlotTail and 0xFFFF'u32),
    uint16((directSlotTail shr 16) and 0xFFFF'u32))

  regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or directSlot)
  nim_adv_schedule_slot = uint8((directSlot + 1'u32) mod 10'u32)

proc scheduleBtbleEvent(delayHalfUs: uint32 = 0'u32) =
  nim_adv_debug_stage = 0x7100'u32
  nim_adv_debug_detail = delayHalfUs
  serviceBleRfCalibrationLatch()
  nim_adv_debug_stage = 0x7110'u32
  let delay =
    if delayHalfUs == 0'u32:
      nimAdvIntervalHalfUs() + nextLegacyAdvDelayHalfUs()
    else: delayHalfUs
  nim_adv_debug_stage = 0x7120'u32
  nim_adv_debug_detail = delay
  let target = (currentBtbleHalfUs() + delay) and 0x0FFFFFFF'u32
  nim_adv_debug_stage = 0x7130'u32
  nim_adv_debug_detail = target
  let nowClock = currentBtbleTime()
  let leadSlots = btbleDelayTicksToSlots(delay)
  let clock = (nowClock + leadSlots) and 0x0000FFFF'u32
  nim_adv_debug_stage = 0x7140'u32
  nim_adv_debug_detail = clock
  nim_adv_target_half_us = target
  regWrite((BLE_BASE + 0x9C0'u32).uint, 0x00004000'u32)
  regWrite((BLE_BASE + 0x0E8'u32).uint,
           clock and 0x0FFFFFFF'u32)
  regWrite((BLE_BASE + 0x0EC'u32).uint, 0x00000270'u32)
  regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntEventTarget)
  enableBtbleInterruptMaskBits(BtbleIntEventTarget)
  nim_adv_debug_stage = 0x7150'u32
  nim_adv_debug_detail = regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
  serviceBleRfCalibrationLatch()
  nim_adv_debug_stage = 0x7160'u32

proc btbleTargetExpired(target: uint32): bool =
  if target == 0:
    return true
  let now = currentBtbleHalfUs()
  (((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32)

proc readBleAddrLow(addrBase: uint32): uint32 =
  read8(addrBase).uint32 or
    (read8(addrBase + 1'u32).uint32 shl 8) or
    (read8(addrBase + 2'u32).uint32 shl 16) or
    (read8(addrBase + 3'u32).uint32 shl 24)

proc readBleAddrHigh(addrBase: uint32): uint32 =
  read8(addrBase + 4'u32).uint32 or
    (read8(addrBase + 5'u32).uint32 shl 8)

template btbleScanReqPduAt(buf: uint16): ptr BtbleScanReqPduView =
  cast[ptr BtbleScanReqPduView](BTBLE_EM_BASE + buf.uint32)

proc bdAddrLow(bd: ptr BdAddr): uint32 {.inline.} =
  bd.data[0].uint32 or
    (bd.data[1].uint32 shl 8) or
    (bd.data[2].uint32 shl 16) or
    (bd.data[3].uint32 shl 24)

proc bdAddrHigh(bd: ptr BdAddr): uint32 {.inline.} =
  bd.data[4].uint32 or (bd.data[5].uint32 shl 8)

proc fallbackLocalAddrByte(idx: int): uint8 {.inline.} =
  case idx
  of 0: 0x01'u8
  of 1: 0x23'u8
  of 2: 0x45'u8
  of 3: 0x67'u8
  of 4: 0x89'u8
  else: 0xAB'u8

proc selectedLocalAddrByte(idx: int, ownAddrType: uint8): uint8 =
  if (ownAddrType and 0x01'u8) != 0'u8 and nim_local_addr_valid:
    return nim_local_addr[idx]
  if nim_public_addr_valid:
    return nim_public_addr[idx]
  fallbackLocalAddrByte(idx)

proc expectedAdvAddrByte(idx: int): uint8 =
  selectedLocalAddrByte(idx, nim_adv_params[5])

proc btbleAdvRxFine(desc: uint32): uint16 {.inline.} =
  ## Vendor lld_adv_frm_isr uses descriptor +0x0C low 10 bits as the raw RX
  ## fine timestamp before subtracting the advertising sync position.
  btbleRxDescMeta(desc) and 0x03FF'u16

proc btbleAdvRxClock(desc: uint32): uint32 {.inline.} =
  ## Reference lld_adv_frm_isr uses descriptor +0x08 as the coarse RX clock for
  ## the advertising-channel PDU.
  btbleRxDescClock(desc).uint32

proc btbleConnRxFine(desc: uint32): uint16 {.inline.} =
  ## Reference lld_con_frm_cbk uses descriptor +0x0C low 10 bits as the
  ## data-channel RX fine timestamp before subtracting the PHY sync position.
  btbleRxDescMeta(desc) and 0x03FF'u16

proc btbleConnRxClock(desc: uint32): uint32 {.inline.} =
  ## Reference lld_con_frm_cbk uses descriptor +0x08 as the data-channel coarse
  ## RX clock. The pure path expands this 16-bit hardware value near the
  ## scheduled anchor.
  btbleRxDescClock(desc).uint32

proc btbleRecordConnectDescTiming(desc: uint32) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let rxDesc = btbleRxDescAt(desc)
    nim_connect_desc_fields[0] = volatileLoad(addr rxDesc.timing0).uint32
    nim_connect_desc_fields[1] = btbleRxDescClock(desc).uint32
    nim_connect_desc_fields[2] = volatileLoad(addr rxDesc.timing1).uint32
    nim_connect_desc_fields[3] = btbleRxDescMeta(desc).uint32

when defined(bl808m0) and bl808BleNimPureCentral:
  proc handleNimInitiatorAdvRx(header: uint16, buf: uint16, desc: uint32,
                               status: uint16, idx: uint32): bool

proc serviceBtbleAdvRxDescriptors() =
  ## The BL808 BTBLE advertising engine writes received advertising-channel
  ## PDUs into the RX descriptor ring at EM 0x458.  Vendor lld_adv_frm_isr()
  ## consumes these on scheduler FIFO completion; the Nim scheduler bypasses
  ## that callback path, so service the ring directly until the full LLD event
  ## callback model is ported.
  var startIdx = 0'u32
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    startIdx = uint32(lld_env[14] and 0x07'u8)
  for step in 0'u32 ..< 8'u32:
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started:
        nimConnMark(0x160'u32 or step)
    let i = (startIdx + step) and 0x07'u32
    let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)
    let status = btbleRxDescStatus(desc)
    if (status and BtbleRxDescDone) == 0:
      continue

    let header = btbleRxDescHeader(desc)
    let buf = btbleRxDescDataOffset(desc)
    let meta = btbleRxDescMeta(desc)
    let pduType = uint8(header and 0x000F'u16)
    let pduLen = uint8((header shr 8) and 0x003F'u16)

    inc nim_ble_dbg_rx_ready_count
    nim_ble_dbg_rx_last_header = header.uint32
    nim_ble_dbg_rx_last_status = status.uint32
    nim_ble_dbg_rx_last_desc = desc
    nim_ble_dbg_rx_last_buf = buf.uint32

    if pduType == 0x03'u8 and pduLen == 12'u8:
      inc nim_ble_dbg_rx_scan_req_count
      let scanReq = btbleScanReqPduAt(buf)
      nim_ble_dbg_rx_scan_req_last_scana0 = bdAddrLow(addr scanReq.scanA)
      nim_ble_dbg_rx_scan_req_last_scana1 = bdAddrHigh(addr scanReq.scanA)
      nim_ble_dbg_rx_scan_req_last_adva0 = bdAddrLow(addr scanReq.advA)
      nim_ble_dbg_rx_scan_req_last_adva1 = bdAddrHigh(addr scanReq.advA)
      var advaMatches = true
      for j in 0 ..< 6:
        if scanReq.advA.data[j] != expectedAdvAddrByte(j):
          advaMatches = false
      if advaMatches:
        inc nim_ble_dbg_rx_scan_req_match_count
    elif pduType == 0x05'u8 and pduLen == 34'u8:
      when defined(bl808BleConnectTrace):
        bleTrace("\r\n[CON] rx connect\r\n")
      when defined(bl808m0) and bl808BleNimConnectionEnabled:
        # Match vendor lld_adv_frm_isr timing extraction.
        btbleRecordConnectDescTiming(desc)
        let rxFine = btbleAdvRxFine(desc)
        let rxClock = btbleAdvRxClock(desc)
        var connectPdu: array[34, uint8]
        let payload = btbleEmPayload(buf)
        for j in 0 ..< connectPdu.len:
          connectPdu[j] = payload[j]
        btbleRxDescClearDone(desc, status)
        noteNimRxDescConsumed(i)
        let advRxSp = bleCentralTraceReadSp()
        let advRxRa = regRead((advRxSp + 124'u32).uint)
        let isrRa = regRead((advRxSp + 156'u32).uint)
        handleNimConnectInd(uint8(i and 0x07'u32),
                               cast[ptr UncheckedArray[uint8]](
                                 addr connectPdu[0]),
                               header, rxClock, rxFine)
        if advRxRa != 0'u32:
          regWrite((advRxSp + 124'u32).uint, advRxRa)
        if isrRa != 0'u32:
          regWrite((advRxSp + 156'u32).uint, isrRa)
        nimConnMark(0x150'u32)
        when defined(bl808BleConnectTrace):
          bleTrace("[CON] post start return\r\n")
        nimConnMark(0x151'u32)
        return

    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started:
        nimConnMark(0x170'u32 or step)

    when defined(bl808m0) and bl808BleNimPureCentral:
      if handleNimInitiatorAdvRx(header, buf, desc, status, i):
        return

    when defined(bl808m0):
      if nim_scan_enabled and pduLen >= 6'u8 and
          (pduType == 0x00'u8 or pduType == 0x02'u8 or
           pduType == 0x04'u8 or pduType == 0x06'u8):
        sendLeAdvertisingReportFromRxDesc(header, buf)
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started and pduType != 0x03'u8 and pduType != 0x05'u8:
        continue

    btbleRxDescClearDone(desc, status)
    when defined(bl808m0) and
        (bl808BleNimConnectionEnabled or
         bl808BleNimPureCentral):
      if (lld_env[14] and 0x07'u8) == uint8(i and 0x07'u32):
        lld_env[14] = uint8((i + 1'u32) and 0x07'u32)

proc resetBtbleLinkLayerCore() =
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) and not 0x00000100'u32)
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x800'u32).uint)
  regWrite((BLE_BASE + 0x80C'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x814'u32).uint, 0xFFFFFFFF'u32)
  for off in [0x404'u32, 0x410'u32, 0x41C'u32, 0x428'u32,
              0x434'u32, 0x440'u32, 0x44C'u32]:
    write16(BTBLE_EM_BASE + off, 0'u16)
  regWrite((BLE_BASE + 0x8D0'u32).uint,
           regRead((BLE_BASE + 0x8D0'u32).uint) and not 0x00001000'u32)
  regWrite((BLE_BASE + 0x850'u32).uint, 0'u32)

proc initBtbleLinkLayerRegisters() =
  ## Port of the BL808 BTBLE lld_init hardware register setup.  The older
  ## BL602-style EM map at 0x28008000 is not used by BL808 advertising.
  resetBtbleLinkLayerCore()
  when defined(bl808m0) and
      bl808BleNimSchProgEnabled:
    sch_slice_params[0] = 0xFFFF'u16
    sch_slice_params[1] = 0xFFFF'u16
    sch_slice_params[2] = 0x57E4'u16
    sch_slice_params[3] = 0'u16
    when bl808BleNimConnectionEnabled or bl808BleNimPureCentral:
      rwip_param.get = rwipParamDummyGet
      rwip_param.set = rwipParamDummySet
      rwip_param.del = rwipParamDummyDel
    nimSchProgInit(3'u8)
  for off in countup(0'u32, 0x00F0'u32, 0x10):
    write16(BTBLE_EM_BASE + off, 0x281A'u16)

  regWrite((BLE_BASE + 0x800'u32).uint, 0x00100607'u32)
  regOr(BLE_BASE + 0x800'u32, 0x00400000'u32)
  regWrite((BLE_BASE + 0x80C'u32).uint, 0x0001001E'u32)
  regWrite((BLE_BASE + 0x930'u32).uint, 0xFF9602EE'u32)
  regWrite((BLE_BASE + 0x940'u32).uint, 0x00070101'u32)
  regWrite((BLE_BASE + 0x944'u32).uint, 0x00000101'u32)
  regWrite((BLE_BASE + 0x970'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x974'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x948'u32).uint, 0x00000010'u32)

  resetBtbleAdvRxRing()

  regWrite((BLE_BASE + 0x828'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x82C'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x860'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x880'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x884'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x888'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x88C'u32).uint, 0x00000350'u32)
  regWrite((BLE_BASE + 0x890'u32).uint, 0x04280703'u32)
  regWrite((BLE_BASE + 0x894'u32).uint, 0x001E0502'u32)
  regWrite((BLE_BASE + 0x898'u32).uint, 0x08870703'u32)
  regWrite((BLE_BASE + 0x89C'u32).uint, 0x08280003'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    refreshNimSyncPositions()
  regWrite((BLE_BASE + 0x950'u32).uint, 0x000500F3'u32)
  regWrite((BLE_BASE + 0x980'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x984'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x988'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x98C'u32).uint, 0x02120013'u32)

  var seq = 0'u16
  for off in [0x122'u32, 0x1B6'u32, 0x24A'u32, 0x2DE'u32, 0x372'u32]:
    let v = (read16(BTBLE_EM_BASE + off) and 0xE0FF'u16) or seq
    write16(BTBLE_EM_BASE + off, v)
    seq = seq + 0x0100'u16

  let seed0 = (currentBtbleTime() xor 0x00243B9F'u32) and 0x003FFFFF'u32
  let seed1 = ((currentBtbleTime() shl 7) xor 0x00238DC9'u32) and 0x003FFFFF'u32
  regWrite((BLE_BASE + 0x978'u32).uint, 0x80000000'u32 or seed0)
  regWrite((BLE_BASE + 0x97C'u32).uint, 0x80000000'u32 or seed1)
  regWrite((BLE_BASE + 0x9E0'u32).uint,
           (regRead((BLE_BASE + 0x9E0'u32).uint) and not 0xFF'u32) or 1'u32)
  regOr(BLE_BASE + 0x800'u32, 0x00000100'u32)
  regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)

proc initBleCoreRegisters() =
  blePlatformInitMark(0x100'u32)
  prepareWirelessDomain()
  blePlatformInitMark(0x101'u32)
  configureBtPriorityPta()
  blePlatformInitMark(0x102'u32)
  configureBleRf1M()
  blePlatformInitMark(0x103'u32)

  regUpdate(BLE_BASE + 0x000'u32, 0x000000F0'u32, 0x000000E0'u32)
  regUpdate(BLE_BASE + 0x0F0'u32, 0x000001FF'u32, 0x000000D2'u32)
  regUpdate(BLE_BASE + 0x0F0'u32, 0x03FF0000'u32, 0x01B80000'u32)
  regWrite((BLE_BASE + 0x00C'u32).uint, 0x0000033A'u32)
  regWrite((BLE_BASE + 0x000'u32).uint,
           regRead((BLE_BASE + 0x000'u32).uint) and not 0x00300000'u32)

  regOr(BLE_BASE + 0x000'u32, 0x00000200'u32)
  regWrite((BLE_BASE + 0x090'u32).uint, 0x00000007'u32)
  regWrite((BLE_BASE + 0x0B0'u32).uint, 0x000001A2'u32)
  regWrite((BLE_BASE + 0x0B4'u32).uint, 0x000001B4'u32)
  regWrite((BLE_BASE + 0x0B8'u32).uint, 0x00000303'u32)
  regWrite((BLE_BASE + 0x120'u32).uint, 0x000001C6'u32)
  regWrite((BLE_BASE + 0x124'u32).uint, 0x00000003'u32)
  regWrite((BLE_BASE + 0x02C'u32).uint, 0x0000035C'u32)

  for off in [
    0x02C'u32, 0x090'u32, 0x0A0'u32, 0x0A8'u32, 0x0AC'u32,
    0x0B0'u32, 0x0B4'u32, 0x0B8'u32, 0x0BC'u32, 0x0F0'u32,
    0x120'u32, 0x124'u32
  ]:
    regWrite((BLE_BASE + off).uint, 0'u32)

  writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x0F0'u32)
  write16(BLE_EM_BASE + 0x106'u32, 0'u16)
  write16(BLE_EM_BASE + 0x108'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10A'u32, 0'u16)
  writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x14C'u32)
  write16(BLE_EM_BASE + 0x162'u32, 0'u16)
  write16(BLE_EM_BASE + 0x164'u32, 0'u16)
  write16(BLE_EM_BASE + 0x166'u32, 0'u16)
  write16(BLE_EM_BASE + 0x0FC'u32, ble_tx_pwr.uint16)
  write16(BLE_EM_BASE + 0x158'u32, ble_tx_pwr.uint16)

  for off in countup(0'u32, 0x3C'u32, 4):
    write16(BLE_EM_BASE + off, 0'u16)
    write16(BLE_EM_BASE + off + 2'u32, 0'u16)

  var v = read16(BLE_EM_BASE + 0x0EA'u32)
  v = v and not 0x0700'u16
  write16(BLE_EM_BASE + 0x0EA'u32, v)
  v = read16(BLE_EM_BASE + 0x146'u32)
  v = v and not 0x0700'u16
  write16(BLE_EM_BASE + 0x146'u32, v)

  regWrite((BLE_BASE + 0x1A0'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x0E0'u32).uint,
           regRead((BLE_BASE + 0x0E0'u32).uint) and not 0x00001000'u32)
  regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
  lld_sleep_init()
  blePlatformInitMark(0x110'u32)
  initBtbleTimeRegisters()
  initBtbleLinkLayerRegisters()

  nim_ble_core_ready = true
  bleVolatileCounterInc(addr nim_ble_core_init_return_count)

proc resetNimControllerState() =
  let irqState = btbleIrqSave()
  quiesceM0PolledBleClicSources()
  defer:
    quiesceM0PolledBleClicSources()
    btbleIrqRestore(irqState)
  nim_adv_enabled = false
  nim_scan_enabled = false
  nim_conn_active = false
  nim_conn_handle = 0
  nim_local_addr_valid = false
  nim_adv_data_len = 0
  nim_scan_rsp_data_len = 0
  nim_hci_debug_stage = 0
  nim_hci_debug_opcode = 0
  nim_hci_debug_status = 0
  nim_hci_debug_len = 0
  nim_hci_debug_cb = cast[uint32](cast[uint](onchiphci_recv_cb))
  nim_suggested_tx_octets = NimBleLeMaxDataOctets
  nim_suggested_tx_time = NimBleLeMaxDataTime
  nim_adv_schedule_slot = 0
  nim_adv_target_half_us = 0
  nim_adv_event_props = 0
  when declared(nim_adv_sch_program_count):
    nim_adv_sch_program_count = 0
    nim_adv_sch_event_count = 0
    nim_adv_sch_end_count = 0
    nim_adv_sch_last_event = 0
    nim_adv_sch_event_active = 0
  when defined(bl808m0):
    nim_pending_scan_report_head = 0
    nim_pending_scan_report_tail = 0
    nim_pending_scan_report_count = 0
    nim_pending_scan_report_dropped = 0
  when defined(bl808m0) and bl808BleNimPureCentral:
    nim_scan_program_count = 0
    nim_scan_event_count = 0
    nim_scan_last_event = 0
    nim_scan_last_status = 0
    nim_scan_next_program_at = 0
    nim_scan_channel_cursor = 0
    nim_scan_last_channel_index = 0
    nim_scan_last_adv_channel = 0
    nim_scan_req_peer_addr_type = 0
    nim_scan_peer_hint_write_index = 0
    for i in 0 ..< NimScanPeerHintSlots:
      nim_scan_peer_hint_addr0[i] = 0
      nim_scan_peer_hint_addr1[i] = 0
      nim_scan_peer_hint_type[i] = 0
      nim_scan_peer_hint_channel_index[i] = 0
      nim_scan_peer_hint_adv_channel[i] = 0
    nim_init_active = 0
    nim_init_program_count = 0
    nim_init_event_count = 0
    nim_init_match_count = 0
    nim_init_start_count = 0
    nim_init_complete_count = 0
    nim_init_hci_complete_count = 0
    nim_init_cancel_count = 0
    nim_init_tx_event_count = 0
    nim_init_last_status = 0
    nim_init_last_event = 0
    nim_init_last_rx_clock = 0
    nim_init_last_rx_fine = 0
    nim_init_last_anchor = 0
    nim_init_last_access_addr = 0
    nim_init_rx_count = 0
    nim_init_rx_match_reason = 0
    nim_init_rx_last_header = 0
    nim_init_rx_last_status = 0
    nim_init_rx_last_buf = 0
    nim_init_rx_last_peer0 = 0
    nim_init_rx_last_peer1 = 0
    nim_init_rx_pdu_mismatch_count = 0
    nim_init_rx_short_count = 0
    nim_init_rx_addr_mismatch_count = 0
    nim_init_rx_addr_match_count = 0
    nim_init_rx_type_mismatch_count = 0
    nim_init_total_rx_count = 0
    nim_init_total_match_count = 0
    nim_init_total_pdu_mismatch_count = 0
    nim_init_total_short_count = 0
    nim_init_total_addr_mismatch_count = 0
    nim_init_total_addr_match_count = 0
    nim_init_total_type_mismatch_count = 0
    nim_init_total_handoff_start_count = 0
    nim_init_total_handoff_timeout_count = 0
    nim_init_total_start_count = 0
    nim_init_total_tx_event_count = 0
    nim_init_total_hci_complete_count = 0
    nim_init_connect_ind_header_flags = 0
    nim_init_rx_log_index = 0
    for i in 0 ..< nim_init_rx_header_log.len:
      nim_init_rx_header_log[i] = 0
      nim_init_rx_status_log[i] = 0
      nim_init_rx_peer0_log[i] = 0
      nim_init_rx_peer1_log[i] = 0
      nim_init_rx_reason_log[i] = 0
    nim_init_next_program_at = 0
    nim_init_event_target_clock = 0
    nim_init_rx_event_clock = 0
    nim_init_last_rx_now = 0
    nim_init_last_rx_event_clock = 0
    nim_init_last_rx_clock_source = 0
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    nim_init_event_done_program_count = 0
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_handoff_start_count = 0
    nim_init_handoff_timeout_count = 0
    nim_init_pending_header = 0
    nim_init_pending_rx_clock = 0
    nim_init_pending_rx_fine = 0
    nim_init_pending_desc = 0
    nim_init_pending_desc_status = 0
    nim_init_pending_desc_idx = 0
    nim_init_channel_cursor = 0
    nim_init_channel_seed = 0
    nim_init_channel_window_valid = 0
    nim_init_channel_window_deadline = 0
    nim_init_last_channel_index = 0
    nim_init_last_adv_channel = 0
    nim_init_channel_hint_hit_count = 0
    nim_init_channel_hint_miss_count = 0
    nim_init_channel_hint_index = 0
    nim_init_channel_hint_adv_channel = 0
    nim_init_complete_pending = 0
    nim_scan_debug_stage = 0
    nim_scan_debug_now = 0
    nim_scan_debug_target = 0
    nim_scan_debug_lead = 0
    when defined(BleDebugCounters):
      nim_init_program_snapshot_count = 0
      nim_init_program_snapshot_channel = 0
      for i in 0 ..< nim_init_program_snapshot_timing.len:
        nim_init_program_snapshot_timing[i] = 0
      for i in 0 ..< nim_init_program_snapshot_em.len:
        nim_init_program_snapshot_em[i] = 0
      for i in 0 ..< nim_init_program_snapshot_tx_desc.len:
        nim_init_program_snapshot_tx_desc[i] = 0
      for i in 0 ..< nim_init_program_snapshot_sched.len:
        nim_init_program_snapshot_sched[i] = 0
      nim_init_sch_event_log_index = 0
      for i in 0 ..< nim_init_sch_event_code_log.len:
        nim_init_sch_event_code_log[i] = 0
        nim_init_sch_event_time_log[i] = 0
        nim_init_sch_event_now_log[i] = 0
        nim_init_sch_event_state_log[i] = 0
        nim_init_sch_event_counts_log[i] = 0
        nim_init_sch_event_done_log[i] = 0
        nim_init_sch_event_int_log[i] = 0
      nim_init_handoff_snapshot_count = 0
      nim_init_handoff_snapshot_reason = 0
      for i in 0 ..< nim_init_handoff_snapshot_timing.len:
        nim_init_handoff_snapshot_timing[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_em.len:
        nim_init_handoff_snapshot_em[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_desc.len:
        nim_init_handoff_snapshot_desc[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_data.len:
        nim_init_handoff_snapshot_data[i] = 0
    discard c_memset(addr nim_init_hci_params[0], 0,
                     nim_init_hci_params.len.csize_t)
    discard c_memset(addr nim_init_ll_data[0], 0,
                     nim_init_ll_data.len.csize_t)
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_sched_log_index = 0
    for i in 0 ..< nim_conn_sched_now_log.len:
      nim_conn_sched_now_log[i] = 0
      nim_conn_sched_target_log[i] = 0
      nim_conn_sched_delta_log[i] = 0
      nim_conn_sched_duration_log[i] = 0
      nim_conn_sched_event_log[i] = 0
      nim_conn_sched_channel_log[i] = 0
      nim_conn_sched_timing_log[i] = 0
    nim_conn_last_schedule_now = 0
    nim_conn_last_schedule_target = 0
    nim_conn_last_schedule_fine = 0
    nim_conn_last_schedule_delta = 0
    nim_conn_last_schedule_duration = 0
    nim_conn_last_rx_timing = 0
    nim_conn_last_channel_word = 0
    nim_conn_last_channel = 0
    nim_conn_last_unmapped_channel = 0
    nim_conn_last_event_counter = 0
    nim_conn_last_schedule_anchor = 0
    nim_conn_last_schedule_anchor_fine = 0
    for i in 0 ..< nim_conn_first_schedule_snapshot.len:
      nim_conn_first_schedule_snapshot[i] = 0
    nim_conn_missed_event_fallback_count = 0
    nim_conn_rx_acquire_events = 0
    nim_conn_rx_acquire_reset_count = 0
    nim_ble_wifi_tx_window_active = 0
    nim_ble_wifi_tx_window_enter_count = 0
    nim_ble_wifi_tx_window_leave_count = 0
    nim_ble_wifi_tx_window_skip_count = 0
    nim_ble_wifi_tx_window_defer_count = 0
    nim_ble_wifi_tx_window_resume_count = 0
    nim_ble_wifi_tx_window_last_intmask = 0
    nim_ble_wifi_tx_window_last_intstat = 0
    when defined(BleDebugCounters):
      nim_conn_tx_header_log_index = 0
      nim_conn_rx_seq_log_index = 0
      nim_conn_sch_event_log_index = 0
      for i in 0 ..< nim_conn_tx_header_log.len:
        nim_conn_tx_header_log[i] = 0
        nim_conn_tx_state_log[i] = 0
        nim_conn_rx_seq_log[i] = 0
        nim_conn_rx_state_log[i] = 0
        nim_conn_sch_event_code_log[i] = 0
        nim_conn_sch_event_time_log[i] = 0
        nim_conn_sch_event_now_log[i] = 0
        nim_conn_sch_event_state_log[i] = 0
        nim_conn_sch_event_counts_log[i] = 0
        nim_conn_sch_event_int_log[i] = 0
  when defined(bl808m0):
    nim_scan_unsupported_count = 0
    nim_scan_unsupported_header = 0
    nim_scan_unsupported_len = 0
    nim_scan_unsupported_buf = 0
    discard c_memset(addr nim_scan_unsupported_data[0], 0,
                     nim_scan_unsupported_data.len.csize_t)
    when not defined(bl808BleNimLlcStart):
      nim_lld_rx_desc_active = 0
      nim_lld_rx_desc_idx = 0
      nim_lld_rx_check_count = 0
      nim_lld_rx_check_hit_count = 0
      nim_lld_rx_check_miss_count = 0
      nim_lld_rx_free_count = 0
      nim_lld_rx_last_idx = 0
      nim_lld_rx_last_env_idx = 0
      nim_lld_rx_last_status = 0
      nim_lld_rx_last_header = 0
      nim_lld_rx_last_meta = 0
    nim_sch_prog_fifo_count = 0
    nim_sch_prog_skip_count = 0
    nim_arb_sw_count = 0
    nim_arb_event_start_count = 0
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_fifo_count = 0
    nim_sch_prog_skip_count = 0
    nim_arb_sw_count = 0
    nim_arb_event_start_count = 0
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_started = false
    nim_connect_ind_pending = 0
    nim_connect_ind_queued_count = 0
    nim_connect_ind_service_count = 0
    nim_connect_ind_return_count = 0
    nim_connect_ind_pending_desc_idx = 0
    nim_connect_ind_pending_header = 0
    nim_connect_ind_pending_rx_clock = 0
    nim_connect_ind_pending_rx_fine = 0
    discard c_memset(addr nim_connect_ind_pending_payload[0], 0,
                     nim_connect_ind_pending_payload.len.csize_t)
    discard c_memset(addr nim_connect_ind_work_payload[0], 0,
                     nim_connect_ind_work_payload.len.csize_t)
    nim_llc_status = 0
    nim_conn_last_status = 0
    nim_conn_last_rx_clock = 0
    nim_conn_last_rx_fine = 0
    nim_conn_last_anchor = 0
    nim_conn_last_win_offset = 0
    nim_conn_last_interval = 0
    nim_conn_last_timeout = 0
    nim_conn_last_access_addr = 0
    nim_conn_last_crcinit = 0
    for i in 0 ..< nim_connect_desc_fields.len:
      nim_connect_desc_fields[i] = 0
    for i in 0 ..< nim_connect_timing_snapshot.len:
      nim_connect_timing_snapshot[i] = 0
    nim_conn_start_return_count = 0
    nim_lld_con_start_count = 0
    nim_lld_con_start_status = 0
    discard c_memset(addr nim_lld_con_start_param[0], 0,
                     nim_lld_con_start_param.len.csize_t)
    discard c_memset(addr nim_conn_start_em_snapshot[0], 0,
                     nim_conn_start_em_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_rx_snapshot[0], 0,
                     nim_conn_start_rx_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_tx_snapshot[0], 0,
                     nim_conn_start_tx_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_reg_snapshot[0], 0,
                     nim_conn_start_reg_snapshot.len.csize_t * sizeof(uint32).csize_t)
    nim_conn_evt_count = 0
    nim_conn_evt_handle = 0
    nim_conn_evt_peer_a0 = 0
    nim_conn_evt_peer_a1 = 0
    nim_conn_evt_peer_type = 0
    nim_conn_evt_reported = false
    nim_disc_evt_count = 0
    nim_disc_evt_reason = 0
    nim_disc_evt_source = 0
    when bl808BleNimPureConnection:
      discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
      discard c_memset(addr nim_conn_sch_prog[0], 0,
                       nim_conn_sch_prog.len.csize_t)
    discard c_memset(addr nim_llc_msg[0], 0,
                     nim_llc_msg.len.csize_t)
    discard c_memset(addr nim_llc_env_storage[0], 0,
                     nim_llc_env_storage.len.csize_t)
    when not defined(bl808BleNimLlcStart):
      nim_lld_rx_desc_active = 0
      nim_lld_rx_desc_idx = 0
      nim_lld_rx_check_count = 0
      nim_lld_rx_check_hit_count = 0
      nim_lld_rx_check_miss_count = 0
      nim_lld_rx_free_count = 0
      nim_lld_rx_last_idx = 0
      nim_lld_rx_last_env_idx = 0
      nim_lld_rx_last_status = 0
      nim_lld_rx_last_header = 0
      nim_lld_rx_last_meta = 0
    nim_llcp_rx_count = 0
    nim_llcp_tx_count = 0
    nim_llcp_tx_pending = 0
    nim_llcp_tx_queued = 0
    nim_llcp_tx_dropped = 0
    nim_llcp_startup_tx_count = 0
    nim_llcp_startup_deferred_count = 0
    nim_llcp_state.versionProcedureStarted = false
    nimLlcpClearFeatureExchangeState(clearDebug = true)
    nim_llcp_state.startupAttemptsLeft = 0
    nim_llcp_state.startupDelayServices = 0
    nimLlcpResetDataLengthState()
    nim_llcp_tx_queue_head = 0
    nim_llcp_tx_queue_tail = 0
    nim_llcp_last_opcode = 0
    nim_llcp_last_status = 0
    nim_llcp_rx_log_index = 0
    nim_llcp_tx_log_index = 0
    nim_llcp_rx_malformed_count = 0
    nim_llcp_rx_malformed_last = 0
    nim_llcp_alloc_count = 0
    nim_llcp_free_count = 0
    nim_llcp_alloc_last_len = 0
    nim_llcp_alloc_last_ptr = 0
    nim_llcp_alloc_last_emoff = 0
    nim_llcp_alloc_last_len_field = 0
    nim_llcp_free_last_raw = 0
    nim_llcp_free_manual_count = 0
    nim_llcp_free_heap_count = 0
    discard c_memset(addr nim_llcp_rx_log[0], 0,
                     (sizeof(uint32) * nim_llcp_rx_log.len).csize_t)
    discard c_memset(addr nim_llcp_tx_log[0], 0,
                     (sizeof(uint32) * nim_llcp_tx_log.len).csize_t)
    nim_acl_empty_tx_count = 0
    nim_acl_empty_tx_pending = 0
    nim_acl_empty_tx_queued = 0
    nim_acl_empty_last_status = 0
    nim_acl_host_tx_count = 0
    nim_acl_host_tx_pending = 0
    nim_acl_host_tx_complete_count = 0
    nim_acl_host_tx_reject_count = 0
    nim_acl_rx_count = 0
    nim_acl_rx_drop_count = 0
    discard c_memset(addr nim_acl_host_tx_buf[0], 0,
                     nim_acl_host_tx_buf.len.csize_t)
    initNimRwipRfTable()
  discard c_memset(addr nim_adv_params[0], 0, nim_adv_params.len.csize_t)
  discard c_memset(addr nim_scan_params[0], 0, nim_scan_params.len.csize_t)
  discard c_memset(addr nim_adv_data[0], 0, nim_adv_data.len.csize_t)
  discard c_memset(addr nim_scan_rsp_data[0], 0, nim_scan_rsp_data.len.csize_t)
  if nim_ble_core_ready:
    when defined(bl808m0):
      nimDisableM0RfClicIrq()
      writeBtbleInterruptMask(0)
      resetBtbleAdvRxRing()
      initBtbleTimeRegisters()
      initBtbleLinkLayerRegisters()
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, 0xFFFFFFFF'u32)
      writeBtbleInterruptMask(0)
      quiesceM0PolledBleClicSources()
    else:
      initBleCoreRegisters()
  else:
    initBleCoreRegisters()

proc localAddrBytes(dst: ptr uint8, ownAddrType: uint8 = 0'u8) =
  if dst == nil:
    return
  let raw = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< 6:
    raw[i] = selectedLocalAddrByte(i, ownAddrType)

proc defaultLocalAddrBytes(dst: ptr uint8) =
  localAddrBytes(dst)

proc programBtbleLegacyAdv(advDataLen: uint8) =
  let advLen = min(advDataLen.int, 31)
  let scanRspLen = min(nim_scan_rsp_data_len.int, 31)
  let pduLen = uint16(6 + advLen)
  let scanRspPduLen = uint16(6 + scanRspLen)
  var addrBytes: array[6, uint8]
  localAddrBytes(addr addrBytes[0], nim_adv_params[5])
  let txAdd = uint16(nim_adv_params[5] and 0x01'u8) shl 6
  let eventAddrType = uint16(nim_adv_params[5] and 0x01'u8)
  let advEventHeader = BtbleLegacyAdvEventHeaderBase or eventAddrType
  let advHeaderFlags = NimBleLegacyAdvChSelBit or txAdd
  let scanRspHeaderFlags = 0x0004'u16 or txAdd
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_adv_event_props = NimConnLegacyAdvEventProps[0]

  copyBytes(BTBLE_EM_BASE + BtbleAdvDataOffset, addr nim_adv_data[0], advLen)
  copyBytes(BTBLE_EM_BASE + BtbleScanRspDataOffset,
            addr nim_scan_rsp_data[0], scanRspLen)
  copyBytes(BTBLE_EM_BASE + 0x128'u32, addr addrBytes[0], addrBytes.len)

  write16(BTBLE_EM_BASE + 0x120'u32, 0x0404'u16)
  write16(BTBLE_EM_BASE + 0x122'u32, advEventHeader)
  write16(BTBLE_EM_BASE + 0x124'u32, BtbleLegacyAdvEventWord124)
  write16(BTBLE_EM_BASE + 0x126'u32, 0'u16)
  writeBtbleDefaultAccessWords(BTBLE_EM_BASE + 0x12E'u32)
  write16(BTBLE_EM_BASE + 0x136'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x138'u32, BtbleLegacyAdvWord138)
  write16(BTBLE_EM_BASE + 0x13A'u32, 0x0020'u16)
  write16(BTBLE_EM_BASE + 0x13C'u32, BtbleLegacyAdvWord13C)
  write16(BTBLE_EM_BASE + 0x13E'u32, 0'u16)
  regWrite((BTBLE_EM_BASE + 0x140'u32).uint, BtbleLegacyAdvControl)
  write16(BTBLE_EM_BASE + 0x144'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x146'u32, BtbleLegacyAdvTimingHigh)
  write16(BTBLE_EM_BASE + 0x148'u32, BtbleLegacyAdvTimingLow)
  write16(BTBLE_EM_BASE + 0x14A'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x14C'u32, BtbleLegacyAdvTail)
  write16(BTBLE_EM_BASE + 0x14E'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
  write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x154'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x156'u32, 0x00E0'u16)
  write16(BTBLE_EM_BASE + 0x158'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15A'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15C'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15E'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x160'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x162'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x164'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x180'u32, 0'u16)

  write16(BTBLE_EM_BASE + 0x558'u32, 0x015A'u16)
  write16(BTBLE_EM_BASE + 0x55A'u32,
          ((pduLen and 0x00FF'u16) shl 8) or advHeaderFlags)
  write16(BTBLE_EM_BASE + 0x55C'u32, BtbleAdvDataOffset.uint16)
  write16(BTBLE_EM_BASE + 0x55E'u32, BtbleLegacyAdvTxDescFlags)
  write16(BTBLE_EM_BASE + 0x560'u32, BtbleLegacyAdvTxTailLow)
  write16(BTBLE_EM_BASE + 0x562'u32, BtbleLegacyAdvTxTailHigh)
  write16(BTBLE_EM_BASE + 0x564'u32, BtbleLegacyAdvRxTailLow)
  write16(BTBLE_EM_BASE + 0x566'u32, BtbleLegacyAdvRxTailHigh)
  write16(BTBLE_EM_BASE + 0x568'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x56A'u32,
          ((scanRspPduLen and 0x00FF'u16) shl 8) or scanRspHeaderFlags)
  if scanRspLen == 0:
    write16(BTBLE_EM_BASE + 0x56C'u32, BtbleLegacyScanRspEmptyPtr)
    write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspEmptyTail)
  else:
    write16(BTBLE_EM_BASE + 0x56C'u32, BtbleScanRspDataOffset.uint16)
    write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspDataTail)
  regWrite((BTBLE_EM_BASE + 0x570'u32).uint, 0xB8B5344B'u32)
  regWrite((BTBLE_EM_BASE + 0x574'u32).uint, 0x3E8F9FB7'u32)

  when defined(bl808m0):
    write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
    write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)

when defined(bl808m0) and bl808BleNimPureCentral:
  when not bl808BleNimSchProg:
    {.error: "bl808BleNimPureCentral requires bl808BleNimSchProg".}

  const
    NimScanEventIndex = 0'u8
    NimScanEventEmOffset = 0x0120'u32
    NimScanMinLeadSlots = 8'u32
    NimScanHalfSlotsPerScanUnit = 2'u32
    # Vendor lld_scan_start programs the scan activity word as 0x0008 for
    # passive scan and 0x0009 for active scan.  The 0x020x form belongs to the
    # legacy initiator path and prevents the scan role from producing reports.
    NimScanPassiveActivityWord = 0x0008'u16
    NimScanActiveActivityWord = 0x0009'u16
    # SDK lld_scan_start programs the active SCAN_REQ TX descriptor at
    # 0x28010e70 and stores the descriptor pointer as offset >> 2.
    NimScanReqTxDescPtr = 0x039C'u16
    NimScanReqTxDescOffset = uint32(NimScanReqTxDescPtr) shl 2
    NimScanReqPduType = 0x0003'u16
    NimScanReqPduLen = 12'u16
    NimInitHalfSlotsPerConnIntervalUnit = 4'u32
    # The pure central path stops scanning before it initiates, so it can reuse
    # the legacy scan activity.  This is the receive-side EM layout the BL808
    # advertising/initiator engine accepts with the pure scheduler.
    NimInitEventIndex = NimScanEventIndex
    NimInitEventEmOffset = 0x0120'u32 + uint32(NimInitEventIndex) * 0x94'u32
    NimInitConnectIndPayloadLen = 34
    NimInitConnReqLlDataLen = 22
    NimInitConnectIndPduType = 0x0005'u16
    NimInitTxDescPtr = 0x0304'u16
    NimInitTxDescOffset = uint32(NimInitTxDescPtr) shl 2
    NimInitConnReqDataOffset0 = 0x1794'u16
    NimInitConnReqDataOffset1 = 0x17B6'u16
    NimInitConnReqDataOffset2 = 0x17D8'u16
    NimInitMinLeadSlots = 32'u32
    NimInitTransmitWindowSize = 2'u8
    NimInitTransmitWindowOffset = 0'u16
    NimInitTransmitWindowDelaySlots = NimInitHalfSlotsPerConnIntervalUnit
    NimInitConnPhyLeadSlots = 4'u32
    NimInitConnectReqTailUs = 1000'u32
    NimInitConnectReqTailSlots = 4'u32
    NimInitConnectReqHandoffGuardSlots = 0'u32
    NimInitFirstAnchorSchedulerGuardSlots = 0'u32
    NimInitMaxChannelDwellSlotsConfig {.intdefine.}: int = 96
    NimInitMaxChannelDwellSlots =
      when NimInitMaxChannelDwellSlotsConfig < 1:
        1'u32
      else:
        uint32(NimInitMaxChannelDwellSlotsConfig)
    # The legacy initiator activity stores a hardware tail through event+0x9C.
    # Use the next connection slot for pure-central handoff to keep that tail
    # clear of connection state.
    NimInitConnHandle = 2'u16
    NimInitDefaultConnInterval = 0x0018'u16
    NimInitDefaultSupervisionTimeout = 0x0190'u16
    NimInitRoleCentral = 1'u8
    # Legacy initiator EM control words are role-specific.  They intentionally
    # differ from scan-mode controls: the hardware uses them to arm the
    # CONNECT_IND TX descriptor and the matching ADV RX descriptor in one event.
    # Legacy initiator event descriptors: one hardware-owned TX descriptor for
    # the CONNECT_IND and one RX descriptor for the advertising PDU that anchors
    # the first data-channel event.  The BL808 encoding is advertising-channel
    # dependent; using a single channel's words makes central connection
    # attempts intermittently fail when the peer is first observed elsewhere.
    NimInitTxDescCtl1 = 0x1194'u16
    NimInitRxWindowCtl = 1'u16
    NimInitTailPacketPtr = 0x0A20'u16
    NimInitTailPacketCtl = 0x0428'u16
    NimInitTailHeaderCtl = 0x060E'u16
    NimInitTailFlags = 0x2000'u16
    # Use CSA#1 for legacy initiation unless CSA#2 is explicitly enabled and
    # advertised in the local feature set. CSA#1 is mandatory, while setting
    # ChSel without matching capabilities can make peers ignore CONNECT_IND.
    NimInitConnectIndChSelBit =
      when bl808BleNimCentralChSel2: 0x0020'u16 else: 0'u16

  proc nimScanParam16(off: int, fallback: uint16): uint16 =
    let raw = uint16(nim_scan_params[off]) or
      (uint16(nim_scan_params[off + 1]) shl 8)
    if raw == 0'u16: fallback else: raw

  proc nimInitPutLe16(dst: ptr UncheckedArray[uint8], off: int,
                      value: uint16) {.inline.} =
    dst[off] = uint8(value and 0x00FF'u16)
    dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc nimInitPutLe32(dst: ptr UncheckedArray[uint8], off: int,
                      value: uint32) {.inline.} =
    dst[off] = uint8(value and 0x000000FF'u32)
    dst[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    dst[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    dst[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

  proc nimInitParam16(off: int, fallback: uint16): uint16 =
    let raw = uint16(nim_init_hci_params[off]) or
      (uint16(nim_init_hci_params[off + 1]) shl 8)
    if raw == 0'u16: fallback else: raw

  proc nimInitConnIntervalUnits(): uint16 {.inline.} =
    nimInitParam16(13, NimInitDefaultConnInterval)

  proc nimInitSupervisionTimeoutUnits(): uint16 {.inline.} =
    nimInitParam16(19, NimInitDefaultSupervisionTimeout)

  proc nimScanIntervalUnits(): uint16 {.inline.} =
    nimScanParam16(1, 0x0060'u16)

  proc nimScanWindowUnits(): uint16 {.inline.} =
    let interval = nimScanIntervalUnits()
    let requested = nimScanParam16(3, 0x0030'u16)
    if requested > interval: interval else: requested

  proc nimScanActive(): bool {.inline.} =
    (nim_scan_params[0] and 0x01'u8) != 0'u8

  proc nimScanActivityWord(): uint16 {.inline.} =
    if nimScanActive(): NimScanActiveActivityWord else: NimScanPassiveActivityWord

  proc nimScanReqHeader(): uint16 {.inline.} =
    let txAdd = uint16(nim_scan_params[5] and 0x01'u8) shl 6
    let rxAdd = uint16(nim_scan_req_peer_addr_type and 0x01'u32) shl 7
    (NimScanReqPduLen shl 8) or NimScanReqPduType or txAdd or rxAdd

  proc programBtbleScanReqTxDesc() =
    let desc = BTBLE_EM_BASE + NimScanReqTxDescOffset
    let header = if nimScanActive(): nimScanReqHeader() else: 0'u16
    btbleLegacyTxDescProgram(desc, 0'u16, header, 0'u16)

  proc nimScanIntervalSlots(): uint32 {.inline.} =
    uint32(nimScanIntervalUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimScanWindowSlots(): uint32 {.inline.} =
    uint32(nimScanWindowUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimScanRescheduleLeadSlots(): uint32 {.inline.} =
    let interval = nimScanIntervalSlots()
    let window = nimScanWindowSlots()
    let gap =
      if interval > window: interval - window
      else: NimScanMinLeadSlots
    if gap < NimScanMinLeadSlots: NimScanMinLeadSlots else: gap

  proc nimScanFallbackDelaySlots(): uint32 {.inline.} =
    ## Fallback polling re-arms a missed callback one scheduler lead before the
    ## next scan interval, not at the scan gap.  Re-arming at the gap overlaps the
    ## still-active window and eventually fills the hardware program-slot FIFO.
    let interval = nimScanIntervalSlots()
    if interval > NimScanMinLeadSlots:
      interval - NimScanMinLeadSlots
    else:
      interval

  proc nimScanTimeReached(target: uint32): bool =
    let now = currentBtbleTime()
    ((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32

  proc enableBtbleLegacySchedulerEvents() =
    ## HCI Reset disables the BTBLE event sources while preserving the already
    ## initialized core.  Scanner and initiator roles both use the legacy
    ## scheduler FIFO path, so re-arm the same event bits that cold init uses
    ## before pushing role programs.
    regWrite(BLE_BASE + BTBLE_INTACK_OFFSET,
             regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
    writeBtbleInterruptMask(BtbleIntLegacyScheduler)
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()

  proc nimAdvRfChannelIndex(idx: uint8): uint16 {.inline.} =
    ## The BL808 legacy activity channel field is programmed with the RF
    ## frequency index for scanner activities.  BLE advertising channels
    ## 39/37/38 map to RF indexes 39/0/12.
    case idx mod 3'u8
    of 0'u8: 39'u16
    of 1'u8: 0'u16
    else: 12'u16

  proc nimInitAdvChannelNumber(idx: uint8): uint16 {.inline.} =
    ## Legacy initiator activities use the Bluetooth advertising channel
    ## number in the same EM field where scanner activities use an RF index.
    ## This matches vendor LLD init snapshots, which program values such as
    ## 0x8026 for advertising channel 38.
    case idx mod 3'u8
    of 0'u8: 39'u16
    of 1'u8: 37'u16
    else: 38'u16

  proc nimInitLegacyCtlWord(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16, 39'u16: 0x69F5'u16
    else: 0xE9F5'u16

  proc nimInitTxDescCtl0(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x2402'u16
    else: 0x2442'u16

  proc nimInitRxDescCtl0(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x1991'u16
    of 39'u16: 0x3D91'u16
    else: 0x3F91'u16

  proc nimInitRxDescCtl1(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16, 39'u16: 0x40F1'u16
    else: 0x40F1'u16

  proc nimInitRxDescCtl2(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x8765'u16
    of 39'u16: 0x9765'u16
    else: 0x85E5'u16

  proc nimScanNextAdvChannel(): uint16 =
    let idx = nim_scan_channel_cursor mod 3'u8
    nim_scan_channel_cursor = (nim_scan_channel_cursor + 1'u8) mod 3'u8
    result = nimAdvRfChannelIndex(idx)
    nim_scan_last_channel_index = idx.uint32
    nim_scan_last_adv_channel = result.uint32

  proc nimInitPeerAddrLow(params: ptr uint8): uint32 {.inline.} =
    let req = hciLeCreateConnReq(params)
    uint32(req.peerAddr.data[0]) or
      (uint32(req.peerAddr.data[1]) shl 8) or
      (uint32(req.peerAddr.data[2]) shl 16) or
      (uint32(req.peerAddr.data[3]) shl 24)

  proc nimInitPeerAddrHigh(params: ptr uint8): uint32 {.inline.} =
    let req = hciLeCreateConnReq(params)
    uint32(req.peerAddr.data[4]) or (uint32(req.peerAddr.data[5]) shl 8)

  proc nimInitSeedChannelFromScanHint(params: ptr uint8): bool =
    ## LE Create Connection consumes a peer address learned from advertising
    ## reports.  Seed the first initiator window from the most recent matching
    ## scanner observation, then let the normal channel dwell/rotation continue.
    let req = hciLeCreateConnReq(params)
    let peerType = uint32(req.peerAddrType and 0x01'u8)
    let peer0 = nimInitPeerAddrLow(params)
    let peer1 = nimInitPeerAddrHigh(params)
    let written = nim_scan_peer_hint_write_index
    let limit =
      if written < NimScanPeerHintSlots.uint32:
        written
      else:
        NimScanPeerHintSlots.uint32
    for age in 0'u32 ..< limit:
      let slot =
        ((written - 1'u32 - age) mod NimScanPeerHintSlots.uint32).int
      if nim_scan_peer_hint_type[slot] == peerType and
          nim_scan_peer_hint_addr0[slot] == peer0 and
          nim_scan_peer_hint_addr1[slot] == peer1:
        let idx = nim_scan_peer_hint_channel_index[slot] mod 3'u32
        nim_init_channel_cursor = uint8(idx)
        nim_init_channel_seed = idx or 0x80000000'u32
        nim_init_channel_hint_index = idx
        nim_init_channel_hint_adv_channel = nim_scan_peer_hint_adv_channel[slot]
        inc nim_init_channel_hint_hit_count
        return true
    nim_init_channel_hint_index = 0xFFFFFFFF'u32
    nim_init_channel_hint_adv_channel = 0
    inc nim_init_channel_hint_miss_count
    false

  proc nimInitWindowUnits(): uint16 {.inline.} =
    let interval = nimInitParam16(0, nimScanIntervalUnits())
    let requested = nimInitParam16(2, nimScanWindowUnits())
    if requested > interval: interval else: requested

  proc nimInitWindowEmUnits(): uint16 {.inline.} =
    nimInitWindowUnits()

  proc nimInitIntervalSlots(): uint32 {.inline.} =
    uint32(nimInitParam16(0, nimScanIntervalUnits())) *
      NimScanHalfSlotsPerScanUnit

  proc nimInitWindowSlots(): uint32 {.inline.} =
    uint32(nimInitWindowUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimInitContinuousWindow(): bool {.inline.} =
    nimInitWindowUnits() >= nimInitParam16(0, nimScanIntervalUnits())

  proc nimInitEventWindowSlots(): uint32 {.inline.} =
    let windowSlots = nimInitWindowSlots()
    if nimInitContinuousWindow() and windowSlots > NimInitMaxChannelDwellSlots:
      NimInitMaxChannelDwellSlots
    else:
      windowSlots

  proc nimInitEventWindowUnits(): uint16 {.inline.} =
    let slots = nimInitEventWindowSlots()
    let units = (slots + NimScanHalfSlotsPerScanUnit - 1'u32) div
      NimScanHalfSlotsPerScanUnit
    if units == 0'u32: 1'u16 else: uint16(units and 0xFFFF'u32)

  proc nimInitRescheduleLeadSlots(): uint32 {.inline.} =
    let interval = nimInitIntervalSlots()
    let window = nimInitWindowSlots()
    let gap =
      if interval > window: interval - window
      else: NimInitMinLeadSlots
    if gap < NimInitMinLeadSlots: NimInitMinLeadSlots else: gap

  proc nimInitFallbackDelaySlots(): uint32 {.inline.} =
    ## See nimScanFallbackDelaySlots: the callback path uses interval-window as
    ## the lead time, while polling uses the full interval cadence.
    if nimInitContinuousWindow() and
        nimInitWindowSlots() > NimInitMaxChannelDwellSlots:
      return nimInitEventWindowSlots()
    let interval = nimInitIntervalSlots()
    if interval > NimInitMinLeadSlots:
      interval - NimInitMinLeadSlots
    else:
      interval

  proc nimInitTargetReached(targetClock, deadline: uint32): bool {.inline.} =
    ((targetClock - deadline) and 0x0FFFFFFF'u32) < 0x08000000'u32

  proc nimInitChannelDwellSlots(): uint32 {.inline.} =
    let window = nimInitWindowSlots()
    if window < NimInitMaxChannelDwellSlots:
      window
    else:
      NimInitMaxChannelDwellSlots

  proc nimInitNextAdvChannel(targetClock: uint32): uint16 =
    ## Keep the selected channel stable across early scheduler completions, but
    ## bound the dwell so a low-duty advertiser cannot phase-lock against a
    ## full-window channel.
    if nim_init_channel_window_valid != 0'u32 and
        not nimInitTargetReached(targetClock, nim_init_channel_window_deadline):
      return uint16(nim_init_last_adv_channel and 0xFFFF'u32)

    let idx = nim_init_channel_cursor mod 3'u8
    nim_init_channel_cursor = (nim_init_channel_cursor + 1'u8) mod 3'u8
    result = nimInitAdvChannelNumber(idx)
    nim_init_last_channel_index = idx.uint32
    nim_init_last_adv_channel = result.uint32
    nim_init_channel_window_valid = 1
    nim_init_channel_window_deadline =
      (targetClock + nimInitChannelDwellSlots()) and 0x0FFFFFFF'u32

  proc nimInitWriteConnReqData() =
    ## The legacy initiator TX buffer contains only the CONNECT_IND LLData.
    ## The activity record provides InitA/AdvA and the hardware prefixes those
    ## addresses when it builds the over-the-air 34-byte CONNECT_IND payload.
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset0.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset1.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset2.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)

  proc nimInitAccessAddress(): uint32 {.inline.} =
    uint32(nim_init_ll_data[0]) or
      (uint32(nim_init_ll_data[1]) shl 8) or
      (uint32(nim_init_ll_data[2]) shl 16) or
      (uint32(nim_init_ll_data[3]) shl 24)

  proc computeConnectIndHeaderFlags(): uint16 {.inline.} =
    ## The CONNECT_IND PDU header carries the initiator address type in TxAdd
    ## and the advertiser address type in RxAdd.  HCI also has identity-address
    ## types 2 and 3; the over-the-air legacy bit is still the rand(om)/public low
    ## bit.
    let txAdd = uint16(nim_init_hci_params[12] and 0x01'u8) shl 6
    let rxAdd = uint16(nim_init_hci_params[5] and 0x01'u8) shl 7
    NimInitConnectIndChSelBit or txAdd or rxAdd

  proc nimInitConnectIndHeader(): uint16 {.inline.} =
    (uint16(NimInitConnectIndPayloadLen) shl 8) or
      NimInitConnectIndPduType or computeConnectIndHeaderFlags()

  proc nimInitBuildConnReqData() =
    let ll = cast[ptr UncheckedArray[uint8]](addr nim_init_ll_data[0])
    discard c_memset(addr nim_init_ll_data[0], 0,
                     nim_init_ll_data.len.csize_t)
    lld_aa_gen(addr nim_init_ll_data[0], 1'u8)
    var crcInit = currentBtbleTime() and 0x00FFFFFF'u32
    if crcInit == 0'u32:
      crcInit = 0x555555'u32
    ll[4] = uint8(crcInit and 0xFF'u32)
    ll[5] = uint8((crcInit shr 8) and 0xFF'u32)
    ll[6] = uint8((crcInit shr 16) and 0xFF'u32)
    ll[7] = NimInitTransmitWindowSize
    nimInitPutLe16(ll, 8, NimInitTransmitWindowOffset)
    nimInitPutLe16(ll, 10, nimInitConnIntervalUnits())
    nimInitPutLe16(ll, 12, nimInitParam16(17, 0'u16))
    nimInitPutLe16(ll, 14, nimInitSupervisionTimeoutUnits())
    ll[16] = 0xFF'u8
    ll[17] = 0xFF'u8
    ll[18] = 0xFF'u8
    ll[19] = 0xFF'u8
    ll[20] = 0x1F'u8
    let hop = uint8(5'u32 + (currentBtbleTime() mod 12'u32))
    let sca = 0'u8
    ll[21] = uint8(((sca and 0x07'u8) shl 5) or (hop and 0x1F'u8))
    nim_init_last_access_addr = nimInitAccessAddress()
    nimInitWriteConnReqData()

  proc programBtbleInitTxDesc() =
    ## The initiator event record points at the same legacy TX descriptor slot
    ## active scanning uses for SCAN_REQ.  Rebuild the descriptor as CONNECT_IND
    ## before scheduling, matching the vendor lld_init_start descriptor path.
    let desc = BTBLE_EM_BASE + NimInitTxDescOffset
    btbleLegacyTxDescProgram(
      desc, 0'u16, nimInitConnectIndHeader(), NimInitConnReqDataOffset0)

  proc nimInitRecordRx(header, status, buf: uint16, peer0, peer1,
                       reason: uint32) =
    let slot = nim_init_rx_log_index and 0x07'u32
    nim_init_rx_header_log[slot.int] = header.uint32
    nim_init_rx_status_log[slot.int] =
      (status.uint32 shl 16) or uint32(buf)
    nim_init_rx_peer0_log[slot.int] = peer0
    nim_init_rx_peer1_log[slot.int] = peer1
    nim_init_rx_reason_log[slot.int] = reason
    nim_init_rx_log_index = nim_init_rx_log_index + 1'u32

  proc nimInitPeerMatches(header: uint16, buf: uint16, status: uint16): bool =
    inc nim_init_rx_count
    inc nim_init_total_rx_count
    nim_init_rx_last_header = header.uint32
    nim_init_rx_last_buf = buf.uint32
    let pduType = uint8(header and 0x000F'u16)
    if pduType != 0x00'u8:
      inc nim_init_rx_pdu_mismatch_count
      inc nim_init_total_pdu_mismatch_count
      nim_init_rx_match_reason = 1
      nimInitRecordRx(header, status, buf, 0, 0, 1)
      return false
    let pduLen = uint8((header shr 8) and 0x003F'u16)
    if pduLen < 6'u8:
      inc nim_init_rx_short_count
      inc nim_init_total_short_count
      nim_init_rx_match_reason = 3
      nimInitRecordRx(header, status, buf, 0, 0, 3)
      return false
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    nim_init_rx_last_peer0 = readBleAddrLow(payloadBase)
    nim_init_rx_last_peer1 = readBleAddrHigh(payloadBase)
    for j in 0 ..< 6:
      if read8(payloadBase + j.uint32) != nim_init_hci_params[6 + j]:
        inc nim_init_rx_addr_mismatch_count
        inc nim_init_total_addr_mismatch_count
        nim_init_rx_match_reason = 4
        nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                        nim_init_rx_last_peer1, 4)
        return false
    inc nim_init_rx_addr_match_count
    inc nim_init_total_addr_match_count
    let actualAddrType = uint8((header shr 6) and 0x0001'u16)
    let expectedAddrType = nim_init_hci_params[5] and 0x01'u8
    if actualAddrType != expectedAddrType:
      inc nim_init_rx_type_mismatch_count
      inc nim_init_total_type_mismatch_count
      nim_init_rx_match_reason = 2
      nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                      nim_init_rx_last_peer1, 2)
      return false
    nim_init_rx_match_reason = 0
    nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                    nim_init_rx_last_peer1, 0)
    true

  proc nimInitConnectReqDelaySlots(pduLen: uint8): uint32 =
    let advPacketHalfUs = (uint32(pduLen) + 10'u32) * 16'u32
    let connectReqHalfUs = (NimInitConnectIndPayloadLen.uint32 + 10'u32) *
      16'u32
    let tifsHalfUs = 300'u32
    btbleDelayTicksCeilSlots(advPacketHalfUs + tifsHalfUs +
                             connectReqHalfUs)

  proc nimInitComputeHandoffReadyClock(rxClock: uint32, pduLen: uint8): uint32 =
    ## Keep the matched advertising RX descriptor owned until the controller has
    ## had enough time to transmit CONNECT_IND, then free it before connection
    ## event 0 needs to be scheduled.
    (rxClock + nimInitConnectReqDelaySlots(pduLen) +
     NimInitConnectReqHandoffGuardSlots) and 0x0FFFFFFF'u32

  proc nimInitFirstAnchor(rxClock: uint32, pduLen: uint8,
                          handoffClock: uint32): uint32 =
    let connectReqDelaySlots = nimInitConnectReqDelaySlots(pduLen)
    let schedulerLeadSlots =
      when bl808BleNimConnectionEnabled:
        NimConnInitialCentralScheduleLeadSlots
      else:
        NimInitMinLeadSlots
    let transmitWindowSlots =
      uint32(NimInitTransmitWindowSize) * NimInitHalfSlotsPerConnIntervalUnit
    let windowOffsetSlots =
      uint32(NimInitTransmitWindowOffset) *
      NimInitHalfSlotsPerConnIntervalUnit
    let windowStart =
      (rxClock + connectReqDelaySlots + NimInitTransmitWindowDelaySlots +
       windowOffsetSlots) and 0x0FFFFFFF'u32
    let earliestOffset =
      if transmitWindowSlots > NimInitConnPhyLeadSlots:
        NimInitConnPhyLeadSlots
      else:
        0'u32
    let latestOffset =
      if transmitWindowSlots >
          NimInitConnPhyLeadSlots + schedulerLeadSlots:
        transmitWindowSlots - NimInitConnPhyLeadSlots
      else:
        transmitWindowSlots
    let handoffOffset =
      ((handoffClock + schedulerLeadSlots +
        NimInitFirstAnchorSchedulerGuardSlots) - windowStart) and
      0x0FFFFFFF'u32
    var targetOffset = earliestOffset
    if handoffOffset < 0x08000000'u32 and handoffOffset > targetOffset:
      targetOffset = handoffOffset
    if targetOffset > latestOffset:
      targetOffset = latestOffset

    # CONNECT_IND only advertises the first-event transmit window; the central
    # chooses the exact first master packet time.  Choose that time at handoff
    # using the current controller clock so a late-but-still-in-window handoff
    # does not silently schedule event 1 before the peer has ever anchored.
    (windowStart + targetOffset) and 0x0FFFFFFF'u32

  proc nimInitClockWithinRxWindow(clock, eventClock: uint32): bool =
    let elapsed = (clock - eventClock) and 0x0FFFFFFF'u32
    let window = nimInitWindowSlots()
    elapsed < 0x08000000'u32 and elapsed <= window + NimInitMinLeadSlots

  proc nimInitExpandRxClock(rawClock, referenceClock: uint32): uint32 =
    let reference = referenceClock and 0x0FFFFFFF'u32
    let rawLow = rawClock and 0x0000FFFF'u32
    var candidate = (reference and 0x0FFF0000'u32) or rawLow
    let ahead = (candidate - reference) and 0x0FFFFFFF'u32
    if ahead < 0x08000000'u32:
      if ahead > 0x00008000'u32:
        candidate = (candidate - 0x00010000'u32) and 0x0FFFFFFF'u32
    else:
      let behind = (reference - candidate) and 0x0FFFFFFF'u32
      if behind > 0x00008000'u32:
        candidate = (candidate + 0x00010000'u32) and 0x0FFFFFFF'u32
    candidate and 0x0FFFFFFF'u32

  proc nimInitRxClock(rawClock: uint32): uint32 =
    let now = currentBtbleTime()
    let eventClock =
      if nim_init_rx_event_clock != 0'u32:
        nim_init_rx_event_clock
      else:
        nim_init_event_target_clock
    let referenceClock =
      if eventClock != 0'u32: eventClock
      else: now
    nim_init_last_rx_now = now
    nim_init_last_rx_event_clock = eventClock

    if rawClock != 0'u32:
      nim_init_last_rx_clock_source = 1
      return nimInitExpandRxClock(rawClock, referenceClock)

    if eventClock != 0'u32:
      let zeroClock = nimInitExpandRxClock(rawClock, eventClock)
      if nimInitClockWithinRxWindow(zeroClock, eventClock):
        nim_init_last_rx_clock_source = 1
        return zeroClock

    # Initiator RX descriptors on BL808 can omit the coarse clock while still
    # reporting a valid RX event.  When that happens inside the active window,
    # use the live BTBLE clock just like the vendor path's lld_read_clock()
    # handoff instead of seeding the connection scheduler from zero.
    if eventClock == 0'u32 or nimInitClockWithinRxWindow(now, eventClock):
      nim_init_last_rx_clock_source = 2
      return now

    nim_init_last_rx_clock_source = 3
    eventClock and 0x0FFFFFFF'u32

  proc nimInitEventDone(event: uint8): bool {.inline.} =
    event == 0'u8 or event == 1'u8 or event == 7'u8 or event == 0xFF'u8

  proc nimInitWindowDoneDeadline(baseClock: uint32): uint32 {.inline.} =
    (baseClock + nimInitEventWindowSlots() + NimInitConnectReqTailSlots +
     NimInitMinLeadSlots) and 0x0FFFFFFF'u32

  proc nimInitProgramDone(programCount: uint32, deadline: uint32): bool =
    if programCount != 0'u32 and
        nim_init_event_done_program_count == programCount:
      return true
    deadline != 0'u32 and nimScanTimeReached(deadline)

  proc clearBtbleLegacyEventEm(em: uint32) =
    ## The BL808 activity record is a 0x94-byte EM object.  Every role transition
    ## must install a complete record instead of inheriting opaque state left by
    ## a previous role or by hardware.
    for off in countup(0'u32, 0x92'u32, 2'u32):
      write16(em + off, 0'u16)

  proc programBtbleLegacyScanEm() =
    let em = BTBLE_EM_BASE + NimScanEventEmOffset
    var addrBytes: array[6, uint8]
    localAddrBytes(addr addrBytes[0], nim_scan_params[5])
    let advChannel = nimScanNextAdvChannel()
    configureBleRfChannelMhz(bleRfLegacyScanChannelMhz(advChannel))
    programBtbleScanReqTxDesc()

    clearBtbleLegacyEventEm(em)
    write16(em + 0x00'u32, nimScanActivityWord())
    write16(em + 0x02'u32,
            0x0020'u16 or uint16(nim_scan_params[5] and 0x01'u8))
    write16(em + 0x06'u32, 0x1000'u16)
    copyBytes(em + 0x08'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x0E'u32)
    let scanCtrl =
      0x0008'u16 or
      (uint16(nim_scan_params[0] and 0x01'u8) shl 4) or
      (uint16(nim_scan_params[6] and 0x03'u8) shl 8)
    write16(em + 0x16'u32, scanCtrl)
    write16(em + 0x18'u32, 0x8000'u16 or (advChannel and 0x003F'u16))
    write16(em + 0x1A'u32, 0'u16)
    write16(em + 0x1C'u32, 0'u16)
    write16(em + 0x1E'u32, 0x8000'u16 or
            (nimScanWindowUnits() and 0x3FFF'u16))
    write16(em + 0x24'u32,
            if nimScanActive(): NimScanReqTxDescPtr else: 0'u16)
    write16(em + 0x26'u32, 0'u16)
    write16(em + 0x2A'u32, 0'u16)
    write16(em + 0x2E'u32, 0'u16)
    write16(em + 0x30'u32, nimScanWindowUnits())
    write16(em + 0x32'u32, 0'u16)
    write16(em + 0x34'u32, 0'u16)
    write16(em + 0x36'u32, 0'u16)
    write16(em + 0x38'u32, 0x4672'u16)
    write16(em + 0x3A'u32, 0'u16)
    write16(em + 0x44'u32, 0'u16)
    write16(em + 0x56'u32, 0'u16)
    regWrite((BLE_BASE + 0x934'u32).uint, 0x00010001'u32)

  proc programBtbleLegacyInitiatorEm(advChannel: uint16) =
    let em = BTBLE_EM_BASE + NimInitEventEmOffset
    var addrBytes: array[6, uint8]
    localAddrBytes(addr addrBytes[0], nim_init_hci_params[12])
    configureBleRfChannelMhz(bleRfChannelMhz(advChannel))
    nimInitWriteConnReqData()
    programBtbleInitTxDesc()

    clearBtbleLegacyEventEm(em)
    write16(em + 0x00'u32, 0x0209'u16)
    write16(em + 0x02'u32,
            0x0020'u16 or uint16(nim_init_hci_params[12] and 0x01'u8))
    write16(em + 0x04'u32, nimInitLegacyCtlWord(advChannel))
    write16(em + 0x06'u32, 0x1000'u16)
    copyBytes(em + 0x08'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x0E'u32)
    write16(em + 0x16'u32, uint16(nim_init_hci_params[4] and 0x01'u8) shl 8)
    write16(em + 0x18'u32, 0x8000'u16 or (advChannel and 0x003F'u16))
    write16(em + 0x1A'u32, 0'u16)
    write16(em + 0x1C'u32, 0'u16)
    write16(em + 0x1E'u32,
            0x8000'u16 or (nimInitEventWindowUnits() and 0x3FFF'u16))
    write16(em + 0x20'u32, nimInitTxDescCtl0(advChannel))
    write16(em + 0x22'u32, NimInitTxDescCtl1)
    write16(em + 0x24'u32, NimInitTxDescPtr)
    write16(em + 0x26'u32, 0'u16)
    write16(em + 0x28'u32, nimInitRxDescCtl0(advChannel))
    write16(em + 0x2A'u32, nimInitRxDescCtl1(advChannel))
    write16(em + 0x2C'u32, nimInitRxDescCtl2(advChannel))
    write16(em + 0x2E'u32, 0'u16)
    write16(em + 0x30'u32, NimInitRxWindowCtl)
    write16(em + 0x32'u32, 0'u16)
    write16(em + 0x34'u32, 0'u16)
    write16(em + 0x36'u32, 0'u16)
    write16(em + 0x38'u32, 0x4672'u16)
    let headerFlags = computeConnectIndHeaderFlags()
    nim_init_connect_ind_header_flags = headerFlags.uint32
    write16(em + 0x3A'u32, 0'u16)
    copyBytes(em + 0x3C'u32, addr nim_init_hci_params[6], 6)
    write16(em + 0x42'u32, uint16(nim_init_hci_params[5] and 0x01'u8))
    write16(em + 0x44'u32, 0'u16)
    write16(em + 0x56'u32, 0'u16)
    write16(em + 0x84'u32, NimInitTailPacketPtr)
    write16(em + 0x86'u32, NimInitTailPacketCtl)
    write16(em + 0x88'u32, NimInitTailHeaderCtl)
    write16(em + 0x8A'u32, uint16(NimInitEventEmOffset and 0xFFFF'u32))
    write16(em + 0x8C'u32, uint16(currentBtbleTime() and 0x0000FFFF'u32))
    write16(em + 0x8E'u32, NimInitTailFlags)
    copyBytes(em + 0x90'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x96'u32)
    regWrite((BLE_BASE + 0x934'u32).uint, 0x00010001'u32)

  when defined(BleDebugCounters):
    proc nimInitCaptureProgramSnapshot(advChannel, now, targetClock,
                                       lead: uint32) =
      let em = BTBLE_EM_BASE + NimInitEventEmOffset
      inc nim_init_program_snapshot_count
      nim_init_program_snapshot_channel = advChannel
      nim_init_program_snapshot_timing[0] = now and 0x0FFFFFFF'u32
      nim_init_program_snapshot_timing[1] = targetClock and 0x0FFFFFFF'u32
      nim_init_program_snapshot_timing[2] = lead
      nim_init_program_snapshot_timing[3] = uint32(nimInitEventWindowUnits())
      nim_init_program_snapshot_timing[4] = nimInitEventWindowSlots()
      nim_init_program_snapshot_timing[5] = nim_init_channel_seed
      nim_init_program_snapshot_timing[6] = nim_init_channel_hint_index
      nim_init_program_snapshot_timing[7] = nim_init_program_count
      for i in 0 ..< nim_init_program_snapshot_em.len:
        nim_init_program_snapshot_em[i] = read32(em + uint32(i * 4))
      for i in 0 ..< nim_init_program_snapshot_tx_desc.len:
        nim_init_program_snapshot_tx_desc[i] =
          read32(BTBLE_EM_BASE + NimInitTxDescOffset + uint32(i * 4))
      for i in 0 ..< nim_init_program_snapshot_sched.len:
        let off = i * 4
        nim_init_program_snapshot_sched[i] =
          uint32(nim_sch_prog[off]) or
          (uint32(nim_sch_prog[off + 1]) shl 8) or
          (uint32(nim_sch_prog[off + 2]) shl 16) or
          (uint32(nim_sch_prog[off + 3]) shl 24)

    proc nimInitCaptureHandoffSnapshot(reason: uint32, header: uint16,
                                       rxClock: uint32, rxFine: uint16) =
      ## Preserve the initiator activity exactly as it looked when the pure
      ## central path handed off to the connection scheduler.  The scheduler
      ## clears this EM slot immediately afterwards.
      let em = BTBLE_EM_BASE + NimInitEventEmOffset
      inc nim_init_handoff_snapshot_count
      nim_init_handoff_snapshot_reason = reason
      nim_init_handoff_snapshot_timing[0] = currentBtbleTime()
      nim_init_handoff_snapshot_timing[1] =
        uint32(header) or (uint32(rxFine) shl 16)
      nim_init_handoff_snapshot_timing[2] = rxClock and 0x0FFFFFFF'u32
      nim_init_handoff_snapshot_timing[3] = nim_init_event_target_clock
      nim_init_handoff_snapshot_timing[4] = nim_init_rx_event_clock
      nim_init_handoff_snapshot_timing[5] = nim_init_handoff_ready_clock
      nim_init_handoff_snapshot_timing[6] = nim_init_handoff_deadline
      nim_init_handoff_snapshot_timing[7] = nim_init_event_count
      nim_init_handoff_snapshot_timing[8] = nim_init_last_event
      nim_init_handoff_snapshot_timing[9] = nim_init_tx_event_count
      nim_init_handoff_snapshot_timing[10] = nim_init_event_done_program_count
      nim_init_handoff_snapshot_timing[11] = nim_init_handoff_program_count
      nim_init_handoff_snapshot_timing[12] = nim_init_handoff_tx_event_count
      nim_init_handoff_snapshot_timing[13] = nim_init_program_count
      nim_init_handoff_snapshot_timing[14] = nim_init_next_program_at
      nim_init_handoff_snapshot_timing[15] = nim_init_pending_desc
      for i in 0 ..< nim_init_handoff_snapshot_em.len:
        nim_init_handoff_snapshot_em[i] = read32(em + uint32(i * 4))
      for i in 0 ..< nim_init_handoff_snapshot_desc.len:
        nim_init_handoff_snapshot_desc[i] =
          read32(BTBLE_EM_BASE + 0x0458'u32 + uint32(i * 4))
      for i in 0 ..< nim_init_handoff_snapshot_data.len:
        nim_init_handoff_snapshot_data[i] =
          read32(BTBLE_EM_BASE + 0x1780'u32 + uint32(i * 4))

    proc nimInitRecordSchEvent(timestamp: uint32, event: uint8) =
      let slot = int(nim_init_sch_event_log_index and 0x0F'u32)
      let intStat = regRead(BLE_BASE + 0x024'u32)
      let eventSlot = (intStat shr 24) and 0x0F'u32
      let slotStatus = uint32(read16(BTBLE_EM_BASE + eventSlot * 0x10'u32))
      nim_init_sch_event_code_log[slot] =
        event.uint32 or (eventSlot shl 8) or (slotStatus shl 16)
      nim_init_sch_event_time_log[slot] = timestamp and 0x0FFFFFFF'u32
      nim_init_sch_event_now_log[slot] = currentBtbleTime()
      nim_init_sch_event_state_log[slot] =
        (nim_init_active and 0x01'u32) or
        ((nim_init_handoff_pending and 0x01'u32) shl 1) or
        ((nim_init_rx_service_pending and 0x01'u32) shl 2) or
        ((nim_init_last_adv_channel and 0xFF'u32) shl 8)
      nim_init_sch_event_counts_log[slot] =
        (nim_init_program_count and 0xFFFF'u32) or
        ((nim_init_tx_event_count and 0xFFFF'u32) shl 16)
      nim_init_sch_event_done_log[slot] = nim_init_event_done_program_count
      nim_init_sch_event_int_log[slot] = intStat
      inc nim_init_sch_event_log_index

  proc pushNimScanProgram(leadSlots: uint32 = NimScanMinLeadSlots)
  proc pushNimInitiatorProgram(leadSlots: uint32 = NimInitMinLeadSlots)
  proc startNimInitiatorConnection(header: uint16, buf: uint16, rxClock: uint32,
                                   rxFine: uint16): bool
  proc nimInitServiceDeferredHandoff()
  proc nimInitRequestRxDescriptorService(eventClock: uint32)

  proc nimScanSchProgCb(timestamp: uint32, ctx: pointer,
                        event: uint8) {.cdecl.} =
    discard timestamp
    discard ctx
    inc nim_scan_event_count
    nim_scan_last_event = event.uint32
    if nim_scan_enabled and (event == 0'u8 or event == 1'u8 or
        event == 4'u8 or event == 7'u8):
      pushNimScanProgram(nimScanRescheduleLeadSlots())

  proc nimInitSchProgCb(timestamp: uint32, ctx: pointer,
                        event: uint8) {.cdecl.} =
    discard ctx
    inc nim_init_event_count
    nim_init_last_event = event.uint32
    when defined(BleDebugCounters):
      nimInitRecordSchEvent(timestamp, event)
    if event == 2'u8:
      nim_init_rx_event_clock =
        if timestamp != 0'u32: timestamp and 0x0FFFFFFF'u32
        else: nim_init_event_target_clock
      nimInitRequestRxDescriptorService(nim_init_rx_event_clock)
    elif event == 3'u8:
      inc nim_init_tx_event_count
      inc nim_init_total_tx_event_count
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
    elif event == 4'u8:
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
      elif nim_init_active != 0'u32:
        pushNimInitiatorProgram(nimInitRescheduleLeadSlots())
    if nimInitEventDone(event):
      nim_init_event_done_program_count = nim_init_program_count
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
      elif nim_init_active != 0'u32:
        let eventClock =
          if timestamp != 0'u32: timestamp and 0x0FFFFFFF'u32
          elif nim_init_rx_event_clock != 0'u32: nim_init_rx_event_clock
          else: nim_init_event_target_clock
        nimInitRequestRxDescriptorService(eventClock)

  proc nimInitRequestRxDescriptorService(eventClock: uint32) =
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32:
      return
    let clock =
      if eventClock != 0'u32: eventClock and 0x0FFFFFFF'u32
      else: nim_init_event_target_clock
    nim_init_rx_event_clock = clock
    nim_init_rx_service_pending = 1
    nim_init_rx_service_program_count = nim_init_program_count
    nim_init_rx_service_deadline = nimInitWindowDoneDeadline(clock)
    requestBtbleSwInterrupt()

  proc nimInitResumeAfterUnmatchedRx() =
    if nim_init_rx_service_pending == 0'u32 or
        nim_init_handoff_pending != 0'u32:
      return
    if not nimInitProgramDone(nim_init_rx_service_program_count,
                              nim_init_rx_service_deadline):
      return
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    if nim_init_active != 0'u32:
      pushNimInitiatorProgram(nimInitRescheduleLeadSlots())

  proc pushNimScanProgram(leadSlots: uint32 = NimScanMinLeadSlots) =
    nim_scan_debug_stage = 0x2000'u32
    programBtbleLegacyScanEm()
    nim_scan_debug_stage = 0x2010'u32
    let lead =
      if leadSlots < NimScanMinLeadSlots: NimScanMinLeadSlots else: leadSlots
    let now = currentBtbleTime()
    let targetClock = (now + lead) and 0x0FFFFFFF'u32
    nim_scan_debug_now = now
    nim_scan_debug_target = targetClock
    nim_scan_debug_lead = lead
    nim_scan_debug_stage = 0x2020'u32
    discard c_memset(addr nim_sch_prog[0], 0,
                     nim_sch_prog.len.csize_t)
    schProgWrite32(0x00, cast[uint32](cast[uint](nimScanSchProgCb)))
    schProgWrite32(0x04, targetClock)
    schProgWrite16(0x08, 0'u16)
    schProgWrite32(0x10, uint32(nimScanWindowUnits()) * 1250'u32)
    schProgWrite32(0x14, 0'u32)
    nim_sch_prog[0x18] = rwip_priority[0]
    nim_sch_prog[0x19] = 0'u8
    nim_sch_prog[0x1A] = rwip_priority[2]
    nim_sch_prog[0x1B] = 0x1F'u8
    nim_sch_prog[0x1C] = NimScanEventIndex
    nim_scan_debug_stage = 0x2030'u32
    sch_prog_push(addr nim_sch_prog[0])
    nim_scan_debug_stage = 0x2040'u32
    nim_scan_next_program_at = (targetClock + nimScanFallbackDelaySlots()) and
      0x0FFFFFFF'u32
    inc nim_scan_program_count
    nim_scan_debug_stage = 0x2050'u32

  proc pushNimInitiatorProgram(leadSlots: uint32 = NimInitMinLeadSlots) =
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32 or
        nim_init_rx_service_pending != 0'u32:
      return
    let lead =
      if leadSlots < NimInitMinLeadSlots: NimInitMinLeadSlots else: leadSlots
    let now = currentBtbleTime()
    let targetClock = (now + lead) and 0x0FFFFFFF'u32
    let advChannel = nimInitNextAdvChannel(targetClock)
    programBtbleLegacyInitiatorEm(advChannel)
    nim_init_event_target_clock = targetClock
    discard c_memset(addr nim_sch_prog[0],
                     0, nim_sch_prog.len.csize_t)
    schProgWrite32(0x00, cast[uint32](cast[uint](nimInitSchProgCb)))
    schProgWrite32(0x04, targetClock)
    schProgWrite16(0x08, 0'u16)
    schProgWrite32(0x10,
                      uint32(nimInitEventWindowUnits()) * 1250'u32 +
                      NimInitConnectReqTailUs)
    schProgWrite32(0x14, 0'u32)
    nim_sch_prog[0x18] = rwip_priority[4]
    nim_sch_prog[0x19] = 0'u8
    nim_sch_prog[0x1A] = rwip_priority[2]
    nim_sch_prog[0x1B] = 0x1F'u8
    nim_sch_prog[0x1C] = NimInitEventIndex
    when defined(BleDebugCounters):
      nimInitCaptureProgramSnapshot(advChannel.uint32, now, targetClock, lead)
    sch_prog_push(addr nim_sch_prog[0])
    nim_init_next_program_at = (targetClock + nimInitFallbackDelaySlots()) and
      0x0FFFFFFF'u32
    inc nim_init_program_count

  proc bleControllerServiceScan*() {.exportc, cdecl.} =
    if nim_init_rx_service_pending != 0'u32:
      serviceBtbleAdvRxDescriptors()
    nimInitServiceDeferredHandoff()
    nimInitResumeAfterUnmatchedRx()
    if nim_scan_enabled and nimScanTimeReached(nim_scan_next_program_at):
      pushNimScanProgram()
    if nim_init_active != 0'u32 and nim_init_handoff_pending == 0'u32 and
        nim_init_rx_service_pending == 0'u32 and
        nimScanTimeReached(nim_init_next_program_at):
      pushNimInitiatorProgram()

  proc nimInitValidCreateConnectionParams(params: ptr uint8,
                                          paramLen: uint8): uint8 =
    if params == nil or paramLen != 25'u8:
      return HciStatusInvalidParams
    let req = hciLeCreateConnReq(params)
    if req.filterPolicy != 0'u8:
      return HciStatusUnsupportedFeatureParam
    if req.peerAddrType > 3'u8 or req.ownAddrType > 3'u8:
      return HciStatusInvalidParams
    if req.connIntervalMin < 6'u16 or req.connIntervalMin > 3200'u16:
      return HciStatusInvalidParams
    if req.connIntervalMax < req.connIntervalMin or
        req.connIntervalMax > 3200'u16:
      return HciStatusInvalidParams
    if req.connLatency > 499'u16:
      return HciStatusInvalidParams
    if req.supervisionTimeout < 10'u16 or req.supervisionTimeout > 3200'u16:
      return HciStatusInvalidParams
    HciStatusSuccess

  proc programNimInitiator(params: ptr uint8, paramLen: uint8): uint8 =
    let paramStatus = nimInitValidCreateConnectionParams(params, paramLen)
    if paramStatus != HciStatusSuccess:
      return paramStatus
    when not (bl808BleNimPureConnection and bl808BleNimManualConnTx):
      discard params
      discard paramLen
      return HciStatusUnsupportedFeatureParam
    else:
      if nim_init_active != 0'u32 or nim_init_complete_pending != 0'u32 or
          nim_conn_active:
        return HciStatusCommandDisallowed
      if not nim_ble_core_ready:
        initBleCoreRegisters()
      ensureBleRf1MConfigured()
      initNimRwipRfTable()
      refreshNimSyncPositions()
      for i in 0 ..< nim_init_hci_params.len:
        nim_init_hci_params[i] = cast[ptr UncheckedArray[uint8]](params)[i]
      nim_scan_enabled = false
      sch_prog_init(3'u8)
      clearBtbleProgramSlots()
      resetBtbleAdvRxRing()
      nim_init_active = 1
      nim_init_complete_pending = 0
      nim_init_last_status = HciStatusSuccess.uint32
      nim_init_last_event = 0
      nim_init_last_rx_clock = 0
      nim_init_last_rx_fine = 0
      nim_init_last_anchor = 0
      nim_init_last_access_addr = 0
      nim_init_rx_count = 0
      nim_init_rx_match_reason = 0
      nim_init_rx_last_header = 0
      nim_init_rx_last_status = 0
      nim_init_rx_last_buf = 0
      nim_init_rx_last_peer0 = 0
      nim_init_rx_last_peer1 = 0
      nim_init_rx_pdu_mismatch_count = 0
      nim_init_rx_short_count = 0
      nim_init_rx_addr_mismatch_count = 0
      nim_init_rx_addr_match_count = 0
      nim_init_rx_type_mismatch_count = 0
      nim_init_connect_ind_header_flags = 0
      nim_init_next_program_at = 0
      nim_init_tx_event_count = 0
      nim_init_event_target_clock = 0
      nim_init_rx_event_clock = 0
      nim_init_last_rx_now = 0
      nim_init_last_rx_event_clock = 0
      nim_init_last_rx_clock_source = 0
      nim_init_rx_service_pending = 0
      nim_init_rx_service_program_count = 0
      nim_init_rx_service_deadline = 0
      nim_init_event_done_program_count = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
      nim_init_handoff_start_count = 0
      nim_init_handoff_timeout_count = 0
      nim_init_pending_header = 0
      nim_init_pending_rx_clock = 0
      nim_init_pending_rx_fine = 0
      nim_init_pending_desc = 0
      nim_init_pending_desc_status = 0
      nim_init_pending_desc_idx = 0
      # Prefer the channel on which the target address was just observed.  If
      # the create request was not preceded by a matching scan report, fall back
      # to the scanner cadence plus live controller time so repeated direct
      # create requests do not phase-lock on one advertising channel.
      if not nimInitSeedChannelFromScanHint(params):
        nim_init_channel_cursor =
          uint8((uint32(nim_scan_channel_cursor mod 3'u8) +
                 currentBtbleTime() mod 3'u32) mod 3'u32)
        nim_init_channel_seed = nim_init_channel_cursor.uint32
      nim_init_channel_window_valid = 0
      nim_init_channel_window_deadline = 0
      nim_init_last_channel_index = 0
      nim_init_last_adv_channel = 0
      nimInitBuildConnReqData()
      enableBtbleLegacySchedulerEvents()
      regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
      pushNimInitiatorProgram()
      HciStatusSuccess

  proc nimInitReleasePendingRxDesc() =
    if nim_init_pending_desc == 0'u32:
      return
    let desc = nim_init_pending_desc
    let status = uint16(nim_init_pending_desc_status and 0xFFFF'u32)
    let idx = nim_init_pending_desc_idx and 0x07'u32
    nim_init_pending_desc = 0
    nim_init_pending_desc_status = 0
    nim_init_pending_desc_idx = 0
    btbleRxDescClearDone(desc, status)
    when bl808BleNimPureConnection:
      noteNimRxDescConsumed(idx)
    else:
      lld_env[14] = uint8((idx + 1'u32) and 0x07'u32)

  proc failPendingNimInitiator(status: uint8) =
    if nim_init_complete_pending == 0'u32 and nim_init_active == 0'u32:
      return
    nimInitReleasePendingRxDesc()
    nim_init_active = 0
    nim_init_complete_pending = 0
    nim_init_rx_service_pending = 0
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_last_status = status.uint32
    when bl808BleNimPureConnection:
      nim_conn_state.active = false
      nim_conn_state.reschedulePending = false
      nim_conn_started = false
    sendLeConnectionCompleteStatusHandle(
      addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
      status, 0'u16, 0'u8)

  proc cancelNimInitiator(): uint8 =
    if nim_init_active == 0'u32 and nim_init_complete_pending == 0'u32:
      return HciStatusCommandDisallowed
    inc nim_init_cancel_count
    failPendingNimInitiator(0x3E'u8)
    HciStatusSuccess

  proc nimInitQueueConnectionHandoff(header: uint16, rxClock: uint32,
                                     rxFine: uint16, desc: uint32,
                                     status: uint16, idx: uint32) =
    if nim_init_handoff_pending != 0'u32:
      return
    let programCount =
      if nim_init_rx_service_program_count != 0'u32:
        nim_init_rx_service_program_count
      else:
        nim_init_program_count
    let eventClock =
      if nim_init_rx_event_clock != 0'u32:
        nim_init_rx_event_clock
      elif nim_init_event_target_clock != 0'u32:
        nim_init_event_target_clock
      else:
        rxClock
    nim_init_handoff_pending = 1
    nim_init_handoff_program_count = programCount
    nim_init_handoff_tx_event_count = nim_init_tx_event_count
    nim_init_handoff_ready_clock =
      nimInitComputeHandoffReadyClock(rxClock,
                                      uint8((header shr 8) and 0x003F'u16))
    nim_init_handoff_deadline = nimInitWindowDoneDeadline(eventClock)
    nim_init_pending_header = header.uint32
    nim_init_pending_rx_clock = rxClock and 0x0FFFFFFF'u32
    nim_init_pending_rx_fine = rxFine.uint32
    nim_init_pending_desc = desc
    nim_init_pending_desc_status = status.uint32
    nim_init_pending_desc_idx = idx and 0x07'u32
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    nim_init_next_program_at = 0
    requestBtbleSwInterrupt()

  proc startNimInitiatorConnection(header: uint16, buf: uint16, rxClock: uint32,
                                   rxFine: uint16): bool =
    when not (bl808BleNimPureConnection and bl808BleNimManualConnTx):
      discard header
      discard buf
      discard rxClock
      discard rxFine
      false
    else:
      let pduLen = uint8((header shr 8) and 0x003F'u16)
      let handoffClock = currentBtbleTime()
      let anchor = nimInitFirstAnchor(rxClock, pduLen, handoffClock)
      let p = cast[ptr UncheckedArray[uint8]](addr nim_conn_params[0])
      discard c_memset(addr nim_conn_params[0],
                       0, nim_conn_params.len.csize_t)
      for i in 0 .. 20:
        p[i] = nim_init_ll_data[i]
      p[21] = nim_init_ll_data[21] and 0x1F'u8
      p[22] = (nim_init_ll_data[21] shr 5) and 0x07'u8
      nimInitPutLe16(p, 24, rxFine)
      nimInitPutLe32(p, 28, rxClock)
      nimInitPutLe32(p, 32, anchor)
      # The initiator path has already converted the matched advertising RX
      # timestamp into the first master-packet anchor inside the CONNECT_IND
      # transmit window.  Use direct-anchor mode so the connection scheduler
      # consumes p[32..35] instead of deriving an earlier anchor from rxClock.
      p[36] = 0'u8
      p[37] = 0'u8
      # lld_con_start takes ChSel as a byte bool(ean) and shifts it into the EM
      # channel-control word. Keep CONNECT_IND and the connection scheduler on
      # the same channel-selection algorithm.
      p[38] =
        when bl808BleNimCentralChSel2: 1'u8 else: 0'u8
      p[NimConnStartCentralRoleOffset] = NimInitRoleCentral

      nim_init_last_rx_clock = rxClock
      nim_init_last_rx_fine = rxFine.uint32
      nim_init_last_anchor = anchor
      nim_conn_last_rx_clock = rxClock
      nim_conn_last_rx_fine = rxFine.uint32
      nim_conn_last_anchor = anchor
      nim_conn_last_win_offset = NimInitTransmitWindowOffset.uint32
      nim_conn_last_interval = nimInitConnIntervalUnits().uint32
      nim_conn_last_timeout = nimInitSupervisionTimeoutUnits().uint32
      nim_conn_last_access_addr = nimInitAccessAddress()
      nim_conn_last_crcinit =
        uint32(nim_init_ll_data[4]) or
        (uint32(nim_init_ll_data[5]) shl 8) or
        (uint32(nim_init_ll_data[6]) shl 16)
      nim_conn_evt_handle = NimInitConnHandle.uint32
      nim_conn_evt_peer_type = uint32(nim_init_hci_params[5] and 1'u8)
      nim_conn_evt_peer_a0 =
        uint32(nim_init_hci_params[6]) or
        (uint32(nim_init_hci_params[7]) shl 8) or
        (uint32(nim_init_hci_params[8]) shl 16) or
        (uint32(nim_init_hci_params[9]) shl 24)
      nim_conn_evt_peer_a1 =
        uint32(nim_init_hci_params[10]) or
        (uint32(nim_init_hci_params[11]) shl 8)

      prepareBtbleConnectionRxRingForHandoff()
      writeBtbleInterruptMask(BtbleIntConnection)
      when defined(bl808m0):
        when not bl808BleNimRuntimeClicIrq:
          nimDisableM0BleClicIrq()
      initNimRwipRfTable()
      refreshNimSyncPositions()
      clearBtbleProgramSlots()
      nim_conn_last_status =
        nimLldConStart(NimInitConnHandle, addr nim_conn_params[0]).uint32
      nim_init_last_status = nim_conn_last_status
      if nim_conn_last_status != 0'u32:
        nim_conn_started = false
        failPendingNimInitiator(0x3E'u8)
        return true

      nim_init_active = 0
      nim_init_complete_pending = 1
      inc nim_init_start_count
      inc nim_init_total_start_count
      nim_conn_started = true
      nimLlcpPrimeStartup()
      noteNimPeripheralConnected(NimInitConnHandle)
      completeNimInitiatorHciConnection(NimInitConnHandle)
      true

  proc nimInitServiceDeferredHandoff() =
    if nim_init_handoff_pending == 0'u32:
      return
    let txDone =
      nim_init_tx_event_count != nim_init_handoff_tx_event_count
    let eventDone =
      nim_init_handoff_program_count != 0'u32 and
      nim_init_event_done_program_count == nim_init_handoff_program_count
    let readyReached =
      nim_init_handoff_ready_clock != 0'u32 and
      nimScanTimeReached(nim_init_handoff_ready_clock)
    let deadlineReached =
      nim_init_handoff_deadline != 0'u32 and
      nimScanTimeReached(nim_init_handoff_deadline)
    if not txDone and not readyReached and not eventDone and not deadlineReached:
      return

    let header = uint16(nim_init_pending_header and 0xFFFF'u32)
    let rxClock = nim_init_pending_rx_clock and 0x0FFFFFFF'u32
    let rxFine = uint16(nim_init_pending_rx_fine and 0x03FF'u32)
    when defined(BleDebugCounters):
      var snapshotReason = 0'u32
      if txDone:
        snapshotReason = snapshotReason or 0x01'u32
      if readyReached:
        snapshotReason = snapshotReason or 0x02'u32
      if eventDone:
        snapshotReason = snapshotReason or 0x04'u32
      if deadlineReached:
        snapshotReason = snapshotReason or 0x08'u32
      nimInitCaptureHandoffSnapshot(snapshotReason, header, rxClock, rxFine)
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_pending_header = 0
    nim_init_pending_rx_clock = 0
    nim_init_pending_rx_fine = 0
    inc nim_init_handoff_start_count
    inc nim_init_total_handoff_start_count
    if deadlineReached and not txDone and not readyReached and not eventDone:
      inc nim_init_handoff_timeout_count
      inc nim_init_total_handoff_timeout_count
    nimInitReleasePendingRxDesc()
    discard startNimInitiatorConnection(header, 0'u16, rxClock, rxFine)

  proc handleNimInitiatorAdvRx(header: uint16, buf: uint16, desc: uint32,
                               status: uint16, idx: uint32): bool =
    nim_init_rx_last_status = status.uint32
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32:
      return false
    if not nimInitPeerMatches(header, buf, status):
      return false
    inc nim_init_match_count
    inc nim_init_total_match_count
    let rxFine = btbleAdvRxFine(desc)
    let rxClock = nimInitRxClock(btbleAdvRxClock(desc))
    inc nim_init_complete_count
    nimInitQueueConnectionHandoff(header, rxClock, rxFine, desc, status, idx)
    true

  proc programNimScanning(enable: bool): uint8 =
    nim_scan_debug_stage = 0x3000'u32
    if not enable:
      nim_scan_enabled = false
      nim_scan_last_status = 0
      nim_scan_next_program_at = 0
      nim_scan_debug_stage = 0x3010'u32
      return HciStatusSuccess
    if not nim_ble_core_ready:
      nim_scan_debug_stage = 0x3020'u32
      initBleCoreRegisters()
      nim_scan_debug_stage = 0x3030'u32
    ensureBleRf1MConfigured()
    sch_prog_init(3'u8)
    clearBtbleProgramSlots()
    nim_scan_enabled = true
    nim_scan_last_status = 0
    nim_scan_next_program_at = 0
    nim_scan_peer_hint_write_index = 0
    for i in 0 ..< NimScanPeerHintSlots:
      nim_scan_peer_hint_addr0[i] = 0
      nim_scan_peer_hint_addr1[i] = 0
      nim_scan_peer_hint_type[i] = 0
      nim_scan_peer_hint_channel_index[i] = 0
      nim_scan_peer_hint_adv_channel[i] = 0
    resetBtbleAdvRxRing()
    enableBtbleLegacySchedulerEvents()
    regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
    nim_scan_debug_stage = 0x3050'u32
    pushNimScanProgram()
    nim_scan_debug_stage = 0x3060'u32
    HciStatusSuccess

proc programNimAdvertising(enable: bool): uint8 =
  nim_adv_debug_stage = 0x7000'u32
  nim_adv_debug_detail = if enable: 1'u32 else: 0'u32
  if not enable:
    nim_adv_enabled = false
    nim_adv_target_half_us = 0
    write16(BLE_EM_BASE + 0x0EA'u32, read16(BLE_EM_BASE + 0x0EA'u32) and
            not 0x2000'u16)
    writeBtbleInterruptMask(0)
    regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)
    nim_adv_debug_stage = 0x7010'u32
    return 0

  if not nim_ble_core_ready:
    nim_adv_debug_stage = 0x7020'u32
    initBleCoreRegisters()
    nim_adv_debug_stage = 0x7030'u32

  var pdu: array[39, uint8]
  let advLen = min(nim_adv_data_len.int, 31)
  nim_adv_debug_detail = advLen.uint32
  pdu[0] = 0x00'u8
  pdu[1] = uint8(6 + advLen)
  localAddrBytes(addr pdu[2], nim_adv_params[5])
  for i in 0 ..< advLen:
    pdu[8 + i] = nim_adv_data[i]
  copyBytes(BLE_EM_BASE + 0x600'u32, addr pdu[0], 8 + advLen)
  programBtbleLegacyAdv(advLen.uint8)
  nim_adv_debug_stage = 0x7040'u32

  let pduLen = uint16(8 + advLen)
  write16(BLE_EM_BASE + 0x28C'u32,
          ((pduLen and 0x00FF'u16) shl 8) or 0x0024'u16)
  write16(BLE_EM_BASE + 0x28E'u32, 0x0600'u16)
  write16(BLE_EM_BASE + 0x298'u32, 0x8000'u16)
  write16(BLE_EM_BASE + 0x29A'u32, 0x0600'u16)
  write16(BLE_EM_BASE + 0x29C'u32, pduLen)
  write16(BLE_EM_BASE + 0x0A4'u32, 0x0298'u16)

  write16(BLE_EM_BASE + 0x0EE'u32,
          (read16(BLE_EM_BASE + 0x0EE'u32) and not 0x001F'u16) or 0x0001'u16)
  write16(BLE_EM_BASE + 0x0EA'u32, 0xF005'u16)
  write16(BLE_EM_BASE + 0x0F8'u32, nim_adv_params[13].uint16 shl 8)
  write16(BLE_EM_BASE + 0x142'u32,
          read16(BLE_EM_BASE + 0x142'u32) and not 0x0080'u16)
  write16(BLE_EM_BASE + 0x138'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13A'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13C'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13E'u32, 0'u16)
  write16(BLE_EM_BASE + 0x140'u32, 0'u16)
  copyBytes(BLE_EM_BASE + 0x110'u32, cast[ptr uint8](addr nim_adv_params[7]), 6)
  write16(BLE_EM_BASE + 0x116'u32, nim_adv_params[5].uint16)
  write16(BLE_EM_BASE + 0x0FA'u32, 0xC027'u16)
  write16(BLE_EM_BASE + 0x0F6'u32, 0x0055'u16)
  write16(BLE_EM_BASE + 0x0FE'u32, 0'u16)
  write16(BLE_EM_BASE + 0x0FC'u32, ble_tx_pwr.uint16)
  write16(BLE_EM_BASE + 0x0EE'u32, read16(BLE_EM_BASE + 0x0EE'u32) or 0x2000'u16)
  write16(BLE_EM_BASE + 0x0EC'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10C'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10E'u32, 0'u16)
  write16(BLE_EM_BASE + 0x104'u32, 8'u16)

  nim_adv_debug_stage = 0x7060'u32
  ensureBleRf1MConfigured()
  nim_adv_debug_stage = 0x7070'u32
  regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
  regWrite((BLE_BASE + 0x828'u32).uint, 0x0000011E'u32)
  nim_adv_debug_stage = 0x7080'u32
  nim_adv_enabled = true
  writeBtbleInterruptMask(BtbleIntAdvertising)
  nim_adv_debug_stage = 0x7090'u32
  nim_adv_debug_detail = regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
  nim_adv_debug_stage = 0x70A0'u32
  scheduleBtbleEvent()
  nim_adv_debug_stage = 0x70B0'u32
  0

proc handleNimHciCommand(opcode: uint16, params: ptr uint8,
                         paramLen: uint8): uint8 =
  nim_hci_debug_stage = 0x4500'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  case opcode
  of HciOpReset:
    rwip_reset()
    0
  of HciOpDisconnect:
    if paramLen != 3 or params == nil:
      return 0x12'u8
    let req = hciDisconnectReq(params)
    let handle = req.handle
    if not nim_conn_active or handle != nim_conn_handle:
      return 0x02'u8
    sendDisconnectComplete(handle, req.reason)
    0
  of HciOpLeSetRandomAddress:
    if paramLen != 6 or params == nil:
      return 0x12'u8
    let req = hciLeSetRandomAddressReq(params)
    for i in 0 ..< nim_local_addr.len:
      nim_local_addr[i] = req.address.data[i]
    nim_local_addr_valid = true
    0
  of HciOpLeSetAdvParams:
    if paramLen != 15 or params == nil:
      return 0x12'u8
    let req = hciLeSetAdvParamsReq(params)
    for i in 0 ..< 15:
      nim_adv_params[i] = req.bytes[i]
    0
  of HciOpLeSetAdvData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    let req = hciLeDataPayloadReq(params)
    if req.length > 31'u8:
      return 0x12'u8
    let n = min(req.length.int, nim_adv_data.len)
    nim_adv_data_len = n.uint8
    for i in 0 ..< n:
      nim_adv_data[i] = req.data[i]
    0
  of HciOpLeSetScanRspData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    let req = hciLeDataPayloadReq(params)
    if req.length > 31'u8:
      return 0x12'u8
    let n = min(req.length.int, nim_scan_rsp_data.len)
    nim_scan_rsp_data_len = n.uint8
    for i in 0 ..< n:
      nim_scan_rsp_data[i] = req.data[i]
    if nim_adv_enabled:
      programBtbleLegacyAdv(nim_adv_data_len)
    0
  of HciOpLeSetAdvEnable:
    if paramLen != 1 or params == nil:
      return 0x12'u8
    programNimAdvertising(hciLeSetAdvEnableReq(params).enabled != 0)
  of HciOpLeSetScanParams:
    nim_hci_debug_stage = 0x4510'u32
    if paramLen != 7 or params == nil:
      return 0x12'u8
    let req = hciLeSetScanParamsReq(params)
    when defined(bl808m0) and bl808BleNimPureCentral:
      if req.scanType > 1'u8:
        return HciStatusInvalidParams
    nim_scan_params[0] = req.scanType
    nim_scan_params[1] = uint8(req.interval and 0xFF'u16)
    nim_scan_params[2] = uint8(req.interval shr 8)
    nim_scan_params[3] = uint8(req.window and 0xFF'u16)
    nim_scan_params[4] = uint8(req.window shr 8)
    nim_scan_params[5] = req.ownAddrType
    nim_scan_params[6] = req.filterPolicy
    nim_hci_debug_stage = 0x4511'u32
    0
  of HciOpLeSetScanEnable:
    nim_hci_debug_stage = 0x4520'u32
    if paramLen != 2 or params == nil:
      return 0x12'u8
    let req = hciLeSetScanEnableReq(params)
    nim_scan_enabled = req.enabled != 0
    when defined(bl808m0) and bl808BleNimPureCentral:
      bleCentralDebugMark(0x800'u32, req.enabled.uint32)
      nim_hci_debug_stage = 0x4521'u32
      programNimScanning(nim_scan_enabled)
    else:
      0
  of HciOpLeCreateConnection:
    nim_hci_debug_stage = 0x4530'u32
    if paramLen != 25 or params == nil:
      return 0x12'u8
    nim_scan_enabled = false
    when defined(bl808m0) and bl808BleNimPureCentral:
      let initStatus = programNimInitiator(params, paramLen)
      if initStatus != 0'u8:
        return initStatus
    elif bl808BleNimSyntheticCentral or bl808BleNimSyntheticCentralComplete:
      sendLeConnectionComplete(params, paramLen)
    else:
      return 0x11'u8
    0
  of HciOpLeCreateConnectionCancel:
    if paramLen != 0:
      return 0x12'u8
    when defined(bl808m0) and bl808BleNimPureCentral:
      cancelNimInitiator()
    else:
      0x0C'u8
  else:
    0x01'u8

# Platform RTOS wrappers. The HAL validation build has no FreeRTOS layer, so
# provide a bounded single-queue shim that is enough for controller smoke tests.
type BleQueue = object
  length: uint32
  itemSize: uint32
  head: uint32
  tail: uint32
  count: uint32
  storage: array[20 * 8, uint8]

var bleMainQueue: BleQueue

proc ble_xQueueCreate(length: uint32, item_size: uint32): pointer {.exportc, cdecl.} =
  if length == 0 or item_size == 0 or length * item_size > bleMainQueue.storage.len.uint32:
    return nil
  bleMainQueue.length = length
  bleMainQueue.itemSize = item_size
  bleMainQueue.head = 0
  bleMainQueue.tail = 0
  bleMainQueue.count = 0
  cast[pointer](addr bleMainQueue)

proc ble_xQueueSend(q: pointer, item: pointer, timeout: uint32): uint32 {.exportc, cdecl.} =
  discard timeout
  if q == nil or item == nil:
    return 0
  let queue = cast[ptr BleQueue](q)
  if queue.count >= queue.length:
    return 0
  let off = queue.tail * queue.itemSize
  discard c_memcpy(addr queue.storage[off], item, queue.itemSize.csize_t)
  queue.tail = (queue.tail + 1) mod queue.length
  inc queue.count
  1

proc ble_xQueueReceive(q: pointer, item: pointer, timeout: uint32): uint32 {.exportc, cdecl.} =
  discard timeout
  if q == nil or item == nil:
    return 0
  let queue = cast[ptr BleQueue](q)
  if queue.count == 0:
    return 0
  let off = queue.head * queue.itemSize
  discard c_memcpy(item, addr queue.storage[off], queue.itemSize.csize_t)
  queue.head = (queue.head + 1) mod queue.length
  dec queue.count
  1

proc bleQueuePending(q: pointer): bool {.inline.} =
  q != nil and cast[ptr BleQueue](q).count != 0

proc ble_vTaskDelete(t: pointer) {.exportc, cdecl.} =
  discard t

proc ble_uxTaskPriorityGet(t: pointer): uint32 {.exportc, cdecl.} =
  discard t
  0

proc ble_xQueueSendFromISR(q: pointer, item: pointer, woken: ptr uint32): uint32 {.exportc, cdecl.} =
  if woken != nil:
    woken[] = 0
  ble_xQueueSend(q, item, 0)

proc ble_portYIELD_FROM_ISR() {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
