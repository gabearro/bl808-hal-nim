# ###########################################################################
#                      SCAN (Lower MAC)
# ###########################################################################

proc scan_init*() {.exportc, cdecl.} =
  ## Initialize scan module (blob: ~50 instrs). From disassembly:
  ##   memset(scan_env, 0, 24)
  ##   scan_env[12] = scan_env[16] = scan_env[20] = 0x35B60  (220000 us)
  ##   ke_state_set(TASK_SCAN=1, 0)
  ##   scan_probe_req_ie[16] = 0xCAFEFADE  (magic marker at +0x10)
  ##   scan_probe_req_ie[20] = 0            (at +0x14)
  ##   scan_probe_req_ie[24] = &scan_probe_req_ie[36]  (IE buffer self-ptr at +0x18)
  ##   scan_probe_req_ie[32] = 0            (at +0x20)
  discard c_memset(addr scan_env, 0, 24.csize_t)
  nimFwTrace("[WIFI-NIMFW] scan_init env cleared")
  scan_env.activeDuration = 0x35B60'u32
  scan_env.passiveDuration = 0x35B60'u32
  scan_env.joinActiveDuration = 0x35B60'u32
  nimFwTrace("[WIFI-NIMFW] scan_init durations set")
  ke_state_set(TASK_SCAN, ScanIdleState)
  nimFwTrace("[WIFI-NIMFW] scan_init state set")
  scan_probe_req_ie.magic = 0xCAFEFADE'u32
  scan_probe_req_ie.reserved0 = 0
  scan_probe_req_ie.ieDataPtr = addr scan_probe_req_ie.ieData[0]
  scan_probe_req_ie.writeOffset = 0
  nimFwTrace("[WIFI-NIMFW] scan_init probe ie set")

proc scan_get_scan_duration*(passive: bool): uint32 {.exportc, cdecl, noinline.} =
  ## Get scan duration. Blob ignores the `passive` arg: reads scan_env[0]
  ## as a pointer, loads +312 off that. If non-zero return it, else 0x35B60.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let scanReq = activeScanReq()
  if scanReq != nil:
    let custom = scanReq.addIeLen
    if custom != 0:
      return custom
  return 0x35B60'u32

proc scan_set_channel_request*(param: pointer) {.exportc, cdecl.} =
  ## Set channel for scanning. Builds channel config from scan_env param
  ## pointer and channel index, computes TX power index, sends indication.
  ## From disassembly (84 instrs).
  let scanParamPtr = scan_env.paramPtr
  let scanReq = scanStartReqView(scanParamPtr)
  let scanIdx = scan_env.channelIndex
  nimFwTrace2U32("[WIFI-NIMFW] scan_set start ", scanIdx.uint32, cast[uint32](scanParamPtr))
  var chanCfg = default(ChanScanReqPayload)
  chanCfg.vifIdx = scanReq.vifIdx
  var freqWord: uint32
  let directFreq = scanReq.sendProbe
  let scanChan = scanReq.channelList[scanIdx.int]
  if directFreq == 0:
    if (scanChan.flags and 1) != 0:
      freqWord = scan_env.activeDuration
    else:
      freqWord = scan_env.passiveDuration
  else:
    freqWord = scan_env.joinActiveDuration
  chanCfg.duration = freqWord
  let chanBand = scanChan.band
  chanCfg.band = chanBand
  let prim20Freq = scanChan.prim20Freq
  nimFwTrace2U32("[WIFI-NIMFW] scan_set chan ", chanBand.uint32, prim20Freq.uint32)
  chanCfg.prim20Freq = prim20Freq
  chanCfg.center1Freq = prim20Freq
  chanCfg.center2Freq = 0
  chanCfg.txPower = scanChan.txPower
  if chanCfg.txPower == 0'i8:
    chanCfg.txPower = -1'i8
  let chanCfgView = chanScanChannel(addr chanCfg)
  nimFwDbgScanReqChanMeta = packChannelMeta(chanCfgView)
  nimFwDbgScanReqChanFreq = packChannelFreq(chanCfgView)
  var txPowerIdx: uint8 = 0
  let chanInfoPtr = scan_env.chanInfoPtr
  if chanBand == 0:
    let freq32 = prim20Freq.uint32
    if freq32 >= 2412 and freq32 <= 2484:
      if freq32 == 2484: txPowerIdx = 14
      else: txPowerIdx = ((freq32 - 2407) div 5).uint8
  elif chanBand == 1:
    let freq32 = prim20Freq.uint32
    if freq32 >= 5000 and freq32 <= 5825:
      txPowerIdx = ((freq32 - 5000) div 5).uint8
  if chanInfoPtr != nil:
    dsParamSetIeAt(chanInfoPtr).currentChannel = txPowerIdx
  # Blob: call chan_scan_req to submit channel change to HW
  chan_scan_req(addr chanCfg)
  # Transition scan task to the channel-request pending state.
  ke_state_set(TASK_SCAN, ScanChannelPendingState)

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
  ## calls mac_ie_find(scan_probe_req_ie+36, ieLen, 3) to locate DS Parameter Set IE,
  ## stores result at scan_env+4, calls scan_set_channel_request, then updates
  ## the scan_probe_req_ie tracking fields (offsets 24, 28, 32).
  let scanReq = activeScanReq()
  let ieLen = scanReq.ieBodyLen
  # Search for DS Parameter Set IE (id=3) in the IE buffer
  let found = mac_ie_find(scanProbeReqIeDataPtr(scan_probe_req_ie),
                          ieLen.uint32, 3)
  scan_env.chanInfoPtr = found
  # Set up the scan channel
  scan_set_channel_request(nil)
  # Update IE tracking in scan_probe_req_ie: end_offset, write_offset
  scan_probe_req_ie.writeOffset = 0
  scan_probe_req_ie.endOffset =
    scanProbeReqIeDataBase(scan_probe_req_ie) - 1 + scanReq.ieBodyLen.uint32

proc scan_probe_req_tx*(param: pointer): uint8 {.exportc, cdecl.} =
  ## Transmit probe request frames for active scanning (114 instrs in blob).
  ## From disassembly: iterates over SSIDs in the scan parameter, builds and
  ## sends one probe request frame per SSID. Returns 1 (success) or 0 (failure).
  ##
  ## The scan parameter pointer is loaded from scan_env[0] (the SCAN_START_REQ msg).
  ## Layout of scan_param (s10):
  ##   [252 + i*34]     = SSID length for SSID i
  ##   [253 + i*34 ...] = SSID bytes (up to 32 bytes)
  ##   [286..291]       = BSSID (6 bytes)
  ##   [292..297]       = Source address / own MAC (6 bytes)
  ##   [304..305]       = IE length (uint16)
  ##   [306]            = vif_idx (uint8)
  ##   [308]            = num_ssids count (uint8)
  ##
  ## For each SSID:
  ##   1. Compute total frame length = IE_len + SSID_len + 26
  ##   2. Allocate frame via txl_frame_get
  ##   3. Build probe request header in link descriptor:
  ##      FC = 0x0040 (probe request), Duration = 0
  ##      Addr1 = BSSID, Addr2 = own MAC, Addr3 = BSSID
  ##      Sequence control from per-VIF counter
  ##      SSID IE (ID=0, len, data)
  ##   4. Adjust THD buffer length, set descriptor fields
  ##   5. Push frame via txl_frame_push(desc, 3)
  let scanParam = scan_env.paramPtr
  if scanParam == nil:
    return 1  # no scan parameters
  let scanReq = scanStartReqView(scanParam)
  let numSsids = scanReq.scanType
  let ieLen = scanReq.ieBodyLen
  let vifIdx = scanReq.vifIdx

  for i in 0 ..< numSsids.int:
    let ssidSlot = scanSsidSlot(scanReq, i)
    let ssidLen = ssidSlot.length
    let totalLen = ieLen.uint16 + ssidLen.uint16 + 26'u16

    # Allocate frame
    let frame = txl_frame_get(totalLen.uint32)
    if frame == nil:
      # If first allocation fails, exit; return current success status
      break

    let frameDesc = hostTxDescAt(frame)
    let linkDesc = hostTxLinkDescAt(frameDesc.bufDesc)
    let thd = txlThdProbeAt(frameDesc.hwDesc)

    # Build probe request frame in the link descriptor MAC header area.
    let probeFrame = hostTxProbeReqFrame(linkDesc)
    let probeHdr = addr probeFrame.fixed
    probeHdr.frameControl = 0x0040'u16
    probeHdr.duration = 0

    # Addr2 (SA) = own MAC address (from scan_param+292)
    probeHdr.addr2 = scanReq.localMac

    # Addr3 (BSSID) = BSSID from scan_param+286
    probeHdr.addr3 = scanReq.bssid

    # Addr1 (DA) = copy of BSSID (same as Addr3)
    probeHdr.addr1 = scanReq.bssid

    probeHdr.seqCtrl = nextTxSeqCtrl()

    probeHdr.ssidIeId = IE_ID_SSID
    probeHdr.ssidLen = ssidLen
    # Copy SSID bytes
    for j in 0'u ..< ssidLen.uint:
      probeFrame.ssidData[j] = ssidSlot.data[j]

    when defined(bl808WifiScanTrace):
      nimFwTrace2U32("[WIFI-SCAN] probe_tx ",
                     totalLen.uint32,
                     ieLen.uint32 or (ssidLen.uint32 shl 16) or (vifIdx.uint32 shl 24))
      nimFwTrace2U32("[WIFI-SCAN] probe_fc ",
                     probeHdr.frameControl.uint32 or
                       (probeHdr.duration.uint32 shl 16),
                     cast[ptr uint32](addr probeHdr.addr1[0])[])

    # Set THD fields
    thd.payloadPtr = scanProbeReqIePayloadPtr(scan_probe_req_ie)
    nimFwDbgProbeIeLen = ieLen.uint32
    for k in 0 ..< nimFwDbgProbeIeRaw.len:
      nimFwDbgProbeIeRaw[k] = 0
    let ieCopyLen =
      if ieLen.uint32 < nimFwDbgProbeIeRaw.len.uint32:
        ieLen.uint32
      else:
        nimFwDbgProbeIeRaw.len.uint32
    if ieCopyLen != 0:
      discard c_memcpy(addr nimFwDbgProbeIeRaw[0],
                       scanProbeReqIeDataPtr(scan_probe_req_ie),
                       ieCopyLen.csize_t)

    # Adjust THD buffer length: subtract IE length
    thd.bufLen = thd.bufLen - ieLen.uint32

    # Set descriptor fields
    frameDesc.callback = nil
    frameDesc.callbackArg = nil
    frameDesc.staInfoIdx = 0xFF'u8
    frameDesc.vifIdx = vifIdx

    # Push frame for transmission on AC 3 (VO)
    # In the blob, txl_frame_push returns 0 on success (via tail-call to
    # txl_cntrl_push which always returns 0). The Nim version is void,
    # so we just call it. The blob checks the return and sets success=false
    # on non-zero, but this is effectively dead code since it always returns 0.
    txl_frame_push(frame, 3)

    # Advance to next SSID entry (stride = 34 bytes)
  return 1

proc scan_send_cancel_cfm*(status: uint8) {.exportc, cdecl, noinline.} =
  ## Send scan cancel confirmation (15 instrs in blob).
  ## Allocates a SCAN_CANCEL_CFM message with 1-byte payload containing
  ## the status code, then sends it.
  ## SCAN_CANCEL_CFM = 0x404, dest=TASK_SCAN(1), src=TASK_SCAN(1).
  let param = cast[ptr StatusCfmPayload](
    ke_msg_alloc(SCAN_CANCEL_CFM, TASK_SCAN, TASK_SCAN,
                 StatusCfmPayloadSize))
  param.status = status
  ke_msg_send(param)

proc scan_get_chan*(idx: uint32): pointer {.exportc, cdecl.} =
  ## Get channel descriptor by index.
  ## From blob (6 instrs): loads channel list base from scan_env[0], band from
  ## scan_env[9], computes entry address = base + idx * 6 (6-byte channel entries).
  ## Returns pointer to the idx-th channel entry.
  let chanListBase = scan_env.paramPtr
  if chanListBase == nil:
    return nil
  let scanReq = scanStartReqView(chanListBase)
  return addr scanReq.channelList[idx.int]

# ###########################################################################
#                      SCANU (Upper MAC Scan)
# ###########################################################################

proc scanu_init*() {.exportc, cdecl.} =
  ## Initialize upper MAC scan module.
  ke_state_set(TASK_SCANU, ScanuIdleState)
  discard c_memset(cast[pointer](addr scanu_env), 0, sizeof(ScanuEnvObj).csize_t)
  scanu_env.probeIeCopyDst = addr scanuAddIeView().ieData[0]
  scanuJoinHandler = cast[pointer](scanu_frame_handler)
  scanuResultCount = 0
  for i in 0 ..< MAX_SCAN_RESULTS:
    scanuResults[i] = nil

proc scanu_confirm*(status: uint8) {.exportc, cdecl.} =
  ## Send scan completion confirmation to host (58 instrs).
  ## Blob flow: allocates SCANU_JOIN_CFM twice in join mode (to requester and
  ## TASK_API), or SCANU_START_CFM in normal scan mode. SCANU_RESULT_IND is not
  ## a status message; it carries real beacon/probe-response frames.
  let joinFlag = scanu_env.bssidFilterEnabled
  let reqSrcId = scanu_env.requester
  var primaryCfm: pointer = nil
  var apiJoinCfm: pointer = nil
  if joinFlag != 0:
    primaryCfm = ke_msg_alloc(SCANU_JOIN_CFM, reqSrcId, TASK_SCANU,
                              StatusCfmPayloadSize)
    apiJoinCfm = ke_msg_alloc(SCANU_JOIN_CFM, TASK_API, TASK_SCANU,
                              StatusCfmPayloadSize)
  else:
    primaryCfm = ke_msg_alloc(SCANU_START_CFM, reqSrcId, TASK_SCANU,
                              StatusCfmPayloadSize)
  if primaryCfm != nil:
    statusCfmView(primaryCfm).status = status
  let scanParam = scanu_env.paramPtr
  if scanParam != nil:
    ke_msg_free(scanParam)
  scanu_env.paramPtr = nil
  if primaryCfm != nil:
    ke_msg_send(primaryCfm)
  if apiJoinCfm != nil:
    statusCfmView(apiJoinCfm).status = status
    ke_msg_send(apiJoinCfm)
  ke_state_set(TASK_SCANU, ScanuIdleState)

type ProbeIeWriter = object
  len*: uint16

proc cursor*(w: ProbeIeWriter): pointer {.inline.} =
  scanProbeReqIeDataPtr(scan_probe_req_ie, w.len)

proc appendByte*(w: var ProbeIeWriter, value: uint8) {.inline.} =
  scan_probe_req_ie.ieData[w.len.int] = value
  w.len = w.len + 1

proc appendIeHeader*(w: var ProbeIeWriter, id, len: uint8) {.inline.} =
  w.appendByte(id)
  w.appendByte(len)

proc skip*(w: var ProbeIeWriter, count: uint16) {.inline.} =
  w.len = w.len + count

proc appendDsParamPlaceholder*(w: var ProbeIeWriter) {.inline.} =
  w.appendIeHeader(IE_ID_DS_PARAM, IE_LEN_DS_PARAM)
  w.skip(IE_LEN_DS_PARAM.uint16)

proc appendBytes*(w: var ProbeIeWriter, src: pointer, count: uint32) {.inline.} =
  if count != 0:
    co_pack8p(w.cursor, src, count)
    w.len = w.len + count.uint16

proc appendHtCapabilities*(w: var ProbeIeWriter, me: ptr MeEnvView) {.inline.} =
  w.appendIeHeader(IE_ID_HT_CAP, IE_LEN_HT_CAP)
  w.appendBytes(meHtCapsPtr(me), IE_LEN_HT_CAP.uint32)

proc macId2RatePtr(offset: uint): pointer {.inline.} =
  addr mac_id2rate[offset.int]

proc appendSupportedRates*(w: var ProbeIeWriter, rateStart: uint) {.inline.} =
  w.appendIeHeader(IE_ID_SUPPORTED_RATES, PROBE_REQ_SUPPORTED_RATE_COUNT)
  w.appendBytes(macId2RatePtr(rateStart), PROBE_REQ_SUPPORTED_RATE_COUNT.uint32)

proc finishScanStartReq*(msg: ptr ScanStartReqPayload, ies: ProbeIeWriter) {.inline.} =
  msg.ieBodyLen = ies.len
  msg.scanResult = 0

proc sendScanStartReq*(msg: ptr ScanStartReqPayload, ies: ProbeIeWriter) {.inline.} =
  msg.finishScanStartReq(ies)
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
    ke_msg_alloc(SCAN_START_REQ, TASK_SCAN, TASK_SCANU, ScanStartReqPayloadSize))

proc allocInitializedScanStartReq*(
    req: ptr ScanuStartReqPayload,
    sendProbe: uint8
  ): ptr ScanStartReqPayload {.inline.} =
  result = allocScanStartReq()
  if result != nil:
    result.initScanStartReq(req, sendProbe)

proc copyScanSsidFilterIfPresent*(
    msg: ptr ScanStartReqPayload,
    req: ptr ScanuStartReqPayload
  ) {.inline.} =
  if req.scanType != 0:
    msg.ssidFilter = req.ssidFilter

proc resetUndirectedScanuStart*() {.inline.} =
  scanu_cached_scanresult_clear()
  let scanParam = scanu_env.paramPtr
  if scanParam != nil:
    activeScanuReq().cacheScanuFilterSsid()
  scanu_env.resultCount = 0

proc finishAdvancedScanuScanBand*() {.inline.} =
  let sendProbeFlag = scanu_env.bssidFilterEnabled
  if sendProbeFlag != 0 and scanu_env.directedFound == 0:
    let retryCount = scanu_env.joinRetryCount
    if retryCount > 0:
      scanu_env.joinRetryCount = retryCount - 1
      let logFunc = getLogFunc(204)
      if logFunc != nil:
        cast[proc(a0, a1: uint32, c: pointer, d: uint32){.cdecl, varargs.}](logFunc)(2, 0, nil, 1163)
      scanu_env.resultState = 1
      scanu_env.bssidFilterEnabled = 0
      return
  scanu_confirm(0)

proc scanu_start*(param: pointer) {.exportc, cdecl.} =
  ## Start a scan operation (37 instrs).
  ## From blob: loads scanu_env base (s0). Checks scanu_env.joinFlag (offset 180).
  ## If joinFlag != 0, jumps to shared path (ke_state_set + scan_next).
  ## If joinFlag == 0: scanu_cached_scanresult_clear, memcpy params, clear count,
  ## then shared path. Shared path: ke_state_set(2,1), check probe data,
  ## tail-call scanu_scan_next.
  let joinFlag = scanu_env.bssidFilterEnabled
  if joinFlag == 0:
    resetUndirectedScanuStart()
  ke_state_set(TASK_SCANU, ScanuScanningState)
  # Blob 0x4c..0x74: if scanParam[300] != 0 (probe data ptr) AND
  # scanParam[304]..[305] (halfword probe length) <= 200, copy the probe
  # data into scanu_env[224] via memcpy, then tail-call scanu_scan_next.
  # Previous Nim omitted the probe-data copy entirely.
  let scanParam = scanu_env.paramPtr
  if scanParam != nil:
    let scanReq = activeScanuReq()
    let probeSrc = scanReq.probeReqIe
    if probeSrc != nil:
      let probeLen = scanReq.probeReqIeLen
      if probeLen <= 200'u16:
        let probeDst = scanu_env.probeIeCopyDst
        if probeDst != nil:
          discard c_memcpy(probeDst, probeSrc, probeLen.csize_t)
  scanu_scan_next()

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_scan_next(void);".}
proc scanu_scan_next*() {.exportc, cdecl.} =
  ## Proceed to scan the next channel in the scan list.
  ## From blob (265 instrs): iterates scan_param channel list, builds
  ## SCAN_START_REQ with probe request IEs, sends to lower-MAC scan module.
  ## When all channels are done or abort is requested, sends SCANU_START_CFM.
  let scanParam = scanu_env.paramPtr
  if scanParam == nil:
    # scanu_confirm already performs ke_state_set(SCANU, 0) internally.
    # Blob does not duplicate the state clear here.
    scanu_confirm(0)
    return
  let scanReq = activeScanuReq()
  let numChannels = scanReq.channelCount
  let scanBand = scanu_env.scanBand
  if scanBand != 0:
    finishAdvancedScanuScanBand()
    return
  # Find the first channel for the current SCANU band phase. The blob scans
  # 2.4GHz entries (band byte 0) first, then lets scan_done_ind_handler bump
  # scanu_env+181 before either retrying or confirming.
  let chanIdx = scanReq.firstScanBandChannel(scanBand)
  if chanIdx >= numChannels:
    scanu_env.scanBand = 1
    scanu_scan_next()
    return
  # Allocate SCAN_START_REQ (paramLen=316)
  let msg = allocInitializedScanStartReq(scanReq, scanu_env.bssidFilterEnabled)
  if msg == nil:
    scanu_confirm(0)
    return

  # Iterate through channels, copying entries for the current band phase to
  # msg[0..]. The blob's indexed memcpy destination is msg + count*6.
  msg.copyScanBandChannels(scanReq, chanIdx, scanBand)

  msg.copyScanSsidFilterIfPresent(scanReq)

  # Get total IE len from scanParam; clamp to 200
  var totalIeLen = scanReq.clampedProbeReqIeLen()

  # Determine passive vs active scan mode
  let passiveFlag = scanReq.passive

  # Build probe request IEs in the global scan_probe_req_ie buffer. The
  # SCAN_START_REQ carries the IE length and the lower scan task downloads
  # from scan_probe_req_ie+0x24.
  var ies: ProbeIeWriter

  ies.appendScanSupportedRates(scanBand, passiveFlag)

  # Copy SSID IE if present (blob walks the IE list from scanParam)
  # Blob: checks if IE at scanu_param has tag 10 (SSID), copies length+2 bytes
  var scanuIePtr = scanuAddIeDataAddr()
  if totalIeLen > 0:
    let firstIe = macIeAt(scanuIePtr)
    if firstIe.id == 10:
      # Copy SSID IE: tag + len + data (blob uses co_pack8p).
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

  # Copy extra IEs from host (at scanu_env+232/236)
  let extraIePtr = scanu_env.extraIePtr
  if extraIePtr != nil:
    let extraIeLen = scanu_env.extraIeLen
    if extraIeLen > 0:
      ies.appendBytes(extraIePtr, extraIeLen.uint32)

  msg.sendScanStartReq(ies)

proc scanu_find_result*(bssid: pointer, allocIfMissing: uint8 = 0): pointer {.exportc, cdecl.} =
  ## Find scan result by BSSID (112b in blob). Unrolled 6-byte MAC compare.
  ## Blob: linear scan with stride 28, valid flag at offset 16, BSSID at 0-5.
  let ba = macAddrAt(bssid)
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let entry = addr scanu_env.entries[i]
    if entry.valid == 0:
      if allocIfMissing != 0:
        return entry
    else:
      # Unrolled 6-byte BSSID comparison (matches blob's lbu+bne pattern)
      if entry.bssid[0] == ba.bytes[0] and
         entry.bssid[1] == ba.bytes[1] and
         entry.bssid[2] == ba.bytes[2] and
         entry.bssid[3] == ba.bytes[3] and
         entry.bssid[4] == ba.bytes[4] and
         entry.bssid[5] == ba.bytes[5]:
        return entry
  return nil

proc scanuCachedSsidFor(entry: ptr ScanuResultEntry): ptr ScanuCachedSsid {.inline.} =
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    if (addr scanu_env.entries[i]) == entry:
      return addr scanuCachedSsids[i]
  return nil

proc scanuClearCachedSsid(entry: ptr ScanuResultEntry) {.inline.} =
  let cached = scanuCachedSsidFor(entry)
  if cached != nil:
    discard c_memset(cached, 0, sizeof(ScanuCachedSsid).csize_t)

proc scanuCacheSsid(entry: ptr ScanuResultEntry;
                    ssid: ptr ScanSsidSlotView) {.inline.} =
  let cached = scanuCachedSsidFor(entry)
  if cached == nil:
    return
  discard c_memset(cached, 0, sizeof(ScanuCachedSsid).csize_t)
  cached.valid = 1
  cached.length = ssid.length
  for i in 0 ..< cached.length.int:
    cached.data[i] = ssid.data[i]

proc scanuCachedSsidMatches(entry: ptr ScanuResultEntry;
                            searchData: pointer;
                            searchLen: uint8): bool {.inline.} =
  let cached = scanuCachedSsidFor(entry)
  if cached == nil or cached.valid == 0:
    return false
  if cached.length != searchLen:
    return false
  if searchLen == 0:
    return true
  c_memcmp(searchData, addr cached.data[0], searchLen.csize_t) == 0

proc scanuCachedSsidMeta(entry: ptr ScanuResultEntry): uint32 {.inline.} =
  let cached = scanuCachedSsidFor(entry)
  if cached == nil:
    return 0
  cached.valid.uint32 or (cached.length.uint32 shl 8) or
    (cached.data[0].uint32 shl 16) or (cached.data[1].uint32 shl 24)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void scanu_frame_handler(void*,unsigned long);".}
proc scanu_frame_handler*(frame: pointer, len: uint32) {.exportc, cdecl.} =
  ## Handle received beacon/probe response during active scan.
  ## Reverse-engineered from the blob (859 instructions).
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
  let scanuState = ke_state_get(TASK_SCANU)
  if scanParam == nil or (scanuState != 1 and scanuState != 2):
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return

  let scanReq = activeScanuReq()
  let scanFlags = scanReq.flags

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
      let pf = wpaCallbacks().parseSecurityIe
      if pf != nil:
        let rsn = cast[ptr MacIeView](rsnIePtr)
        let fn = cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](pf)
        if fn(rsnIePtr, rsn.totalLen.uint8, addr secInfo) != nil:
          ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
          return
  elif wpaIePtr != nil:
    if wpa_cbs != nil:
      let pf = wpaCallbacks().parseSecurityIe
      if pf != nil:
        let wpa = cast[ptr MacIeView](wpaIePtr)
        let fn = cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](pf)
        if fn(wpaIePtr, wpa.totalLen.uint8, addr secInfo) != nil:
          ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
          return

  # Security flag filtering for undirected scan
  let bfOn = scanu_env.bssidFilterEnabled
  if bfOn == 0:
    let fHasWpa = (scanFlags and 0x200) != 0
    let fHasRsn = (scanFlags and 0x400) != 0
    if fHasWpa and not fHasRsn:
      if rsnIePtr == nil and wpaIePtr == nil:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return
    elif fHasRsn and not fHasWpa:
      if rsnIePtr == nil:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return
    elif not fHasWpa and not fHasRsn:
      if rsnIePtr != nil and (secInfo.caps and 0x40) != 0:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return

  # Find or allocate scan result entry
  let result = scanu_find_result(addr rx.bssid[0], 1)
  if result == nil:
    ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
    return
  let entry = scanuResultAt(result)

  # BSSID filter match
  if bfOn == 0 and (scanu_env.filterBssid[0] and 1) == 0:
    for i in 0 ..< 6:
      if rx.bssid[i] != scanu_env.filterBssid[i]:
        ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
        return

  # Send result IND if flag bit 8
  var sentInd: uint8 = 0
  if (scanFlags and 0x100) != 0:
    ke_msg_send_basic(76, 1, 2)
    sentInd = 1

  # Security info
  if bfOn == 0:
    if (secInfo.keyMgmtByte and 0x04) != 0:
      entry.securityType = 0x0101; entry.securityAuth = 1
    else:
      entry.securityType = 0; entry.securityAuth = 0
      if rsnIePtr != nil:
        if (secInfo.caps and 0x80) != 0:
          entry.securityType = entry.securityType or 0x0001'u16
        if (secInfo.caps and 0x40) != 0:
          entry.securityType = entry.securityType or 0x0100'u16

  # Fill basic fields
  entry.bssid = rx.bssid
  entry.beaconPeriod = rx.beaconPeriod
  let capI = rx.capInfo
  entry.capInfo = capI
  entry.band = 2'u16 - (capI and 1).uint16

  # SSID IE
  let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
  if ssidIe == nil:
    ssidScratch.length = 0
  else:
    let ssid = ssidIeAt(ssidIe)
    ssidScratch.length = min(ssid.ie.len, 32)
    for i in 0 ..< ssidScratch.length.int:
      ssidScratch.data[i] = ssid.data[i]
  scanuCacheSsid(entry, addr ssidScratch)
  nimFwDbgScanSsidLast =
    ssidScratch.length.uint32 or
    (ssidScratch.data[0].uint32 shl 8) or
    (ssidScratch.data[1].uint32 shl 16) or
    (ssidScratch.data[2].uint32 shl 24)

  # "Not broadcast" SSID debug logging. Blob calls strlen 3 times
  # (once per length-threshold check at 0xa1c/0xa50/0xaae) with the
  # same ptr — each log path recomputes the length.
  block:
    let ssidStrPtr = rx.rxuMgtIndSsidLogPtr
    type LogV = proc(a0, a1: uint32, fmt: pointer, line: uint32, val: uint32) {.cdecl, varargs.}
    var len5 {.volatile.}: uint32 = c_strlen(ssidStrPtr).uint32
    if len5 == 5:
      let lf = cast[LogV](getLogFunc(204))
      if lf != nil: lf(2, 0, nil, 762, len5)
    var len10 {.volatile.}: uint32 = c_strlen(ssidStrPtr).uint32
    if len10 == 10:
      let lf = cast[LogV](getLogFunc(204))
      if lf != nil: lf(2, 0, nil, 452, len10)
    var len14 {.volatile.}: uint32 = c_strlen(ssidStrPtr).uint32
    if len14 == 14:
      let lf = cast[LogV](getLogFunc(204))
      if lf != nil: lf(2, 0, nil, 461, len14)

  entry.noiseFloor1 = rx.noiseFloor1
  entry.noiseFloor2 = rx.noiseFloor2

  # Channel from DS IE
  let dsIe2 = mac_ie_find(ieStart, ieLen, IE_ID_DS_PARAM)
  if dsIe2 != nil:
    let ds = dsParamSetIeAt(dsIe2)
    let freq = dsParamFreq(rx.band, ds)
    entry.chanPtr = me_freq_to_chan_ptr(rx.band, freq)
    let r = rx.rssi
    if entry.rssi < r: entry.rssi = r
  else:
    let r = rx.rssi
    if entry.rssi < r:
      entry.chanPtr = me_freq_to_chan_ptr(rx.band, rx.freq)
      entry.rssi = r

  # SSID filter loop
  let numSsids = scanReq.scanType
  var ssidOk = (numSsids == 0)
  if numSsids > 0:
    var idx = 0
    while idx < numSsids.int:
      let filterSlot = scanSsidSlot(scanReq, idx)
      let fL = filterSlot.length
      if fL != 0:
        if fL == ssidScratch.length and
            c_memcmp(addr filterSlot.data[0], addr ssidScratch.data[0],
                     fL.csize_t) == 0:
          ssidOk = true; break
      else:
        if (scanFlags and 0x40) != 0: scan_env.abortFlag = 1
        if sentInd == 0 and (scanFlags and 0x100) != 0:
          ke_msg_send_basic(76, 1, 2)
        ssidOk = true; break
      idx += 1
    if not ssidOk:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return

  # Directed scan: populate VIF
  if bfOn != 0:
    let vif = vif_mgmt_get_vif(scanReq.vifIdx)
    if vif != nil:
      let vifView = vifChannelAt(vif)
      let htCaps = vifHtCapabilities(vifView)
      let apCfg = vifApConfig(vifView)
      let sec = vifSecurity(vifView)
      let sm = smEnvView()
      let smP = sm.connectInfo
      let ci = connectInfoView(smP)
      let smF = ci.channelDuration
      let vSR = cast[pointer](htCaps)
      let vRO = cast[pointer](addr vifView.basicRates[0])

      vifView.scanBand = entry.band
      discard c_memcpy(addr vifView.bssid[0], addr entry.bssid[0], 6)
      discard c_memcpy(addr vifView.supportedRatesLong[0], addr ssidScratch,
                       sizeof(ScanSsidSlotView).csize_t)
      vifView.capabilityInfo = entry.capInfo
      vifView.beaconIntervalTu = entry.beaconPeriod
      vifView.operChan = entry.chanPtr
      apCfg.securityFlags = 0
      apCfg.noiseFloor1 = entry.noiseFloor1
      apCfg.noiseFloor2 = entry.noiseFloor2

      me_extract_rate_set(ieStart, ieLen, vRO)

      if entry.chanPtr != nil:
        let cB = cast[ptr UncheckedArray[uint8]](entry.chanPtr)
        if cB[2] == 0:
          let rb = me_legacy_rate_bitfield_build(vRO, 1)
          var mr: uint8 = 1
          if (rb and 0x0F) != 0:
            var clzIn: cuint = (rb and 0x0F).cuint
            var c: cint
            {.emit: [c, " = __builtin_clz(", clzIn, ");"].}
            mr = (31 - c).uint8
          apCfg.highestRateBit = mr

      let wmmO = unsafeAddr WMM_OUI[0]
      let wmmIe = mac_vsie_find(ieStart, ieLen, cast[pointer](wmmO), 5)
      if wmmIe != nil:
        let wmm = wmmParameterIeAt(wmmIe)
        vifView.wmmQosInfo = wmm.qosInfo
        vifView.capabilityInfo = vifView.capabilityInfo or 0x200'u16
        for si in 0..3:
          let rv = wmm.ac[si].le32
          let ri = (rv and 0x0F) or ((rv shr 8) shl 4)
          var af = vifView.wmmAcFlags
          case si
          of 0: af = af or ((rv shr 3).uint8 and 2)
          of 1: af = af or ((rv shr 3).uint8 and 2)
          of 2: af = af or ((rv shr 2).uint8 and 4)
          of 3: af = af or ((rv shr 1).uint8 and 8)
          else: discard
          vifView.wmmAcFlags = af
          vifApEdcaWord(apCfg, si)[] = ri
        apCfg.securityFlags = apCfg.securityFlags or 1
      else:
        let dr = 0x0A43'u32
        for si in 0..3:
          vifApEdcaWord(apCfg, si)[] = dr

      if meEnvView().htSupp != 0 and
          (apCfg.securityFlags and 1) != 0:
        let hcIe = mac_ie_find(ieStart, ieLen, IE_ID_HT_CAP)
        if hcIe != nil:
          let hc = htCapIeAt(hcIe)
          htCaps.capInfo = hc.capInfo
          htCaps.ampduParams = hc.ampduParams
          for mi in 0'u8 ..< 16:
            htCaps.mcsSet[mi.int] = hc.mcsSet[mi.int]
          htCaps.extCap = hc.extCap
          htCaps.txBfCaps = hc.txBfCapsLo.uint32
          htCaps.aselCap = hc.aselCap
          apCfg.securityFlags = apCfg.securityFlags or 2

      sec.connected = ci.authRetryGate
      if sm.state == 2:
        ci.channelDuration = smF or 9
      elif ci.authRetryGate != 0 and cast[int32](apCfg.securityFlags) >= 0:
        ci.channelDuration = 0
        var lW, lR: pointer
        var parsedSec {.noinit.}: WpaParsedInfoBuffer
        discard c_memset(addr parsedSec, 0, sizeof(WpaParsedInfoBuffer).csize_t)
        sec.rsnIePtr = 0
        sec.rsnIeLen = 0
        sec.cipher = 0
        find_wpa_rsn_ie(ieStart, ieLen, addr lW, addr lR)
        var sT: uint8 = 0
        if lR != nil:
          sT = 3
          if wpa_cbs != nil:
            let rsn = cast[ptr MacIeView](lR)
            let pf = wpaCallbacks().parseSecurityIe
            if pf != nil:
              discard cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](pf)(
                lR, rsn.totalLen.uint8, addr parsedSec.view)
        elif lW != nil:
          sT = 2
          if wpa_cbs != nil:
            let wpa = cast[ptr MacIeView](lW)
            let pf = wpaCallbacks().parseSecurityIe
            if pf != nil:
              discard cast[proc(a:pointer,b:uint8,c:pointer):pointer{.cdecl.}](pf)(
                lW, wpa.totalLen.uint8, addr parsedSec.view)
        sec.cipher = sT
        # Read key_mgmt as a full 16-bit value (struct wifi_wpa_ie_t has it as
        # int at offset 12, LE). Prior code read only lS[12] (single byte) which
        # silently lost bit 10 (WPA_KEY_MGMT_SAE = 0x400) since it lives in byte 13.
        var aT: uint32 = 2
        let lS = addr parsedSec.view
        let lf = lS.keyMgmtLe
        nimFwDbgScanKeyMgmt = lf
        nimFwDbgScanSmF = smF
        nimFwDbgScanCaps = lS.caps.uint32
        when defined(bl808WifiForcePmfCapable):
          var smFEff = smF or 0x600'u32
        else:
          var smFEff = smF
        if (smFEff and 0x600) != 0:
          if (lf and 0x400) != 0: aT = 1024
          elif (lf and 0x100) != 0: aT = 256
        else:
          if (lf and 0x100) != 0: aT = 256
          elif (lf and 2) == 0: aT = 0
        nimFwDbgScanAT = aT
        if aT != 0:
          sec.groupCipher = lS.groupCipher
          sec.pairwiseCipher = lS.pairwiseCipher
          sec.keyMgmtByte = lS.keyMgmtByte
          sec.keyMgmt = aT
          if (lS.caps and 0x80) != 0:
            sec.pmfCapable = 1
            if (lS.caps and 0x40) != 0 or aT == 1024:
              sec.pmfRequired = 1
              sec.keyMgmtByte = 6
          if aT == 1024: sec.cipher = 4
          let stF = sec.cipher
          if stF >= 2 and stF <= 4:
            let srcSecIe = if lR != nil: lR else: lW
            if srcSecIe != nil:
              let secIe = cast[ptr MacIeView](srcSecIe)
              let secLenRaw = secIe.totalLen
              let copyLen = if secLenRaw > 128'u: 128'u else: secLenRaw
              let slot = if vifView.vifIdx.int < MAX_VIFS: vifView.vifIdx.int else: 0
              discard c_memcpy(addr assocSecIeStore[slot][0], srcSecIe, copyLen.csize_t)
              sec.rsnIePtr = cast[uint32](addr assocSecIeStore[slot][0])
              sec.rsnIeLen = copyLen.uint8
              nimFwTrace2U32("[WIFI-NIMFW] scan_sec_ie ",
                             stF.uint32 or (copyLen.uint32 shl 8),
                             cast[ptr uint32](srcSecIe)[])
            var notify {.noinit.}: WpaScanSecurityNotifyView
            discard c_memset(addr notify, 0, sizeof(WpaScanSecurityNotifyView).csize_t)
            notify.vifIdx = vifView.vifIdx
            notify.macAddr = vifView.macAddr
            notify.bssid = vifView.bssid
            notify.cipher = stF
            notify.keyMgmt = aT.uint16
            notify.cipherPair = cast[ptr uint16](addr sec.groupCipher)[]
            notify.vendorByte124 = lS.vendorByte28
            if wpa_cbs != nil:
              let nf = wpaCallbacks().scanSecurityNotify
              if nf != nil: cast[proc(b:pointer){.cdecl.}](nf)(addr notify)
            let sI = sm.connectInfo
            let secCi = connectInfoView(sI)
            secCi.channelDuration = secCi.channelDuration or 9
            if stF == 4: secCi.authType = 3

      me_bw_check(vSR)
      me_extract_power_constraint(ieStart, ieLen, vSR)
      me_extract_country_reg(ieStart, ieLen, vSR)
      apCfg.securityFlags = apCfg.securityFlags or 0x80000000'u32
      scanu_env.directedFound = 1

  # WPS callback
  if smEnvView().state == 1:
    let wO = unsafeAddr WPS_OUI[0]
    let wIe = mac_vsie_find(ieStart, ieLen, cast[pointer](wO), 4)
    if wIe != nil:
      var wb {.noinit.}: WpsScanCallbackBuffer
      discard c_memset(addr wb.view, 0, sizeof(WpsScanCallbackView).csize_t)
      wb.view.result = result
      wb.view.ssidPtr = cast[pointer](addr ssidScratch.data[0])
      wb.view.ssidLen = ssidScratch.length
      wb.view.capInfo = entry.capInfo
      wb.view.wpsIe = wIe
      var wW, wR: pointer
      find_wpa_rsn_ie(ieStart, ieLen, addr wW, addr wR)
      wb.view.rsnIe = wR
      wb.view.wpaIe = wW
      if wps_cbs != nil:
        let cf = cast[ptr pointer](wps_cbs)[]
        if cf != nil: cast[proc(b:pointer){.cdecl.}](cf)(addr wb.view)

  # Update result count and mark valid
  if entry.valid == 0: scanu_env.resultCount += 1
  if numSsids == 0:
    # Blob: when no SSIDs in filter list and scan_env.abortFlag is not set,
    # forward the frame and return without marking valid.
    if scan_env.abortFlag == 0:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
  entry.valid = 1
  inc nimFwDbgScanFrameAccepted
  nimFwDbgScanFrameLast =
    scanu_env.resultCount.uint32 or
    (entry.rssi.uint8.uint32 shl 8) or
    (entry.band.uint32 shl 16) or
    (bfOn.uint32 shl 24)

  if bfOn != 0:
    if entry.rawMsgPtr != nil:
      ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)
      return
  else:
    if entry.rawMsgPtr != nil:
      ke_msg_free_payload(entry.rawMsgPtr)
      entry.rawMsgPtr = nil

  let rawLen = totalLen.uint32 + 32
  let msg = ke_msg_try_alloc(0x1C00'u16, 2, 2, rawLen)
  entry.rawMsgPtr = msg
  if bfOn != 0:
    scanu_env.pendingRawMsg = msg
  if msg != nil:
    # Single memcpy of entire frame (blob uses 1 call, not header+body split).
    discard c_memcpy(msg, frame, rawLen.csize_t)
  ke_msg_forward_and_change_id(frame, 0x804'u16, 9, 2)

proc scanu_search_by_bssid*(bssid: pointer): pointer {.exportc, cdecl, noinline.} =
  return scanu_find_result(bssid, 0)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void* scanu_search_by_ssid(void*,void*);".}
proc scanu_search_by_ssid*(ssid: pointer, entryIndexOut: pointer): pointer {.exportc, cdecl.} =
  ## Search scan results by SSID (103 instrs).
  ## ssid = pointer to SSID string (first byte = SSID length, rest = SSID data).
  ## entryIndexOut receives the selected result index; blob reads length from ssid[0].
  ## Returns pointer to matching scan result entry, or nil if not found.
  ##
  ## Assembly trace:
  ##   s2 = scanu_env.entries[48] (result filter state at offset 48 in scanu_env)
  ##   s6 = initial filter flag (0 or non-zero from s2)
  ##   s7 = ssid pointer
  ##   Builds search key: ssid[0]+1 bytes starting from ssid, masks with 0xFF00FF
  ##   Loops over SCANU_MAX_RESULT_ENTRIES (6), for each:
  ##     checks entry.valid (offset 20 from entry base)
  ##     if s6 (filter): checks channel info mask against 0xFF00FF pattern
  ##     compares entry RSSI (offset 21) against -128
  ##     compares entry SSID (at entry+188...) against search SSID
  ##     if match: stores result index, records best entry
  ##   Returns pointer to best matching entry or nil.
  let ssidSlot = lengthPrefixedSsidView(ssid)
  # Read the SSID: first byte is length
  let searchLen = ssidSlot.length
  let searchWord = ssidSlot.data[0].uint32 or
    (ssidSlot.data[1].uint32 shl 8) or
    (ssidSlot.data[2].uint32 shl 16) or
    (ssidSlot.data[3].uint32 shl 24)
  nimFwDbgSsidSearch = searchLen.uint32 or (searchWord shl 8)
  nimFwDbgSsidEntries = 0
  nimFwDbgSsidHits = 0
  nimFwTrace2U32("[WIFI-NIMFW] ssid_s ", searchLen.uint32, searchWord)
  if searchLen == 0:
    return nil
  # Build search key (ssid+1 is the actual SSID data, length = searchLen)
  let searchData = cast[pointer](addr ssidSlot.data[0])
  # The blob can apply an optional channel filter here. Keep it disabled for
  # the normal station-connect scan path; the cached scan entries already
  # carry the channel pointer used by sm_get_bss_params.
  let filterState = 0'u32
  var bestEntry: ptr ScanuResultEntry = nil
  var bestRssi: int8 = -128
  for i in 0'u8 ..< SCANU_MAX_RESULT_ENTRIES.uint8:
    let entry = addr scanu_env.entries[i]
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] ssid_entry ",
                            i.uint32 or (entry.valid.uint32 shl 8) or
                              (entry.rssi.uint8.uint32 shl 16),
                            cast[uint32](entry.chanPtr))
      nimFwConnectTrace2U32("[WIFI-CT] ssid_cache ",
                            i.uint32, scanuCachedSsidMeta(entry))
    nimFwTrace2U32("[WIFI-NIMFW] ssid_i ",
                   i.uint32 or (entry.valid.uint32 shl 8),
                   cast[uint32](entry.rawMsgPtr))
    if entry.valid == 0:
      continue
    inc nimFwDbgSsidEntries
    # If filter active, check channel info pattern
    if filterState != 0:
      let chanInfo = cast[uint32](entry.rawMsgPtr)
      if (chanInfo and 0x00FF00FF'u32) == 0:
        continue
    # Check RSSI threshold (offset 17 = rssi, signed byte)
    let rssi = entry.rssi
    if rssi < -128'i8:
      continue
    # Compare SSID: each entry has a rawMsgPtr (offset 24) pointing to the
    # beacon/probe response. The SSID IE is at a known offset in the raw frame.
    # Blob: reads entry.rawMsgPtr, finds SSID IE (id=0), compares length+data.
    let rawMsgPtr = entry.rawMsgPtr
    if rawMsgPtr == nil:
      nimFwTrace2U32("[WIFI-NIMFW] ssid_raw0 ", i.uint32, cast[uint32](entry))
      if not scanuCachedSsidMatches(entry, searchData, searchLen):
        continue
    else:
      # Find SSID IE in the cached RXU_MGT_IND payload. The RXU header is 32
      # bytes, followed by the MAC header (24) and beacon fixed fields (12).
      let rawRx = rxuMgtIndAt(rawMsgPtr)
      let totalLen = rawRx.frameLen
      let ieLen = if totalLen > 36'u16: totalLen.uint32 - 36'u32 else: 0'u32
      let ieStart = rxuMgtIndIeStart(rawMsgPtr)
      let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
      if ssidIe == nil:
        if not scanuCachedSsidMatches(entry, searchData, searchLen):
          continue
      else:
        let entrySsid = ssidIeAt(ssidIe)
        let entrySsidLen = entrySsid.ie.len
        let entryWord = entrySsid.data[0].uint32 or
          (entrySsid.data[1].uint32 shl 8) or
          (entrySsid.data[2].uint32 shl 16) or
          (entrySsid.data[3].uint32 shl 24)
        let entryMeta = i.uint32 or (entry.valid.uint32 shl 8) or
          (entrySsidLen.uint32 shl 16) or (rssi.uint8.uint32 shl 24)
        nimFwTrace2U32("[WIFI-NIMFW] ssid_e ", entryMeta, entryWord)
        if entrySsidLen != searchLen:
          if not scanuCachedSsidMatches(entry, searchData, searchLen):
            continue
        if searchLen > 0:
          let cmpResult = c_memcmp(searchData,
                                   addr entrySsid.data[0],
                                   searchLen.csize_t)
          if cmpResult != 0:
            nimFwTrace2U32("[WIFI-NIMFW] ssid_cmp ", i.uint32, cast[uint32](cmpResult))
            if not scanuCachedSsidMatches(entry, searchData, searchLen):
              continue
    nimFwTrace2U32("[WIFI-NIMFW] ssid_hit ", i.uint32, rssi.uint8.uint32)
    inc nimFwDbgSsidHits
    # Match found: log via g_bl_ops_funcs[204]
    let logFnMatch = getLogFunc(204)
    if logFnMatch != nil:
      logFnMatch(2, 0, nil, 1010, cast[uint32](i), cast[uint32](rssi))
    if entryIndexOut != nil:
      cast[ptr uint32](entryIndexOut)[] = i.uint32
    # Track best RSSI
    if rssi > bestRssi:
      bestRssi = rssi
      bestEntry = entry
  # Blob does NOT have a second fallback loop without filter — the single
  # loop above is the entire scan. Previous Nim added a redundant second
  # pass that matched blob's behavior nowhere.
  return bestEntry

proc scanu_rm_exist_ssid*(ssid: pointer, ssidLen: uint8) {.exportc, cdecl.} =
  ## Remove an existing scan result entry if its SSID matches (76 instrs in blob).
  ## a0=ssid (length-prefixed: ssid[0]=len, ssid[1..]=data), a1=entryIndex (signed).
  ## Blob flow:
  ##   1. Log at line 1032 (entry)
  ##   2. If entryIndex < 0 or ssid == nil, return
  ##   3. Compute entry offset = entryIndex * 28, check entries[idx].valid
  ##   4. Compare scanu_env.filterSsidLen with ssid[0]; if mismatch, skip
  ##   5. memcmp(scanu_env.filterSsid, ssid+1, len); if mismatch, skip
  ##   6. On match: log at line 1043, memset(entry, 0, 28) to clear it
  ##   7. Log at line 1046, return
  let logFn = getLogFunc(4)

  # Log entry
  if logFn != nil:
    logFn(2, 0, nil, 1032)

  # Validate inputs (blob: bltz s0 / beqz s3)
  let entryIdx = cast[int8](ssidLen)
  if entryIdx < 0:
    return
  if ssid == nil:
    return

  # Check entry validity (valid field at offset 20 within entry)
  let entry = addr scanu_env.entries[entryIdx.int]
  if entry.valid == 0:
    return

  # Compare SSID length: scanu_env.filterSsidLen (offset 188 from scanEnvBase)
  let inputSsid = lengthPrefixedSsidView(ssid)
  let inputSsidLen = inputSsid.length

  if inputSsidLen != scanu_env.filterSsidLen:
    # Mismatch, log and return
    if logFn != nil:
      logFn(2, 0, nil, 1046)
    return

  # Compare SSID data: scanu_env.filterSsid (offset 189) vs ssid+1
  let cmpResult = c_memcmp(addr scanu_env.filterSsid[0],
                           addr inputSsid.data[0],
                           inputSsidLen.csize_t)

  if cmpResult != 0:
    # Mismatch
    if logFn != nil:
      logFn(2, 0, nil, 1046)
    return

  # Match found: log and clear the entry
  if logFn != nil:
    logFn(2, 0, nil, 1043)

  # Clear the cached result entry.
  scanuClearCachedSsid(entry)
  discard c_memset(entry, 0, sizeof(ScanuResultEntry).csize_t)

  # Log exit
  if logFn != nil:
    logFn(2, 0, nil, 1046)

proc scanu_cached_scanresult_clear*() {.exportc, cdecl.} =
  ## Clear all cached scan results in scanu_env.
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let e = addr scanu_env.entries[i]
    scanuClearCachedSsid(e)
    e.valid = 0
    e.rssi = -128'i8
    if e.rawMsgPtr != nil:
      ke_msg_free_payload(e.rawMsgPtr)
      e.rawMsgPtr = nil

proc scanu_prune_scanresult_raw_frames() =
  ## Release raw scan frames that are no longer needed after target selection.
  ## The fixed ScanuResultEntry records are retained so the join path can still
  ## use the selected BSS/channel result; dropping raw frame copies lowers peak
  ## heap use before the large SM_CONNECT_IND allocation.
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let e = addr scanu_env.entries[i]
    if e.rawMsgPtr != nil:
      ke_msg_free_payload(e.rawMsgPtr)
      e.rawMsgPtr = nil

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

  var bestEntry: ptr ScanuResultEntry = nil
  var bestRssi: int8 = -128
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let entry = addr scanu_env.entries[i]
    if entry.valid == 0 or entry.rawMsgPtr == nil:
      continue
    let rawRx = rxuMgtIndAt(entry.rawMsgPtr)
    let totalLen = rawRx.frameLen
    let ieLen = if totalLen > 36'u16: totalLen.uint32 - 36'u32 else: 0'u32
    let ieStart = rxuMgtIndIeStart(entry.rawMsgPtr)
    let ssidIe = mac_ie_find(ieStart, ieLen, IE_ID_SSID)
    if ssidIe == nil:
      continue
    let entrySsid = ssidIeAt(ssidIe)
    if entrySsid.ie.len.uint32 != ssidLen:
      continue
    if c_memcmp(cast[pointer](ssid), addr entrySsid.data[0],
                ssidLen.csize_t) != 0:
      continue
    if bestEntry == nil or entry.rssi > bestRssi:
      bestEntry = entry
      bestRssi = entry.rssi

  if bestEntry == nil:
    scanu_prune_scanresult_raw_frames()
    return

  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let entry = addr scanu_env.entries[i]
    if entry != bestEntry and entry.rawMsgPtr != nil:
      ke_msg_free_payload(entry.rawMsgPtr)
      entry.rawMsgPtr = nil

proc scanu_dump_scanresult*() {.exportc, cdecl.} =
  ## Dump scan results for debugging.
  discard

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

proc bestDirectedScanuResult(): ptr ScanuResultEntry {.inline.} =
  if scanu_env.directedFound == 0:
    return nil
  var best: ptr ScanuResultEntry = nil
  var bestRssi: int8 = -128
  for i in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    let entry = addr scanu_env.entries[i]
    if entry.valid == 0 or entry.chanPtr == nil:
      continue
    if best == nil or entry.rssi > bestRssi:
      best = entry
      bestRssi = entry.rssi
  return best

# ###########################################################################
#                   SM: Station State Machine
# ###########################################################################

proc sm_init*() {.exportc, cdecl.} =
  ## Initialize SM module.
  smConnecting = false
  smAuthRetryLimit = 4
  smReconnectTrigger = false
  let sm = smEnvView()
  sm.connectInfo = nil
  sm.deauthPending = 1
  sm.authRetryLimit = 4
  ke_state_set(TASK_SM, SmIdleState)

proc sm_get_bss_params*(resultOut: ptr pointer, chanPtrOut: ptr pointer): bool {.exportc, cdecl.} =
  ## Get BSS parameters from scan results.
  ## From blob (111 instrs): loads sm_env[0] connect info, searches scanu results
  ## by BSSID/SSID, fills resultOut with scan result ptr and chanPtrOut with
  ## channel frequency pointer. Returns true if found.
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil: return false
  let ci = connectInfoView(connInfo)
  let logFn = blOpsFunc(4)

  # Initialize outputs to nil/zero
  resultOut[] = nil
  chanPtrOut[] = nil

  let bssidPtr = cast[pointer](addr ci.bssid[0])
  nimFwDbgBssIn =
    connectInfoSsidLen(ci).uint32 or
    (scanu_env.resultCount.uint32 shl 8) or
    (scanu_env.directedFound.uint32 shl 24)
  when defined(bl808WifiConnectTrace):
    let ssid0 = ci.ssid[0].uint32 or (ci.ssid[1].uint32 shl 8) or
      (ci.ssid[2].uint32 shl 16) or (ci.ssid[3].uint32 shl 24)
    let bssid0 = ci.bssid[0].uint32 or (ci.bssid[1].uint32 shl 8) or
      (ci.bssid[2].uint32 shl 16) or (ci.bssid[3].uint32 shl 24)
    nimFwConnectTrace2U32("[WIFI-CT] bss_in ",
                          connectInfoSsidLen(ci).uint32 or
                            (scanu_env.resultCount.uint32 shl 8) or
                            (scanu_env.directedFound.uint32 shl 24),
                          ssid0)
    nimFwConnectTrace2U32("[WIFI-CT] bss_bssid ", bssid0,
                          ci.bssid[4].uint32 or (ci.bssid[5].uint32 shl 8))

  # Log the BSSID we're searching for (3 iterations logging pairs)
  if logFn != nil:
    for i in 0'u32 ..< 3'u32:
      let bssidByte = ci.bssid[i.uint * 2]
      cast[proc(a0: pointer, a1: uint32){.cdecl.}](logFn)(nil, bssidByte.uint32)

  # Check if BSSID is set (not all zeros and not starting with bit 0 set)
  let b0 = ci.bssid[0]
  var searchBySsid = false
  if (b0 and 1) != 0:
    # BSSID has group bit set -- search by SSID instead
    searchBySsid = true
  else:
    var allZero = true
    for i in 0 ..< 6:
      if ci.bssid[i] != 0:
        allZero = false
        break
    if allZero:
      searchBySsid = true
    else:
      # Search by BSSID
      if logFn != nil:
        let ssidPtr = cast[pointer](addr ci.ssid[0])
        cast[proc(a0: pointer, a1: pointer){.cdecl.}](logFn)(nil, ssidPtr)

      # Call scanu_search_by_bssid (blob's 2-instr trampoline that
      # tail-calls scanu_find_result(bssid, 0)). Matching the blob call
      # here keeps the call graph parity intact.
      resultOut[] = bssidPtr
      let scanResult = scanu_search_by_bssid(bssidPtr)

      if logFn != nil:
        cast[proc(a0: pointer, a1: int32){.cdecl.}](logFn)(nil, (-1'i32))

      if scanResult != nil:
        # Get channel pointer from scan result offset 8
        let chanPtr = scanuResultAt(scanResult).chanPtr
        chanPtrOut[] = chanPtr

        # Log and return
        if logFn != nil:
          cast[proc(a0: pointer){.cdecl.}](logFn)(nil)
        return true

      if connectInfoHasChannelHint(ci):
        chanPtrOut[] = connectInfoChannelHint(connInfo)

  if searchBySsid:
    # BSSID not specified -- search by SSID.
    if logFn != nil:
      cast[proc(a0: pointer){.cdecl.}](logFn)(nil)

    var resultIndex: int32 = -1
    var searchSlot {.noinit.}: ScanSsidSlotView
    connectInfoFillSsidSlot(addr searchSlot, ci)
    let ssidResult = scanu_search_by_ssid(addr searchSlot,
                                          cast[pointer](addr resultIndex))
    nimFwDbgBssSsidResult =
      cast[uint32](cast[uint](ssidResult)) or
      ((resultIndex.uint32 and 0xFF'u32) shl 24)
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] bss_ssid_result ",
                            cast[uint32](cast[uint](ssidResult)),
                            cast[uint32](resultIndex))
    if ssidResult != nil:
      if resultIndex >= 0:
        resultOut[] = ssidResult
        sm.scanResultIndex = resultIndex.uint32
      let chanPtr = scanuResultAt(ssidResult).chanPtr
      chanPtrOut[] = chanPtr
    else:
      let directed = bestDirectedScanuResult()
      nimFwDbgBssDirected =
        cast[uint32](cast[uint](directed)) or
        (scanu_env.directedFound.uint32 shl 24)
      when defined(bl808WifiConnectTrace):
        nimFwConnectTrace2U32("[WIFI-CT] bss_directed ",
                              cast[uint32](cast[uint](directed)),
                              scanu_env.directedFound.uint32)
      if directed != nil:
        resultOut[] = cast[pointer](directed)
        chanPtrOut[] = directed.chanPtr
      elif connectInfoHasChannelHint(ci):
        chanPtrOut[] = connectInfoChannelHint(connInfo)

  if chanPtrOut[] == nil:
    if connectInfoHasChannelHint(ci):
      chanPtrOut[] = connectInfoChannelHint(connInfo)

  # Final log
  nimFwDbgBssOut =
    cast[uint32](cast[uint](resultOut[])) xor
    (cast[uint32](cast[uint](chanPtrOut[])) shl 1)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] bss_out ",
                          cast[uint32](cast[uint](resultOut[])),
                          cast[uint32](cast[uint](chanPtrOut[])))
  if logFn != nil:
    cast[proc(a0: pointer){.cdecl.}](logFn)(nil)
  return resultOut[] != nil

proc sm_scan_bss*(bssid: pointer, ssid: pointer, chanInfo: pointer) {.exportc, cdecl.} =
  ## Initiate a BSS scan for connection.
  ## From blob (92 instrs): loads sm_env[0] (connect info), allocates SCANU_START_REQ
  ## message (320 bytes), populates scan parameters, initiates scan via ke_state_set.
  ##
  ## Register map: s0=msg, s1=connInfo, s2=chanInfo,
  ##   s3=target BSSID filter, s4=local VIF MAC
  let connInfo = smEnvView().connectInfo
  let ci = connectInfoView(connInfo)

  # Allocate SCANU_START_REQ message: ke_msg_alloc(0x800, 2, 4, 320)
  let msg = scanuStartReqView(
    ke_msg_alloc(SCANU_START_REQ, TASK_SCANU, TASK_SM,
                 ScanuStartReqPayloadSize))

  let vifIdx = ci.vifIdx

  # Clear and populate scan request fields
  msg.probeReqIe = nil
  msg.vifIdx = vifIdx
  msg.probeReqIeLen = 0

  connectInfoFillSsidSlot(scanSsidSlot(msg, 0), ci)

  # Set active scan flag
  msg.scanType = 1

  # Copy target BSSID filter into msg+286. Nil means undirected.
  if ssid != nil:
    discard c_memcpy(addr msg.bssid[0], ssid, msg.bssid.len.csize_t)
  else:
    discard c_memset(addr msg.bssid[0], 0xFF, msg.bssid.len.csize_t)

  # Copy local VIF MAC into msg+292
  discard c_memcpy(addr msg.localMac[0], bssid, msg.localMac.len.csize_t)

  msg.flags = ci.channelDuration

  # Handle channel info
  if chanInfo != nil:
    # Copy channel info (6 bytes) into msg
    discard c_memcpy(addr msg.channelList[0], chanInfo, ScanChannelEntrySize.csize_t)
    msg.channelCount = 1
  else:
    # No specific channel -- scan all channels from scanu_env
    let channelConfig = scanuChannelConfig()
    let numChan = channelConfig.count
    msg.channelCount = 0
    var chanIdx: int = 0
    var resultCount: uint8 = 0
    while chanIdx < numChan.int:
      # Skip channels with flag bit 1 set (DFS or excluded)
      let chanEntry = addr channelConfig.entries[chanIdx]
      if (chanEntry.flags and 2) == 0:
        # Copy 6-byte channel entry into scan message channel list
        discard c_memcpy(addr msg.channelList[resultCount.int],
                         chanEntry, ScanChannelEntrySize.csize_t)
        msg.channelCount = msg.channelCount + 1
        resultCount = resultCount + 1
      chanIdx += 1

  # Send the scan request and advance SM state
  ke_msg_send(msg)
  ke_state_set(TASK_SM, SmScanningState)

proc sm_join_bss*(bssid: pointer, ssid: pointer, joinInfo: pointer, flag: uint32) {.exportc, cdecl.} =
  ## Join a BSS (send join request to scan module).
  ## From blob (74 instrs): allocates SCANU_JOIN_REQ (320 bytes), populates join
  ## params from sm_env connect info, sends message and advances SM state.
  ##
  ## Register map: s0=msg, s1=connInfo, s2=sm_env_reloc, s3=flag, s4=1,
  ##   s5=bssid, s6=ssid
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  let ci = connectInfoView(connInfo)

  # Allocate SCANU_JOIN_REQ: ke_msg_alloc(0x802, 2, 4, 320)
  let msg = scanuStartReqView(
    ke_msg_alloc(SCANU_JOIN_REQ, TASK_SCANU, TASK_SM,
                 ScanuStartReqPayloadSize))

  # Copy join info (6 bytes) into msg payload start
  discard c_memcpy(addr msg.channelList[0], joinInfo,
                   ScanChannelEntrySize.csize_t)

  # Set join-specific flag
  msg.channelCount = 1

  connectInfoFillSsidSlot(scanSsidSlot(msg, 0), ci)

  # Set active scan
  msg.scanType = 1

  # Clear scan state fields
  msg.probeReqIeLen = 0
  msg.probeReqIe = nil

  let vifIdx = ci.vifIdx

  # Copy SSID (6 bytes) into msg+286
  discard c_memcpy(addr msg.bssid[0], ssid, msg.bssid.len.csize_t)

  msg.vifIdx = vifIdx

  # Copy BSSID (6 bytes) into msg+292
  discard c_memcpy(addr msg.localMac[0], bssid, msg.localMac.len.csize_t)

  msg.flags = ci.channelDuration

  # Set flag in message byte 3 if flag arg is nonzero
  if flag != 0:
    msg.channelList[0].flags = msg.channelList[0].flags or 1

  sm.joinBssFlag = flag.uint8

  # Send message
  ke_msg_send(msg)

  # Advance SM state to waiting-for-join.
  ke_state_set(TASK_SM, SmWaitingState)

proc sm_add_chan_ctx*(param: pointer): uint8 {.exportc, cdecl, discardable.} =
  ## Add channel context for the target BSS (27 instrs). Returns chan_ctxt_add's
  ## status (non-zero = failure, matching blob).
  let connInfo = smEnvView().connectInfo
  let vifIdx = connectInfoView(connInfo).vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let chanDef = vif.operChan
  let chan = cast[ptr ScanChannelEntry](chanDef)
  var chanReq = default(ChanCtxtDefView)
  chanReq.band = chan.band
  chanReq.chanType = connectInfoChannelContext(connInfo).chanType
  chanReq.primFreq = chan.prim20Freq
  chanReq.centerFreq1 = vifChannelCenterFreq1(vif, chan.prim20Freq)
  chanReq.centerFreq2 = vifChannelCenterFreq2(vif)
  chanReq.txPower = cast[uint8](chan.txPower)
  return chan_ctxt_add(cast[pointer](addr chanReq), cast[ptr uint8](param))

proc sm_send_next_bss_param*(param: pointer) {.exportc, cdecl.} =
  ## Pop the next prepared BSS-parameter message from the sm_env+8 queue and
  ## send it. Matches blob: co_list_pop_front + ke_msg_send (tail call).
  ## If queue unexpectedly empty, asserts (sm.c:600).
  let node = co_list_pop_front(addr smEnvView().pendingBssParams)
  if node == nil:
    assert_err("sm.c", "sm.c", 600)
    return
  # node is a CoListHdr embedded at start of the ke_msg header.
  let msgPayload = keMsgPayload(cast[ptr KeMsgHdr](node))
  ke_msg_send(msgPayload)

proc sm_set_bss_param*(param: pointer) {.exportc, cdecl.} =
  ## Set BSS parameters for association.
  ## Blob structure (166 instrs): allocates all MM config messages up front,
  ## initializes a local message queue at sm_env+8 with co_list_init, then
  ## pushes each prepared ke_msg onto that queue via co_list_push_back. The
  ## actual sends are dispatched later by sm_send_next_bss_param which pops
  ## from the queue. Call sequence:
  ##   ke_msg_alloc x5, co_list_init(sm_env+8),
  ##   co_list_push_back x2 (PS_DISABLE, BSSID+memcpy),
  ##   me_legacy_rate_bitfield_build, co_list_push_back x2 (RATES, BCN_INT),
  ##   ke_msg_alloc (EDCA loop), co_list_push_back (EDCA),
  ##   co_list_push_back (VIF_STATE), sm_send_next_bss_param, ke_state_set.
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil:
    return
  let ci = connectInfoView(connInfo)
  let vifIdx = ci.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let smListPtr = addr sm.pendingBssParams

  template pushMsg(msg: pointer) =
    ## Push an allocated ke_msg onto sm_env+8 queue.
    let msgHdr = cast[ptr CoListHdr](keMsgHdrFromPayload(msg))
    co_list_push_back(smListPtr, msgHdr)

  # Allocate all 5 up-front messages (blob 0x2c..0x76)
  let msgPs     = ke_msg_alloc(ME_SET_PS_DISABLE_REQ,  TASK_ME, TASK_SM,
                               MeSetPsDisableReqPayloadSize)
  let msgBssid  = ke_msg_alloc(MM_SET_BSSID_REQ,        TASK_MM, TASK_SM,
                               MmSetBssidReqPayloadSize)
  let msgRates  = ke_msg_alloc(MM_SET_BASIC_RATES_REQ,  TASK_MM, TASK_SM,
                               MmSetBasicRatesReqPayloadSize)
  let msgBcn    = ke_msg_alloc(MM_SET_BEACON_INT_REQ,   TASK_MM, TASK_SM,
                               MmSetBeaconIntReqPayloadSize)
  let msgActive = ke_msg_alloc(ME_SET_ACTIVE_REQ,       TASK_ME, TASK_SM,
                               MeSetActiveReqPayloadSize)

  # Initialize the queue (blob 0x88)
  co_list_init(smListPtr)

  # 1. ME_SET_PS_DISABLE_REQ (blob 0x90..0xAA)
  if msgPs != nil:
    let req = cast[ptr MeSetPsDisableReqPayload](msgPs)
    req.disable = 1
    req.vifIdx = vifIdx
    pushMsg(msgPs)

  # 2. MM_SET_BSSID_REQ: memcpy BSSID from VIF+380 (blob 0xCE), then push (0xEA)
  if msgBssid != nil:
    let req = cast[ptr MmSetBssidReqPayload](msgBssid)
    discard c_memcpy(addr req.bssid[0], addr vif.bssid[0], 6)
    req.vifIdx = vifIdx
    pushMsg(msgBssid)

  # 3. MM_SET_BASIC_RATES_REQ: rate bitfield (blob 0x10A), push (0x12A)
  let rateBitfield = me_legacy_rate_bitfield_build(
    cast[pointer](addr vif.basicRates[0]), 1)
  if msgRates != nil:
    let req = cast[ptr MmSetBasicRatesReqPayload](msgRates)
    let chanPtr = vif.operChan
    if chanPtr != nil:
      req.band = cast[ptr ScanChannelEntry](chanPtr).band
    req.rateBitfield = rateBitfield
    req.vifIdx = vifIdx
    pushMsg(msgRates)

  # 4. MM_SET_BEACON_INT_REQ (blob push at 0x152)
  if msgBcn != nil:
    let req = cast[ptr MmSetBeaconIntReqPayload](msgBcn)
    req.interval = vif.beaconIntervalTu
    req.vifIdx = vifIdx
    pushMsg(msgBcn)

  # 5. 4x MM_SET_EDCA_REQ per AC (blob 0x17A alloc, 0x1BC push). These are
  # pushed BEFORE the ME_SET_ACTIVE_REQ because the blob emits the active
  # msg last to ensure ME activation fires after the ACs are programmed.
  for ac in 0'u8 ..< 4'u8:
    let msg = ke_msg_alloc(MM_SET_EDCA_REQ, TASK_MM, TASK_SM,
                           MmSetEdcaReqPayloadSize)
    if msg != nil:
      let req = cast[ptr MmSetEdcaReqPayload](msg)
      req.edcaParam = cast[ptr uint32](addr vif.edcaParams[ac.uint * 32])[]
      req.acmFlag = ac
      var psFlag: uint8 = 0
      if chanEnvView().currentCtxt != nil:
        if vifEdcaPsGate(vif) < 0:
          if ((1'u8 shl ac) and ci.qosInfo) != 0:
            psFlag = 1
      req.uapsdAc = psFlag
      req.vifIdx = vifIdx
      pushMsg(msg)

  # 6. ME_SET_ACTIVE_REQ at the tail (blob push at 0x1E6). Previous Nim
  # pushed msgActive above AND allocated a separate MM_SET_VIF_STATE_REQ
  # at the end — blob issues only ME_SET_ACTIVE_REQ here and never a
  # dedicated VIF-state message. The ME activation ripples into the MM
  # state transition downstream.
  if msgActive != nil:
    let req = cast[ptr MeSetActiveReqPayload](msgActive)
    req.active = 1
    req.vifIdx = vifIdx
    pushMsg(msgActive)

  # 8. Advance state, then dispatch the queue. The confirmation handlers
  # require state 4 before the first queued request can complete.
  ke_state_set(TASK_SM, SmSettingBssState)
  sm_send_next_bss_param(param)

proc sm_handle_connection*(vifIdxOrFlag: uint32, status: uint32,
    callbackCtx: pointer, failureFn: pointer) {.exportc, cdecl.} =
  ## Handle connection state change — send deauthentication frame (434 bytes in blob).
  ## Blob call sequence: ke_state_set(SM,10), txl_frame_get(0x200),
  ##   tpc_update_frame_tx_power, memcpy x3 (DA/SA/BSSID), txl_get_seq_ctrl,
  ##   mfp_protect_mgmt_frame, txu_cntrl_protect_mgmt_frame (conditional),
  ##   me_build_deauthenticate(bodyStart, 3), mfp_add_mgmt_mic (conditional),
  ##   txl_frame_push(frame, 3). On fail: failureFn(vifEntry, status, 3).
  let vifIdx = vifIdxOrFlag.uint8
  let vif = vifChannelForIdx(vifIdx)

  # Early exit if VIF byte at +86 is non-zero (blob: lbu a5,86(s3); bnez)
  let vifFlag = vif.vifType
  if vifFlag != 0:
    return

  # Save staIdx from VIF before frame alloc (blob: lbu s8,96(s3))
  let staIdx = vif.staIdx

  # Set SM state to disconnecting (blob: ke_state_set(4, 10))
  ke_state_set(TASK_SM, SmDisconnectingState)

  # Allocate TX frame (blob: txl_frame_get(0x200) = li a0,512)
  let frame = txl_frame_get(512)
  if frame == nil:
    # Failure: tail-call failureFn(vifEntry, status, 3)
    if failureFn != nil:
      cast[proc(a: pointer, b: uint32, c: uint32){.cdecl.}](failureFn)(
        cast[pointer](vif), status, 3)
    return

  let desc = hostTxDescAt(frame)

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
  let seqCtrl = txl_get_seq_ctrl()
  hdr.seqCtrl = seqCtrl

  # Store callback/ctx at frame+208/212 (blob: sw s6,208(s0); sw s3,212(s0))
  desc.callback = callbackCtx
  desc.callbackArg = cast[pointer](vif)
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
    # Read security header length added (blob: lbu s2,98(s0); addi s2,s2,24)
    bodyOffset = desc.hdrLen.uint + 24

  # Build deauthentication body (blob: me_build_deauthenticate(macHdr+bodyOffset, 3))
  let bodyStart = cast[pointer](addr link.macHeader[bodyOffset])
  let deauthLen = me_build_deauthenticate(bodyStart, 3)
  var totalLen = bodyOffset + deauthLen.uint

  # Conditional: mfp_add_mgmt_mic if mfp returned 2
  if mfpResult == 2:
    let micLen = mfp_add_mgmt_mic(frame, cast[uint32](totalLen),
      cast[uint32](totalLen))
    totalLen = totalLen + micLen.uint
  elif mfpResult == 1:
    # If mfp==1, check for CCMP/TKIP tail (blob: lbu a5,100(s0); add s2,s2,a5)
    let secTailLen = desc.secTailLen
    totalLen = totalLen + secTailLen.uint

  # TX descriptor setup (blob: lw a4,112(s0); lw a5,20(a4); ...)
  if desc.hwDesc != nil:
    let txDesc = hostTxHwDescAt(desc.hwDesc)
    let payloadLen = txDesc.payloadStart
    txDesc.payloadEnd = payloadLen - 1 + totalLen.uint32
    txDesc.frameLen = totalLen.uint32 + 4

  # Push frame to TX queue (blob: txl_frame_push(frame, 3))
  txl_frame_push(frame, 3)

  # Completion: tail-call failureFn(vifEntry, status, 3)
  if failureFn != nil:
    cast[proc(a: pointer, b: uint32, c: uint32){.cdecl.}](failureFn)(
      cast[pointer](vif), status, 3)

proc sm_disconnect_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.} =
  ## Process a disconnect request (122 bytes in blob, 39 instrs).
  ## Blob: ke_msg_alloc, ke_timer_clear, clear smConnecting + sm_env[0],
  ## sm_delete_resources, populate msg, tail-call ke_msg_send.
  inc nimFwDbgDisconnectProcess
  let msg = cast[ptr SmDisconnectProcessIndPayload](
    ke_msg_alloc(SM_DISCONNECT_IND, TASK_API, TASK_SM,
                 SmDisconnectProcessIndPayloadSize))
  if msg == nil:
    return
  # Clear SM response timeout timer (blob: ke_timer_clear(0x1009, 4))
  let smTimerId = KE_FIRST_MSG(TASK_SM.uint16) + 9  # SM_RSP_TIMEOUT_IND
  ke_timer_clear(smTimerId, TASK_SM)
  smConnecting = false
  let sm = smEnvView()
  # Clean up SM resources before clearing sm_env[0]; sm_delete_resources reads
  # the active connection pointer from sm_env[0].
  sm_delete_resources(param)
  sm.connectInfo = nil
  msg.status = statusCode
  msg.reason = reasonCode
  if param != nil:
    msg.vifIdx = vifChannelAt(param).vifIdx
  ke_msg_send(msg)

proc sm_disconnect_deauth_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Confirmation that deauth frame was sent during disconnect.
  ## From blob (5 instrs): li a2,3; li a1,19; jr sm_disconnect_process
  ## Tail-calls sm_disconnect_process(param, WLAN_FW_DISCONNECT_BY_USER_WITH_DEAUTH, 3).
  sm_disconnect_process(param, 19, 3)

proc sm_connect_ind*(statusCode: uint16, reasonCode: uint16) {.exportc, cdecl, noinline.} =
  ## Send connect indication to host.
  ## From blob (131 instrs): loads sm_env[0] and vif_info_tab to build a full
  ## SM_CONNECT_IND message with BSSID, aid, channel info, VHT capabilities,
  ## then sends to host. Also notifies the AP via chan_bcn_detect_start if needed.
  ##
  ## a0=statusCode(->s8), a1=reasonCode(->s9)
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  let ci = connectInfoView(connInfo)

  let vifIdx = ci.vifIdx
  let vif = vifChannelForIdx(vifIdx)

  # Get sm_env secondary fields.
  # Blob re-uses the 860-byte message that sm_connect_req_handler parked at
  # sm_env[4] — it is NOT a fresh ke_msg_alloc here. Nim was allocating a
  # new buffer, which leaked the prior one AND sent an uninitialised msg
  # downstream. The blob's smEnvSecond pointer and the "msg" pointer are
  # the same object.
  let smEnvSecond = sm.connectIndMsg
  let msg = smEnvSecond
  if msg == nil:
    return
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
    ind.assocIeBuffer[12] = (chan.channel.primFreq and 0xFF).uint8
    ind.assocIeBuffer[13] = (chan.channel.primFreq shr 8).uint8
    ind.assocIeBuffer[14] = (chan.channel.centerFreq1 and 0xFF).uint8
    ind.assocIeBuffer[15] = (chan.channel.centerFreq1 shr 8).uint8
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

  # Blob state handling (offsets 0xda-0xf4, 0x14a-0x1a0):
  #   if statusCode == 0:  ke_state_set(TASK_SM, 0)       ; success -> idle
  #   else:                ke_state_set(TASK_SM, 10)      ; failure -> failed
  #                        (failure path also runs scanu_rm_exist_ssid etc.)
  # Then both paths fall through to ke_msg_free + ke_msg_send + sm_delete_resources.
  # There is NO second ke_state_set at the end.
  if statusCode == 0:
    ke_state_set(TASK_SM, SmIdleState)
  else:
    # Failure path (blob .L97 at 0x14a-0x1a0):
    #   ke_state_set(TASK_SM, 10)
    #   ... diagnostic logs ...
    #   if (sm_env[28] >= 0):
    #       scanu_rm_exist_ssid(connInfo /*s5*/, sm_env[28] /*s6*/)
    #       sm_env[28] = -1
    # Then falls through to L98 via unconditional jump.
    ke_state_set(TASK_SM, SmDisconnectingState)
    let bssIdx = cast[int32](sm.scanResultIndex)
    if bssIdx >= 0:
      scanu_rm_exist_ssid(connInfo, cast[uint8](bssIdx and 0xFF))
      sm.scanResultIndex = 0xFFFFFFFF'u32

  # Blob: ke_msg_free(connInfoOld - 12). sm_env[0] holds the payload.
  let connInfoOld = sm.connectInfo
  if connInfoOld != nil:
    ke_msg_free(keMsgHdrFromPayload(connInfoOld))
  sm.connectInfo = nil

  # Send message to host (blob: ke_msg_send at offset 0x10A)
  ke_msg_send(msg)

  # Clear secondary sm_env slot (blob: sm_env[4] = 0 at offset 0x116-0x11a)
  sm.connectIndMsg = nil

  # Blob: sm_delete_resources — cleanup SM resources (offset 0x198, tail-call)
  sm_delete_resources()
  if statusCode != 0 and ke_state_get(TASK_SM) == SmDisconnectingState:
    ke_state_set(TASK_SM, SmIdleState)

proc sm_connect_abort_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.} =
  ## Process a connect abort request.
  ## From blob (5 instrs): shuffles args (a0=a1, a1=a2) and tail-calls sm_connect_ind.
  sm_connect_ind(statusCode, reasonCode)

proc sm_connect_abort_deauth_cfm*(param: pointer) {.exportc, cdecl.} =
  ## Confirmation of deauth during connect abort.
  ## From blob (5 instrs): li a1,3; li a0,23; jr sm_connect_ind
  ## Tail-calls sm_connect_ind(WLAN_FW_CONNECT_ABORT_BY_USER_WITH_DEAUTH=23, 3).
  sm_connect_ind(23, 3)

proc sm_deauth_send*(param: pointer, reason: uint16) {.exportc, cdecl.} =
  ## Send a deauthentication frame.
  ## From blob (93 instrs): loads sm_env[0], gets vifIdx from connInfo+59,
  ## computes VIF entry, allocates 512-byte frame, builds deauth MAC header
  ## with addresses from VIF, calls me_build_deauthenticate, sets TX descriptor
  ## fields, and pushes frame via txl_frame_push(frame, 3).
  let connInfo = smEnvView().connectInfo
  if connInfo == nil:
    return
  let vifIdx = connectInfoView(connInfo).vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  let sta = staInfoForIdx(staIdx)
  let bssidPtr = cast[pointer](addr sta.macAddr[0])
  # Allocate 512-byte frame buffer (blob: txl_frame_get, NOT ke_msg_alloc)
  let frame = txl_frame_get(512)
  if frame == nil:
    return
  let desc = hostTxDescAt(frame)
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
  # Push to TX
  txl_frame_push(frame, 3)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_auth_send(unsigned short, unsigned long);".}
proc sm_auth_send*(authSeqNum: uint16, statusCode: uint32) {.exportc, cdecl.} =
  ## Send an authentication frame (166 instructions in blob).
  ##
  ## Register map: s0=frame s1=frame_body(desc+108) s2=bodyLen s3=sm_env[0]
  ##   s4=sm_env s5=authSeqNum(a0) s6=statusCode(a1) s7=bssid_ptr(sta+4)
  ##   s8=secondaryIeLen
  ##
  ## Steps:
  ##   1. Load connect info from sm_env[0], extract vifIdx from info[59]
  ##   2. Compute VIF/STA entries, get BSSID from sta_info_tab[staIdx]+4
  ##   3. Allocate 512-byte frame via txl_frame_get
  ##   4. Call me_build_authenticate to build auth body
  ##   5. Copy BSSID into frame header: DA, SA, BSSID (3 x memcpy of 6 bytes)
  ##   6. Set sequence number, frame type=0xB0
  ##   7. If auth_algo==1(shared key) and seq==3: append challenge text IE
  ##   8. Compute final lengths, set TX descriptor, push frame
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil: return
  let ci = connectInfoView(connInfo)

  let vifIdx = ci.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  let sta = staInfoForIdx(staIdx)
  let bssidPtr = cast[pointer](addr sta.macAddr[0])

  # Read auth parameters from connect info
  let authAlgo = ci.authType
  nimFwDbgSaeAuthAlgo = authAlgo.uint32

  # Allocate frame buffer (512 bytes)
  let frame = txl_frame_get(512)
  if frame == nil:
    # .L116: Allocation failure -- send timeout indication
    sm_connect_ind(0, 0)
    return
  let desc = hostTxDescAt(frame)

  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Build auth frame header.
  hdr.frameControl = 0x00B0'u16
  hdr.duration = 0

  # Copy DA (6 bytes) from BSSID to frame body+352
  discard c_memcpy(addr hdr.addr1[0], bssidPtr, 6)
  # Copy SA (6 bytes) from VIF+80 to frame body+358
  discard c_memcpy(addr hdr.addr2[0], cast[pointer](addr vif.macAddr[0]), 6)
  # Copy BSSID (6 bytes) from BSSID to frame body+364
  discard c_memcpy(addr hdr.addr3[0], bssidPtr, 6)

  # Generate and write sequence number (frame body+370..371)
  let seqNum = txl_get_seq_ctrl()  # blob uses txl_get_seq_ctrl for sequence numbers
  hdr.seqCtrl = seqNum

  # Store AP channel info at frame+47
  let apChanIdx = vif.vifIdx
  desc.vifIdx = apChanIdx
  desc.hdrLen = 0
  desc.secTailLen = 0
  desc.staInfoIdx = staIdx

  # Build authenticate IE body
  var bodyLen: uint32 = 24  # base auth frame size

  # Check for shared key auth with challenge text
  let authType = ci.authType
  if authType == 1 and authSeqNum == 3:
    # Shared key auth seq 3: append challenge text from connect info
    bodyLen = 24  # me_build_authenticate handles this internally
    let ieStartPtr = cast[pointer](addr link.macHeader[bodyLen])
    # Copy challenge text IE (24 bytes) from connect_info
    let extraLen = desc.hdrLen
    bodyLen += extraLen.uint32 + 24

  # .L117/.L128: Write auth body via me_build_authenticate
  let authBodyPtr = cast[pointer](addr link.macHeader[bodyLen])
  let builtLen = me_build_authenticate(
    authBodyPtr, authAlgo.uint16, authSeqNum, statusCode.uint16, nil)

  # Update frame lengths
  # .L128: Set TX descriptor fields
  let thd = hostTxHwDescAt(desc.hwDesc)
  desc.callback = nil
  desc.callbackArg = frame

  # Total frame length excluding FCS.
  var totalLen = bodyLen + builtLen
  let extraIeLen = desc.secTailLen
  totalLen += extraIeLen.uint32

  # Set THD length fields
  let thdBase = thd.payloadStart
  thd.payloadEnd = thdBase - 1 + totalLen
  thd.frameLen = totalLen + 4
  let authRawLen = if totalLen > nimFwDbgAuthTxRaw.len.uint32:
    nimFwDbgAuthTxRaw.len.uint32
  else:
    totalLen
  nimFwDbgAuthTxLen = totalLen
  nimFwDbgAuthTxMeta = authSeqNum.uint32 or (authAlgo.uint32 shl 16) or
    (vifIdx.uint32 shl 24) or (staIdx.uint32 shl 28)
  nimFwDbgAuthTxDesc = thd.frameLen or (authRawLen shl 16)
  discard c_memset(addr nimFwDbgAuthTxRaw[0], 0, nimFwDbgAuthTxRaw.len.csize_t)
  discard c_memcpy(addr nimFwDbgAuthTxRaw[0],
                   cast[pointer](addr link.macHeader[0]),
                   authRawLen.csize_t)
  let authTrace = cast[ptr AuthBodyTraceView](authBodyPtr)
  let authTraceWord0 =
    authTrace.fixed.authAlgo.uint32 or (authTrace.fixed.authSeq.uint32 shl 16)
  let authTraceWord1 =
    authTrace.fixed.statusCode.uint32 or
    (authTrace.challengeTag.uint32 shl 16) or
    (authTrace.challengeLen.uint32 shl 24)
  nimFwTrace2U32("[WIFI-NIMFW] auth_tx ",
                 authSeqNum.uint32 or (authAlgo.uint32 shl 16),
                 vifIdx.uint32 or (staIdx.uint32 shl 8) or
                   ((statusCode and 0xFFFF'u32) shl 16))
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] auth_tx ",
                          authSeqNum.uint32 or (authAlgo.uint32 shl 16),
                          vifIdx.uint32 or (staIdx.uint32 shl 8) or
                            ((statusCode and 0xFFFF'u32) shl 16))
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
                          authTraceWord0,
                          authTraceWord1)
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
                 authTraceWord0,
                 authTraceWord1)

  # Check for SAE auth (blob: me_build_sae_authenticate path)
  if authAlgo == 3:
    let saeLen = me_build_sae_authenticate(frame, 3'u16, authSeqNum, statusCode.uint16, vifIdx.uint32)
    if saeLen == 0:
      # .L119: SAE build failed — release frame and indicate failure
      txl_frame_release(frame)
      sm_connect_ind(2, 0xFFFF)
      return

  when defined(bl808WifiUseBl808Rf):
    rfPriApplyWb03AuthTxLatches()
    rfPriCaptureWb03AuthTxPrePush()
    applyForcedInternalMgmtTxPower(thd)
    captureAuthTxHwPrePush(desc, thd)

  # Push frame to TX queue (AC=3 = VO)
  txl_frame_push(frame, 3)

  # Set auth timeout timer (blob: ke_timer_set)
  let listenFlag = sm.connectFlags
  var listenInterval: uint32 = 0x7D000  # default 512000 us
  if listenFlag != 0:
    if ci.authType != 3:
      listenInterval = 0x1E000  # reduced for non-SAE
  # Set auth response timeout timer (blob: ke_timer_set)
  ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, listenInterval)

  # Vendor waits for the auth response in state 5. State 6 is the
  # association-response wait state after a successful auth response.
  ke_state_set(TASK_SM, SmAuthStartingState)

  smConnecting = true

proc sm_auth_send_pre*(authSeqNum: uint16, statusCode: uint32 = 0) {.exportc, cdecl.} =
  ## Pre-send authentication (5 instrs in blob).
  ## From blob: mv a2,a1; mv a1,a0; li a0,5; jr sm_auth_assoc_send_according_chan
  ## Tail-calls sm_auth_assoc_send_according_chan(nextState=5, param1=<a0 in>,
  ## param2=<a1 in>). The Nim declaration only has `param` (a0); the callee's
  ## second arg comes from a1 at the call site. Recover a1 via inline asm.
  sm_auth_assoc_send_according_chan(SmAuthStartingState, authSeqNum, statusCode)

proc sm_auth_start*(param: pointer) {.exportc, cdecl.} =
  ## Start authentication (24 bytes in blob, 8 instrs).
  ## From blob: loads sm_env[0] (connect info), clears auth retry count at offset 60,
  ## tail-calls sm_auth_assoc_send_according_chan(1, 0, 0).
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo != nil:
    connectInfoAuthRetry(connInfo)[] = 0
  sm_auth_send_pre(1'u16, 0)

proc sm_assoc_req_send*(param: pointer) {.exportc, cdecl.} =
  ## Send association request frame (424 bytes in blob).
  ## Blob call sequence: txl_frame_get(256), tpc_update_frame_tx_power,
  ##   memcpy x3 (DA/SA/BSSID), txl_get_seq_ctrl, me_build_associate_req,
  ##   txl_frame_push(3), ke_timer_set, ke_state_set(SM,6).
  ## On alloc failure: sm_connect_ind(0,0).
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  if connInfo == nil: return
  let ci = connectInfoView(connInfo)
  let vifIdx = ci.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  inc nimFwDbgAssocReqSend

  # Allocate TX frame via txl_frame_get(512) - NOT ke_msg_alloc
  let frame = txl_frame_get(512)
  if frame == nil:
    sm_connect_ind(0, 0)
    return
  let desc = hostTxDescAt(frame)

  # TPC update (blob: tpc_update_frame_tx_power at 0x5a)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  # Get STA entry for addresses
  let sta = staInfoForIdx(staIdx)
  let staMac = cast[pointer](addr sta.macAddr[0])

  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Clear frame control/duration fields (blob: sb zero,348-351)
  hdr.frameControl = 0
  hdr.duration = 0

  # Snapshot vif+80 (frame SA) + MAC HW addr regs for crypto MAC consistency check.
  for i in 0 ..< 6:
    nimFwDbgVifMac[i] = vif.macAddr[i]
  nimFwDbgMacHwLo = regRead(MACHW_BASE + 0x10'u)
  nimFwDbgMacHwHi = regRead(MACHW_BASE + 0x14'u)

  # DA from sta_info_tab+4 (blob: memcpy at 0x8e)
  discard c_memcpy(addr hdr.addr1[0], staMac, 6.csize_t)
  # SA from vifEntry+80 (blob: memcpy at 0xa0)
  discard c_memcpy(addr hdr.addr2[0], cast[pointer](addr vif.macAddr[0]), 6.csize_t)
  # BSSID from sta_info_tab+4 (blob: memcpy at 0xb0)
  discard c_memcpy(addr hdr.addr3[0], staMac, 6.csize_t)

  # Sequence control via txl_get_seq_ctrl (blob at 0xb8)
  let seqCtrl = txl_get_seq_ctrl()
  hdr.seqCtrl = seqCtrl

  # Store VIF/STA info
  desc.vifIdx = vifIdx
  desc.staInfoIdx = staIdx

  # Build association request body at the MAC-header body start. Blob passes:
  # a0=macHdr+372, a1=vif+348, a2=nil, a3=vif.inst_nbr, a4=&cursor,
  # a5=&bodyLen, a6=connect info.
  var assocCursor {.noinit.}: pointer
  var assocBodyLen {.noinit.}: uint16
  let assocBodyPtr = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  let assocInfo = cast[pointer](vifHtCapabilities(vif))
  let instNbr = vif.vifIdx
  let builtLen = me_build_associate_req_impl(
    assocBodyPtr,
    assocInfo,
    nil,
    cast[pointer](instNbr.uint),
    cast[pointer](addr assocCursor),
    cast[pointer](addr assocBodyLen),
    connInfo)

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
  let smEnvSecond = sm.connectIndMsg
  if smEnvSecond != nil:
    smConnectIndPayloadAt(smEnvSecond).assocReqIeLen = assocBodyLen
  let assocFixed = cast[ptr AssocReqFixedBodyView](assocBodyPtr)
  let assocTraceWord0 =
    assocFixed.capabilityInfo.uint32 or (assocFixed.listenInterval.uint32 shl 16)
  let assocTraceWord1 = cast[ptr uint32](addr assocFixed.reassocBssid[0])[]
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_len ", builtLen, assocBodyLen.uint32)
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_body ",
                 assocTraceWord0,
                 assocTraceWord1)
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_rates ",
                 cast[ptr uint32](addr vif.basicRates[0])[],
                 cast[ptr uint32](addr vif.basicRates[4])[])
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_len ", builtLen, assocBodyLen.uint32)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_body ",
                          assocTraceWord0,
                          assocTraceWord1)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_tx_rates ",
                          cast[ptr uint32](addr vif.basicRates[0])[],
                          cast[ptr uint32](addr vif.basicRates[4])[])
    nimFwConnectTraceHw("[WIFI-CT] assoc_hw ")

  when defined(bl808WifiUseBl808Rf):
    rfPriApplyWb03AuthTxLatches()
    rfPriCaptureWb03AuthTxPrePush()

  # Push frame to TX (blob: txl_frame_push(frame, 3))
  txl_frame_push(frame, 3)

  # Set timeout timer
  let tmo = if sm.connectFlags != 0: 0x1E000'u32 else: 0x7D000'u32
  ke_timer_set(SM_RSP_TIMEOUT_IND, TASK_SM, tmo)
  ke_state_set(TASK_SM, SmAuthenticatingState)

proc sm_assoc_req_send_pre*(param: pointer) {.exportc, cdecl.} =
  ## Pre-send association request.
  ## Blob (5 instrs):
  ##   li a0, 7         ; nextState = 7 (SM_ASSOC_REQ_WAIT_RSP / internal)
  ##   li a1, 0         ; param1 = 0
  ##   li a2, 0         ; param2 = 0
  ##   tail-call sm_auth_assoc_send_according_chan
  sm_auth_assoc_send_according_chan(SmAssociatingState, 0'u16, 0'u32)

proc sm_assoc_done*(aid: uint16) {.exportc, cdecl.} =
  ## Handle association completion.
  ## From blob (37 instrs): allocates MM_SET_VIF_STATE_REQ (size 4),
  ## fills status (param as uint16), VIF state = 1 (active), inst_nbr from
  ## connInfo+59, sends the message. Sets SM state to SM_ACTIVATING_STATE (9),
  ## clears sm_env[36], then tail-calls ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM).
  inc nimFwDbgAssocDone
  let sm = smEnvView()
  # Mark this VIF as "WPA pending" if the connection target requires WPA.
  # Read connInfo before any reuse; the connect-info struct lives at sm_env[0].
  block markWpaPending:
    let connInfo0 = sm.connectInfo
    if connInfo0 == nil: break markWpaPending
    let vifIdx0 = connectInfoView(connInfo0).vifIdx
    if vifIdx0 >= 8: break markWpaPending
    let secType = vifSecurity(vifChannelForIdx(vifIdx0)).cipher
    if secType >= 2'u8:
      nimFwWpaPendingMask = nimFwWpaPendingMask or (1'u32 shl vifIdx0)
  let connInfo = sm.connectInfo
  let ci = connectInfoView(connInfo)

  # Allocate MM_SET_VIF_STATE_REQ: ke_msg_alloc(24, TASK_MM=0, TASK_SM=4, 4)
  let msg = cast[ptr MmSetVifStateReqPayload](
    ke_msg_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_SM,
                 MmSetVifStateReqPayloadSize))
  if msg != nil:
    msg.aid = aid
    msg.state = 1
    msg.vifIdx = ci.vifIdx
    ke_msg_send(msg)

  # Set SM state to ACTIVATING (9)
  ke_state_set(TASK_SM, SM_ACTIVATING_STATE)

  sm.saQueryActive = 0

  # Clear the SA query timeout timer
  ke_timer_clear(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_auth_handler(void*);".}
proc sm_auth_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle received authentication frame.
  ##
  ## From blob disassembly (201 instructions):
  ## param = auth frame descriptor with:
  ##   offset 0:   uint16 - total frame length
  ##   offset 32:  uint16 - auth algorithm number (LE)
  ##   offset 34:  uint16 - auth transaction sequence (LE)
  ##   offset 36:  uint16 - status code (LE)
  ##   offset 38+: IE body (challenge text etc.)
  ##
  ## s3 -> sm_env, s2 = param + 32.
  ## The function dispatches on status_code and auth_algo to:
  ## - SAE (algo==3): call wpa_cbs SAE handler
  ## - Open (algo==0): proceed to association
  ## - Shared Key (algo==1): handle challenge text
  ## On success, sends SM_CONNECT_AUTH_ASSOC_REQ_MSG and tail-calls
  ## sm_assoc_req_send_pre. On failure, logs via g_bl_ops_funcs[204].
  let frame = smAuthFrameView(param)
  let smConnInfo = smEnvView().connectInfo

  let statusCode = frame.statusCode
  inc nimFwDbgAuthHandler
  nimFwDbgAuthHandlerLast =
    frame.authAlgo.uint32 or (frame.authSeq.uint32 shl 16) or
      (statusCode.uint32 shl 24)
  when defined(bl808WifiConnectTrace):
    let authAlgoDbg = frame.authAlgo
    let authSeqDbg = frame.authSeq
    nimFwConnectTrace2U32("[WIFI-CT] auth_rx ",
                          authAlgoDbg.uint32 or (authSeqDbg.uint32 shl 16),
                          statusCode.uint32 or (ke_state_get(TASK_SM).uint32 shl 16))

  if statusCode != 0:
    # Auth failure path (blob offsets 0x5E-0x1D8)
    # Clear connection timeout timer (blob: ke_timer_clear at 0x6E)
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
    # Check if auth retry via SA query is possible
    if smConnInfo != nil:
      let ci = connectInfoView(smConnInfo)
      if ci.authType == 1 and ci.authRetryGate != 0:
        ci.authType = 0
        # Retry authentication (blob: sm_auth_send_pre at 0x8C)
        sm_auth_send_pre(1'u16, 0)
        return
    # Check if association is possible despite auth failure
    if frame.authAlgo == 0 and statusCode == 13:
      # Status 13: try association anyway (blob: sm_assoc_req_send_pre at 0xAA)
      sm_assoc_req_send_pre(param)
      return
    # Auth truly failed: clear timer, report connection failure
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)  # blob: ke_timer_clear at 0xF2
    sm_connect_ind(statusCode, WLAN_FW_AUTHENTICATION_FAIILURE.uint16)  # blob: 0x12A
    return

  # Status == 0: successful auth response
  let authAlgo = frame.authAlgo

  if authAlgo == 3:
    # SAE authentication
    let saeSeq = frame.authSeq
    let frameLen = frame.frameLen
    if wpa_cbs != nil:
      let wpaCbArr = cast[ptr UncheckedArray[pointer]](wpa_cbs)
      let saeHandler = wpaCbArr[15]  # offset 60
      if saeHandler != nil:
        let fn = cast[proc(body: pointer, bodyLen: uint16, seq: uint16, arg: pointer): int32 {.cdecl.}](saeHandler)
        let rc = fn(smAuthSaeBodyPtr(frame), frameLen - 6, saeSeq, nil)
        if rc == 0:
          # Blob at 0x6e: just clear SM rsp-timeout timer. Previous Nim also
          # allocated + sent an SM_CONNECT_AUTH_ASSOC_REQ msg here — blob
          # never issues that from this path; the auth/assoc req is enqueued
          # downstream via sm_auth_send_pre / sm_assoc_req_send_pre below.
          ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
          if saeSeq == 1:
            sm_auth_send_pre((saeSeq + 1).uint16, 0)
          elif saeSeq == 2:
            if smConnInfo != nil:
              connectInfoAuthRetry(smConnInfo)[] = 0
            sm_assoc_req_send_pre(param)
          return
        elif rc == -8:
          let lf = getLogFunc(204)
          if lf != nil:
            cast[proc(a, b: uint32, c: pointer, d, e: uint32){.cdecl.}](lf)(3, 0, nil, 1302, saeSeq.uint32)
          return
      else:
          let lf = getLogFunc(204)
          if lf != nil:
            cast[proc(a, b: uint32, c: pointer, d, e: uint32){.cdecl.}](lf)(3, 0, nil, 1307, saeSeq.uint32)
          sm_assoc_req_send_pre(param)
          return
    return
  else:
    # Open System or Shared Key
    # Clear connection timeout timer (blob: ke_timer_clear at 0x138, 0x1D0)
    ke_timer_clear(SM_RSP_TIMEOUT_IND, TASK_SM)
    if authAlgo == 0:
      # Open System: clear auth state, proceed to association
      if smConnInfo != nil:
        connectInfoAuthRetry(smConnInfo)[] = 0
      inc nimFwDbgAuthOpenSuccess
      sm_assoc_req_send_pre(param)
      return
    if authAlgo == 1:
      let sharedSeq = frame.authSeq
      if sharedSeq == 4:
        # Shared Key seq 4: auth complete, proceed to association
        if smConnInfo != nil:
          connectInfoAuthRetry(smConnInfo)[] = 0
        sm_assoc_req_send_pre(param)
        return
      elif sharedSeq == 2:
        # Shared Key seq 2: challenge text, restart auth
        let frameLen = frame.frameLen
        if frameLen > 135:
          # Restart authentication with challenge (blob: sm_auth_start at 0x21C)
          sm_auth_start(smAuthSharedChallengePtr(frame))
          return
        else:
          let lf = getLogFunc(204)
          if lf != nil:
            cast[proc(a, b: uint32, c: pointer, d, e: uint32){.cdecl.}](lf)(3, 0, nil, 1338, 0)
          return
      else:
        # Blob at 0x19a: sm_connect_ind(3, 0) for unrecognized shared-key seq,
        # then assert_warn("sm.c", 1343).
        sm_connect_ind(3, 0)
        assert_warn("sm.c", "sm.c", 1343)
        return

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_assoc_rsp_handler(void*);".}
proc sm_assoc_rsp_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle received association response frame.
  ## From blob (141 instrs): parses association response, extracts status code
  ## and AID, checks for HT/VHT IE, sends ME_STA_ADD_REQ if successful,
  ## or reports failure to host.
  ##
  ## param layout: offset 0 = uint16 frame_len, offset 32 = frame body start
  ## Frame body: offset 2..3 = status code, offset 4..5 = AID,
  ##   offset 6+ = IEs (including HT cap, vendor-specific)
  let sm = smEnvView()
  let connInfo = sm.connectInfo
  let ci = connectInfoView(connInfo)

  let vifIdx = ci.vifIdx
  let vif = vifChannelForIdx(vifIdx)

  # Read sm_env secondary struct
  let smEnvSecond = sm.connectIndMsg

  let frame = smAssocRspFrameView(param)
  let frameLen = frame.frameLen
  let frameBody = smAssocRspBodyPtr(frame)
  let assocBody = smAssocRspIePtr(frame)

  # Blob entry (0x56) clears the SM rsp-timeout timer FIRST, before
  # inspecting the status code. Previous Nim set ke_state_set(SM, 4) at
  # the entry, which blob does not do — the state transition happens
  # elsewhere (sm_auth_handler / sm_assoc_req_send).
  let smTimerIdEarly = SM_RSP_TIMEOUT_IND
  ke_timer_clear(smTimerIdEarly, TASK_SM)

  let statusCode = frame.statusCode
  inc nimFwDbgAssocRspCount
  nimFwDbgAssocRspStatus = statusCode.uint32
  nimFwDbgAssocRspLen = frameLen.uint32
  nimFwDbgAssocRspBody0 = cast[ptr uint32](frameBody)[]
  nimFwDbgAssocRspBody4 = cast[ptr uint32](addr frame.aid)[]
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_status ", frameLen.uint32, statusCode.uint32)
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_body ",
                          cast[ptr uint32](frameBody)[],
                          cast[ptr uint32](addr frame.aid)[])

  if statusCode != 0:
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_fail ",
                            statusCode.uint32,
                            cast[uint32](blOpsFunc(0)))
    # Association failed
    if statusCode == 30:
      # Status 30: blob .L187 searches for a vendor IE and programs a
      # retry timer. Previous Nim allocated a ME_STA_ADD_REQ message and
      # sent it — blob never does that here. Replace with blob's
      # ke_timer_set path.
      if frameLen > 6:
        let iePtr = mac_ie_find(assocBody, (frameLen - 6).uint32, 56)
        if iePtr != nil:
          let timeoutIe = timeoutIntervalIeAt(iePtr)
          if timeoutIe.ie.len == 5:
            if timeoutIe.intervalType == 3:
              # Clear SM connect info offset 60 and schedule the retry.
              connectInfoAuthRetry(connInfo)[] = 0
              let retry = timeoutIe.intervalValue
              let timerMs = ((retry[2].uint32 shl 16) or
                             (retry[1].uint32 shl 8) or
                             retry[0].uint32) shl 10
              ke_timer_set(smTimerIdEarly, TASK_SM, timerMs.uint16)
              return
    # Report failure: status code != 0.  The blob uses the printf-style slot
    # at g_bl_ops_funcs+4 here; slot 0 can contain a small mode flag in this
    # harness and jumping through it faults before sm_connect_ind runs.
    let logFn = blOpsFunc(4)
    if cast[uint](logFn) > 0x1000'u:
      cast[proc(a0: pointer, a1: uint16){.cdecl.}](logFn)(nil, statusCode)
    # Send failure indication
    sm_connect_ind(5, statusCode)
    return

  # Association successful (status == 0) — timer already cleared above.

  let aid = frame.aid and 0x3FFF'u16
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_aid ", aid.uint32,
                          connectInfoAuthRetry(connInfo)[].uint32)

  # Store association response IE diagnostics in the connect indication.
  # Layout: +16 assoc_req_ie_len, +18 assoc_rsp_ie_len, +20 assoc IE buffer.
  # The blob copies response IEs after the request IEs; it does not synthesize
  # the later AID field here.
  if smEnvSecond != nil:
    let ind = smConnectIndPayloadAt(smEnvSecond)
    let rspIeLen = if frameLen > 6: frameLen - 6 else: 0'u16
    let reqIeLen = ind.assocReqIeLen
    ind.assocRspIeLen = rspIeLen
    if rspIeLen != 0 and reqIeLen.uint + rspIeLen.uint <= 800'u:
      discard c_memcpy(addr ind.assocIeBuffer[reqIeLen.int],
                       assocBody,
                       rspIeLen.csize_t)

  # Blob: sm_assoc_done — mark association complete (offset 0xB6)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_done ", vifIdx.uint32,
                          pointerAddrU32(cast[pointer](vif)))
  sm_assoc_done(aid)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_after_done ", ke_state_get(TASK_SM).uint32,
                          connectInfoAuthRetry(connInfo)[].uint32)

  # Blob: me_init_rate — initialize rate control for the associated STA
  # recorded in the VIF entry.
  let staIdx = vif.staIdx
  let staEntry = cast[pointer](staInfoForIdx(staIdx))
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_rate ", staIdx.uint32,
                          pointerAddrU32(staEntry))
  me_init_rate(staEntry)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_after_rate ", staIdx.uint32,
                          vif.staIdx.uint32)

  # Blob: tpc_update_vif_tx_power — update TX power after association (offset 0xFA)
  let chanPtr = vif.operChan
  if chanPtr != nil:
    let chan = cast[ptr ScanChannelEntry](chanPtr)
    var tpcPower: uint8 = cast[ptr uint8](addr chan.txPower)[]
    var tpcRate: uint8
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_before_tpc ", cast[uint32](cast[uint](chanPtr)),
                            tpcPower.uint32)
    tpc_update_vif_tx_power(cast[pointer](vif), cast[pointer](addr tpcPower), cast[pointer](addr tpcRate))
    when defined(bl808WifiConnectTrace):
      nimFwConnectTrace2U32("[WIFI-CT] assoc_rsp_after_tpc ", tpcPower.uint32, tpcRate.uint32)

  # Blob success path (.L186) does NOT call mac_ie_find or ke_timer_set —
  # those only fire from the status==30 branch above. The "HT capability"
  # search previously reproduced here was a phantom call, as was the
  # 5-second follow-up timer (blob only arms the retry timer inside the
  # status==30 path).

  # Check WPS callback
  if sm.state == 2:
    # WPS mode: check wps_cbs
    let wpsCbs = wps_cbs
    if wpsCbs != nil:
      # Call wps callback offset 12
      let wpsStaAddCb = wpsCallbacks().staAddConfirm
      if wpsStaAddCb != nil:
        cast[proc(){.cdecl.}](wpsStaAddCb)()

proc sm_deauth_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle deauthentication frame (140 instrs). Validates BSSID/SA,
  ## extracts reason code, dispatches based on SM state.
  ## Returns result via a0: 0=handled/ignored, 2=state mismatch.
  inc nimFwDbgDeauthHandler
  let deauth = smDeauthFrameView(param)
  let vifIdx = deauth.vifIdx
  let sm = smEnvView()
  let vif = vifChannelForIdx(vifIdx)

  # Validate BSSID: param[48..53] vs vif.bssid.
  for i in 0 ..< 6:
    if deauth.bssid[i] != vif.bssid[i]:
      # BSSID mismatch - blob logs debug with line 1503 and returns 0
      return

  # Validate SA: if multicast bit (bit 0 of first SA byte) clear, compare SA
  if (deauth.sa[0] and 1) == 0:
    for i in 0 ..< 6:
      if deauth.sa[i] != vif.macAddr[i]:
        # SA mismatch - blob logs debug with line 1507 and returns 0
        return

  # Extract reason code (LE u16 at param+56..57)
  let reason = deauth.reason

  # Load connect-info pointer from sm_env[0]
  let connInfoPtr = sm.connectInfo

  # Check SM state - first call
  let st = ke_state_get(TASK_SM)
  if st == SmDisconnectingState:
    # SM already disconnecting - return 2
    smConnecting = false  # blob: s3=2 -> return
    return

  # Check SM state - second call
  let st2 = ke_state_get(TASK_SM)
  if st2 != SmIdleState:
    # SM in an active state other than disconnecting:
    # Check if connect-info vifIdx matches param vifIdx
    if connInfoPtr != nil:
      let connVifIdx = connectInfoView(connInfoPtr).vifIdx
      if connVifIdx != vifIdx:
        # VIF mismatch - return 2
        smConnecting = false
        return
    # VIF matches: send connect indication with status=6 (deauth by AP)
    sm_connect_ind(6, reason)
    return

  # state == 0 (idle): check VIF connection flag at vif[88]
  let vifConn = vif.state
  if vifConn == 0:
    return  # not connected, ignore

  # Check param[27] bit 0 for protected frame
  if (deauth.frameFlags and 1) != 0:
    # Protected frame: check PMF flag at sm_env[36]
    if sm.saQueryActive != 0:
      # PMF already active: just ignore (blob returns 0 via .L208)
      return

    # PMF not active: store deauth info and initiate SA query
    # blob: sh 0x201 -> sm_env[36], sb param[7] -> sm_env[38], sh reason -> sm_env[42]
    sm.saQueryActive = 1
    sm.saQueryRetryCount = 2
    sm.saQueryVifIdx = deauth.saQueryVifIdx
    sm.saQueryReason = reason
    # Initiate SA query (blob: sm_issue_sa_query_request at 0x18E)
    sm_issue_sa_query_request()
  else:
    # Unprotected deauth (.L217):
    # 1. Set SM state to disconnecting.
    ke_state_set(TASK_SM, SmDisconnectingState)
    # 2. Log via g_bl_ops_funcs[1] (blob at 0x1A4-0x1B6)
    let logFn = blOpsFunc(4)
    if logFn != nil:
      cast[PlatformLogFunc](logFn)(3, 0, nil, 0, reason.uint32, 0, 0)
    # 3. Call sm_disconnect_process(vifEntry, 7, reason)
    sm_disconnect_process(cast[pointer](vif), 7, reason)

proc sm_get_set_machwkey_index*(getFlag: uint32, vifIdx: uint32, keyBuf: pointer, keyType: uint32): uint8 {.exportc, cdecl, noinline.} =
  ## Get/set MAC HW key index for SM.
  ## From blob (32 instrs): a0=getFlag (0=set, nonzero=get), a1=vifIdx,
  ## a2=keyBuf pointer, a3=keyType (0/1/2 = different key offsets within VIF entry).
  ##
  ## For each keyType (0, 1, 2), a different offset within vif_info_tab is accessed.
  ## The exact offsets depend on relocations in the blob; from VIF entry layout they
  ## correspond to pairwise/group/management key indices.
  ## If vifIdx > 1, returns 0xFF (-1). If keyType > 2, returns 0xFF.
  ## getFlag=0: writes keyBuf[0] to vif[offset]; nonzero: reads vif[offset] into keyBuf[0].
  ## Returns 0 on success.
  ## noinline + asm barrier: blob calls this as a real function from
  ## bl_wifi_get_sta_gtk and bl_wifi_set_igtk_internal; without noinline GCC
  ## inlines the short table lookup.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  if vifIdx > 1:
    return 0xFF'u8

  let vif = vifChannelForIdx(vifIdx.uint8)
  let indexes = vifMachwKeyIndexes(vif)

  var keyAddr: ptr uint8
  case keyType
  of 0: keyAddr = addr indexes.primaryPairwise
  of 1: keyAddr = addr indexes.secondaryPairwise
  of 2: keyAddr = addr indexes.group
  else: return 0xFF'u8

  if getFlag == 0:
    # SET: write from keyBuf to vif entry
    keyAddr[] = cast[ptr uint8](keyBuf)[]
  else:
    # GET: read from vif entry to keyBuf
    cast[ptr uint8](keyBuf)[] = keyAddr[]

  return 0'u8

proc sm_handle_eapol_input*(staIdx: uint8, srcAddr: pointer, eapolBuf: pointer,
    eapolLen: uint32) {.exportc, cdecl.} =
  ## Handle EAPOL frame input (51 instrs).
  ## From blob: a0 = STA idx, a1 = source MAC, a2 = EAPOL buffer, a3 = length.
  ## Computes STA entry = sta_info_tab + staIdx * 368.
  ## Computes VIF entry = vif_info_tab + vifIdx * 1512 (vifIdx from sta[39]).
  ## Checks VIF+488 (WPA state flag). If zero, returns.
  ## Checks sm_env[44] (connection state): if == 2 (WPS mode), loads wps_cbs
  ## and calls wps_cbs[4] (WPS EAPOL handler). Otherwise checks ke_state_get(4).
  ## If state == 9 (SM_ACTIVATING), loads wpa_cbs[20] (WPA EAPOL handler).
  ## If state == 0, allocates ke_msg SM_CONNECT_AUTH_ASSOC_REQ with EAPOL data.
  inc nimFwDbgEapolIn
  let vifIdxFromSta = staInfoForIdx(staIdx).instNbr
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
        cast[proc(src: pointer, buf: pointer, len: uint32) {.cdecl.}](wpsHandler)(
          srcAddr, eapolBuf, eapolLen)
    return
  # Normal mode: check SM task state
  let smState = ke_state_get(TASK_SM)
  nimFwDbgSmStateAtEapol = smState.uint32
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] sm_eapol ", staIdx.uint32 or (smState.uint32 shl 8), eapolLen)
  if smState == SM_ACTIVATING_STATE:
    # In activating state: forward to WPA supplicant
    if wpa_cbs != nil:
      let wpaHandler = wpaCallbacks().eapolHandler
      if cast[uint](wpaHandler) > 0x1000'u:
        inc nimFwDbgEapolCbInv
        cast[proc(src: pointer, buf: pointer, len: uint32) {.cdecl.}](wpaHandler)(
          srcAddr, eapolBuf, eapolLen)
      else:
        inc nimFwDbgEapolCbNull
    else:
      inc nimFwDbgEapolCbNull
  elif smState == SmIdleState:
    # Idle: may need to start auth/assoc
    discard

{.emit: "__attribute__((optimize(\"crossjumping\"))) void sm_handle_supplicant_result(unsigned char,unsigned char);".}
proc sm_handle_supplicant_result*(result_code: uint8, reason: uint8) {.exportc, cdecl.} =
  ## Handle WPA supplicant result (133 instrs).
  ## a0=result_code, a1=reason.
  ## From blob: loads sta_info_tab, checks ke_state_get(4)==10 for SM task state.
  ## If state==10 (SM_ACTIVATING), returns immediately.
  ## If reason==0: sets sta[72]=2 (failed) and tail-calls sm_connect_ind(0,0).
  ## If reason==15: calls g_bl_ops_funcs log, then falls through.
  ## Otherwise: transitions SM state to disconnecting, allocates TX frame via txl_frame_get(512),
  ## builds deauth frame with VIF info, calls me_build_deauthenticate, then
  ## txl_frame_push to transmit. On failure, calls sm_connect_ind(9/10, reason).
  let sta = staInfoForIdx(result_code)

  # Check SM task state
  let smState = ke_state_get(TASK_SM)
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] supp_result ",
                          result_code.uint32 or (reason.uint32 shl 8),
                          smState.uint32)
  if smState == SmDisconnectingState:
    return  # Already disconnecting

  if reason == 0:
    # Supplicant failed with reason=0: check if already failed
    let curStatus = sta.rxNss
    if curStatus == 2:
      return  # already marked failed
    sta.rxNss = 2
    sm_connect_ind(0, 0)
    return

  if reason == 15:
    # Timeout: call platform log function if available
    let logFn = blOpsFunc(4)
    if logFn != nil:
      cast[proc(a: uint32, b: uint32, c: cstring, d: uint32) {.cdecl.}](logFn)(
        3, 0, "sm.c", 1717)

  # Transition SM state to disconnecting.
  ke_state_set(TASK_SM, SmDisconnectingState)

  # Allocate TX frame for deauth (512 bytes)
  let frame = txl_frame_get(512)
  if frame == nil:
    # Allocation failed: signal error via sm_connect_ind
    sm_connect_ind(10, reason.uint16)
    return

  let vifIdx = sta.instNbr
  let vif = vifChannelForIdx(vifIdx)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)

  let desc = hostTxDescAt(frame)
  if desc.bufDesc == nil:
    sm_connect_ind(10, reason.uint16)
    return
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

  # Register TX-completion callback. Blob: `addi a5, s1, 128; sw &cfm, 80(a5);
  # sw vif, 84(a5)` — i.e. frame+208 = &sm_supplicant_deauth_cfm,
  # frame+212 = &vif_entry.
  desc.callback = cast[pointer](sm_supplicant_deauth_cfm)
  desc.callbackArg = cast[pointer](vif)
  desc.vifIdx = vifIdx
  desc.staInfoIdx = result_code

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

  # Push frame for TX (tail call in blob)
  txl_frame_push(frame, 3)

proc sm_send_sa_query*(vifIdx: uint8, transId: uint16, isTx: uint8) {.exportc, cdecl.} =
  ## Send SA Query frame for PMF (104 instrs).
  ## Builds an SA Query action frame and sends it via txl_frame_push.
  ## a0=vifIdx, a1=transId, a2=isTx (0=request, 1=response).
  ##
  ## Assembly trace:
  ##   s2 = sta_info_tab base, computes STA entry via vifIdx*368
  ##   s7 = sta[39] (format mod)
  ##   s5 = vif_info_tab base, computes VIF entry via vifIdx*1512
  ##   Allocates frame via txl_frame_get(512, ...)
  ##   Builds MAC header: FC=0xD0 (action), addresses from STA/VIF
  ##   Body: category=8 (SA Query), action=0/1, transId
  ##   Updates frame lengths and pushes via txl_frame_push(desc, 3)
  let sta = staInfoForIdx(vifIdx)
  let vif = vifChannelForIdx(vifIdx)
  let staFormatMod = sta.instNbr
  # Allocate frame (512 bytes payload capacity)
  let frame = txl_frame_get(512)
  if frame == nil:
    return
  let desc = hostTxDescAt(frame)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)
  # Frame Control: 0xD0 = management, action frame
  hdr.frameControl = 0x00D0'u16
  hdr.duration = 0
  # Addr1 (RA) = STA MAC (BSSID)
  discard c_memcpy(addr hdr.addr1[0], addr sta.macAddr[0], 6.csize_t)
  # Addr2 (SA) = VIF MAC
  discard c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)
  # Addr3 (BSSID) = STA MAC
  discard c_memcpy(addr hdr.addr3[0], addr sta.macAddr[0], 6.csize_t)
  # Generate sequence number (blob: txl_get_seq_ctrl)
  let seqCtrl = txl_get_seq_ctrl()
  hdr.seqCtrl = seqCtrl
  # SA Query body at linkDesc+348+24 = linkAddr+372
  # The body offset depends on frame header: 24-byte header for non-QoS mgmt
  let bodyOff = desc.hdrLen  # header length
  let body = saQueryActionBodyAt(addr link.macHeader[bodyOff])
  # Category = 8 (SA Query)
  body.category = 8
  # Action = isTx (0=request, 1=response)
  body.action = isTx
  # Transaction ID (2 bytes)
  body.transId = transId
  # Update frame lengths
  let totalHdrLen = bodyOff.uint32
  let bodyLen = 4'u32  # category + action + transId(2)
  let thd = hostTxHwDescAt(desc.hwDesc)
  let oldLen = thd.payloadStart
  thd.payloadEnd = oldLen + totalHdrLen + bodyLen + 3
  thd.frameLen = totalHdrLen + bodyLen + 8
  # Store metadata in descriptor
  desc.vifIdx = staFormatMod
  desc.staInfoIdx = vifIdx
  desc.hdrLen = 0  # clear
  desc.secTailLen = 0  # clear
  # Apply mgmt frame protection (blob: txu_cntrl_protect_mgmt_frame)
  txu_cntrl_protect_mgmt_frame(frame, cast[pointer](hdr), 0)
  # Apply TX power control (blob: tpc_update_frame_tx_power)
  tpc_update_frame_tx_power(cast[pointer](vif), frame)
  # Push frame for TX on AC 3 (VO)
  txl_frame_push(frame, 3)

proc sm_sa_query_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle SA Query response/request (52 instrs).
  ## From blob: a0 = ke_msg payload. Reads VIF idx from param[8].
  ## Computes VIF entry = vif_info_tab + vifIdx * 1512.
  ## Checks VIF+88 (active flag) and VIF+86 (type != 2, not monitor).
  ## Reads STA idx from param[7]; if 0xFF returns.
  ## Checks STA entry[60] (assoc state) == APM_STA_ASSOCIATED.
  ## Loads STA+48 (connection info); checks MFP state.
  ## Reads SA Query action from param: action=0 is request, action=1 is response.
  ## For request: calls sm_send_sa_query(vifIdx, transId, 1) to send response.
  ## For response: checks transId matches pending query; if so, clears SA query
  ## timer and resets state.
  let frame = smSaQueryFrameView(param)
  let vifIdx = frame.vifIdx
  let vif = vifChannelForIdx(vifIdx)
  # Check VIF active
  let active = vif.state
  if active == 0:
    return
  let vifType = vif.vifType
  if vifType == 2:
    return  # monitor mode, ignore
  let staIdx = frame.staIdx
  if staIdx == 0xFF:
    return
  # Check STA association state
  let assocState = staInfoForIdx(staIdx).rxNss
  if assocState != 2:
    return  # not associated
  # Read SA query frame fields from param
  let action = frame.action  # SA query action (0=req, 1=resp)
  let transId = frame.transId
  if action == 0:
    # SA Query Request received: send response
    sm_send_sa_query(vifIdx, transId, 1)
  elif action == 1:
    # SA Query Response received: validate against pending query
    let sm = smEnvView()
    if sm.saQueryActive == 0:
      return
    let pendingTransId = sm.saQueryTransId
    if transId == pendingTransId:
      # Match: clear SA query state, cancel timer (blob: ke_timer_clear)
      sm.saQueryActive = 0
      let saTimerId = KE_FIRST_MSG(TASK_SM.uint16) + 10  # SM_SA_QUERY_TIMEOUT_IND
      ke_timer_clear(saTimerId, TASK_SM)

proc sm_issue_sa_query_request*() {.exportc, cdecl.} =
  ## Issue SA Query request to AP (28 instrs).
  ## From blob: generates random transaction ID via LCG PRNG (rc_prng),
  ## stores lower 16 bits as pending transId in sm_env+40.
  ## Reads VIF idx from sm_env+38. Calls sm_send_sa_query(vifIdx, transId, 0).
  ## Starts SA query timeout timer: ke_timer_set(SM_SA_QUERY_TIMEOUT_IND,
  ## TASK_SM, 4, 100000) for ~100ms timeout.
  let sm = smEnvView()
  # Generate random transaction ID using LCG PRNG
  let rng = rcPrngNext()
  let transId = (rng shr 16).uint16
  sm.saQueryTransId = transId
  # Read VIF index
  let vifIdx = sm.saQueryVifIdx
  # Send SA Query request
  sm_send_sa_query(vifIdx, transId, 0)
  # Start SA query timeout timer via ke_timer_set
  # From blob: calls ke_timer_set(SM_SA_QUERY_TIMEOUT_IND, TASK_SM, 100000)
  # which schedules a kernel-task message event ~100ms in the future.
  ke_timer_set(SM_SA_QUERY_TIMEOUT_IND_MSG, TASK_SM, 100000'u32)

proc sm_set_channel_coex_connected*(channel: uint8) {.exportc, cdecl.} =
  ## Set channel coexistence info after connection (10 instrs).
  ## From blob: loads primary freq from sm_env+32, center freq from sm_env+34,
  ## then applies the PHY channel descriptor for the STA channel.
  let sm = smEnvView()
  phySetChannel(0, 0, sm.primaryFreq, sm.centerFreq, 0, 0)

proc sm_connection_tlv_set*(id: uint8, data: pointer, len: uint16) {.exportc, cdecl, noinline.} =
  ## Set a TLV in the connection data chain.
  ## noinline: blob calls this from mm_connection_loss_ind_handler; empty body
  ## would otherwise be elided.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  discard

proc sm_connection_tlv_reset*() {.exportc, cdecl.} =
  ## Reset all connection TLV data.
  discard

proc sm_connection_tlv_pack*(param: pointer) {.exportc, cdecl.} =
  ## Pack connection TLV data into a buffer (2 instrs).
  ## From blob: li a0,0; ret -- returns 0 (no TLV data to pack).
  ## Blob always returns 0; no TLV packing is implemented.
  {.emit: ["asm volatile(\"li a0, 0\");"].}

proc sm_connection_tlv_desc_get*(): pointer {.exportc, cdecl.} =
  ## Get the connection TLV descriptor list.
  return nil

proc sm_connect_wap_tlv_pack_cb*(param: pointer) {.exportc, cdecl.} =
  ## Callback for WPA TLV packing during connection.
  discard

proc sm_connection_sta_add_ind*(param: pointer) {.exportc, cdecl.} =
  ## Indicate STA addition during connection (37 instrs).
  ## From blob: loads sm_env pointer (sm_env[0]). Allocates ke_msg with
  ## id=SM_STA_ADD_IND (0x100A), dest=TASK_API(9), src=TASK_SM(4), paramLen=3.
  ## Copies VIF index from sm_env+59 to msg[0], VIF's STA index to msg[1],
  ## and VIF+484 bit 0 (WPA flag) to msg[2]. Tail-calls ke_msg_send.
  let connInfo = smEnvView().connectInfo
  if connInfo == nil:
    return
  let ci = connectInfoView(connInfo)
  # Allocate SM_STA_ADD_IND message
  let msg = cast[ptr SmStaAddIndPayload](
    ke_msg_alloc(SM_STA_ADD_IND, TASK_API, TASK_SM,
                 SmStaAddIndPayloadSize))
  if msg == nil:
    return
  # Copy VIF index from sm_env connection info
  let vifIdx = ci.vifIdx
  msg.vifIdx = vifIdx
  # Get VIF entry and copy the associated STA index
  let vif = vifChannelForIdx(vifIdx)
  let staIdx = vif.staIdx
  msg.staIdx = staIdx
  # Copy WPA flag (VIF+484 bit 0)
  let wpaFlags = vifApConfig(vif).securityFlags
  msg.wpa = (wpaFlags and 1).uint8
  when defined(bl808WifiConnectTrace):
    nimFwConnectTrace2U32("[WIFI-CT] sta_add_ind ",
                          vifIdx.uint32 or (staIdx.uint32 shl 8) or
                            ((wpaFlags and 1).uint32 shl 16),
                          vifSecurity(vif).connected.uint32)
  ke_msg_send(msg)

proc sm_connect_auth_assoc_req() {.exportc, cdecl.} =
  ## Send pending auth or assoc during connection (32 instrs).
  ## From blob: a0 = ke_msg header, a1 = ke_msg payload.
  ## Reads payload[0] (msg_id halfword). If msg_id == 5 (SM_AUTH_STATE),
  ## checks ke_state_get(4) == 5; if match, reads payload[2] (freq) and
  ## payload[4] (param ptr), calls sm_auth_send(freq, paramPtr).
  ## If msg_id == 7, checks ke_state_get(4) == 7; if match, calls
  ## sm_assoc_req_send. Otherwise returns 0.
  ## Call graph: ke_state_get, sm_auth_send, sm_assoc_req_send
  var payload: pointer
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", payload, ") );"].}
  if payload == nil:
    return
  let msg = cast[ptr SmConnectAuthAssocReqPayload](payload)
  let msgId = msg.nextState
  if msgId == 5:
    let smState = ke_state_get(TASK_SM)
    if smState != SmAuthStartingState:
      return
    # Blob: lhu a0,2(s0); lw a1,4(s0); call sm_auth_send
    # a0 = payload[2] (authSeqNum), a1 = payload[4] (statusCode via hidden arg)
    sm_auth_send(msg.param1, msg.param2)
  elif msgId == 7:
    let smState = ke_state_get(TASK_SM)
    if smState != SmAssociatingState:
      return
    sm_assoc_req_send(payload)

# ###########################################################################
#                   APM: AP Management
# ###########################################################################

proc apm_init*() {.exportc, cdecl.} =
  ## Initialize AP management module (20 instrs).
  ## From blob: memset(apm_env, 0, 176), then sets:
  ##   apm_env[12] = 0 (already zero from memset)
  ##   apm_env[88] = 4 (max STA count default)
  ##   apm_env[87] = 0 (STA counter)
  ## Then tail-calls ke_state_set(TASK_APM=5, 0).
  let apm = apmEnvView()
  discard c_memset(apm, 0, sizeof(ApmEnvView).csize_t)  # clear full 176-byte env
  apm.maxSta = 4
  apm.staCount = 0
  ke_state_set(TASK_APM, ApmIdleState)

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
  let apInfo = apmStartInfoView(connInfo)

  # Allocate APM_START_CFM message (4 bytes)
  let msg = cast[ptr ApmStartCfmPayload](
    ke_msg_alloc(APM_START_CFM, TASK_API, TASK_APM,
                 ApmStartCfmPayloadSize))
  if msg == nil:
    return

  if status == 0:
    # --- Success path ---
    let vifIdx = apInfo.vifIdx
    let vif = vifChannelForIdx(vifIdx)
    let selfStaIdx = vifIdx + 5  # Self-STA index = vifIdx + NX_REMOTE_STA_MAX

    # 1. Send MM_SET_VIF_STATE_REQ to activate VIF
    let msg2 = cast[ptr MmSetVifStateReqPayload](
      ke_msg_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_APM,
                   MmSetVifStateReqPayloadSize))
    if msg2 != nil:
      msg2.state = 1
      msg2.vifIdx = vif.vifIdx
      ke_msg_send(msg2)

    # 2. Copy beacon-related fields from connect info to VIF entry
    vifKeyPointers(vif).flags = apInfo.beaconRateInfo
    vif.psBaCounter = 0
    vif.apStartBeaconInterval = apInfo.vifBeaconInterval

    # 3. Read band from channel context and store in APM_START_CFM msg
    let chanPtr = vif.chanCtxt
    if chanPtr != nil:
      msg.band = chanCtxtAt(chanPtr).idx

    # 4. Log via g_bl_ops_funcs[204]
    let logFn = getLogFunc(204)
    if logFn != nil:
      logFn(2, 0, nil, 94, 0)

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

    # Set self-STA flags
    selfStaStart.rcFlags = selfStaStart.rcFlags or 0x10
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
    logFn2(1, 0, nil, 120, 0)

  # Start connection timeout timer (5 seconds = 5,000,000 MAC ticks)
  ke_timer_set(APM_STA_CONNECT_TIMEOUT_IND, TASK_APM, 5000000)

  # Send the APM_START_CFM message
  ke_msg_send(msg)

  # Free the connect info payload's message header.
  ke_msg_free(keMsgHdrFromPayload(connInfo))

  # Clear connect info pointer in apm_env
  apm.connectInfo = nil

  # Reset APM state to idle
  ke_state_set(TASK_APM, ApmIdleState)

proc apm_stop*(vifEntry: pointer) {.exportc, cdecl.} =
  ## Stop AP mode for the given VIF entry.
  ## From blob (72 instrs): allocates ME_SET_PS_DISABLE_REQ and ME_SET_ACTIVE_REQ
  ## messages, logs the stop event, sends PS disable, optionally sends
  ## MM_SET_VIF_STATE_REQ if STAs are connected, unlinks channel context if
  ## present, sends ME_SET_ACTIVE_REQ (deactivate), then tail-calls ke_msg_send.
  let vif = vifChannelAt(vifEntry)
  let instNbr = vif.vifIdx

  # 1. Allocate ME_SET_PS_DISABLE_REQ: ke_msg_alloc(0xC0F, TASK_ME, TASK_APM, 2)
  let msg1 = ke_msg_alloc(ME_SET_PS_DISABLE_REQ, TASK_ME, TASK_APM,
                          MeSetPsDisableReqPayloadSize)

  # 2. Allocate ME_SET_ACTIVE_REQ: ke_msg_alloc(0xC0D, TASK_ME, TASK_APM, 2)
  let msg2 = ke_msg_alloc(ME_SET_ACTIVE_REQ, TASK_ME, TASK_APM,
                          MeSetActiveReqPayloadSize)

  # 3. Log the stop event via g_bl_ops_funcs
  let logFn = getLogFunc(204)
  if logFn != nil:
    logFn(1, 0, nil, 234, 0)

  # 4. Clear the STA connect timeout timer (blob: ke_timer_clear at 0x60)
  # Blob: a0=APM_STA_CONNECT_TIMEOUT_IND, a1=instNbr
  let timerMsgId = KE_FIRST_MSG(TASK_APM.uint16) + 6  # APM_STA_CONNECT_TIMEOUT_IND
  ke_timer_clear(timerMsgId, instNbr)

  # 5. Fill and send ME_SET_PS_DISABLE_REQ
  if msg1 != nil:
    let req = cast[ptr MeSetPsDisableReqPayload](msg1)
    req.disable = 0
    req.vifIdx = instNbr
    ke_msg_send(msg1)

  # 6. If VIF has connected STAs, send MM_SET_VIF_STATE_REQ to deactivate
  let numSta = vif.state
  if numSta != 0:
    let stateMsg = cast[ptr MmSetVifStateReqPayload](
      ke_msg_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_APM,
                   MmSetVifStateReqPayloadSize))
    if stateMsg != nil:
      stateMsg.state = 0
      stateMsg.vifIdx = instNbr
      ke_msg_send(stateMsg)

  # 7. Unlink channel context if present (blob: chan_ctxt_unlink at 0xb0)
  let chanCtxt = vif.chanCtxt
  if chanCtxt != nil:
    chan_ctxt_unlink(instNbr)

  # 8. Fill and send ME_SET_ACTIVE_REQ (deactivate)
  if msg2 != nil:
    let req = cast[ptr MeSetActiveReqPayload](msg2)
    req.active = 0
    req.vifIdx = instNbr
    ke_msg_send(msg2)

proc apm_set_bss_param*(param: pointer) {.exportc, cdecl.} =
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
    let rateCount = apInfo.basicRateCount
    let rateBits = me_legacy_rate_bitfield_build(
      cast[pointer](addr apInfo.basicRates[0]), rateCount)
    req.rateBitfield = rateBits
    req.vifIdx = vifIdx
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
  ke_state_set(TASK_APM, ApmActiveState)
  apm_send_next_bss_param(param)

proc apm_send_next_bss_param*(param: pointer) {.exportc, cdecl.} =
  ## Send next BSS parameter during AP setup (72 bytes in blob, 18 instrs, apm.o).
  ## Blob: co_list_pop_front(&apm_env+4), assert non-null (line 188),
  ## add 12 to skip ke_msg header, tail-call ke_msg_send.
  let listPtr = addr apmEnvView().pendingBssParams
  let elem = co_list_pop_front(listPtr)
  if elem == nil:
    assert_err("apm.c", "apm.c", 188)
  # Element is the CoListHdr at the start of the ke_msg header.
  let msg = keMsgPayload(cast[ptr KeMsgHdr](elem))
  ke_msg_send(msg)

proc apm_bcn_set*(param: pointer) {.exportc, cdecl.} =
  ## Set beacon content for AP mode.
  ## From blob (59 instrs): loads connect info from apm_env[0], allocates
  ## MM_BCN_CHANGE_REQ message (id=45), fills beacon ptr/len/tim/csa offsets,
  ## optionally copies beacon payload from apm_env[16] and clears it, sends
  ## the message, then tail-calls ke_state_set(TASK_APM, 2).
  let apm = apmEnvView()
  let connInfo = apm.connectInfo
  if connInfo == nil: return
  let apInfo = apmStartInfoView(connInfo)

  # Compute paramLen from beacon length + 12 (header)
  let bcnLen = apInfo.beaconLength
  let paramLen = bcnLen.uint32 + 12
  # Allocate MM_BCN_CHANGE_REQ (msg id 45)
  let msg = cast[ptr MmBcnChangeReqPayload](
    ke_msg_alloc(45, TASK_MM, TASK_APM, paramLen))
  if msg == nil: return

  # Fill message fields from connect info
  msg.beaconTemplate = apInfo.beaconTemplate
  msg.beaconLength = apInfo.beaconLength
  msg.timOffset = apInfo.timOffset
  msg.csaOffset0 = apInfo.csaOffset0
  msg.csaOffset1 = apInfo.vifIdx

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

  # Send the message
  ke_msg_send(cast[pointer](msg))

  # Advance APM state to 2
  ke_state_set(TASK_APM, ApmStartingState)

proc apm_sta_add*(param: pointer): uint8 {.exportc, cdecl.} =
  ## Add a station to AP (association) (38 instrs).
  ## From blob: a0 = STA info pointer from association request.
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
  let sta = staInfoAt(param)
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
  msg.assoc0 = sta.registerWord0
  msg.assoc1 = sta.registerWord1
  msg.flags = sta.paramFlag
  ke_msg_send(msg)
  return 0

proc apm_sta_remove*(vifEntry: pointer, staIdx: uint8, macAddr: pointer, reason: uint32) {.exportc, cdecl.} =
  ## Remove a station from AP (62 instructions in blob).
  ##
  ## Blob ABI: a0=vifEntry, a1=staIdx, a2=macAddr, a3=reason.
  ##
  ## Flow:
  ##   1. Compute sta_entry = sta_info_tab + a1 * 368.
  ##   2. Log STA MAC bytes (offsets 4,6,8 halfwords from entry) at line 1090.
  ##   3. Compute VIF entry from vif_info_tab + vifIdx * 1512.
  ##   4. Call apm_send_mlme(sta_entry+4, 0xC0, macAddr, nil, nil, reason) to send
  ##      deauth frame.
  ##   5. Tail-call apm_sta_fw_delete(staIdx, vifIdx, reason).
  let sta = staInfoForIdx(staIdx)
  let staMac = cast[pointer](addr sta.macAddr[0])

  # Log STA MAC bytes from sta_entry at offsets 4, 6, 8 (halfwords)
  let logFn = getLogFunc(0)
  if logFn != nil:
    let hw4 = sta.macAddr[0].uint16 or (sta.macAddr[1].uint16 shl 8)
    let hw6 = sta.macAddr[2].uint16 or (sta.macAddr[3].uint16 shl 8)
    let hw8 = sta.macAddr[4].uint16 or (sta.macAddr[5].uint16 shl 8)
    logFn(2, 0, nil, 1090, hw4.uint32, hw6.uint32, hw8.uint32)

  # Send deauth MLME frame: apm_send_mlme(sta_entry+4, 0xC0, macAddr, nil, nil, reason)
  apm_send_mlme(staMac, 0xC0'u16, macAddr, nil, nil,
                cast[pointer](reason))

  # Tail-call apm_sta_delete to remove the STA (blob calls apm_sta_delete, not apm_sta_fw_delete)
  apm_sta_delete(cast[pointer](staIdx.uint or (1'u shl 16) or (reason shl 8)))

proc apm_sta_fw_delete*(staIdx: uint8, vifIdx: uint8, reason: uint16) {.exportc, cdecl.} =
  ## Delete station from firmware tables (28 bytes in blob, 8 instrs).
  ## From blob: tail-calls apm_sta_delete with packed ABI:
  ##   a0=staIdx, a1=sta_info_tab+4+staIdx*368 (MAC addr), a2=vifIdx, a3=reason.
  let sta = staInfoForIdx(staIdx)
  let staMacAddr = cast[pointer](addr sta.macAddr[0])
  # Pass a1=macAddr, a2=vifIdx, a3=reason to apm_sta_delete (which reads them via asm)
  {.emit: ["asm volatile(\"mv a1, %0\" : : \"r\"(", staMacAddr, ") );"].}
  {.emit: ["asm volatile(\"mv a2, %0\" : : \"r\"(", vifIdx, ") );"].}
  {.emit: ["asm volatile(\"mv a3, %0\" : : \"r\"(", reason, ") );"].}
  apm_sta_delete(cast[pointer](staIdx.uint))

proc apm_probe_req_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle probe request in AP mode (103 instrs).
  ## a0 = RX frame descriptor for the received probe request.
  ## Looks up the AP VIF from param[8] (VIF index). If VIF index is 0xFF,
  ## calls mm_ap_probe_cfm to find the matching AP VIF.
  ## Checks VIF is active (byte 88 != 0) and has a channel context (offset 64 != nil).
  ## Extracts the probe request SSID IE and compares against the AP's SSID.
  ## If SSID matches or is wildcard, checks supported rates for band compatibility.
  ## Finally tail-calls apm_send_mlme to send probe response.
  let req = apmProbeReqView(param)
  let vifIdx = req.vifIdx
  let vif =
    if vifIdx == 0xFF:
      # Search for AP VIF
      let apVif = vif_mgmt_get_first_ap_inf()
      if apVif == nil:
        return
      vifChannelAt(apVif)
    else:
      vifChannelForIdx(vifIdx)
  let apSsid = vifApProbeSsid(vif)
  # Check VIF is active and has channel context
  let active = vif.state
  if active == 0:
    return
  let chanCtxt = vif.chanCtxt
  if chanCtxt == nil:
    return
  # Find SSID IE in probe request using mac_ie_find
  # Build search params: body starts at param-24 offset from frame start
  let bodyPtr = param
  let bodyLen = req.bodyLen
  # Use mac_ie_find with the available frame info
  let ssidIe = mac_ie_find(bodyPtr, bodyLen.uint32, 0)
  if ssidIe != nil:
    let ssid = cast[ptr MacIeView](ssidIe)
    let ieLen = ssid.len
    if ieLen != 0:
      let apSsidLen = apSsid.ssidLen
      if ieLen != apSsidLen:
        return
      let result = c_memcmp(cast[pointer](addr ssid.macIePayload[0]),
                            cast[pointer](addr apSsid.ssidData[0]), ieLen.csize_t)
      if result != 0:
        return
  else:
    if apSsid.hiddenSsidMode != 0:
      return
  # Check supported rates (IE ID=1) for band compatibility
  let ratesIe = mac_ie_find(bodyPtr, bodyLen.uint32, 1)
  if ratesIe != nil:
    let rates = cast[ptr MacIeView](ratesIe)
    let rateVal = rates.macIePayload[0]
    let rateInfo = vif.operChan
    if rateInfo != nil:
      let chan = cast[ptr ScanChannelEntry](rateInfo)
      let band = chan.band
      # Perform rate/band compatibility check
      if band == 0:
        # 2.4GHz: check basic rate range (blob computes rate offset and divides by 5)
        let rateBase = (rateVal and 0x7F).uint32
        if rateBase > 72:  # 48*1.5 = max expected
          return
      else:
        # 5GHz band
        let rateBase = (rateVal and 0x7F).uint32
        if rateBase < 12:  # min 6Mbps
          return
  # Send probe response: tail-call apm_send_mlme
  # Args: a0=vifEntry, a1=0x50(probe_resp subtype), a2=param+42(src addr), a3..a5=0
  apm_send_mlme(cast[pointer](vif), 0x50'u16,
                cast[pointer](addr req.staMac[0]), nil, nil, nil)

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
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx == 0xFF:
    return

  let vif = vifChannelForIdx(vifIdx)
  let staMac = cast[pointer](addr rx.staMac[0])

  # Look up STA by MAC address via HW search
  let staIdx = hal_machw_search_addr(staMac, 0)

  if staIdx != 0xFF:
    # Station exists: delete it before re-adding
    apm_sta_delete(staMac)

  # Get channel context count
  let ctxtCnt = chan_ctxt_cnt()
  if ctxtCnt > 1:
    let chanCtxt = vif.chanCtxt
    vif.apChanSwitchPending = 1
    chan_ctxt_trigger(chanCtxt)

  # Send authentication response frame: tail-call apm_send_mlme
  apm_send_mlme(cast[pointer](vif), 0xB0, staMac, nil, nil, nil)

{.emit: "__attribute__((optimize(\"crossjumping\"))) void apm_assoc_req_handler(void*,unsigned long);".}
proc apm_assoc_req_handler*(param: pointer, reassoc: uint32 = 0) {.exportc, cdecl.} =
  ## Handle AP-mode association request (470 instructions in blob).
  ## Parses Assoc/Reassoc Request, validates rates/security, builds
  ## APM_STA_ADD_IND message, manages apm_env STA slots, and sends
  ## association response via apm_send_mlme with TX confirm callback.
  ## Second parameter reassoc: 0=assoc, 1=reassoc (passed by dispatcher).
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx == 0xFF: return

  let staMac = cast[pointer](addr rx.staMac[0])
  let apm = apmEnvView()
  let logFn204 = getLogFunc(204)

  # Debug log: MAC address at line 501 (blob: jalr t1 at 0x7C)
  if logFn204 != nil:
    let m = cast[ptr UncheckedArray[uint8]](staMac)
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 501,
      m[0].uint32, m[1].uint32, m[2].uint32,
      m[3].uint32, m[4].uint32, m[5].uint32)

  # Search apm_env for existing entry with matching MAC (blob: loop at 0x8A-0x94)
  # 5 entries, stride 16 bytes; active flag at +104, MAC at +92
  for i in 0'u ..< 5'u:
    let slot = apmStaSlot(i)
    if slot.active != 0:
      if c_memcmp(cast[pointer](addr slot.macAddr[0]), staMac, 6) == 0:
        # Duplicate STA found: log at line 852 via g_bl_ops_funcs[4] and return
        let warnFn = getLogFunc(4)
        if warnFn != nil:
          warnFn(cast[uint32](cast[uint](cstring"apm duplicate")),
            cast[uint32](cast[uint](cstring"apm.c")), cast[pointer](852), 0)
        return

  # Alloc APM_STA_ADD_IND (88 bytes)
  let msg = cast[ptr ApmAssocStaAddIndPayload](
    ke_msg_alloc(APM_STA_ADD_IND, TASK_API, TASK_APM,
                 sizeof(ApmAssocStaAddIndPayload).uint32))
  if msg == nil: return
  discard c_memset(msg, 0, sizeof(ApmAssocStaAddIndPayload).csize_t)
  discard c_memcpy(addr msg.macAddr[0], staMac, 6)
  msg.vifIdx = vifIdx
  msg.assocWord16 = rx.assocWord16
  msg.assocWord20 = rx.assocWord20
  msg.assocByte24 = rx.assocByte24
  msg.assocByte28 = rx.assocByte28

  # Debug logs for msg fields (blob: 5 calls at lines 864-868 via g_bl_ops_funcs[204])
  if logFn204 != nil:
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 864)
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 865, msg.assocWord16)
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 866, msg.assocWord20)
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 867, msg.assocByte24.uint32)
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 868, msg.assocByte28.uint32)

  # Determine assoc vs reassoc from parameter; compute IE body
  let totalIeLen = rx.bodyLen
  var iePtr: pointer; var ieLen: uint32
  if reassoc != 0:
    iePtr = cast[pointer](addr rx.bodyPrefix[6])
    ieLen = if totalIeLen > 34: totalIeLen.uint32 - 34 else: 0'u32
  else:
    iePtr = cast[pointer](addr rx.bodyPrefix[0])
    ieLen = if totalIeLen > 28: totalIeLen.uint32 - 28 else: 0'u32

  let vifView = vifChannelForIdx(vifIdx)
  let apCfg = vifApConfig(vifView)
  let vifMaxRate = apCfg.maxAssocRate

  var status: uint8 = 0

  # Parse SSID (id=0) and validate against AP config (blob: mac_ie_find + memcmp at 0x218/0x278)
  let ssidIe = mac_ie_find(iePtr, ieLen, 0)
  if ssidIe != nil:
    let ssid = cast[ptr MacIeView](ssidIe)
    let ssidLen = ssid.len
    let vifSsidLen = apCfg.privacyFlag
    if ssidLen != vifSsidLen or
       c_memcmp(cast[pointer](ssid.macIePayload),
                cast[pointer](addr apCfg.ssidData[0]), ssidLen.csize_t) != 0:
      status = 12  # SSID mismatch

  # Parse Supported Rates (id=1) and check against VIF max
  let ratesIe = mac_ie_find(iePtr, ieLen, 1)
  if ratesIe != nil:
    let rates = cast[ptr MacIeView](ratesIe)
    let rLen = rates.len
    if rLen.uint16 > vifMaxRate: status = 18

  # Build rate accumulator
  var rateBuf {.noinit.}: array[49, uint8]
  rateBuf[0] = 0
  if ratesIe != nil:
    let rates = cast[ptr MacIeView](ratesIe)
    let ratesBody = rates.macIePayload
    let rLen = rates.len
    var ri: uint8 = 0
    while ri < rLen:
      rateBuf[0] += 1
      rateBuf[rateBuf[0]] = ratesBody[ri]
      ri += 1

  # Parse Extended Rates (id=50)
  let extIe = mac_ie_find(iePtr, ieLen, 50)
  if extIe != nil:
    let ext = cast[ptr MacIeView](extIe)
    let extBody = ext.macIePayload
    let eLen = ext.len
    var ei: uint8 = 0
    while ei < eLen:
      rateBuf[0] += 1
      rateBuf[rateBuf[0]] = extBody[ei]
      ei += 1
  msg.rateCount = 0

  # Check rates against VIF supported set at vif+436
  let vifRateCount = vifView.basicRates[0]
  var rI: uint8 = 0
  while rI < vifRateCount:
    let vr = vifView.basicRates[1 + rI.int]
    var fnd = false
    for j in 1'u8 .. rateBuf[0]:
      if (rateBuf[j] and 0x7F) == (vr and 0x7F):
        fnd = true; break
    if not fnd and (cast[int8](vr) < 0):
      status = 18; break
    if fnd:
      let cnt = msg.rateCount
      if cnt < msg.rateBytes.len.uint8:
        msg.rateBytes[cnt] = vr
      msg.rateCount = cnt + 1
    rI += 1

  # Parse HT Capabilities (id=45)
  let htIe = mac_ie_find(iePtr, ieLen, 45)
  if htIe != nil:
    let ht = cast[ptr MacIeView](htIe)
    let htBody = ht.macIePayload
    let htLen = ht.len
    if htLen >= 26:
      let hc0 = htBody[0]
      let hc1 = htBody[1]
      apmAssocHtCapInfo(msg)[] = hc0.uint16 or (hc1.uint16 shl 8)
      let he0 = htBody[19]
      let he1 = htBody[20]
      apmAssocHtExtendedCap(msg)[] = he0.uint16 or (he1.uint16 shl 8)
      let tf0 = htBody[21]
      let tf1 = htBody[22]
      apmAssocTxBfCap(msg)[] = tf0.uint32 or (tf1.uint32 shl 8)
      apmAssocAselCap(msg)[] = htBody[25]
      msg.flags = msg.flags or 2

  # NOTE: Blob does NOT search for QoS (id=4) or VHT (id=191) in apm_assoc_req_handler.
  # Those IEs are handled by the host driver after receiving APM_STA_ADD_IND.

  # Build rate bitfield from parsed rates (blob: call me_legacy_rate_bitfield_build)
  let rateBitfield = me_legacy_rate_bitfield_build(cast[pointer](addr rateBuf[0]), rateBuf[0])
  msg.rateBitfield = rateBitfield

  # Check RSN/security: blob only validates the IE exists (via
  # mac_ie_find/mac_vsie_find) but does NOT memcmp the IE body against
  # the VIF template. Removing the spurious memcmp to match blob's
  # 3-site memcmp count.
  if vifView.securityTimer.link.next != nil:
    let rsnIe = mac_ie_find(iePtr, ieLen, 48)
    if rsnIe == nil:
      let wpaOui = cast[pointer](addr WPA_OUI[0])
      let wpaIe = mac_vsie_find(iePtr, ieLen, wpaOui, 4)
      if wpaIe == nil:
        status = 40
  else:
    msg.aid = 0

  # Check STA limit against apm_env counters (blob: lbu at 87(s4), 88(s4) where s4=apm_env)
  if apm.staCount >= apm.maxSta: status = 17

  # apm_env STA slot management (blob: 0x3BC-0x5A6)
  # Only entered when status == 0 (STA limit not exceeded, rates/security OK)
  var aidIdx: int = -1
  if status == 0:
    # Translate rate for message (blob: me_rate_translate)
    let translatedRate = me_rate_translate(rateBitfield)
    msg.translatedRate = translatedRate

    # Debug log: MAC address at line 525 (blob: jalr t1 at 0x400)
    if logFn204 != nil:
      let m = cast[ptr UncheckedArray[uint8]](staMac)
      logFn204(2, 0, cast[pointer](cstring"apm.c"), 525,
        m[0].uint32, m[1].uint32, m[2].uint32,
        m[3].uint32, m[4].uint32, m[5].uint32)

    # Search apm_env for existing STA entry (blob: loop at 0x406-0x530)
    for i in 0 ..< 5:
      let slot = apmStaSlot(i.uint)
      if slot.active == 0:
        continue
      if c_memcmp(cast[pointer](addr slot.macAddr[0]), staMac, 6) == 0:
        # Found existing entry: log at line 536 and mark connected
        if logFn204 != nil:
          logFn204(2, 0, cast[pointer](cstring"apm.c"), 536, i.uint32)
        slot.active = 1
        aidIdx = i
        break

    if aidIdx < 0:
      # No existing entry: find a free slot (blob: loop .L201 at 0x536)
      for i in 0 ..< 5:
        let slot = apmStaSlot(i.uint)
        if slot.active == 0:
          # Free slot found: memcpy MAC, set flags, store msg ptr, incr count
          discard c_memcpy(addr slot.macAddr[0], staMac, 6)  # blob: memcpy at 0x568
          slot.active = 1
          slot.staHandle = cast[pointer](msg)
          apm.staCount = apm.staCount + 1
          # Debug log: slot index at line 560 (blob: jalr a6 at 0x5A4)
          if logFn204 != nil:
            logFn204(2, 0, cast[pointer](cstring"apm.c"), 560, i.uint32)
          aidIdx = i
          break

    if aidIdx < 0:
      # All STA slots full
      status = 17

  # Store AID in message (blob: sh at 0x45A, AID = index + 1)
  if aidIdx >= 0:
    msg.aid = (aidIdx + 1).uint16

  # Debug log: final status at line 1023 (blob: jalr a6 at 0x47A)
  if logFn204 != nil:
    logFn204(2, 0, cast[pointer](cstring"apm.c"), 1023, status.uint32)

  if status != 0:
    msg.status = status

  # Send association/reassociation response via apm_send_mlme (blob: call at 0x23E)
  # Blob always sends regardless of status; passes apm_tx_cfm_handler as callback
  # and msg as callbackArg. The TX confirm handler sends or frees the msg.
  let vifPtr = cast[pointer](vifView)
  let frameType: uint16 = if reassoc != 0: 0x30'u16 else: 0x10'u16
  apm_send_mlme(vifPtr, frameType, staMac,
    cast[pointer](apm_tx_cfm_handler), cast[pointer](msg), nil)

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
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx == 0xFF:
    return
  let staIdx = rx.staIdx
  if staIdx == 0xFF:
    return

  # Extract reason code from param[56..57] (LE16)
  let reason = rx.reason

  # Log
  let logFn = getLogFunc(4)
  if logFn != nil:
    logFn(2, 0, nil, 1054, reason.uint32)

  let staMac = cast[pointer](addr rx.staMac[0])

  # Remove station: blob tail-calls apm_sta_delete(packed args)
  # Blob ABI: a0=staIdx|reason<<8|type<<16, passes as single packed pointer arg
  apm_sta_delete(cast[pointer](staIdx.uint or (2'u shl 16) or (reason.uint shl 8)))

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
  let rx = apmRxMgmtPrefix(param)
  let vifIdx = rx.vifIdx
  if vifIdx == 0xFF:
    return
  let staIdx = rx.staIdx
  if staIdx == 0xFF:
    return

  # Extract reason code from param[56..57] (LE16)
  let reason = rx.reason

  # Log
  let logFn = getLogFunc(4)
  if logFn != nil:
    logFn(2, 0, nil, 1074, reason.uint32)

  # Get VIF entry from the typed VIF table overlay.
  let vif = vifChannelForIdx(vifIdx)
  let staMac = cast[pointer](addr rx.staMac[0])

  # Send disassociation response
  apm_send_mlme(cast[pointer](vif), 0xC0, staMac, nil, nil, nil)

  # Remove station: blob tail-calls apm_sta_delete(packed args)
  apm_sta_delete(cast[pointer](staIdx.uint or (3'u shl 16) or (reason.uint shl 8)))

proc apm_beacon_handler*(param: pointer) {.exportc, cdecl, noinline.} =
  ## Handle beacon reception in AP mode.
  ## noinline + asm barrier: blob calls this as a real function from
  ## rxu_mgt_ind_handler/rxu_mgt_ind_handler_apm; without the barrier GCC
  ## elides the call because the body is a no-op.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}

proc apm_embedded_enabled*(vifEntry: pointer): bool {.exportc, cdecl, noinline.} =
  ## Check if embedded AP mode is enabled for given VIF entry.
  ## From blob (12 instrs): if vifEntry is NULL, return hostapd_enabled & 1.
  ## Otherwise, check if vifType (offset 86) == 2 (AP mode); if so return
  ## hostapd_enabled & 1, else return 0.
  ## noinline + asm barrier: callers use `discard apm_embedded_enabled(...)`
  ## or call with nil in some branches; without the barrier GCC elides the
  ## call because the return value is unused and the body is side-effect-free.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  if vifEntry == nil:
    return (hostapd_enabled and 1) != 0
  let vifType = vifChannelAt(vifEntry).vifType
  if vifType == 2:
    return (hostapd_enabled and 1) != 0
  return false

proc apm_get_hostapd_ctx*(): pointer {.exportc, cdecl, noinline.} =
  ## Get hostapd context pointer from apm_env[172] (blob layout; not a
  ## separate global). Previous Nim read a separate Nim-only `hostapd_ctx`
  ## global that is never written by the firmware, so always returned nil.
  ## Blob: `auipc+lw of apm_env+0xac; ret`.
  {.emit: ["asm volatile(\"\" ::: \"memory\");"].}
  return apmEnvView().hostapdCtx

proc apm_handle_eapol_input*(staIdx: uint8, rxBuf: pointer, rxLen: uint32) {.exportc, cdecl.} =
  ## Handle EAPOL input in AP mode.
  ## From blob (17 instrs): checks hostapd_ctx; if NULL, returns immediately.
  ## Otherwise, computes STA entry from staIdx, then VIF entry from STA instNbr
  ## vif_info_tab + instNbr * VIF_ENTRY_SIZE. Loads the hostapd_ops callback
  ## table, extracts the EAPOL RX handler at offset 44 of the ops struct, and
  ## calls it with (apm_env[172], vif->hostapd_priv, rxBuf, rxLen).
  let hostapdCtx = apmEnvView().hostapdCtx
  if hostapdCtx == nil:
    return
  let instNbr = staInfoForIdx(staIdx).instNbr
  let vif = vifChannelForIdx(instNbr)
  # Load hostapd ops table pointer from vif_mgmt_env offset 12
  let opsPtr = vifMgmtHostapdOpsEnv().hostapdOps
  if opsPtr == nil: return
  # Get EAPOL RX handler at offset 44 in ops table
  let eapolHandler = hostapdOpsAt(opsPtr).eapolRx
  if eapolHandler == nil: return
  # Load VIF's hostapd private data from vif+364
  let vifPriv = vifHostapdPriv(vif).hostapdPriv
  # Call the handler: eapolHandler(hostapd_ctx, vifPriv, rxBuf, rxLen)
  type EapolHandlerFn = proc(ctx: pointer, priv: pointer, buf: pointer, length: uint32) {.cdecl.}
  cast[EapolHandlerFn](eapolHandler)(hostapdCtx, vifPriv, rxBuf, rxLen)

proc apm_handle_auth_done*(param: pointer) {.exportc, cdecl.} =
  ## Handle auth done callback in AP mode.
  ## From blob (7 instrs): param is actually a staIdx (uint8 in a0).
  ## Computes sta_info_tab[staIdx] (stride 368), stores 2 at sta[72] (auth done flag).
  let staIdx = encodedArgU8(param)
  staInfoForIdx(staIdx).rxNss = 2  # auth done state at offset 72

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
  ## On alloc failure, calls assert_rec then callback(callbackArg, 0x40000000) if set.
  let vif = vifChannelAt(vifEntry)

  # Allocate 512-byte frame buffer (blob: txl_frame_get, NOT ke_msg_alloc)
  let frame = txl_frame_get(512)
  if frame == nil:
    if callback != nil:
      type CbFn = proc(arg: pointer, flags: uint32) {.cdecl.}
      cast[CbFn](callback)(callbackArg, 0x40000000'u32)
    return

  let desc = hostTxDescAt(frame)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hdr = hostTxDataHeader(desc)

  # Build MAC header at link.macHeader.
  hdr.frameControl = frameType
  hdr.duration = 0

  # DA = destAddr.
  discard c_memcpy(addr hdr.addr1[0], destAddr, 6.csize_t)

  # SA = VIF MAC at vifEntry+80.
  discard c_memcpy(addr hdr.addr2[0], addr vif.macAddr[0], 6.csize_t)

  # BSSID = VIF MAC (same as SA for AP mode).
  discard c_memcpy(addr hdr.addr3[0], addr vif.macAddr[0], 6.csize_t)

  let seqField = nextTxSeqCtrl()
  hdr.seqCtrl = seqField

  # Dispatch on frame type to build frame body after the MAC header.
  let bodyBuf = cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView)])
  let instNbr = vif.vifIdx
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
    # Probe response: me_build_probe_rsp(body, inst_nbr)
    let bodyLen = me_build_probe_rsp(bodyBuf, instNbr, nil)
    totalLen = bodyLen + 24

    # Add customer IEs (blob: me_add_ie_customer at 0x110)
    let apm = apmEnvView()
    let custIeLen = me_add_ie_customer(
      cast[pointer](addr link.macHeader[sizeof(MacDataFrameHeaderView) + bodyLen.int]),
      addr apm.securityIe[0],
      apm.cryptoType.uint32)
    totalLen += custIeLen
    # Blob does NOT append extra probe response IEs here — customer IEs
    # are the full append path.

  elif (frameType and (not 0x20'u16)) == 0x10:
    # Assoc response (0x10) or reassoc response (0x30)
    # me_build_associate_rsp(body, inst_nbr, extraParam, callbackArg)
    type BuildAssocRspFn = proc(buf: pointer, vifIdx: uint8, status: pointer,
        extra: pointer): uint32 {.cdecl.}
    let bodyLen = cast[BuildAssocRspFn](me_build_associate_rsp)(
        bodyBuf, instNbr, extraParam, callbackArg)
    totalLen = bodyLen + 24

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
  txl_frame_push(frame, 3)

proc aidListDelete(macAddr: pointer) {.exportc: "aid_list_delete", cdecl, noinline.} =
  ## Compiler-generated helper (blob: _aid_list_delete.isra.0; Nim exports the
  ## parent symbol `aid_list_delete` for 1:1 symbol parity).
  ## Iterates 5 AID entries in apm_env, compares 6-byte MAC addresses.
  ## On match: clears the MAC, calls WPA disconnect callback, decrements STA count.
  ## noinline: blob calls this from both apm_sta_delete and apm_tx_cfm_handler.
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  let logFn = getLogFunc(204)
  let apm = apmEnvView()
  # Log the MAC address (line 471)
  if logFn != nil:
    let m = cast[ptr UncheckedArray[uint8]](macAddr)
    cast[PlatformLogFunc](logFn)(2, 0, nil, 471,
      m[0].uint32, m[1].uint32, m[2].uint32, m[3].uint32, m[4].uint32, m[5].uint32)
  # Search 5 entries (stride 16 bytes from apm_env base)
  for i in 0'u32 ..< 5'u32:
    let slot = apmStaSlot(i.uint)
    if slot.active == 0:
      continue
    # Compare 6-byte MAC at entry offset 92
    let entryMac = cast[pointer](addr slot.macAddr[0])
    if c_memcmp(entryMac, macAddr, 6) != 0:
      continue
    # Match found: clear the MAC
    discard c_memset(entryMac, 0, 6)
    # Call WPA disconnect callback: wpa_cbs[10] (byte offset 40)
    if wpa_cbs != nil:
      let wpaCbArr = cast[ptr UncheckedArray[pointer]](wpa_cbs)
      let disconnCb = wpaCbArr[10]
      if disconnCb != nil:
        cast[proc(p: pointer) {.cdecl.}](disconnCb)(slot.staHandle)
    # Clear connected byte at apm_env + (i+5)*16 + 24
    slot.active = 0
    # Decrement STA count
    apm.staCount = apm.staCount - 1
    # Log deletion (line 487)
    if logFn != nil:
      cast[PlatformLogFunc](logFn)(2, 0, nil, 487, i.uint32)
    return
  # No match found: log (line 491)
  if logFn != nil:
    cast[PlatformLogFunc](logFn)(2, 0, nil, 491)

proc apm_tx_cfm_handler*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation in AP mode (31 instrs).
  ## From blob: a0=txDesc, a1=txStatus. Checks bit 23 (0x00800000) of txStatus:
  ##   If set (retry/failure) and pendingCount != 0: tail-call ke_msg_send(txDesc).
  ##   If set and pendingCount == 0: tail-call ke_msg_free(txDesc - 12).
  ##   If not set (success) and pendingCount != 0: call _aid_list_delete(txDesc).
  ##   Then call g_bl_ops_funcs[1] TX confirm callback with string and counts.
  var txStatus: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", txStatus, ") );"].}
  let tx = apmTxDescPsAt(param)
  let pendingCount = tx.pendingCount
  if (txStatus and 0x00800000'u32) != 0:
    # TX retry/failure path
    if pendingCount != 0:
      ke_msg_send(param)
    else:
      ke_msg_free(keMsgHdrFromPayload(param))
  else:
    # TX success path
    if pendingCount != 0:
      aidListDelete(param)
    # Call TX confirm callback via g_bl_ops_funcs[1] (byte offset 4)
    let pendingCount2 = tx.pendingCount  # reload after aidListDelete
    let txCfmCb = blOpsFunc(4)
    if txCfmCb != nil:
      cast[proc(a: pointer, b: uint32, c: uint32) {.cdecl.}](txCfmCb)(
        param, txStatus, pendingCount2.uint32)

proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.} =
  ## Check if station requires PS postpone (AP-side TX path).
  ## From blob (54 instrs): reads txDesc fields, loads STA and VIF entries,
  ## checks if VIF is in AP mode (type==2), STA is in PS state, and frame
  ## is not a bufferable management frame (subtype <= 6). If all conditions
  ## met and STA TIM bit is clear, sets the PS-poll flag in the STA's
  ## postpone bitmap and returns false (don't transmit). Returns true (OK to TX)
  ## in all other cases.
  let tx = apmTxDescPsAt(txDesc)

  # Check active channel contexts (blob: chan_ctxt_cnt, not ke_state_get)
  let ctxtCount = chan_ctxt_cnt()
  if ctxtCount <= 1:
    return true  # APM not active, allow TX

  # Check STA entry: offset 4 = next ptr, offset 32 = rate info
  let staPeerPtr = tx.staPeer
  if staPeerPtr == nil:
    return true
  let staRateInfo = staInfoAt(staPeerPtr).rateSet
  if staRateInfo != 0:
    return true

  # Load STA's TX descriptor at offset 108
  let staDescPtr = tx.staDesc
  if staDescPtr == nil:
    return true
  let linkDesc = hostTxLinkDescAt(staDescPtr)

  # Check frame type (TID descriptor offsets 348-349)
  let ftype0 = linkDesc.macHeader[0]
  let ftype1 = linkDesc.macHeader[1]
  let frameType = ftype0.uint16 or (ftype1.uint16 shl 8)
  if frameType == 0xC4:
    return true  # Control frame, allow TX

  # Blob checks the first AP VIF slot here.
  let vifType = vifChannelForIdx(0).vifType
  if vifType != 2:
    return true  # Not AP mode

  # Check STA subtype
  let staSubtype = tx.subtype
  if staSubtype > 6:
    return true

  let staInstNbr = tx.staInstNbr

  # Check PS state at STA entry offset 41
  let psState = staInfoForIdx(staInstNbr).psMode
  if psState != 1:
    return true

  # Check STA's postpone state bits at offset 48
  let postponeBits = tx.postponeFlags
  if (postponeBits and 3) != 0:
    return true

  # Set PS-poll flag in STA's postpone bitmap
  tx.postponeFlags = tx.postponeFlags or 0x1000
  return false

proc apm_tx_int_ps_postpone*(txDesc: pointer, staEntry: pointer) {.exportc, cdecl.} =
  ## Postpone TX for PS station (47 instrs).
  ## From blob: a0=txDesc (VIF entry), a1=staEntry. Checks txDesc+50 (halfword)
  ## bit 12 (0x1000) set. If not, returns. Reads STA delivery mask from a1+314,
  ## computes AND with txDesc[46] (AC/TID). If match, checks staEntry+73 bits.
  ## Sets bit 3 (0x08) or bit 1 (0x02) in staEntry+73 depending on delivery type.
  ## If bit was already set, returns. Otherwise stores updated flags.
  ## If all delivery bits match (mask==0xF), allocates ke_msg for TIM update.
  let tx = apmTxDescPsAt(txDesc)  # blob passes txDesc as a0
  let sta = staInfoAt(staEntry)  # blob passes staEntry as a1
  # Check postpone flag at txDesc+50
  let postponeFlags = tx.postponeFlags
  if (postponeFlags and 0x1000) == 0:
    return
  # Read delivery mask and TID
  let delivMask = sta.psState
  let tid = tx.tid
  let tidMatch = tid and delivMask
  let psFlags = sta.trafficFlags
  if tidMatch != 0:
    # UAPSD delivery
    if (psFlags and 0x08) != 0:
      return  # already set
    sta.trafficFlags = psFlags or 0x08
  else:
    # Legacy PS delivery
    if (psFlags and 0x02) != 0:
      return  # already set
    sta.trafficFlags = psFlags or 0x02
  # Check if all delivery bits now active -> send TIM update
  let updatedFlags = sta.trafficFlags
  let allMask = delivMask and tx.tid
  if allMask == 0x0F or updatedFlags == 0x0F:
    let msg = cast[ptr MmTimUpdatePayload](
      ke_msg_alloc(47, TASK_MM, TASK_APM, MmTimUpdatePayloadSize))  # MM_TIM_UPDATE pseudo-msg
    if msg != nil:
      msg.aid = sta.aid
      msg.setFlag = 1
      msg.vifIdx = sta.instNbr
      ke_msg_send(msg)

proc apm_tx_int_ps_get_postpone*(vifEntry: pointer, staEntry: pointer, postponeFlag: ptr uint32): pointer {.exportc, cdecl.} =
  ## Get postponed TX frame for PS station.
  ## From blob (124 instrs): VIF AP mode check, walks STA postponed list
  ## (sta+356), matches TID against delivery mask, removes and returns frame.
  let vifView = vifChannelAt(vifEntry)
  let sta = staInfoAt(staEntry)
  let vifType = vifView.vifType
  if vifType != 2:
    postponeFlag[] = 0; return nil
  let psStatus = sta.psStatus
  if psStatus == 0:
    postponeFlag[] = 0; return nil
  var psMask, checkMask: uint8
  if (psStatus and 1) != 0:
    psMask = 1; checkMask = 2
  else:
    psMask = 4; checkMask = 8
  let staFlags = sta.trafficFlags
  if (staFlags and checkMask) == 0:
    postponeFlag[] = 1; return nil
  let delivMask = sta.psState
  var cur = cast[pointer](sta.postponedList.first)
  var prev: pointer = nil
  let psCheckSeqz = cast[uint32](if (psStatus - 2) == 0: 1 else: 0)
  while cur != nil:
    let curDesc = apmTxDescPsAt(cur)
    let frameTid = curDesc.tid
    let tidMatch = frameTid and delivMask
    let tidSeqz = cast[uint32](if tidMatch == 0: 1 else: 0)
    if tidSeqz != psCheckSeqz:
      co_list_remove(addr sta.postponedList, cast[ptr CoListHdr](prev), cast[ptr CoListHdr](cur))
      curDesc.tid = cast[uint8]((psStatus and 3) + 3)
      var nextScan =
        if prev != nil: cast[pointer](cast[ptr CoListHdr](prev).next)
        else: cast[pointer](sta.postponedList.first)
      var hasMore = false
      var scan = nextScan
      while scan != nil:
        let sTid = apmTxDescPsAt(scan).tid
        let sSeqz = cast[uint32](if (sTid and delivMask) == 0: 1 else: 0)
        let sChk = cast[uint32](if (sta.psStatus - 2) == 0: 1 else: 0)
        if sSeqz != sChk:
          hasMore = true; break
        scan = cast[pointer](cast[ptr CoListHdr](scan).next)
      if not hasMore:
        var nf = staFlags and (not checkMask)
        sta.trafficFlags = nf
        if (nf and psMask) == 0:
          let tm = cast[ptr MmTimUpdatePayload](
            ke_msg_alloc(MM_TIM_UPDATE_REQ, TASK_MM, TASK_APM,
                         MmTimUpdatePayloadSize))
          if tm != nil:
            tm.aid = sta.aid
            tm.setFlag = 0
            tm.vifIdx = sta.instNbr
            ke_msg_send(tm)
      return cur
    prev = cur
    cur = cast[pointer](cast[ptr CoListHdr](cur).next)
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
  let vif = vifChannelAt(vifEntry)
  if vif.vifType != VIF_TYPE_AP:
    return  # Not AP mode
  let sta = staInfoForIdx(staIdx)
  discard sta_mgmt_send_postponed_frame(vifEntry, cast[pointer](sta), 0)

  let psFlags = sta.trafficFlags
  if (psFlags and 0x0A) == 0:
    return
  let newFlags = psFlags and 0xF5'u8
  sta.trafficFlags = newFlags
  if newFlags != 0:
    return

  let msg = cast[ptr MmTimUpdatePayload](
    ke_msg_alloc(MM_TIM_UPDATE_REQ, TASK_MM, TASK_APM,
                 MmTimUpdatePayloadSize))
  if msg != nil:
    msg.aid = sta.aid
    msg.setFlag = 0
    msg.vifIdx = sta.instNbr
    ke_msg_send(msg)

# ###########################################################################
#                   ME: Management Entity
# ###########################################################################

proc me_init*() {.exportc, cdecl.} =
  ## Initialize management entity. Blob:
  ##   memset(me_env, 0, 136)
  ##   ke_state_set(TASK_ME=3, 0)
  ##   scanu_init(); apm_init(); sm_init(); bam_init()
  discard c_memset(addr me_env[0], 0, 136.csize_t)
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

proc me_init_rate*(staEntry: pointer) {.exportc, cdecl.} =
  ## Initialize rate control for a station.
  ## Blob ABI passes a sta_info_tag pointer through to rc_init, then reuses the
  ## same pointer for me_update_buffer_control.
  rc_init(staEntry)
  discard me_update_buffer_control(staEntry)

proc me_init_bcmc_rate*(staEntry: pointer) {.exportc, cdecl.} =
  ## Initialize broadcast/multicast rate for a station entry.
  ## From blob (35 instrs): a0 is a sta_info_tag pointer.
  ## Loads rate count from sta+248, asserts non-zero.
  ## Loops over rates at sta+249, finds max rate (masking bit 7).
  ## Calls me_rate_translate(maxRate), then rc_init_bcmc_rate(sta, rateIdx).
  ## Clears sta+334 (RC flags byte).
  let sta = staInfoAt(staEntry)
  let start = apSelfStaStart(sta)
  let rateCount = start.rateSeed[0]
  if rateCount == 0:
    assert_err("me.c", "me.c", 510)
  # Loop scanning rates at sta+249, find max rate (masking bit 7)
  var maxRate: uint32 = 0
  var i: uint32 = 0
  let rateCountU = rateCount.uint32
  while i < rateCountU:
    let rate = start.rateSeed[1 + i.int]
    let unmasked = rate.uint32 and 0x7F'u32
    if unmasked > maxRate:
      maxRate = rate.uint32 and 0x7F'u32
    inc i
  # Convert max rate to rate index, then set bcmc rate
  # Blob: mv a1,a0 (rateIdx); mv a0,s0 (sta); call rc_init_bcmc_rate
  let rateIdx = me_rate_translate(maxRate)  # blob: me_rate_translate (not me_legacy_ridx_min)
  rc_init_bcmc_rate(staEntry, rateIdx)
  start.rcFlags = 0

proc me_add_chan_ctx*(vifIdx: uint8, chanInfo: pointer, primFreq: uint16,
    centerFreq1: uint16, extra: uint8): bool {.exportc, cdecl.} =
  ## Add channel context for ME (58 bytes in blob, 18 instrs).
  ## Blob ABI: a0=vifIdx, a1=chanInfoPtr, a2=primFreq, a3=centerFreq1, a4=extra.
  ## Builds local chan_def struct on stack from chanInfo fields, calls chan_ctxt_add.
  let chan = cast[ptr ScanChannelEntry](chanInfo)
  var chanDef = default(ChanCtxtDefView)
  chanDef.band = chan.band
  chanDef.chanType = extra
  chanDef.primFreq = chan.prim20Freq
  chanDef.centerFreq1 = primFreq
  chanDef.centerFreq2 = centerFreq1
  chanDef.txPower = cast[uint8](chan.txPower)
  let rc = chan_ctxt_add(cast[pointer](addr chanDef), cast[ptr uint8](vifIdx))
  return rc == 0

proc me_beacon_check*(vifIdx: uint8, frameDesc: pointer, iesBase: pointer) {.exportc, cdecl.} =
  ## Check beacon content for HT/VHT capability changes.
  ## From blob (124 instrs): computes VIF entry from vifIdx, scans IEs in the
  ## beacon frame for HT operation IE and channel info changes. Updates VIF
  ## bandwidth flags and calls sta_mgmt_register if needed.
  ##
  ## a0=vifIdx(->s5), a1=frameDesc (adjusted -36), a2=iesBase (adjusted +36 -> s6)
  let vif = vifChannelForIdx(vifIdx)
  let vifEntry = cast[uint](vif)

  # Adjust iesBase: blob does a2 += 36
  let iesBuf = cast[pointer](cast[uint](iesBase) + 36)
  # Adjust frameDesc: blob does a1 -= 36
  let frameDescAdj = cast[pointer](cast[uint](frameDesc) - 36)

  # Get current channel context info from VIF
  let chanPtr = vif.operChan
  let chan = if chanPtr != nil: cast[ptr ScanChannelEntry](chanPtr) else: nil
  let chanBand = if chan != nil: chan.band else: 0'u8
  let htOp = vifHtOperation(vif)

  # Save current HT operation params
  let prevSecChan = htOp.secChan
  let prevChanWidth = htOp.chanWidth

  # Clear HT operation flags
  htOp.flags = 0

  # Search for HT operation IE (ID=42, length=42) in beacon IEs
  let htOpIe = mac_ie_find(iesBuf, 42, 42)  # IE_ID_HT_OPERATION = 42
  if htOpIe != nil:
    let ieData = cast[uint](htOpIe)
    let htFlags = cast[ptr uint8](ieData + 2)[]
    var bwFlags = htOp.flags
    bwFlags = bwFlags and 0xFFF8'u16  # clear lower 3 bits

    # Check secondary channel offset (bit 0)
    if (htFlags and 1) != 0:
      bwFlags = bwFlags or 1

    htOp.flags = bwFlags

    # Check STA channel width (bit 1)
    if (htFlags and 2) != 0:
      # Replicate STA channel width flag to VIF entry for the specific vifIdx
      var dstFlags = htOp.flags
      dstFlags = dstFlags or 2
      htOp.flags = dstFlags

    # Check RIFS mode (bit 2)
    if (htFlags and 4) != 0:
      var dstFlags2 = htOp.flags
      dstFlags2 = dstFlags2 or 4
      htOp.flags = dstFlags2

  # Call me_extract_power_constraint with (iesBase, ?, staEntry)
  # Blob relocation at 0xb4: me_extract_power_constraint(a0=iesBase, ?, a2=staEntry)
  let staPowerConstraint = staPowerConstraintOut(staInfoForIdx(vifIdx))
  me_extract_power_constraint(cast[pointer](iesBuf), 0, staPowerConstraint)

  # Check if channel width changed (vif[480])
  let newChanWidth = htOp.chanWidth
  if newChanWidth != prevChanWidth:
    # Channel width changed: compute delta and call tpc_update_vif_tx_power
    # Blob: delta = chanCtx[4] - newChanWidth, stored on stack, passed to tpc_update_vif_tx_power
    if chan != nil:
      let chanBw = cast[ptr uint8](addr chan.txPower)[]
      var bwDelta: uint8 = chanBw - newChanWidth
      var outParam: uint8
      # tpc_update_vif_tx_power blob ABI: (a0=vifEntry, a1=&delta, a2=&outParam)
      let tpcFn = cast[proc(vif: pointer, delta: pointer, outP: pointer) {.cdecl.}](tpc_update_vif_tx_power)
      tpcFn(cast[pointer](vifEntry), cast[pointer](addr bwDelta), cast[pointer](addr outParam))

  # Check if secondary channel offset increased (vif[479])
  let newSecChan = htOp.secChan
  if prevSecChan < newSecChan:
    # prevSecChan < newSecChan: send MM_CHAN_CTXT_UNLINK_CFM (msg ID 41)
    let surveyMsg = cast[ptr MmChanCtxtUpdatePayload](
      ke_msg_alloc(MM_CHAN_CTXT_UNLINK_CFM, TASK_MM, TASK_ME,
                   MmChanCtxtUpdatePayloadSize))
    if surveyMsg != nil:
      let chanCtxt = vif.chanCtxt
      if chanCtxt != nil:
        surveyMsg.ctxtIdx = chanCtxtAt(chanCtxt).idx
      surveyMsg.band = chanBand
      surveyMsg.secChan = htOp.secChan
      let chanFreq = if chanPtr != nil: cast[ptr uint16](cast[uint](chanPtr))[] else: 0'u16
      surveyMsg.primFreq = chanFreq
      surveyMsg.centerFreq1 = uint16(vif.channelFreqPair and 0xFFFF'u32)
      surveyMsg.centerFreq2 = uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)
      let chanCtxt2 = vif.chanCtxt
      if chanCtxt2 != nil:
        surveyMsg.txPower =
          chanCtxtAt(chanCtxt2).channel.txPower
      ke_msg_send(surveyMsg)

proc me_bw_check*(param: pointer) {.exportc, cdecl.} =
  ## Check bandwidth capabilities.
  ## From blob (7 instrs): param is a sta_info_tag pointer.
  ## Loads rate info pointer from sta+76, reads BW capability half-word,
  ## clears sta+130 and sta+82, stores BW at sta+80.
  let bw = staBandwidthOverlay(staInfoAt(param))
  let rateInfoPtr = bw.rateInfoPtr
  let bwCap = if rateInfoPtr != nil:
    cast[ptr uint16](rateInfoPtr)[]
  else:
    0'u16
  bw.secondaryBw = 0'u16  # clear secondary BW result
  bw.bwField = 0'u16      # clear BW field
  bw.primaryBw = bwCap    # store primary BW capability

proc me_check_rc*(staIdx: uint8) {.exportc, cdecl, noinline.} =
  ## Check rate control for a station.
  ## From blob (2 instrs): tail-call to rc_check(staIdx).
  rc_check(staIdx)

proc me_set_sta_ht_vht_param*(staEntry: pointer, param: pointer) {.exportc, cdecl.} =
  ## Set HT/VHT parameters for a station.
  ## From blob (6 instrs): a0 is sta_info_tag pointer (not staIdx in blob ABI).
  ## Loads a config byte from me_env global, clears sta+312 (half-word),
  ## stores config byte at sta+316, returns 0.
  ## NOTE: blob's a0 is the sta pointer; a1 is unused.
  let meBase = cast[uint](addr me_env[0])
  let configByte = cast[ptr uint8](meBase)[]  # first byte of me_env
  let sta = staInfoAt(staEntry)
  sta.bwConfigState = 0'u8
  sta.nssBwMax = 0'u8
  sta.htVhtConfig = configByte

{.emit: "__attribute__((optimize(\"crossjumping\"))) void* me_update_buffer_control(void*);".}
proc me_update_buffer_control*(sta: pointer): pointer {.exportc, cdecl.} =
  ## Update TX buffer control for a station.
  ## Reads the RC stats and TX policy descriptor, updates the rate control
  ## fields based on current rate entries, then writes the new policy to HW.
  let staView = staInfoAt(sta)
  let rcFlags = staView.mmFlagsBytes[0]
  let txPolicy = staView.txPolicy
  if rcFlags == 0:
    return txPolicy
  let policy = txPolicyAt(txPolicy)

  # Mirror the vendor stack copies before updating the descriptor under IRQ.
  var policyWord = policy.bufferAddr
  var rateWords: array[4, uint32]
  var txPowerWords: array[4, uint32]
  for acIdx in 0 ..< 4:
    rateWords[acIdx] = policy.retryRate[acIdx]
    txPowerWords[acIdx] = policy.txPower[acIdx]

  if (rcFlags and 1) != 0:
    # RC active: update retry-chain rate words from RC stats.
    let rcStats = staView.rcStats
    let vifIdx = staView.instNbr
    let vif = vifChannelForIdx(vifIdx)
    let vifHtCaps = vifHtCapabilities(vif)
    let retryRotate = rcU8(rcStats, RCS_ANOTHER_FLAG) # 0xB0
    let staMaxNss = staView.htVhtConfig

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

        let nssGroup = (mcsOrGroup shr 4) and 0x7'u32
        if acIdx == 0:
          if nssGroup < staMaxNss.uint32:
            firstNssGroup = nssGroup
            foundSameNssChain = 1
        elif foundSameNssChain != 0:
          foundSameNssChain = (if nssGroup == firstNssGroup: 1'u8 else: 0'u8)

      rateWords[acIdx] = rateWord or (rateWords[acIdx] and 0x1FFFC000'u32)

    policyWord = policyWord and (not 0x180'u32)
    if foundSameNssChain != 0:
      policyWord = policyWord or ((firstNssGroup + 1'u32) shl 7)

    staView.mmFlagsBytes[0] = staView.mmFlagsBytes[0] or 0x12'u8

  # Check bit 2 (needs descriptor update), matching vendor's temporary chain.
  if (staView.mmFlagsBytes[0] and 0x02'u8) != 0:
    for acIdx in 0 ..< 4:
      let rateWord = rateWords[acIdx]
      let formatBits = (rateWord shr 11) and 0x7'u32
      let legacyBits = rateWord and 0x7C'u32
      if (formatBits or legacyBits) != 0:
        rateWords[acIdx] =
          (rateWord and 0xE0003FFF'u32) or staView.aggregationLength

  # Check bit 4 (needs TPC update). The local TPC proc still uses its old Nim
  # signature, so pass the policy word as the second argument.
  if (staView.mmFlagsBytes[0] and 0x10'u8) != 0:
    for acIdx in 0 ..< 4:
      txPowerWords[acIdx] = tpc_get_vif_tx_power_vs_rate(0'u8, rateWords[acIdx]).uint32

  # Critical section: write back policy word under IRQ protection
  let irqState = irqSave()
  policy.bufferAddr = policyWord
  for acIdx in 0 ..< 4:
    policy.retryRate[acIdx] = rateWords[acIdx]
    policy.txPower[acIdx] = txPowerWords[acIdx]

  irqRestore(irqState)
  # Clear RC flags to mark update complete
  staView.mmFlagsBytes[0] = 0
  return txPolicy

proc me_tx_cfm_singleton*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation for singleton frames (80 bytes in blob, 25 instrs).
  ## From blob: reads host TX desc chain from frame+112 -> THD -> status word (THD+16).
  ## Extracts retry count via custom bit extract, checks bit 16 (success).
  ## If success: calls rc_check(frame) first, then rc_update_counters.
  ## Always: computes attempts=retries+1, successes=successBit+retries.
  let desc = hostTxDescAt(param)
  let thd = hostTxHeadThd(hostTxHwDescAt(desc.hwDesc))
  let statusWord = thd.flags
  # Extract retry count via custom bit extraction (approximate: bits 15:8)
  let retries = (statusWord shr 8) and 0xFF'u32
  # Check success bit (bit 16 = 0x10000)
  let successBit = if (statusWord and 0x10000'u32) != 0: 1'u32 else: 0'u32
  let attempts = retries + 1
  let successes = successBit + retries
  # If success, call rf_dump_status (blob: rf_dump_status, NOT rc_check)
  if (statusWord and 0x10000'u32) != 0:
    when defined(bl808WifiUseBl808Rf):
      rf_dump_status()
    else:
      proc rf_dump_status(staIdx: uint8) {.importc, cdecl.}
      rf_dump_status(desc.staInfoIdx)
  let staIdx = desc.staInfoIdx
  rc_update_counters(staIdx, attempts, successes)

proc me_tx_cfm_ampdu*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation for A-MPDU frames (5 instrs).
  ## From blob: a0=staIdx, a1=totalAttempts, a2=failCount, a3=ampduLen.
  ## Computes successes = a1 - a2, tail-calls rc_update_counters(a0, a1, successes).
  ## Capture hidden args via inline asm.
  var totalAttempts, failCount: uint32
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", totalAttempts, ") );"].}
  {.emit: ["asm volatile(\"mv %0, a2\" : \"=r\"(", failCount, ") );"].}
  let staIdx = encodedArgU8(param)
  let successes = totalAttempts - failCount
  rc_update_counters(staIdx, totalAttempts, successes)

proc me_tx_cfm_amsdu*(param: pointer) {.exportc, cdecl.} =
  ## Handle TX confirmation for A-MSDU frames (16 instrs).
  ## From blob: reads STA idx from frame[46], looks up sta_info_tab entry,
  ## loads rc_stats pointer from sta[324], reads AMSDU length stat from rcStats[196].
  ## Returns the stat value (or 0 if invalid STA). Return via a0 register.
  let desc = hostTxDescAt(param)
  let staIdx = desc.staIdx
  if staIdx == 0xFF:
    {.emit: ["asm volatile(\"li a0, 0\");"].}
    return
  let sta = staInfoForIdx(staIdx)
  if sta.instNbr == 0xFF:
    {.emit: ["asm volatile(\"li a0, 0\");"].}
    return
  let rcStats = sta.rcStats
  if rcStats != nil:
    let amsduLen = rcStatsCounters(rcStats).legacyRateMap
    {.emit: ["asm volatile(\"mv a0, %0\" : : \"r\"(", amsduLen, ") );"].}
  else:
    {.emit: ["asm volatile(\"li a0, 0\");"].}

# ME IE building functions
proc me_add_ie_ssid*(buf: pointer, ssid: pointer, ssidLen: uint8): uint32 {.exportc, cdecl.} =
  ## Add SSID IE to buffer. buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## Writes IE ID=0, length, then SSID data. Advances *buf. Returns total bytes.
  let bufPtrPtr = cast[ptr pointer](buf)
  let ie = ssidIeAt(bufPtrPtr[])
  ie.ie.id = 0'u8
  ie.ie.len = ssidLen
  if ssidLen > 0 and ssid != nil:
    co_pack8p(addr ie.data[0], ssid, ssidLen.uint32)
  let total = ssidLen.uint32 + 2
  bufPtrPtr[] = addr ie.data[ssidLen]
  return total

proc me_add_ie_supp_rates*(buf: pointer, rateSetPtr: pointer): uint32 {.exportc, cdecl.} =
  ## Add supported rates IE to buffer (34 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## rateSetPtr: rate_set[0] = count, rate_set[1..N] = rate bytes.
  ## Writes IE with ID=1, length=min(count,8), copies min(count,8) rate bytes.
  ## Advances *buf, returns bytes written (count clipped to 8, + 2).
  let bufPtrPtr = cast[ptr pointer](buf)
  let rateSet = rateSetAt(rateSetPtr)
  let rateCount = rateSet.count
  var writeCount = rateCount
  if writeCount > 8:
    writeCount = 8
  let ie = macIeDataAt(bufPtrPtr[])
  # Write IE header: ID=1 (Supported Rates), length
  ie.ie.id = 1'u8
  ie.ie.len = writeCount
  # Copy rate bytes — blob uses co_pack8p, not memcpy.
  co_pack8p(addr ie.data[0], addr rateSet.rates[0], writeCount.uint32)
  # Advance buffer pointer
  let totalLen = writeCount.uint32 + 2
  bufPtrPtr[] = addr ie.data[writeCount]
  return totalLen

proc me_add_ie_ext_supp_rates*(buf: pointer, rateSetPtr: pointer, totalCount: uint32): uint32 {.exportc, cdecl.} =
  ## Add Extended Supported Rates IE (ID=50) (26 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## rateSetPtr: same rate_set as supp_rates. totalCount: total number of rates.
  ## Writes IE with ID=50, length=count-8, data=rates[9..count].
  ## Advances *buf. Returns total bytes written (count-8+2 = count-6).
  let bufPtrPtr = cast[ptr pointer](buf)
  let rateSet = rateSetAt(rateSetPtr)
  let extCount = totalCount - 8
  let ie = macIeDataAt(bufPtrPtr[])
  # Write IE header: ID=50 (Extended Supported Rates)
  ie.ie.id = 50'u8
  ie.ie.len = extCount.uint8
  # Copy extended rate bytes (starting from rate_set[9], skipping first 8) —
  # blob uses co_pack8p, not memcpy.
  co_pack8p(addr ie.data[0], addr rateSet.rates[8], extCount.uint32)
  # Advance buffer pointer
  let written = totalCount - 6  # (count-8) + 2
  bufPtrPtr[] = addr ie.data[extCount]
  return written

proc me_add_ie_ds*(buf: pointer, channel: uint8): uint32 {.exportc, cdecl.} =
  ## Add DS Parameter Set IE (ID=3, length=1, total=3 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 3.
  let bufPtrPtr = cast[ptr pointer](buf)
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
  let bufPtrPtr = cast[ptr pointer](buf)
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
  let bufPtrPtr = cast[ptr pointer](buf)
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
  # TX Beamforming Capabilities (4 bytes) — same pack pattern.
  co_pack8p(cast[pointer](addr ht.txBfCapsLo),
            cast[pointer](addr me.htCaps[22]), 4)
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
  ## Secondary offset: 7 if no secondary, 5 if center1 >= prim.
  let bufPtrPtr = cast[ptr pointer](buf)
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
        if chanCtxt.channel.centerFreq1 >= primFreq:
          secOffset = 5  # SCA (secondary channel above)
      else:
        secOffset = 7  # SCB (secondary channel below)

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
  ## secMode=2: 26-byte RSN with TKIP+CCMP + 802.1X AKM.
  ## Other secMode: no IE added, returns 0.
  ##
  ## bufCtx layout: [0]=current write pointer. The IE is written at *bufCtx[0]
  ## and bufCtx[0] is advanced by the IE length.
  ## For Nim callers that pass buf directly (not a context struct), secMode
  ## defaults to 0 which returns 0 (no RSN), preserving backward compatibility.
  let bufPtrPtr = cast[ptr pointer](buf)
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
    # RSN IE: TKIP+CCMP + 802.1X AKM (26 bytes total)
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

{.emit: "__attribute__((noipa)) unsigned long me_add_ie_wpa(void*,unsigned long);".}
proc me_add_ie_wpa*(buf: pointer, secMode: uint32 = 0): uint32 {.exportc, cdecl.} =
  ## Add WPA IE (168 bytes in blob, 53 instrs).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern).
  ## secMode: if != 2, returns 0 (only WPA2/mixed mode adds WPA IE).
  ## Writes WPA vendor IE (ID=221) with Microsoft OUI (00:50:F2:01).
  ## Total 30 bytes. Advances *buf by 30. Returns 30 on success, 0 otherwise.
  ## Note: blob is 168 bytes because GCC reloads *buf before each store group.
  ## Our GCC -Os factors the stores into a helper, so this is 30 bytes compiled.
  ## The gap is a GCC code factoring optimization difference, not missing logic.
  if secMode != 2:
    return 0
  let bufPtrPtr = cast[ptr pointer](buf)
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
  bufPtrPtr[] = addr wpa.next[2]
  return 30

proc writeWpaPskVendorIe(ieBuf: pointer, cipherType: uint8): pointer {.inline.} =
  let wpa = wpaPskVendorIeAt(ieBuf)
  wpa.ie.id = 0xDD'u8
  wpa.ie.len = 22'u8
  wpa.vendorType = [0x00'u8, 0x50'u8, 0xF2'u8, 0x01'u8]
  wpa.version = 1'u16
  wpa.groupCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: cipherType)
  wpa.pairwiseCount = 1'u16
  wpa.pairwiseCipher = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: cipherType)
  wpa.akmCount = 1'u16
  wpa.akmSuite = RsnSuiteView(oui: [0x00'u8, 0x50'u8, 0xF2'u8], suiteType: 2'u8)
  addr wpa.next[0]

proc writeCsaIe(ieBuf: pointer; switchMode, newChannel, switchCount: uint8): pointer {.inline.} =
  let csa = csaIeAt(ieBuf)
  csa.ie.id = 37'u8
  csa.ie.len = 3'u8
  csa.switchMode = switchMode
  csa.newChannel = newChannel
  csa.switchCount = switchCount
  addr csa.next[0]

proc me_add_ie_tim*(buf: pointer, dtimBitmap: uint8 = 0): uint32 {.exportc, cdecl.} =
  ## Add TIM IE (ID=5, length=4, total=6 bytes).
  ## buf is ptr-to-write-pointer (ptr-ptr pattern). Advances *buf by 6.
  ## dtimBitmap is stored at offset 3 (DTIM count field in blob).
  let bufPtr = cast[ptr pointer](buf)
  let tim = timIeAt(bufPtr[])
  tim.ie.id = 5'u8
  tim.ie.len = 4'u8
  tim.dtimCount = 0'u8
  tim.dtimPeriod = dtimBitmap
  tim.bitmapControl = 0'u8
  tim.partialBitmap[0] = 0'u8
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
  if ieData != nil and length != 0:
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
    for i in 0 ..< 128:
      challenge.challengeText[i] = src[i]
    return 136
  return 6

proc me_build_sae_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16,
    statusCode: uint16, vifIdx: uint32): uint32 {.exportc, cdecl.} =
  ## Build SAE authentication frame body.
  ## From blob (53 instrs): writes auth header (6 bytes), then loads SAE state
  ## from the VIF entry, calls SAE callback to get
  ## payload, copies to buf+6. Returns total length or 0 on failure.
  let body = cast[ptr AuthBodyDataView](buf)
  body.fixed.authAlgo = authAlgo
  body.fixed.authSeq = authSeq
  body.fixed.statusCode = statusCode

  # SAE payload: call WPA callback to get SAE frame data from VIF SAE context.
  # Blob: loads VIF entry, computes SAE context at vif+80, then calls
  # wpa_cbs[14] (offset 56 = func pointer for get_sae_frame) with context.
  let vif = vifChannelForIdx(vifIdx.uint8)
  let saeCtx = cast[pointer](addr vif.macAddr[0])

  if wpa_cbs != nil:
    let wpaCbArr = cast[ptr UncheckedArray[pointer]](wpa_cbs)
    let getSaeFrame = wpaCbArr[14]  # offset 56 = index 14
    if getSaeFrame != nil:
      type SaeFrameFn = proc(ctx: pointer, lenOut: ptr uint32): pointer {.cdecl.}
      var saeLen: uint32 = 0
      let saeData = cast[SaeFrameFn](getSaeFrame)(saeCtx, addr saeLen)
      if saeData != nil:
        discard c_memcpy(addr body.data[0], saeData, saeLen.csize_t)
        return saeLen + sizeof(AuthFixedBodyView).uint32
  return 0

proc me_build_associate_req_impl(buf: pointer, assocInfo: pointer,
    reassocBssid: pointer, capParam: pointer, cursorOut: pointer,
    bodyLenOut: pointer, connInfo: pointer): uint32 {.exportc: "me_build_associate_req", cdecl.} =
  ## Build association request frame body (159 instrs).
  ## Blob ABI: a0=body write pointer, a1=vif association info (vif+348),
  ## a2=reassociation BSSID or nil, a3=capability param (inst_nbr),
  ## a4=cursor out, a5=bodyLen out, a6=connect info.
  ##
  ## buf is the direct body write pointer. Writes: capability info (2B),
  ## listen interval (2B), optional BSSID (6B for reassoc), then appends IEs:
  ## SSID, Supported Rates, Extended Supported Rates, the prebuilt
  ## association/security IE block, HT Capabilities (if 11n), WMM, and
  ## vendor-specific IEs from sm_env.
  ## Returns total body length in a0 (via bodyLenOut).
  let assoc = vifAssocInfo(assocInfo)
  let secFlags = assoc.securityFlags

  # Read listen interval from connInfo+54 (a6+54 in blob), default 5.
  var listenInt: uint16 = 5
  if connInfo != nil:
    let li = connectInfoView(connInfo).listenInterval
    if li != 0:
      listenInt = li

  # Build capability info using the inst_nbr/capability parameter (a3).
  let capInfo = me_build_capability(capParam)

  # Write cap info at buf[0..1]. The blob receives a direct body pointer in a0,
  # then uses a stack-local pointer-to-pointer for the IE helper calls.
  let bufBase = cast[uint](buf)
  var writePtr = bufBase
  let fixedReq = cast[ptr AssocReqFixedBodyView](buf)
  fixedReq.capabilityInfo = capInfo
  fixedReq.listenInterval = listenInt

  # Check for reassoc (reassocBssid ptr != nil).
  # If present, copy 6 BSSID bytes and hdrSize becomes 10
  var hdrSize: uint = 4
  if reassocBssid != nil:
    discard c_memcpy(addr fixedReq.reassocBssid[0], reassocBssid, 6.csize_t)
    hdrSize = 10

  # Advance write pointer past header, store to the caller's cursor slot, and
  # use a local cursor for all IE helper ptr-to-write-pointer calls.
  writePtr += hdrSize
  var cursor = cast[pointer](writePtr)
  if cursorOut != nil:
    cast[ptr pointer](cursorOut)[] = cursor
  var totalLen: uint32 = hdrSize.uint32

  # Add SSID IE: blob uses assocInfo+38 (vif+386 len, vif+387 data).
  let ssidIeLen = me_add_ie_ssid(addr cursor,
    cast[pointer](addr assoc.ssidData[0]), assoc.ssidLen)
  totalLen += ssidIeLen

  # Add Supported Rates IE with rates pointer from assocInfo+88 (vif+436).
  let ratesPtr = cast[pointer](addr assoc.basicRates[0])
  let suppLen = me_add_ie_supp_rates(addr cursor, ratesPtr)
  totalLen += suppLen

  # Add Extended Supported Rates IE (if > 8 rates)
  let rateCount = assoc.basicRates[0]
  if rateCount > 8:
    let extLen = me_add_ie_ext_supp_rates(addr cursor, ratesPtr, rateCount.uint32)
    totalLen += extLen

  # Copy the prebuilt association/security IE block from assocInfo+144/+148.
  # The blob performs this copy before checking the capability flags.
  let assocIeSrc = cast[pointer](assoc.rsnIePtr)
  let assocIeLen = assoc.rsnIeLen.uint32
  nimFwDbgVifIeLenAtAssoc = assocIeLen or (cast[uint32](assocIeSrc) shl 8)
  if assocIeSrc != nil and assocIeLen != 0:
    discard c_memcpy(cursor, assocIeSrc, assocIeLen.csize_t)
    cursor = cast[pointer](cast[uint](cursor) + assocIeLen.uint)
    totalLen += assocIeLen
  nimFwTrace2U32("[WIFI-NIMFW] assoc_tx_sec ",
                 secFlags,
                 assocIeLen)

  # Emit WMM Information Element only (blob does NOT emit a separate QoS
  # Capability IE — just the 9-byte WMM IE which carries QoS Info at byte 8).
  # Blob: memcpy(scratch, .LANCHOR0, 10); conditionally overwrite scratch[8];
  # co_pack8p(buf, scratch, 9).
  if (secFlags and 1) != 0:
    let qosInfo =
      if connInfo != nil: connectInfoView(connInfo).qosInfo
      else: assoc.modeByte104
    let wmm = wmmInfoIeAt(cursor)
    wmm.ie.id = 0xDD'u8
    wmm.ie.len = 7'u8
    wmm.oui = [0x00'u8, 0x50, 0xF2]
    wmm.ouiType = 0x02'u8
    wmm.ouiSubtype = 0x00'u8
    wmm.version = 0x01'u8
    wmm.qosInfo = qosInfo
    cursor = addr wmm.next[0]
    totalLen += sizeof(WmmInfoIeView).uint32

  # Handle HT Capabilities IE (if bit 1 set in secFlags and me_env HT enabled).
  if (secFlags and 2) != 0:
    if meEnvView().htSupp != 0:
      let htLen = me_add_ie_ht_capa(addr cursor)
      totalLen += htLen

  # Append vendor-specific IE template (if any) from sm_env+48 / +52.
  # Blob: `lw a1,48(s1); beqz a1,.L72; lhu a2,52(s1); lw a0,12(sp);
  # call co_pack8p; lhu a5,52(s1); s0+=a5; advance write ptr`.
  let sm = smEnvView()
  if sm.vendorIePtr != nil:
    let vendorPtr = sm.vendorIePtr
    let vendorLen = sm.vendorIeLen
    let wp = cast[uint](cursor)
    co_pack8p(cast[pointer](wp), vendorPtr, vendorLen)
    cursor = cast[pointer](wp + vendorLen.uint)
    totalLen += vendorLen.uint32

  # Store association IE length. The return value is the full association
  # request body length, but the status message field is IE-only: blob stores
  # current cursor minus the initial cursor after fixed cap/listen fields.
  if cursorOut != nil:
    cast[ptr pointer](cursorOut)[] = cursor
  if bodyLenOut != nil:
    let endPtr = cast[uint](cursor)
    cast[ptr uint16](bodyLenOut)[] = cast[uint16](endPtr - writePtr)
  return totalLen

proc me_build_associate_rsp_impl(buf: pointer, staEntry: pointer,
    statusCode: uint16, aid: uint16): uint32 {.exportc: "me_build_associate_rsp", cdecl.} =
  ## Build association response frame body (166 instrs).
  ## Blob ABI: a0=buf_ctx (ptr-to-write-ptr), a1=vifIdx (passed as pointer but
  ## actually a small VIF index), a2=statusCode, a3=aid (or STA entry pointer).
  ## Writes: cap info (2B), status code (2B), AID (2B), then Supported Rates,
  ## Ext Rates, HT Cap, HT Oper, WMM Parameter, and BSS Max Idle Period IEs.
  ## Returns total length in a0.
  # staEntry parameter is actually used as VIF index in the blob
  # (me_build_capability(a0=a1) where a1 is the VIF index).
  # The blob computes the VIF entry from a1.
  let vifIdx = cast[uint](staEntry)
  let vif = vifChannelForIdx(vifIdx.uint8)
  let apCfg = vifApConfig(vif)
  let privacy = apCfg.privacyFlag

  # Build capability info using VIF index
  var capInfo = me_build_capability(staEntry)  # staEntry is really vifIdx
  if privacy != 0:
    capInfo = capInfo or 16

  var writePtr = cast[uint](cast[ptr pointer](buf)[])
  let fixedRsp = cast[ptr AssocRspFixedBodyView](cast[pointer](writePtr))
  fixedRsp.capabilityInfo = capInfo
  fixedRsp.statusCode = statusCode

  # Write AID with 2 MSBs set (LE16). Blob's a3 is the APM STA-add payload
  # pointer even though this compatibility wrapper receives it as uint16.
  let staAdd = cast[ptr ApmAssocStaAddIndPayload](cast[uint](aid))
  let aidVal = staAdd.aid
  let aidField = aidVal or 0xC000'u16
  fixedRsp.aid = aidField

  writePtr += 6
  cast[ptr pointer](buf)[] = cast[pointer](writePtr)
  var totalLen: uint32 = 6

  # Add Supported Rates IE -- rates from STA entry at staEntry+6
  # Blob: addi a1, s2, 6 where s2=a3=staEntry
  let ratesPtr = cast[pointer](addr staAdd.rateCount)
  totalLen += me_add_ie_supp_rates(buf, ratesPtr)

  # Add Extended Supported Rates if > 8 rates
  # Blob: lbu a4, 6(s2) -> rate count from staEntry+6 (first byte of rates struct)
  let rateCount = staAdd.rateCount
  if rateCount > 8:
    totalLen += me_add_ie_ext_supp_rates(buf, ratesPtr, rateCount.uint32)

  # Check STA HT capabilities from staEntry+64 (blob: lw a5, 64(s2))
  let staCap = staAdd.flags
  if (staCap and 2) != 0:
    # Add HT Capabilities IE
    totalLen += me_add_ie_ht_capa(buf)

    # Add HT Operation IE with VIF entry for channel context
    totalLen += me_add_ie_ht_oper(buf, cast[pointer](vif))

  # Check WMM capabilities (bit 0 of staCap from staEntry+64)
  if (staCap and 1) != 0:
    # Write WMM Parameter Element (IEEE 802.11 vendor-specific IE)
    let bufPtrPtr = cast[ptr pointer](buf)
    let wmm = wmmParameterIeAt(bufPtrPtr[])
    let wmmSrc = mmWmmParameterSource()
    wmm.ie.id = 0xDD'u8
    wmm.ie.len = 0x18'u8
    wmm.oui = [0x00'u8, 0x50, 0xF2]
    wmm.ouiType = 0x02'u8
    wmm.ouiSubtype = 0x01'u8
    wmm.version = 0x01'u8
    wmm.qosInfo = vif.wmmQosInfo
    wmm.reserved9 = 0
    wmm.ac[0].setLe32(wmmSrc.acBe)
    wmm.ac[1].setLe32(wmmSrc.acBk)
    wmm.ac[2].setLe32(wmmSrc.acVi)
    wmm.ac[3].setLe32(wmmSrc.acVo)

    let wmmLen = sizeof(WmmParameterIeView).uint32
    bufPtrPtr[] = addr wmm.next[0]
    totalLen += wmmLen

    # BSS Max Idle Period IE (ID=90, Length=3)
    let bssMaxIdle = bssMaxIdlePeriodIeAt(bufPtrPtr[])
    bssMaxIdle.ie.id = 90'u8
    bssMaxIdle.ie.len = 3'u8
    bssMaxIdle.idlePeriod = wmmSrc.idlePeriod
    bssMaxIdle.idleOptions = wmmSrc.idleOptions
    bufPtrPtr[] = addr bssMaxIdle.next[0]
    totalLen += sizeof(BssMaxIdlePeriodIeView).uint32

  return totalLen

proc me_build_deauthenticate*(buf: pointer, reason: uint16): uint32 {.exportc, cdecl, noinline.} =
  ## Build deauthentication frame body (2 bytes: reason code LE16).
  ## From blob (5 instrs): a0=buf, a1=reason_code(u16).
  ## Writes reason_code as LE16 at buf[0..1]. Returns 2.
  ## noinline: blob calls this as a real function.
  managementReasonBodyAt(buf).reason = reason
  return 2

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
  discard me_add_ie_ssid(addr ieBuf, ssidArgPtr, ssidArgLen)

  # bodyLen tracks total from the IE start (buf) including the 36-byte header
  var bodyLen: uint32 = cast[uint32](cast[uint](ieBuf) - cast[uint](buf))

  # Add Supported Rates IE -- pass rates pointer from VIF+436
  let ratesPtr = cast[pointer](addr vif.basicRates[0])
  bodyLen += me_add_ie_supp_rates(addr ieBuf, ratesPtr)

  # Add Extended Supported Rates if > 8 rates
  let rateCount = vif.basicRates[0]
  if rateCount > 8:
    bodyLen += me_add_ie_ext_supp_rates(addr ieBuf, ratesPtr, rateCount.uint32)

  # Add DS Parameter Set IE: compute channel from VIF channel frequency
  # Blob computes: channel = ((freq - 2412) / 5) + 1 for 2.4GHz
  let chanPtr = vif.operChan
  let chan = cast[ptr ScanChannelEntry](chanPtr)
  let chanFreq = chan.prim20Freq
  let chanNum = (((chanFreq.int - 2412) div 5) + 1).uint8
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

  # Add WPA/RSN IE from VIF+492 (pre-built IE pointer) if present
  let sec = vifSecurity(vif)
  let wpaIePtr = cast[pointer](sec.rsnIePtr)
  if wpaIePtr != nil:
    let wpaIeLen = sec.rsnIeLen
    ieBuf = copyIeBytes(ieBuf, wpaIePtr, wpaIeLen.uint)
    bodyLen += wpaIeLen.uint32

  # Add ERP IE (blob: li a1,0 -> no protection)
  bodyLen += me_add_ie_erp(addr ieBuf, 0)

  let flagsWord = apCfg.securityFlags
  if (flagsWord and 2) != 0:
    # NOTE: Blob does NOT call me_add_ie_rsn in me_build_beacon (only in me_build_probe_rsp).
    # Add vendor WPA IE -- blob passes vif entry base as a1 for secMode lookup
    bodyLen += me_add_ie_wpa(addr ieBuf, 2)

  # Add HT Capabilities IE (always present for 11n AP)
  bodyLen += me_add_ie_ht_capa(addr ieBuf)

  # Add HT Operation IE
  bodyLen += me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))

  # Build WPA1 vendor IE inline if flagsWord bit 0 is set (from blob)
  if (flagsWord and 1) != 0:
    let cipherType = vifWpaCipher(vif)
    ieBuf = writeWpaPskVendorIe(ieBuf, cipherType)
    bodyLen += 24

  # Add CSA IE if channel switch is pending (blob: co_pack8p at 0x26e)
  # Gate: chan_ctxt slot[14] != 0xFF indicates a pending CSA.
  let chanCtxPtr = vif.chanCtxt
  if chanCtxPtr != nil:
    let chanCtx = chanCtxtAt(chanCtxPtr)
    let csaCount = chanCtx.invalidMarker
    if csaCount != 0xFF and csaCount != 0:
      # Blob uses T-Head custom insns to compute the channel inline.
      # For 2.4GHz, chan = ((freq - 2412) / 5) + 1. Inlining avoids the
      # phy_freq_to_channel call that blob doesn't emit from the CSA path.
      let csaFreq = chanCtx.channel.primFreq
      let csaChannel = ((csaFreq.int - 2412) div 5 + 1).uint8
      ieBuf = writeCsaIe(ieBuf, chanCtx.channel.txPower, csaChannel, csaCount)
      bodyLen += 5

  # Add application beacon IEs if registered
  if appIeBeaconLen > 0 and appIeBeaconPtr != nil:
    ieBuf = copyIeBytes(ieBuf, appIeBeaconPtr, appIeBeaconLen.uint)
    bodyLen += appIeBeaconLen.uint32

  return bodyLen

proc me_build_probe_rsp*(buf: pointer, vifIdx: uint8,
                      lenOut: ptr uint16): uint32 {.exportc, cdecl.} =
  ## Build probe response frame IEs.
  ## From blob (202 instrs): builds probe response frame body.
  ## buf points to the probe response body (after MAC header).
  ## Writes: timestamp(8B, not written here), beacon_interval(2B at +8),
  ## capability(2B at +10), then IEs from offset 12.
  ## Nearly identical to beacon but without TIM IE, uses phy_freq_to_channel
  ## for DS param, and passes privacy to ERP IE.
  ## Returns total body length.
  let vif = vifChannelForIdx(vifIdx)
  let apCfg = vifApConfig(vif)
  let privacy = apCfg.privacyFlag
  let frame = probeRspFixedBodyView(buf)

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
  var bodyLen: uint32 = me_add_ie_ssid(addr ieBuf, ssidDataPtr, ssidLen)

  # Add Supported Rates IE -- pass rates pointer from VIF+436
  let ratesPtr = cast[pointer](addr vif.basicRates[0])
  bodyLen += me_add_ie_supp_rates(addr ieBuf, ratesPtr)

  # Add Extended Supported Rates if > 8 rates
  let rateCount = vif.basicRates[0]
  if rateCount > 8:
    bodyLen += me_add_ie_ext_supp_rates(addr ieBuf, ratesPtr, rateCount.uint32)

  # Add 12 for the header (timestamp+interval+capability = 12 bytes)
  # Blob: addi s0,s0,12 at this point
  bodyLen += 12

  # Add DS Parameter Set IE: use phy_freq_to_channel (unlike beacon which
  # computes inline). Blob: lbu a0,2(a5) -> band; lhu a1,0(a5) -> freq;
  # call phy_freq_to_channel
  let chanPtr = vif.operChan
  let chan = cast[ptr ScanChannelEntry](chanPtr)
  let chanFreq = chan.prim20Freq
  let chanBand = chan.band
  let chanNum = phy_freq_to_channel(chanBand, chanFreq)
  let dsLen = me_add_ie_ds(addr ieBuf, chanNum)

  # Add RSN IE unconditionally (blob: a1=privacy as secMode, at reloc 0xee)
  # privacy from VIF+520 is passed as secMode; me_add_ie_rsn returns 0 if secMode==0
  let rsnLen = me_add_ie_rsn(addr ieBuf, privacy)

  # Add ERP IE (blob: a1=0, at reloc 0xfc)
  let erpLen = me_add_ie_erp(addr ieBuf, 0)

  # Accumulate ds+rsn+erp into bodyLen
  let flagsWord = apCfg.securityFlags
  bodyLen += dsLen + rsnLen + erpLen

  # Add HT Capabilities + HT Operation IEs (conditional on flagsWord bit 1)
  # Blob: beqz flagsWord&2 → skip HT IEs, jump to me_add_ie_wpa
  if (flagsWord and 2) != 0:
    bodyLen += me_add_ie_ht_capa(addr ieBuf)
    bodyLen += me_add_ie_ht_oper(addr ieBuf, cast[pointer](vif))

  # Add WPA IE unconditionally (blob: a1=privacy as secMode, reloc 0x13e)
  bodyLen += me_add_ie_wpa(addr ieBuf, privacy)

  # Check WPA1 flag at VIF+484 bit 0 (from blob: 0x15e-0x260)
  if (flagsWord and 1) != 0:
    # Build WPA1 vendor IE inline (blob builds 4 cipher suites from VIF crypto state)
    # WPA OUI: 00-50-F2-01, version 1, group cipher, unicast cipher count
    let cipherType = vifWpaCipher(vif)
    ieBuf = writeWpaPskVendorIe(ieBuf, cipherType)
    bodyLen += 24

  # Add CSA IE if channel switch is pending (blob: co_pack8p at 0x192)
  let chanCtxPtr = vif.chanCtxt
  if chanCtxPtr != nil:
    let chanCtx = chanCtxtAt(chanCtxPtr)
    let csaCount = chanCtx.invalidMarker
    if csaCount != 0xFF and csaCount != 0:
      # Blob uses T-Head custom insns to compute the channel inline.
      # For 2.4GHz, chan = ((freq - 2412) / 5) + 1. Inlining avoids the
      # phy_freq_to_channel call that blob doesn't emit from the CSA path.
      let csaFreq = chanCtx.channel.primFreq
      let csaChannel = ((csaFreq.int - 2412) div 5 + 1).uint8
      ieBuf = writeCsaIe(ieBuf, chanCtx.channel.txPower, csaChannel, csaCount)
      bodyLen += 5

  # Add application probe response IEs if registered
  if appIeProbeRespLen > 0 and appIeProbeRespPtr != nil:
    ieBuf = copyIeBytes(ieBuf, appIeProbeRespPtr, appIeProbeRespLen.uint)
    bodyLen += appIeProbeRespLen.uint32

  # Write total length output
  if lenOut != nil:
    lenOut[] = bodyLen.uint16

  return bodyLen

proc me_build_add_ba_req*(buf: pointer, param: pointer): uint32 {.exportc, cdecl.} =
  ## Build ADDBA Request action frame body (9 bytes).
  ## From blob (30 instrs): a0=buf, a1=BA params struct.
  ## Struct offsets: [8]=SSN(u16), [10]=BA_timeout(u16), [14]=amsdu_supported(u8),
  ## [15]=buffer_size(u8), [16]=TID(u8), [17]=dialog_token(u8).
  ## Frame: [0]=category(3), [1]=action(0=ADDBA_REQ), [2]=dialog_token,
  ## [3..4]=BA_param_set(LE16), [5..6]=BA_timeout(LE16), [7..8]=start_seq(LE16).
  let body = addBaReqActionBodyAt(buf)
  body.category = 3  # Block Ack
  body.action = 0    # ADDBA Request
  if param == nil:
    return 9
  let req = meAddBaReqParamView(param)
  body.dialogToken = req.dialogToken
  # BA Parameter Set: bit0=amsdu, bits1-4=TID, bits6-15=buffer_size
  let amsdu = req.amsduSupported.uint16 shl 1
  let tid = req.tid.uint16 shl 2
  let bufSize = req.bufferSize.uint16 shl 6
  body.baParams = amsdu or tid or bufSize
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
  let body = delBaActionBodyAt(buf)
  body.category = 3  # Block Ack
  body.action = 2    # DELBA
  # Build DELBA Parameter Set
  var delbaParams: uint16 = 0
  if baInfo != nil:
    let info = delBaInfoView(baInfo)
    delbaParams = info.tid.uint16 shl 12
    if info.initiator == 1:
      delbaParams = delbaParams or 0x0800'u16  # set initiator bit
  body.delbaParams = delbaParams
  body.reasonCode = reasonCode
  return 6

proc me_build_capability*(param: pointer): uint16 {.exportc, cdecl.} =
  ## Build capability information field.
  ## From blob (14 instrs): param is vifIdx (uint8 in a0).
  ## Computes VIF entry, checks type. For STA (type 0), reads capability info
  ## from vif[434] to determine short preamble (bit 4) and short slot (bit 5).
  ## Always sets ESS (bit 0) and privacy (bit 10).
  let vifIdx = encodedArgU8(param)
  let vif = vifChannelForIdx(vifIdx)
  var cap = 1'u16  # ESS bit
  let vifType = vif.vifType
  if vifType == VIF_TYPE_STA:
    let beaconCap = vif.capabilityInfo
    if (beaconCap and 0x10) != 0:  # short preamble
      cap = cap or 0x10
    if (beaconCap and 0x20) != 0:  # short slot time
      cap = cap or 0x20
  cap = cap or 0x400  # privacy bit
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

proc me_legacy_rate_bitfield_build*(rates: pointer, count: uint8): uint32 {.exportc, cdecl.} =
  ## Build legacy rate bitfield from supported rates array (55 instructions in blob).
  ## Iterates count entries from rates array (each u8 at rates[1+i], with rates[0]
  ## being the rate count prefix). For each rate, masks to 7 bits (removing basic
  ## rate flag bit 7), calls me_rate_translate to get the index (0..11), and if
  ## the index <= 11, sets (1 << index) in the result bitfield.
  ## Asserts at line 411 if me_rate_translate returns > 11.
  var bitfield: uint32 = 0
  let rateSet = rateSetAt(rates)
  # The blob reads loop count from rates[0] (the rate count byte in the struct).
  # count parameter (a1) is used as a flag: when non-zero, extra rate filtering
  # is applied via custom instructions. When zero, all rates are included.
  let rateCount = rateSet.count.int
  var i: int = 0
  while i < rateCount:
    # Each rate byte is at rates[1+i]; mask off basic rate flag (bit 7)
    let rateByte = rateSet.rates[i] and 0x7F
    let rateIdx = me_rate_translate(rateByte.uint32)
    if rateIdx <= 11:
      bitfield = bitfield or (1'u32 shl rateIdx)
    else:
      assert_warn("me.c", "me.c", 411.cint)
    i += 1
  return bitfield

proc me_legacy_ridx_min*(bitfield: uint32): uint8 {.exportc, cdecl.} =
  ## Get minimum legacy rate index.
  ## From blob (10 instrs): scans bitfield from bit 0 upward, returns index of
  ## first set bit. Returns 12 if no bits set.
  for i in 0'u32 ..< 12:
    if ((bitfield shr i) and 1) != 0:
      return i.uint8
  return 12

proc me_legacy_ridx_max*(bitfield: uint32): uint8 {.exportc, cdecl.} =
  ## Get maximum legacy rate index.
  ## From blob (15 instrs): scans bitfield from bit 11 downward, returns index
  ## of highest set bit. Returns 12 if no bits set.
  if bitfield == 0:
    return 12
  for i in countdown(11'i32, 0):
    if ((bitfield shr i.uint32) and 1) != 0:
      return i.uint8
  return 12

proc me_rate_bitfield_vht_build*(param: pointer): uint32 {.exportc, cdecl.} =
  ## Build VHT rate bitfield.
  ## From blob (22 instrs): param is rxMcsMap (uint32 in a0), a1=txMcsMap.
  ## Iterates 8 NSS groups (2 bits each), for each: if either rx or tx field == 3,
  ## stop. Otherwise, takes the minimum of rx and tx MCS and inserts into result.
  ## Returns the combined supported MCS map (16-bit, 0xFFFF init).
  let rxMap = cast[uint32](param)
  # txMap would be in a1 (second C arg), but not visible in Nim
  # For single-arg Nim callers, return rxMap clamped to valid entries
  var res = 0xFFFF'u32
  var shift = 0'u32
  while shift < 16:
    let rxField = (rxMap shr shift) and 3
    if rxField == 3:
      break
    let mask = not (3'u32 shl shift)
    res = (res and mask) or (rxField shl shift)
    shift += 2
  return res

proc me_get_basic_rates*(vifIdx: uint8): uint32 {.exportc, cdecl.} =
  ## Get basic rate set for a VIF (16 instrs).
  ## From blob: a0=rate_set_ptr, a1=output_buf_ptr via C ABI.
  ## Clears output[0] to 0. Iterates rate_set[0] entries (count at rate_set[0]),
  ## reads rate_set[i+1] for each. If bit 7 set (basic rate), sign-extends,
  ## copies to output[output[0]+1], increments output[0].
  var outputBuf: pointer
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", outputBuf, ") );"].}
  let rateSet = rateSetAt(cast[pointer](vifIdx))  # a0 = rate_set_ptr
  let output = rateSetAt(outputBuf)
  # Clear output count
  output.count = 0
  # Iterate rate set
  let rateCount = rateSet.count
  var i: uint8 = 0
  while i < rateCount:
    let rate = rateSet.rates[i]
    # Sign-extend byte to check bit 7 (basic rate indicator)
    let sextRate = cast[int8](rate)
    if sextRate < 0:  # bit 7 set = basic rate
      let curCount = output.count
      output.rates[curCount] = rate
      output.count = curCount + 1
    i += 1
  return 0

proc me_freq_to_chan_ptr*(band: uint8, freq: uint16): pointer {.exportc, cdecl.} =
  ## Convert band+frequency to channel context pointer — blob me_mgmtframe.o
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
  let chanConfig = meChannelConfigView()
  for i in 0 ..< chanConfig.count.int:
    let entry = addr chanConfig.entries[i]
    if entry.freq == freq:
      return cast[pointer](entry)
  return nil

proc me_extract_rate_set*(ieBuf: pointer, ieLen: uint32, rateOut: pointer) {.exportc, cdecl.} =
  ## Extract supported rate set from received frame IEs (68 instrs).
  ## Finds Supported Rates IE (ID=1) and Extended Supported Rates IE (ID=50),
  ## copies rate bytes into rateOut[1..N], stores count in rateOut[0].
  ## Rate byte format: bit7=basic flag, bits[6:0]=rate in 0.5Mbps units.
  ## rateOut layout: [0]=count, [1..count]=rate bytes (max 12 total).
  let out_arr = cast[ptr UncheckedArray[uint8]](rateOut)
  out_arr[0] = 0  # initialize count

  # Find Supported Rates IE (ID=1)
  let suppRatesIe = mac_ie_find(ieBuf, ieLen, 1)
  if suppRatesIe == nil:
    return

  let sr = cast[ptr MacIeView](suppRatesIe)
  let srRates = sr.macIePayload
  let srCount = sr.len  # IE length = number of rate bytes
  if srCount > 12:
    return  # malformed: too many rates

  # Copy supported rates (strip to 7-bit rate value, keeping basic bit)
  var writePos: uint8 = 1  # rateOut[1] is first rate
  var i: uint8 = 0
  while i < srCount:
    let rateByte = srRates[i]
    # Store byte at writePos, using indexed store like the blob
    out_arr[writePos] = rateByte
    writePos += 1
    i += 1
  out_arr[0] = srCount

  # Find Extended Supported Rates IE (ID=50)
  let extRatesIe = mac_ie_find(ieBuf, ieLen, 50)
  if extRatesIe == nil:
    return

  let er = cast[ptr MacIeView](extRatesIe)
  let erRates = er.macIePayload
  let erCount = er.len
  let totalCount = out_arr[0].uint + erCount.uint
  if totalCount > 12:
    # assert_err but blob just bounds-checks and exits
    assert_err("me_mgmtframe.c", "me_mgmtframe.c", 897)
    if out_arr[0].int + erCount.int > 12:
      return  # too many rates combined

  # Append extended rates starting at rateOut[srCount+1]
  var j: uint8 = 0
  while j < erCount:
    let rateByte = erRates[j]
    let dstOff = out_arr[0] + 1 + j  # rateOut offset
    out_arr[dstOff] = rateByte
    j += 1
  out_arr[0] = out_arr[0] + erCount

proc me_extract_country_reg*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.} =
  ## Extract country/regulatory information from frame IEs (46 instructions in blob).
  ## Searches for Country IE (ID=7). If not found, returns immediately.
  ## If found:
  ##   - Loads regulatory data from out_ptr[76] (channel reg struct pointer).
  ##   - Reads environment byte from chanReg[2]: if non-zero, envStep=4, else envStep=1.
  ##   - Reads country code halfword from chanReg[0..1] and calls phy_channel_to_freq
  ##     to get the target channel.
  ##   - Iterates IE triplets (starting at IE+5, stride 3): each triplet is
  ##     (firstChan, numChan, maxPower). For each triplet, iterates numChan channels
  ##     (incrementing firstChan by envStep). When a channel matches the target,
  ##     stores maxPower at chanReg[4].
  let ie = mac_ie_find(ieBuf, ieLen, 7)  # Country IE = ID 7
  if ie == nil:
    return

  # out_ptr+76 (0x4C) points to the channel regulatory struct
  let chanReg = countryRegAt(countryRegOutputAt(out_ptr).channelReg)

  # Read environment byte from chanReg[2] (not from IE!)
  let envByte = chanReg.environment
  var envStep: uint8 = 1
  if envByte != 0:
    envStep = 4

  # Read country code from chanReg[0..1] and get target channel
  let targetChan = phy_freq_to_channel(chanReg.countryHalf.uint8, envStep.uint16)
  let targetChanU8 = targetChan

  # IE data: [0]=id, [1]=len, then data starts at [2].
  # Country IE data: [2..3]=country code string, [4]=environment, [5..]=triplets
  let countryIe = cast[ptr MacIeView](ie)
  let ieLength = countryIe.len
  var pos: uint8 = 5  # first triplet starts at IE+5

  while pos.int < ieLength.int + 2:  # while within IE bounds (id+len+data)
    let payloadOff = pos - 2
    let triplet = countryTripletAt(addr countryIe.macIePayload[payloadOff])
    var firstChan = triplet.firstChan

    # Iterate through all channels in this triplet
    var chanIdx: uint8 = 0
    while chanIdx != triplet.numChan:
      if firstChan == targetChanU8:
        # Match found: store max power from triplet byte 2
        chanReg.maxPower = triplet.maxPower
        return
      firstChan = firstChan + envStep
      chanIdx += 1

    pos += 3

proc me_extract_csa*(ieBuf: pointer, ieLen: uint32, band: pointer,
                     csaOut: pointer) {.exportc, cdecl.} =
  ## Extract Channel Switch Announcement from beacon IEs (117 instrs).
  ## a0=ieBuf, a1=ieLen, a2=band ptr, a3=csaOut (8-byte output struct).
  ##
  ## Searches for CSA IE (ID=37), Extended CSA IE (ID=60), Secondary Channel
  ## Offset IE (ID=62), and Wide Bandwidth Channel Switch IE (ID=194,
  ## vendor-specific wrapper). Extracts new channel, switch mode, switch count,
  ## secondary offset, and computes new channel frequency via phy_channel_to_freq.
  ##
  ## csaOut layout: [0]=u8 csa_present, [1]=u8 sec_chan_offset, [2]=u16 freq,
  ##   [4]=u16 new_freq, [6]=u16 bw_freq.
  let csaResult = cast[ptr CsaOutputView](csaOut)

  # Find CSA IE (ID=37) and Extended CSA IE (ID=60)
  let csaIe = mac_ie_find(ieBuf, ieLen, 37)
  let ecsaIe = mac_ie_find(ieBuf, ieLen, 60)

  # If neither found, return 0 (no CSA)
  if csaIe == nil and ecsaIe == nil:
    return  # a0=0 in blob means no CSA

  # Find Secondary Channel Offset IE (ID=62) and Wide BW CS IE (ID=194)
  let secChanIe = mac_ie_find(ieBuf, ieLen, 62)

  # Find vendor-specific Wide BW Channel Switch (ID=194 within subelement)
  let wbcsIe = mac_ie_find(ieBuf, ieLen, 196)
  var wbcsInner: pointer = nil
  if wbcsIe != nil:
    # Look inside for sub-element with ID=194
    let wbcs = cast[ptr MacIeView](wbcsIe)
    wbcsInner = mac_ie_find(cast[pointer](wbcs.macIePayload),
                            wbcs.len.uint32, 194)

  # Extract CSA fields
  var newChan: uint8
  var switchCount: uint8
  var switchMode: uint8
  var secOffset: uint8 = 0
  let bandVal = cast[ptr uint8](band)[]

  if csaIe != nil:
    # CSA IE format: [2]=switch_mode, [3]=new_channel, [4]=switch_count
    let ie = cast[ptr CsaIeView](csaIe)
    switchMode = ie.switchMode
    newChan = ie.newChannel
    switchCount = ie.switchCount
  else:
    # Extended CSA IE: [2]=switch_mode, [4]=new_channel, [5]=switch_count
    let ie = cast[ptr ExtendedCsaIeView](ecsaIe)
    switchMode = ie.switchMode
    newChan = ie.newChannel
    switchCount = ie.switchCount

  # If switch count is 0, default to 2
  if switchCount == 0:
    switchCount = 2

  # Determine if mode indicates immediate switch
  var csaPresent: uint8
  if switchMode >= 15:
    csaPresent = 1
  else:
    csaPresent = 0

  # Get frequency for new channel
  let newFreq = phy_channel_to_freq(bandVal, newChan)

  # Process secondary channel offset
  if secChanIe != nil:
    let scIe = cast[ptr SecondaryChannelOffsetIeView](secChanIe)
    let scMode = scIe.mode
    secOffset = scMode
    # Validate: mode must be 1..3
    let modeAdj = scMode - 1
    if modeAdj <= 2:
      secOffset = scMode + 1
  elif wbcsInner != nil:
    # Wide BW Channel Switch sub-element
    let wbIe = cast[ptr WideBandwidthChannelSwitchIeView](wbcsInner)
    let bwType = wbIe.bandwidthType
    var bwFreqOffset: int16 = 0
    if bwType == 1:
      bwFreqOffset = 10
    elif bwType == 3:
      bwFreqOffset = -10

    let bwFreq = phy_channel_to_freq(bandVal, wbIe.centerFreq1)
    let freq0: uint16 = 0
    if wbIe.centerFreq2 != 0:
      discard phy_channel_to_freq(bandVal, wbIe.centerFreq2)

    csaResult.bwFreq = bwFreq
    secOffset = 1  # default offset when wide BW present

  # Fill output struct
  csaResult.csaPresent = csaPresent
  csaResult.secChanOffset = secOffset
  csaResult.freq = newFreq
  csaResult.newFreq = 0  # reserved/new_freq

proc me_extract_power_constraint*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.} =
  ## Extract power constraint from frame IEs (14 instructions in blob).
  ## Searches for IE with ID=32 (Power Constraint). If found, reads byte at
  ## IE+2 (the constraint value) and stores it in the blob output overlay
  ## constraint slot at out_ptr+132 (0x84).
  ## If not found, stores 0 at that offset.
  let ie = mac_ie_find(ieBuf, ieLen, 32)
  var constraintVal: uint8 = 0
  if ie != nil:
    constraintVal = cast[ptr MacIeView](ie).macIePayload[0]
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
    let field = (mcsMap shr shift) and 3
    if field != 3:
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

proc michael_block*(ctx: pointer, val: uint32) {.exportc, cdecl.} =
  ## Michael MIC block function (TKIP).
  ## ctx layout: [0]=uint32 L, [4]=uint32 R.
  ## From blob (43 instrs): XOR val into L, then perform the Michael
  ## permutation rounds: XSWAP, XOR, rotate, add operations.
  let mic = michaelMicContextAt(ctx)
  var L = mic.left
  var R = mic.right

  L = L xor val

  # Round 1: R ^= rotl(L, 17)
  R = R xor ((L shl 17) or (L shr 15))
  L = L + R

  # Round 2: byte-swap L (swap bytes 0,2 and 1,3 within halves)
  # Michael XSWAP: swap bytes within 16-bit halves
  let swapped = ((L and 0x00FF00FF'u32) shl 8) or
                ((L and 0xFF00FF00'u32) shr 8)
  L = swapped xor R

  # Round 3: R ^= rotl(L, 3)
  L = L + R
  R = R xor ((L shl 3) or (L shr 29))

  # Round 4: L ^= rotr(R, 2)  i.e., R ^= (L >> 2)
  L = L + R
  R = R xor ((L shr 2) or (L shl 30))

  L = L + R

  mic.left = R
  mic.right = L

proc me_mic_init*(micCtx: pointer, key: pointer, sa: pointer, da: pointer,
                  priority: uint8) {.exportc, cdecl.} =
  ## Initialize Michael MIC calculation (66 instrs).
  ## a0=micCtx, a1=key (8 bytes), a2=sa (6 bytes), a3=da (6 bytes), a4=priority.
  ## micCtx layout: [0]=L, [4]=R, [8]=pending, [12]=nBytes.
  ## Loads key into L,R, then processes a2[0..5] || a3[0..5] || priority
  ## via four michael_block calls.
  let ctx = micCtx
  let mic = michaelMicContextAt(ctx)

  # Load key words into ctx
  mic.left = cast[ptr uint32](key)[]
  mic.right = cast[ptr UncheckedArray[uint32]](key)[1]
  mic.pending = 0
  mic.nBytes = 0

  # Build packed LE32 words from sa (a2) and da (a3) per blob byte-build sequence
  let a2 = cast[ptr UncheckedArray[uint8]](sa)
  let a3 = cast[ptr UncheckedArray[uint8]](da)

  let word0 = a2[0].uint32 or (a2[1].uint32 shl 8) or
              (a2[2].uint32 shl 16) or (a2[3].uint32 shl 24)
  let word1 = (a2[4].uint32 or (a2[5].uint32 shl 8)) or
              ((a3[0].uint32 or (a3[1].uint32 shl 8)) shl 16)
  let word2 = a3[2].uint32 or (a3[3].uint32 shl 8) or
              (a3[4].uint32 shl 16) or (a3[5].uint32 shl 24)

  var prio2: uint32 = priority.uint32 and 7
  if priority == 0xFF:
    prio2 = 0

  michael_block(ctx, word0)
  michael_block(ctx, word1)
  michael_block(ctx, word2)
  michael_block(ctx, prio2)

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
  let buf = cast[ptr UncheckedArray[uint8]](data)
  var nBytes = mic.nBytes
  var pending = mic.pending
  var offset: uint32 = 0
  var remaining = dataLen

  # Handle unaligned start: fill pending word up to 4 bytes
  if nBytes > 0 and remaining > 0:
    let needed = 4'u32 - nBytes.uint32
    let toProcess = if remaining < needed: remaining else: needed
    for i in 0'u32 ..< toProcess:
      pending = pending or (buf[offset].uint32 shl (nBytes.uint32 * 8))
      nBytes += 1
      offset += 1
      remaining -= 1
    if nBytes >= 4:
      michael_block(ctx, pending)
      pending = 0
      nBytes = 0

  # Process bulk 4-byte words (single michael_block call site per loop,
  # matching blob's structure).
  while remaining >= 4:
    let word = buf[offset].uint32 or
               (buf[offset + 1].uint32 shl 8) or
               (buf[offset + 2].uint32 shl 16) or
               (buf[offset + 3].uint32 shl 24)
    let blockIn = if nBytes > 0: pending or (word shl (nBytes.uint32 * 8))
                  else: word
    michael_block(ctx, blockIn)
    pending = if nBytes > 0: word shr ((4 - nBytes.uint32) * 8) else: 0
    offset += 4
    remaining -= 4

  # Handle remaining bytes
  for i in 0'u32 ..< remaining:
    pending = pending or (buf[offset].uint32 shl (nBytes.uint32 * 8))
    nBytes += 1
    offset += 1
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
  # Pad with 0x5A at the current byte position
  let padShift = nBytes.uint32 * 8
  let padded = pending or (0x5A'u32 shl padShift)
  michael_block(ctx, padded)
  # Final block with zero
  michael_block(ctx, 0)

