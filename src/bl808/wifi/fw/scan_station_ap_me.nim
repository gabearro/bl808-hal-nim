# ###########################################################################
#                      SCAN (Lower MAC)
# ###########################################################################

const
  WifiAuthForceFreq {.intdefine.} = 0

proc scan_init*() {.exportc, cdecl.} =
  ## Initialize scan module (blob: ~50 instrs). From disassembly:
  ##   memset(scan_env, 0, 24)
  ##   scan_env[12] = scan_env[16] = scan_env[20] = 0x35B60  (220000 us)
  ##   ke_state_set(TASK_SCAN=1, 0)
  ##   scan_probe_req_ie[16] = 0xCAFEFADE  (magic marker at +0x10)
  ##   scan_probe_req_ie[20] = 0            (probe IE state word at +0x14)
  ##   scan_probe_req_ie[24] = &scan_probe_req_ie[36]  (IE buffer self-ptr at +0x18)
  ##   scan_probe_req_ie[32] = 0            (at +0x20)
  let saved = irqSave()
  var oldDwell = scanDwellBeginReset()
  defer: scanDwellFinishReset(oldDwell)
  inc scanRequestEpoch
  discard c_memset(addr scan_env, 0, sizeof(scan_env).csize_t)
  scan_env.activeDuration = 0x35B60'u32
  scan_env.passiveDuration = 0x35B60'u32
  scan_env.joinActiveDuration = 0x35B60'u32
  scan_probe_req_ie.magic = 0xCAFEFADE'u32
  scan_probe_req_ie.probeIeStateWord = 0
  scan_probe_req_ie.ieDataPtr = addr scan_probe_req_ie.ieData[0]
  scan_probe_req_ie.writeOffset = 0
  # Rescheduling saved SCAN messages can expose the idle state immediately.
  ke_state_set(TASK_SCAN, ScanIdleState)
  irqRestore(saved)
  nimFwTrace("[WIFI-NIMFW] scan_init complete")

proc scan_get_scan_duration*(): uint32 {.exportc, cdecl, noinline.} =
  ## Return the request duration, or the vendor default when it is zero.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let scanReq = activeScanReq()
  if scanReq != nil:
    let custom = scanReq.addIeLen
    if custom != 0:
      return custom
  return 0x35B60'u32

proc scanChannelValid*(band: uint8; frequency: uint16): bool {.inline.} =
  case band
  of 0'u8:
    frequency == 2484'u16 or
      (frequency >= 2412'u16 and frequency <= 2472'u16 and
       (frequency - 2412'u16) mod 5'u16 == 0'u16)
  of 1'u8:
    frequency >= 5005'u16 and frequency <= 5825'u16 and
      (frequency - 5000'u16) mod 5'u16 == 0'u16
  else:
    false

proc scan_set_channel_request*() {.exportc, cdecl.} =
  ## Set channel for scanning. Builds channel config from scan_env param
  ## pointer and channel index, computes TX power index, sends indication.
  ## From disassembly (84 instrs).
  let scanParamPtr = scan_env.paramPtr
  if scanParamPtr == nil:
    return
  let scanReq = scanStartReqView(scanParamPtr)
  let scanIdx = scan_env.channelIndex
  if scanIdx >= scanReq.channelCount or
      scanIdx.int >= scanReq.channelList.len:
    return
  let scanChan = addr scanReq.channelList[scanIdx.int]
  if not scanChannelValid(scanChan.band, scanChan.prim20Freq):
    return
  let requestEpoch = scanRequestEpoch
  var chanCfg = default(ChanScanReqPayload)
  chanCfg.vifIdx = scanReq.vifIdx
  var freqWord: uint32
  let directFreq = scanReq.sendProbe
  if directFreq == 0:
    if (scanChan.flags and 1) != 0:
      freqWord = scan_env.passiveDuration
    else:
      freqWord = scan_env.activeDuration
  else:
    freqWord = scan_env.joinActiveDuration
  chanCfg.duration = freqWord
  let chanBand = scanChan.band
  chanCfg.band = chanBand
  let prim20Freq = scanChan.prim20Freq
  chanCfg.prim20Freq = prim20Freq
  chanCfg.center1Freq = prim20Freq
  chanCfg.center2Freq = 0
  chanCfg.txPower = scanChan.txPower
  nimFwTrace2U32("[WIFI-NIMFW] scan_set start ", scanIdx.uint32, cast[uint32](scanParamPtr))
  if scanRequestEpoch != requestEpoch or scan_env.paramPtr != scanParamPtr or
      scan_env.channelIndex != scanIdx:
    return
  nimFwTrace2U32("[WIFI-NIMFW] scan_set chan ", chanBand.uint32, prim20Freq.uint32)
  if scanRequestEpoch != requestEpoch or scan_env.paramPtr != scanParamPtr or
      scan_env.channelIndex != scanIdx:
    return
  let chanCfgView = chanScanChannel(addr chanCfg)
  nimFwDbgScanReqChanMeta = packChannelMeta(chanCfgView)
  nimFwDbgScanReqChanFreq = packChannelFreq(chanCfgView)
  # Blob: call chan_scan_req to submit channel change to HW
  chan_scan_req(addr chanCfg)
  if scanRequestEpoch != requestEpoch or scan_env.paramPtr != scanParamPtr or
      scan_env.channelIndex != scanIdx:
    return
  let chanInfoPtr = scan_env.chanInfoPtr
  if chanInfoPtr != nil:
    var txPowerIdx: uint8 = 0
    let currentFreq = prim20Freq.uint32
    if chanBand == 0:
      if currentFreq >= 2412 and currentFreq <= 2484:
        if currentFreq == 2484: txPowerIdx = 14
        else: txPowerIdx = ((currentFreq - 2407) div 5).uint8
    elif chanBand == 1:
      if currentFreq >= 5005 and currentFreq <= 5825:
        txPowerIdx = ((currentFreq - 5000) div 5).uint8
    dsParamSetIeAt(chanInfoPtr).currentChannel = txPowerIdx
  # Transition scan task to the channel-request pending state.
  ke_state_set(TASK_SCAN, ScanChannelPendingState)

var scanEarlyEnd {.wifiCtrl.}: tuple[pending: bool; request: pointer;
                                    epoch: uint32; channel: uint8]

proc scanEarlyEndRequest() =
  ## Ask TASK_SCAN to end the current dwell. The vendor message has no payload,
  ## so the dwell it is meant for is recorded here; with no dwell there is
  ## nothing to end and nothing is sent.
  let saved = irqSave()
  defer: irqRestore(saved)
  if scan_env.paramPtr == nil: return
  scanEarlyEnd = (true, scan_env.paramPtr, scanRequestEpoch, scan_env.channelIndex)
  ke_msg_send_basic(MM_SCAN_CHANNEL_END_EARLY, TASK_SCAN, TASK_SCANU)

proc scanEarlyEndClaim(): bool =
  ## True once per request, and only while the dwell that asked is still current.
  let saved = irqSave()
  defer: irqRestore(saved)
  let asked = scanEarlyEnd
  scanEarlyEnd.pending = false
  asked.pending and asked.request != nil and asked.request == scan_env.paramPtr and
    asked.epoch == scanRequestEpoch and asked.channel == scan_env.channelIndex

proc scan_terminate_channel_request*() {.exportc, cdecl.} =
  ## Terminate the current channel scan request (15 instrs in blob).
  ## Builds a 20-byte abort parameter block on the stack with byte 0 = 1
  ## (abort request type), zeros for the rest, then calls chan_scan_req
  ## to cancel the scan.
  var abortParam = default(ChanScanAbortPayload)
  abortParam.reqType = 1
  chan_scan_req(addr abortParam)

proc scan_ie_download*(param: pointer) {.exportc, cdecl.} =
  ## Download IEs (Information Elements) for probe request (30 instrs in blob).
  ## From blob: loads scan param from scan_env[0], reads IE length (offset 304),
  ## calls mac_ie_find(scan_probe_req_ie+36, ieLen, 3), stores the result at
  ## scan_env+4, then calls scan_set_channel_request. The final end marker
  ## uses the stored IE data pointer at +24 and the argument's IE length.
  let scanParam = scan_env.paramPtr
  if scanParam == nil or param == nil:
    return
  let requestEpoch = scanRequestEpoch
  let channelIndex = scan_env.channelIndex
  let scanReq = scanStartReqView(scanParam)
  let ieLen = scanReq.ieBodyLen
  let argumentIeLen = scanStartReqView(param).ieBodyLen
  if ieLen.int > scan_probe_req_ie.ieData.len or
      argumentIeLen.int > scan_probe_req_ie.ieData.len:
    scan_env.chanInfoPtr = nil
    return
  # Search for DS Parameter Set IE (id=3) in the IE buffer
  let found = mac_ie_find(scanProbeReqIeDataPtr(scan_probe_req_ie),
                          ieLen.uint32, 3)
  scan_env.chanInfoPtr =
    if found != nil and cast[ptr MacIeView](found).len == 1: found else: nil
  # Set up the scan channel
  scan_set_channel_request()
  if scanRequestEpoch != requestEpoch or scan_env.paramPtr != scanParam or
      scan_env.channelIndex != channelIndex:
    return
  # Update IE tracking in scan_probe_req_ie: end_offset, write_offset
  scan_probe_req_ie.writeOffset = 0
  scan_probe_req_ie.endOffset =
    scanProbeReqIeDataBase(scan_probe_req_ie) - 1 +
    argumentIeLen.uint32

proc scan_probe_req_tx*(): uint8 {.exportc, cdecl.} =
  ## The vendor supports one SSID slot and initially returns 1, clearing it
  ## on a nonzero push result. Keep that status convention, not a success bool.
  let saved = irqSave()
  defer: irqRestore(saved)
  let scanParam = scan_env.paramPtr
  if scanParam == nil:
    return 1
  let scanReq = scanStartReqView(scanParam)
  let numSsids = scanReq.scanType
  if numSsids == 0:
    return 1
  if numSsids != 1 or scan_env.abortFlag != 0:
    return 0
  let vifIdx = scanReq.vifIdx
  let ieLen = scanReq.ieBodyLen.uint32
  let ssid = scanSsidSlot(scanReq, 0)[]
  if vifIdx >= MAX_VIFS.uint8 or ssid.length > 32 or
      ieLen > scan_probe_req_ie.ieData.len.uint32:
    return 0
  let totalLen = 26'u32 + ssid.length.uint32 + ieLen
  let requestEpoch = scanRequestEpoch
  let channelIndex = scan_env.channelIndex
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: 0xFF,
    vifEpoch: rxVifEpochs[vifIdx], stationEpoch: staDeleteEpoch(0xFF),
    resetEpoch: txResetEpoch)
  let bssid = scanReq.bssid
  let localMac = scanReq.localMac
  # A recovery callback can replace both the request and the shared IE buffer.
  let ieBytes = scan_probe_req_ie.ieData
  let frame = txl_frame_get(totalLen)
  if frame == nil:
    return 1
  let frameDesc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(frameDesc)
  frameDesc.vifIdx = vifIdx
  frameDesc.staInfoIdx = 0xFF
  template ensureProbeCurrent() =
    if not txlFramePreparationCurrent(frameDesc, identity, generation):
      return 0
    if scanRequestEpoch != requestEpoch or scan_env.paramPtr != scanParam or
        scan_env.channelIndex != channelIndex or scan_env.abortFlag != 0:
      txl_frame_release(frame, false)
      return 0
  ensureProbeCurrent()

  let linkDesc = hostTxLinkDescAt(frameDesc.bufDesc)
  let probeFrame = hostTxProbeReqFrame(linkDesc)
  let probeHdr = addr probeFrame.fixed
  probeHdr.frameControl = 0x0040
  probeHdr.duration = 0
  probeHdr.addr1 = bssid
  probeHdr.addr2 = localMac
  probeHdr.addr3 = bssid
  probeHdr.seqCtrl = nextTxSeqCtrl()
  probeHdr.ssidIeId = IE_ID_SSID
  probeHdr.ssidLen = ssid.length
  for i in 0 ..< ssid.length.int:
    probeFrame.ssidData[i] = ssid.ssidBytes[i]
  if ieLen != 0:
    discard c_memcpy(addr probeFrame.ssidData[ssid.length.int],
                     unsafeAddr ieBytes[0], ieLen.csize_t)
  # The allocator's contiguous payload now owns the IEs too. Do not chain the
  # shared scan buffer, which a later channel/request can rewrite during DMA.
  frameDesc.callback = nil
  frameDesc.callbackArg = nil
  nimFwDbgProbeIeLen = ieLen
  for i in 0 ..< nimFwDbgProbeIeRaw.len:
    nimFwDbgProbeIeRaw[i] = if i.uint32 < ieLen: ieBytes[i] else: 0
  ensureProbeCurrent()
  when defined(bl808WifiScanTrace):
    let addressWord = bssid[0].uint32 or (bssid[1].uint32 shl 8) or
      (bssid[2].uint32 shl 16) or (bssid[3].uint32 shl 24)
    nimFwTrace2U32("[WIFI-SCAN] probe_tx ", totalLen,
      ieLen or (ssid.length.uint32 shl 16) or (vifIdx.uint32 shl 24))
    ensureProbeCurrent()
    nimFwTrace2U32("[WIFI-SCAN] probe_fc ", 0x40, addressWord)
    ensureProbeCurrent()
  if txl_frame_push(frame, 3) != 0: 0'u8 else: 1'u8

proc scan_send_cancel_cfm*(status: uint8, destId: uint8)
    {.exportc, cdecl, noinline.} =
  ## Send scan cancel confirmation (15 instrs in blob).
  ## Allocates a SCAN_CANCEL_CFM message with 1-byte payload containing
  ## the status code, then sends it.
  ## SCAN_CANCEL_CFM = 0x404, dest=requester, src=TASK_SCAN(1).
  let cancelCfmPayload = cast[ptr StatusCfmPayload](
    ke_msg_alloc(SCAN_CANCEL_CFM, destId, TASK_SCAN,
                 StatusCfmPayloadSize))
  if cancelCfmPayload == nil:
    return
  cancelCfmPayload.status = status
  ke_msg_send(cancelCfmPayload)

proc scan_get_chan*(): pointer {.exportc, cdecl.} =
  ## Return the channel selected by scan_env.channelIndex.
  let chanListBase = scan_env.paramPtr
  if chanListBase == nil:
    return nil
  let scanReq = scanStartReqView(chanListBase)
  if scan_env.channelIndex >= scanReq.channelCount or
      scan_env.channelIndex.int >= scanReq.channelList.len:
    return nil
  return addr scanReq.channelList[scan_env.channelIndex.int]

# ###########################################################################
#                      SCANU (Upper MAC Scan)
# ###########################################################################

type ScanuLowerExchange = object
  request, startCfm, done: pointer
  epoch: uint32

# One lower scan phase at a time. Queue envelopes are identities, not borrowed
# payloads; the upper generation invalidates the whole exchange on retirement.
var scanuLower {.wifiCtrl.}: ScanuLowerExchange

proc scanuLowerCurrent(request: pointer): bool {.inline.} =
  request != nil and scanuLower.request == request and
    scanu_env.paramPtr != nil and scanuLower.epoch == scanuRequestEpoch

proc scanuTrackLowerReply(request, reply: pointer; done: bool) {.inline.} =
  if scanuLowerCurrent(request):
    if done: scanuLower.done = reply
    else: scanuLower.startCfm = reply

proc scanuClaimLowerReply(reply: pointer; done: bool): bool {.inline.} =
  # Called under the same IRQ lock as consumption of the claimed reply.
  if reply == nil or not scanuLowerCurrent(scanuLower.request): return false
  if done:
    if scanuLower.done != reply: return false
    scanuLower = default(ScanuLowerExchange)
  else:
    if scanuLower.startCfm != reply: return false
    scanuLower.startCfm = nil
  true

proc scanuRequestCurrent(param: pointer; epoch: uint32): bool {.inline.} =
  param != nil and scanu_env.paramPtr == param and scanuRequestEpoch == epoch

proc scanu_init*() {.exportc, cdecl.} =
  ## Initialize upper MAC scan module.
  let saved = irqSave()
  defer: irqRestore(saved)
  inc scanuRequestEpoch
  ke_state_set(TASK_SCANU, ScanuIdleState)
  discard c_memset(cast[pointer](addr scanu_env), 0, sizeof(ScanuEnvObj).csize_t)
  scanu_env.probeIeCopyDst = addr scanuAddIeView().ieData[0]
  scanuJoinHandler = cast[pointer](scanu_frame_handler)
  scanuResultCount = 0
  for scanResultPointerIndex in 0 ..< MAX_SCAN_RESULTS:
    scanuResults[scanResultPointerIndex] = nil

proc scanuReleaseCompletedOwner(epoch: uint32) =
  let saved = irqSave()
  defer: irqRestore(saved)
  # Setting IDLE drains saved requests. The confirmation must reach the
  # queue first, and a reentrant replacement must keep its own state.
  if scanuRequestEpoch == epoch and scanu_env.paramPtr == nil:
    ke_state_set(TASK_SCANU, ScanuIdleState)

proc scanuAnswer(request: pointer; id: uint16; destination, status: uint8) =
  ## Answer `request` in place: it becomes its own confirmation. This needs
  ## no allocation, so it cannot fail.
  statusCfmView(request).status = status
  keMsgHdrFromPayload(request).paramLen = StatusCfmPayloadSize
  ke_msg_forward_and_change_id(request, id, destination, TASK_SCANU)

proc scanuReply(id: uint16; destination: uint8): pointer =
  ## A separate confirmation, as the blob allocates one. SM's requests, and
  ## any whose allocation fails, are answered in place instead (nil).
  if destination == TASK_SM: nil
  else: ke_msg_try_alloc(id, destination, TASK_SCANU, StatusCfmPayloadSize)

proc scanuPublishCompletion(request, reply: pointer; id: uint16;
                            destination, status: uint8) =
  if reply == nil:
    scanuAnswer(request, id, destination, status)
  else:
    statusCfmView(reply).status = status
    ke_msg_free(keMsgHdrFromPayload(request))
    ke_msg_send(reply)

proc scanu_confirm*(status: uint8) {.exportc, cdecl.} =
  ## Send scan completion confirmation to host (58 instrs).
  ## Blob flow: allocates SCANU_JOIN_CFM twice in join mode (to requester and
  ## TASK_API), or SCANU_START_CFM in normal scan mode. SCANU_RESULT_IND is not
  ## a status message; it carries real beacon/probe-response frames.
  # Detach the old request before callouts, but keep the task busy until
  # this completion is published ahead of any saved scan request.
  let completion = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let oldRequest = scanu_env.paramPtr
    if oldRequest == nil: return
    # SM's answer has the type of its request; SM does not read the filter.
    let joining = if scanu_env.requester == TASK_SM:
        uint8(keMsgHdrFromPayload(oldRequest).id == SCANU_JOIN_REQ)
      else: scanu_env.bssidFilterEnabled
    inc scanuRequestEpoch
    scanu_env.paramPtr = nil
    scanu_env.pendingJoinRxuMgtInd = nil
    (request: oldRequest, join: joining,
     source: scanu_env.requester, epoch: scanuRequestEpoch)
  defer: scanuReleaseCompletedOwner(completion.epoch)
  let primaryId = if completion.join != 0: SCANU_JOIN_CFM else: SCANU_START_CFM
  let primaryCfm = scanuReply(primaryId, completion.source)
  var apiJoinCfm: pointer = nil
  if completion.join != 0:
    apiJoinCfm = ke_msg_try_alloc(SCANU_JOIN_CFM, TASK_API, TASK_SCANU,
                                  StatusCfmPayloadSize)
  if apiJoinCfm != nil:
    statusCfmView(apiJoinCfm).status = status
  scanuPublishCompletion(completion.request, primaryCfm, primaryId,
                         completion.source, status)
  if apiJoinCfm != nil:
    ke_msg_send(apiJoinCfm)

type ProbeIeWriter = object
  len*: uint16
  failed: bool
  bytes: array[200, uint8]

proc reserveProbeIeBytes(w: var ProbeIeWriter; count: uint32): bool {.inline.} =
  if w.failed:
    return false
  if w.len.uint32 > w.bytes.len.uint32 or
      count > w.bytes.len.uint32 - w.len.uint32:
    w.failed = true
    return false
  true

proc cursor*(w: var ProbeIeWriter): pointer {.inline.} =
  if w.failed or w.len.int >= w.bytes.len: nil
  else: addr w.bytes[w.len.int]

proc appendByte*(w: var ProbeIeWriter, value: uint8) {.inline.} =
  if w.reserveProbeIeBytes(1):
    w.bytes[w.len.int] = value
    inc w.len

proc appendIeHeader*(w: var ProbeIeWriter, id, len: uint8) {.inline.} =
  if w.reserveProbeIeBytes(2):
    w.bytes[w.len.int] = id
    w.bytes[w.len.int + 1] = len
    w.len += 2

proc skip*(w: var ProbeIeWriter, count: uint16) {.inline.} =
  if w.reserveProbeIeBytes(count.uint32):
    for i in 0 ..< count.int:
      w.bytes[w.len.int + i] = 0
    w.len += count

proc appendDsParamPlaceholder*(w: var ProbeIeWriter) {.inline.} =
  w.appendIeHeader(IE_ID_DS_PARAM, IE_LEN_DS_PARAM)
  w.skip(IE_LEN_DS_PARAM.uint16)

proc appendBytes*(w: var ProbeIeWriter, src: pointer, count: uint32) {.inline.} =
  if count == 0:
    return
  if src == nil:
    w.failed = true
  elif w.reserveProbeIeBytes(count):
    co_pack8p(w.cursor, src, count)
    w.len += count.uint16

proc probeIesValid(data: pointer; length: uint32): bool =
  if length == 0:
    return true
  if data == nil or length > 200:
    return false
  var offset = 0'u32
  while offset < length:
    let remaining = length - offset
    if remaining < 2:
      return false
    let ie = macIeAt(cast[uint](data) + offset.uint)
    let size = ie.totalLen.uint32
    if size > remaining:
      return false
    if ie.id == IE_ID_DS_PARAM and ie.len != IE_LEN_DS_PARAM:
      return false
    offset += size
  true

proc appendHtCapabilities*(w: var ProbeIeWriter, me: ptr MeEnvView) {.inline.} =
  w.appendIeHeader(IE_ID_HT_CAP, IE_LEN_HT_CAP)
  w.appendBytes(meHtCapsPtr(me), IE_LEN_HT_CAP.uint32)

proc macId2RatePtr(offset: uint): pointer {.inline.} =
  addr mac_id2rate[offset.int]

proc appendSupportedRates*(w: var ProbeIeWriter, rateStart: uint) {.inline.} =
  w.appendIeHeader(IE_ID_SUPPORTED_RATES, PROBE_REQ_SUPPORTED_RATE_COUNT)
  w.appendBytes(macId2RatePtr(rateStart), PROBE_REQ_SUPPORTED_RATE_COUNT.uint32)

proc finishScanStartReq*(msg: ptr ScanStartReqPayload, ies: var ProbeIeWriter): bool {.inline.} =
  if ies.failed or not probeIesValid(addr ies.bytes[0], ies.len.uint32):
    return false
  if ies.len != 0:
    discard c_memcpy(scanProbeReqIeDataPtr(scan_probe_req_ie),
                     addr ies.bytes[0], ies.len.csize_t)
  msg.ieBodyLen = ies.len
  msg.scanResult = 0
  true

proc sendScanStartReq*(msg: ptr ScanStartReqPayload, ies: var ProbeIeWriter) {.inline.} =
  let owner = scanu_env.paramPtr
  let epoch = scanuRequestEpoch
  if not msg.finishScanStartReq(ies):
    ke_msg_free(keMsgHdrFromPayload(msg))
    if scanuRequestCurrent(owner, epoch):
      scanu_confirm(SCAN_STATUS_BAD_PARAM)
    return
  if not scanuRequestCurrent(owner, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg))
    return
  scanuLower = ScanuLowerExchange(request: msg, epoch: epoch)
  ke_msg_send(msg)

proc initScanStartReq*(
    msg: ptr ScanStartReqPayload,
    req: ptr ScanuStartReqPayload,
    sendProbe: uint8
  ) {.inline.} =
  msg.vifIdx = req.vifIdx
  msg.bssid = req.bssid
  msg.localMac = req.localMac
  msg.scanType = req.scanType
  msg.passive = req.passive
  msg.sendProbe = sendProbe
  msg.addIeLen = req.addIeLen

proc appendScanBandChannel*(
    msg: ptr ScanStartReqPayload,
    channel: ScanChannelEntry,
    count: var uint8
  ) {.inline.} =
  msg.channelList[count.int] = channel
  count += 1
  msg.channelCount = count

proc copyScanBandChannels*(
    msg: ptr ScanStartReqPayload,
    req: ptr ScanuStartReqPayload,
    firstIdx: uint8,
    scanBand: uint8
  ) {.inline.} =
  var msgChanCount: uint8 = 0
  var scanChanIdx = firstIdx
  while scanChanIdx < req.channelCount:
    let srcBand = req.channelList[scanChanIdx.int].band
    if srcBand == scanBand:
      msg.appendScanBandChannel(req.channelList[scanChanIdx.int], msgChanCount)
    scanChanIdx += 1

proc firstScanBandChannel*(req: ptr ScanuStartReqPayload, scanBand: uint8): uint8 {.inline.} =
  var chanIdx: uint8 = 0
  while chanIdx < req.channelCount:
    let band = req.channelList[chanIdx.int].band
    if band == scanBand:
      break
    chanIdx += 1
  chanIdx

proc clampedProbeReqIeLen*(req: ptr ScanuStartReqPayload): uint16 {.inline.} =
  let len = req.probeReqIeLen
  if len <= 200'u16: len else: 0'u16

proc supportedRateStart*(scanBand, passiveFlag: uint8): uint {.inline.} =
  if scanBand == 1'u8 or passiveFlag != 0: 4'u else: 0'u

proc appendScanSupportedRates*(
    w: var ProbeIeWriter,
    scanBand, passiveFlag: uint8
  ) {.inline.} =
  w.appendSupportedRates(supportedRateStart(scanBand, passiveFlag))

proc appendScanHtCapabilities*(
    w: var ProbeIeWriter,
    me: ptr MeEnvView
  ) {.inline.} =
  if me.htSupp != 0:
    w.appendHtCapabilities(me)

proc allocScanStartReq*(): ptr ScanStartReqPayload {.inline.} =
  cast[ptr ScanStartReqPayload](
    ke_msg_try_alloc(SCAN_START_REQ, TASK_SCAN, TASK_SCANU, ScanStartReqPayloadSize))

proc allocInitializedScanStartReq*(
    req: ptr ScanuStartReqPayload,
    sendProbe: uint8
  ): ptr ScanStartReqPayload {.inline.} =
  let epoch = scanuRequestEpoch
  result = allocScanStartReq()
  if not scanuRequestCurrent(cast[pointer](req), epoch):
    if result != nil:
      ke_msg_free(keMsgHdrFromPayload(result))
    return nil
  if result != nil:
    result.initScanStartReq(req, sendProbe)

proc copyScanSsidFilterIfPresent*(
    msg: ptr ScanStartReqPayload,
    req: ptr ScanuStartReqPayload
  ) {.inline.} =
  if req.scanType != 0:
    msg.ssidFilter = req.ssidFilter

proc resetUndirectedScanuStart*() {.inline.} =
  let scanParam = scanu_env.paramPtr
  let epoch = scanuRequestEpoch
  scanu_cached_scanresult_clear()
  if not scanuRequestCurrent(scanParam, epoch):
    return
  scanuStartReqView(scanParam).cacheScanuFilterSsid()
  scanu_env.resultCount = 0

proc finishAdvancedScanuScanBand*(): bool {.inline.} =
  let scanParam = scanu_env.paramPtr
  let epoch = scanuRequestEpoch
  let sendProbeFlag = scanu_env.bssidFilterEnabled
  if sendProbeFlag != 0 and scanu_env.directedFound == 0:
    let retryCount = scanu_env.joinRetryCount
    if retryCount > 0:
      scanu_env.joinRetryCount = retryCount - 1
      let logFunc = getLogFunc(204)
      if logFunc != nil:
        cast[proc(level: uint32; tag, file: cstring; line: cint;
                  format: cstring) {.cdecl, varargs.}](logFunc)(
          2, nil, "scanu.c", 1163, "rescan:%s %d \r\n", "scanu_scan_next", 1163.cint)
      if not scanuRequestCurrent(scanParam, epoch):
        return false
      scanu_env.resultState = 1
      scanu_env.scanBand = 0
      return true
  scanu_confirm(0)
  false

proc scanu_start*() {.exportc, cdecl.} =
  ## Start a scan operation (37 instrs).
  ## From blob: loads scanu_env base (s0). Checks scanu_env.joinFlag (offset 180).
  ## If joinFlag != 0, jumps to shared path (ke_state_set + scan_next).
  ## If joinFlag == 0: scanu_cached_scanresult_clear, memcpy params, clear count,
  ## then shared path. Shared path: ke_state_set(2,1), check probe data,
  ## tail-call scanu_scan_next.
  let saved = irqSave()
  defer: irqRestore(saved)
  let scanParam = scanu_env.paramPtr
  let epoch = scanuRequestEpoch
  if not scanuRequestCurrent(scanParam, epoch):
    return
  if scanuProducerRequest == scanParam and scanuProducerEpoch == epoch:
    return
  let previousProducer = scanuProducerRequest
  let previousProducerEpoch = scanuProducerEpoch
  scanuProducerRequest = scanParam
  scanuProducerEpoch = epoch
  defer:
    scanuProducerRequest = previousProducer
    scanuProducerEpoch = previousProducerEpoch
  let joinFlag = scanu_env.bssidFilterEnabled
  if joinFlag == 0:
    resetUndirectedScanuStart()
    if not scanuRequestCurrent(scanParam, epoch):
      return
  ke_state_set(TASK_SCANU, ScanuScanningState)
  if not scanuRequestCurrent(scanParam, epoch):
    return
  # Blob 0x4c..0x74: if scanParam[300] != 0 (probe data ptr) AND
  # scanParam[304]..[305] (halfword probe length) <= 200, copy the probe
  # data into scanu_env[224] via memcpy, then tail-call scanu_scan_next.
  # Previous Nim omitted the probe-data copy entirely.
  if scanParam != nil:
    let scanReq = scanuStartReqView(scanParam)
    let probeSrc = scanReq.probeReqIe
    if probeSrc != nil:
      let probeLen = scanReq.probeReqIeLen
      if probeLen <= 200'u16:
        let probeDst = scanu_env.probeIeCopyDst
        if probeDst != nil:
          discard c_memcpy(probeDst, probeSrc, probeLen.csize_t)
  # Startup hands the same request to the guarded scan builder without a callout
  # between releasing its producer guard and entering the builder.
  scanuProducerRequest = previousProducer
  scanuProducerEpoch = previousProducerEpoch
  scanu_scan_next()

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_scan_next(void);".}
proc scanu_scan_next*() {.exportc, cdecl.} =
  ## Proceed to scan the next channel in the scan list.
  ## From blob (265 instrs): iterates scan_param channel list, builds
  ## SCAN_START_REQ with probe request IEs, sends to lower-MAC scan module.
  ## When all channels are done or abort is requested, sends SCANU_START_CFM.
  let saved = irqSave()
  defer: irqRestore(saved)
  let scanParam = scanu_env.paramPtr
  let epoch = scanuRequestEpoch
  if scanParam == nil:
    # scanu_confirm already performs ke_state_set(SCANU, 0) internally.
    # Blob does not duplicate the state clear here.
    scanu_confirm(0)
    return
  if scanuProducerRequest == scanParam and scanuProducerEpoch == epoch:
    return
  let previousProducer = scanuProducerRequest
  let previousProducerEpoch = scanuProducerEpoch
  scanuProducerRequest = scanParam
  scanuProducerEpoch = epoch
  defer:
    scanuProducerRequest = previousProducer
    scanuProducerEpoch = previousProducerEpoch
  let scanReq = activeScanuReq()
  let numChannels = scanReq.channelCount
  if numChannels.int > scanReq.channelList.len or
      scanReq.scanType > 1 or
      (scanReq.scanType != 0 and scanSsidSlot(scanReq, 0).length > 32) or
      scanReq.vifIdx >= MAX_VIFS.uint8:
    scanu_confirm(SCAN_STATUS_BAD_PARAM)
    return
  for channelIndex in 0 ..< numChannels.int:
    let channel = scanReq.channelList[channelIndex]
    if not scanChannelValid(channel.band, channel.prim20Freq):
      scanu_confirm(SCAN_STATUS_BAD_PARAM)
      return
  var scanBand: uint8
  var chanIdx: uint8
  while true:
    scanBand = scanu_env.scanBand
    if scanBand != 0:
      if finishAdvancedScanuScanBand() and
          scanuRequestCurrent(scanParam, epoch):
        continue
      return
    # The vendor scans band 0 first and restarts that phase on a join retry.
    chanIdx = scanReq.firstScanBandChannel(scanBand)
    if chanIdx < numChannels:
      break
    scanu_env.scanBand = 1
  # Allocate SCAN_START_REQ (paramLen=316)
  let msg = allocInitializedScanStartReq(scanReq, scanu_env.bssidFilterEnabled)
  if not scanuRequestCurrent(scanParam, epoch):
    return
  if msg == nil:
    scanu_confirm(SCAN_STATUS_FAIL)
    return

  # Iterate through channels, copying entries for the current band phase to
  # msg[0..]. The blob's indexed memcpy destination is msg + count*6.
  msg.copyScanBandChannels(scanReq, chanIdx, scanBand)

  msg.copyScanSsidFilterIfPresent(scanReq)

  # Get total IE len from scanParam; clamp to 200
  var totalIeLen = scanReq.clampedProbeReqIeLen()

  # Determine passive vs active scan mode
  let passiveFlag = scanReq.passive

  # Assemble locally; malformed input and overflow must not partially rewrite
  # the shared buffer consumed by the lower scan task.
  var ies: ProbeIeWriter
  let hostIeData = cast[pointer](scanuAddIeDataAddr())
  let extraIePtr = scanu_env.extraIePtr
  let extraIeLen = scanu_env.extraIeLen
  if (totalIeLen != 0 and scanReq.probeReqIe == nil) or
      not probeIesValid(hostIeData, totalIeLen.uint32) or
      (extraIePtr != nil and not probeIesValid(extraIePtr, extraIeLen.uint32)):
    ies.failed = true
    msg.sendScanStartReq(ies)
    return

  ies.appendScanSupportedRates(scanBand, passiveFlag)

  # Preserve the vendor ordering of Request IE (10) and Operating Classes (59).
  var scanuIePtr = scanuAddIeDataAddr()
  if totalIeLen > 0:
    let firstIe = macIeAt(scanuIePtr)
    if firstIe.id == 10:
      let copyLen = firstIe.totalLen
      ies.appendBytes(cast[pointer](scanuIePtr), copyLen.uint32)
      totalIeLen -= copyLen.uint16
      scanuIePtr += copyLen

  if scanBand == 0'u8 and passiveFlag == 0:
    ies.appendByte(50'u8)
    ies.appendByte(4'u8)
    ies.appendBytes(macId2RatePtr(8), 4)

  # Add DS Parameter Set IE if not passive
  # Blob: li a5,3; sb a5,0(s0); li a5,1; sb a5,1(s0); addi s0,s0,3
  if scanBand == 0'u8:
    ies.appendDsParamPlaceholder()

  if totalIeLen > 0 and macIeAt(scanuIePtr).id == 59'u8:
    let htOperLen = macIeAt(scanuIePtr).totalLen
    ies.appendBytes(cast[pointer](scanuIePtr), htOperLen.uint32)
    totalIeLen -= htOperLen.uint16
    scanuIePtr += htOperLen

  # Add HT Capabilities IE if not aborting
  # Blob: li a5,45; sb a5,0(s0); li a5,26; sb a5,1(s0); memcpy 26 bytes
  let me = meEnvView()
  ies.appendScanHtCapabilities(me)

  # Copy remaining extra IEs from scanParam
  if totalIeLen > 0:
    ies.appendBytes(cast[pointer](scanuIePtr), totalIeLen.uint32)

  # Copy extra IEs from host (at scanu_env+232/236).
  if extraIePtr != nil:
    if extraIeLen > 0:
      ies.appendBytes(extraIePtr, extraIeLen.uint32)

  msg.sendScanStartReq(ies)

proc scanuResetCachedSsid(cached: ptr ScanuCachedSsid) {.inline.} =
  let nextGeneration = cached.generation + 1'u32
  cached[] = ScanuCachedSsid(generation: nextGeneration)

proc scanu_find_result*(bssid: pointer, allocIfMissing: uint8 = 0): pointer {.exportc, cdecl.} =
  ## Find scan result by BSSID (112b in blob). Unrolled 6-byte MAC compare.
  ## Scan existing entries before reserving a free slot so one BSSID does not
  ## acquire two entries when the first free slot precedes its existing entry.
  if bssid == nil:
    return nil
  let saved = irqSave()
  defer: irqRestore(saved)
  let ba = macAddrAt(bssid)
  var firstFree: ptr ScanuResultEntry
  var firstFreeIndex = -1
  for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]
    if scanResultEntry.valid == 0:
      if firstFree == nil:
        firstFree = scanResultEntry
        firstFreeIndex = scanResultSlotIndex
    else:
      # Unrolled 6-byte BSSID comparison (matches blob's lbu+bne pattern)
      if scanResultEntry.bssid[0] == ba.bytes[0] and
         scanResultEntry.bssid[1] == ba.bytes[1] and
         scanResultEntry.bssid[2] == ba.bytes[2] and
         scanResultEntry.bssid[3] == ba.bytes[3] and
         scanResultEntry.bssid[4] == ba.bytes[4] and
         scanResultEntry.bssid[5] == ba.bytes[5]:
        return scanResultEntry
  if allocIfMissing != 0 and firstFree != nil:
    discard c_memset(firstFree, 0, sizeof(ScanuResultEntry).csize_t)
    scanuResetCachedSsid(addr scanuCachedSsids[firstFreeIndex])
    discard c_memset(addr scanuCachedChannels[firstFreeIndex], 0,
                     sizeof(ScanChannelEntry).csize_t)
    firstFree.rssi = -128'i8
    return firstFree
  return nil

proc scanuCachedSsidFor(scanResultEntry: ptr ScanuResultEntry):
    ptr ScanuCachedSsid {.inline.} =
  for ssidCacheSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if (addr scanu_env.entries[ssidCacheSlotIndex]) == scanResultEntry:
      return addr scanuCachedSsids[ssidCacheSlotIndex]
  return nil

proc scanuClearCachedSsid(scanResultEntry: ptr ScanuResultEntry) {.inline.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  let cached = scanuCachedSsidFor(scanResultEntry)
  if cached != nil:
    scanuResetCachedSsid(cached)

proc scanuCacheSsid(scanResultEntry: ptr ScanuResultEntry;
                    ssid: ptr ScanSsidSlotView) {.inline.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  let cached = scanuCachedSsidFor(scanResultEntry)
  if cached == nil:
    return
  scanuResetCachedSsid(cached)
  cached.valid = 1
  cached.length = ssid.length
  for ssidByteIndex in 0 ..< cached.length.int:
    cached.ssidBytes[ssidByteIndex] = ssid.ssidBytes[ssidByteIndex]

proc scanuCachedSsidMatches(scanResultEntry: ptr ScanuResultEntry;
                            searchData: pointer;
                            searchLen: uint8): bool {.inline.} =
  let cached = scanuCachedSsidFor(scanResultEntry)
  if cached == nil or cached.valid == 0:
    return false
  if cached.length != searchLen:
    return false
  if searchLen == 0:
    return true
  c_memcmp(searchData, addr cached.ssidBytes[0], searchLen.csize_t) == 0

proc scanuCachedSsidMeta(scanResultEntry: ptr ScanuResultEntry): uint32 {.inline.} =
  let cached = scanuCachedSsidFor(scanResultEntry)
  if cached == nil:
    return 0
  cached.valid.uint32 or (cached.length.uint32 shl 8) or
    (cached.ssidBytes[0].uint32 shl 16) or (cached.ssidBytes[1].uint32 shl 24)

proc scanuCachedChannelFor(scanResultEntry: ptr ScanuResultEntry):
    ptr ScanChannelEntry {.inline.} =
  for channelCacheSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if (addr scanu_env.entries[channelCacheSlotIndex]) == scanResultEntry:
      return addr scanuCachedChannels[channelCacheSlotIndex]
  return nil

proc scanuClearCachedChannel(scanResultEntry: ptr ScanuResultEntry) {.inline.} =
  let cached = scanuCachedChannelFor(scanResultEntry)
  if cached != nil:
    discard c_memset(cached, 0, sizeof(ScanChannelEntry).csize_t)

proc configuredScanChannelEntryForFreq(freq: uint16):
    ptr ScanChannelEntry {.inline.} =
  let channelConfig = scanuChannelConfig()
  if channelConfig.count.int > channelConfig.entries.len:
    return nil
  for channelConfigIndex in 0 ..< channelConfig.count.int:
    let channelConfigEntry = addr channelConfig.entries[channelConfigIndex]
    if channelConfigEntry.prim20Freq == freq:
      return channelConfigEntry
  nil

proc scanuCacheChannel(scanResultEntry: ptr ScanuResultEntry;
                       band: uint8;
                       freq: uint16): pointer {.inline.} =
  let cached = scanuCachedChannelFor(scanResultEntry)
  if cached == nil:
    return nil
  let configured = configuredScanChannelEntryForFreq(freq)
  if configured == nil or configured.band != band:
    discard c_memset(cached, 0, sizeof(ScanChannelEntry).csize_t)
    return nil
  cached[] = configured[]
  cast[pointer](cached)

proc scanuPublishVifChannel(vif: ptr VifChannelView; entry: ptr ScanuResultEntry): bool =
  if entry.chanPtr == nil: return false
  let cached = cast[ptr ScanChannelEntry](entry.chanPtr)
  let configured = configuredScanChannelEntryForFreq(cached.prim20Freq)
  if configured == nil or configured.band != cached.band: return false
  # The VIF outlives the scan result and its cached channel copy.
  vif.operChan = configured
  let freq = configured.prim20Freq.uint32
  vif.channelFreqPair = freq or (freq shl 16)
  true

proc configuredChannelPtrForFreq(freq: uint16): pointer {.inline.} =
  let channelConfig = meChannelConfigView()
  if channelConfig.count.int > channelConfig.entries.len:
    return nil
  for channelConfigIndex in 0 ..< channelConfig.count.int:
    let channelConfigEntry = addr channelConfig.entries[channelConfigIndex]
    if channelConfigEntry.freq == freq:
      return cast[pointer](channelConfigEntry)
  nil

proc rxuMgtChannelPtr(rx: ptr RxuMgtIndView; freq: uint16): pointer {.inline.} =
  if rx.band == 0:
    result = me_freq_to_chan_ptr(rx.band, freq)
  if result == nil:
    result = configuredChannelPtrForFreq(freq)
  if result != nil and cast[ptr MeChannelConfigEntry](result).band != rx.band:
    result = nil

proc scanResultChannelPtr(scanResultEntry: ptr ScanuResultEntry): pointer =
  if scanResultEntry == nil:
    return nil
  result = scanResultEntry.chanPtr
  nimFwDbgBssChanFixMeta =
    cast[uint32](cast[uint](scanResultEntry)) xor
    (cast[uint32](cast[uint](result)) shl 1)
  nimFwDbgBssChanFixRaw = cast[uint32](cast[uint](scanResultEntry.cachedRxuMgtInd))
  if result == nil and scanResultEntry.cachedRxuMgtInd != nil:
    let rx = rxuMgtIndAt(scanResultEntry.cachedRxuMgtInd)
    if rx.frameLen < 36'u16:
      return nil
    var selectedFreq = rx.freq
    let dsIe = mac_ie_find(rxuMgtIndIeStart(scanResultEntry.cachedRxuMgtInd),
                           rx.frameLen.uint32 - 36'u32, IE_ID_DS_PARAM)
    if dsIe != nil:
      let ds = dsParamSetIeAt(dsIe)
      if ds.ie.len != IE_LEN_DS_PARAM:
        return nil
      selectedFreq = dsParamFreq(rx.band, ds)
      if selectedFreq == 0xFFFF'u16:
        return nil
    result = rxuMgtChannelPtr(rx, selectedFreq)
    scanResultEntry.chanPtr = result
    nimFwDbgBssChanFixMeta =
      selectedFreq.uint32 or (rx.band.uint32 shl 16) or
      (scanResultEntry.rssi.uint8.uint32 shl 24)
  nimFwDbgBssChanFixPtr = cast[uint32](cast[uint](result))

template selectedMgmtTxPower(): uint32 =
  when declared(NimFwForcedMgmtTxPower):
    NimFwForcedMgmtTxPower
  else:
    0x00000070'u32

proc macPtrIsSpecific(mac: pointer): bool {.inline.} =
  if mac == nil:
    return false
  let bytes = cast[ptr UncheckedArray[uint8]](mac)
  if (bytes[0] and 1'u8) != 0:
    return false
  var allZero = true
  var allFf = true
  for macByteIndex in 0 ..< 6:
    let macByte = bytes[macByteIndex]
    if macByte != 0'u8:
      allZero = false
    if macByte != 0xFF'u8:
      allFf = false
  not allZero and not allFf

proc macPtrEquals(a, b: pointer): bool {.inline.} =
  if a == nil or b == nil:
    return false
  let aa = cast[ptr UncheckedArray[uint8]](a)
  let bb = cast[ptr UncheckedArray[uint8]](b)
  for macByteIndex in 0 ..< 6:
    if aa[macByteIndex] != bb[macByteIndex]:
      return false
  true

const DefaultStaMacAddr = [0x02'u8, 0xB8'u8, 0x08'u8, 0x00'u8, 0x00'u8, 0x01'u8]

proc ensureVifMgmtMac(vif: ptr VifChannelView): pointer {.inline.} =
  if vif != nil:
    var allZero = true
    for macByteIndex in 0 ..< 6:
      if vif.macAddr[macByteIndex] != 0'u8:
        allZero = false
        break
    if allZero:
      discard c_memcpy(addr vif.macAddr[0], unsafeAddr DefaultStaMacAddr[0],
                       6.csize_t)
    when defined(bl808WifiAuthHwWorkaround):
      mm_hw_info_set(cast[pointer](addr vif.macAddr[0]))
    return cast[pointer](addr vif.macAddr[0])
  cast[pointer](unsafeAddr DefaultStaMacAddr[0])

proc vifMgmtTxSa(vif: ptr VifChannelView): pointer {.inline.} =
  if vif != nil:
    var allZero = true
    for macByteIndex in 0 ..< 6:
      if vif.macAddr[macByteIndex] != 0'u8:
        allZero = false
        break
    if not allZero:
      return cast[pointer](addr vif.macAddr[0])
  cast[pointer](unsafeAddr DefaultStaMacAddr[0])

proc applyConservativeMgmtTxRetryPolicy(link: ptr HostTxLinkDescView) {.inline.} =
  if link == nil:
    return
  let rate = hostTxRateTemplate(link)
  let txPower = selectedMgmtTxPower()
  when defined(bl808WifiMgmtOfdmFirst):
    rate.rateWord = 0x80001007'u32
  elif defined(bl808WifiMgmtLegacyFirst):
    rate.rateWord = 0x8000040A'u32
  elif not defined(bl808WifiKeepMgmtRcPrimary):
    rate.rateWord = 0x80000400'u32
  when defined(bl808WifiMgmtOfdmFirst):
    rate.retryRateControl0 = 0x80001007'u32
    rate.retryRateControl1 = 0x80000400'u32
    rate.retryRateControl2 = 0x8000040A'u32
  else:
    rate.retryRateControl0 = 0x80000400'u32
    rate.retryRateControl1 = 0x8000040A'u32
    rate.retryRateControl2 = 0x80001007'u32
  rate.txPower = txPower.int32
  rate.retryTxPowerControl0 = txPower
  rate.retryTxPowerControl1 = txPower
  rate.retryTxPowerControl2 = txPower
  link.ackPolicyControl = 0x00000200'u32
  link.retryLimitControl = 0x003F0000'u32

proc selectedBssRsnAkmInfo(scanResultEntry: ptr ScanuResultEntry): WifiRsnAkmInfo =
  if scanResultEntry == nil or scanResultEntry.cachedRxuMgtInd == nil:
    return
  let rx = rxuMgtIndAt(scanResultEntry.cachedRxuMgtInd)
  let totalLen = rx.frameLen
  let ieLen = if totalLen > 36'u16: totalLen.uint32 - 36'u32 else: 0'u32
  let ieStart = rxuMgtIndIeStart(scanResultEntry.cachedRxuMgtInd)
  wifiRsnAkmInfoFromIeBuffer(ieStart, ieLen)

proc configureSelectedBssAuth(scanResultEntry: ptr ScanuResultEntry;
                              ci: ptr ConnectInfoView) =
  if ci == nil:
    return
  let rsnInfo = selectedBssRsnAkmInfo(scanResultEntry)
  let authMask = rsnInfo.authMask
  let eligibleAuthMask =
    if rsnInfo.ccmpGroup and rsnInfo.ccmpPairwise and rsnInfo.bipCmac128: authMask
    else: authMask and not WifiAuthMaskSae
  var authFlags = ci.channelDuration
  when defined(bl808WifiForcePmfCapable):
    authFlags = authFlags or 0x200'u32
  let localPmfRequired = (authFlags and 0x400'u32) != 0
  var acceptedSaeForBss = false
  if ci.authType == 3'u8 and scanResultEntry != nil and
      ci.vifIdx < MAX_VIFS.uint8 and (eligibleAuthMask and WifiAuthMaskSae) != 0 and
      rsnInfo.pmfCapable:
    let vif = vifChannelForIdx(ci.vifIdx)
    if vif != nil and vif.vifType == VIF_TYPE_STA and
        vif.bssid == scanResultEntry.bssid:
      let security = vifSecurity(vif)
      acceptedSaeForBss = security.keyMgmt == WifiKeyMgmtSae and
        security.cipher == 4 and security.pmfCapable != 0 and
        security.pmfRequired != 0
  let localPmfCapable = (authFlags and 0x600'u32) != 0 or acceptedSaeForBss
  let candidate =
    if acceptedSaeForBss:
      WifiKeyMgmtSae
    else:
      wifiPreferredKeyMgmtFromMask(eligibleAuthMask,
        localPmfCapable and rsnInfo.pmfCapable, localPmfRequired)
  let pmfCompatible =
    (candidate != WifiKeyMgmtSae or (localPmfCapable and rsnInfo.pmfCapable)) and
    (not rsnInfo.pmfRequired or (localPmfCapable and rsnInfo.pmfCapable)) and
    (not localPmfRequired or rsnInfo.pmfCapable) and
    (not (localPmfCapable and rsnInfo.pmfCapable) or rsnInfo.bipCmac128)
  let keyMgmt = if pmfCompatible: candidate else: WifiKeyMgmtNone
  if authMask != 0:
    nimFwDbgScanKeyMgmt = authMask
    nimFwDbgScanAT = keyMgmt
  when defined(bl808WifiForceSaeAuth):
    ci.authType = 3
    nimFwDbgScanAT = 1024'u32
    return
  ci.authType = wifiDot11AuthTypeFromKeyMgmt(keyMgmt)

proc readLegacyRateIe(ie: ptr MacIeView; start: int;
                      rates: var array[12, uint8]): int =
  ## Append one bounded IE to the join rate set; -1 means it will not fit.
  result = start
  if ie == nil: return
  let bytes = ie.macIePayload
  for i in 0 ..< ie.len.int:
    let rate = bytes[i]
    # Basic-marked values 120..127 are BSS membership selectors, not rates.
    if rate >= 0xF8'u8: continue
    if result == rates.len: return -1
    rates[result] = rate
    inc result

type StaWmmParameters = object
  edca: array[4, uint32]
  qosInfo, admissionMask: uint8

proc isWmmParameterIe(ie: ptr MacIeView): bool =
  if ie == nil or ie.id != 221 or ie.len < WMM_OUI.len.uint8:
    return false
  let bytes = ie.macIePayload
  for i, octet in WMM_OUI:
    if bytes[i] != octet: return false
  true

proc decodeStaWmmParameters(ie: ptr MacIeView; params: var StaWmmParameters): bool =
  if not isWmmParameterIe(ie) or ie.len != 24: return false
  let wmm = wmmParameterIeAt(ie)
  if wmm.version != 1: return false
  var decoded = StaWmmParameters(qosInfo: wmm.qosInfo)
  var seen = 0'u8
  for record in wmm.ac:
    let word = record.le32
    let aifsn = word and 0xF
    let cwMin = (word shr 8) and 0xF
    let cwMax = (word shr 12) and 0xF
    if aifsn < 2 or cwMin > cwMax: return false
    let aci = ((word shr 5) and 3).uint8
    let queue = if aci == 0: API_AC_BE elif aci == 1: API_AC_BK else: aci
    let bit = 1'u8 shl queue
    if (seen and bit) != 0: return false
    seen = seen or bit
    decoded.edca[queue] = aifsn or ((word shr 8) shl 4)
    if (word and 0x10) != 0:
      decoded.admissionMask = decoded.admissionMask or bit
  params = decoded
  true

proc updateStaWmmFromBeacon(vif: ptr VifChannelView; sta: ptr StaInfoView;
                            frame: pointer; length, rxPrimaryFreq: uint16): bool =
  ## Caller holds the RX owner through the commit; True also permits retrying
  ## publication when a previous idle request could not be allocated.
  if frame == nil or length < sizeof(BeaconFrameFixedView).uint16 or
      vif.state == 0 or vif.vifType != VIF_TYPE_STA or vif.staIdx != sta.infoIdx or
      sta.instNbr != vif.vifIdx or sta.valid == 0 or vif.chanCtxt == nil or
      chanCtxtAt(vif.chanCtxt).channel.primFreq != rxPrimaryFreq:
    return false
  let config = vifApConfig(vif)
  if (config.securityFlags and 1) == 0: return false
  let beacon = beaconFrameFixedView(frame)
  if (beacon.frameControl and 0x07FF) != 0x0080 or (beacon.seqCtrl and 0xF) != 0 or
      beacon.addr1 != [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] or
      beacon.addr2 != sta.macAddr or beacon.addr3 != sta.macAddr or
      vif.currentBssid != sta.macAddr:
    return false
  var remaining = length.uint - sizeof(BeaconFrameFixedView).uint
  var cursor = cast[uint](beaconFrameIeBody(beacon))
  if remaining > high(uint) - cursor: return false
  var found = false
  var params: StaWmmParameters
  while remaining != 0:
    if remaining < 2: return false
    let ie = macIeAt(cursor)
    let size = ie.len.uint + 2
    if size > remaining: return false
    if isWmmParameterIe(ie):
      if found or not decodeStaWmmParameters(ie, params): return false
      found = true
    cursor += size
    remaining -= size
  if not found: return false
  let updateCount = params.qosInfo and 0x0F
  if updateCount != (vif.wmmQosInfo and 0x0F):
    # U-APSD negotiation is association state, not the EDCA update count.
    vif.wmmQosInfo = (vif.wmmQosInfo and 0xF0) or updateCount
    vif.wmmAcFlags = params.admissionMask
    vif.edcaRegs = params.edca
    for queue, word in params.edca:
      vifApEdcaWord(config, queue)[] = word
  true

proc scanuRxFrameValid(frame: pointer; payloadLength: uint32): bool =
  const
    headerLength = offsetof(RxuMgtIndMsgView, body).uint32
    fixedFrameLength = 36'u32
  if frame == nil or payloadLength < headerLength + fixedFrameLength:
    return false
  let rx = rxuMgtIndAt(frame)
  let frameLength = rx.frameLen.uint32
  if frameLength < fixedFrameLength or frameLength > payloadLength - headerLength:
    return false
  let frameControl = rxuMgtIndMsgAt(frame).frameCtrl
  if (frameControl and 0x00FF'u16) notin [0x50'u16, 0x80'u16]:
    return false
  var supportedRates, extendedRates: ptr MacIeView
  var seenSsid = false
  var seenDsParam = false
  var seenRsn = false
  var seenWpa = false
  var cursor = cast[uint](rxuMgtIndIeStart(frame))
  var remaining = frameLength - fixedFrameLength
  while remaining != 0:
    if remaining < 2:
      return false
    let ie = macIeAt(cursor)
    let size = ie.totalLen.uint32
    if size > remaining:
      return false
    case ie.id
    of IE_ID_SSID:
      if seenSsid or ie.len > 32: return false
      seenSsid = true
    of 1:
      if supportedRates == nil: supportedRates = ie
    of 50:
      if extendedRates == nil: extendedRates = ie
    of IE_ID_DS_PARAM:
      if seenDsParam or ie.len != 1: return false
      seenDsParam = true
    of 32, 42:
      if ie.len != 1: return false
    of IE_ID_RSN:
      if seenRsn: return false
      seenRsn = true
    of IE_ID_HT_CAP:
      if ie.len < 26: return false
    of 221:
      let body = ie.macIePayload
      if ie.len >= 4 and body[0] == WPA_OUI[0] and
          body[1] == WPA_OUI[1] and body[2] == WPA_OUI[2] and
          body[3] == WPA_OUI[3]:
        if seenWpa: return false
        seenWpa = true
      # WMM parameter parsing reads four complete AC records.
      if ie.len >= 5:
        if body[0] == 0 and body[1] == 0x50 and body[2] == 0xF2 and
            body[3] == 2 and body[4] == 1 and ie.len < 24:
          return false
        if body[0] == 0 and body[1] == 0x50 and body[2] == 0xF2 and
            body[3] == 2 and body[4] == 1:
          var seenAccessCategories = 0'u8
          for recordIndex in 0 ..< 4:
            let aci = (body[8 + recordIndex * 4] shr 5) and 3'u8
            let aciBit = 1'u8 shl aci
            if (seenAccessCategories and aciBit) != 0:
              return false
            seenAccessCategories = seenAccessCategories or aciBit
    else:
      discard
    cursor += size.uint
    remaining -= size
  # Discovery forwards the original IEs. Only a join fills the fixed VIF rate set.
  if scanu_env.bssidFilterEnabled == 0 or supportedRates == nil: return true
  var rates: array[12, uint8]
  let count = readLegacyRateIe(supportedRates, 0, rates)
  count >= 0 and readLegacyRateIe(extendedRates, count, rates) >= 0

proc scanuFrameMatchesBssid(rx: ptr RxuMgtIndView): bool {.inline.} =
  if (scanu_env.filterBssid[0] and 1) != 0:
    return true
  for filterBssidByteIndex in 0 ..< 6:
    if rx.bssid[filterBssidByteIndex] != scanu_env.filterBssid[filterBssidByteIndex]:
      return false
  true

proc scanuConnectionKeyLength(param: pointer; payloadLength: uint32): int =
  const keyOffset = offsetof(ConnectInfoCredentialOverlay, keyString).uint32
  if param == nil or payloadLength <= keyOffset:
    return -1
  let credentials = connectInfoCredentials(param)
  let available = min(payloadLength - keyOffset, credentials.keyString.len.uint32)
  for i in 0 ..< available.int:
    if credentials.keyString[i] == 0:
      return i
  -1

proc scanuApplyLegacyCredentialPolicy(param: pointer; payloadLength: uint32;
    security: ptr VifSecurityOverlay; sm: ptr SmEnvView; privacy: bool): bool =
  if security == nil or sm == nil:
    return false
  let saved = irqSave()
  defer: irqRestore(saved)
  let errorFlag = if privacy: 2'u8 else: 1'u8
  if param == nil or payloadLength < sizeof(ConnectInfoView).uint32:
    sm.connectModeFlags = sm.connectModeFlags or errorFlag
    return false
  let keyLength = scanuConnectionKeyLength(param, payloadLength)
  let connection = connectInfoView(param)
  if privacy:
    if keyLength in [5, 10, 13, 26]:
      if keyLength == 10 or keyLength == 26:
        let key = connectInfoCredentials(param)
        for i in 0 ..< keyLength:
          let ch = key.keyString[i]
          if not ((ch >= 0x30 and ch <= 0x39) or
                  (ch >= 0x41 and ch <= 0x46) or
                  (ch >= 0x61 and ch <= 0x66)):
            sm.connectModeFlags = sm.connectModeFlags or errorFlag
            return false
      security.cipher = 1
      connection.authType = 1
      return true
    sm.connectModeFlags = sm.connectModeFlags or errorFlag
    return false
  connection.channelDuration = connection.channelDuration or 2
  if keyLength != 0:
    sm.connectModeFlags = sm.connectModeFlags or errorFlag
    return false
  true

proc scanuPublishFrameResult(frame: pointer; validatedFrameLen: uint16;
                             payloadLen: uint32;
                             scanResultEntry: ptr ScanuResultEntry;
                             request: pointer; epoch, generation: uint32;
                             numSsids, bfOn: uint8;
                             smStamp = 0'u32) =
  ## `smStamp`: the SM operation a directed scan belongs to, else 0.
  if frame == nil:
    return
  defer: ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
  if payloadLen < 32 or validatedFrameLen < 36 or
      validatedFrameLen.uint32 > payloadLen - 32:
    return
  let saved = irqSave()
  defer: irqRestore(saved)
  let cached = scanuCachedSsidFor(scanResultEntry)
  template ownsSlot(): bool =
    scanuRequestCurrent(request, epoch) and cached != nil and
      cached.generation == generation and
      (smStamp == 0 or opCurrent(smOwn.op, smStamp))
  if not ownsSlot(): return

  if scanResultEntry.valid == 0:
    scanu_env.resultCount += 1
  if numSsids == 0:
    return
  scanResultEntry.valid = 1
  inc nimFwDbgScanFrameAccepted
  nimFwDbgScanFrameLast =
    scanu_env.resultCount.uint32 or
    (scanResultEntry.rssi.uint8.uint32 shl 8) or
    (scanResultEntry.band.uint32 shl 16) or
    (bfOn.uint32 shl 24)

  if bfOn != 0 and scanResultEntry.cachedRxuMgtInd != nil:
    return
  let retired = scanResultEntry.cachedRxuMgtInd
  scanResultEntry.cachedRxuMgtInd = nil
  let expected = scanResultEntry[]
  template current(): bool = ownsSlot() and scanResultEntry[] == expected
  ke_msg_free_payload(retired)
  if not current(): return

  let cachedRxuMgtIndLen = validatedFrameLen.uint32 + 32
  let cachedAllocLen = max(cachedRxuMgtIndLen, sizeof(RxuMgtIndView).uint32)
  let msg = ke_msg_try_alloc(0x1C00'u16, 2, 2, cachedAllocLen)
  if msg == nil: return
  if not current():
    ke_msg_free_payload(msg)
    return
  discard c_memcpy(msg, frame, cachedRxuMgtIndLen.csize_t)
  rxuMgtIndAt(msg).frameLen = validatedFrameLen
  scanResultEntry.cachedRxuMgtInd = msg

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_frame_handler(void*,unsigned long);".}
proc scanu_frame_handler*(frame: pointer, len: uint32) {.exportc, cdecl.} =
  ## Handle received beacon/probe response during active scan.
  ## Reverse-engineered from the blob (859 instructions).
  if not scanuRxFrameValid(frame, len):
    return
  let rx = rxuMgtIndAt(frame)
  inc nimFwDbgScanFrameSeen
  let totalLen = rx.frameLen
  let ieStart = rxuMgtIndIeStart(frame)
  var ieLen = if totalLen > 36: totalLen.uint32 - 36 else: 0'u32

  var wpaIePtr: pointer = nil
  var rsnIePtr: pointer = nil
  var ssidScratch {.noinit.}: ScanSsidSlotView
  var secInfo {.noinit.}: WpaParsedInfoView
  discard c_memset(addr ssidScratch, 0, sizeof(ScanSsidSlotView).csize_t)
  discard c_memset(addr secInfo, 0, sizeof(WpaParsedInfoView).csize_t)

  let scanParam = scanu_env.paramPtr
  let scanEpoch = scanuRequestEpoch
  let scanuState = ke_state_get(TASK_SCANU)
  if scanParam == nil or (scanuState != 1 and scanuState != 2) or
      not scanuRequestCurrent(scanParam, scanEpoch):
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return

  var scanFlags: uint32
  var scanVifIdx, numSsids: uint8
  var filterSsid: ScanSsidSlotView
  var directedBssid: bool
  let requestCaptured = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if not scanuRequestCurrent(scanParam, scanEpoch):
      false
    else:
      # Only these request fields are needed after callbacks can retire it.
      let request = scanuStartReqView(scanParam)
      scanFlags = request.flags
      scanVifIdx = request.vifIdx
      numSsids = request.scanType
      directedBssid = (scanu_env.filterBssid[0] and 1) == 0
      if numSsids == 1:
        filterSsid = scanSsidSlot(request, 0)[]
      true
  if not requestCaptured or scanVifIdx >= MAX_VIFS.uint8 or numSsids > 1 or
      (numSsids != 0 and filterSsid.length > 32) or
      not scanuFrameMatchesBssid(rx):
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return
  # Validate channel via DS Parameter Set IE
  block:
    let dsIe = mac_ie_find(ieStart, ieLen, IE_ID_DS_PARAM)
    if dsIe != nil:
      let ds = dsParamSetIeAt(dsIe)
      if dsParamFreq(rx.band, ds) == 0xFFFF'u16:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return

  # Find WPA/RSN IEs and parse RSN via wpa_cbs
  find_wpa_rsn_ie(ieStart, ieLen, addr wpaIePtr, addr rsnIePtr)

  if rsnIePtr != nil:
    if wpa_cbs != nil:
      let parseSecurityIeCallback = wpaCallbacks().parseSecurityIe
      if parseSecurityIeCallback != nil:
        let rsn = cast[ptr MacIeView](rsnIePtr)
        let securityIeParser =
          cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](parseSecurityIeCallback)
        if rsn.totalLen > high(uint8).uint or
            securityIeParser(rsnIePtr, rsn.totalLen.uint8, addr secInfo) != nil:
          ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
          return
  elif wpaIePtr != nil:
    if wpa_cbs != nil:
      let parseSecurityIeCallback = wpaCallbacks().parseSecurityIe
      if parseSecurityIeCallback != nil:
        let wpa = cast[ptr MacIeView](wpaIePtr)
        let securityIeParser =
          cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](parseSecurityIeCallback)
        if wpa.totalLen > high(uint8).uint or
            securityIeParser(wpaIePtr, wpa.totalLen.uint8, addr secInfo) != nil:
          ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
          return

  if not scanuRequestCurrent(scanParam, scanEpoch):
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return

  # Security flag filtering for undirected scan
  let bfOn = scanu_env.bssidFilterEnabled
  if bfOn == 0:
    let allowUnrestrictedSecurity = (scanFlags and 0x200) != 0
    let requirePmfCapableRsn = (scanFlags and 0x400) != 0
    if requirePmfCapableRsn:
      if rsnIePtr == nil or (secInfo.caps and 0x80) == 0:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return
    elif not allowUnrestrictedSecurity:
      if rsnIePtr != nil and (secInfo.caps and 0x40) != 0:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return

  # Find or allocate scan result entry
  let result = scanu_find_result(addr rx.bssid[0], 1)
  if result == nil or not scanuRequestCurrent(scanParam, scanEpoch):
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return
  let scanResultEntry = scanuResultAt(result)
  let cachedSsid = scanuCachedSsidFor(scanResultEntry)
  if cachedSsid == nil:
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return
  var resultGeneration = cachedSsid.generation
  template ownsResult(): bool =
    scanuRequestCurrent(scanParam, scanEpoch) and
      cachedSsid.generation == resultGeneration

  # 0x4C ends the current channel dwell, not the whole scan. A wildcard
  # BSSID must first match the requested SSID slot below.
  let earlyEnd = (scanFlags and 0x100) != 0
  template endDwellEarly() =
    scanEarlyEndRequest()
    if not ownsResult():
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
  if directedBssid and earlyEnd:
    endDwellEarly()

  # Security info
  # Keep rejected observations from changing an already published result.
  let previousResult = scanResultEntry[]
  var observedResult = previousResult
  if bfOn == 0:
    if (secInfo.keyMgmtMaskLow and 0x04) != 0:
      observedResult.securityType = 0x0101; observedResult.securityAuth = 1
    else:
      observedResult.securityType = 0; observedResult.securityAuth = 0
      if rsnIePtr != nil:
        if (secInfo.caps and 0x80) != 0:
          observedResult.securityType =
            observedResult.securityType or 0x0001'u16
        if (secInfo.caps and 0x40) != 0:
          observedResult.securityType =
            observedResult.securityType or 0x0100'u16

  # Fill basic fields
  observedResult.bssid = rx.bssid
  observedResult.beaconPeriod = rx.beaconPeriod
  let capI = rx.capInfo
  observedResult.capInfo = capI
  observedResult.band = 2'u16 - (capI and 1).uint16

  # SSID IE
  let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
  if ssidIe == nil:
    ssidScratch.length = 0
  else:
    let ssid = ssidIeAt(ssidIe)
    if ssid.ie.len > 32:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
    ssidScratch.length = ssid.ie.len
    for ssidScratchByteIndex in 0 ..< ssidScratch.length.int:
      ssidScratch.ssidBytes[ssidScratchByteIndex] = ssid.ssidBytes[ssidScratchByteIndex]
    if ssidScratch.length == 0 and previousResult.valid != 0 and
        previousResult.bssid == rx.bssid:
      block:
        let saved = irqSave()
        defer: irqRestore(saved)
        if ownsResult() and cachedSsid.valid != 0 and
            cachedSsid.length in 1'u8 .. 32'u8:
          ssidScratch.length = cachedSsid.length
          for i in 0 ..< cachedSsid.length.int:
            ssidScratch.ssidBytes[i] = cachedSsid.ssidBytes[i]
  nimFwDbgScanSsidLast =
    ssidScratch.length.uint32 or
    (ssidScratch.ssidBytes[0].uint32 shl 8) or
    (ssidScratch.ssidBytes[1].uint32 shl 16) or
    (ssidScratch.ssidBytes[2].uint32 shl 24)

  observedResult.noiseFloor1 = rx.noiseFloor1
  observedResult.noiseFloor2 = rx.noiseFloor2

  # Channel from DS IE. Some RX indications carry a stale frequency after
  # multi-channel scans, so prefer the beacon's DS channel when it is valid.
  var updateChannel = false
  var selectedFreq = rx.freq
  let dsIe2 = mac_ie_find(ieStart, ieLen, IE_ID_DS_PARAM)
  if dsIe2 != nil:
    let ds = dsParamSetIeAt(dsIe2)
    let dsFreq = dsParamFreq(rx.band, ds)
    nimFwDbgBssRxFreq = rx.freq.uint32 or (rx.band.uint32 shl 16)
    nimFwDbgBssDsFreq = dsFreq.uint32 or (ds.currentChannel.uint32 shl 16)
    selectedFreq = if dsFreq != 0xFFFF'u16: dsFreq else: rx.freq
    nimFwDbgBssSelectedFreq = selectedFreq.uint32
    updateChannel = true
  else:
    nimFwDbgBssRxFreq = rx.freq.uint32 or (rx.band.uint32 shl 16)
    nimFwDbgBssDsFreq = 0xFFFFFFFF'u32
    nimFwDbgBssSelectedFreq = rx.freq.uint32
    updateChannel = observedResult.rssi < rx.rssi
  if observedResult.rssi < rx.rssi:
    observedResult.rssi = rx.rssi

  # SSID filter loop
  if numSsids != 0:
    let length = filterSsid.length
    if length != 0 and (length != ssidScratch.length or
        c_memcmp(addr filterSsid.ssidBytes[0], addr ssidScratch.ssidBytes[0],
                 length.csize_t) != 0):
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
    if (scanFlags and 0x40) != 0: scan_env.abortFlag = 1
    if not directedBssid and earlyEnd:
      endDwellEarly()

  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    if not ownsResult() or scanResultEntry[] != previousResult:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
    # Do not publish a result that cannot be used for a join. Check after the
    # SSID-filter callbacks, before replacing the cached channel or VIF state.
    if updateChannel:
      let configured = configuredScanChannelEntryForFreq(selectedFreq)
      if configured == nil or configured.band != rx.band:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return
    elif observedResult.chanPtr == nil:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
    if updateChannel:
      observedResult.chanPtr =
        scanuCacheChannel(scanResultEntry, rx.band, selectedFreq)
    scanResultEntry[] = observedResult
    scanuCacheSsid(scanResultEntry, addr ssidScratch)
    resultGeneration = cachedSsid.generation

  # A directed scan belongs to SM's attempt: the SM operation that asked for
  # it must still be live after each callback.
  var directedConnection: pointer
  var directedStamp: uint32
  template frameOwnerCurrent(): bool =
    ownsResult() and (bfOn == 0 or opCurrent(smOwn.op, directedStamp))
  template requireFrameOwner() =
    if not frameOwnerCurrent():
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return

  # Directed scan: populate VIF
  if bfOn != 0:
    let saved = irqSave()
    defer: irqRestore(saved)
    directedConnection = smEnvView().connectInfo
    if directedConnection == nil or
        connectInfoView(directedConnection).vifIdx != scanVifIdx or
        vifChannelForIdx(scanVifIdx).vifIdx != scanVifIdx or
        vifChannelForIdx(scanVifIdx).vifType != VIF_TYPE_STA:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
    directedStamp = smOwn.op.serial
    requireFrameOwner()
    let vif = vif_mgmt_get_vif(scanVifIdx)
    requireFrameOwner()
    if vif != nil:
      let vifView = vifChannelAt(vif)
      if not scanuPublishVifChannel(vifView, scanResultEntry):
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return
      let htCaps = vifHtCapabilities(vifView)
      let apConfig = vifApConfig(vifView)
      let securityState = vifSecurity(vifView)
      let assocState = vifAssocInfo(cast[pointer](htCaps))
      let stationManager = smEnvView()
      let connectInfoPtr = directedConnection
      let connectInfo = connectInfoView(connectInfoPtr)
      let savedChannelDurationFlags = connectInfo.channelDuration
      let bssInfoOut = vifBssInfoBase(vifView)
      let basicRatesOut = cast[pointer](addr vifView.basicRates[0])

      vifView.scanBand = scanResultEntry.band
      discard c_memcpy(addr vifView.bssid[0],
                       addr scanResultEntry.bssid[0], 6)
      discard c_memcpy(addr vifView.supportedRatesLong[0], addr ssidScratch,
                       sizeof(ScanSsidSlotView).csize_t)
      vifView.capabilityInfo = scanResultEntry.capInfo
      vifView.beaconIntervalTu = scanResultEntry.beaconPeriod
      apConfig.securityFlags = 0
      apConfig.noiseFloor1 = scanResultEntry.noiseFloor1
      apConfig.noiseFloor2 = scanResultEntry.noiseFloor2

      me_extract_rate_set(ieStart, ieLen, basicRatesOut)
      requireFrameOwner()

      if scanResultEntry.chanPtr != nil:
        let channelBytes =
          cast[ptr UncheckedArray[uint8]](scanResultEntry.chanPtr)
        if channelBytes[2] == 0:
          let basicRateMask = me_legacy_rate_bitfield_build(basicRatesOut, 1)
          requireFrameOwner()
          var highestBasicRateBit: uint8 = 1
          if (basicRateMask and 0x0F) != 0:
            var basicRateNibble: cuint = (basicRateMask and 0x0F).cuint
            var leadingZeroCount: cint
            {.emit: [leadingZeroCount, " = __builtin_clz(", basicRateNibble, ");"].}
            highestBasicRateBit = (31 - leadingZeroCount).uint8
          apConfig.highestRateBit = highestBasicRateBit

      let wmmO = unsafeAddr WMM_OUI[0]
      let wmmIe = mac_vsie_find(ieStart, ieLen, cast[pointer](wmmO), 5)
      var wmm: StaWmmParameters
      if decodeStaWmmParameters(cast[ptr MacIeView](wmmIe), wmm):
        vifView.wmmQosInfo = wmm.qosInfo
        vifView.capabilityInfo = vifView.capabilityInfo or 0x200'u16
        for queue, word in wmm.edca:
          vifApEdcaWord(apConfig, queue)[] = word
        vifView.wmmAcFlags = wmm.admissionMask
        apConfig.securityFlags = apConfig.securityFlags or 1
      else:
        vifView.wmmQosInfo = 0
        vifView.wmmAcFlags = 0
        let defaultEdcaParam = 0x0A43'u32
        for accessCategory in 0..3:
          vifApEdcaWord(apConfig, accessCategory)[] = defaultEdcaParam

      if meEnvView().htSupp != 0 and
          (apConfig.securityFlags and 1) != 0:
        let hcIe = mac_ie_find(ieStart, ieLen, IE_ID_HT_CAP)
        if hcIe != nil:
          let htCapIe = htCapIeAt(hcIe)
          htCaps.capInfo = htCapIe.capInfo
          htCaps.ampduParams = htCapIe.ampduParams
          for mi in 0'u8 ..< 16:
            htCaps.mcsSet[mi.int] = htCapIe.mcsSet[mi.int]
          htCaps.extCap = htCapIe.extCap
          htCaps.txBfCaps = htCapIe.txBfCapsLo.uint32
          htCaps.aselCap = htCapIe.aselCap
          apConfig.securityFlags = apConfig.securityFlags or 2

      securityState.connected = connectInfo.authRetryGate
      var securityAccepted = true
      if stationManager.state == 2:
        connectInfo.channelDuration = savedChannelDurationFlags or 9
      elif cast[int32](apConfig.securityFlags) >= 0:
        securityAccepted = false
        connectInfo.channelDuration = 0
        var wpaIe, rsnIe: pointer
        var parsedSec {.noinit.}: WpaParsedInfoBuffer
        discard c_memset(addr parsedSec, 0, sizeof(WpaParsedInfoBuffer).csize_t)
        securityState.rsnIePtr = 0
        securityState.rsnIeLen = 0
        assocState.rsnIePtr = 0
        assocState.rsnIeLen = 0
        securityState.cipher = 0
        securityState.groupCipher = 0
        securityState.pairwiseCipher = 0
        securityState.keyMgmtMaskLow = 0
        securityState.keyMgmt = 0
        securityState.pmfCapable = 0
        securityState.pmfRequired = 0
        find_wpa_rsn_ie(ieStart, ieLen, addr wpaIe, addr rsnIe)
        var selectedCipher: uint8 = 0
        var securityParsed = false
        if rsnIe != nil:
          selectedCipher = 3
          if wpa_cbs != nil:
            let rsn = cast[ptr MacIeView](rsnIe)
            let parseSecurityIeCallback = wpaCallbacks().parseSecurityIe
            if parseSecurityIeCallback != nil:
              if rsn.totalLen <= high(uint8).uint:
                securityParsed = cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](
                  parseSecurityIeCallback)(rsnIe, rsn.totalLen.uint8,
                                           addr parsedSec.view) == nil
        elif wpaIe != nil:
          selectedCipher = 2
          if wpa_cbs != nil:
            let wpa = cast[ptr MacIeView](wpaIe)
            let parseSecurityIeCallback = wpaCallbacks().parseSecurityIe
            if parseSecurityIeCallback != nil:
              if wpa.totalLen <= high(uint8).uint:
                securityParsed = cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](
                  parseSecurityIeCallback)(wpaIe, wpa.totalLen.uint8,
                                           addr parsedSec.view) == nil
        requireFrameOwner()
        securityState.cipher = selectedCipher
        # Read key_mgmt as a full 16-bit value (struct wifi_wpa_ie_t has it as
        # int at offset 12, LE). Prior code read only parsedSecurity[12]
        # (single byte), which
        # silently lost bit 10 (WPA_KEY_MGMT_SAE = 0x400) since it lives in byte 13.
        var selectedAuth: uint32 = 2
        let parsedSecurity = addr parsedSec.view
        let keyMgmtMask = parsedSecurity.keyMgmtLe
        let rsnInfo =
          if rsnIe != nil:
            wifiRsnAkmInfoFromIe(rsnIe, cast[ptr MacIeView](rsnIe).totalLen.uint32)
          else:
            WifiRsnAkmInfo()
        let eligibleKeyMgmtMask =
          if parsedSecurity.groupCipher == 4'u8 and
              parsedSecurity.pairwiseCipher in [4'u8, 5'u8] and
              rsnInfo.bipCmac128: keyMgmtMask
          else: keyMgmtMask and not WifiAuthMaskSae
        nimFwDbgScanKeyMgmt = keyMgmtMask
        nimFwDbgScanSmF = savedChannelDurationFlags
        nimFwDbgScanCaps = parsedSecurity.caps.uint32
        when defined(bl808WifiForcePmfCapable):
          let effectiveAuthFlags = savedChannelDurationFlags or 0x200'u32
        else:
          let effectiveAuthFlags = savedChannelDurationFlags
        let peerPmfCapable = (parsedSecurity.caps and 0x80) != 0
        let peerPmfRequired = (parsedSecurity.caps and 0x40) != 0
        let localPmfCapable = (effectiveAuthFlags and 0x600) != 0
        let localPmfRequired = (effectiveAuthFlags and 0x400) != 0
        selectedAuth = wifiPreferredKeyMgmtFromMask(
          eligibleKeyMgmtMask, localPmfCapable and peerPmfCapable,
          localPmfRequired)
        nimFwDbgScanAT = selectedAuth
        let pmfCompatible =
          (selectedAuth != WifiKeyMgmtSae or (peerPmfCapable and localPmfCapable)) and
          (not peerPmfRequired or (peerPmfCapable and localPmfCapable)) and
          (not localPmfRequired or peerPmfCapable) and
          (not (peerPmfCapable and localPmfCapable) or rsnInfo.bipCmac128)
        if securityParsed and selectedAuth != 0 and pmfCompatible:
          securityAccepted = true
          securityState.groupCipher = parsedSecurity.groupCipher
          securityState.pairwiseCipher = parsedSecurity.pairwiseCipher
          securityState.keyMgmtMaskLow = parsedSecurity.keyMgmtMaskLow
          securityState.keyMgmt = selectedAuth
          if peerPmfCapable and localPmfCapable:
            securityState.pmfCapable = 1
            if peerPmfRequired or localPmfRequired or selectedAuth == WifiKeyMgmtSae:
              securityState.pmfRequired = 1
              securityState.keyMgmtMaskLow = 6
          if selectedAuth == 1024: securityState.cipher = 4
          let effectiveCipher = securityState.cipher
          if effectiveCipher >= 2 and effectiveCipher <= 4:
            let srcSecIe = if rsnIe != nil: rsnIe else: wpaIe
            if srcSecIe != nil:
              let secIe = cast[ptr MacIeView](srcSecIe)
              let secLenRaw = secIe.totalLen
              let assocSecurityIeSlot =
                if vifView.vifIdx.int < MAX_VIFS: vifView.vifIdx.int else: 0
              if secLenRaw > assocSecIeStore[assocSecurityIeSlot].len.uint:
                ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
                return
              let copyLen = secLenRaw
              discard c_memcpy(addr assocSecIeStore[assocSecurityIeSlot][0], srcSecIe,
                               copyLen.csize_t)
              securityState.rsnIePtr =
                cast[uint32](addr assocSecIeStore[assocSecurityIeSlot][0])
              securityState.rsnIeLen = copyLen.uint8
              assocState.rsnIePtr = securityState.rsnIePtr
              assocState.rsnIeLen = securityState.rsnIeLen
              var securityIeTraceWord = 0'u32
              let traceLen = min(copyLen, sizeof(securityIeTraceWord).uint)
              discard c_memcpy(addr securityIeTraceWord, srcSecIe, traceLen.csize_t)
              nimFwTrace2U32("[WIFI-NIMFW] scan_sec_ie ",
                             effectiveCipher.uint32 or (copyLen.uint32 shl 8),
                             securityIeTraceWord)
              requireFrameOwner()
            var notify {.noinit.}: WpaScanSecurityNotifyView
            discard c_memset(addr notify, 0, sizeof(WpaScanSecurityNotifyView).csize_t)
            notify.vifIdx = vifView.vifIdx
            notify.macAddr = vifView.macAddr
            notify.bssid = vifView.bssid
            notify.cipher = effectiveCipher
            notify.keyMgmt = selectedAuth.uint16
            notify.pairwiseCipher = securityState.pairwiseCipher
            notify.groupCipher = securityState.groupCipher
            notify.pmfRequired = securityState.pmfRequired
            notify.mgmtGroupCipher =
              if securityState.pmfCapable != 0: 6'u8 else: 0'u8
            if wpa_cbs != nil:
              let scanSecurityNotifyCallback = wpaCallbacks().scanSecurityNotify
              if scanSecurityNotifyCallback != nil:
                cast[proc(b:pointer){.cdecl.}](scanSecurityNotifyCallback)(addr notify)
            requireFrameOwner()
            let securityConnectInfoPtr = directedConnection
            let securityConnectInfo = connectInfoView(securityConnectInfoPtr)
            securityConnectInfo.channelDuration = securityConnectInfo.channelDuration or 9
            if effectiveCipher == 4: securityConnectInfo.authType = 3

        if wpaIe == nil and rsnIe == nil:
          securityAccepted = scanuApplyLegacyCredentialPolicy(
            connectInfoPtr, keMsgHdrFromPayload(connectInfoPtr).paramLen,
            securityState, stationManager, (vifView.capabilityInfo and 0x10) != 0)

      if securityAccepted:
        me_bw_check(bssInfoOut)
        requireFrameOwner()
        me_extract_power_constraint(ieStart, ieLen, bssInfoOut)
        requireFrameOwner()
        me_extract_country_reg(ieStart, ieLen, bssInfoOut)
        requireFrameOwner()
        apConfig.securityFlags = apConfig.securityFlags or 0x80000000'u32
        vifView.vifType = VIF_TYPE_STA
        scanu_env.directedFound = 1

  # WPS callback
  requireFrameOwner()
  if smEnvView().state == 1:
    let wO = unsafeAddr WPS_OUI[0]
    let wIe = mac_vsie_find(ieStart, ieLen, cast[pointer](wO), 4)
    if wIe != nil:
      var wb {.noinit.}: WpsScanCallbackBuffer
      discard c_memset(addr wb.view, 0, sizeof(WpsScanCallbackView).csize_t)
      wb.view.result = result
      wb.view.ssidPtr = cast[pointer](addr ssidScratch.ssidBytes[0])
      wb.view.ssidLen = ssidScratch.length
      wb.view.capInfo = scanResultEntry.capInfo
      wb.view.wpsIe = wIe
      var wW, wR: pointer
      find_wpa_rsn_ie(ieStart, ieLen, addr wW, addr wR)
      wb.view.rsnIe = wR
      wb.view.wpaIe = wW
      if wps_cbs != nil:
        let cf = cast[ptr pointer](wps_cbs)[]
        if cf != nil: cast[proc(b:pointer){.cdecl.}](cf)(addr wb.view)

  requireFrameOwner()
  scanuPublishFrameResult(frame, totalLen, len,
                          scanResultEntry, scanParam, scanEpoch,
                          resultGeneration, numSsids, bfOn,
                          if bfOn == 0: 0'u32 else: directedStamp)

proc scanu_search_by_bssid*(bssid: pointer): pointer {.exportc, cdecl, noinline.} =
  return scanu_find_result(bssid, 0)

type ScanuResultSnapshot = object
  entry: ptr ScanuResultEntry
  value: ScanuResultEntry
  ssid: ScanuCachedSsid
  channel: ScanChannelEntry
  epoch: uint32

proc scanuCaptureResult(scanResultEntry: ptr ScanuResultEntry): ScanuResultSnapshot =
  # Callers hold the IRQ guard while capturing and checking borrowed state.
  if scanResultEntry == nil or scanResultEntry.valid == 0:
    return
  let cached = scanuCachedSsidFor(scanResultEntry)
  if cached == nil:
    return
  result.entry = scanResultEntry
  result.value = scanResultEntry[]
  result.ssid = cached[]
  result.epoch = scanuRequestEpoch
  if result.value.chanPtr != nil:
    result.channel = cast[ptr ScanChannelEntry](result.value.chanPtr)[]

proc scanuResultCurrent(snapshot: ScanuResultSnapshot;
                        allowRawRelease = false): bool =
  if snapshot.entry == nil or snapshot.epoch != scanuRequestEpoch:
    return false
  var value = snapshot.entry[]
  if value.cachedRxuMgtInd != snapshot.value.cachedRxuMgtInd:
    if not allowRawRelease or value.cachedRxuMgtInd != nil:
      return false
    value.cachedRxuMgtInd = snapshot.value.cachedRxuMgtInd
  if value != snapshot.value:
    return false
  let cached = scanuCachedSsidFor(snapshot.entry)
  if cached == nil or cached[] != snapshot.ssid:
    return false
  value.chanPtr == nil or
    cast[ptr ScanChannelEntry](value.chanPtr)[] == snapshot.channel

proc scanuBssSecurityPreferred(entry: ptr ScanuResultEntry): bool {.inline.} =
  # BL808 scanu_search_by_ssid masks entry bytes 0x14 and 0x16,
  # the low bytes of the two security fields, not the retained frame pointer.
  entry.securityAuth != 0 or (entry.securityType and 0xFF'u16) != 0

{.emit: "__attribute__((optimize(\"crossjumping\"))) void* scanu_search_by_ssid(void*,void*);".}
proc scanu_search_by_ssid*(ssid: pointer, entryIndexOut: pointer): pointer {.exportc, cdecl.} =
  ## Search scan results by SSID.
  ## ssid = pointer to SSID string (first byte = SSID length, rest = SSID data).
  ## entryIndexOut receives the selected result index; blob reads length from ssid[0].
  ## Returns pointer to matching scan result entry, or nil if not found.
  ## A directed scan compares the query with the request's SSID filter, then
  ## keeps the strongest valid result. Unfiltered scans also use the Nim-side
  ## raw-frame and retained-cache lookup.
  if ssid == nil:
    return nil
  let saved = irqSave()
  defer: irqRestore(saved)
  let searchEpoch = scanuRequestEpoch
  let ssidSlot = lengthPrefixedSsidView(ssid)
  let searchLen = ssidSlot.length
  if searchLen == 0 or searchLen > 32:
    return nil
  let useRequestFilter = scanu_env.filterSsidLen != 0
  if useRequestFilter and
      (searchLen != scanu_env.filterSsidLen or
       c_memcmp(addr ssidSlot.ssidBytes[0], addr scanu_env.filterSsid[0],
                searchLen.csize_t) != 0):
    return nil
  # Keep a bounded query snapshot across diagnostic callbacks.
  var searchSsid: ScanSsidSlotView
  searchSsid.length = searchLen
  for ssidByteIndex in 0 ..< searchLen.int:
    searchSsid.ssidBytes[ssidByteIndex] = ssidSlot.ssidBytes[ssidByteIndex]
  let searchWord = searchSsid.ssidBytes[0].uint32 or
    (searchSsid.ssidBytes[1].uint32 shl 8) or
    (searchSsid.ssidBytes[2].uint32 shl 16) or
    (searchSsid.ssidBytes[3].uint32 shl 24)
  # Bit 9 enables the vendor's security preference. Bit 10 suppresses retry.
  let connectInfo = smEnvView().connectInfo
  let searchFlags =
    if connectInfo != nil: connectInfoView(connectInfo).channelDuration
    else: 0'u32
  let preferSecurity = (searchFlags and (1'u32 shl 9)) != 0
  let strictSecurity = (searchFlags and (1'u32 shl 10)) != 0
  let passCount = if preferSecurity and not strictSecurity: 2 else: 1
  nimFwDbgSsidSearch = searchLen.uint32 or (searchWord shl 8)
  nimFwDbgSsidEntries = 0
  nimFwDbgSsidHits = 0
  nimFwTrace2U32("[WIFI-NIMFW] ssid_s ", searchLen.uint32, searchWord)
  # Build search key (ssid+1 is the actual SSID data, length = searchLen)
  let searchData = cast[pointer](addr searchSsid.ssidBytes[0])
  var bestScanResultEntry: ptr ScanuResultEntry = nil
  var bestRssi: int8 = -128
  var bestSnapshot: ScanuResultSnapshot
  var bestIndex: uint32
  var bestAllowsRawRelease = false
  for scanIteration in 0'u8 ..< (SCANU_MAX_RESULT_ENTRIES * passCount).uint8:
    if scanIteration == SCANU_MAX_RESULT_ENTRIES.uint8 and
        bestScanResultEntry != nil:
      break
    let ssidSearchResultSlotIndex =
      scanIteration mod SCANU_MAX_RESULT_ENTRIES.uint8
    let filterState = preferSecurity and
      scanIteration < SCANU_MAX_RESULT_ENTRIES.uint8
    let ssidSearchResultEntry =
      addr scanu_env.entries[ssidSearchResultSlotIndex]
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] ssid_entry ",
                            ssidSearchResultSlotIndex.uint32 or
                              (ssidSearchResultEntry.valid.uint32 shl 8) or
                              (ssidSearchResultEntry.rssi.uint8.uint32 shl 16),
                            cast[uint32](ssidSearchResultEntry.chanPtr))
      nimFwConnectTrace2U32("[WIFI-CT] ssid_cache ",
                            ssidSearchResultSlotIndex.uint32,
                            scanuCachedSsidMeta(ssidSearchResultEntry))
    nimFwTrace2U32("[WIFI-NIMFW] ssid_i ",
                   ssidSearchResultSlotIndex.uint32 or
                     (ssidSearchResultEntry.valid.uint32 shl 8),
                   cast[uint32](ssidSearchResultEntry.cachedRxuMgtInd))
    if scanuRequestEpoch != searchEpoch:
      return nil
    if ssidSearchResultEntry.valid == 0:
      continue
    inc nimFwDbgSsidEntries
    if filterState and not scanuBssSecurityPreferred(ssidSearchResultEntry):
      continue
    # The vendor skips entries that cannot improve the selected RSSI before
    # reading their SSID or invoking its match logger.
    let rssi = ssidSearchResultEntry.rssi
    if rssi <= bestRssi:
      continue
    let snapshot = scanuCaptureResult(ssidSearchResultEntry)
    let retainedMatch =
      if useRequestFilter: false
      else: scanuCachedSsidMatches(ssidSearchResultEntry, searchData, searchLen)
    # On unfiltered scans, an advertised SSID is authoritative; the retained
    # cache only fills in hidden or unavailable raw SSIDs.
    let cachedRxuMgtInd = ssidSearchResultEntry.cachedRxuMgtInd
    if not useRequestFilter and cachedRxuMgtInd == nil:
      nimFwTrace2U32("[WIFI-NIMFW] ssid_raw0 ",
                     ssidSearchResultSlotIndex.uint32,
                     cast[uint32](ssidSearchResultEntry))
      if not retainedMatch:
        continue
    elif not useRequestFilter:
      # Find SSID IE in the cached RXU_MGT_IND payload. The RXU header is 32
      # bytes, followed by the MAC header (24) and beacon fixed fields (12).
      let cachedRxuMgtIndView = rxuMgtIndAt(cachedRxuMgtInd)
      let totalLen = cachedRxuMgtIndView.frameLen
      let ieLen = if totalLen > 36'u16: totalLen.uint32 - 36'u32 else: 0'u32
      let ieStart = rxuMgtIndIeStart(cachedRxuMgtInd)
      let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
      if ssidIe == nil:
        if not retainedMatch:
          continue
      else:
        let entrySsid = ssidIeAt(ssidIe)
        let entrySsidLen = entrySsid.ie.len
        var entrySsidWord = 0'u32
        for ssidByteIndex in 0 ..< min(entrySsidLen.int, 4):
          entrySsidWord = entrySsidWord or
            (entrySsid.ssidBytes[ssidByteIndex].uint32 shl (ssidByteIndex * 8))
        let entrySsidMeta = ssidSearchResultSlotIndex.uint32 or
          (ssidSearchResultEntry.valid.uint32 shl 8) or
          (entrySsidLen.uint32 shl 16) or (rssi.uint8.uint32 shl 24)
        # Finish raw-frame reads before a trace callback can release the frame.
        let cmpResult =
          if entrySsidLen == searchLen:
            c_memcmp(searchData, addr entrySsid.ssidBytes[0], searchLen.csize_t)
          else:
            1.cint
        let matches =
          if entrySsidLen == 0: retainedMatch
          else: entrySsidLen <= 32 and entrySsidLen == searchLen and
            cmpResult == 0
        nimFwTrace2U32("[WIFI-NIMFW] ssid_e ",
                       entrySsidMeta, entrySsidWord)
        if entrySsidLen == searchLen and cmpResult != 0:
          nimFwTrace2U32("[WIFI-NIMFW] ssid_cmp ",
                         ssidSearchResultSlotIndex.uint32,
                         cast[uint32](cmpResult))
        if not matches:
          continue
    nimFwTrace2U32("[WIFI-NIMFW] ssid_hit ",
                   ssidSearchResultSlotIndex.uint32, rssi.uint8.uint32)
    inc nimFwDbgSsidHits
    # Match found: log via g_bl_ops_funcs[204]
    let logFnMatch = getLogFunc(204)
    if logFnMatch != nil:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.}](logFnMatch)(
        2, nil, "scanu.c", 1010, "find existed ssid, idx = %d, rssi %d\r\n",
        ssidSearchResultSlotIndex.cint, rssi.cint)
    if not scanuResultCurrent(snapshot, useRequestFilter or retainedMatch):
      return nil
    bestRssi = rssi
    bestScanResultEntry = ssidSearchResultEntry
    bestSnapshot = snapshot
    bestIndex = ssidSearchResultSlotIndex.uint32
    bestAllowsRawRelease = useRequestFilter or retainedMatch
  if bestScanResultEntry != nil:
    if scanuRequestEpoch != searchEpoch or
        not scanuResultCurrent(bestSnapshot, bestAllowsRawRelease):
      return nil
    if entryIndexOut != nil:
      cast[ptr uint32](entryIndexOut)[] = bestIndex
  return bestScanResultEntry

proc scanu_rm_exist_ssid*(ssid: pointer, ssidLen: uint8) {.exportc, cdecl.} =
  ## The second argument is a signed cache index, not an SSID length.
  ## Complete removal before logging or freeing can refill the cache slot.
  var removal: tuple[inspected, matched: bool; frame: pointer; ssid: array[33, char]]
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let ssidResultEntryIndex = cast[int8](ssidLen)
    if ssid != nil and ssidResultEntryIndex >= 0 and
        ssidResultEntryIndex.int < SCANU_MAX_RESULT_ENTRIES:
      let ssidIndexResultEntry = addr scanu_env.entries[ssidResultEntryIndex.int]
      if ssidIndexResultEntry.valid != 0:
        removal.inspected = true
        let inputSsid = lengthPrefixedSsidView(ssid)
        let inputSsidLen = inputSsid.length
        if inputSsidLen <= 32 and inputSsidLen == scanu_env.filterSsidLen and
            c_memcmp(addr scanu_env.filterSsid[0], addr inputSsid.ssidBytes[0],
                     inputSsidLen.csize_t) == 0:
          removal.matched = true
          removal.frame = ssidIndexResultEntry.cachedRxuMgtInd
          for i in 0 ..< inputSsidLen.int:
            removal.ssid[i] = char(scanu_env.filterSsid[i])
          scanuClearCachedSsid(ssidIndexResultEntry)
          scanuClearCachedChannel(ssidIndexResultEntry)
          discard c_memset(ssidIndexResultEntry, 0, sizeof(ScanuResultEntry).csize_t)

  let startLogFn = getLogFunc(204)
  if startLogFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](startLogFn)(
      2, nil, "scanu.c", 1032, "start scanu_rm_exist_ssid \r\n")
  if not removal.inspected:
    return
  if removal.matched:
    let matchLogFn = getLogFunc(204)
    if matchLogFn != nil:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.}](matchLogFn)(
        2, nil, "scanu.c", 1043, "delete the existed ssid %s\r\n",
        cast[cstring](addr removal.ssid[0]))
    ke_msg_free_payload(removal.frame)
  let endLogFn = getLogFunc(204)
  if endLogFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](endLogFn)(
      2, nil, "scanu.c", 1046, "over scanu_rm_exist_ssid \r\n")

proc scanuDetachCachedScanResults(): array[SCANU_MAX_RESULT_ENTRIES, pointer] =
  let saved = irqSave()
  defer: irqRestore(saved)
  for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]
    result[scanResultSlotIndex] = scanResultEntry.cachedRxuMgtInd
    scanResultEntry.cachedRxuMgtInd = nil
    scanuClearCachedSsid(scanResultEntry)
    scanuClearCachedChannel(scanResultEntry)
    scanResultEntry.valid = 0
    scanResultEntry.rssi = -128'i8

proc scanu_cached_scanresult_clear*() {.exportc, cdecl.} =
  ## Clear all cached scan results in scanu_env.
  let retired = scanuDetachCachedScanResults()
  # All old ownership is private before the first free hook can refill a slot.
  for frame in retired:
    ke_msg_free_payload(frame)

proc scanuDetachRawScanFrames(keep: ptr ScanuResultEntry = nil):
    array[SCANU_MAX_RESULT_ENTRIES, pointer] =
  let saved = irqSave()
  defer: irqRestore(saved)
  for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]
    if scanResultEntry != keep:
      result[scanResultSlotIndex] = scanResultEntry.cachedRxuMgtInd
      scanResultEntry.cachedRxuMgtInd = nil

proc scanu_prune_scanresult_raw_frames() =
  ## Retain structured results while releasing their detached raw frame copies.
  let retired = scanuDetachRawScanFrames()
  for frame in retired:
    ke_msg_free_payload(frame)

proc scanu_prune_scanresult_raw_frames_except_bssid*(bssid: pointer) =
  ## Selection and detachment must observe the same cache contents.
  let retired = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let keepEntry =
      if macPtrIsSpecific(bssid): scanu_search_by_bssid(bssid)
      else: nil
    scanuDetachRawScanFrames(cast[ptr ScanuResultEntry](keepEntry))
  for frame in retired:
    ke_msg_free_payload(frame)

proc wifi_nimfw_release_scan_raw_cache*() {.exportc, cdecl.} =
  ## Release bulky cached raw scan frames while retaining structured scan
  ## result entries. Call before connect request allocation when a previous
  ## foreground scan may have filled the cache.
  scanu_prune_scanresult_raw_frames()

proc wifi_nimfw_prune_scan_raw_cache_for_ssid*(ssid: cstring,
                                               ssidLen: uint32)
    {.exportc, cdecl.} =
  ## Keep only the strongest cached raw scan frame for the target SSID.
  ## The connect selector still needs one raw frame to parse SSID/security IEs,
  ## but retaining every beacon/probe-response copy can exhaust the small WiFi
  ## message heap before the connect request is allocated.
  if ssid == nil or ssidLen == 0'u32 or ssidLen > 32'u32:
    return

  let retired = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    var bestScanResultEntry: ptr ScanuResultEntry = nil
    var bestRssi: int8 = -128
    for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
      let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]
      if scanResultEntry.valid == 0 or scanResultEntry.cachedRxuMgtInd == nil:
        continue
      let cachedRxuMgtIndView = rxuMgtIndAt(scanResultEntry.cachedRxuMgtInd)
      let totalLen = cachedRxuMgtIndView.frameLen
      let ieLen = if totalLen > 36'u16: totalLen.uint32 - 36'u32 else: 0'u32
      let ieStart = rxuMgtIndIeStart(scanResultEntry.cachedRxuMgtInd)
      let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
      if ssidIe == nil:
        continue
      let entrySsid = ssidIeAt(ssidIe)
      let matches =
        if entrySsid.ie.len == 0:
          scanuCachedSsidMatches(scanResultEntry, cast[pointer](ssid),
                                 ssidLen.uint8)
        elif entrySsid.ie.len.uint32 == ssidLen:
          c_memcmp(cast[pointer](ssid), addr entrySsid.ssidBytes[0],
                   ssidLen.csize_t) == 0
        else:
          false
      if not matches:
        continue
      if bestScanResultEntry == nil or scanResultEntry.rssi > bestRssi:
        bestScanResultEntry = scanResultEntry
        bestRssi = scanResultEntry.rssi
    scanuDetachRawScanFrames(bestScanResultEntry)
  for frame in retired:
    ke_msg_free_payload(frame)

proc scanu_raw_send_cfm*(result: pointer, destId: uint8) {.exportc, cdecl.} =
  ## Send raw frame send confirmation (16 instrs in blob).
  ## Signature: scanu_raw_send_cfm(result_ptr, dest_id). dest_id comes from
  ## the original request's srcId (blob passes a1 = saved_a3). For the
  ## synchronous call in scanu_raw_send_req_handler, result == nil.
  let msg = cast[ptr ScanuRawSendCfmPayload](
    ke_msg_alloc(SCANU_RAW_SEND_CFM, destId, TASK_SCANU,
                 ScanuRawSendCfmPayloadSize))
  if msg != nil:
    msg.result = cast[uint32](result)
    ke_msg_send(msg)

proc bestCachedScanuResult(searchData: pointer; searchLen: uint8;
                           freq: uint16; searchFlags: uint32): ptr ScanuResultEntry =
  let preferSecurity = (searchFlags and (1'u32 shl 9)) != 0
  let strictSecurity = preferSecurity and (searchFlags and (1'u32 shl 10)) != 0
  var best: ptr ScanuResultEntry
  var bestPreferred: ptr ScanuResultEntry
  for scanResultSlotIndex in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let scanResultEntry = addr scanu_env.entries[scanResultSlotIndex]
    if scanResultEntry.valid == 0:
      continue
    if not scanuCachedSsidMatches(scanResultEntry, searchData, searchLen):
      continue
    let channel = scanResultChannelPtr(scanResultEntry)
    if channel == nil:
      continue
    if freq != 0 and cast[ptr ScanChannelEntry](channel).prim20Freq != freq:
      continue
    if preferSecurity and scanuBssSecurityPreferred(scanResultEntry) and
        (bestPreferred == nil or scanResultEntry.rssi > bestPreferred.rssi):
      bestPreferred = scanResultEntry
    if best == nil or scanResultEntry.rssi > best.rssi:
      best = scanResultEntry
  if bestPreferred != nil or strictSecurity: bestPreferred else: best

proc scanuResultSlotIndex(entry: ptr ScanuResultEntry): uint32 {.inline.} =
  for index in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if entry == addr scanu_env.entries[index]:
      return index.uint32
  0xFFFFFFFF'u32

# ###########################################################################
#                   SM: Station State Machine
# ###########################################################################

proc sm_init*() {.exportc, cdecl.} =
  ## Initialize SM module. Pinned sm_init clears only sm_env[0]; here an
  ## attempt or teardown in progress is dropped, and the SM_CONNECT_REQ and
  ## SM_CONNECT_IND it parked are freed (smAbandon).
  smAbandon()
  smConnecting = false
  smAuthRetryLimit = 4
  smReconnectTrigger = false
  let sm = smEnvView()
  sm.deauthPending = 1
  sm.authRetryLimit = 4

proc sm_get_bss_params*(selectedBssResultOut: ptr pointer, selectedBssChannelOut: ptr pointer) {.exportc, cdecl.} =
  ## Get BSS parameters from scan results.
  ## From blob (111 instrs): loads sm_env[0] connect info, searches scanu results
  ## by BSSID/SSID, fills selectedBssResultOut with scan result ptr and selectedBssChannelOut with
  ## channel frequency pointer. The archive reports status through those outputs.
  if selectedBssResultOut != nil: selectedBssResultOut[] = nil
  if selectedBssChannelOut != nil: selectedBssChannelOut[] = nil
  if selectedBssResultOut == nil or selectedBssChannelOut == nil: return
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil: return
  let vifIdx = connectInfoView(connInfo).vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx).vifIdx != vifIdx or
      vifChannelForIdx(vifIdx).vifType != VIF_TYPE_STA: return
  # The log callbacks below run host code: the results are published only
  # while SM's operation and the scan that produced them are still current.
  let stamp = smOwn.op.serial
  let indication = sm.connectIndMsg
  let scanEpoch = scanuRequestEpoch
  template current(): bool =
    opCurrent(smOwn.op, stamp) and sm.connectIndMsg == indication and
      scanuRequestEpoch == scanEpoch
  var snapshot = connectInfoView(connInfo)[]
  let ci = addr snapshot
  snapshot.ssid[connectInfoSsidLen(ci).int] = 0
  var selectedBssResult, selectedBssChannel: pointer
  var selectedAuthEntry: ptr ScanuResultEntry
  var selectedEntrySnapshot: ScanuResultSnapshot
  var selectedIndex: uint32
  var publishIndex = false
  # Keep outputs and connection changes private until the final callback returns.
  defer:
    if current() and (selectedAuthEntry == nil or
        scanuResultCurrent(selectedEntrySnapshot)):
      if selectedAuthEntry != nil:
        configureSelectedBssAuth(selectedAuthEntry, connectInfoView(connInfo))
      if current():
        if publishIndex: sm.scanResultIndex = selectedIndex
        selectedBssResultOut[] = selectedBssResult
        selectedBssChannelOut[] = selectedBssChannel
  let logFn = cast[proc(fmt: cstring) {.cdecl, varargs.}](blOpsFunc(4))
  if not current(): return
  if logFn != nil:
    logFn("===start sm_get_bss_params===\r\n")
    if not current(): return

  let bssidPtr = cast[pointer](addr ci.bssid[0])
  nimFwDbgBssIn =
    connectInfoSsidLen(ci).uint32 or
    (scanu_env.resultCount.uint32 shl 8) or
    (scanu_env.directedFound.uint32 shl 24)
  when defined(bl808WifiConnectTrace):
    let ssidPrefixWord =
      ci.ssid[0].uint32 or (ci.ssid[1].uint32 shl 8) or
      (ci.ssid[2].uint32 shl 16) or (ci.ssid[3].uint32 shl 24)
    let bssidPrefixWord =
      ci.bssid[0].uint32 or (ci.bssid[1].uint32 shl 8) or
      (ci.bssid[2].uint32 shl 16) or (ci.bssid[3].uint32 shl 24)
    nimFwConnectTrace2U32("[WIFI-CT] bss_in ",
                          connectInfoSsidLen(ci).uint32 or
                            (scanu_env.resultCount.uint32 shl 8) or
                            (scanu_env.directedFound.uint32 shl 24),
                          ssidPrefixWord)
    if not current(): return
    nimFwConnectTrace2U32("[WIFI-CT] bss_bssid ", bssidPrefixWord,
                          ci.bssid[4].uint32 or (ci.bssid[5].uint32 shl 8))
    if not current(): return

  # Log the BSSID we're searching for (3 iterations logging pairs)
  if logFn != nil:
    for bssidPairLogIndex in 0'u32 ..< 3'u32:
      let index = bssidPairLogIndex.int * 2
      let pair = ci.bssid[index].uint32 or (ci.bssid[index + 1].uint32 shl 8)
      logFn("bssid[%d] = 0x%x\r\n", bssidPairLogIndex, pair)
      if not current(): return

  # Check if BSSID is set (not all zeros and not starting with bit 0 set)
  let bssidFirstByte = ci.bssid[0]
  var searchBySsid = false
  if (bssidFirstByte and 1) != 0:
    # BSSID has group bit set -- search by SSID instead
    searchBySsid = true
  else:
    var bssidAllZero = true
    for bssidByteIndex in 0 ..< 6:
      if ci.bssid[bssidByteIndex] != 0:
        bssidAllZero = false
        break
    if bssidAllZero:
      searchBySsid = true
    else:
      # Search by BSSID
      if logFn != nil:
        logFn("search bssid \r\n")
        if not current(): return

      # Call scanu_search_by_bssid (blob's 2-instr trampoline that
      # tail-calls scanu_find_result(bssid, 0)). Matching the blob call
      # here keeps the call graph parity intact.
      selectedBssResult = cast[pointer](addr connectInfoView(connInfo).bssid[0])
      let scanResult = scanu_search_by_bssid(bssidPtr)
      if not current(): return

      if scanResult != nil:
        # Get channel pointer from scan result offset 8
        let bssidResultEntry = scanuResultAt(scanResult)
        selectedAuthEntry = bssidResultEntry
        let scanResultChannel = scanResultChannelPtr(bssidResultEntry)
        selectedBssChannel = scanResultChannel
        selectedEntrySnapshot = scanuCaptureResult(bssidResultEntry)

        # Log and return
        if logFn != nil:
          logFn("===end sm_get_bss_params===\r\n")
        return

      if connectInfoHasChannelHint(ci):
        selectedBssChannel = connectInfoChannelHint(connInfo)

  if searchBySsid:
    # BSSID not specified -- search by SSID.
    if logFn != nil:
      logFn("search ssid = %s\r\n", cast[cstring](addr ci.ssid[0]))
      if not current(): return

    var resultIndex: int32 = -1
    var searchSlot {.noinit.}: ScanSsidSlotView
    connectInfoFillSsidSlot(addr searchSlot, ci)
    let hintedFreq =
      if connectInfoHasChannelHint(ci): connectInfoChannelFrequency(ci)
      else: 0'u16
    let searchData = cast[pointer](addr searchSlot.ssidBytes[0])
    let hasHintedFreq = hintedFreq != 0'u16 and hintedFreq != 0xFFFF'u16
    let hintedResult =
      if hasHintedFreq:
        bestCachedScanuResult(searchData, searchSlot.length, hintedFreq,
                              ci.channelDuration)
      else:
        nil
    let ssidResult =
      if hintedResult != nil:
        hintedResult
      elif hasHintedFreq:
        nil
      else:
        cast[ptr ScanuResultEntry](
          scanu_search_by_ssid(addr searchSlot, cast[pointer](addr resultIndex)))
    if not current(): return
    if ssidResult != nil:
      if resultIndex >= 0 or hintedResult != nil:
        selectedBssResult = ssidResult
        selectedIndex =
          if hintedResult != nil: scanuResultSlotIndex(hintedResult)
          else: resultIndex.uint32
        publishIndex = selectedIndex != 0xFFFFFFFF'u32
      let ssidResultEntry = scanuResultAt(ssidResult)
      selectedAuthEntry = ssidResultEntry
      let ssidResultChannel = scanResultChannelPtr(ssidResultEntry)
      selectedBssChannel = ssidResultChannel
      selectedEntrySnapshot = scanuCaptureResult(ssidResultEntry)
    if logFn != nil:
      logFn("result ssid index = %d\r\n", resultIndex)
      if not current(): return
    nimFwDbgBssSsidResult =
      cast[uint32](cast[uint](ssidResult)) or
        ((resultIndex.uint32 and 0xFF'u32) shl 24)
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] bss_ssid_result ",
                            cast[uint32](cast[uint](ssidResult)),
                            cast[uint32](resultIndex))
      if not current(): return
    if ssidResult == nil:
      let directed =
        if hintedFreq == 0'u16 and scanu_env.directedFound != 0:
          bestCachedScanuResult(searchData, searchSlot.length, 0, ci.channelDuration)
        else:
          nil
      if directed != nil:
        selectedBssResult = cast[pointer](directed)
        selectedAuthEntry = directed
        selectedBssChannel = scanResultChannelPtr(directed)
        selectedEntrySnapshot = scanuCaptureResult(directed)
        selectedIndex = scanuResultSlotIndex(directed)
        publishIndex = selectedIndex != 0xFFFFFFFF'u32
      nimFwDbgBssDirected =
        cast[uint32](cast[uint](directed)) or
        (scanu_env.directedFound.uint32 shl 24)
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] bss_directed ",
                              cast[uint32](cast[uint](directed)),
                              scanu_env.directedFound.uint32)
        if not current(): return
      if directed == nil and connectInfoHasChannelHint(ci):
        selectedBssChannel = connectInfoChannelHint(connInfo)

  if selectedBssChannel == nil:
    if connectInfoHasChannelHint(ci):
      selectedBssChannel = connectInfoChannelHint(connInfo)

  # Final log
  nimFwDbgBssOut =
    cast[uint32](cast[uint](selectedBssResult)) xor
    (cast[uint32](cast[uint](selectedBssChannel)) shl 1)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] bss_out ",
                          cast[uint32](cast[uint](selectedBssResult)),
                          cast[uint32](cast[uint](selectedBssChannel)))
    if not current(): return
  if logFn != nil:
    logFn("===end sm_get_bss_params===\r\n")
  return

proc smSubmitScanRequest(localMac, targetBssid, channelInfo: pointer;
                         joining: bool; joinFlag: uint32) =
  ## Send the attempt's scan (state 1) or join (state 2) request. Unless no
  ## attempt is live, this ends in the new state or in sm_connect_ind.
  let sm = smEnvView()
  let connectionPtr = sm.connectInfo
  if connectionPtr == nil or sm.connectIndMsg == nil or smOwn.teardown != tdNone: return
  template invalidInput() =
    sm_connect_ind(WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL.uint16, 0xFFFF)
  let vifIdx = connectInfoView(connectionPtr).vifIdx
  # An FT request (authType 2) is admitted on a VIF of any type.
  if localMac == nil or (joining and (targetBssid == nil or channelInfo == nil)) or
      vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx).vifIdx != vifIdx or
      vifChannelForIdx(vifIdx).vifType != VIF_TYPE_STA:
    invalidInput()
    return

  var prepared: ScanuStartReqPayload
  prepared.localMac = cast[ptr array[6, uint8]](localMac)[]
  if targetBssid != nil:
    prepared.bssid = cast[ptr array[6, uint8]](targetBssid)[]
  else:
    for value in prepared.bssid.mitems: value = 0xFF
  let connection = connectInfoView(connectionPtr)
  connectInfoFillSsidSlot(scanSsidSlot(addr prepared, 0), connection)
  prepared.vifIdx = vifIdx
  prepared.flags = connection.channelDuration
  prepared.scanType = 1
  if channelInfo != nil:
    prepared.channelList[0] = cast[ptr ScanChannelEntry](channelInfo)[]
    prepared.channelCount = 1
    if joining and joinFlag != 0:
      prepared.channelList[0].flags = prepared.channelList[0].flags or 1
  else:
    let config = scanuChannelConfig()
    if config.count.int > config.entries.len:
      invalidInput()
      return
    for index in 0 ..< config.count.int:
      if (config.entries[index].flags and 2) == 0:
        if prepared.channelCount.int >= prepared.channelList.len:
          invalidInput()
          return
        prepared.channelList[prepared.channelCount.int] = config.entries[index]
        inc prepared.channelCount
    if prepared.channelCount == 0:
      invalidInput()
      return
  for channelIndex in 0 ..< prepared.channelCount.int:
    let channel = prepared.channelList[channelIndex]
    if not scanChannelValid(channel.band, channel.prim20Freq):
      invalidInput()
      return

  let messageId = if joining: SCANU_JOIN_REQ else: SCANU_START_REQ
  let message = ke_msg_try_alloc(messageId, TASK_SCANU, TASK_SM, ScanuStartReqPayloadSize)
  if message == nil:
    sm_connect_ind(WLAN_FW_JOIN_NETWORK_FAILURE.uint16, 0xFFFF)
    return
  scanuStartReqView(message)[] = prepared
  if joining: sm.joinBssFlag = cast[uint8](joinFlag)
  when defined(bl808WifiDiagColdScan):
    nimFwDbgColdScanFlow[0] = messageId.uint32 + 1
  smGo(if joining: SmWaitingState else: SmScanningState)
  smSend(message)

proc sm_scan_bss*(bssid: pointer, ssid: pointer, chanInfo: pointer) {.exportc, cdecl.} =
  smSubmitScanRequest(bssid, ssid, chanInfo, false, 0)

proc sm_join_bss*(bssid: pointer, ssid: pointer, joinInfo: pointer, flag: bool) {.exportc, cdecl.} =
  smSubmitScanRequest(bssid, ssid, joinInfo, true, flag.uint32)

proc smPrepareChannelContext(connInfo: pointer; chanReq: var ChanCtxtDefView): bool =
  if connInfo == nil: return false
  let vifIdx = connectInfoView(connInfo).vifIdx
  if vifIdx >= MAX_VIFS.uint8: return false
  let vif = vifChannelForIdx(vifIdx)
  let chanDef = vif.operChan
  if chanDef == nil: return false
  let chan = cast[ptr ScanChannelEntry](chanDef)
  chanReq = default(ChanCtxtDefView)
  chanReq.band = chan.band
  chanReq.chanType = vifBssStatus(vif).phyBandwidth
  chanReq.primFreq = chan.prim20Freq
  chanReq.centerFreq1 = vifChannelCenterFreq1(vif, chan.prim20Freq)
  chanReq.centerFreq2 = vifChannelCenterFreq2(vif)
  chanReq.txPower = cast[uint8](chan.txPower)
  nimFwDbgSmChanCtxPtrs = pointerAddrU32(cast[pointer](vif)) xor
    pointerAddrU32(cast[pointer](chanDef))
  true

proc smAddPreparedChannelContext(chanReq: var ChanCtxtDefView; output: ptr uint8;
                                 lease: ptr ChanCtxtLease = nil): uint8 =
  if output == nil: return 1
  nimFwDbgSmChanCtxReq0 = chanReq.primFreq.uint32 or
    (chanReq.centerFreq1.uint32 shl 16)
  nimFwDbgSmChanCtxReq1 = chanReq.centerFreq2.uint32 or
    (chanReq.band.uint32 shl 16) or
    (chanReq.chanType.uint32 shl 24) or
    (chanReq.txPower.uint32 shl 28)
  let result = if lease == nil: chan_ctxt_add(cast[pointer](addr chanReq), output)
    else: chanLeaseAcquire(addr chanReq, lease[])
  if result == 0 and lease != nil: output[] = lease.index
  nimFwDbgSmChanCtxResult = result.uint32
  return result

proc sm_add_chan_ctx*(chanIndex: ptr uint8): uint8 {.exportc, cdecl, discardable.} =
  ## Prepare a channel context and return its index through the vendor output.
  var prepared: ChanCtxtDefView
  if not smPrepareChannelContext(smEnvView().connectInfo, prepared): return 1
  smAddPreparedChannelContext(prepared, chanIndex)

proc sm_send_next_bss_param*() {.exportc, cdecl.} =
  ## Send the BSS parameter batch's next request (station_bss.nim).
  smBssNext()

proc sm_set_bss_param*() {.exportc, cdecl.} =
  ## Start the association's BSS parameter batch, state 4 (station_bss.nim).
  smBssBegin()

proc sm_handle_connection*(vifIdx: uint8, status: uint16,
    callbackCtx: pointer, failureFn: pointer) {.exportc, cdecl.} =
  ## Handle connection state change — send deauthentication frame (434 bytes in blob).
  ## Blob call sequence: ke_state_set(SM,10), txl_frame_get(0x200),
  ##   tpc_update_frame_tx_power, memcpy x3 (DA/SA/BSSID), txl_get_seq_ctrl,
  ##   mfp_protect_mgmt_frame, txu_cntrl_protect_mgmt_frame (conditional),
  ##   me_build_deauthenticate(bodyStart, 3), mfp_add_mgmt_mic (conditional),
  ##   txl_frame_push(frame, 3). On fail: failureFn(vifEntry, status, 3).
  ## Here state 10 is entered by smDeauthWait once the frame is built, just
  ## before the push, and the frame carries the wait's stamp, not the VIF.
  ## The build commits only while SM's operation is the one it started in
  ## (station_tx_build.nim).
  if vifIdx.int >= MAX_VIFS:
    return
  # A teardown in progress already ends this link.
  if smOwn.teardown != tdNone: return
  let vif = vifChannelForIdx(vifIdx)
  # Early exit unless this is a STA VIF (blob: lbu a5,86(s3); bnez)
  if vif.vifIdx != vifIdx or vif.vifType != VIF_TYPE_STA:
    return
  let stamp = smOwn.op.serial
  var frame: pointer
  template notifyFailure(): untyped =
    if frame != nil: txl_frame_release(frame, false)
    if opCurrent(smOwn.op, stamp) and failureFn != nil:
      cast[proc(a: pointer; b, c: uint16) {.cdecl.}](failureFn)(
        cast[pointer](vif), status, 3'u16)
    return

  # Save staIdx from VIF before frame alloc (blob: lbu s8,96(s3))
  let staIdx = vif.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    notifyFailure()

  # Allocate TX frame (blob: txl_frame_get(0x200) = li a0,512)
  frame = txl_frame_get(512)
  if frame == nil:
    notifyFailure()
  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil or desc.hwDesc == nil:
    notifyFailure()

  # Update TX power (blob: tpc_update_frame_tx_power(vifEntry, frame))
  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  # Get link descriptor from frame (blob: lw s1,108(s0) -> s1 = frame[108]).
  # The MAC header buffer lives in link.macHeader (linkDesc+348).
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)
  let sta = staInfoForIdx(staIdx)
  let staMac = cast[pointer](addr sta.macAddr[0])

  # Set frame control byte (blob: li a5,-64 = 0xC0; sb a5,348(s1))
  hdr.frameControl = 0x00C0'u16
  hdr.duration = 0

  # DA from sta_info_tab+4 (blob: memcpy dst=s1+348+4 -> macHdr+4)
  discard c_memcpy(addr hdr.addr1[0], staMac, 6.csize_t)
  # SA from vifEntry+80 (blob: memcpy dst=s1+348+10 -> macHdr+10)
  discard c_memcpy(addr hdr.addr2[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)
  # BSSID from sta_info_tab+4 (blob: memcpy dst=s1+348+16 -> macHdr+16)
  discard c_memcpy(addr hdr.addr3[0], staMac, 6.csize_t)

  # Get sequence control (blob: txl_get_seq_ctrl at 0xBE)
  hdr.seqCtrl = txl_get_seq_ctrl()

  # Store VIF/STA info (blob: sb s7,47(s0); sb zero,98,100; sb a5,49(s0))
  desc.vifIdx = vifIdx
  desc.hdrLen = 0
  desc.secTailLen = 0
  desc.staInfoIdx = staIdx

  # MFP protection (blob: mfp_protect_mgmt_frame at 0xFE)
  let fc = hdr.frameControl
  let mfpResult = mfp_protect_mgmt_frame(frame, fc.uint32)

  # Track body start offset (macHdr + secHdrLen)
  var bodyOffset: uint = 24  # base MAC header size
  let macHdrPtr = cast[pointer](hdr)

  # Conditional: txu_cntrl_protect_mgmt_frame if mfp returned 1
  if mfpResult == 1:
    txu_cntrl_protect_mgmt_frame(frame, macHdrPtr, 24)
    if desc.hdrLen != 8 or desc.secTailLen != 8:
      notifyFailure()
    # Read security header length added (blob: lbu s2,98(s0); addi s2,s2,24)
    bodyOffset = desc.hdrLen.uint + 24

  # Build deauthentication body (blob: me_build_deauthenticate(macHdr+bodyOffset, 3))
  let bodyStart = cast[pointer](addr link.macHeader[bodyOffset])
  let deauthLen = me_build_deauthenticate(bodyStart, 3)
  var totalLen = bodyOffset + deauthLen.uint

  # Conditional: mfp_add_mgmt_mic if mfp returned 2
  if mfpResult == 2:
    let micLen = mfp_add_mgmt_mic(frame, macHdrPtr, totalLen.uint32)
    if micLen != 18:
      notifyFailure()
    totalLen = totalLen + micLen.uint
  elif mfpResult == 1:
    # If mfp==1, check for CCMP/TKIP tail (blob: lbu a5,100(s0); add s2,s2,a5)
    let secTailLen = desc.secTailLen
    totalLen = totalLen + secTailLen.uint

  # TX descriptor setup (blob: lw a4,112(s0); lw a5,20(a4); ...)
  if totalLen > 512:
    notifyFailure()
  desc.frameLen = totalLen.uint16
  desc.seqPassthrough = totalLen.uint16
  if desc.hwDesc != nil:
    let txDesc = hostTxHwDescAt(desc.hwDesc)
    let payloadLen = txDesc.payloadStart
    txDesc.payloadEnd = payloadLen - 1 + totalLen.uint32
    txDesc.frameLen = totalLen.uint32 + 4

  # Commit. txl_frame_get may have run SM code (station_tx_build.nim).
  if not opCurrent(smOwn.op, stamp):
    txl_frame_release(frame, false)
    return
  # Enter the deauthentication wait, then push (blob: txl_frame_push(frame, 3)).
  # The callback and its argument sit at frame+208/212 (blob: sw s6,208(s0)).
  let wait = smDeauthWait(vifIdx, callbackCtx)
  if wait == 0:
    txl_frame_release(frame, false)
    return
  desc.callback = callbackCtx
  desc.callbackArg = opStampEnv(wait)
  if txl_frame_push(frame, 3) != 0:
    return
  # A refused push has already consumed the descriptor and runs no callback,
  # so the wait ends here. A successful push owns it until its confirmation.
  if smDeauthConfirmed(opStampEnv(wait)) and failureFn != nil:
    cast[proc(a: pointer; b, c: uint16) {.cdecl.}](failureFn)(
      cast[pointer](vif), status, 3'u16)

proc sm_disconnect_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.} =
  ## End the link on this VIF; SM_DISCONNECT_IND follows the cleanup. The
  ## vendor clears SA Query here, then deletes the resources; smTeardown
  ## does both. Also the end of a disconnect's deauthentication wait.
  inc nimFwDbgDisconnectProcess
  smTeardown(param, disconnected = true, status = statusCode, reason = reasonCode)

proc sm_disconnect_deauth_cfm*(param: pointer, txStatus: uint32) {.exportc, cdecl.} =
  ## Confirmation that deauth frame was sent during disconnect.
  ## From blob (5 instrs): li a2,3; li a1,19; jr sm_disconnect_process
  ## Tail-calls sm_disconnect_process(param, WLAN_FW_DISCONNECT_BY_USER_WITH_DEAUTH, 3).
  ## Any status ends the wait, as in the blob; param is the wait's stamp.
  discard txStatus
  if smDeauthConfirmed(param): sm_disconnect_process(smDeauthVif(), 19, 3)

proc smConnectEnd(statusCode, reasonCode: uint16) =
  ## End the attempt and send its connect indication to host (the body of
  ## the blob's sm_connect_ind, 131 instrs): loads sm_env[0] and vif_info_tab
  ## to build a full SM_CONNECT_IND message with BSSID, aid, channel info and
  ## VHT capabilities. A failure tears the attempt down first, and the
  ## indication is sent when the cleanup completes.
  ##
  ## a0=statusCode(->s8), a1=reasonCode(->s9)
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  # Blob re-uses the 860-byte message that sm_connect_req_handler parked at
  # sm_env[4] — it is NOT a fresh ke_msg_alloc here. Nim was allocating a
  # new buffer, which leaked the prior one AND sent an uninitialised msg
  # downstream. The blob's smEnvSecond pointer and the "msg" pointer are
  # the same object.
  let msg = sm.connectIndMsg
  if connInfo == nil or msg == nil or connectInfoView(connInfo).vifIdx >= MAX_VIFS.uint8:
    # No attempt is left to report on; a deauthentication wait still ends.
    if smOwn.teardown == tdDeauthWait: smTeardown(smDeauthVif())
    return
  let vifIdx = connectInfoView(connInfo).vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let vifEpoch = rxVifEpochs[vifIdx]
  let ind = smConnectIndPayloadAt(msg)
  let msgHdr = keMsgHdrFromPayload(msg)
  msgHdr.id = SM_CONNECT_IND_MSG
  msgHdr.destId = TASK_API
  msgHdr.srcId = TASK_SM

  ind.vifIdx = vifIdx

  discard c_memcpy(addr ind.bssid[0], addr vif.bssid[0], 6.csize_t)

  ind.aid = vif.staIdx

  # Copy channel info from vif+64 pointer
  let chanPtr = vif.chanCtxt
  ind.channelStatus = 0

  # Fill channel and VHT capability fields from chanPtr if available
  if chanPtr != nil:
    let chan = chanCtxtAt(chanPtr)
    ind.chanBand = chan.channel.band
    ind.chanPrimFreq = chan.channel.primFreq
    ind.chanType = chan.channel.chanType
    ind.chanCenterFreq1 = chan.channel.centerFreq1.uint32
    ind.chanCenterFreq2 = chan.channel.centerFreq2.uint32
  else:
    ind.chanBand = 0
    ind.chanPrimFreq = 0
    ind.chanCenterFreq1 = 0
    ind.chanCenterFreq2 = 0
    ind.chanType = 0

  let hasWmm = ind.hasWmm
  var qosFlag: uint8 = 0
  if hasWmm != 0:
    qosFlag = vif.wmmAcFlags

  ind.qosFlag = qosFlag

  ind.securityStatus = 0

  ind.statusCode = statusCode
  ind.reasonCode = reasonCode

  if chanPtr != nil:
    sm.primaryFreq = ind.chanPrimFreq
    sm.centerFreq = ind.chanCenterFreq1.uint16
  if statusCode != 0:
    let bssIdx = cast[int32](sm.scanResultIndex)
    if bssIdx >= 0:
      sm.scanResultIndex = 0xFFFFFFFF'u32
      scanu_rm_exist_ssid(connInfo, cast[uint8](bssIdx and 0xFF))
    smTeardown(vif, msg)
    return

  # Detach the completed attempt before allocator or host callbacks run.
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  smGo(SmIdleState)
  ke_msg_free(keMsgHdrFromPayload(connInfo))
  if rxVifEpochs[vifIdx] != vifEpoch or sm.connectInfo != nil or
      sm.connectIndMsg != nil or ke_state_get(TASK_SM) != SmIdleState:
    ke_msg_free(keMsgHdrFromPayload(msg))
    return
  ke_msg_send(msg)

proc sm_connect_ind*(statusCode: uint16, reasonCode: uint16) {.exportc, cdecl, noinline.} =
  ## The end of the connection attempt. An attempt is live from its admission
  ## until its teardown starts; any other call does nothing.
  if smOwn.teardown == tdNone: smConnectEnd(statusCode, reasonCode)

proc sm_connect_abort_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.} =
  ## Process a connect abort request.
  ## From blob (5 instrs): shuffles args (a0=a1, a1=a2) and tail-calls sm_connect_ind.
  ## It ends an abort's deauthentication wait, so it calls smConnectEnd.
  smConnectEnd(statusCode, reasonCode)

proc sm_connect_abort_deauth_cfm*(param: pointer, txStatus: uint32) {.exportc, cdecl.} =
  ## Confirmation of deauth during connect abort.
  ## From blob (5 instrs): li a1,3; li a0,23; jr sm_connect_ind
  ## Tail-calls sm_connect_ind(WLAN_FW_CONNECT_ABORT_BY_USER_WITH_DEAUTH=23, 3).
  ## Any status ends the wait, as in the blob; param is the wait's stamp.
  discard txStatus
  if smDeauthConfirmed(param): smConnectEnd(23, 3)

proc sm_deauth_send*() {.exportc, cdecl.} =
  ## Send a deauthentication frame to the attempt's AP. Nothing waits for it:
  ## it has no confirmation callback and changes no SM state. Like the other
  ## builders it is pushed only while SM's operation is the one it started in
  ## (station_tx_build.nim).
  ## From blob (93 instrs): loads sm_env[0], gets vifIdx from connInfo+59,
  ## computes VIF entry, allocates 512-byte frame, builds deauth MAC header
  ## with addresses from VIF, calls me_build_deauthenticate, sets TX descriptor
  ## fields, and pushes frame via txl_frame_push(frame, 3).
  let connection = smEnvView().connectInfo
  if connection == nil: return
  let vifIdx = connectInfoView(connection).vifIdx
  if vifIdx >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifIdx != vifIdx or vif.vifType != VIF_TYPE_STA: return
  let staIdx = vif.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return
  let sta = staInfoForIdx(staIdx)
  let bssidPtr = cast[pointer](addr sta.macAddr[0])
  let stamp = smOwn.op.serial
  # Allocate 512-byte frame buffer (blob: txl_frame_get, NOT ke_msg_alloc)
  let frame = txl_frame_get(512)
  if frame == nil:
    return
  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil or desc.hwDesc == nil:
    txl_frame_release(frame, false)
    return
  # Blob prepares TX power before using the frame body pointer.
  tpc_update_frame_tx_power(cast[pointer](vif), frame)
  # Build deauth MAC header at frameBody+348.
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)
  hdr.frameControl = 0x00C0'u16
  hdr.duration = 0
  # DA and BSSID come from sta_info_tab[staIdx]+4; SA comes from VIF+80.
  discard c_memcpy(addr hdr.addr1[0], bssidPtr, 6.csize_t)
  discard c_memcpy(addr hdr.addr2[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)
  discard c_memcpy(addr hdr.addr3[0], bssidPtr, 6.csize_t)
  # Sequence control (blob: txl_get_seq_ctrl)
  hdr.seqCtrl = txl_get_seq_ctrl()
  # Frame metadata
  desc.callbackArg = cast[pointer](vif)
  desc.callback = nil
  desc.vifIdx = vif.vifIdx
  desc.staInfoIdx = staIdx
  desc.hdrLen = 0
  desc.secTailLen = 0
  # Build deauth body
  let bodyPtr = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  let deauthLen = me_build_deauthenticate(bodyPtr, 3)
  # Set TX descriptor lengths on the HW descriptor pointed to by frame+112.
  let txDesc = hostTxHwDescAt(desc.hwDesc)
  let payloadLen = txDesc.payloadStart
  # From blob: total = payloadLen + 23 + txl_frame_push_arg
  let bodyLen = deauthLen  # actual body length from me_build_deauthenticate return
  txDesc.payloadEnd = payloadLen + 23 + bodyLen
  txDesc.frameLen = bodyLen + 28
  desc.frameLen = (bodyLen + 24).uint16
  desc.seqPassthrough = desc.frameLen
  when defined(bl808WifiConnectTrace):
    let hdrWords = cast[ptr UncheckedArray[uint32]](hdr)
    nimFwConnectTrace2U32("[WIFI-CT] deauth_tx ",
                          vifIdx.uint32 or (staIdx.uint32 shl 8),
                          vif.vifIdx.uint32)
    nimFwConnectTrace2U32("[WIFI-CT] deauth_hdr0 ",
                          hdrWords[0],
                          hdrWords[1])
    nimFwConnectTrace2U32("[WIFI-CT] deauth_hdr1 ",
                          hdrWords[2],
                          hdrWords[3])
    nimFwConnectTrace2U32("[WIFI-CT] deauth_hdr2 ",
                          hdrWords[4],
                          hdrWords[5])
    nimFwConnectTrace2U32("[WIFI-CT] deauth_len ",
                          bodyLen,
                          txDesc.frameLen)
  # txl_frame_get may have run SM code (station_tx_build.nim).
  if not opCurrent(smOwn.op, stamp):
    txl_frame_release(frame, false)
    return
  discard txl_frame_push(frame, 3)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_auth_send(unsigned short, void*);".}
proc sm_auth_send*(authSeqNum: uint16, challenge: pointer) {.exportc, cdecl.} =
  ## Send an authentication frame (166 instructions in blob).
  ##
  ## Register map: s0=frame s1=frame_body(desc+108) s2=bodyLen s3=sm_env[0]
  ##   s4=sm_env s5=authSeqNum(a0) s6=challenge(a1) s7=bssid_ptr(sta+4)
  ##   s8=secondaryIeLen
  ##
  ## Steps:
  ##   1. Load connect info from sm_env[0], extract vifIdx from info[59]
  ##   2. Compute VIF/STA entries, get BSSID from sta_info_tab[staIdx]+4
  ##   3. Allocate 512-byte frame via txl_frame_get
  ##   4. Call me_build_authenticate to build auth body
  ##   5. Copy BSSID into frame header: DA, SA, BSSID (3 x memcpy of 6 bytes)
  ##   6. Set sequence number, frame type=0xB0
  ##   7. Shared-key seq 3: protect with WEP and append challenge text IE
  ##   8. Compute final lengths, set TX descriptor, push frame
  ## Here the frame is built in one pass, then SM enters state 6, arms the
  ## response deadline and pushes (station_tx_build.nim).
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil: return
  let ci = connectInfoView(connInfo)
  let stamp = smOwn.op.serial
  var frame: pointer
  template fail(status: uint16) =
    if frame != nil: txl_frame_release(frame, false)
    if opCurrent(smOwn.op, stamp): sm_connect_ind(status, 0xFFFF)
    return

  let vifIdx = ci.vifIdx
  var staIdx: uint8
  var authBssid: MacAddrView
  if not smJoinPeer(vifIdx, staIdx, authBssid):
    fail(WLAN_FW_AUTHENTICATION_FAIILURE.uint16)
  let vif = vifChannelForIdx(vifIdx)
  let bssidPtr = cast[pointer](addr authBssid.bytes[0])
  when defined(bl808WifiPreAuthVifActive):
    if vif != nil:
      vif.state = 1
  let vifTxSaSource = ensureVifMgmtMac(vif)
  var authOwn = macAddrAt(vifTxSaSource)[]
  let vifTxSa = cast[pointer](addr authOwn.bytes[0])
  when defined(bl808WifiAuthHwWorkaround):
    regWrite(MACHW_BASE + 0x010'u, (addr authOwn).lowLe)
    regWrite(MACHW_BASE + 0x014'u, (addr authOwn).highLe)
    regWrite(MACHW_BASE + 0x01C'u, 0x100'u32)
  nimFwDbgMacHwLo = regRead(MACHW_BASE + 0x010'u)
  nimFwDbgMacHwHi = regRead(MACHW_BASE + 0x014'u)
  when defined(bl808WifiAuthHwWorkaround):
    regWrite(MACHW_BASE + 0x020'u, (addr authBssid).lowLe)
    regWrite(MACHW_BASE + 0x024'u, (addr authBssid).highLe)
  if vif != nil:
    vif.currentBssid[0] = authBssid.bytes[0]
    vif.currentBssid[1] = authBssid.bytes[1]
    vif.currentBssid[2] = authBssid.bytes[2]
    vif.currentBssid[3] = authBssid.bytes[3]
    vif.currentBssid[4] = authBssid.bytes[4]
    vif.currentBssid[5] = authBssid.bytes[5]
  nimFwDbgBssidHwLo = regRead(MACHW_BASE + 0x020'u)
  nimFwDbgBssidHwHi = regRead(MACHW_BASE + 0x024'u)

  # Read auth parameters from connect info
  when defined(bl808WifiForceSaeAuth):
    ci.authType = 3
  let authAlgo = ci.authType
  nimFwDbgSaeAuthAlgo = authAlgo.uint32
  let responseDelay = if sm.connectFlags != 0 and authAlgo != 3:
      0x1E000'u32
    else: 0x7D000'u32
  var challengeCopy: array[128, uint8]
  if challenge != nil:
    discard c_memcpy(addr challengeCopy[0], challenge, challengeCopy.len.csize_t)
  let authChallenge = if challenge != nil: addr challengeCopy[0] else: nil

  # Allocate frame buffer (512 bytes)
  frame = txl_frame_get(512)
  if frame == nil:
    # Vendor sm_auth_send+0x1e4 reports allocation failure, not a timeout.
    fail(WLAN_FW_TX_AUTH_FRAME_ALLOCATE_FAIILURE)
  # txl_frame_get can run SM code; an attempt that ended has freed connInfo.
  if not opCurrent(smOwn.op, stamp): fail(0)
  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil or desc.hwDesc == nil:
    fail(WLAN_FW_TX_AUTH_FRAME_ALLOCATE_FAIILURE)

  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Build auth frame header.
  hdr.frameControl = 0x00B0'u16
  hdr.duration = 0

  # Copy DA (6 bytes) from BSSID to frame body+352
  discard c_memcpy(addr hdr.addr1[0], bssidPtr, 6)
  # Copy SA (6 bytes) from VIF+80 to frame body+358
  discard c_memcpy(addr hdr.addr2[0], vifTxSa, 6)
  # Copy BSSID (6 bytes) from BSSID to frame body+364
  discard c_memcpy(addr hdr.addr3[0], bssidPtr, 6)

  # Generate and write sequence number (frame body+370..371)
  hdr.seqCtrl = txl_get_seq_ctrl()  # blob uses txl_get_seq_ctrl for sequence numbers

  # Store AP channel info at frame+47
  let apChanIdx = vif.vifIdx
  desc.vifIdx = apChanIdx
  desc.hdrLen = 0
  desc.secTailLen = 0
  desc.staInfoIdx = staIdx

  var bodyLen = 24'u32
  if authAlgo == 1 and authSeqNum == 3:
    if authChallenge == nil:
      fail(2)
    txu_cntrl_protect_mgmt_frame(frame, hdr, bodyLen)
    # Shared-key authentication requires a WEP IV and ICV, not RSN framing.
    if desc.hdrLen != 4 or desc.secTailLen != 4:
      fail(2)
    bodyLen += desc.hdrLen.uint32

  let authBodyPtr = cast[pointer](addr link.macHeader[bodyLen])
  var builtLen: uint32
  if authAlgo == 3:
    builtLen = meBuildSaeAuthenticate(
      authBodyPtr, 3'u16, authSeqNum, 0'u16, vifIdx.uint32, frame,
      bssidPtr, vifTxSa)
    if builtLen == 0:
      fail(2)
  else:
    builtLen = me_build_authenticate(
      authBodyPtr, authAlgo.uint16, authSeqNum, 0'u16, authChallenge)

  # Update frame lengths
  # .L128: Set TX descriptor fields
  let thd = hostTxHwDescAt(desc.hwDesc)
  desc.callback = nil
  desc.callbackArg = frame

  # Total frame length excluding FCS.
  var totalLen = bodyLen + builtLen
  let extraIeLen = desc.secTailLen
  totalLen += extraIeLen.uint32
  if totalLen > 512'u32:
    fail(2)
  desc.frameLen = totalLen.uint16
  desc.seqPassthrough = totalLen.uint16

  # Set THD length fields
  let thdBase = thd.payloadStart
  thd.payloadEnd = thdBase - 1 + totalLen
  thd.frameLen = totalLen + 4
  let authRawLen = if totalLen > nimFwDbgAuthTxRaw.len.uint32:
    nimFwDbgAuthTxRaw.len.uint32
  else:
    totalLen
  nimFwDbgAuthCfmPush = 0
  nimFwDbgAuthCfmFrame = 0
  nimFwDbgAuthCfmEvt = 0
  nimFwDbgAuthCfmStatus = 0
  nimFwDbgAuthCfmHwStatus = 0
  nimFwDbgAuthCfmThdFlags = 0
  nimFwDbgAuthCfmFinalFail16 = 0
  nimFwDbgAuthCfmAckOk23 = 0
  nimFwDbgAuthCfmAckFail = 0
  nimFwDbgAuthCfmDesc = 0
  nimFwDbgAuthCfmMeta = 0
  nimFwDbgAuthCfmFc = 0
  nimFwDbgAuthTxLen = totalLen
  nimFwDbgAuthTxMeta = authSeqNum.uint32 or (authAlgo.uint32 shl 16) or
    (vifIdx.uint32 shl 24) or (staIdx.uint32 shl 28)
  nimFwDbgAuthTxDesc = thd.frameLen or (authRawLen shl 16)
  discard c_memset(addr nimFwDbgAuthTxRaw[0], 0, nimFwDbgAuthTxRaw.len.csize_t)
  discard c_memcpy(addr nimFwDbgAuthTxRaw[0],
                   cast[pointer](addr link.macHeader[0]),
                   authRawLen.csize_t)
  let authTrace = cast[ptr AuthBodyTraceView](authBodyPtr)
  let authAlgoSeqTraceWord =
    authTrace.fixed.authAlgo.uint32 or (authTrace.fixed.authSeq.uint32 shl 16)
  let authStatusChallengeTraceWord =
    authTrace.fixed.statusCode.uint32 or
    (authTrace.challengeTag.uint32 shl 16) or
    (authTrace.challengeLen.uint32 shl 24)
  nimFwTrace2U32("[WIFI-NIMFW] auth_tx ",
                 authSeqNum.uint32 or (authAlgo.uint32 shl 16),
                 vifIdx.uint32 or (staIdx.uint32 shl 8))
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] auth_tx ",
                          authSeqNum.uint32 or (authAlgo.uint32 shl 16),
                          vifIdx.uint32 or (staIdx.uint32 shl 8))
    nimFwConnectTrace2U32("[WIFI-CT] auth_hdr0 ",
                          cast[ptr uint32](addr link.macHeader[0])[],
                          cast[ptr uint32](addr link.macHeader[4])[])
    nimFwConnectTrace2U32("[WIFI-CT] auth_hdr1 ",
                          cast[ptr uint32](addr link.macHeader[8])[],
                          cast[ptr uint32](addr link.macHeader[12])[])
    nimFwConnectTrace2U32("[WIFI-CT] auth_hdr2 ",
                          cast[ptr uint32](addr link.macHeader[16])[],
                          cast[ptr uint32](addr link.macHeader[20])[])
    nimFwConnectTrace2U32("[WIFI-CT] auth_body ",
                          authAlgoSeqTraceWord,
                          authStatusChallengeTraceWord)
    nimFwConnectTrace2U32("[WIFI-CT] auth_len ",
                          totalLen,
                          thd.frameLen)
    nimFwConnectTraceBytes("[WIFI-RAW] auth_tx ",
                           cast[pointer](addr link.macHeader[0]),
                           totalLen,
                           96)
    nimFwConnectTraceHw("[WIFI-CT] auth_hw ")
  nimFwTrace2U32("[WIFI-NIMFW] auth_mac ",
                 cast[ptr uint32](addr link.macHeader[4])[],
                 cast[ptr uint32](addr link.macHeader[16])[])
  nimFwTrace2U32("[WIFI-NIMFW] auth_len ",
                 totalLen,
                 thd.frameLen)
  nimFwTrace2U32("[WIFI-NIMFW] auth_body ",
                 authAlgoSeqTraceWord,
                 authStatusChallengeTraceWord)

  when defined(WifiAuthForceFreq):
    let forcedAuthFreq = uint16(WifiAuthForceFreq)
    if vif != nil and forcedAuthFreq != 0'u16:
      vif.channelFreqPair = forcedAuthFreq.uint32 or
        (forcedAuthFreq.uint32 shl 16)
      sm.primaryFreq = forcedAuthFreq
      sm.centerFreq = forcedAuthFreq

  when not defined(bl808WifiSkipAuthStaTxPrepare):
    # The channel scheduler already selected the join channel. Only reclaim
    # RF for a shared-radio window, or when the bench override is explicit.
    when WifiAuthForceFreq != 0:
      wifi_nimfw_prepare_sta_tx_channel()
    else:
      if nimFwBleWifiRoleWindowEnabled != 0 and
          chan_is_on_operational_channel(cast[pointer](vif)) and
          chan_is_tx_allowed(cast[pointer](vif)):
        wifi_nimfw_prepare_sta_tx_channel()
  when defined(bl808WifiAuthPromiscRx):
    let mm = mmEnvView()
    mm.rxFilterExtra = mm.rxFilterExtra or SCAN_ACTIVE_RX_FILTER_BITS
    mm.rxFilterBase = 0x7FFFFFDE'u32
    mm_rx_filter_set()
  nimFwDbgAuthRxCtrl = regRead(MACHW_RX_CNTRL_REG)
  # Keep the allocator/TPC policy unless the bench workaround is requested.
  when defined(bl808WifiMgmtRetryWorkaround):
    applyConservativeMgmtTxRetryPolicy(link)
    thd.ackPolicyControl = link.ackPolicyControl
    thd.retryLimitControl = link.retryLimitControl
  rfPriCaptureWb03AuthTxPrePush()
  applyForcedInternalMgmtTxPower(thd)
  captureAuthTxHwPrePush(desc, thd)

  # Commit. The build may have run SM code (station_tx_build.nim).
  if not opCurrent(smOwn.op, stamp):
    txl_frame_release(frame, false)
    return
  # Publish response state and its timeout before handing the frame over.
  let wait = smGo(SmAuthenticatingState)
  if not smArmResponse(wait, responseDelay) or
      (authAlgo in [0'u8, 1'u8, 3'u8] and
       not smAuthRecordResponse(wait, authAlgo, authSeqNum)):
    txl_frame_release(frame, false)
    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)
    return
  smConnecting = true
  # The vendor does not inspect the TX return value: the deadline, not this
  # call, drives the bounded retry policy.
  when defined(bl808WifiForceAuthAssocPush):
    let accepted = txl_frame_try_push_force(frame, 3) != 0
  else:
    let accepted = txl_frame_push(frame, 3) != 0
  if not accepted:
    if authAlgo in [0'u8, 1'u8, 3'u8]: smAuthCancelResponse(wait)
    return
  when defined(bl808WifiInjectAuthSuccess):
    if opCurrent(smOwn.op, wait):
      var injectedAuth: tuple[header: KeMsgHdr, frame: SmAuthFrameView]
      injectedAuth.header.paramLen = sizeof(SmAuthFrameView).uint32
      injectedAuth.frame.frameLen = 6
      injectedAuth.frame.authSeq = 2
      let dispatch = rxuMgtDispatchView(addr injectedAuth.frame)
      dispatch.frameCtrl = 0xB0
      dispatch.vifIdx = vifIdx
      dispatch.staIdx = staIdx
      sm_auth_handler(addr injectedAuth.frame)

proc sm_auth_send_pre*(authSeqNum: uint16, challenge: pointer = nil) {.exportc, cdecl.} =
  ## Pre-send authentication (5 instrs in blob).
  ## From blob: mv a2,a1; mv a1,a0; li a0,5; jr sm_auth_assoc_send_according_chan
  sm_auth_assoc_send_according_chan(SmAuthStartingState, authSeqNum, challenge)

proc sm_auth_start*() {.exportc, cdecl.} =
  ## Start authentication (24 bytes in blob, 8 instrs).
  ## From blob: loads sm_env[0] (connect info), clears auth retry count at offset 60,
  ## tail-calls sm_auth_send_pre(1, nil).
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo != nil:
    connectInfoAuthRetry(connInfo)[] = 0
  sm_auth_send_pre(1'u16, nil)

proc sm_assoc_req_send*() {.exportc, cdecl.} =
  ## Send association request frame (424 bytes in blob).
  ## Blob call sequence: txl_frame_get(512), tpc_update_frame_tx_power,
  ##   memcpy x3 (DA/SA/BSSID), txl_get_seq_ctrl, me_build_associate_req,
  ##   txl_frame_push(3), ke_timer_set, ke_state_set(SM,8).
  ## Here the frame is built in one pass, then SM enters state 8, arms the
  ## response deadline and pushes (station_tx_build.nim).
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  let smEnvSecond = sm.connectIndMsg
  if connInfo == nil or smEnvSecond == nil: return
  let stamp = smOwn.op.serial
  var frame: pointer
  template fail(status: uint16) =
    if frame != nil: txl_frame_release(frame, false)
    if opCurrent(smOwn.op, stamp): sm_connect_ind(status, 0xFFFF)
    return
  let vifIdx = connectInfoView(connInfo).vifIdx
  var staIdx: uint8
  var peer: MacAddrView
  if not smJoinPeer(vifIdx, staIdx, peer):
    fail(WLAN_FW_ASSOCIATE_FAIILURE.uint16)
  let vif = vifChannelForIdx(vifIdx)
  let staMac = cast[pointer](addr peer.bytes[0])
  var own = macAddrAt(vifMgmtTxSa(vif))[]
  let responseDelay = if sm.connectFlags != 0: 0x1E000'u32 else: 0x7D000'u32
  inc nimFwDbgAssocReqSend

  # Allocate TX frame via txl_frame_get(512) - NOT ke_msg_alloc
  frame = txl_frame_get(512)
  if frame == nil:
    # Vendor sm_assoc_req_send+0x19c reports allocation failure, not a timeout.
    fail(WLAN_FW_TX_ASSOC_FRAME_ALLOCATE_FAIILURE)
  # txl_frame_get can run SM code; an attempt that ended has freed connInfo.
  if not opCurrent(smOwn.op, stamp): fail(0)
  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil or desc.hwDesc == nil:
    fail(WLAN_FW_TX_ASSOC_FRAME_ALLOCATE_FAIILURE)

  # TPC update (blob: tpc_update_frame_tx_power at 0x5a)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Clear frame control/duration fields (blob: sb zero,348-351)
  hdr.frameControl = 0
  hdr.duration = 0

  # Snapshot vif+80 (frame SA) + MAC HW addr regs for crypto MAC consistency check.
  for vifMacByteIndex in 0 ..< 6:
    nimFwDbgVifMac[vifMacByteIndex] = vif.macAddr[vifMacByteIndex]
  nimFwDbgMacHwLo = regRead(MACHW_BASE + 0x10'u)
  nimFwDbgMacHwHi = regRead(MACHW_BASE + 0x14'u)

  # DA from sta_info_tab+4 (blob: memcpy at 0x8e)
  discard c_memcpy(addr hdr.addr1[0], staMac, 6.csize_t)
  # SA from vifEntry+80 (blob: memcpy at 0xa0)
  discard c_memcpy(addr hdr.addr2[0], addr own.bytes[0], 6.csize_t)
  # BSSID from sta_info_tab+4 (blob: memcpy at 0xb0)
  discard c_memcpy(addr hdr.addr3[0], staMac, 6.csize_t)

  # Sequence control via txl_get_seq_ctrl (blob at 0xb8)
  let seqCtrl = txl_get_seq_ctrl()
  hdr.seqCtrl = seqCtrl

  # Store VIF/STA info
  desc.vifIdx = vifIdx
  desc.staInfoIdx = staIdx
  desc.hdrLen = 0
  desc.secTailLen = 0

  # Build association request body at the MAC-header body start. Blob passes:
  # a0=macHdr+372, a1=vif+348, a2=nil, a3=vif.inst_nbr, a4=&cursor,
  # a5=&bodyLen, a6=connect info.
  var assocIeStart: pointer
  var assocBodyLen: uint16
  let assocBodyPtr = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  let assocInfo = cast[pointer](vifHtCapabilities(vif))
  let instNbr = vif.vifIdx
  var builtLen = meBuildAssociateReq(
    assocBodyPtr,
    assocInfo,
    nil,
    cast[pointer](instNbr.uint),
    cast[pointer](addr assocIeStart),
    cast[pointer](addr assocBodyLen),
    connInfo, frame)
  if builtLen < 4 or not smTxFits(frame, assocBodyPtr, builtLen) or
      cast[uint](assocIeStart) != cast[uint](assocBodyPtr) + 4'u or
      assocBodyLen.uint32 != builtLen - 4:
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocRequestBuild
    fail(WLAN_FW_ASSOCIATE_FAIILURE)
  let assocEnd = cast[pointer](cast[uint](assocBodyPtr) + builtLen.uint)

  var assocHasSecurityIe = false
  var assocIeOffset = 4'u
  while assocIeOffset + 2'u <= builtLen.uint:
    let ie = cast[ptr MacIeView](cast[uint](assocBodyPtr) + assocIeOffset)
    let ieLen = ie.len.uint
    if assocIeOffset + 2'u + ieLen > builtLen.uint:
      break
    if ie.id == IE_ID_RSN:
      assocHasSecurityIe = true
      break
    if ie.id == 0xDD'u8 and ieLen >= 4'u:
      let oui = cast[ptr UncheckedArray[uint8]](
        cast[uint](ie) + sizeof(MacIeView).uint)
      if oui[0] == 0x00'u8 and oui[1] == 0x50'u8 and
          oui[2] == 0xF2'u8 and oui[3] == 0x01'u8:
        assocHasSecurityIe = true
        break
    assocIeOffset += 2'u + ieLen
  let secState = vifSecurity(vif)
  let secIeSrc = cast[pointer](secState.rsnIePtr)
  let secIeLen = secState.rsnIeLen.uint32
  if not assocHasSecurityIe and secIeSrc != nil and secIeLen != 0'u32:
    if not smTxFits(frame, assocEnd, secIeLen):
      when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocSecurityTail
      fail(WLAN_FW_ASSOCIATE_FAIILURE)
    discard c_memcpy(assocEnd, secIeSrc, secIeLen.csize_t)
    builtLen += secIeLen
    assocBodyLen = assocBodyLen + secIeLen.uint16
    nimFwDbgVifIeLenAtAssoc =
      secIeLen or (cast[uint32](secIeSrc) shl 8) or 0x80000000'u32

  # Complete TX descriptor lengths to match the blob's sm_assoc_req_send.
  let thd = hostTxHwDescAt(desc.hwDesc)
  desc.callback = nil
  desc.callbackArg = frame
  let thdBase = thd.payloadStart
  thd.payloadEnd = thdBase + 23'u32 + builtLen
  thd.frameLen = builtLen + 28'u32
  nimFwDbgAssocReqMeta =
    vifIdx.uint32 or (staIdx.uint32 shl 8) or
      (builtLen.uint32 shl 16) or (assocBodyLen.uint32 shl 24)
  let assocTotalLen = sizeof(MacDataFrameHeaderView).uint32 + builtLen
  desc.frameLen = assocTotalLen.uint16
  desc.seqPassthrough = assocTotalLen.uint16
  let assocRawLen = if assocTotalLen > nimFwDbgAssocReqRaw.len.uint32:
    nimFwDbgAssocReqRaw.len.uint32
  else:
    assocTotalLen
  nimFwDbgAssocReqDesc = thd.frameLen or (assocRawLen shl 16)
  nimFwDbgAssocCfmPush = 0
  nimFwDbgAssocCfmFrame = 0
  nimFwDbgAssocCfmEvt = 0
  nimFwDbgAssocCfmStatus = 0
  nimFwDbgAssocCfmHwStatus = 0
  nimFwDbgAssocCfmThdFlags = 0
  nimFwDbgAssocCfmFinalFail16 = 0
  nimFwDbgAssocCfmAckOk23 = 0
  nimFwDbgAssocCfmAckFail = 0
  nimFwDbgAssocCfmDesc = 0
  nimFwDbgAssocCfmMeta = 0
  nimFwDbgAssocCfmFc = 0
  discard c_memset(addr nimFwDbgAssocReqRaw[0], 0,
                   nimFwDbgAssocReqRaw.len.csize_t)
  discard c_memcpy(addr nimFwDbgAssocReqRaw[0],
                   cast[pointer](addr link.macHeader[0]),
                   assocRawLen.csize_t)
  let assocFixed = cast[ptr AssocReqFixedBodyView](assocBodyPtr)
  let assocCapabilityListenTraceWord =
    assocFixed.capabilityInfo.uint32 or (assocFixed.listenInterval.uint32 shl 16)
  let assocReassocBssidPrefixWord =
    cast[ptr uint32](addr assocFixed.reassocBssid[0])[]
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_len ", builtLen, assocBodyLen.uint32)
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_body ",
                 assocCapabilityListenTraceWord,
                 assocReassocBssidPrefixWord)
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_rates ",
                 cast[ptr uint32](addr vif.basicRates[0])[],
                 cast[ptr uint32](addr vif.basicRates[4])[])
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_len ", builtLen, assocBodyLen.uint32)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_body ",
                          assocCapabilityListenTraceWord,
                          assocReassocBssidPrefixWord)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_rates ",
                          cast[ptr uint32](addr vif.basicRates[0])[],
                          cast[ptr uint32](addr vif.basicRates[4])[])
    nimFwConnectTraceHw("[WIFI-CT] assoc_hw ")

  when defined(bl808WifiAuthPromiscRx):
    let mmAssoc = mmEnvView()
    mmAssoc.rxFilterBase = 0x7FFFFFDE'u32
    mm_rx_filter_set()
  when defined(bl808WifiMgmtRetryWorkaround):
    applyConservativeMgmtTxRetryPolicy(link)
    thd.ackPolicyControl = link.ackPolicyControl
    thd.retryLimitControl = link.retryLimitControl
  rfPriCaptureWb03AuthTxPrePush()
  applyForcedInternalMgmtTxPower(thd)

  # The response handler appends after this exact transmitted IE prefix.
  let ind = smConnectIndPayloadAt(smEnvSecond)
  if assocBodyLen.int > ind.assocIeBuffer.len:
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocRequestIeCopy
    fail(WLAN_FW_ASSOCIATE_FAIILURE)

  # Commit. txl_frame_get may have run SM code (station_tx_build.nim); the
  # indication is the attempt's while its operation is live.
  if not opCurrent(smOwn.op, stamp):
    txl_frame_release(frame, false)
    return
  if assocBodyLen != 0:
    discard c_memcpy(addr ind.assocIeBuffer[0], assocIeStart, assocBodyLen.csize_t)
  ind.assocReqIeLen = assocBodyLen
  # Publish response state before handing the frame to the lower layer.
  if not smArmResponse(smGo(SmAssocRspState), responseDelay):
    txl_frame_release(frame, false)
    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)
    return
  # A refused frame is released by the TX layer; the deadline retries.
  when defined(bl808WifiForceAuthAssocPush):
    discard txl_frame_try_push_force(frame, 3)
  else:
    discard txl_frame_push(frame, 3)

proc sm_assoc_req_send_pre*() {.exportc, cdecl.} =
  ## Pre-send association request.
  ## Blob (5 instrs):
  ##   li a0, 7         ; nextState = 7 (SM_ASSOC_REQ_WAIT_RSP / internal)
  ##   li a1, 0         ; param1 = 0
  ##   li a2, 0         ; param2 = 0
  ##   tail-call sm_auth_assoc_send_according_chan
  sm_auth_assoc_send_according_chan(SmAssociatingState, 0'u16, nil)

proc smAssocIesValid(data: pointer; length: uint): bool =
  var offset = 0'u
  while offset < length:
    if length - offset < 2: return false
    let size = macIeAt(cast[uint](data) + offset).totalLen
    if size > length - offset: return false
    offset += size
  true

proc smAssocIePrefix(data: pointer; length, capacity: uint): uint =
  while result < length:
    let size = macIeAt(cast[uint](data) + result).totalLen
    if size > capacity - result: break
    result += size

proc smRxFrameFits(param: pointer; minimumFrameLength: uint32): bool =
  if param == nil: return false
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if payloadLength < 32'u32 + minimumFrameLength: return false
  let frameLength = rxuMgtIndMsgAt(param).frameLen.uint32
  frameLength >= minimumFrameLength and frameLength <= payloadLength - 32'u32

proc smAssocDone(vif, station: uint8; aid: uint16; notifyWps: bool) =
  ## The AP accepted the association: activate the link, state 9.
  if aid == 0 or aid > 2007'u16:
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocAid
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
    return
  smActivationStart(vif, station, aid, notifyWps)

proc sm_assoc_done*(aid: uint16) {.exportc, cdecl.} =
  let connection = smEnvView().connectInfo
  let state = ke_state_get(TASK_SM)
  if connection == nil or
      (state != SmAssocRspState and state != SmAuthenticatingState): return
  let vif = connectInfoView(connection).vifIdx
  if vif >= MAX_VIFS.uint8: return
  let vifView = vifChannelForIdx(vif)
  let station = vifView.staIdx
  if vifView.vifIdx != vif or vifView.vifType != VIF_TYPE_STA or
      station >= STA_INFO_TAB_ENTRIES.uint8: return
  smAssocDone(vif, station, aid, false)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_auth_handler(void*);".}
proc sm_auth_handler*(param: pointer) {.exportc, cdecl.} =
  ## Validate the RX body before taking ownership of this response.
  if param == nil: return
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if payloadLength < 38: return
  let frame = smAuthFrameView(param)
  let frameLen = frame.frameLen
  if frameLen < 6 or frameLen.uint32 > payloadLength - 32: return
  let dispatch = rxuMgtDispatchView(param)
  if (dispatch.frameCtrl and 0xFC'u16) != 0xB0: return
  let connection = smEnvView().connectInfo
  let indication = smEnvView().connectIndMsg
  if connection == nil or indication == nil or
      ke_state_get(TASK_SM) != SmAuthenticatingState: return
  let vifIndex = connectInfoView(connection).vifIdx
  if vifIndex >= MAX_VIFS.uint8 or dispatch.vifIdx != vifIndex: return
  let station = vifChannelForIdx(vifIndex).staIdx
  if station >= STA_INFO_TAB_ENTRIES.uint8 or
      (dispatch.staIdx != 0xFF and dispatch.staIdx != station): return
  let status = frame.statusCode
  let algorithm = frame.authAlgo
  let sequence = frame.authSeq
  if status == 0:
    if algorithm != 0 and algorithm != 1 and algorithm != 3: return
    # The archive accepts any successful open-system sequence and does not
    # compare the algorithm with the request. Neither may complete our attempt.
    if algorithm != connectInfoView(connection).authType.uint16 or
        (algorithm == 0 and sequence != 2): return
    if (algorithm == 1 and sequence notin [2'u16, 4'u16]) or
        (algorithm == 3 and sequence notin [1'u16, 2'u16]): return
    if algorithm == 1 and sequence == 2 and
        (frameLen < 136 or frame.saeBodyFirst != 16 or
         frame.sharedChallengeLen != 128): return
  const
    AuthAlgorithmNotSupported = 13'u16
    AuthTransactionOutOfSequence = 14'u16
  # An identified peer can explicitly refuse the only open-system transaction
  # without echoing transaction 2. Success and multi-step exchanges stay strict.
  let expectedSequence =
    if algorithm == 0 and dispatch.staIdx == station and
        status in {AuthAlgorithmNotSupported, AuthTransactionOutOfSequence}: 2'u16
    else: sequence
  # Only the response to the request of the live operation (state 6) counts.
  if not smAuthResponseMatches(algorithm, expectedSequence): return
  let stamp = smOwn.op.serial

  var challenge: array[128, uint8]
  if status == 0 and algorithm == 1 and sequence == 2:
    discard c_memcpy(addr challenge[0], smAuthSharedChallengePtr(frame), 128)

  inc nimFwDbgAuthHandler
  nimFwDbgAuthHandlerLast = algorithm.uint32 or (sequence.uint32 shl 16) or
    (status.uint32 shl 24)
  when defined(bl808WifiConnectTrace):
    let staVifPair = dispatch.staIdx.uint32 or (dispatch.vifIdx.uint32 shl 8)
    nimFwConnectTrace2U32("[WIFI-CT] sm_mgt_auth ", SmAuthenticatingState.uint32, staVifPair)
    nimFwConnectTrace2U32("[WIFI-CT] auth_rx ",
      algorithm.uint32 or (sequence.uint32 shl 16),
      status.uint32 or (SmAuthenticatingState.uint32 shl 16))

  if status != 0:
    if not smAuthConsumeResponse(algorithm, expectedSequence): return
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
    let info = connectInfoView(connection)
    if info.authType == 1 and info.authRetryGate != 0:
      info.authType = 0
      sm_auth_send_pre(1'u16, nil)
    else:
      sm_connect_ind(WLAN_FW_AUTHENTICATION_FAIILURE.uint16, status)
    return

  if algorithm == 3:
    var processed = -1'i32
    if wpa_cbs != nil:
      let callback = cast[ptr UncheckedArray[pointer]](wpa_cbs)[15]
      if callback != nil:
        let handleSae = cast[proc(body: pointer; length, sequence: uint16;
                                 context: pointer): int32 {.cdecl.}](callback)
        # The supplicant may end the attempt, or send a new request, here.
        processed = handleSae(smAuthSaeBodyPtr(frame), frameLen - 6, sequence, nil)
        if not opCurrent(smOwn.op, stamp): return
    if processed == 0:
      if not smAuthConsumeResponse(algorithm, sequence): return
      ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
      if sequence == 1:
        sm_auth_send_pre(2'u16, nil)
      elif sequence == 2:
        connectInfoAuthRetry(connection)[] = 0
        sm_assoc_req_send_pre()
      return
    if processed != -8:
      if not smAuthConsumeResponse(algorithm, sequence): return
      ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
    let logFn = getLogFunc(204)
    if logFn != nil:
      let line = if processed == -8: 1302.cint else: 1307.cint
      let format: cstring = if processed == -8:
        "BL_SAE_INVALID_PACKET, auth seq num= %d\r\n"
      else:
        "SAE Authentication parse failure, auth seq num= %d\r\n"
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.}](logFn)(
        3, nil, "sm.c", line, format, sequence.cint)
    if processed != -8:
      sm_connect_ind(WLAN_FW_AUTHENTICATION_FAIILURE.uint16, 0)
    return

  if algorithm != 0 and algorithm != 1: return
  if not smAuthConsumeResponse(algorithm, sequence): return
  ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
  if algorithm == 0:
    connectInfoAuthRetry(connection)[] = 0
    inc nimFwDbgAuthOpenSuccess
    sm_assoc_req_send_pre()
  elif sequence == 4:
    connectInfoAuthRetry(connection)[] = 0
    sm_assoc_req_send_pre()
  elif sequence == 2:
    sm_auth_send_pre(3'u16, addr challenge[0])
  else:
    sm_connect_ind(3, 0)
    assert_warn("sm.c", "sm.c", 1343)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_assoc_rsp_handler(void*);".}
proc sm_assoc_rsp_handler*(param: pointer) {.exportc, cdecl.} =
  ## Parse the RX wrapper's six-byte fixed body and bounded IE stream.
  if param == nil: return
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if payloadLength < 38: return
  let frame = smAssocRspFrameView(param)
  let frameLen = frame.frameLen
  if frameLen < 6 or frameLen.uint32 > payloadLength - 32: return
  let dispatch = rxuMgtDispatchView(param)
  let subtype = dispatch.frameCtrl and 0xFC'u16
  if subtype != 0x10 and subtype != 0x30: return
  let assocBody = smAssocRspIePtr(frame)
  let ieLength = frameLen.uint - 6
  let connection = smEnvView().connectInfo
  if connection == nil or ke_state_get(TASK_SM) != SmAssocRspState: return
  let vifIdx = connectInfoView(connection).vifIdx
  if vifIdx >= MAX_VIFS.uint8 or dispatch.vifIdx != vifIdx: return
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8 or
      (dispatch.staIdx != 0xFF and dispatch.staIdx != staIdx): return
  let smEnvSecond = smEnvView().connectIndMsg
  if smEnvSecond == nil: return
  let statusCode = frame.statusCode
  let iesValid = smAssocIesValid(assocBody, ieLength)
  # A valid fixed failure status must still be reported when optional IEs are
  # malformed. Successful association and comeback timing require valid IEs.
  if statusCode == 0 and not iesValid: return
  let aid = frame.aid and 0x3FFF'u16
  let body0 = frame.capabilityInfo.uint32 or (statusCode.uint32 shl 16)
  var body4 = frame.aid.uint32
  let ieBytes = cast[ptr UncheckedArray[uint8]](assocBody)
  if ieLength > 0: body4 = body4 or (ieBytes[0].uint32 shl 16)
  if ieLength > 1: body4 = body4 or (ieBytes[1].uint32 shl 24)
  ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
  if statusCode == 0 and (aid == 0 or aid > 2007'u16):
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocAid
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
    return
  inc nimFwDbgAssocRspCount
  nimFwDbgAssocRspStatus = statusCode.uint32
  nimFwDbgAssocRspLen = frameLen.uint32
  nimFwDbgAssocRspBody0 = body0
  nimFwDbgAssocRspBody4 = body4
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_status ", frameLen.uint32, statusCode.uint32)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_body ", body0, body4)
  if statusCode != 0:
    if statusCode == 30 and iesValid:
      let iePtr = mac_ie_find(assocBody, ieLength.uint32, 56)
      if iePtr != nil:
        let timeoutIe = timeoutIntervalIeAt(iePtr)
        if timeoutIe.ie.len == 5:
          if timeoutIe.intervalType == 3:
            let retry = timeoutIe.intervalValue
            let intervalTu = retry[0].uint32 or (retry[1].uint32 shl 8) or
              (retry[2].uint32 shl 16) or (retry[3].uint32 shl 24)
            connectInfoAuthRetry(connection)[] = 0
            # Waiting out the comeback is a new operation in the same state,
            # so an expiry already posted for the request is stale.
            if smArmResponse(smGo(SmAssocRspState),
                             max(1'u64, intervalTu.uint64 * 1024)): return
            when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocComeback
            sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
            return
    let logFn = blOpsFunc(4)
    if cast[uint](logFn) > 0x1000'u:
      cast[proc(fmt: cstring) {.cdecl, varargs.}](logFn)(
        "Association failure, Wlan802.11 status code = %d\r\n", statusCode.cint)
    sm_connect_ind(5, statusCode)
    return
  let ind = smConnectIndPayloadAt(smEnvSecond)
  let reqIeLen = ind.assocReqIeLen
  if reqIeLen.uint > ind.assocIeBuffer.len.uint:
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocResponseIeCopy
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
    return
  let rspIeLen = smAssocIePrefix(assocBody, ieLength,
    ind.assocIeBuffer.len.uint - reqIeLen.uint).uint16
  ind.assocRspIeLen = rspIeLen
  if rspIeLen != 0:
    discard c_memcpy(addr ind.assocIeBuffer[reqIeLen.int], assocBody, rspIeLen.csize_t)
  let staEntry = cast[pointer](staInfoForIdx(staIdx))
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_rate ", staIdx.uint32,
                          pointerAddrU32(staEntry))
  if not meTryInitRate(staEntry):
    when defined(bl808WifiDiagWarmScan): nimFwDbgWarmAssocFailure = warmAssocRateInit
    sm_connect_ind(WLAN_FW_ASSOCIATE_FAIILURE.uint16, 0xFFFF)
    return
  let chanPtr = vif.operChan
  if chanPtr != nil:
    let chan = cast[ptr ScanChannelEntry](chanPtr)
    # Keep the requested power negative when a large constraint exceeds the
    # signed channel limit; the PHY applies its own lower bound afterward.
    var tpcPower = cast[uint8](max(
      chan.txPower.int - vifBssStatus(vif).powerConstraint.int,
      low(int8).int).int8)
    var tpcRate: uint8
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_tpc ", pointerAddrU32(chanPtr),
                            tpcPower.uint32)
    tpc_update_vif_tx_power(cast[pointer](vif), cast[pointer](addr tpcPower), cast[pointer](addr tpcRate))
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_done ", vifIdx.uint32,
                          pointerAddrU32(cast[pointer](vif)))
  smAssocDone(vifIdx, staIdx, aid, smEnvView().state == 2)

proc sm_deauth_handler*(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## Handle deauthentication frame (140 instrs). Validates BSSID/SA,
  ## extracts reason code, dispatches based on SM state.
  ## Returns 0 for consumed messages, 2 to save/retry during a conflicting SM
  ## transition. A saved message must not alter connection ownership.
  inc nimFwDbgDeauthHandler
  if not smRxFrameFits(param, 26):
    return KeMsgConsumed
  let frame = rxuMgtIndMsgAt(param)
  if (frame.frameCtrl and 0x000C) != 0: return KeMsgConsumed
  let headerLength = rxMacHeaderLen(frame.frameCtrl)
  if frame.frameLen < headerLength.uint16 + 2: return KeMsgConsumed
  let deauth = smDeauthFrameView(param)
  let vifIdx = deauth.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return KeMsgConsumed
  # The scheduler may have checked the tag before this slot was reused.
  when defined(bl808WifiDiagPeerRxAdmission):
    var protection: RxMgtProtection
    if not rxMgtMessageCurrent(keMsgHdrFromPayload(param), addr protection):
      return KeMsgConsumed
  else:
    if not rxMgtMessageCurrent(keMsgHdrFromPayload(param)):
      return KeMsgConsumed
  when defined(bl808WifiDiagLinkDrop):
    template peerEvidence(viaQuery: bool): SmPeerDisconnectEvidence =
      block:
        var evidence = smCapturePeerDisconnect(frame, viaQuery)
        when defined(bl808WifiDiagPeerRxAdmission):
          evidence.protection = protection
        evidence
  let sm = smEnvView()
  let vif = vifChannelForIdx(vifIdx)

  # Validate BSSID: param[48..53] vs vif.bssid.
  for bssidByteIndex in 0 ..< 6:
    if deauth.bssid[bssidByteIndex] != vif.bssid[bssidByteIndex]:
      # BSSID mismatch - blob logs debug with line 1503 and returns 0
      return KeMsgConsumed

  # This field is the destination address; group-addressed disconnects pass.
  if (deauth.sa[0] and 1) == 0:
    for destAddrByteIndex in 0 ..< 6:
      if deauth.sa[destAddrByteIndex] != vif.macAddr[destAddrByteIndex]:
        # Destination mismatch - blob logs debug with line 1507 and returns 0
        return KeMsgConsumed

  # RX retains the management header (including HT Control), but not the IV.
  let reason = managementReasonBodyAt(addr frame.body[headerLength]).reason

  # Load connect-info pointer from sm_env[0]
  let connInfoPtr = sm.connectInfo

  let state = ke_state_get(TASK_SM)
  if state == SmDisconnectingState:
    return KeMsgSaved
  if state != SmIdleState:
    # SM in an active state other than disconnecting:
    # Check if connect-info vifIdx matches param vifIdx
    if connInfoPtr == nil or connectInfoView(connInfoPtr).vifIdx != vifIdx:
      return KeMsgSaved
    # VIF matches: send connect indication with status=6 (deauth by AP)
    sm_connect_ind(6, reason)
    return KeMsgConsumed

  # state == 0 (idle): check VIF connection flag at vif[88]
  let vifConn = vif.state
  if vifConn == 0:
    return KeMsgConsumed

  let peer = mmCaptureVif(vif)
  if not mmVifCurrent(peer): return KeMsgConsumed
  # RX policy requests SA Query for an unprotected PMF disconnect.
  if (deauth.frameFlags and 1) != 0:
    if smSaQueryResetting or smSaQueryCurrent(smSaQuery.serial): return KeMsgConsumed
    if deauth.staIdx.int >= STA_INFO_TAB_ENTRIES or deauth.staIdx != vif.staIdx:
      return KeMsgConsumed
    if staInfoForIdx(deauth.staIdx).instNbr != vifIdx:
      return KeMsgConsumed
    inc smSaQuery.serial
    smSaQuery.peer = peer
    smSaQuery.armed = false
    when defined(bl808WifiDiagLinkDrop):
      smSaQuery.evidence = peerEvidence(true)
    sm.saQueryActive = 1
    sm.saQueryRetryCount = 2
    sm.saQueryStaIdx = deauth.staIdx
    sm.saQueryReason = reason
    sm_issue_sa_query_request()
    return KeMsgConsumed
  when defined(bl808WifiDiagLinkDrop):
    smReportApDisconnect(peer, reason, peerEvidence(false))
  else:
    smReportApDisconnect(peer, reason)
  return KeMsgConsumed

proc sm_get_set_machwkey_index*(getFlag: bool, vifIdx: uint8,
    keyBuf: ptr uint8, keyType: uint8): cint {.exportc, cdecl, noinline.} =
  ## Get/set MAC HW key index for SM.
  ## From blob (32 instrs): a0=getFlag (0=set, nonzero=get), a1=vifIdx,
  ## a2=keyBuf pointer, a3=keyType (0/1/2 = different key offsets within VIF entry).
  ##
  ## The vendor relocations select vif_info_tab + 510/511/512 for keyType
  ## 0/1/2: pairwise, group, and management key indices respectively.
  ## If vifIdx > 1 or keyType > 2, returns int -1.
  ## getFlag=0: writes keyBuf[0] to vif[offset]; nonzero: reads vif[offset] into keyBuf[0].
  ## Returns 0 on success.
  ## noinline + asm barrier: blob calls this as a real function from
  ## bl_wifi_get_sta_gtk and bl_wifi_set_igtk_internal; without noinline GCC
  ## inlines the short table lookup.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  if vifIdx > 1:
    return -1

  let vif = vifChannelForIdx(vifIdx)
  let indexes = vifMachwKeyIndexes(vif)

  var keyAddr: ptr uint8
  case keyType
  of 0: keyAddr = addr indexes.pairwise
  of 1: keyAddr = addr indexes.group
  of 2: keyAddr = addr indexes.management
  else: return -1

  if not getFlag:
    # SET: write from keyBuf to vif entry
    keyAddr[] = keyBuf[]
  else:
    # GET: read from vif entry to keyBuf
    keyBuf[] = keyAddr[]

  return 0

proc sm_handle_eapol_input*(staIdx: uint8, srcAddr: pointer, eapolBuf: pointer,
    eapolLen: uint16) {.exportc, cdecl.} =
  ## Handle EAPOL frame input (51 instrs).
  ## From blob: a0 = STA idx, a1 = source MAC, a2 = EAPOL buffer, a3 = length.
  ## Computes STA entry = sta_info_tab + staIdx * 368.
  ## Computes VIF entry = vif_info_tab + vifIdx * 1512 (vifIdx from sta[39]).
  ## Checks VIF+488 (WPA state flag). If zero, returns.
  ## Checks sm_env[44] (connection state): if == 2 (WPS mode), loads wps_cbs
  ## and calls wps_cbs[4] (WPS EAPOL handler). Otherwise checks ke_state_get(4).
  ## In states 0 (idle) and 9 (activating), calls wpa_cbs[20].
  ## Other SM states leave the frame unhandled by the supplicant.
  inc nimFwDbgEapolIn
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    inc nimFwDbgEapolDropped
    return
  let vifIdxFromSta = staInfoForIdx(staIdx).instNbr
  if vifIdxFromSta.int >= MAX_VIFS:
    inc nimFwDbgEapolDropped
    return
  let vifEntry = cast[uint](vifChannelForIdx(vifIdxFromSta))
  let wpaState = vifSecurityAt(vifEntry).connected
  nimFwDbgVifWpaState = wpaState.uint32
  if wpaState == 0:
    inc nimFwDbgEapolDropped
    return
  inc nimFwDbgEapolForwarded
  # Check connection state
  if smEnvView().state == 2:
    # WPS mode: dispatch to WPS callback
    if wps_cbs != nil:
      let wpsHandler = wpsCallbacks().eapolHandler
      if cast[uint](wpsHandler) > 0x1000'u:
        discard cast[proc(src: pointer, buf: pointer, len: uint32): cint {.cdecl.}](wpsHandler)(
          srcAddr, eapolBuf, eapolLen)
    return
  # Normal mode: check SM task state
  let smState = ke_state_get(TASK_SM)
  nimFwDbgSmStateAtEapol = smState.uint32
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] sm_eapol ", staIdx.uint32 or (smState.uint32 shl 8), eapolLen)
  if smState == SmIdleState or smState == SM_ACTIVATING_STATE:
    # Idle also forwards key updates for an already connected station.
    if wpa_cbs != nil:
      let wpaHandler = wpaCallbacks().eapolHandler
      if cast[uint](wpaHandler) > 0x1000'u:
        inc nimFwDbgEapolCbInv
        discard cast[proc(src: pointer, buf: pointer, len: uint32): cint {.cdecl.}](wpaHandler)(
          srcAddr, eapolBuf, eapolLen)
      else:
        inc nimFwDbgEapolCbNull
    else:
      inc nimFwDbgEapolCbNull

proc smRetireEstablishedSupplicantLink(staIdx: uint8; reason: uint16) =
  if txlResetting() or smEnvView().connectInfo != nil or
      ke_state_get(TASK_SM) != SmIdleState:
    return
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or sta.instNbr >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(sta.instNbr)
  if vif.vifIdx != sta.instNbr or vif.staIdx != staIdx or
      vif.vifType != VIF_TYPE_STA or vif.state == 0:
    return
  # No pending connect indication exists after association. Retire the live
  # link even if key failure makes another management transmission unreliable.
  sm_disconnect_process(vif, WLAN_FW_4WAY_HANDSHAKE_ERROR_PSK_TIMEOUT_FAILURE.uint16, reason)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_handle_supplicant_result(unsigned char,unsigned short);".}
proc sm_handle_supplicant_result*(result_code: uint8, reason: uint16) {.exportc, cdecl.} =
  ## Handle WPA supplicant result (133 instrs).
  ## a0=result_code, a1=reason.
  ## From blob: loads sta_info_tab, checks ke_state_get(4)==10 for SM task state.
  ## If state==10 (disconnecting), returns immediately.
  ## If reason==0: opens sta[72]=2 and tail-calls sm_connect_ind(0,0).
  ## If reason==15: calls g_bl_ops_funcs log, then falls through.
  ## Otherwise: transitions SM state to disconnecting, allocates TX frame via txl_frame_get(512),
  ## builds deauth frame with VIF info, calls me_build_deauthenticate, then
  ## txl_frame_push to transmit. On failure, calls sm_connect_ind(9/10, reason).
  if result_code.int >= STA_INFO_TAB_ENTRIES:
    return
  if reason == 0 and smActivationConsumeSuccess(result_code): return
  if smEnvView().connectInfo == nil:
    if reason != 0: smRetireEstablishedSupplicantLink(result_code, reason)
    return
  let sta = staInfoForIdx(result_code)
  let vifIdx = sta.instNbr
  if vifIdx.int >= MAX_VIFS:
    return

  # Check SM task state
  let smState = ke_state_get(TASK_SM)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] supp_result ",
                          result_code.uint32 or (reason.uint32 shl 8),
                          smState.uint32)
  if smState == SmDisconnectingState:
    return  # Already disconnecting

  if reason == 0:
    # Supplicant accepted the PTK. Mark the control port open and report the
    # deferred WPA-protected connection success to the host.
    let supplicantControlPortState = sta.controlPortState
    if supplicantControlPortState == 2:
      return  # already open
    sta.controlPortState = 2
    sm_connect_ind(0, 0)
    return

  if reason == 15:
    # Slot 4 is printf-like, not the structured logger at slot 204.
    let logFn = blOpsFunc(4)
    if logFn != nil:
      cast[proc(fmt: cstring) {.cdecl, varargs.}](logFn)(
        "4-way handshake timeout failure, wlan 802.11 reason code = %u,                try to transmit deauth frame\r\n",
        reason.cuint)

  # The blob enters state 10 here; this port does so once the frame is built
  # (smDeauthWait), so a failure below still ends a live attempt.
  let stamp = smOwn.op.serial
  # Allocate TX frame for deauth (512 bytes)
  let frame = txl_frame_get(512)
  if frame == nil:
    # Allocation failed: report it, unless SM moved on inside txl_frame_get.
    if opCurrent(smOwn.op, stamp): sm_connect_ind(10, reason.uint16)
    return

  let vif = vifChannelForIdx(vifIdx)
  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil or desc.hwDesc == nil:
    txl_frame_release(frame, false)
    if opCurrent(smOwn.op, stamp): sm_connect_ind(10, reason.uint16)
    return
  tpc_update_frame_tx_power(cast[pointer](vif), frame)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Build MAC header for deauth frame.
  hdr.frameControl = 0x00C0'u16
  hdr.duration = 0

  # Copy addresses (DA=BSSID, SA=own MAC, BSSID)
  discard c_memcpy(addr hdr.addr1[0],
                   cast[pointer](addr sta.macAddr[0]), 6.csize_t)
  discard c_memcpy(addr hdr.addr2[0],
                   addr vif.macAddr[0], 6.csize_t)
  discard c_memcpy(addr hdr.addr3[0],
                   cast[pointer](addr sta.macAddr[0]), 6.csize_t)

  # Get sequence control (blob: txl_get_seq_ctrl).
  let seqCtrl = txl_get_seq_ctrl()
  hdr.seqCtrl = seqCtrl

  desc.vifIdx = vifIdx
  desc.staInfoIdx = result_code
  desc.hdrLen = 0
  desc.secTailLen = 0

  # Build deauthenticate body
  let bodyPtr = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  let bodyLen = me_build_deauthenticate(bodyPtr, reason.uint16)

  # Update THD length fields.
  let thd = hostTxHwDescAt(desc.hwDesc)
  let payloadStart = thd.payloadStart
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] supp_deauth ",
                          reason.uint32 or (result_code.uint32 shl 8) or
                            (vifIdx.uint32 shl 16),
                          cast[uint32](cast[uint](frame)))
    nimFwConnectTrace2U32("[WIFI-CT] supp_thd ",
                          payloadStart,
                          cast[uint32](cast[uint](addr link.macHeader[0])))
  thd.payloadEnd = payloadStart + 23 + bodyLen
  thd.frameLen = bodyLen + 28

  # Enter the deauthentication wait and register the TX-completion callback.
  # Blob: `addi a5, s1, 128; sw &cfm, 80(a5); sw vif, 84(a5)`, i.e. frame+208 =
  # &sm_supplicant_deauth_cfm, frame+212 = &vif_entry; here frame+212 holds
  # the wait's stamp.
  # Commit. txl_frame_get may have run SM code (station_tx_build.nim).
  let callback = cast[pointer](sm_supplicant_deauth_cfm)
  let wait = if opCurrent(smOwn.op, stamp): smDeauthWait(vifIdx, callback) else: 0'u32
  if wait == 0:
    txl_frame_release(frame, false)
    return
  desc.callback = callback
  desc.callbackArg = opStampEnv(wait)
  # The queue consumes the descriptor even on failure. Completion owns the
  # success path; a rejected push runs no callback and reports the distinct
  # vendor status 9.
  if txl_frame_push(frame, 3) == 0:
    smConnectEnd(9, reason)

proc smTrySubmitSaQuery(staIdx: uint8, action: uint8, transId: uint16;
                        querySerial: ptr uint32 = nil): SmSaQueryTxResult =
  ## Vendor ABI: int(ap_sta_idx, action, transaction_id). SA Query uses the
  ## peer's VIF and unicast protection before appending its four-byte body.
  if staIdx.int >= STA_INFO_TAB_ENTRIES or action > 1:
    return saQueryBuildRejected
  let sta = staInfoForIdx(staIdx)
  let vifIdx = sta.instNbr
  if vifIdx.int >= MAX_VIFS:
    return saQueryBuildRejected
  let vif = vifChannelForIdx(vifIdx)
  let peer = mmCaptureVif(vif)
  let identity = TxSessionIdentity(captured: true, vif: vifIdx, station: staIdx,
    vifEpoch: peer.epoch, stationEpoch: peer.stationEpoch, resetEpoch: txResetEpoch)
  # A response need not belong to our outstanding query, but cannot span a flush.
  let queryResetEpoch = smSaQueryResetEpoch
  template currentPeer(): bool =
    not smSaQueryResetting and queryResetEpoch == smSaQueryResetEpoch and
      peer.station == staIdx and mmVifCurrent(peer) and
      identity.resetEpoch == txResetEpoch and not txlResetting() and
      vif.vifType == VIF_TYPE_STA and vif.state != 0 and
      (querySerial == nil or smSaQueryCurrent(querySerial[]))
  if not currentPeer(): return saQueryBuildRejected
  let frame = txl_frame_get(512)
  if frame == nil:
    return saQueryBuildRejected
  let desc = hostTxDescAt(frame)
  let lease = txlFrameLeaseToken(desc)
  var owned = true
  defer:
    if owned and txlFrameLeaseMatches(desc, lease):
      txl_frame_release(frame, false)
  if not currentPeer(): return saQueryBuildRejected
  let linkPtr = desc.bufDesc
  let hardware = desc.hwDesc
  desc.vifIdx = vifIdx
  desc.staInfoIdx = staIdx
  template prepared(): bool =
    currentPeer() and txlFramePreparationCurrent(desc, identity, lease) and
      desc.bufDesc == linkPtr and desc.hwDesc == hardware
  if not prepared(): return saQueryBuildRejected
  tpc_update_frame_tx_power(cast[pointer](vif), frame)
  if not prepared(): return saQueryBuildRejected
  let link = hostTxLinkDescAt(linkPtr)
  let hdr = hostTxDataHeader(desc)
  hdr.frameControl = 0x00D0'u16
  hdr.duration = 0
  discard c_memcpy(addr hdr.addr1[0], addr sta.macAddr[0], 6.csize_t)
  discard c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)
  discard c_memcpy(addr hdr.addr3[0], addr sta.macAddr[0], 6.csize_t)
  hdr.seqCtrl = txl_get_seq_ctrl()
  desc.hdrLen = 0
  desc.secTailLen = 0
  desc.callback = nil
  desc.callbackArg = nil
  txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 24)
  if not prepared(): return saQueryBuildRejected
  if desc.hdrLen != 8 or desc.secTailLen != 8:
    return saQueryBuildRejected
  let bodyOff = 24 + desc.hdrLen.int
  let body = saQueryActionBodyAt(addr link.macHeader[bodyOff])
  body.category = 8
  body.action = action
  body.transId = transId
  let frameLen = bodyOff.uint32 + 4 + desc.secTailLen.uint32
  let thd = hostTxHwDescAt(hardware)
  thd.payloadEnd = thd.payloadStart + frameLen - 1
  thd.frameLen = frameLen + 4
  # The queue consumes the frame even when it rejects the submission.
  owned = false
  if txl_frame_push(frame, 3) == 0: saQueryQueueRejected else: saQuerySubmitted

proc sm_send_sa_query*(staIdx: uint8, action: uint8, transId: uint16): cint {.exportc, cdecl, discardable.} =
  # The vendor ignores local queue rejection in this ABI.
  if smTrySubmitSaQuery(staIdx, action, transId) == saQueryBuildRejected: -1 else: 0

proc sm_sa_query_handler*(param: pointer) {.exportc, cdecl.} =
  ## Accept SA Query messages only from the connected peer of an active STA
  ## VIF with an open control port. Reply to requests; matching responses
  ## retire the pending query before cancelling its timer.
  if not smRxFrameFits(param, 4):
    return
  let frame = smSaQueryFrameView(param)
  let vifIdx = frame.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return
  if smSaQueryResetting or not rxMgtMessageCurrent(keMsgHdrFromPayload(param)): return
  let vif = vifChannelForIdx(vifIdx)
  # Check VIF active
  let active = vif.state
  if active == 0:
    return
  let vifType = vif.vifType
  if vifType != 0:
    return
  let staIdx = frame.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES or staIdx != vif.staIdx:
    return
  if staInfoForIdx(staIdx).instNbr != vifIdx:
    return
  # Check STA control-port/association gate state
  let stationControlPortState = staInfoForIdx(staIdx).controlPortState
  if stationControlPortState != 2:
    return  # not associated
  # Read SA query frame fields from param
  let action = frame.action  # SA query action (0=req, 1=resp)
  let transId = frame.transId
  if action == 0:
    # SA Query Request received: send response
    discard sm_send_sa_query(staIdx, 1, transId)
  elif action == 1:
    # SA Query Response received: validate against pending query
    let sm = smEnvView()
    if not smSaQueryCurrent(smSaQuery.serial) or sm.saQueryStaIdx != staIdx:
      return
    let pendingTransId = sm.saQueryTransId
    if transId == pendingTransId:
      sm.saQueryActive = 0
      smSaQuery.armed = false
      ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM)

proc sm_issue_sa_query_request*() {.exportc, cdecl.} =
  ## Issue SA Query request to AP (28 instrs).
  ## From blob: generates a transaction ID from sm.o's private LCG,
  ## stores lower 16 bits as pending transId in sm_env+40.
  ## reads the peer STA index from sm_env+38, and sends action 0.
  ## Starts the SA query timeout with ke_timer_set(id, TASK_SM, 100000).
  if not smSaQueryCurrent(smSaQuery.serial): return
  let sm = smEnvView()
  inc smSaQuery.serial
  if smSaQuery.serial == 0: inc smSaQuery.serial
  var serial = smSaQuery.serial
  smSaQuery.armed = false
  smQueryPrngState = smQueryPrngState * RC_PRNG_MULT + RC_PRNG_INCR
  let rng = smQueryPrngState
  let transId = (rng shr 16).uint16
  sm.saQueryTransId = transId
  let sendStatus = smTrySubmitSaQuery(sm.saQueryStaIdx, 0, transId, addr serial)
  if not smSaQueryCurrent(serial): return
  when defined(bl808WifiDiagLinkDrop):
    if sendStatus == saQuerySubmitted: inc smSaQuery.evidence.submitted
    else: inc smSaQuery.evidence.rejected
  const delay = 100_000'u32
  let deadline = macTimeNow() + delay
  if not smSaQueryCurrent(serial): return
  smSaQuery.deadline = deadline
  smSaQuery.armed = true
  if not ke_timer_try_set(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM, delay,
      stamp = serial) and smSaQueryCurrent(serial):
    # Timer allocation failure is not evidence that the AP stopped responding.
    sm.saQueryActive = 0
    smSaQuery.armed = false

proc sm_set_channel_coex_connected*() {.exportc, cdecl.} =
  ## Set channel coexistence info after connection (10 instrs).
  ## From blob: loads primary freq from sm_env+32, center freq from sm_env+34,
  ## then applies the PHY channel descriptor for the STA channel.
  let sm = smEnvView()
  phySetChannel(0, 0, sm.primaryFreq, sm.centerFreq, 0, 0)

proc sm_connection_tlv_set*() {.exportc, cdecl, noinline.} =
  ## The vendor exports a no-argument, ret-only stub.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}

proc sm_connection_tlv_reset*() {.exportc, cdecl.} =
  ## Reset all connection TLV data.
  discard

proc sm_connection_tlv_pack*(id, flag: uint8; data: pointer;
                             len: uint16): cint {.exportc, cdecl.} =
  ## The vendor accepts a TLV descriptor but does not pack anything.
  discard id
  discard flag
  discard data
  discard len
  0

proc sm_connection_tlv_desc_get*(list: ptr CoList) {.exportc, cdecl.} =
  ## The vendor leaves the caller's list unchanged.
  discard list

proc sm_connect_wap_tlv_pack_cb*(eapolId: uint8; data: pointer;
                                length: uint16) {.exportc, cdecl.} =
  ## Vendor diagnostic callback: the body is a no-op with three ABI arguments.
  discard eapolId
  discard data
  discard length

proc sm_connection_sta_add_ind*() {.exportc, cdecl.} =
  discard smActivationNotifyCurrent()

proc sm_connect_auth_assoc_req(param: pointer): cint {.exportc, cdecl, discardable.} =
  ## The local dispatcher passes only the payload, unlike the vendor ABI.
  ## Only the request SM parked is taken (smDeferredDispatch).
  smDeferredDispatch(param)

# ###########################################################################
#                   APM: AP Management
# ###########################################################################

proc apmPendingClear(index: int) =
  let pending = addr apmPendingAssociations[index]
  pending.request = nil
  pending.confirmation = nil
  pending.meQueued = false
  inc pending.generation

proc apmPendingRequestSlot(request: pointer; queued: bool): int =
  if request != nil:
    for index in 0 ..< apmPendingAssociations.len:
      let pending = addr apmPendingAssociations[index]
      if pending.request == request and pending.meQueued == queued and
         apmStaSlot(index.uint).active != 0:
        return index
  -1

proc apmPendingConfirmationSlot(confirmation: pointer): int =
  if confirmation != nil:
    for index in 0 ..< apmPendingAssociations.len:
      if apmPendingAssociations[index].confirmation == confirmation:
        return index
  -1

proc apmCancelPendingForVif(vifIdx: uint8) =
  if vifIdx.int >= MAX_VIFS:
    return
  apmPendingCancelMask = apmPendingCancelMask or (1'u8 shl vifIdx)
  for index in 0 ..< apmPendingAssociations.len:
    let pending = addr apmPendingAssociations[index]
    if pending.vifIdx == vifIdx and
       (pending.request != nil or pending.confirmation != nil):
      let generation = pending.generation
      aidListDelete(addr apmStaSlot(index.uint).macAddr[0])
      if pending.generation == generation:
        apmPendingClear(index)

proc apmStartPendingForVif(vifIdx: uint8): bool =
  let request = apmEnvView().connectInfo
  request != nil and apmStartInfoView(request).vifIdx == vifIdx

proc apmSessionCurrent(vifIdx: uint8; epoch: uint32): bool =
  apmVifRunning(vifIdx) and rxVifEpochs[vifIdx] == epoch

proc apmPrepareRollbackBuffers(): bool =
  var complete = true
  for index in 0 ..< apmRollbackCommands.len:
    if apmRollbackCommands[index] == nil or apmRollbackReplies[index] == nil:
      complete = false
  if complete:
    return true
  for pool in [addr apmRollbackCommands, addr apmRollbackReplies]:
    for message in pool[].mitems:
      if message != nil:
        ke_msg_free(keMsgHdrFromPayload(message))
        message = nil
  for index in 0 ..< apmRollbackCommands.len:
    let id = [ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ, ME_SET_ACTIVE_REQ][index]
    let destination = if index == 1: TASK_MM else: TASK_ME
    let length = if index == 1: MmSetVifStateReqPayloadSize else: MeSetActiveReqPayloadSize
    apmRollbackCommands[index] = ke_msg_alloc(id, destination, TASK_APM, length)
    apmRollbackReplies[index] = ke_msg_alloc(0, TASK_APM, TASK_MM, 1)
    if apmRollbackCommands[index] == nil or apmRollbackReplies[index] == nil:
      for pool in [addr apmRollbackCommands, addr apmRollbackReplies]:
        for message in pool[].mitems:
          if message != nil:
            ke_msg_free(keMsgHdrFromPayload(message))
            message = nil
      return false
  true

proc apmPrepareStartReplies(): bool =
  # Keep the teardown reserve through successful startup for allocation-free stop.
  for reply in apmStartReplyPool.mitems:
    reply = ke_msg_alloc(0, TASK_APM, TASK_MM, 1)
    if reply == nil:
      return false
  apmPrepareRollbackBuffers()

when defined(bl808WifiApHttpSmoke):
  # CLIC mtime low words: request entry, WPA callback enter/leave, ME enqueue/entry.
  var nimfwApTiming {.exportc: "nimfw_ap_timing", wifiCtrl.}: array[5, uint32]
  var nimfwApQueueSnapshot {.exportc: "nimfw_ap_queue_snapshot", wifiCtrl.}: array[5, uint32]

  proc nimfw_ap_snapshot() {.exportc, cdecl.} =
    let saved = irqSave()
    defer: irqRestore(saved)
    nimfwApQueueSnapshot[0] = ke_evt_field_get()
    nimfwApQueueSnapshot[1] = apmStartReplyId.uint32 or
      (apmStartReplyPublished.uint32 shl 16)
    nimfwApQueueSnapshot[2] = ke_state_get(TASK_APM).uint32 or
      (ke_state_get(TASK_ME).uint32 shl 8) or (ke_state_get(TASK_MM).uint32 shl 16)
    if apmStartRequest != nil:
      let node = cast[ptr CoListHdr](keMsgHdrFromPayload(apmStartRequest))
      if co_list_find(addr keMsgQueueSent, node):
        nimfwApQueueSnapshot[3] = 1
      elif co_list_find(addr keMsgQueueSaved, node):
        nimfwApQueueSnapshot[3] = 2
      else:
        nimfwApQueueSnapshot[3] = 3
    nimfwApQueueSnapshot[4] = (meControlCommand != nil).uint32 or
      ((meControlReply != nil).uint32 shl 1)

proc apmSendStartRequest(request: pointer) =
  assert apmStartRequest == nil and apmStartReply == nil
  assert apmStartReplyIndex < apmStartReplyPool.len
  let header = keMsgHdrFromPayload(request)
  apmStartRequest = request
  apmStartReply = apmStartReplyPool[apmStartReplyIndex]
  apmStartReplyPool[apmStartReplyIndex] = nil
  inc apmStartReplyIndex
  apmStartReplyId = header.id + 1
  apmStartReplySource = header.destId
  apmStartReplyPublished = false
  when defined(bl808WifiApHttpSmoke):
    if header.id == ME_SET_ACTIVE_REQ and not apmRollbackActive:
      nimfwApTiming[3] = regRead(ClicMtimeBase)
  ke_msg_send(request)

proc apmTakeStartReply(request: pointer, id: uint16, length: uint32): pointer =
  if request == nil or request != apmStartRequest or id != apmStartReplyId or
     apmStartReply == nil or length > 1:
    return nil
  let source = keMsgHdrFromPayload(request)
  if source.srcId != TASK_APM or source.destId != apmStartReplySource:
    return nil
  let header = keMsgHdrFromPayload(apmStartReply)
  header.id = id
  header.destId = TASK_APM
  header.srcId = source.destId
  header.paramLen = length
  result = apmStartReply
  apmStartRequest = nil
  apmStartReplyPublished = true

proc apmConsumeStartReply(reply: pointer): bool =
  if reply == nil or reply != apmStartReply or not apmStartReplyPublished:
    return false
  let header = keMsgHdrFromPayload(reply)
  if header.destId != TASK_APM or header.id != apmStartReplyId or
     header.srcId != apmStartReplySource:
    return false
  apmStartReply = nil
  apmStartReplyPublished = false
  true

proc apmStartMessageMatches(node: ptr CoListHdr, payload: pointer): bool {.cdecl.} =
  keMsgPayload(cast[ptr KeMsgHdr](node)) == payload

proc apmCancelStartExchange() =
  let request = apmStartRequest
  let reply = apmStartReply
  let replyPublished = apmStartReplyPublished
  apmStartRequest = nil
  apmStartReply = nil
  apmStartReplyPublished = false
  apmStartReplyIndex = 0
  for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
    for payload in [request, (if replyPublished: reply else: nil)]:
      if payload != nil:
        let saved = irqSave()
        let node = ke_queue_extract(queue, apmStartMessageMatches, payload)
        irqRestore(saved)
        if node != nil:
          ke_msg_free(node)
  if reply != nil and not replyPublished:
    ke_msg_free(keMsgHdrFromPayload(reply))
  for reserved in apmStartReplyPool.mitems:
    if reserved != nil:
      ke_msg_free(keMsgHdrFromPayload(reserved))
      reserved = nil

proc apmFreeStartBuffers(keepRollbackBuffers = false) =
  let apm = apmEnvView()
  apmCancelStartExchange()
  while apm.pendingBssParams.first != nil:
    let message = co_list_pop_front(addr apm.pendingBssParams)
    if message != nil: ke_msg_free(message)
  for message in [apmStartBeaconMessage, apmStartVifMessage]:
    if message != nil: ke_msg_free(keMsgHdrFromPayload(message))
  apmStartBeaconMessage = nil
  apmStartVifMessage = nil
  if not keepRollbackBuffers:
    for commands in [addr apmRollbackCommands, addr apmRollbackReplies]:
      for message in commands[].mitems:
        if message != nil:
          ke_msg_free(keMsgHdrFromPayload(message))
          message = nil
  let beacon = apm.pendingBeaconBuffer
  apm.pendingBeaconBuffer = nil
  if beacon != nil:
    let release = blOpsFunc(188)
    if release != nil: cast[proc(p: pointer) {.cdecl.}](release)(beacon)

proc apm_init*() {.exportc, cdecl.} =
  ## Initialize AP management module (20 instrs).
  ## From blob: memset(apm_env, 0, 176), then sets:
  ##   apm_env[12] = 0 (already zero from memset)
  ##   apm_env[88] = 4 (max STA count default)
  ##   apm_env[87] = 0 (STA counter)
  ## Then tail-calls ke_state_set(TASK_APM=5, 0).
  let apm = apmEnvView()
  apmFreeStartBuffers()
  if apmStartConfirmation != nil:
    ke_msg_free(keMsgHdrFromPayload(apmStartConfirmation))
    apmStartConfirmation = nil
  if apm.connectInfo != nil:
    ke_msg_free(keMsgHdrFromPayload(apm.connectInfo))
    apm.connectInfo = nil
  if apmStopRequest != nil:
    ke_msg_free(keMsgHdrFromPayload(apmStopRequest))
    apmStopRequest = nil
  for vifIdx in 0'u8 ..< MAX_VIFS.uint8:
    apmCancelPendingForVif(vifIdx)
  for index in 0 ..< apmPendingAssociations.len:
    apmPendingClear(index)
  apmPendingCancelMask = 0
  apmStoppingVifs = 0
  apmStartSideEffects = false
  apmRollbackActive = false
  apmRollbackHaltPending = false
  apmRollbackStatus = 0
  apmStopActive = false
  apmStopVifIdx = 0xFF
  discard c_memset(apm, 0, sizeof(ApmEnvView).csize_t)  # clear full 176-byte env
  apm.maxSta = 4
  apm.staCount = 0
  ke_state_set(TASK_APM, ApmIdleState)

proc apmFinishStop() =
  let apm = apmEnvView()
  let vifIdx = apmStopVifIdx
  let request = apmStopRequest
  apmStopRequest = nil
  apmFreeStartBuffers()
  if vifChannelForIdx(vifIdx).chanCtxt != nil:
    chan_ctxt_unlink(vifIdx)
  let context = apm.hostapdCtx
  apm.hostapdCtx = nil
  apm.embeddedEnabled = 0
  apm.cryptoType = 0
  discard c_memset(addr apm.securityIe[0], 0, apm.securityIe.len.csize_t)
  if context != nil and wpa_cbs != nil and wpaCallbacks().apStopped != nil:
    discard cast[proc(p: pointer): bool {.cdecl.}](wpaCallbacks().apStopped)(context)
  apmStopActive = false
  apmStoppingVifs = apmStoppingVifs and not (1'u8 shl vifIdx)
  ke_state_set(TASK_APM, ApmIdleState)
  discard ke_reschedule_saved_messages(TASK_MM)
  if request != nil:
    let header = keMsgHdrFromPayload(request)
    let destination = header.srcId
    header.srcId = TASK_APM
    header.destId = destination
    header.id = APM_STOP_CFM
    header.paramLen = 0
    ke_msg_send(request)

proc apmContinueStartRollback() =
  if apmRollbackHaltPending: return
  if apmEnvView().pendingBssParams.first != nil:
    apm_send_next_bss_param(nil)
  else:
    let status = apmRollbackStatus
    apmRollbackActive = false
    apmStartSideEffects = false
    if apmStopActive:
      apmFinishStop()
    else:
      apm_start_cfm(cast[pointer](status.uint))

proc apmBeginStartRollback(status: uint8) =
  let apm = apmEnvView()
  let vifIdx = if apmStopActive: apmStopVifIdx else: apmStartInfoView(apm.connectInfo).vifIdx
  apmRollbackActive = true
  apmRollbackStatus = status
  apmRollbackHaltPending = true
  if not mm_bcn_stop(vifChannelForIdx(vifIdx)):
    return
  apmRollbackHaltPending = false
  let commands = apmRollbackCommands
  let replies = apmRollbackReplies
  apmRollbackCommands = default(typeof(apmRollbackCommands))
  apmRollbackReplies = default(typeof(apmRollbackReplies))
  apmFreeStartBuffers()
  for index in 0 ..< commands.len:
    assert commands[index] != nil and replies[index] != nil
    case index
    of 0:
      let request = cast[ptr MeSetPsDisableReqPayload](commands[index])
      request.disable = 0
      request.vifIdx = vifIdx
    of 1:
      let request = cast[ptr MmSetVifStateReqPayload](commands[index])
      request.state = 0
      request.vifIdx = vifIdx
    else:
      let request = cast[ptr MeSetActiveReqPayload](commands[index])
      request.active = 0
      request.vifIdx = vifIdx
    co_list_push_back(addr apm.pendingBssParams,
                      cast[ptr CoListHdr](keMsgHdrFromPayload(commands[index])))
    apmStartReplyPool[index] = replies[index]
  ke_state_set(TASK_APM, ApmActiveState)
  apmContinueStartRollback()

proc apmResumeHaltRollback() =
  if apmRollbackHaltPending:
    apmBeginStartRollback(apmRollbackStatus)

proc apmVifNeedsStop(vifIdx: uint8): bool =
  let vif = vifChannelForIdx(vifIdx)
  let bit = 1'u32 shl vifIdx
  vif.vifType == VIF_TYPE_AP and
    (vif.state != 0 or vif.beaconEnabled != 0 or vif.chanCtxt != nil or
     ((meEnvView().activeMask or meEnvView().psDisableMask) and bit) != 0 or
     (apmEnvView().vifIdx == vifIdx and apmEnvView().hostapdCtx != nil))

proc apmBeginStop(vifEntry, request: pointer): bool =
  if vifEntry == nil or apmStopActive or apmEnvView().connectInfo != nil:
    return false
  let vif = vifChannelAt(vifEntry)
  let vifIdx = vif.vifIdx
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx) != vif or
      vif.vifType != VIF_TYPE_AP or ke_state_get(TASK_APM) != ApmIdleState:
    return false
  let epoch = rxVifEpochs[vifIdx]
  if not apmPrepareRollbackBuffers():
    return false
  if apmStopActive or apmEnvView().connectInfo != nil or
      rxVifEpochs[vifIdx] != epoch or vif.vifType != VIF_TYPE_AP or
      ke_state_get(TASK_APM) != ApmIdleState:
    return false
  block:
    let saved = irqSave()
    defer: irqRestore(saved)
    var selected: uint8
    if not txlHaltVifQueues(vifIdx, selected): return false
    apmStopActive = true
    apmStopVifIdx = vif.vifIdx
    apmStopRequest = request
    apmStoppingVifs = apmStoppingVifs or (1'u8 shl vif.vifIdx)
    rxInvalidateQuiescentVif(vifIdx, selected)
  apmCancelPendingForVif(vif.vifIdx)
  ke_timer_clear(APM_STA_CONNECT_TIMEOUT_IND, TASK_APM)
  apmBeginStartRollback(0)
  true

proc apmPrepareVifRemoval(vifIdx: uint8): bool =
  # MM must keep a removing VIF registered until its control messages finish.
  if vifIdx >= MAX_VIFS.uint8 or vifChannelForIdx(vifIdx).vifType != VIF_TYPE_AP:
    return true
  if apmStartPendingForVif(vifIdx):
    apm_start_cfm(cast[pointer](1'u))
    return false
  if apmStopActive and apmStopVifIdx == vifIdx:
    return false
  if apmVifNeedsStop(vifIdx):
    discard apmBeginStop(vifChannelForIdx(vifIdx), nil)
    return false
  true

proc apm_start_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Process AP start confirmation.
  ## From blob (135 instrs): param (a0) is status code (0 = success).
  ## On success, sends MM_SET_VIF_STATE_REQ to activate VIF, copies beacon/channel
  ## info from connect info to VIF entry, initializes self-STA in sta_info_tab,
  ## calls me_init_rate on it. Then (both success/failure): fills APM_START_CFM
  ## message with status and vifIdx, sends it, starts connection timeout timer,
  ## frees the connect info, clears apm_env[0], and resets APM state to 0.
  let status = encodedArgU8(param)
  let apm = apmEnvView()
  let connInfo = apm.connectInfo
  if connInfo == nil:
    return
  if apmRollbackActive:
    return
  if status != 0 and apmStartSideEffects:
    apmBeginStartRollback(status)
    return
  let apInfo = apmStartInfoView(connInfo)
  let completedVif = apInfo.vifIdx

  # Allocate APM_START_CFM message (4 bytes)
  let msg = cast[ptr ApmStartCfmPayload](apmStartConfirmation)
  apmStartConfirmation = nil
  if msg == nil:
    apm.connectInfo = nil
    apmFreeStartBuffers()
    ke_msg_free(keMsgHdrFromPayload(connInfo))
    ke_state_set(TASK_APM, ApmIdleState)
    return

  if status == 0:
    # --- Success path ---
    let vifIdx = apInfo.vifIdx
    let vif = vifChannelForIdx(vifIdx)
    let selfStaIdx = vifIdx + 5  # Self-STA index = vifIdx + NX_REMOTE_STA_MAX

    # 1. Send MM_SET_VIF_STATE_REQ to activate VIF
    let msg2 = cast[ptr MmSetVifStateReqPayload](apmStartVifMessage)
    apmStartVifMessage = nil
    if msg2 != nil:
      msg2.state = 1
      msg2.vifIdx = vif.vifIdx
      ke_msg_send(msg2)

    # 2. Copy beacon-related fields from connect info to VIF entry
    vifKeyPointers(vif).flags = apInfo.beaconRateInfo
    vif.psBaCounter = 0
    vif.apStartBeaconInterval = apInfo.vifBeaconInterval

    # 3. Supply the channel-context index (ch_idx), not the RF band.
    let chanPtr = vif.chanCtxt
    if chanPtr != nil:
      msg.channelContextIndex = chanCtxtAt(chanPtr).contextIndexOrMarker

    # 4. Log via g_bl_ops_funcs[204]
    let logFn = getLogFunc(204)
    if logFn != nil:
      cast[proc(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.}](logFn)(
        2, nil, "apm.c", 94, "--- APM start cfm, %s\r\n", cstring"apm_start_cfm")

    # 5. Store AP STA index into msg and apm_env
    msg.staIdx = selfStaIdx
    apm.selfStaIdx = selfStaIdx

    # 6. Initialize self-STA entry in sta_info_tab
    let selfSta = staInfoForIdx(selfStaIdx)
    let selfStaStart = apSelfStaStart(selfSta)

    # Copy 13 bytes of rate info from connect info to STA entry offset 248
    discard c_memcpy(addr selfStaStart.rateSeed[0], connInfo,
                     selfStaStart.rateSeed.len.csize_t)

    # Set STA type to AP
    selfStaStart.vifType = 2

    # Initialize rate control for the self-STA.
    me_init_bcmc_rate(selfSta)

    # Mark self-STA TX power policy refresh work.
    selfStaStart.txPolicyUpdateFlags = selfStaStart.txPolicyUpdateFlags or StaTxPolicyUpdateTxPower
    selfStaStart.status = 1
    selfStaStart.valid = 1
    selfStaStart.infoIdx = selfStaIdx

  # --- Common tail (both success and failure) ---
  # Fill and send APM_START_CFM
  msg.status = status
  msg.vifIdx = apInfo.vifIdx

  # Log
  let logFn2 = getLogFunc(204)
  if logFn2 != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn2)(
      1, nil, "apm.c", 120, "%s: start apm timer\r\n", cstring"apm_start_cfm")

  apm.connectInfo = nil
  apmFreeStartBuffers(status == 0)
  apmStartSideEffects = false
  ke_msg_free(keMsgHdrFromPayload(connInfo))
  ke_state_set(TASK_APM, ApmIdleState)
  if status == 0:
    apmPendingCancelMask = apmPendingCancelMask and not (1'u8 shl completedVif)
    ke_timer_set(APM_STA_CONNECT_TIMEOUT_IND, TASK_APM, 5000000)
  else:
    let vif = vifChannelForIdx(completedVif)
    if vif.chanCtxt != nil: chan_ctxt_unlink(completedVif)
    let context = apm.hostapdCtx
    apm.hostapdCtx = nil
    apm.embeddedEnabled = 0
    apm.cryptoType = 0
    discard c_memset(addr apm.securityIe[0], 0, apm.securityIe.len.csize_t)
    if context != nil and wpa_cbs != nil and wpaCallbacks().apStopped != nil:
      discard cast[proc(p: pointer): bool {.cdecl.}](wpaCallbacks().apStopped)(context)
    discard ke_reschedule_saved_messages(TASK_MM)
  ke_msg_send(msg)

proc apm_stop*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Internal callers use the same confirmed teardown as host stop requests.
  discard apmBeginStop(vifEntry, nil)

proc apm_set_bss_param*(param: pointer): bool {.exportc, cdecl, discardable.} =
  ## Set BSS parameters for AP mode.
  ## Blob (123 instrs): loads APM connect info from apm_env, reads vifIdx,
  ## allocates 5 messages up front, then pushes each onto apm_env+4 list
  ## via co_list_push_back. apm_send_next_bss_param pops and dispatches.
  ## Call sequence: ke_msg_alloc x5, co_list_push_back (PS_DISABLE), memcpy
  ## (BSSID), co_list_push_back (BSSID), me_legacy_rate_bitfield_build,
  ## co_list_push_back (RATES), co_list_push_back (BCN_INT),
  ## co_list_push_back (ACTIVE), apm_send_next_bss_param, ke_state_set.
  let apm = apmEnvView()
  let connInfo = apm.connectInfo
  let apInfo = apmStartInfoView(connInfo)
  let vifIdx = apInfo.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let apmListPtr = addr apm.pendingBssParams

  template pushMsg(msg: pointer) =
    let msgHdr = cast[ptr CoListHdr](keMsgHdrFromPayload(msg))
    co_list_push_back(apmListPtr, msgHdr)

  # Alloc all 5 up front (blob 0x2e..0x78)
  let msgPs     = ke_msg_alloc(ME_SET_PS_DISABLE_REQ,  TASK_ME, TASK_APM,
                               MeSetPsDisableReqPayloadSize)
  let msgBssid  = ke_msg_alloc(MM_SET_BSSID_REQ,        TASK_MM, TASK_APM,
                               MmSetBssidReqPayloadSize)
  let msgRates  = ke_msg_alloc(MM_SET_BASIC_RATES_REQ,  TASK_MM, TASK_APM,
                               MmSetBasicRatesReqPayloadSize)
  let msgBcn    = ke_msg_alloc(MM_SET_BEACON_INT_REQ,   TASK_MM, TASK_APM,
                               MmSetBeaconIntReqPayloadSize)
  let msgActive = ke_msg_alloc(ME_SET_ACTIVE_REQ,       TASK_ME, TASK_APM,
                               MeSetActiveReqPayloadSize)
  let messages = [msgPs, msgBssid, msgRates, msgBcn, msgActive]
  for message in messages:
    if message == nil:
      for owned in messages:
        if owned != nil: ke_msg_free(keMsgHdrFromPayload(owned))
      return false

  # 1. ME_SET_PS_DISABLE_REQ -> push at 0xAC
  if msgPs != nil:
    let req = cast[ptr MeSetPsDisableReqPayload](msgPs)
    req.disable = 1
    req.vifIdx = vifIdx
    pushMsg(msgPs)

  # 2. MM_SET_BSSID_REQ: memcpy (blob 0xBC), push at 0xD8
  if msgBssid != nil:
    let req = cast[ptr MmSetBssidReqPayload](msgBssid)
    discard c_memcpy(addr req.bssid[0], cast[pointer](addr vif.macAddr[0]), 6)
    req.vifIdx = vifIdx
    pushMsg(msgBssid)

  # 3. MM_SET_BASIC_RATES_REQ: rate bitfield (blob 0xEC), push at 0x10A
  if msgRates != nil:
    let req = cast[ptr MmSetBasicRatesReqPayload](msgRates)
    let rateBits = me_legacy_rate_bitfield_build(
      cast[pointer](addr apInfo.staRateSeed[0]), 1)
    req.rateBitfield = rateBits
    req.vifIdx = vifIdx
    req.band = apmStartReqView(connInfo).channel.band
    pushMsg(msgRates)

  # 4. MM_SET_BEACON_INT_REQ -> push at 0x12E
  if msgBcn != nil:
    let req = cast[ptr MmSetBeaconIntReqPayload](msgBcn)
    req.interval = apInfo.beaconInterval
    req.vifIdx = vifIdx
    pushMsg(msgBcn)

  # 5. ME_SET_ACTIVE_REQ -> push at 0x14E
  if msgActive != nil:
    let req = cast[ptr MeSetActiveReqPayload](msgActive)
    req.active = 1
    req.vifIdx = vifIdx
    pushMsg(msgActive)

  # 6. Advance state, then dispatch the queue. AP confirmation handlers
  # require state 1 before the first queued request can complete.
  apmStartSideEffects = true
  ke_state_set(TASK_APM, ApmActiveState)
  apm_send_next_bss_param(param)
  true

proc apm_send_next_bss_param*(param: pointer) {.exportc, cdecl.} =
  ## Send next BSS parameter during AP setup (72 bytes in blob, 18 instrs, apm.o).
  ## Blob: co_list_pop_front(&apm_env+4), assert non-null (line 188),
  ## add 12 to skip ke_msg header, tail-call ke_msg_send.
  let listPtr = addr apmEnvView().pendingBssParams
  let elem = co_list_pop_front(listPtr)
  if elem == nil:
    return
  # Element is the CoListHdr at the start of the ke_msg header.
  let msg = keMsgPayload(cast[ptr KeMsgHdr](elem))
  apmSendStartRequest(msg)

proc apm_bcn_set*(param: pointer) {.exportc, cdecl.} =
  ## Set beacon content for AP mode.
  ## From blob (59 instrs): loads connect info from apm_env[0], allocates
  ## MM_BCN_CHANGE_REQ message (id=45), fills beacon pointer, length, and TIM fields,
  ## optionally copies beacon payload from apm_env[16] and clears it, sends
  ## the message, then tail-calls ke_state_set(TASK_APM, 2).
  let apm = apmEnvView()
  let connInfo = apm.connectInfo
  if connInfo == nil: return
  let apInfo = apmStartInfoView(connInfo)

  # Compute paramLen from beacon length + 12 (header)
  let bcnLen = apInfo.beaconLength
  # Allocate MM_BCN_CHANGE_REQ (msg id 45)
  let msg = cast[ptr MmBcnChangeReqPayload](apmStartBeaconMessage)
  if msg == nil:
    apm_start_cfm(cast[pointer](1'u))
    return
  apmStartBeaconMessage = nil

  # Fill message fields from connect info
  msg.beaconTemplate = apInfo.beaconTemplate
  msg.beaconLength = apInfo.beaconLength
  msg.timOffset = apInfo.timOffset
  msg.timLength = apInfo.timLength
  msg.vifIdx = apInfo.vifIdx

  # Look up VIF entry for beacon buffer copy
  let instNbr = apInfo.vifIdx
  let vif = vifChannelForIdx(instNbr)

  # Check if embedded AP mode is enabled (blob: apm_embedded_enabled at 0x66)
  let embEnabled = apm_embedded_enabled(cast[pointer](vif))
  if embEnabled:
    # Blob copies the separately allocated beacon buffer at apm_env+16 into
    # the MM request, frees it through g_bl_ops_funcs[188], then clears it.
    let bcnDataPtr = apm.pendingBeaconBuffer
    if bcnDataPtr != nil:
      discard c_memcpy(addr msg.beaconData[0], bcnDataPtr, bcnLen.csize_t)
      let freeFnPtr = blOpsFunc(188)
      if freeFnPtr != nil:
        cast[proc(p: pointer) {.cdecl.}](freeFnPtr)(bcnDataPtr)
      apm.pendingBeaconBuffer = nil
  elif apInfo.beaconTemplate != nil:
    discard c_memcpy(addr msg.beaconData[0], apInfo.beaconTemplate, bcnLen.csize_t)

  # Advance APM state to 2
  ke_state_set(TASK_APM, ApmStartingState)
  apmSendStartRequest(cast[pointer](msg))

proc apm_sta_add*(staIdx: uint8): uint8 {.exportc, cdecl.} =
  ## Add a station to AP (association) (38 instrs).
  ## From blob: a0 is the logical station index.
  ## Allocates ke_msg APM_STA_ADD_IND (0x1404), dest=TASK_API(9), src=TASK_APM(5),
  ## paramLen=28. Copies fields from STA entry:
  ##   msg[0..3] = sta[308] (rate config info)
  ##   msg[4..7] = sta[4..7] (MAC addr low)
  ##   msg[8..9] = sta[8..9] (MAC addr high)
  ##   msg[11] = sta[40] (info_idx)
  ##   msg[10] = sta[39] (VIF inst)
  ##   msg[12] = sta[43] (signed byte, capabilities)
  ##   msg[16..19] = sta[12..15] (assoc info)
  ##   msg[20..23] = sta[16..19] (assoc info cont)
  ##   msg[24] = sta[44] (flags byte)
  ## Tail-calls ke_msg_send.
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return 0xFF
  let sta = staInfoForIdx(staIdx)
  let msg = cast[ptr ApmStaAddIndPayload](
    ke_msg_alloc(APM_STA_ADD_IND, TASK_API, TASK_APM,
                 ApmStaAddIndPayloadSize))
  if msg == nil:
    return 0xFF
  msg.rateConfig = sta.capabilityFlags
  msg.macLow = cast[ptr uint32](addr sta.macAddr[0])[]
  msg.macHigh = cast[ptr uint16](addr sta.macAddr[4])[]
  msg.infoIdx = sta.infoIdx
  msg.vifInst = sta.instNbr
  msg.capability = sta.extFlag
  msg.assoc0 = sta.assocInfoWord0
  msg.assoc1 = sta.assocInfoWord1
  msg.flags = sta.paramFlag
  ke_msg_send(msg)
  return 0

proc apm_sta_remove*(vifIdx, staIdx: uint8,
                     statusCode, reasonCode: uint16): bool {.exportc, cdecl.} =
  ## Vendor ABI: VIF index, station index, firmware status, 802.11 reason.
  if vifIdx.int >= MAX_VIFS or staIdx >= STA_MGMT_FREE_STAS.uint8:
    return false
  let vif = vifChannelForIdx(vifIdx)
  let sta = staInfoForIdx(staIdx)
  if vif.vifType != 2 or sta.valid == 0 or sta.instNbr != vifIdx:
    return false
  let epoch = staDeleteEpoch(staIdx)
  var peerMac = sta.macAddr
  let staMac = cast[pointer](addr peerMac[0])
  let logFn = getLogFunc(204)
  if logFn != nil:
    let hw4 = sta.macAddr[0].uint16 or (sta.macAddr[1].uint16 shl 8)
    let hw6 = sta.macAddr[2].uint16 or (sta.macAddr[3].uint16 shl 8)
    let hw8 = sta.macAddr[4].uint16 or (sta.macAddr[5].uint16 shl 8)
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "apm.c", 1090,
      "%s: sta_idx = %d, sta->mac_addr: %x:%x:%x\r\n",
      cstring"apm_sta_remove", staIdx.cint, hw4.cuint, hw6.cuint, hw8.cuint)
  if not staDeleteIsCurrent(staIdx, epoch):
    return false
  apm_send_mlme(cast[pointer](vif), 0xC0'u16, staMac, nil, nil,
                cast[pointer](reasonCode.uint))
  if not staDeleteIsCurrent(staIdx, epoch):
    return false
  apm_sta_delete(staIdx, staMac, statusCode, reasonCode)

proc apm_sta_fw_delete*(staIdx: uint8, statusCode, reasonCode: uint16) {.exportc, cdecl.} =
  ## The second argument is a disconnect status, not a VIF index.
  if staIdx >= STA_MGMT_FREE_STAS.uint8:
    return
  let sta = staInfoForIdx(staIdx)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  discard apm_sta_delete(staIdx, staMacAddr, statusCode, reasonCode)

proc apm_probe_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Infrastructure AP response eligibility (IEEE 802.11-2012 10.1.4.3.2).
  let saved = irqSave()
  defer: irqRestore(saved)
  when defined(bl808WifiApDiscoveryDiag):
    var probeKind = apProbeUnknown
    var outcome = apProbeBadLength
    defer:
      inc apProbeTrace[probeKind].apmEntered
      inc apProbeTrace[probeKind].outcomes[outcome]
  template probeOutcome(value: untyped) =
    when defined(bl808WifiApDiscoveryDiag):
      outcome = value
  if param == nil:
    return
  let header = keMsgHdrFromPayload(param)
  if header.paramLen < ApmProbeReqViewSize:
    return
  let req = apmProbeReqView(param)
  const macHeaderLength = sizeof(MacDataFrameHeaderView).uint32
  const indicationPrefixLength = offsetof(ApmProbeReqView, frame).uint32
  let frameLength = req.frameLen.uint32
  if frameLength < macHeaderLength or frameLength + indicationPrefixLength > header.paramLen:
    return
  when defined(bl808WifiApDiscoveryDiag):
    probeKind = apProbeClassifyForAp(addr req.ies[0], frameLength - macHeaderLength)
  probeOutcome(apProbeNoVif)
  let vifIdx = req.vifIdx
  if vifIdx != 0xFF and vifIdx >= MAX_VIFS.uint8:
    return
  let vif =
    if vifIdx == 0xFF:
      # Search for AP VIF
      let apVif = vif_mgmt_get_first_ap_inf()
      if apVif == nil:
        return
      vifChannelAt(apVif)
    else:
      vifChannelForIdx(vifIdx)
  let resolvedVif = vif.vifIdx
  if resolvedVif >= MAX_VIFS.uint8 or
      vifChannelForIdx(resolvedVif) != vif or not apmVifRunning(resolvedVif) or
      vif.chanCtxt == nil:
    return
  probeOutcome(apProbeWrongAddress)
  const broadcastAddress = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
  if (req.frame.addr1 != broadcastAddress and req.frame.addr1 != vif.macAddr) or
      (req.frame.addr3 != broadcastAddress and req.frame.addr3 != vif.macAddr) or
      (req.frame.addr2[0] and 1) != 0:
    return
  probeOutcome(apProbeBadIes)
  let epoch = rxVifEpochs[resolvedVif]
  let apSsid = vifApProbeSsid(vif)
  template namesAp(ie: ptr MacIeView): bool =
    ie.len != 0 and ie.len == apSsid.ssidLen and
      c_memcmp(addr ie.macIePayload[0], addr apSsid.ssidData[0], ie.len.csize_t) == 0

  let ieLength = frameLength - macHeaderLength
  var offset = 0'u32
  var ssid, rates, ds: ptr MacIeView
  var listMatches, listWildcard: bool
  while offset < ieLength:
    if ieLength - offset < 2:
      return
    let ie = cast[ptr MacIeView](addr req.ies[offset])
    let size = ie.len.uint32 + 2
    if size > ieLength - offset:
      return
    case ie.id
    of IE_ID_SSID:
      if ssid == nil: ssid = ie
    of IE_ID_SUPPORTED_RATES:
      if rates == nil: rates = ie
    of IE_ID_DS_PARAM:
      if ds == nil: ds = ie
    of IE_ID_SSID_LIST:
      let listLength = ie.len.uint32
      var listOffset = 0'u32
      while listOffset < listLength:
        if listLength - listOffset < 2:
          return
        let entry = cast[ptr MacIeView](addr ie.macIePayload[listOffset])
        let entrySize = 2 + entry.len.uint32
        if entry.id != IE_ID_SSID or entry.len > 32 or entrySize > listLength - listOffset:
          return
        if entry.len == 0:
          listWildcard = true
        elif not listMatches:
          listMatches = namesAp(entry)
          if not apmSessionCurrent(resolvedVif, epoch):
            probeOutcome(apProbeRetired)
            return
        listOffset += entrySize
    else: discard
    offset += size

  # Table 8-26 requires both IEs. An absent SSID is not a wildcard.
  if ssid == nil or ssid.len > 32 or rates == nil or rates.len notin 1'u8 .. 8'u8:
    return

  probeOutcome(apProbeWrongChannel)
  template noteDsss(reason, requested, configured, opMhz: untyped) =
    when defined(bl808WifiApDiscoveryDiag):
      if ds != nil:
        apProbeNoteDsss(probeKind, reason, ds.len, requested, configured,
                        rxuMgtIndMsgAt(param).freq, opMhz)
  if ds != nil and ds.len != IE_LEN_DS_PARAM:
    noteDsss(apProbeDsssBadLength, 0, 0, 0)
    return
  let requested = if ds != nil: ds.macIePayload[0] else: 0'u8
  if vif.operChan == nil:
    noteDsss(apProbeDsssNoOperatingChannel, requested, 0, 0)
    return
  let chan = cast[ptr ScanChannelEntry](vif.operChan)
  let freq = chan.prim20Freq
  let channel = phy_freq_to_channel(chan.band, freq)
  if channel == 0:
    noteDsss(apProbeDsssInvalidOperatingChannel, requested, channel, freq)
    return
  if ds != nil:
    if requested != channel:
      noteDsss(apProbeDsssMismatch, requested, channel, freq)
      return
    noteDsss(apProbeDsssMatched, requested, channel, freq)

  let exactMatch = listMatches or namesAp(ssid)
  probeOutcome(apProbeRetired)
  if not apmSessionCurrent(resolvedVif, epoch):
    return
  probeOutcome(apProbeWrongSsid)
  if exactMatch or ((ssid.len == 0 or listWildcard) and apmEnvView().flags == 0):
    probeOutcome(apProbeRespond)
    var extra: pointer = nil
    when defined(bl808WifiApDiscoveryDiag):
      extra = cast[pointer](probeKind.uint)
    apm_send_mlme(cast[pointer](vif), 0x50'u16,
                  cast[pointer](addr req.frame.addr2[0]), nil, nil, extra)

proc apmRxFrameFits(param: pointer; minimumFrameLength: uint32): bool =
  if param == nil:
    return false
  let payloadLength = keMsgHdrFromPayload(param).paramLen
  if payloadLength < 32'u32 + minimumFrameLength:
    return false
  # RX allocations are padded; only frameLen proves the body was received.
  let frameLength = apmRxMgmtPrefix(param).frameLen.uint32
  frameLength >= minimumFrameLength and frameLength <= payloadLength - 32'u32

proc apm_auth_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle authentication frame in AP mode (59 instructions in blob).
  ## a0 = RX frame descriptor (param).
  ## Flow:
  ##   1. Read vifIdx from param[8]; if 0xFF, return.
  ##   2. Get VIF entry from the typed VIF table overlay.
  ##   3. Get STA MAC from param+42.
  ##   4. Look up station by MAC; if not found, try to add one.
  ##   5. Check how many STAs are associated. If > 1, update VIF[338] (STA count)
  ##      and ensure channel context via vif[64].
  ##   6. Tail-call apm_send_mlme(vif, 0xB0, macAddr, nil, nil, nil) to send
  ##      auth response (frame type 0xB0 = authentication = 176).
  if not apmRxFrameFits(param, 30):
    return
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if not apmVifRunning(vifIdx):
    return
  let epoch = rxVifEpochs[vifIdx]
  let vif = vifChannelForIdx(vifIdx)
  let staMac = cast[pointer](addr rx.staMac[0])

  # Look up STA by MAC address via HW search
  let staIdx = hal_machw_search_addr(staMac, 0)
  if not apmSessionCurrent(vifIdx, epoch):
    return

  if staIdx < STA_INFO_TAB_ENTRIES.uint32 and
     staInfoForIdx(staIdx.uint8).instNbr == vifIdx:
    # Station exists: delete it before re-adding
    discard apm_sta_delete(staIdx.uint8, staMac,
      WLAN_FW_APM_DELETESTA_FOR_NEW_CONNECTION.uint16, 0xFFFF'u16)
  if not apmSessionCurrent(vifIdx, epoch):
    return

  # Get channel context count
  let ctxtCnt = chan_ctxt_cnt()
  if not apmSessionCurrent(vifIdx, epoch):
    return
  if ctxtCnt > 1:
    let chanCtxt = vif.chanCtxt
    vif.apChanSwitchPending = 1
    chan_ctxt_trigger(chanCtxt)

  # Send authentication response frame: tail-call apm_send_mlme
  if not apmSessionCurrent(vifIdx, epoch):
    return
  apm_send_mlme(cast[pointer](vif), 0xB0, staMac, nil, nil, nil)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void apm_assoc_req_handler(void*,unsigned long);".}
proc apm_assoc_req_handler*(param: pointer, reassoc: uint32 = 0) {.exportc, cdecl.} =
  ## Parse a received association into the ME station request retained by TX.
  if param == nil:
    return
  let header = keMsgHdrFromPayload(param)
  if header.paramLen < 60:
    return
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  let fixedLength = if reassoc != 0: 34'u32 else: 28'u32
  if vifIdx.int >= MAX_VIFS or rx.frameLen.uint32 < fixedLength or
     rx.frameLen.uint32 + 32 > header.paramLen or (rx.staMac[0] and 1) != 0:
    return
  if not apmVifRunning(vifIdx):
    return
  let epoch = rxVifEpochs[vifIdx]
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifType != 2:
    return
  let apm = apmEnvView()
  let staMac = cast[pointer](addr rx.staMac[0])
  var freeSlot = -1
  for slotIndex in 0'u ..< 5'u:
    let slot = apmStaSlot(slotIndex)
    if slot.active != 0:
      if c_memcmp(addr slot.macAddr[0], staMac, 6.csize_t) == 0:
        return
    elif freeSlot < 0:
      freeSlot = slotIndex.int

  let msg = cast[ptr ApmAssocStaAddIndPayload](
    ke_msg_alloc(ME_STA_ADD_REQ, TASK_ME, TASK_APM,
                 sizeof(ApmAssocStaAddIndPayload).uint32))
  if msg == nil:
    return
  if not apmSessionCurrent(vifIdx, epoch):
    ke_msg_free(keMsgHdrFromPayload(msg))
    return
  msg[] = default(ApmAssocStaAddIndPayload)
  discard c_memcpy(addr msg.macAddr[0], staMac, 6.csize_t)
  msg.vifIdx = vifIdx
  msg.assocWord16 = rx.assocWord16
  msg.assocWord20 = rx.assocWord20
  msg.assocByte24 = rx.assocByte24
  msg.assocByte28 = rx.assocByte28

  let ieBytes = cast[ptr UncheckedArray[uint8]](
    cast[uint](param) + 32'u + fixedLength.uint)
  let ieLength = rx.frameLen.uint32 - fixedLength
  var ssid, rates, extendedRates, ht, wmm, rsn, wpa: ptr MacIeView
  var status = 0'u16
  var offset = 0'u32
  while offset < ieLength:
    if ieLength - offset < 2:
      status = 1
      break
    let ie = cast[ptr MacIeView](addr ieBytes[offset])
    let total = ie.len.uint32 + 2
    if total > ieLength - offset:
      status = 1
      break
    case ie.id
    of 0:
      if ssid == nil: ssid = ie
    of 1:
      if rates == nil: rates = ie
    of 50:
      if extendedRates == nil: extendedRates = ie
    of 45:
      if ht == nil: ht = ie
    of 48:
      if rsn == nil: rsn = ie
    of 221:
      let data = ie.macIePayload
      if ie.len >= 4 and data[0] == 0 and data[1] == 0x50 and data[2] == 0xF2:
        if data[3] == 2 and wmm == nil: wmm = ie
        elif data[3] == 1 and wpa == nil: wpa = ie
    else:
      discard
    offset += total

  let apSsid = vifApProbeSsid(vif)
  if status == 0 and (ssid == nil or ssid.len > 32 or
      ssid.len != apSsid.ssidLen or
      c_memcmp(ssid.macIePayload, addr apSsid.ssidData[0], ssid.len.csize_t) != 0):
    status = 1
  if status == 0 and rx.listenInterval > vifApConfig(vif).maxAssocRate:
    status = 51
  if status == 0 and (rates == nil or rates.len == 0 or rates.len > 8 or
      vif.basicRates[0] == 0 or vif.basicRates[0] > 12):
    status = 18
  if status == 0:
    var peerRates = 0'u32
    for ie in [rates, extendedRates]:
      if ie == nil: continue
      for rateIndex in 0 ..< ie.len.int:
        let rate = me_rate_translate(ie.macIePayload[rateIndex].uint32)
        if rate < 12: peerRates = peerRates or (1'u32 shl rate)
    for rateIndex in 0 ..< vif.basicRates[0].int:
      let rate = vif.basicRates[rateIndex + 1]
      let index = me_rate_translate(rate.uint32)
      let present = index < 12 and (peerRates and (1'u32 shl index)) != 0
      if not present and (rate and 0x80) != 0:
        status = 18
        break
      if present:
        msg.rateBytes[msg.rateCount] = rate
        inc msg.rateCount
    if msg.rateCount == 0: status = 18
  if status == 0 and ht != nil:
    if ht.len != 26:
      status = 1
    else:
      let data = ht.macIePayload
      let caps = cast[ptr VifHtCapabilitiesOverlay](addr msg.htCapabilities[0])
      caps.capInfo = data[0].uint16 or (data[1].uint16 shl 8)
      caps.ampduParams = data[2]
      discard c_memcpy(addr caps.mcsSet[0], addr data[3], 16.csize_t)
      caps.extCap = data[19].uint16 or (data[20].uint16 shl 8)
      caps.txBfCaps = data[21].uint32 or (data[22].uint32 shl 8) or
        (data[23].uint32 shl 16) or (data[24].uint32 shl 24)
      caps.aselCap = data[25]
      msg.flags = msg.flags or 2
  if status == 0 and wmm != nil:
    let data = wmm.macIePayload
    if wmm.len < 7 or data[4] > 1 or data[5] != 1:
      status = 1
    else:
      msg.flags = msg.flags or 1
      msg.uapsdQueues = data[6] and 0x0F
      msg.maxServicePeriod = ((data[6] shr 5) and 3) * 2

  var securityContext, releaseContext: pointer
  if status == 0 and (freeSlot < 0 or apm.staCount >= min(apm.maxSta, 5'u8)):
    status = 17
  if status == 0 and apm.hostapdCtx != nil:
    let securityIe = if rsn != nil: rsn else: wpa
    if securityIe == nil or securityIe.len < 2 or securityIe.len > 253 or wpa_cbs == nil:
      status = 40
    else:
      let join = wpaCallbacks().apJoin
      let remove = wpaCallbacks().disconnect
      if join == nil or remove == nil:
        status = 40
      else:
        releaseContext = remove
        type JoinProc = proc(context: ptr pointer, mac, ie: pointer;
                             length: uint8): bool {.cdecl.}
        if not cast[JoinProc](join)(addr securityContext, staMac,
                                   securityIe, securityIe.len + 2) or securityContext == nil:
          status = 40
          if securityContext != nil:
            discard cast[proc(context: pointer): bool {.cdecl.}](releaseContext)(securityContext)
            securityContext = nil
  if status == 0:
    # A join hook can reenter AP management before this request owns a slot.
    let slot = apmStaSlot(freeSlot.uint)
    if slot.active != 0 or apm.staCount >= min(apm.maxSta, 5'u8):
      status = 17
      if securityContext != nil:
        discard cast[proc(context: pointer): bool {.cdecl.}](releaseContext)(securityContext)
        securityContext = nil
  if not apmSessionCurrent(vifIdx, epoch):
    if securityContext != nil:
      discard cast[proc(context: pointer): bool {.cdecl.}](releaseContext)(securityContext)
    ke_msg_free(keMsgHdrFromPayload(msg))
    return
  if status == 0:
    let slot = apmStaSlot(freeSlot.uint)
    discard c_memcpy(addr slot.macAddr[0], staMac, 6.csize_t)
    slot.staHandle = securityContext
    slot.staIdx = 0xFF
    slot.active = 1
    inc apm.staCount
    msg.aid = (freeSlot + 1).uint16
    apmPendingClear(freeSlot)
    apmPendingAssociations[freeSlot].request = msg
    apmPendingAssociations[freeSlot].vifIdx = vifIdx

  let frameType = if reassoc != 0: 0x30'u16 else: 0x10'u16
  apm_send_mlme(cast[pointer](vif), frameType, staMac,
    cast[pointer](apm_tx_cfm_handler), msg, cast[pointer](status.uint))

proc apm_deauth_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle deauthentication frame in AP mode (similar structure to disassoc, ~50 instrs).
  ## Nearly identical to apm_disassoc_handler but uses type=2 (deauth).
  ##
  ## a0 = RX frame descriptor (param).
  ## Flow:
  ##   1. Read vifIdx from param[8]; if 0xFF, return.
  ##   2. Read staIdx from param[7]; if 0xFF, return.
  ##   3. Extract reason code from param[56..57] (LE16).
  ##   4. Log at line 1054 with reason code.
  ##   5. Get STA MAC from param+42.
  ##   6. Tail-call apm_sta_delete(staIdx, macAddr, 2, reason) to remove STA.
  if not apmRxFrameFits(param, 26):
    return
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return
  let staIdx = rx.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or sta.instNbr != vifIdx:
    return
  if c_memcmp(addr sta.macAddr[0], addr rx.staMac[0], 6.csize_t) != 0:
    return
  let epoch = staDeleteEpoch(staIdx)

  # Extract reason code from param[56..57] (LE16)
  let reason = rx.reason

  # Log
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "apm.c", 1054,
      "Deauth by STA, Wlan802.11 reason code = %d\r\n", reason.cint)

  let staMac = cast[pointer](addr rx.staMac[0])
  if staDeleteIsCurrent(staIdx, epoch):
    discard apm_sta_delete(staIdx, staMac, WLAN_FW_APM_DEATUH_BY_STA.uint16, reason)

proc apm_disassoc_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle disassociation frame in AP mode (58 instructions in blob).
  ## Very similar to apm_deauth_handler but uses frame type 0xC0 (disassoc)
  ## and passes type=3 to the station delete function.
  ##
  ## a0 = RX frame descriptor (param).
  ## Flow:
  ##   1. Read vifIdx from param[8]; if 0xFF, return.
  ##   2. Read staIdx from param[7]; if 0xFF, return.
  ##   3. Extract reason code from param[56..57] (LE16).
  ##   4. Log at line 1074 with reason code.
  ##   5. Get VIF entry from the typed VIF table overlay.
  ##   6. Get STA MAC from param+42.
  ##   7. Call apm_send_mlme(vif, 0xC0, macAddr, nil, nil, nil) to send
  ##      disassociation response.
  ##   8. Tail-call apm_sta_delete(staIdx, macAddr, 3, reason) to remove STA.
  if not apmRxFrameFits(param, 26):
    return
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx.int >= MAX_VIFS:
    return
  let staIdx = rx.staIdx
  if staIdx.int >= STA_INFO_TAB_ENTRIES:
    return
  let sta = staInfoForIdx(staIdx)
  if sta.valid == 0 or sta.instNbr != vifIdx:
    return
  if c_memcmp(addr sta.macAddr[0], addr rx.staMac[0], 6.csize_t) != 0:
    return
  let epoch = staDeleteEpoch(staIdx)

  # Extract reason code from param[56..57] (LE16)
  let reason = rx.reason

  # Log
  let logFn = getLogFunc(204)
  if logFn != nil:
    cast[proc(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.}](logFn)(
      2, nil, "apm.c", 1074,
      "Disassociate by STA, Wlan802.11 reason code = %d\r\n", reason.cint)

  # Get VIF entry from the typed VIF table overlay.
  let vif = vifChannelForIdx(vifIdx)
  let staMac = cast[pointer](addr rx.staMac[0])

  # Send disassociation response
  if not staDeleteIsCurrent(staIdx, epoch):
    return
  apm_send_mlme(cast[pointer](vif), 0xC0, staMac, nil, nil, cast[pointer](2'u))
  if staDeleteIsCurrent(staIdx, epoch):
    discard apm_sta_delete(staIdx, staMac, WLAN_FW_APM_DISASSOCIATE_BY_STA.uint16, reason)

proc apm_beacon_handler*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Handle beacon reception in AP mode.
  ## noinline + asm barrier: blob calls this as a real function from
  ## rxu_mgt_ind_handler/rxu_mgt_ind_handler_apm; without the barrier GCC
  ## elides the call because the body is a no-op.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}

proc apm_embedded_enabled*(vifEntry: pointer): bool {.exportc, cdecl, noinline.} =
  ## Read the embedded flag populated by AP start (apm_env offset 85).
  ## noinline + asm barrier: callers use `discard apm_embedded_enabled(...)`
  ## or call with nil in some branches; without the barrier GCC elides the
  ## call because the return value is unused and the body is side-effect-free.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  let enabled = apmEnvView().embeddedEnabled
  if vifEntry == nil:
    return enabled != 0
  vifChannelAt(vifEntry).vifType == VIF_TYPE_AP and (enabled and 1'u8) != 0

proc apm_get_hostapd_ctx*(): pointer {.exportc, cdecl, noinline.} =
  ## Get hostapd context pointer from apm_env[172] (blob layout; not a
  ## separate global). Previous Nim read a separate Nim-only `hostapd_ctx`
  ## global that is never written by the firmware, so always returned nil.
  ## Blob: `auipc+lw of apm_env+0xac; ret`.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  return apmEnvView().hostapdCtx

proc apm_handle_eapol_input*(staIdx: uint8, rxBuf: pointer, rxLen: uint32) {.exportc, cdecl.} =
  ## Vendor slot 44 receives hostapd, the station's WPA context, and EAPOL.
  let hostapdCtx = apmEnvView().hostapdCtx
  if hostapdCtx == nil or staIdx.int >= STA_INFO_TAB_ENTRIES or
     rxBuf == nil or rxLen == 0 or wpa_cbs == nil:
    return
  let sta = staInfoForIdx(staIdx)
  let eapolHandler = wpaCallbacks().apEapolRx
  if sta.valid == 0 or sta.apmWpaContext == nil or eapolHandler == nil:
    return
  type EapolHandlerFn = proc(ctx, station, buf: pointer; length: csize_t): bool {.cdecl.}
  discard cast[EapolHandlerFn](eapolHandler)(hostapdCtx, sta.apmWpaContext, rxBuf, rxLen.csize_t)

proc apm_handle_auth_done*(param: pointer) {.exportc, cdecl.} =
  ## Handle auth done callback in AP mode.
  ## From blob (7 instrs): param is actually a staIdx (uint8 in a0).
  ## Computes sta_info_tab[staIdx] (stride 368), stores 2 at sta[72] (control-port ready flag).
  let staIdx = encodedArgU8(param)
  staInfoForIdx(staIdx).controlPortState = 2  # control-port ready state at offset 72

proc readApFrameExtras(data: pointer; length: uint32; extras: var ApFrameExtras): bool =
  extras = ApFrameExtras(data: data, length: length)
  if length == 0:
    return true
  if data == nil:
    return false
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  var offset = 0'u32
  while offset < length:
    if length - offset < 2:
      return false
    let size = bytes[offset + 1].uint32 + 2
    if size > length - offset:
      return false
    if bytes[offset] == 7: # Country
      let payloadSize = size - 2
      if extras.countrySize != 0 or payloadSize < 6 or (payloadSize and 1) != 0:
        return false
      # Country string (3 bytes), whole triplets, and zero padding if needed.
      case (payloadSize - 3) mod 3
      of 0: discard
      of 1:
        if bytes[offset + size - 1] != 0: return false
      else: return false
      extras.countryOffset = offset
      extras.countrySize = size
    offset += size
  true

proc appendApFrameExtras(buf: pointer; built, countryAt, capacity: uint32;
                         extras: ApFrameExtras): bool =
  if buf == nil or built > capacity or extras.length > capacity - built or
      countryAt > built:
    return false
  if extras.length == 0:
    return true
  var tail = ieCursorAfter(buf, built.uint)
  if extras.countrySize == 0:
    discard copyIeBytes(tail, extras.data, extras.length.uint)
  else:
    # The TIM and DSSS positions remain stable. Shift only the suffix and
    # keep non-Country extras in their original relative order.
    let slot = ieCursorAfter(buf, countryAt.uint)
    let afterCountry = ieCursorAfter(slot, extras.countrySize.uint)
    discard c_memmove(afterCountry, slot, (built - countryAt).csize_t)
    discard copyIeBytes(slot, ieCursorAfter(extras.data, extras.countryOffset.uint),
                        extras.countrySize.uint)
    tail = ieCursorAfter(tail, extras.countrySize.uint)
    if extras.countryOffset != 0:
      tail = copyIeBytes(tail, extras.data, extras.countryOffset.uint)
    let afterExtraCountry = extras.countryOffset + extras.countrySize
    if afterExtraCountry < extras.length:
      discard copyIeBytes(tail, ieCursorAfter(extras.data, afterExtraCountry.uint),
                          (extras.length - afterExtraCountry).uint)
  true

proc apm_send_mlme*(vifEntry: pointer, frameType: uint16, destAddr: pointer,
    callback: pointer, callbackArg: pointer, extraParam: pointer) {.exportc, cdecl.} =
  ## Send MLME frame in AP mode (auth response, assoc response, deauth, probe rsp).
  ## From blob (160 instrs): allocates 512-byte frame buffer, builds MAC header
  ## with DA=destAddr, SA=BSSID=vifEntry+80 (AP's own MAC), dispatches on frameType:
  ##   0xB0 (auth):    me_build_authenticate(body, 0, 2, 0, nil)
  ##   0xC0 (deauth):  me_build_deauthenticate(body, reason=extraParam)
  ##   0x50 (probe):   me_build_probe_rsp(body, inst_nbr) + extra IEs
  ##   0x10/0x30 (assoc/reassoc rsp): me_build_associate_rsp(body, inst_nbr, extraParam, callbackArg)
  ## Then sets TX descriptor fields and tail-calls txl_frame_push(frame, 3).
  ## Failures before TX accepts the frame complete the callback with 0x40000000.
  let saved = irqSave()
  defer: irqRestore(saved)
  var submitted = false
  defer:
    # Until TX accepts the frame, its callback argument still belongs here.
    if not submitted and callback != nil:
      cast[proc(arg: pointer; flags: uint32) {.cdecl.}](callback)(
        callbackArg, 0x40000000'u32)
  if vifEntry == nil or destAddr == nil:
    return
  let vif = vifChannelAt(vifEntry)
  let instNbr = vif.vifIdx
  if instNbr >= MAX_VIFS.uint8 or vifChannelForIdx(instNbr) != vif:
    return
  let identity = TxSessionIdentity(captured: true, vif: instNbr, station: 0xFF,
    vifEpoch: rxVifEpochs[instNbr], resetEpoch: txResetEpoch)
  # Recovery can release the receive buffer or station that supplied this MAC.
  var destination: array[6, uint8]
  let source = cast[ptr UncheckedArray[uint8]](destAddr)
  for index in 0 ..< destination.len:
    destination[index] = source[index]

  # Allocate 512-byte frame buffer (blob: txl_frame_get, NOT ke_msg_alloc)
  let frame = txl_frame_get(512)
  if frame == nil:
    return

  let desc = hostTxDescAt(frame)
  let generation = txlFrameLeaseToken(desc)
  desc.vifIdx = instNbr
  desc.staInfoIdx = 0xFF
  if not txlFramePreparationCurrent(desc, identity, generation):
    return
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Build MAC header at link.macHeader.
  hdr.frameControl = frameType
  hdr.duration = 0

  # DA = destAddr.
  discard c_memcpy(addr hdr.addr1[0], addr destination[0], 6.csize_t)

  # SA = VIF MAC at vifEntry+80.
  discard c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)

  # BSSID = VIF MAC (same as SA for AP mode).
  discard c_memcpy(addr hdr.addr3[0], addr vif.macAddr[0], 6.csize_t)

  let seqField = nextTxSeqCtrl()
  hdr.seqCtrl = seqField

  # Dispatch on frame type to build frame body after the MAC header.
  let bodyBuf = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  var totalLen: uint32 = 24  # default: MAC header only

  if frameType == 0xB0:
    # Auth response: me_build_authenticate(body, algo=0, seq=2, status=0, challenge=nil)
    let bodyLen = me_build_authenticate(bodyBuf, 0, 2, 0, nil)
    totalLen = bodyLen + 24

  elif frameType == 0xC0:
    # Deauth: me_build_deauthenticate(body, reason)
    let reason = cast[uint16](cast[uint](extraParam))
    let bodyLen = me_build_deauthenticate(bodyBuf, reason)
    totalLen = bodyLen + 24

  elif frameType == 0x50:
    let apm = apmEnvView()
    let customerLength = apm.cryptoType.uint32
    const capacity = TxlFramePayloadSize - 24'u32
    var extras: ApFrameExtras
    var countryAt: uint16
    var bodyLen = 0'u32
    if customerLength <= apm.securityIe.len.uint32 and
        readApFrameExtras(addr apm.securityIe[0], customerLength, extras):
      bodyLen = meBuildProbeResponse(bodyBuf, instNbr,
        capacity - customerLength, nil, addr countryAt)
    if not txlFramePreparationCurrent(desc, identity, generation):
      return
    if bodyLen == 0 or not appendApFrameExtras(bodyBuf, bodyLen, countryAt.uint32,
                                               capacity, extras):
      txl_frame_release(frame, false)
      return
    totalLen = bodyLen + extras.length + 24

  elif (frameType and (not 0x20'u16)) == 0x10:
    # Assoc response (0x10) or reassoc response (0x30)
    # me_build_associate_rsp(body, inst_nbr, extraParam, callbackArg)
    let bodyLen = me_build_associate_rsp(bodyBuf, instNbr,
      (cast[uint](extraParam) and 0xFFFF'u).uint16, callbackArg)
    if bodyLen == 0:
      if txlFramePreparationCurrent(desc, identity, generation):
        txl_frame_release(frame, false)
      return
    totalLen = bodyLen + 24

  if not txlFramePreparationCurrent(desc, identity, generation):
    return
  # Set TX descriptor fields at frame+112
  let txDesc = hostTxHwDescAt(desc.hwDesc)
  let baseLen = txDesc.payloadStart
  txDesc.payloadEnd = baseLen - 1 + totalLen
  txDesc.frameLen = totalLen + 4  # include FCS

  # Frame metadata
  desc.hdrLen = 0
  desc.secTailLen = 0
  desc.vifIdx = instNbr
  desc.staInfoIdx = 0xFF  # no rate override
  desc.callback = callback
  desc.callbackArg = callbackArg

  # Push frame to TX queue (AC=3, management)
  when defined(bl808WifiApDiscoveryDiag):
    var probeKind = apProbeUnknown
    if frameType == 0x50:
      let ordinal = cast[uint](extraParam)
      if ordinal <= high(ApProbeKind).uint:
        probeKind = ApProbeKind(ordinal)
      apProbeMarkBuilt(generation, probeKind)
  submitted = txl_frame_push(frame, 3) != 0
  when defined(bl808WifiApDiscoveryDiag):
    if frameType == 0x50 and submitted:
      inc apProbeTrace[probeKind].submitted

proc aidListDelete(macAddr: pointer) {.exportc: "aid_list_delete", cdecl, noinline.} =
  ## Detach the slot before releasing its opaque WPA state: callbacks may reenter.
  if macAddr == nil:
    return
  let apm = apmEnvView()
  for apmStaSlotIndex in 0'u32 ..< 5'u32:
    let aidListStaSlot = apmStaSlot(apmStaSlotIndex.uint)
    if aidListStaSlot.active == 0 or
       c_memcmp(addr aidListStaSlot.macAddr[0], macAddr, 6.csize_t) != 0:
      continue
    let context = aidListStaSlot.staHandle
    let staIdx = aidListStaSlot.staIdx
    let pending = apmPendingAssociations[apmStaSlotIndex]
    var unpublishedSta = -1
    if pending.confirmation != nil:
      let cfm = apmStaAddCfmParamView(pending.confirmation)
      if cfm.status == 0 and cfm.staIdx.int < STA_INFO_TAB_ENTRIES:
        let sta = staInfoForIdx(cfm.staIdx)
        if sta.valid != 0 and sta.instNbr == pending.vifIdx and
           c_memcmp(addr sta.macAddr[0], addr aidListStaSlot.macAddr[0], 6.csize_t) == 0:
          unpublishedSta = cfm.staIdx.int
    apmPendingClear(apmStaSlotIndex.int)
    discard c_memset(addr aidListStaSlot.macAddr[0], 0, 6.csize_t)
    aidListStaSlot.active = 0
    aidListStaSlot.staHandle = nil
    aidListStaSlot.staIdx = 0xFF
    if apm.staCount != 0: dec apm.staCount
    if staIdx.int < STA_INFO_TAB_ENTRIES:
      let sta = staInfoForIdx(staIdx)
      if sta.apmWpaContext == context: sta.apmWpaContext = nil
    if unpublishedSta >= 0:
      mm_sta_del(unpublishedSta.uint8)
    if context != nil and wpa_cbs != nil:
      let remove = wpaCallbacks().disconnect
      if remove != nil:
        discard cast[proc(context: pointer): bool {.cdecl.}](remove)(context)
    return

proc apm_tx_cfm_handler*(param: pointer; txStatus: uint32) {.exportc, cdecl.} =
  ## Handle TX confirmation in AP mode (31 instrs).
  ## On ACK, queue the retained ME station request if it still owns an AID.
  ## Otherwise roll back a failed association and release its message.
  if param == nil:
    return
  let msg = cast[ptr ApmAssocStaAddIndPayload](param)
  let pendingSlot = apmPendingRequestSlot(param, false)
  if msg.aid != 0 and pendingSlot < 0:
    ke_msg_free(keMsgHdrFromPayload(param))
    return
  if (txStatus and 0x00800000'u32) != 0:
    if msg.aid != 0:
      apmPendingAssociations[pendingSlot].meQueued = true
      ke_msg_send(param)
      return
  else:
    if msg.aid != 0:
      aidListDelete(param)
    let logFn = blOpsFunc(4)
    if logFn != nil:
      cast[proc(format: cstring) {.cdecl, varargs.}](logFn)(
        "apm mlme assoc rsp send failed:%d,aid:%d\n", cast[cint](txStatus), msg.aid.cint)
  ke_msg_free(keMsgHdrFromPayload(param))

proc apmPsCapture(staEntry: pointer): ApmPsSession =
  # Callers hold interrupts while identifying the table slot and its session.
  if staEntry == nil:
    return
  for index in 0'u8 ..< STA_INFO_TAB_ENTRIES.uint8:
    let sta = staInfoForIdx(index)
    if cast[pointer](sta) != staEntry:
      continue
    if sta.instNbr >= MAX_VIFS.uint8 or
        (index < STA_MGMT_FREE_STAS.uint8 and sta.valid == 0):
      return
    result = ApmPsSession(captured: true, station: index, vif: sta.instNbr,
      aid: sta.aid, stationEpoch: staDeleteEpoch(index),
      vifEpoch: rxVifEpochs[sta.instNbr])
    return

proc apmPsSessionCurrent(identity: ApmPsSession): bool =
  if not identity.captured or identity.vif >= MAX_VIFS.uint8 or
      identity.station >= STA_INFO_TAB_ENTRIES.uint8 or
      rxVifEpochs[identity.vif] != identity.vifEpoch or
      staDeleteEpoch(identity.station) != identity.stationEpoch:
    return false
  let sta = staInfoForIdx(identity.station)
  sta.instNbr == identity.vif and sta.aid == identity.aid and
    (identity.station >= STA_MGMT_FREE_STAS.uint8 or sta.valid != 0) and
    vifChannelForIdx(identity.vif).vifType == VIF_TYPE_AP

proc apmPsTimRequest(identity: ApmPsSession; requiredTraffic, setFlag: uint8;
                     clearMask: uint8 = 0xFF) =
  if not apmPsSessionCurrent(identity):
    return
  let msg = cast[ptr MmTimUpdatePayload](
    ke_msg_alloc(MM_TIM_UPDATE_REQ, TASK_MM, TASK_ME, MmTimUpdatePayloadSize))
  if msg == nil:
    return
  if not apmPsSessionCurrent(identity) or
      (setFlag == 0 and
       (staInfoForIdx(identity.station).trafficFlags and clearMask) != 0) or
      (setFlag != 0 and
       (staInfoForIdx(identity.station).trafficFlags and requiredTraffic) == 0):
    ke_msg_free_payload(msg)
    return
  msg.aid = identity.aid
  msg.setFlag = setFlag
  msg.vifIdx = identity.vif
  ke_msg_send(msg)

proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.} =
  ## Defer AP traffic to sleeping stations outside an active service period.
  ## The multi-channel special case permits CTS frames, then the ordinary
  ## VIF/station power-save checks still apply to every other frame.
  let tx = apmTxDescPsAt(txDesc)
  if chan_ctxt_cnt() > 1 and (tx.pbufAddr == 0 or tx.etherType == 0):
    let link = hostTxLinkDescAt(tx.linkDesc)
    let frameControl = link.macHeader[0].uint16 or (link.macHeader[1].uint16 shl 8)
    if frameControl == 0x00C4'u16:
      return true

  if vifChannelForIdx(tx.vifIdx).vifType != VIF_TYPE_AP:
    return true
  if tx.staIdx > 6:
    return true
  let sta = staInfoForIdx(tx.staIdx)
  if sta.psMode != 1 or (sta.psStatus and 3) != 0:
    return true
  tx.postponeFlags = tx.postponeFlags or 0x1000
  return false

proc apm_tx_int_ps_postpone*(txDesc: pointer, staEntry: pointer) {.exportc, cdecl.} =
  ## Mark newly buffered internal traffic and update TIM for legacy delivery
  ## or when every AC is delivery-enabled, as in the vendor path.
  let saved = irqSave()
  defer: irqRestore(saved)
  if txDesc == nil:
    return
  let identity = apmPsCapture(staEntry)
  if not apmPsSessionCurrent(identity):
    return
  let tx = apmTxDescPsAt(txDesc)
  let sta = staInfoAt(staEntry)
  if tx.vifIdx != identity.vif or tx.staIdx != identity.station or
      tx.accessCategory >= 4 or (tx.postponeFlags and 0x1000) == 0:
    return
  let delivMask = sta.psState
  let uapsdDelivery = (mac_ac2uapsd[tx.accessCategory] and delivMask) != 0
  let trafficBit = if uapsdDelivery: 0x08'u8 else: 0x02'u8
  let psFlags = sta.trafficFlags
  if (psFlags and trafficBit) != 0:
    return
  sta.trafficFlags = psFlags or trafficBit
  if not uapsdDelivery or delivMask == 0x0F:
    apmPsTimRequest(identity, trafficBit, 1)

proc apmPsHasMore(queue: ptr CoList; deliveryMask: uint8; uapsdService: bool): bool =
  var node = queue.first
  while node != nil:
    let ac = apmTxDescPsAt(cast[pointer](node)).accessCategory
    if ac < 4 and ((mac_ac2uapsd[ac] and deliveryMask) != 0) == uapsdService:
      return true
    node = node.next

proc apm_tx_int_ps_get_postpone*(vifEntry: pointer, staEntry: pointer, postponeFlag: ptr uint32): pointer {.exportc, cdecl.} =
  ## Select a postponed frame for the current power-save service period,
  ## then update buffered-traffic flags, TIM, and the More Data header bit.
  let saved = irqSave()
  defer: irqRestore(saved)
  if postponeFlag == nil:
    return nil
  if vifEntry == nil or staEntry == nil:
    postponeFlag[] = 1
    return nil
  let vifView = vifChannelAt(vifEntry)
  let sta = staInfoAt(staEntry)
  let vifType = vifView.vifType
  if vifType != VIF_TYPE_AP:
    postponeFlag[] = 0; return nil
  let identity = apmPsCapture(staEntry)
  if not apmPsSessionCurrent(identity) or
      cast[pointer](vifChannelForIdx(identity.vif)) != vifEntry:
    postponeFlag[] = 1
    return nil
  if not staPostponedListValid(addr sta.postponedList):
    postponeFlag[] = 1
    return nil
  let psStatus = sta.psStatus
  if psStatus == 0:
    postponeFlag[] = 0; return nil
  var hostTrafficBit, internalTrafficBit: uint8
  if (psStatus and 1) != 0:
    hostTrafficBit = 1; internalTrafficBit = 2
  else:
    hostTrafficBit = 4; internalTrafficBit = 8
  let staFlags = sta.trafficFlags
  if (staFlags and internalTrafficBit) == 0:
    postponeFlag[] = 1; return nil
  let delivMask = sta.psState
  var postponedTxDesc = cast[pointer](sta.postponedList.first)
  var previousPostponedTxDesc: pointer = nil
  let uapsdService = psStatus == 2
  while postponedTxDesc != nil:
    let postponedDesc = apmTxDescPsAt(postponedTxDesc)
    let ac = postponedDesc.accessCategory
    if ac >= 4:
      assert_warn("apm.c", "apm.c", 377)
      postponeFlag[] = 1
      return nil
    let uapsdDelivery = (mac_ac2uapsd[ac] and delivMask) != 0
    if uapsdDelivery == uapsdService:
      co_list_remove(addr sta.postponedList, cast[ptr CoListHdr](previousPostponedTxDesc), cast[ptr CoListHdr](postponedTxDesc))
      let selected = cast[ptr CoListHdr](postponedTxDesc)
      selected.next = nil
      var batch = TxFlushBatch(previous: txActiveFlush,
        postponed: CoList(first: selected, last: selected))
      txActiveFlush = addr batch
      defer: txlFlushScopeExit(batch.previous)
      let generation = txlFrameLeaseToken(hostTxDescAt(postponedTxDesc))
      # th.extu ...,3,3 extracts service-period bit 3, not bits 1:0.
      postponedDesc.accessCategory = 3'u8 + ((sta.psStatus shr 3) and 1).uint8
      let hasMoreDeliverablePostponedTx =
        apmPsHasMore(addr sta.postponedList, delivMask, uapsdService)
      var moreData = hasMoreDeliverablePostponedTx
      if not hasMoreDeliverablePostponedTx:
        let remainingTraffic = sta.trafficFlags and (not internalTrafficBit)
        sta.trafficFlags = remainingTraffic
        moreData = (remainingTraffic and hostTrafficBit) != 0
        if not moreData:
          apmPsTimRequest(identity, 0, 0, hostTrafficBit or internalTrafficBit)
      if batch.postponed.first != selected:
        postponeFlag[] = 1
        return nil
      if not txlFrameLeaseMatches(hostTxDescAt(postponedTxDesc), generation):
        batch.postponed = default(CoList)
        postponeFlag[] = 1
        return nil
      if not apmPsSessionCurrent(identity):
        postponeFlag[] = 1
        txlDrainRetiredPostponed(addr batch.postponed)
        return nil
      if sta.psStatus != psStatus or sta.psState != delivMask:
        # A changed service period must select this frame again under its new policy.
        postponedDesc.accessCategory = ac
        co_list_push_front(addr sta.postponedList, selected)
        batch.postponed = default(CoList)
        let newDelivery = (mac_ac2uapsd[ac] and sta.psState) != 0
        let newTrafficBit = if newDelivery: 8'u8 else: 2'u8
        sta.trafficFlags = sta.trafficFlags or newTrafficBit
        let needsTim = not newDelivery or sta.psState == 0x0F
        postponeFlag[] = 1
        ke_evt_set(256)
        if needsTim:
          apmPsTimRequest(identity, newTrafficBit, 1)
        return nil
      let stillMore = apmPsHasMore(addr sta.postponedList, delivMask, uapsdService)
      if stillMore:
        sta.trafficFlags = sta.trafficFlags or internalTrafficBit
      else:
        sta.trafficFlags = sta.trafficFlags and not internalTrafficBit
      moreData = stillMore or (sta.trafficFlags and hostTrafficBit) != 0
      if moreData:
        let link = hostTxLinkDescAt(postponedDesc.linkDesc)
        link.macHeader[1] = link.macHeader[1] or 0x20'u8
      batch.postponed = default(CoList)
      return postponedTxDesc
    previousPostponedTxDesc = postponedTxDesc
    postponedTxDesc = cast[pointer](cast[ptr CoListHdr](postponedTxDesc).next)
  assert_warn("apm.c", "apm.c", 377)
  postponeFlag[] = 1
  return nil

proc apm_tx_int_ps_clear*(vifEntry: pointer, staIdx: uint8) {.exportc, cdecl.} =
  ## Clear PS postpone buffer for station (41 instrs).
  ## From blob: a0=vifEntry, a1=staIdx. Checks vifEntry+86 (type) == 2
  ## (AP mode). If not AP, returns. Computes STA entry = sta_info_tab +
  ## staIdx*368, flushes postponed frames, then checks staEntry+73 (PS flags)
  ## bits [1,3] (0x0A). If zero, returns. Clears bits (AND 0xF5), stores.
  ## If result is zero, allocates ke_msg for TIM update (clear bit).
  ## msg[0..1] = sta+36 (AID), msg[2] = 0 (clear), msg[3] = sta+39 (inst).
  ## Tail-calls ke_msg_send.
  let saved = irqSave()
  defer: irqRestore(saved)
  if vifEntry == nil or staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let vif = vifChannelAt(vifEntry)
  if vif.vifType != VIF_TYPE_AP:
    return  # Not AP mode
  let sta = staInfoForIdx(staIdx)
  let identity = apmPsCapture(sta)
  if not apmPsSessionCurrent(identity) or
      cast[pointer](vifChannelForIdx(identity.vif)) != vifEntry:
    return
  discard sta_mgmt_send_postponed_frame(vifEntry, cast[pointer](sta), 0)
  if not apmPsSessionCurrent(identity):
    return

  let psFlags = sta.trafficFlags
  if (psFlags and 0x0A) == 0:
    return
  let newFlags = psFlags and 0xF5'u8
  sta.trafficFlags = newFlags
  if newFlags != 0:
    return

  apmPsTimRequest(identity, newFlags, 0)

# ###########################################################################
#                   ME: Management Entity
# ###########################################################################

proc me_init*() {.exportc, cdecl.} =
  ## Initialize management entity. Blob:
  ##   memset(me_env, 0, 136)
  ##   ke_state_set(TASK_ME=3, 0)
  ##   scanu_init(); apm_init(); sm_init(); bam_init()
  meControlReset()
  discard c_memset(addr me_env[0], 0, 136.csize_t)
  meEnvView().requesterId = TASK_NONE
  ke_state_set(TASK_ME, MeIdleState)
  nimFwTrace("[WIFI-NIMFW] scanu_init begin")
  scanu_init()
  nimFwTrace("[WIFI-NIMFW] scanu_init done")
  nimFwTrace("[WIFI-NIMFW] apm_init begin")
  apm_init()
  nimFwTrace("[WIFI-NIMFW] apm_init done")
  nimFwTrace("[WIFI-NIMFW] sm_init begin")
  sm_init()
  nimFwTrace("[WIFI-NIMFW] sm_init done")
  nimFwTrace("[WIFI-NIMFW] bam_init begin")
  bam_init()
  nimFwTrace("[WIFI-NIMFW] bam_init done")

proc meTryInitRate(staEntry: pointer): bool =
  ## Do not refresh policy or activate a station after a returning diagnostic.
  if not rcTryInitStation(staEntry):
    return false
  discard me_update_buffer_control(staEntry)
  true

proc me_init_rate*(staEntry: pointer) {.exportc, cdecl.} =
  discard meTryInitRate(staEntry)

proc me_init_bcmc_rate*(staEntry: pointer) {.exportc, cdecl.} =
  ## Initialize broadcast/multicast rate for a station entry.
  ## From blob (35 instrs): a0 is a sta_info_tag pointer.
  ## Loads rate count from sta+248, asserts non-zero.
  ## Loops over rates at sta+249, finds max rate (masking bit 7).
  ## Calls me_rate_translate(maxRate), then rc_init_bcmc_rate(sta, rateIdx).
  ## Clears sta+334 (RC flags byte).
  if staEntry == nil:
    return
  let sta = staInfoAt(staEntry)
  let start = apSelfStaStart(sta)
  let rateCount = start.rateSeed[0]
  if rateCount == 0 or rateCount.int >= start.rateSeed.len:
    assert_err("me.c", "me.c", 510)
    return
  # Loop scanning rates at sta+249, find max rate (masking bit 7)
  var maxRate: uint32 = 0
  var rateIndex: uint32 = 0
  let rateCountU = rateCount.uint32
  while rateIndex < rateCountU:
    let rate = start.rateSeed[1 + rateIndex.int]
    let unmasked = rate.uint32 and 0x7F'u32
    if unmasked > maxRate:
      maxRate = rate.uint32 and 0x7F'u32
    inc rateIndex
  # Convert max rate to rate index, then set bcmc rate
  # Blob: mv a1,a0 (rateIdx); mv a0,s0 (sta); call rc_init_bcmc_rate
  let rateIdx = me_rate_translate(maxRate)  # blob: me_rate_translate (not me_legacy_ridx_min)
  if rateIdx > 11:
    return
  rc_init_bcmc_rate(staEntry, rateIdx)
  start.txPolicyUpdateFlags = 0

proc me_add_chan_ctx*(contextIndex: ptr uint8, chanInfo: pointer, centerFreq1: uint32,
    centerFreq2: uint32, channelWidth: uint8): uint8 {.exportc, cdecl.} =
  ## The first argument is an output pointer; zero is the vendor success code.
  if contextIndex == nil or chanInfo == nil or centerFreq1 > 65535 or centerFreq2 > 65535:
    return 1
  let chan = cast[ptr ScanChannelEntry](chanInfo)
  var chanDef = default(ChanCtxtDefView)
  chanDef.band = chan.band
  chanDef.chanType = channelWidth
  chanDef.primFreq = chan.prim20Freq
  chanDef.centerFreq1 = centerFreq1.uint16
  chanDef.centerFreq2 = centerFreq2.uint16
  chanDef.txPower = cast[uint8](chan.txPower)
  chan_ctxt_add(cast[pointer](addr chanDef), contextIndex)

proc me_beacon_check*(vifIdx: uint8, frameLength: uint16, frame: pointer) {.exportc, cdecl.} =
  ## The vendor ABI supplies the full beacon length, not a descriptor pointer.
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if vifIdx >= MAX_VIFS.uint8 or frame == nil or frameLength < 36:
    return
  let vif = vifChannelForIdx(vifIdx)
  let vifEpoch = rxVifEpochs[vifIdx]
  let poolEpoch = mmBcnGeneration
  let vifType = vif.vifType
  let contextPtr = vif.chanCtxt
  let bindingEpoch = chanCtxtLinkEpochs[vifIdx]
  let chanPtr = vif.operChan
  let chan = if chanPtr != nil: cast[ptr ScanChannelEntry](chanPtr) else: nil
  if chan == nil:
    return
  template current(): bool =
    rxVifEpochs[vifIdx] == vifEpoch and
      (vifType != VIF_TYPE_AP or mmBcnGeneration == poolEpoch) and
      vif.vifType == vifType and vif.operChan == chanPtr and
      vif.chanCtxt == contextPtr and chanCtxtLinkEpochs[vifIdx] == bindingEpoch
  let iesBuf = cast[pointer](cast[uint](frame) + 36)
  let iesLength = frameLength.uint32 - 36
  var ieCursor = cast[uint](iesBuf)
  if iesLength.uint > high(uint) - ieCursor:
    return
  var ieRemaining = iesLength
  while ieRemaining != 0:
    if ieRemaining < 2:
      return
    let ie = macIeAt(ieCursor)
    let size = ie.len.uint32 + 2'u32
    if size > ieRemaining or
        (ie.id in [32'u8, 42'u8] and ie.len != 1):
      return
    ieCursor += size.uint
    ieRemaining -= size
  let bss = vifBssStatus(vif)
  let previousBandwidth = bss.phyBandwidth
  let previousConstraint = bss.powerConstraint
  bss.protectionFlags = 0
  if chan.band == 0:
    let erp = cast[ptr MacIeView](mac_ie_find(iesBuf, iesLength, 42))
    if erp != nil and erp.len == 1:
      bss.protectionFlags = (erp.macIePayload[0] and 7).uint16
  me_extract_power_constraint(iesBuf, iesLength, vifBssInfoBase(vif))
  if bss.powerConstraint != previousConstraint:
    # A large received constraint must not wrap into a positive TX power.
    var power = max(chan.txPower.int - bss.powerConstraint.int,
                    low(int8).int).int8
    var powerIndex: uint8
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
    tpc_update_vif_tx_power(cast[pointer](vif), addr power, addr powerIndex)
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if not current():
      return
  if bss.phyBandwidth > previousBandwidth and contextPtr != nil:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
    let update = cast[ptr MmChanCtxtUpdatePayload](
      ke_msg_alloc(MM_CHAN_CTXT_UPDATE_REQ, TASK_MM, TASK_ME,
                   MmChanCtxtUpdatePayloadSize))
    discard irqSave()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    if update != nil:
      let valid = current() and vif.chanCtxt == contextPtr
      var publish = false
      if valid:
        # Allocation can update this binding's channel parameters.
        let context = chanCtxtAt(contextPtr)
        update[] = MmChanCtxtUpdatePayload(
          ctxtIdx: context.contextIndexOrMarker,
          band: chan.band,
          secChan: bss.phyBandwidth,
          primFreq: chan.prim20Freq,
          centerFreq1: vif.channelFreqPair.uint16,
          centerFreq2: (vif.channelFreqPair shr 16).uint16,
          txPower: context.channel.txPower)
        publish = chanUpdateBindVif(update, vifIdx)
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      irqRestore(saved)
      if publish:
        ke_msg_send(update)
      else:
        ke_msg_free(keMsgHdrFromPayload(update))
      discard irqSave()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}

proc me_bw_check*(param: pointer) {.exportc, cdecl.} =
  ## Reset BSS bandwidth and seed its center frequency from the primary channel.
  if param == nil:
    return
  let bss = bssChannelAt(param)
  let channel = cast[ptr ScanChannelEntry](bss.channel)
  let primaryFreq = if channel != nil: channel.prim20Freq else: 0'u16
  bss.bandwidth = 0
  bss.centerFreq2 = 0
  bss.centerFreq1 = primaryFreq

proc me_check_rc*(staIdx: uint8) {.exportc, cdecl, noinline.} =
  ## Check rate control for a station.
  ## From blob (2 instrs): tail-call to rc_check(staIdx).
  rc_check(staIdx)

proc me_set_sta_ht_vht_param*(staEntry: pointer, param: pointer): bool
    {.exportc, cdecl, discardable.} =
  ## Reset station bandwidth state and copy the configured STBC NSS limit.
  if staEntry == nil:
    return false
  let stbcNss = meEnvView().nss
  let sta = staInfoAt(staEntry)
  sta.bwConfigState = 0'u8
  sta.nssBwMax = 0'u8
  sta.htVhtConfig = stbcNss
  false

proc me_update_buffer_control*(sta: pointer): pointer {.exportc, cdecl.} =
  ## Update TX buffer control for a station.
  ## Reads the RC stats and TX policy descriptor, updates the rate control
  ## fields based on current rate entries, then writes the new policy to HW.
  if sta == nil:
    return nil
  let staView = staInfoAt(sta)
  let txPolicyUpdateFlags = staView.txPolicyUpdateFlags[0]
  let txPolicy = staView.txPolicy
  if txPolicyUpdateFlags == 0 or txPolicy == nil:
    return txPolicy
  if (txPolicyUpdateFlags and StaTxPolicyUpdateRateControl) != 0:
    let stats = staView.rcStats
    if stats == nil or staView.instNbr >= MAX_VIFS.uint8:
      return txPolicy
    let sampleCount = rcU16(stats, RCS_N_RATES)
    if sampleCount == 0 or sampleCount > RC_MAX_RATE_ENTRIES.uint16:
      return txPolicy
    let retryRotate = rcU8(stats, RCS_ANOTHER_FLAG)
    for acIdx in 0 ..< 4:
      let retrySlot = (retryRotate.uint32 + acIdx.uint32) and 3'u32
      if rcU16(stats, 0x80 + retrySlot.int * 8) >= sampleCount:
        return txPolicy
  let policy = txPolicyAt(txPolicy)

  # Mirror the vendor stack copies before updating the descriptor under IRQ.
  var policyWord = policy.bufferAddr
  var rateWords: array[4, uint32]
  var txPowerWords: array[4, uint32]
  for acIdx in 0 ..< 4:
    rateWords[acIdx] = policy.retryRate[acIdx]
    txPowerWords[acIdx] = policy.txPower[acIdx]

  if (txPolicyUpdateFlags and StaTxPolicyUpdateRateControl) != 0:
    # RC active: update retry-chain rate words from RC stats.
    let rcStats = staView.rcStats
    let vifIdx = staView.instNbr
    let vif = vifChannelForIdx(vifIdx)
    let vifHtCaps = vifHtCapabilities(vif)
    let retryRotate = rcU8(rcStats, RCS_ANOTHER_FLAG) # 0xB0
    let staStbcNss = staView.htVhtConfig
    let preserveStationRates = when defined(bl808WifiNativeWlanCalibration):
      vif.vifType == VIF_TYPE_STA and rcU8(rcStats, RCS_GROUP_CNT) == 0 and
        rcU8(rcStats, RCS_FORMAT_MOD) == RC_FORMATMOD_HT_MF
    else:
      false

    rcU8(rcStats, 0xBF) = vifHtCaps.mcsSet[12]

    var foundSameNssChain: uint8 = 0
    var firstNssGroup: uint32 = 0
    var selectedGroup: uint8 = 0xFF'u8

    for acIdx in 0 ..< 4:
      let retrySlot = (retryRotate.uint32 + acIdx.uint32) and 0x3'u32
      let retryIdx = rcU16(rcStats, 0x80 + retrySlot.int * 8)
      let rateConfig = rcRateConfig(rcStats, retryIdx.int)
      var rateWord = (rateConfig.uint32 and 0x3FFF'u32) or 0x80000000'u32

      if ((rateWord shr 11) and 0x6'u32) != 0:
        var mcsOrGroup = rateWord and 0x7F'u32
        # Native 1SS station samples already obey the negotiated peer bitmap.
        # Substituting the VIF's highest MCS here would collapse the retry chain.
        if not preserveStationRates:
          let vifBitmap = vifHtCaps.mcsSet[acIdx]
          rcU8(rcStats, RCS_RATE_BITMAP + acIdx) = vifBitmap

          if acIdx == 0:
            var search = 7'i32
            while search >= 0:
              if (vifBitmap and (1'u8 shl search.uint8)) != 0:
                selectedGroup = search.uint8
                break
              dec search
            if selectedGroup != 0xFF'u8:
              rcU8(rcStats, RCS_MAX_NSS_MCS) = selectedGroup
              mcsOrGroup = selectedGroup.uint32
          elif selectedGroup != 0xFF'u8:
            rcU8(rcStats, RCS_MAX_NSS_MCS) = selectedGroup
            mcsOrGroup = selectedGroup.uint32

          if (rcU8(rcStats, RCS_FLAGS) and 0x40'u8) == 0:
            rateWord = (rateWord and not 0x7F'u32) or mcsOrGroup

        # th.extu ...,4,3 extracts the two-bit zero-based NSS for STBC.
        let nssGroup = (mcsOrGroup shr 3) and 0x3'u32
        if acIdx == 0:
          if nssGroup < staStbcNss.uint32:
            firstNssGroup = nssGroup
            foundSameNssChain = 1
        elif foundSameNssChain != 0:
          foundSameNssChain = (if nssGroup == firstNssGroup: 1'u8 else: 0'u8)

      rateWords[acIdx] = rateWord or (rateWords[acIdx] and 0x1FFFC000'u32)

    policyWord = policyWord and (not 0x180'u32)
    if foundSameNssChain != 0:
      policyWord = policyWord or ((firstNssGroup + 1'u32) shl 7)

    staView.txPolicyUpdateFlags[0] = staView.txPolicyUpdateFlags[0] or
      (StaTxPolicyUpdateAggregationLength or StaTxPolicyUpdateTxPower)

  # Check bit 2 (needs descriptor update), matching vendor's temporary chain.
  if (staView.txPolicyUpdateFlags[0] and StaTxPolicyUpdateAggregationLength) != 0:
    for acIdx in 0 ..< 4:
      let rateWord = rateWords[acIdx]
      let formatBits = (rateWord shr 11) and 0x7'u32
      let legacyBits = rateWord and 0x7C'u32
      if (formatBits or legacyBits) != 0:
        rateWords[acIdx] =
          (rateWord and 0xE0003FFF'u32) or staView.aggregationLength

  # Recompute the unsigned RF power index for each completed rate word.
  if (staView.txPolicyUpdateFlags[0] and StaTxPolicyUpdateTxPower) != 0:
    for acIdx in 0 ..< 4:
      txPowerWords[acIdx] = tpc_get_vif_tx_power_vs_rate(rateWords[acIdx]).uint32

  # Critical section: write back policy word under IRQ protection
  let irqState = irqSave()
  policy.bufferAddr = policyWord
  for acIdx in 0 ..< 4:
    policy.retryRate[acIdx] = rateWords[acIdx]
    policy.txPower[acIdx] = txPowerWords[acIdx]

  when defined(bl808m0):
    if (txPolicyUpdateFlags and StaTxPolicyUpdateRateControl) != 0:
      rcRejectUnprogrammedTrial(staView.infoIdx, staView.rcStats, rateWords)
  # Do not erase a new policy request delivered when IRQs are restored.
  staView.txPolicyUpdateFlags[0] = 0
  irqRestore(irqState)
  return txPolicy

proc me_tx_cfm_singleton*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation for singleton frames (80 bytes in blob, 25 instrs).
  ## THD bits 15:8 count retries; bit 16 marks a failed final attempt.
  let observed = block:
    let saved = irqSave()
    defer: irqRestore(saved)
    let desc = hostTxDescAt(param)
    let thd = hostTxHeadThd(hostTxHwDescAt(desc.hwDesc))
    let statusWord = thd.flags
    (status: statusWord, isControlPort: desc.frameLen in [0x8E88'u16, 0x888E'u16],
     sta: desc.staInfoIdx, vif: desc.vifIdx, resetEpoch: txResetEpoch,
     stationEpoch: staDeleteEpoch(desc.staInfoIdx),
     vifEpoch: (if desc.vifIdx < MAX_VIFS.uint8: rxVifEpochs[desc.vifIdx] else: 0'u32))
  let statusWord = observed.status
  # A software completion did not use a hardware retry slot.
  const softwareDoneBit = 1'u32 shl 30
  if (statusWord and softwareDoneBit) != 0:
    return
  # Vendor th.extu extracts bits 15:8.
  let retries = (statusWord shr 8) and 0xFF'u32
  let finalFailure = (statusWord and 0x10000'u32) != 0
  let attempts = retries + 1
  let failures = retries + finalFailure.uint32
  let staIdx = observed.sta
  let vifIdx = observed.vif
  if finalFailure:
    rf_dump_status()
  let desc = hostTxDescAt(param)
  if txResetEpoch != observed.resetEpoch or
      staDeleteEpoch(staIdx) != observed.stationEpoch or
      (vifIdx < MAX_VIFS.uint8 and rxVifEpochs[vifIdx] != observed.vifEpoch) or
      desc.staInfoIdx != staIdx or desc.vifIdx != vifIdx:
    return
  # EAPOL may use a per-frame fallback not represented in the STA retry slots.
  if observed.isControlPort: return
  rc_update_counters(staIdx, attempts, failures, false, false)

proc me_tx_cfm_ampdu*(staIdx: uint8; transmitted, acknowledged: uint32;
                       retryRequired: bool) {.exportc, cdecl.} =
  ## Handle TX confirmation for A-MPDU frames (5 instrs).
  rc_update_counters(staIdx, transmitted, transmitted - acknowledged,
                     true, retryRequired)

proc me_tx_cfm_amsdu*(param: pointer): uint16 {.exportc, cdecl.} =
  ## Handle TX confirmation for A-MSDU frames (16 instrs).
  ## Descriptor+46 (TID) is only an invalid sentinel; +49 selects the STA.
  ## Returns rc_stats.curr_amsdu_len at +196, not max_amsdu_len at +194.
  if param == nil:
    return 0
  let desc = hostTxDescAt(param)
  if desc.staIdx == 0xFF or desc.staInfoIdx.int >= STA_INFO_TAB_ENTRIES:
    return 0
  let staIdx = desc.staInfoIdx
  let sta = staInfoForIdx(staIdx)
  if sta.instNbr == 0xFF:
    return 0
  let rcStats = sta.rcStats
  if rcStats == nil:
    return 0
  rcStatsCounters(rcStats).currentAmsduLen

# ME IE building functions
proc me_add_ie_ssid*(buf: pointer, ssidLen: uint8, ssid: pointer): uint32 {.exportc, cdecl.} =
  ## Add SSID IE to buffer. buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## Writes IE ID=0, length, then SSID data. Advances *buf. Returns total bytes.
  if buf == nil or ssidLen > 32 or (ssidLen != 0 and ssid == nil):
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let ie = ssidIeAt(bufPtrPtr[])
  ie.ie.id = 0'u8
  ie.ie.len = ssidLen
  if ssidLen > 0:
    co_pack8p(addr ie.ssidBytes[0], ssid, ssidLen.uint32)
  let total = ssidLen.uint32 + 2
  bufPtrPtr[] = addr ie.ssidBytes[ssidLen]
  return total

proc me_add_ie_supp_rates*(buf: pointer, rateSetPtr: pointer): uint32 {.exportc, cdecl.} =
  ## Add supported rates IE to buffer (34 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## rateSetPtr: rate_set[0] = count, rate_set[1..N] = rate bytes.
  ## Writes IE with ID=1, length=min(count,8), copies min(count,8) rate bytes.
  ## Advances *buf, returns bytes written (count clipped to 8, + 2).
  if buf == nil or rateSetPtr == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let rateSet = rateSetAt(rateSetPtr)
  let rateCount = rateSet.count
  if rateCount > 12:
    return 0
  var writeCount = rateCount
  if writeCount > 8:
    writeCount = 8
  let ie = macIeDataAt(bufPtrPtr[])
  # Write IE header: ID=1 (Supported Rates), length
  ie.ie.id = 1'u8
  ie.ie.len = writeCount
  # Copy rate bytes — blob uses co_pack8p, not memcpy.
  co_pack8p(addr ie.payload[0], addr rateSet.rates[0], writeCount.uint32)
  # Advance buffer pointer
  let totalLen = writeCount.uint32 + 2
  bufPtrPtr[] = addr ie.payload[writeCount]
  return totalLen

proc me_add_ie_ext_supp_rates*(buf: pointer, rateSetPtr: pointer): uint32 {.exportc, cdecl.} =
  ## Add Extended Supported Rates IE (ID=50) (26 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## rateSetPtr: same rate set as supp_rates; its first byte supplies the count.
  ## Writes IE with ID=50, length=count-8, data=rates[9..count].
  ## Advances *buf. Returns total bytes written (count-8+2 = count-6).
  if buf == nil or rateSetPtr == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let rateSet = rateSetAt(rateSetPtr)
  let totalCount = rateSet.count.uint32
  if totalCount <= 8 or totalCount > 12:
    return 0
  let extCount = totalCount - 8
  let ie = macIeDataAt(bufPtrPtr[])
  # Write IE header: ID=50 (Extended Supported Rates)
  ie.ie.id = 50'u8
  ie.ie.len = extCount.uint8
  # Copy extended rate bytes (starting from rate_set[9], skipping first 8) —
  # blob uses co_pack8p, not memcpy.
  co_pack8p(addr ie.payload[0], addr rateSet.rates[8], extCount.uint32)
  # Advance buffer pointer
  let written = totalCount - 6  # (count-8) + 2
  bufPtrPtr[] = addr ie.payload[extCount]
  return written

proc me_add_ie_ds*(buf: pointer, channel: uint8): uint32 {.exportc, cdecl.} =
  ## Add DS Parameter Set IE (ID=3, length=1, total=3 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 3.
  if buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let ds = dsParamSetIeAt(bufPtrPtr[])
  ds.ie.id = 3'u8
  ds.ie.len = 1'u8
  ds.currentChannel = channel
  bufPtrPtr[] = addr ds.next[0]
  return 3

proc me_add_ie_erp*(buf: pointer, erpInfo: uint8 = 0): uint32 {.exportc, cdecl.} =
  ## Add ERP IE (ID=42, length=1, total=3 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 3.
  ## erpInfo is the ERP information byte (protection flags etc).
  if buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let erp = oneByteMacIeAt(bufPtrPtr[])
  erp.ie.id = 42'u8
  erp.ie.len = 1'u8
  erp.value = erpInfo
  bufPtrPtr[] = addr erp.next[0]
  return 3

proc me_add_ie_ht_capa*(buf: pointer): uint32 {.exportc, cdecl.} =
  ## Add HT Capabilities IE (ID=45, length=26, total=28 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 28.
  ## Loads HT cap fields from me_env global.
  if buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let ht = htCapIeAt(bufPtrPtr[])
  let me = meEnvView()
  ht.ie.id = 45'u8
  ht.ie.len = 26'u8
  # HT Capability Info: clear SM Power Save bits 2-3, set LDPC/40MHz/SGI
  var htCapInfo = cast[ptr uint16](addr me.htCaps[0])[]
  htCapInfo = htCapInfo and (not 0x000C'u16)
  htCapInfo = htCapInfo or 0x002D'u16
  ht.capInfo = htCapInfo
  # A-MPDU parameters
  ht.ampduParams = me.htCaps[2]
  # Supported MCS set (16 bytes) — blob uses co_pack8p (byte-by-byte pack),
  # not memcpy. Matching the call lets call-graph audit tools line up.
  co_pack8p(addr ht.mcsSet[0], cast[pointer](addr me.htCaps[3]), 16)
  # HT Extended Capabilities
  let htExtCap = cast[ptr uint16](addr me.htCaps[20])[]
  ht.extCap = htExtCap
  # TX Beamforming Capabilities follow two alignment bytes in the ME source.
  co_pack8p(cast[pointer](addr ht.txBfCapsLo),
            cast[pointer](addr me.htCaps[24]), 4)
  # ASEL Capabilities
  ht.aselCap = me.htCaps[28]
  # Advance write pointer
  bufPtrPtr[] = addr ht.next[0]
  return 28

proc me_add_ie_ht_oper*(buf: pointer, vifEntry: pointer = nil): uint32 {.exportc, cdecl.} =
  ## Add HT Operation IE (ID=61, length=22, total=24 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 24.
  ## vifEntry points to the VIF entry; vifEntry+64 is the channel context.
  ## Channel context layout: [4]=band(u8), [5]=type(u8), [6]=prim_freq(u16),
  ## [8]=center1_freq(u16). Calls phy_freq_to_channel for primary channel.
  ## Secondary offset is 0 for 20 MHz, 5 above the primary, and 7 below it.
  if buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let oper = htOperIeAt(bufPtrPtr[])
  oper.ie.id = 61'u8
  oper.ie.len = 22'u8

  # Determine primary channel and secondary offset from channel context
  var chanNum: uint8 = 0
  var secOffset: uint8 = 0  # default: no secondary channel (0 when chanType==0)
  if vifEntry != nil:
    let chanCtx = vifChannelAt(vifEntry).chanCtxt
    if chanCtx != nil:
      let chanCtxt = chanCtxtAt(chanCtx)
      let band = chanCtxt.channel.band
      let primFreq = chanCtxt.channel.primFreq
      chanNum = phy_freq_to_channel(band, primFreq)
      if chanCtxt.channel.chanType != 0:
        secOffset = if chanCtxt.channel.centerFreq1 >= primFreq: 5'u8 else: 7'u8

  oper.primaryChannel = chanNum
  oper.secondaryOffset = secOffset
  oper.htProtection = 3'u8
  oper.operationMode = [0'u8, 0, 0]
  oper.basicMcsSet = [0xFF'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  bufPtrPtr[] = addr oper.next[0]
  return 24

proc me_add_ie_rsn*(buf: pointer, secMode: uint8 = 0): uint32 {.exportc, cdecl.} =
  ## Add RSN IE (ID=48).
  ## From blob (90 instrs): a0=bufCtx (ptr to write-pointer), a1=secMode.
  ## secMode=1: 22-byte RSN with CCMP + PSK AKM.
  ## secMode=2: 26-byte RSN with TKIP+CCMP + PSK AKM.
  ## Other secMode: no IE added, returns 0.
  ##
  ## bufCtx layout: [0]=current write pointer. The IE is written at *bufCtx[0]
  ## and bufCtx[0] is advanced by the IE length.
  ## For Nim callers that pass buf directly (not a context struct), secMode
  ## defaults to 0 which returns 0 (no RSN), preserving backward compatibility.
  if secMode notin [1'u8, 2'u8] or buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  if secMode == 1:
    # RSN IE: CCMP only + PSK AKM (22 bytes total)
    let rsn = rsnCcmpPskIeAt(bufPtrPtr[])
    rsn.ie.id = 48'u8
    rsn.ie.len = 20'u8
    rsn.version = 1'u16
    rsn.groupCipher = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 4'u8)
    rsn.pairwiseCount = 1'u16
    rsn.pairwiseCipher = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 4'u8)
    rsn.akmCount = 1'u16
    rsn.akmSuite = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)
    rsn.capabilities = 0'u16
    bufPtrPtr[] = addr rsn.next[0]
    return 22
  elif secMode == 2:
    # RSN IE: TKIP+CCMP + PSK AKM (26 bytes total)
    let rsn = rsnTkipCcmpIeAt(bufPtrPtr[])
    rsn.ie.id = 48'u8
    rsn.ie.len = 24'u8
    rsn.version = 1'u16
    rsn.groupCipher = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)
    rsn.pairwiseCount = 2'u16
    rsn.pairwiseCipher[0] = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)
    rsn.pairwiseCipher[1] = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 4'u8)
    rsn.akmCount = 1'u16
    rsn.akmSuite = RsnSuiteView(oui: [0'u8, 15'u8, 0xAC'u8], suiteType: 2'u8)
    rsn.capabilities = 0'u16
    bufPtrPtr[] = addr rsn.next[0]
    return 26
  else:
    # Unknown secMode or 0: no RSN IE
    return 0

{.emit: "__attribute__((noipa)) unsigned long me_add_ie_wpa(void*,unsigned char);".}
proc me_add_ie_wpa*(buf: pointer, secMode: uint8 = 0): uint32 {.exportc, cdecl.} =
  ## Add WPA IE (168 bytes in blob, 53 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## secMode: only mixed mode (2) adds this legacy WPA IE.
  ## Writes WPA vendor IE (ID=221) with Microsoft OUI (00:50:F2:01).
  ## Total 30 bytes. Advances *buf by 30. Returns 30 on success, 0 otherwise.
  ## Note: blob is 168 bytes because GCC reloads *buf before each store group.
  ## Our GCC -Os factors the stores into a helper, so this is 30 bytes compiled.
  ## The gap is a GCC code factoring optimization difference, not missing logic.
  if secMode != 2:
    return 0
  if buf == nil:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
  if bufPtrPtr[] == nil:
    return 0
  let wpa = wpaVendorIeAt(bufPtrPtr[])
  wpa.ie.id = 221'u8
  wpa.ie.len = 28'u8
  wpa.vendorType = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]
  wpa.version = 1'u16
  wpa.groupCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)
  wpa.pairwiseCount = 2'u16
  wpa.pairwiseCipher[0] = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)
  wpa.pairwiseCipher[1] = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 4'u8)
  wpa.akmCount = 1'u16
  wpa.akmSuite = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)
  wpa.capabilities = 0
  bufPtrPtr[] = addr wpa.next[0]
  return 30

proc writeWmmParameterIe(ieBuf: pointer; vif: ptr VifChannelView): pointer =
  let wmm = wmmParameterIeAt(ieBuf)
  wmm.ie.id = 221
  wmm.ie.len = 24
  wmm.oui = [0'u8, 0x50, 0xF2]
  wmm.ouiType = 2
  wmm.ouiSubtype = 1
  wmm.version = 1
  wmm.qosInfo = vif.wmmQosInfo
  wmm.parameterReserved = 0
  const hardwareOrder = [1, 0, 2, 3]
  for ac in 0 ..< 4:
    let encoded = vif.edcaRegs[hardwareOrder[ac]]
    let aciAifsn = (ac.uint32 shl 5) or (encoded and 0xF)
    wmm.ac[ac].setLe32(aciAifsn or (((encoded shr 4) and 0xFF) shl 8) or
      (((encoded shr 12) and 0xFFFF) shl 16))
  addr wmm.next[0]

proc me_add_ie_tim*(buf: pointer, dtimBitmap: uint8 = 0): uint32 {.exportc, cdecl.} =
  ## Add TIM IE (ID=5, length=4, total=6 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 6.
  ## The template leaves DTIM count and bitmap bytes unchanged; the live
  ## beacon path supplies them from its separate TIM descriptor.
  if buf == nil:
    return 0
  let bufPtr = cast[ptr pointer](buf)
  if bufPtr[] == nil:
    return 0
  let tim = timIeAt(bufPtr[])
  tim.ie.id = 5'u8
  tim.ie.len = 4'u8
  tim.dtimPeriod = dtimBitmap
  bufPtr[] = addr tim.partialBitmap[1]
  return 6

proc me_add_ie_csa*(buf: pointer): uint32 {.exportc, cdecl.} =
  ## Add Channel Switch Announcement IE (ID=37).
  ## New function (not in blob). Returns 0 when no CSA is pending.
  return 0

proc me_add_ie_customer*(buf: pointer, ieData: pointer = nil,
                         length: uint32 = 0): uint32 {.exportc, cdecl.} =
  ## Add customer-defined IE (11 instrs).
  ## Blob ABI: a0=write pointer, a1=IE data, a2=IE byte length.
  ## It calls co_pack8p(a0, a1, a2), then returns a2.
  if length == 0:
    return 0
  if buf == nil or ieData == nil:
    return 0
  co_pack8p(buf, ieData, length)
  return length

# ME frame building
proc me_build_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16,
    statusCode: uint16, challengeText: pointer): uint32 {.exportc, cdecl, noinline.} =
  ## Build authentication frame body (noinline so blob-style call remains).
  ## From blob (27 instrs): writes auth_algo, auth_seq, status_code as LE16.
  ## If challengeText != nil, appends challenge text IE (ID=16, len=128).
  ## Returns 6 (no challenge) or 136 (with challenge).
  let fixed = cast[ptr AuthFixedBodyView](buf)
  fixed.authAlgo = authAlgo
  fixed.authSeq = authSeq
  fixed.statusCode = statusCode
  if challengeText != nil:
    let challenge = authChallengeBodyAt(buf)
    # Challenge Text IE: ID=16, Length=128
    challenge.challengeTag = 16
    challenge.challengeLen = 128
    # Blob copies the 128-byte challenge via a byte-loop + T-Head custom
    # insn (no memcpy call emitted). Emit the equivalent byte copy inline
    # so the call graph stays at 0 calls (matching blob).
    let src = cast[ptr UncheckedArray[uint8]](challengeText)
    for challengeByteIndex in 0 ..< 128:
      challenge.challengeText[challengeByteIndex] = src[challengeByteIndex]
    return 136
  return 6

proc meBuildSaeAuthenticate(buf: pointer; authAlgo, authSeq, statusCode: uint16;
                             vifIdx: uint32; frame: pointer;
                             peerOverride: pointer = nil;
                             ownOverride: pointer = nil): uint32 =
  if vifIdx >= MAX_VIFS.uint32 or
      not smTxFits(frame, buf, sizeof(AuthFixedBodyView).uint32): return 0
  let body = cast[ptr AuthBodyDataView](buf)
  body.fixed = AuthFixedBodyView(authAlgo: authAlgo, authSeq: authSeq,
                                 statusCode: statusCode)
  let vif = vifChannelForIdx(vifIdx.uint8)
  var bssid: array[6, uint8]
  if peerOverride != nil:
    bssid = cast[ptr array[6, uint8]](peerOverride)[]
  else:
    bssid = vif.bssid
    let staIdx = vif.staIdx
    if staIdx < STA_MGMT_FREE_STAS.uint8:
      let sta = staInfoForIdx(staIdx)
      # The archive passes sta_info_tab[vif.staIdx].macAddr to the SAE callback.
      # A stale STA entry must not override a different, specific join target.
      if not macPtrIsSpecific(addr bssid[0]) or
          macPtrEquals(addr sta.macAddr[0], addr bssid[0]):
        bssid = sta.macAddr
    if not macPtrIsSpecific(addr bssid[0]):
      bssid = vif.currentBssid
  if not macPtrIsSpecific(addr bssid[0]): return 0
  var own = vif.macAddr
  if ownOverride != nil:
    own = cast[ptr array[6, uint8]](ownOverride)[]
  # Callback arguments must remain valid even if it replaces the connection.
  var passphrase: array[65, uint8]
  let connInfo = smEnvView().connectInfo
  let passphrasePtr = if connInfo != nil: addr passphrase[0] else: nil
  if connInfo != nil:
    discard c_memcpy(addr passphrase[0],
      addr connectInfoCredentials(connInfo).keyString[0], 64)
  if wpa_cbs == nil: return 0
  let getSaeFrame = cast[ptr UncheckedArray[pointer]](wpa_cbs)[14]
  if getSaeFrame == nil: return 0
  type SaeFrameFn = proc(bssid, mac, passphrase: pointer; msgType: uint32;
                         lenOut: ptr uint32): pointer {.cdecl.}
  var saeLen: uint32
  let saeData = cast[SaeFrameFn](getSaeFrame)(
    addr bssid[0], addr own[0], passphrasePtr, authSeq.uint32, addr saeLen)
  if saeData == nil or saeLen > high(uint32) - sizeof(AuthFixedBodyView).uint32:
    return 0
  let total = sizeof(AuthFixedBodyView).uint32 + saeLen
  if not smTxFits(frame, buf, total): return 0
  if saeLen != 0:
    discard c_memcpy(addr body.variablePayload[0], saeData, saeLen.csize_t)
  total

proc me_build_sae_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16,
    statusCode: uint16, vifIdx: uint32): uint32 {.exportc, cdecl.} =
  meBuildSaeAuthenticate(buf, authAlgo, authSeq, statusCode, vifIdx, nil)

proc meBuildAssociateReq(buf, assocInfo, reassocBssid, capParam, cursorOut,
                         bodyLenOut, connInfo: pointer;
                         frame: pointer): uint32 =
  let hdrSize = if reassocBssid == nil: 4'u32 else: 10'u32
  if cast[uint](capParam) >= MAX_VIFS.uint or assocInfo == nil or
      not smTxFits(frame, buf, hdrSize): return 0
  let assoc = vifAssocInfo(assocInfo)
  if assoc.ssidLen == 0 or assoc.ssidLen > 32 or
      assoc.basicRates[0] == 0 or
      assoc.basicRates[0].int >= assoc.basicRates.len:
    return 0
  let secFlags = assoc.securityFlags
  var listenInt = 5'u16
  if connInfo != nil and connectInfoView(connInfo).listenInterval != 0:
    listenInt = connectInfoView(connInfo).listenInterval
  let capInfo = me_build_capability(capParam)
  let fixedReq = cast[ptr AssocReqFixedBodyView](buf)
  fixedReq.capabilityInfo = capInfo
  fixedReq.listenInterval = listenInt
  if reassocBssid != nil:
    discard c_memcpy(addr fixedReq.reassocBssid[0], reassocBssid, 6)
  let ieStart = cast[uint](buf) + hdrSize.uint
  var cursor = cast[pointer](ieStart)
  var totalLen = hdrSize

  if not smTxFits(frame, cursor, assoc.ssidLen.uint32 + 2): return 0
  totalLen += me_add_ie_ssid(addr cursor, assoc.ssidLen, addr assoc.ssidData[0])
  if not smTxFits(frame, cursor, 0): return 0

  let ratesPtr = cast[pointer](addr assoc.basicRates[0])
  let rateCount = assoc.basicRates[0].uint32
  if not smTxFits(frame, cursor, min(rateCount, 8'u32) + 2): return 0
  totalLen += me_add_ie_supp_rates(addr cursor, ratesPtr)
  if not smTxFits(frame, cursor, 0): return 0
  if rateCount > 8:
    if not smTxFits(frame, cursor, rateCount - 6): return 0
    totalLen += me_add_ie_ext_supp_rates(addr cursor, ratesPtr)
    if not smTxFits(frame, cursor, 0): return 0

  let assocIeSrc = cast[pointer](assoc.rsnIePtr)
  let assocIeLen = assoc.rsnIeLen.uint32
  nimFwDbgVifIeLenAtAssoc = assocIeLen or (cast[uint32](assocIeSrc) shl 8)
  if assocIeLen != 0:
    if assocIeSrc == nil or not smTxFits(frame, cursor, assocIeLen): return 0
    discard c_memcpy(cursor, assocIeSrc, assocIeLen.csize_t)
    cursor = cast[pointer](cast[uint](cursor) + assocIeLen.uint)
    totalLen += assocIeLen
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_sec ", secFlags, assocIeLen)
  if not smTxFits(frame, cursor, 0): return 0

  if (secFlags and 1) != 0:
    if not smTxFits(frame, cursor, sizeof(WmmInfoIeView).uint32): return 0
    let qosInfo =
      if psEnvView().uapsdPeriod != 0 and
          cast[int8](assoc.wmmQosInfo) < 0 and connInfo != nil:
        connectInfoView(connInfo).qosInfo
      else:
        0'u8
    let wmm = wmmInfoIeAt(cursor)
    wmm.ie.id = 0xDD
    wmm.ie.len = 7
    wmm.oui = [0x00'u8, 0x50, 0xF2]
    wmm.ouiType = 2
    wmm.ouiSubtype = 0
    wmm.version = 1
    wmm.qosInfo = qosInfo
    cursor = addr wmm.next[0]
    totalLen += sizeof(WmmInfoIeView).uint32

  if (secFlags and 2) != 0 and meEnvView().htSupp != 0:
    if not smTxFits(frame, cursor, 28): return 0
    totalLen += me_add_ie_ht_capa(addr cursor)
    if not smTxFits(frame, cursor, 0): return 0

  let sm = smEnvView()
  let vendorPtr = sm.vendorIePtr
  let vendorLen = sm.vendorIeLen.uint32
  if vendorLen != 0:
    if vendorPtr == nil or not smTxFits(frame, cursor, vendorLen): return 0
    co_pack8p(cursor, vendorPtr, vendorLen)
    cursor = cast[pointer](cast[uint](cursor) + vendorLen.uint)
    totalLen += vendorLen
    if not smTxFits(frame, cursor, 0): return 0
  if cursorOut != nil: cast[ptr pointer](cursorOut)[] = cast[pointer](ieStart)
  if bodyLenOut != nil:
    cast[ptr uint16](bodyLenOut)[] = (cast[uint](cursor) - ieStart).uint16
  totalLen

proc me_build_associate_req_impl(buf: pointer, assocInfo: pointer,
    reassocBssid: pointer, capParam: pointer, cursorOut: pointer,
    bodyLenOut: pointer, connInfo: pointer): uint32 {.exportc: "me_build_associate_req", cdecl.} =
  meBuildAssociateReq(buf, assocInfo, reassocBssid, capParam, cursorOut,
                       bodyLenOut, connInfo, nil)
proc me_build_associate_rsp_impl(buf: pointer, vifIdx: uint8,
    statusCode: uint16, staRequest: pointer): uint32 {.exportc: "me_build_associate_rsp", cdecl.} =
  ## Vendor ABI: raw output buffer, VIF index, status, full request pointer.
  if buf == nil or staRequest == nil or vifIdx.int >= MAX_VIFS:
    return 0
  let staAdd = cast[ptr ApmAssocStaAddIndPayload](staRequest)
  if staAdd.rateCount > staAdd.rateBytes.len.uint8:
    return 0
  let vif = vifChannelForIdx(vifIdx)
  let apCfg = vifApConfig(vif)
  let privacy = apCfg.privacyFlag

  # Build capability info using VIF index
  var capInfo = me_build_capability(cast[pointer](vifIdx.uint))
  if privacy != 0:
    capInfo = capInfo or 16

  var writePtr = cast[uint](buf)
  let fixedRsp = cast[ptr AssocRspFixedBodyView](cast[pointer](writePtr))
  fixedRsp.capabilityInfo = capInfo
  fixedRsp.statusCode = statusCode

  # The two high AID bits are set in the over-the-air response.
  let aidVal = staAdd.aid
  let aidField = aidVal or 0xC000'u16
  fixedRsp.aid = aidField

  writePtr += 6
  var cursor = cast[pointer](writePtr)
  var totalLen: uint32 = 6

  # Add Supported Rates IE -- rates from STA entry at staEntry+6
  # Blob: addi a1, s2, 6 where s2=a3=staEntry
  let ratesPtr = cast[pointer](addr staAdd.rateCount)
  totalLen += me_add_ie_supp_rates(addr cursor, ratesPtr)

  # Add Extended Supported Rates if > 8 rates
  # Blob: lbu a4, 6(s2) -> rate count from staEntry+6 (first byte of rates struct)
  let rateCount = staAdd.rateCount
  if rateCount > 8:
    totalLen += me_add_ie_ext_supp_rates(addr cursor, ratesPtr)

  # Check STA HT capabilities from staEntry+64 (blob: lw a5, 64(s2))
  let staCap = staAdd.flags
  if (staCap and 2) != 0:
    # Add HT Capabilities IE
    totalLen += me_add_ie_ht_capa(addr cursor)

    # Add HT Operation IE with VIF entry for channel context
    totalLen += me_add_ie_ht_oper(addr cursor, cast[pointer](vif))

  # Check WMM capabilities (bit 0 of staCap from staEntry+64)
  if (staCap and 1) != 0:
    cursor = writeWmmParameterIe(cursor, vif)
    totalLen += sizeof(WmmParameterIeView).uint32

  return totalLen

proc me_build_deauthenticate*(buf: pointer, reason: uint16): uint32 {.exportc, cdecl, noinline.} =
  ## Build deauthentication frame body (2 bytes: reason code LE16).
  ## From blob (5 instrs): a0=buf, a1=reason_code(u16).
  ## Writes reason_code as LE16 at buf[0..1]. Returns 2.
  ## noinline: blob calls this as a real function.
  managementReasonBodyAt(buf).reason = reason
  return 2

proc meBeaconFrameLength(vifIdx: uint8; hiddenSsid: uint8): uint64 =
  let vif = vifChannelForIdx(vifIdx)
  let rates = vif.basicRates[0].uint64
  result = 36 + 2 + (if hiddenSsid == 0: vif.supportedRatesLong[0].uint64 else: 0'u64)
  result += 2 + min(rates, 8'u64)
  if rates > 8: result += 2 + rates - 8
  result += 3 + 6 + 3  # DS, TIM and ERP.
  let security = vifSecurity(vif)
  if security.rsnIePtr != 0: result += security.rsnIeLen.uint64
  let flags = vifApConfig(vif).securityFlags
  if (flags and 2) != 0: result += 28 + 24
  if vifApConfig(vif).privacyFlag == 2: result += 30
  if (flags and 1) != 0: result += 26

proc me_build_beacon*(buf: pointer, vifIdx: uint8, lenOut: ptr uint16,
                     flagsOut: ptr uint8, hiddenSsid: uint8): uint32 {.exportc, cdecl.} =
  ## Build beacon frame IEs.
  ## From blob (276 instrs): builds a complete beacon frame body.
  ## buf = output buffer. hiddenSsid mirrors the AP-mode flag passed in a4.
  ## Writes 802.11 beacon frame header at buf[0..35], then appends IEs.
  ## Returns total body length (header + IEs).
  let vif = vifChannelForIdx(vifIdx)
  let apCfg = vifApConfig(vif)
  let privacy = apCfg.privacyFlag
  let frame = beaconFrameFixedView(buf)

  # Write frame control: beacon = 0x80
  frame.frameControl = 0x0080'u16
  frame.duration = 0
  frame.tsfLow = 0
  frame.tsfHigh = 0

  # Write DA at offset 4..9: broadcast (FF:FF:FF:FF:FF:FF). Blob copies from
  # the global mac_addr_bcst symbol, not a function-local const — match so
  # the reloc shape is identical (PCREL_HI20 → mac_addr_bcst).
  discard c_memcpy(addr frame.addr1[0], addr mac_addr_bcst_fwd[0], 6.csize_t)
  discard c_memcpy(addr frame.addr2[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)
  discard c_memcpy(addr frame.addr3[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)

  # Sequence number: increment and write at offset 22..23
  let meSeq = meBeaconSequence()
  var seqNum = meSeq.seqCounter
  seqNum += 1
  meSeq.seqCounter = seqNum
  let seqField = seqNum shl 4
  frame.seqCtrl = seqField

  let bcnInt = apCfg.beaconInterval
  frame.beaconInterval = bcnInt

  # Capability info
  var capInfo = me_build_capability(cast[pointer](vifIdx.uint))
  if privacy != 0:
    capInfo = capInfo or 16  # set privacy bit

  # Prepare SSID data pointer (set up before capability write, as blob does)
  let ssidDataPtr = cast[pointer](addr vif.supportedRatesLong[1])

  # Write capability at buf+34..35
  frame.capabilityInfo = capInfo

  # Start building IEs at buf+36 (after 24-byte MAC header + 12-byte beacon body)
  # Blob: sp+12 tracks current write position (ptr-ptr pattern)
  var ieBuf: pointer = beaconFrameIeBody(frame)

  # Add SSID IE (blob tail-merges into a single me_add_ie_ssid call).
  var ssidArgPtr: pointer = nil
  var ssidArgLen: uint8 = 0
  if hiddenSsid == 0:
    ssidArgPtr = ssidDataPtr
    ssidArgLen = vif.supportedRatesLong[0]
  discard me_add_ie_ssid(addr ieBuf, ssidArgLen, ssidArgPtr)

  # bodyLen tracks total from the IE start (buf) including the 36-byte header
  var bodyLen: uint32 = cast[uint32](cast[uint](ieBuf) - cast[uint](buf))

  # Add Supported Rates IE -- pass rates pointer from VIF+436
  let ratesPtr = cast[pointer](addr vif.basicRates[0])
  bodyLen += me_add_ie_supp_rates(addr ieBuf, ratesPtr)

  # Add DS Parameter Set IE: compute channel from VIF channel frequency
  # Blob computes: channel = ((freq - 2412) / 5) + 1 for 2.4GHz
  let chanPtr = vif.operChan
  let chan = cast[ptr ScanChannelEntry](chanPtr)
  let chanFreq = chan.prim20Freq
  let chanNum = phy_freq_to_channel(chan.band, chanFreq)
  bodyLen += me_add_ie_ds(addr ieBuf, chanNum)

  # Write body length to lenOut BEFORE adding TIM and remaining IEs
  # Blob: sh s0,0(s6) at this exact point
  if lenOut != nil:
    lenOut[] = bodyLen.uint16

  # Add TIM IE (blob: lbu a1,432(s7) for DTIM bitmap byte)
  let timBitmap = uint8(vif.beaconIntervalTu and 0x00FF'u16)
  let timLen = me_add_ie_tim(addr ieBuf, timBitmap)
  # Store TIM return (masked to byte) to flagsOut
  if flagsOut != nil:
    flagsOut[] = (timLen and 0xFF).uint8
  bodyLen += timLen

  # Table 8-20: the optional Country goes after TIM, ahead of ERP.
  bodyLen += me_add_ie_erp(addr ieBuf, 0)
  if vif.basicRates[0] > 8:
    bodyLen += me_add_ie_ext_supp_rates(addr ieBuf, ratesPtr)

  # Add WPA/RSN IE from VIF+492 (pre-built IE pointer) if present
  let sec = vifSecurity(vif)
  let wpaIePtr = cast[pointer](sec.rsnIePtr)
  if wpaIePtr != nil:
    let wpaIeLen = sec.rsnIeLen
    ieBuf = copyIeBytes(ieBuf, wpaIePtr, wpaIeLen.uint)
    bodyLen += wpaIeLen.uint32

  let flagsWord = apCfg.securityFlags
  if (flagsWord and 2) != 0:
    bodyLen += me_add_ie_ht_capa(addr ieBuf)
    bodyLen += me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))
  bodyLen += me_add_ie_wpa(addr ieBuf, privacy)

  # Bit zero denotes QoS support, not WPA support.
  if (flagsWord and 1) != 0:
    ieBuf = writeWmmParameterIe(ieBuf, vif)
    bodyLen += sizeof(WmmParameterIeView).uint32

  return bodyLen

proc meProbeResponseLength(vifIdx: uint8): uint32 =
  if vifIdx >= MAX_VIFS.uint8:
    return 0
  let vif = vifChannelForIdx(vifIdx)
  let ssidLength = vif.supportedRatesLong[0].uint32
  let rateCount = vif.basicRates[0].uint32
  if ssidLength > 32 or rateCount > 12 or vif.operChan == nil:
    return 0
  let config = vifApConfig(vif)
  result = 12 + 2 + ssidLength + 2 + min(rateCount, 8'u32) + 3 + 3
  if rateCount > 8:
    result += 2 + rateCount - 8
  case config.privacyFlag
  of 1: result += 22
  of 2: result += 26 + 30
  else: discard
  if (config.securityFlags and 2) != 0:
    result += 28 + 24
  if (config.securityFlags and 1) != 0:
    result += sizeof(WmmParameterIeView).uint32

proc meBuildProbeResponse(buf: pointer; vifIdx: uint8; capacity: uint32;
                          lenOut: ptr uint16; countryAt: ptr uint16 = nil): uint32 =
  ## Build probe response frame IEs.
  ## From blob (202 instrs): builds probe response frame body.
  ## buf points to the probe response body (after MAC header).
  ## Writes: zero timestamp(8B), beacon_interval(2B at +8),
  ## capability(2B at +10), then IEs from offset 12.
  ## The caller holds interrupts from the size check through serialization.
  if lenOut != nil:
    lenOut[] = 0
  if countryAt != nil:
    countryAt[] = 0
  let required = meProbeResponseLength(vifIdx)
  if buf == nil or required == 0 or required > capacity or
      required > high(uint16).uint32:
    return 0
  let vif = vifChannelForIdx(vifIdx)
  let chanPtr = vif.operChan
  let chan = cast[ptr ScanChannelEntry](chanPtr)
  let chanFreq = chan.prim20Freq
  let chanBand = chan.band
  let chanNum = phy_freq_to_channel(chanBand, chanFreq)
  if chanNum == 0:
    return 0
  let apCfg = vifApConfig(vif)
  let privacy = apCfg.privacyFlag
  let frame = probeRspFixedBodyView(buf)
  frame.tsfLow = 0
  frame.tsfHigh = 0

  let bcnInt = apCfg.beaconInterval
  frame.beaconInterval = bcnInt

  # Capability info
  var capInfo = me_build_capability(cast[pointer](vifIdx.uint))
  if privacy != 0:
    capInfo = capInfo or 16  # set privacy bit

  frame.capabilityInfo = capInfo

  # Start building IEs at offset 12 (after timestamp+interval+capability)
  var ieBuf: pointer = probeRspIeBody(frame)

  # Add SSID IE from VIF+386 (length) and VIF+387 (data)
  let ssidLen = vif.supportedRatesLong[0]
  let ssidDataPtr = cast[pointer](addr vif.supportedRatesLong[1])
  var bodyLen: uint32 = me_add_ie_ssid(addr ieBuf, ssidLen, ssidDataPtr)

  # Add Supported Rates IE -- pass rates pointer from VIF+436
  let ratesPtr = cast[pointer](addr vif.basicRates[0])
  bodyLen += me_add_ie_supp_rates(addr ieBuf, ratesPtr)

  # Add 12 for the header (timestamp+interval+capability = 12 bytes)
  # Blob: addi s0,s0,12 at this point
  bodyLen += 12

  bodyLen += me_add_ie_ds(addr ieBuf, chanNum)
  # Table 8-27: Country precedes ERP and Extended Supported Rates.
  if countryAt != nil:
    countryAt[] = bodyLen.uint16
  bodyLen += me_add_ie_erp(addr ieBuf, 0)
  if vif.basicRates[0] > 8:
    bodyLen += me_add_ie_ext_supp_rates(addr ieBuf, ratesPtr)
  bodyLen += me_add_ie_rsn(addr ieBuf, privacy)
  let flagsWord = apCfg.securityFlags

  # Add HT Capabilities + HT Operation IEs (conditional on flagsWord bit 1)
  # Blob: beqz flagsWord&2 → skip HT IEs, jump to me_add_ie_wpa
  if (flagsWord and 2) != 0:
    bodyLen += me_add_ie_ht_capa(addr ieBuf)
    bodyLen += me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))

  # Add WPA IE unconditionally (blob: a1=privacy as secMode, reloc 0x13e)
  bodyLen += me_add_ie_wpa(addr ieBuf, privacy)

  # QoS adds WMM parameters using the VIF's EDCA configuration.
  if (flagsWord and 1) != 0:
    ieBuf = writeWmmParameterIe(ieBuf, vif)
    bodyLen += sizeof(WmmParameterIeView).uint32

  # Write total length output
  if lenOut != nil:
    lenOut[] = bodyLen.uint16

  return bodyLen

proc me_build_probe_rsp*(buf: pointer, vifIdx: uint8,
                        lenOut: ptr uint16): uint32 {.exportc, cdecl.} =
  let saved = irqSave()
  defer: irqRestore(saved)
  meBuildProbeResponse(buf, vifIdx,
    TxlFramePayloadSize - sizeof(MacDataFrameHeaderView).uint32, lenOut)

proc me_build_add_ba_req*(buf: pointer, param: pointer): uint32 {.exportc, cdecl.} =
  ## Build ADDBA Request action frame body (9 bytes).
  ## From blob (30 instrs): a0=buf, a1=BA params struct.
  ## Struct offsets: [8]=SSN(u16), [10]=BA_timeout(u16), [14]=BA_policy(u8),
  ## [15]=buffer_size(u8), [16]=TID(u8), [17]=dialog_token(u8).
  ## Frame: [0]=category(3), [1]=action(0=ADDBA_REQ), [2]=dialog_token,
  ## [3..4]=BA_param_set(LE16), [5..6]=BA_timeout(LE16), [7..8]=start_seq(LE16).
  if buf == nil or param == nil:
    return 0
  let body = addBaReqActionBodyAt(buf)
  body.category = 3  # Block Ack
  body.action = 0    # ADDBA Request
  let req = meAddBaReqParamView(param)
  body.dialogToken = req.dialogToken
  # The vendor advertises no A-MSDU. Bit 1 is BA policy, bits 2..5 are TID.
  let policy = req.baPolicy.uint16 shl 1
  let tid = req.tid.uint16 shl 2
  let bufSize = req.bufferSize.uint16 shl 6
  body.baParams = policy or tid or bufSize
  # BA Timeout Value
  body.timeout = req.timeout
  # Starting Sequence Number (SSN << 4)
  body.startSeq = req.ssn shl 4
  return 9

proc me_build_add_ba_rsp*(buf: pointer, unused: pointer, baParams: uint16,
    dialogToken: uint8, statusCode: uint16): uint32 {.exportc, cdecl, noinline.} =
  ## Build ADDBA Response action frame body (9 bytes).
  ## From blob (15 instrs): writes category, action, dialog token,
  ## status code, BA parameter set, and zero timeout.
  ## noinline: blob calls this as a real function.
  if buf == nil:
    return 0
  let body = addBaRspActionBodyAt(buf)
  body.category = 3  # Block Ack
  body.action = 1    # ADDBA Response
  body.dialogToken = dialogToken
  body.statusCode = statusCode
  body.baParams = baParams
  body.timeout = 0
  return 9

proc me_build_del_ba*(buf: pointer, baInfo: pointer, reasonCode: uint16): uint32 {.exportc, cdecl.} =
  ## Build DELBA action frame body (6 bytes).
  ## From blob (25 instrs): writes category=3, action=2, DELBA params, reason code.
  ## DELBA params: bit11 = initiator, bits 12-15 = TID.
  if buf == nil or baInfo == nil:
    return 0
  let body = delBaActionBodyAt(buf)
  body.category = 3  # Block Ack
  body.action = 2    # DELBA
  # Build DELBA Parameter Set
  let info = delBaInfoView(baInfo)
  var delbaParams = info.tid.uint16 shl 12
  if info.initiator == 1:
    delbaParams = delbaParams or 0x0800'u16  # set initiator bit
  body.delbaParams = delbaParams
  body.reasonCode = reasonCode
  return 6

proc me_build_capability*(param: pointer): uint16 {.exportc, cdecl.} =
  ## Build capability information field.
  ## From blob (14 instrs): param is vifIdx (uint8 in a0).
  ## For STA (type 0), preserves Privacy (bit 4) and Short Preamble (bit 5)
  ## from the capability field at vif[434].
  ## Always sets ESS (bit 0) and short-slot-time (bit 10).
  if cast[uint](param) >= MAX_VIFS.uint:
    return 0
  let vifIdx = encodedArgU8(param)
  let vif = vifChannelForIdx(vifIdx)
  var cap = 1'u16  # ESS bit
  let vifType = vif.vifType
  if vifType == VIF_TYPE_STA:
    let beaconCap = vif.capabilityInfo
    if (beaconCap and 0x10) != 0:  # privacy
      cap = cap or 0x10
    if (beaconCap and 0x20) != 0:  # short preamble
      cap = cap or 0x20
  cap = cap or 0x400  # short-slot-time capability
  return cap

# ME rate/capability helpers
proc me_rate_translate*(rateConfig: uint32): uint32 {.exportc, cdecl.} =
  ## Translate 802.11 rate (in 0.5 Mbps units, masked to 7 bits) to rate index.
  ## From blob (49 instrs): maps standard rate values to internal indices.
  ## Rate -> Index: 2->0, 4->1, 11->2, 22->3, 12->4, 18->5, 24->6,
  ## 36->7, 48->8, 72->9, 96->10, 108->11. Unknown rates -> 255.
  let rate = rateConfig and 0x7F
  case rate
  of 2:   return 0    #  1   Mbps
  of 4:   return 1    #  2   Mbps
  of 11:  return 2    #  5.5 Mbps
  of 22:  return 3    # 11   Mbps
  of 12:  return 4    #  6   Mbps
  of 18:  return 5    #  9   Mbps
  of 24:  return 6    # 12   Mbps
  of 36:  return 7    # 18   Mbps
  of 48:  return 8    # 24   Mbps
  of 72:  return 9    # 36   Mbps
  of 96:  return 10   # 48   Mbps
  of 108: return 11   # 54   Mbps
  else:   return 255  # unknown rate

proc me_legacy_rate_bitfield_build*(rates: pointer, basicOnly: uint8): uint32 {.exportc, cdecl.} =
  ## Select legacy rate indices, optionally requiring the basic-rate marker.
  if rates == nil:
    return 0
  let rateSet = rateSetAt(rates)
  let rateCount = rateSet.count.int
  var rateBytes: array[12, uint8]
  if rateCount > rateBytes.len:
    return 0
  # Warning callbacks can retire or replace the original rate-set storage.
  for rateIndex in 0 ..< rateCount:
    rateBytes[rateIndex] = rateSet.rates[rateIndex]
  var bitfield = 0'u32
  for rateIndex in 0 ..< rateCount:
    let rateByte = rateBytes[rateIndex]
    if basicOnly != 0 and (rateByte and 0x80'u8) == 0:
      continue
    let rateIdx = me_rate_translate(rateByte.uint32)
    if rateIdx <= 11:
      bitfield = bitfield or (1'u32 shl rateIdx)
    else:
      assert_warn("me.c", "me.c", 411.cint)
  bitfield

proc me_legacy_ridx_min*(bitfield: uint32): uint8 {.exportc, cdecl.} =
  ## Get minimum legacy rate index.
  ## From blob (10 instrs): scans bitfield from bit 0 upward, returns index of
  ## first set bit. Returns 12 if no bits set.
  for legacyRateBitIndex in 0'u32 ..< 12:
    if ((bitfield shr legacyRateBitIndex) and 1) != 0:
      return legacyRateBitIndex.uint8
  return 12

proc me_legacy_ridx_max*(bitfield: uint32): uint8 {.exportc, cdecl.} =
  ## Get maximum legacy rate index.
  ## From blob (15 instrs): scans bitfield from bit 11 downward, returns index
  ## of highest set bit. Returns 12 for zero, 255 for nonzero high bits only.
  if bitfield == 0:
    return 12
  for legacyRateReverseBitIndex in countdown(11'i32, 0):
    if ((bitfield shr legacyRateReverseBitIndex.uint32) and 1) != 0:
      return legacyRateReverseBitIndex.uint8
  return 255

proc me_rate_bitfield_vht_build*(rxMap, txMap: uint32): uint32 {.exportc, cdecl.} =
  ## Intersect the two-bit RX/TX MCS fields until either map ends support.
  var supportedMcsMap = 0xFFFF'u32
  var shift = 0'u32
  while shift < 16:
    let rxField = (rxMap shr shift) and 3
    let txField = (txMap shr shift) and 3
    if rxField == 3 or txField == 3:
      break
    let mask = not (3'u32 shl shift)
    supportedMcsMap = (supportedMcsMap and mask) or (min(rxField, txField) shl shift)
    shift += 2
  supportedMcsMap

proc me_get_basic_rates*(rates, outputBuf: pointer) {.exportc, cdecl.} =
  ## Both arguments are full pointers to 13-byte rate sets.
  if rates == nil or outputBuf == nil:
    return
  let rateSet = rateSetAt(rates)
  let output = rateSetAt(outputBuf)
  # Clear output count
  output.count = 0
  let rateCount = rateSet.count
  if rateCount > 12:
    return
  # Iterate rate set
  var rateIndex: uint8 = 0
  while rateIndex < rateCount:
    let rate = rateSet.rates[rateIndex]
    # Sign-extend byte to check bit 7 (basic rate indicator)
    let sextRate = cast[int8](rate)
    if sextRate < 0:  # bit 7 set = basic rate
      let basicRateOutputCount = output.count
      output.rates[basicRateOutputCount] = rate
      output.count = basicRateOutputCount + 1
    rateIndex += 1

proc me_freq_to_chan_ptr*(band: uint8, freq: uint16): pointer {.exportc, cdecl.} =
  ## Convert band+frequency to channel context pointer — blob me.o
  ## (84 bytes). Blob assertion shape:
  ##   if band != 0: assert_err("me.c", "me.c", 113)
  ##   count = me_env[0x7c]
  ##   table = me_env + 0x28
  ##   iterate table, compare 16-bit freq via T-Head custom insn 0xb867460b
  ##
  ## Previous Nim attempted a dual-band layout (band 1 used a different
  ## offset), but the blob HAL only supports band 0 — the assert_err
  ## enforces that invariant. Matching the blob's shape.
  if band != 0:
    assert_err("me.c", "me.c", 113)
    return nil
  let chanConfig = meChannelConfigView()
  if chanConfig.count.int > chanConfig.entries.len:
    return nil
  for channelConfigIndex in 0 ..< chanConfig.count.int:
    let channelConfigEntry = addr chanConfig.entries[channelConfigIndex]
    if channelConfigEntry.freq == freq:
      return cast[pointer](channelConfigEntry)
  return nil

proc me_extract_rate_set*(ieBuf: pointer, ieLen: uint32, rateOut: pointer) {.exportc, cdecl.} =
  ## Extract at most twelve supported/extended rate bytes, keeping basic flags.
  if rateOut == nil:
    return
  let output = rateSetAt(rateOut)
  output.count = 0

  # Find Supported Rates IE (ID=1)
  let suppRatesIe = mac_ie_find(ieBuf, ieLen, 1)
  if suppRatesIe == nil:
    return

  var rates: array[12, uint8]
  let srCount = readLegacyRateIe(cast[ptr MacIeView](suppRatesIe), 0, rates)
  if srCount < 0: return
  for i in 0 ..< srCount: output.rates[i] = rates[i]
  output.count = srCount.uint8

  # Find Extended Supported Rates IE (ID=50)
  let extRatesIe = mac_ie_find(ieBuf, ieLen, 50)
  if extRatesIe == nil:
    return

  let totalCount = readLegacyRateIe(cast[ptr MacIeView](extRatesIe), srCount, rates)
  if totalCount < 0:
    assert_err("me_mgmtframe.c", "me_mgmtframe.c", 897)
    # Platform diagnostics may return after replacing input or output storage.
    return

  for i in srCount ..< totalCount: output.rates[i] = rates[i]
  output.count = totalCount.uint8

proc me_extract_country_reg*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.} =
  ## Apply the matching Country IE triplet to the BSS primary channel.
  if out_ptr == nil:
    return
  let countryIe = cast[ptr MacIeView](mac_ie_find(ieBuf, ieLen, 7))
  if countryIe == nil or countryIe.len < 6:
    return
  let channel = cast[ptr ScanChannelEntry](bssChannelAt(out_ptr).channel)
  if channel == nil:
    return
  let targetChannel = phy_freq_to_channel(channel.band, channel.prim20Freq)
  if targetChannel == 0:
    return
  let channelStep = if channel.band == 0: 1 else: 4

  # The three-byte country string precedes complete channel/power triplets.
  var payloadOffset = 3
  while payloadOffset + sizeof(CountryTripletView) <= countryIe.len.int:
    let triplet = countryTripletAt(addr countryIe.macIePayload[payloadOffset])
    var channelNumber = triplet.firstChan.int
    for channelIndex in 0 ..< triplet.numChan.int:
      if channelNumber == targetChannel.int:
        channel.txPower = cast[int8](triplet.maxPower)
        return
      channelNumber += channelStep
    payloadOffset += sizeof(CountryTripletView)

proc me_extract_csa*(ieBuf: pointer, ieLen: uint32, switchModeOut: pointer,
                     csaOut: pointer): uint8 {.exportc, cdecl, discardable.} =
  ## Return the switch countdown (zero becomes two), or zero if no CSA exists.
  ## a2 receives the switch mode; a3 receives band, bandwidth, and frequencies.
  if ieBuf == nil or switchModeOut == nil or csaOut == nil:
    return 0
  let csaIe = mac_ie_find(ieBuf, ieLen, 37)
  let ecsaIe = mac_ie_find(ieBuf, ieLen, 60)
  if csaIe == nil and ecsaIe == nil:
    return 0
  let secChanIe = mac_ie_find(ieBuf, ieLen, 62)
  let wbcsIe = mac_ie_find(ieBuf, ieLen, 196)
  var wbcsInner: pointer = nil
  if wbcsIe != nil:
    let wbcs = cast[ptr MacIeView](wbcsIe)
    wbcsInner = mac_ie_find(wbcs.macIePayload, wbcs.len.uint32, 194)

  var newChan, switchCount, switchMode: uint8
  if csaIe != nil:
    let ie = cast[ptr CsaIeView](csaIe)
    if ie.ie.len != 3:
      return 0
    switchMode = ie.switchMode
    newChan = ie.newChannel
    switchCount = ie.switchCount
  else:
    let ie = cast[ptr ExtendedCsaIeView](ecsaIe)
    if ie.ie.len != 4:
      return 0
    switchMode = ie.switchMode
    newChan = ie.newChannel
    switchCount = ie.switchCount

  var width, centerChannel1, centerChannel2, secondaryOffset: uint8
  if wbcsInner != nil:
    let wbIe = cast[ptr WideBandwidthChannelSwitchIeView](wbcsInner)
    if wbIe.ie.len != 3:
      return 0
    width = if wbIe.bandwidthType in 1'u8 .. 3'u8: wbIe.bandwidthType + 1 else: 1
    centerChannel1 = wbIe.centerFreq1
    centerChannel2 = wbIe.centerFreq2
  elif secChanIe != nil:
    let secondary = cast[ptr SecondaryChannelOffsetIeView](secChanIe)
    if secondary.ie.len != 1:
      return 0
    secondaryOffset = secondary.mode
    if secondaryOffset notin [0'u8, 1'u8, 3'u8]:
      return 0

  let band = if newChan < 15: 0'u8 else: 1'u8
  let primaryFreq = phy_channel_to_freq(band, newChan)
  if primaryFreq == 0xFFFF'u16:
    return 0
  var parsed = CsaOutputView(band: band, bandwidth: width,
    primaryFreq: primaryFreq, centerFreq1: primaryFreq)
  if wbcsInner != nil:
    parsed.centerFreq1 = phy_channel_to_freq(band, centerChannel1)
    if parsed.centerFreq1 == 0xFFFF'u16:
      return 0
    if centerChannel2 != 0:
      parsed.centerFreq2 = phy_channel_to_freq(band, centerChannel2)
      if parsed.centerFreq2 == 0xFFFF'u16:
        return 0
  elif secondaryOffset == 1 or secondaryOffset == 3:
    parsed.bandwidth = 1
    parsed.centerFreq1 = if secondaryOffset == 1: primaryFreq + 10'u16
                        else: primaryFreq - 10'u16
    if not scanChannelValid(band, parsed.centerFreq1):
      return 0
  cast[ptr uint8](switchModeOut)[] = switchMode
  cast[ptr CsaOutputView](csaOut)[] = parsed
  if switchCount == 0: 2'u8 else: switchCount

proc me_extract_power_constraint*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.} =
  ## Extract power constraint from frame IEs (14 instructions in blob).
  ## Searches for IE with ID=32 (Power Constraint). If found, reads byte at
  ## IE+2 (the constraint value) and stores it in the blob output overlay
  ## constraint slot at out_ptr+132 (0x84).
  ## If not found, stores 0 at that offset.
  if out_ptr == nil:
    return
  let ie = cast[ptr MacIeView](mac_ie_find(ieBuf, ieLen, 32))
  var constraintVal: uint8 = 0
  if ie != nil and ie.len == 1:
    constraintVal = ie.macIePayload[0]
  powerConstraintOutputAt(out_ptr).constraint = constraintVal

proc me_11n_nss_max*(param: pointer): uint8 {.exportc, cdecl.} =
  ## Get max NSS for 11n.
  ## From blob (10 instrs): param points to HT MCS set bytes (4 bytes for NSS 0-3).
  ## Returns highest NSS index with non-zero MCS support.
  let mcs = htMcsNssPrefixView(param)
  if mcs.nss3 != 0: return 3
  if mcs.nss2 != 0: return 2
  if mcs.nss1 != 0: return 1
  return 0

proc me_11ac_nss_max*(param: pointer): uint8 {.exportc, cdecl.} =
  ## Get max NSS for 11ac.
  ## From blob (10 instrs): param is actually the VHT MCS map (uint32 in a0).
  ## Scans 2-bit fields from NSS 7 (bits [15:14]) down to NSS 0 (bits [1:0]).
  ## Returns highest NSS where field != 3 (3 = not supported).
  let mcsMap = cast[uint32](param)
  var nss = 7'u8
  var shift = 14'u32
  while nss > 0:
    let nssMcsSupport = (mcsMap shr shift) and 3
    if nssMcsSupport != 3:
      return nss
    dec nss
    shift -= 2
  return nss

proc me_11ac_mcs_max*(param: pointer): uint8 {.exportc, cdecl.} =
  ## Get max MCS for 11ac.
  ## From blob (8 instrs): param is actually a VHT MCS map value (uint32 in a0).
  ## Checks bits [1:0]: 0 -> MCS 7, 1 -> MCS 8, 2 -> MCS 9, 3 -> not supported (7).
  let mcsMap = cast[uint32](param) and 3
  case mcsMap
  of 1: return 8
  of 2: return 9
  else: return 7

proc michael_block*(ctx: pointer, messageWord: uint32) {.exportc, cdecl.} =
  ## Michael MIC block function (TKIP).
  ## ctx layout: [0]=uint32 L, [4]=uint32 R.
  ## From blob (43 instrs): XOR messageWord into L, then perform the Michael
  ## permutation rounds: XSWAP, XOR, rotate, add operations.
  let mic = michaelMicContextAt(ctx)
  var L = mic.left
  var R = mic.right

  L = L xor messageWord

  # Round 1: R ^= rotl(L, 17)
  R = R xor ((L shl 17) or (L shr 15))
  L = L + R

  # Round 2: XOR the adjacent-byte swap of L into R.
  let swapped = ((L and 0x00FF00FF'u32) shl 8) or
                ((L and 0xFF00FF00'u32) shr 8)
  R = R xor swapped
  L = L + R

  # Round 3: R ^= rotl(L, 3)
  R = R xor ((L shl 3) or (L shr 29))
  L = L + R

  # Round 4: R ^= rotr(L, 2)
  R = R xor ((L shr 2) or (L shl 30))
  L = L + R

  mic.left = L
  mic.right = R

proc me_mic_init*(micCtx: pointer, key: pointer, da: pointer, sa: pointer,
                  priority: uint8) {.exportc, cdecl.} =
  ## Initialize Michael MIC calculation (66 instrs).
  ## a0=micCtx, a1=key (8 bytes), a2=da (6 bytes), a3=sa (6 bytes), a4=priority.
  ## micCtx layout: [0]=L, [4]=R, [8]=pending, [12]=nBytes.
  ## Loads key into L,R, then processes a2[0..5] || a3[0..5] || priority
  ## via four michael_block calls.
  let michaelMicContextPtr = micCtx
  let mic = michaelMicContextAt(michaelMicContextPtr)

  # Load key words into ctx
  mic.left = cast[ptr uint32](key)[]
  mic.right = cast[ptr UncheckedArray[uint32]](key)[1]
  mic.pending = 0
  mic.nBytes = 0

  # Build packed LE32 words from source/destination MACs per the TKIP pseudo-header.
  let sourceAddr = cast[ptr UncheckedArray[uint8]](sa)
  let destAddr = cast[ptr UncheckedArray[uint8]](da)

  let destAddrLow =
    destAddr[0].uint32 or (destAddr[1].uint32 shl 8) or
    (destAddr[2].uint32 shl 16) or (destAddr[3].uint32 shl 24)
  let destSourceMiddle =
    (destAddr[4].uint32 or (destAddr[5].uint32 shl 8)) or
    ((sourceAddr[0].uint32 or (sourceAddr[1].uint32 shl 8)) shl 16)
  let sourceAddrHigh =
    sourceAddr[2].uint32 or (sourceAddr[3].uint32 shl 8) or
    (sourceAddr[4].uint32 shl 16) or (sourceAddr[5].uint32 shl 24)

  var tidPriority: uint32 = priority.uint32 and 7
  if priority == 0xFF:
    tidPriority = 0

  michael_block(michaelMicContextPtr, destAddrLow)
  michael_block(michaelMicContextPtr, destSourceMiddle)
  michael_block(michaelMicContextPtr, sourceAddrHigh)
  michael_block(michaelMicContextPtr, tidPriority)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void me_mic_calc(void*,void*,unsigned long);".}
proc me_mic_calc*(ctx: pointer, data: pointer, dataLen: uint32) {.exportc, cdecl.} =
  ## Calculate TKIP Michael MIC over data buffer (117 instrs).
  ## ctx = MIC context (layout: [0]=L, [4]=R, [8]=pending_word, [12]=nBytes).
  ## Processes data byte-by-byte, accumulating into the pending word.
  ## When 4 bytes are accumulated, calls michael_block(ctx, pending_word)
  ## and resets the byte counter.
  ##
  ## Assembly trace: handles unaligned start and bulk 4-byte processing.
  ## Uses word-aligned loads with shift/mask for efficiency.
  let mic = michaelMicContextAt(ctx)
  let micInputBytes = cast[ptr UncheckedArray[uint8]](data)
  var nBytes = mic.nBytes
  var pending = mic.pending
  var micInputByteOffset: uint32 = 0
  var remaining = dataLen

  # Handle unaligned start: fill pending word up to 4 bytes
  if nBytes > 0 and remaining > 0:
    let needed = 4'u32 - nBytes.uint32
    let toProcess = if remaining < needed: remaining else: needed
    for pendingWordFillByteIndex in 0'u32 ..< toProcess:
      pending = pending or
        (micInputBytes[micInputByteOffset].uint32 shl (nBytes.uint32 * 8))
      nBytes += 1
      micInputByteOffset += 1
      remaining -= 1
    if nBytes >= 4:
      michael_block(ctx, pending)
      pending = 0
      nBytes = 0

  # Process bulk 4-byte words (single michael_block call site per loop,
  # matching blob's structure).
  while remaining >= 4:
    let micBlockWord = micInputBytes[micInputByteOffset].uint32 or
                       (micInputBytes[micInputByteOffset + 1].uint32 shl 8) or
                       (micInputBytes[micInputByteOffset + 2].uint32 shl 16) or
                       (micInputBytes[micInputByteOffset + 3].uint32 shl 24)
    let blockIn = if nBytes > 0: pending or (micBlockWord shl (nBytes.uint32 * 8))
                  else: micBlockWord
    michael_block(ctx, blockIn)
    pending = if nBytes > 0: micBlockWord shr ((4 - nBytes.uint32) * 8) else: 0
    micInputByteOffset += 4
    remaining -= 4

  # Handle remaining bytes
  for tailMicByteIndex in 0'u32 ..< remaining:
    pending = pending or
      (micInputBytes[micInputByteOffset].uint32 shl (nBytes.uint32 * 8))
    nBytes += 1
    micInputByteOffset += 1
    if nBytes >= 4:
      michael_block(ctx, pending)
      pending = 0
      nBytes = 0

  # Store state back
  mic.pending = pending
  mic.nBytes = nBytes

proc me_mic_end*(ctx: pointer) {.exportc, cdecl.} =
  ## Finalize MIC calculation (from disassembly).
  ## Pads the remaining bytes with 0x5A marker byte, then performs a final
  ## michael_block call to produce the final MIC value.
  ## ctx layout: [0]=L, [4]=R, [8]=pending_word, [12]=nBytes.
  let mic = michaelMicContextAt(ctx)
  let nBytes = mic.nBytes
  let pending = mic.pending
  # Assert nBytes <= 3
  if nBytes > 3:
    # Blob uses assert_err, not assert_rec.
    assert_err("me_mic.c", "me_mic.c", 323)
    return
  # Pad with 0x5A at the current byte position
  let padShift = nBytes.uint32 * 8
  let padded = pending or (0x5A'u32 shl padShift)
  michael_block(ctx, padded)
  # Final block with zero
  michael_block(ctx, 0)
