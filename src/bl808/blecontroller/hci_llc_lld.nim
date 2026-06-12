# ======================== HCI =============================================
# ---------------------------------------------------------------------------

proc hci_fc_init*() {.exportc, cdecl.}

proc hci_init*(reset: bool) {.exportc, cdecl.} =
  ## Initialize HCI layer
  discard c_memset(addr hci_env[0], 0, sizeof(hci_env).csize_t)
  discard c_memset(addr hci_evt_mask[0], 0xFF, sizeof(hci_evt_mask).csize_t)
  discard c_memset(addr hci_le_evt_mask[0], 0xFF, sizeof(hci_le_evt_mask).csize_t)
  hci_fc_init()

proc hci_reset*() {.exportc, cdecl.} =
  ## Reset HCI layer
  hci_init(true)

proc hci_tl_init*() {.exportc, cdecl.} =
  ## Initialize HCI transport layer
  discard

proc hci_tl_send*(transportPacket: pointer, packetLen: uint16): bool {.exportc, cdecl.} =
  ## Send data over HCI transport
  return true

proc hci_fc_init*() {.exportc, cdecl.} =
  hci_fc_env.acl_pkt_nb = 0
  hci_fc_env.acl_buf_size = 0
  hci_fc_env.flow_en = false

proc hci_fc_acl_buf_size_set*(size: uint16) {.exportc, cdecl.} =
  hci_fc_env.acl_buf_size = size

proc hci_fc_acl_en*(en: bool) {.exportc, cdecl.} =
  hci_fc_env.flow_en = en

proc hci_fc_acl_packet_sent*() {.exportc, cdecl.} =
  if hci_fc_env.acl_pkt_nb > 0:
    dec hci_fc_env.acl_pkt_nb

proc hci_fc_check_host_available_nb_acl_packets*(): bool {.exportc, cdecl.} =
  if not hci_fc_env.flow_en:
    return true
  return hci_fc_env.acl_pkt_nb > 0

proc hci_fc_host_nb_acl_pkts_complete*(nb: uint16) {.exportc, cdecl.} =
  hci_fc_env.acl_pkt_nb = hci_fc_env.acl_pkt_nb + nb

proc completeHciCommand(opcode: uint16, params: ptr uint8,
                        paramLen: uint8): uint8 =
  nim_hci_debug_stage = 0x4100'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  if opcode == HciOpReadBufferSize:
    return sendReadBufferSizeComplete(opcode, paramLen)
  if opcode == HciOpLeReadBufferSize:
    return sendLeReadBufferSizeComplete(opcode, paramLen)
  if opcode == HciOpLeReadLocalSupportedFeatures:
    return sendLeReadLocalSupportedFeaturesComplete(opcode, paramLen)
  if opcode == HciOpLeConnectionUpdate:
    return sendLeConnectionUpdateCommand(opcode, params, paramLen)
  if opcode == HciOpReadRemoteVersionInfo:
    return sendReadRemoteVersionInfoCommand(opcode, params, paramLen)
  if opcode == HciOpLeReadRemoteFeatures:
    return sendLeReadRemoteFeaturesCommand(opcode, params, paramLen)
  if opcode == HciOpLeEncrypt:
    return sendLeEncryptComplete(opcode, params, paramLen)
  if opcode == HciOpLeRand:
    return sendLeRandComplete(opcode, paramLen)
  if opcode == HciOpLeSetDataLen:
    return sendLeSetDataLengthComplete(opcode, params, paramLen)
  if opcode == HciOpLeReadSuggestedDefaultDataLen:
    return sendLeReadSuggestedDefaultDataLengthComplete(opcode, paramLen)
  if opcode == HciOpLeWriteSuggestedDefaultDataLen:
    return sendLeWriteSuggestedDefaultDataLengthComplete(opcode, params,
                                                        paramLen)
  if opcode == HciOpLeReadLocalP256PublicKey:
    return sendLeReadLocalP256Complete(opcode, paramLen)
  if opcode == HciOpLeGenerateDhKey:
    return sendLeGenerateDhKeyComplete(opcode, params, paramLen)
  if opcode == HciOpLeReadMaximumDataLen:
    return sendLeReadMaximumDataLengthComplete(opcode, paramLen)
  nim_hci_debug_stage = 0x4110'u32
  result = handleNimHciCommand(opcode, params, paramLen)
  nim_hci_debug_stage = 0x4120'u32
  nim_hci_debug_status = result.uint32
  sendCmdComplete(opcode, result)
  nim_hci_debug_stage = 0x4130'u32

proc hci_evt_mask_set*(mask: ptr uint8) {.exportc, cdecl.} =
  discard c_memcpy(addr hci_evt_mask[0], mask, 8)

proc hci_cmd_get_max_param_size*(): uint16 {.exportc, cdecl.} =
  return 255

proc hci_cmd_received*(commandPacket: pointer, commandPacketLen: uint16) {.exportc, cdecl.} =
  ## Process received HCI command
  if commandPacket == nil or commandPacketLen < 3:
    return
  let opcode = hciRawOpcode(commandPacket)
  let paramLen = hciRawParamLen(commandPacket)
  if commandPacketLen < uint16(paramLen.int + 3):
    sendCmdComplete(opcode, 0x12'u8)
    return
  let params =
    if paramLen == 0: nil
    else: hciRawParams(commandPacket)
  discard completeHciCommand(opcode, params, paramLen)

proc hci_command_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                           src_id: KeTaskId, commandMsgParam: pointer): int32 {.exportc, cdecl.} =
  return 1  # KE_MSG_CONSUMED

proc hci_send_2_controller*(controllerMsg: pointer) {.exportc, cdecl.} =
  ble_ke_msg_send(controllerMsg)

proc hci_send_2_host*(hostMsg: pointer) {.exportc, cdecl.} =
  ble_ke_msg_send(hostMsg)

proc hci_look_for_cmd_desc*(opcode: uint16): pointer {.exportc, cdecl.} =
  return nil

proc hci_look_for_evt_desc*(code: uint8): pointer {.exportc, cdecl.} =
  return nil

proc hci_look_for_le_evt_desc*(subcode: uint8): pointer {.exportc, cdecl.} =
  return nil

proc hci_build_evt*(eventCode: uint8, eventPayload: pointer, eventPayloadLen: uint16): pointer {.exportc, cdecl.} =
  let eventMsg = ble_ke_msg_alloc(eventCode.KeMsgId, 0, 0, eventPayloadLen)
  if eventMsg != nil and eventPayload != nil and eventPayloadLen > 0:
    discard c_memcpy(eventMsg, eventPayload, eventPayloadLen.csize_t)
  return eventMsg

proc hci_build_le_evt*(leSubeventCode: uint8, leEventPayload: pointer, leEventPayloadLen: uint16): pointer {.exportc, cdecl.} =
  discard leSubeventCode
  return hci_build_evt(0x3E, leEventPayload, leEventPayloadLen)

proc hci_build_cc_evt*(opcode: uint16, commandCompletePayload: pointer, commandCompletePayloadLen: uint16): pointer {.exportc, cdecl.} =
  return hci_build_evt(0x0E, commandCompletePayload, commandCompletePayloadLen)

proc hci_build_acl_rx_data*(handle: uint16, aclRxPayload: pointer, aclRxPayloadLen: uint16): pointer {.exportc, cdecl.} =
  let aclRxMsg = ble_ke_msg_alloc(0, handle, 0, aclRxPayloadLen)
  if aclRxMsg != nil and aclRxPayload != nil and aclRxPayloadLen > 0:
    discard c_memcpy(aclRxMsg, aclRxPayload, aclRxPayloadLen.csize_t)
  return aclRxMsg

proc hci_acl_tx_data_alloc*(handle: uint16, aclTxPayloadLen: uint16): pointer {.exportc, cdecl.} =
  return ble_ke_msg_alloc(0, handle, 0, aclTxPayloadLen)

proc hciAclTxDataStatus(handle: uint16, pbBcFlag: uint8,
                        aclTxPayload: pointer, aclTxPayloadLen: uint16): uint8 =
  let pb = pbBcFlag and 0x03'u8
  let bc = (pbBcFlag shr 2) and 0x03'u8
  if bc != 0'u8 or (pb != 0'u8 and pb != 0x02'u8):
    return HciStatusUnsupportedFeatureParam
  if aclTxPayload == nil or aclTxPayloadLen == 0'u16:
    return HciStatusInvalidParams
  if aclTxPayloadLen > NimBleLeMaxDataOctets:
    return HciStatusInvalidParams
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx and bl808BleNimPureConnection:
    let conhdl = handle and 0x0FFF'u16
    if not nim_conn_state.active or conhdl != nim_conn_state.handle:
      inc nim_acl_host_tx_reject_count
      return HciStatusUnknownConnection
    if not nim_conn_state.dataFlowEnabled:
      inc nim_acl_host_tx_reject_count
      return HciStatusCommandDisallowed
    if nim_acl_host_tx_pending != 0'u32:
      inc nim_acl_host_tx_reject_count
      return HciStatusCommandDisallowed
    copyBtbleEmBytes(NimAclTxEmOffset, cast[ptr uint8](aclTxPayload), aclTxPayloadLen.int)
    nimConnTxElementInit(addr nim_acl_host_tx_buf[0], NimAclTxEmOffset, aclTxPayloadLen)
    nim_acl_host_tx_pending = 1
    inc nim_acl_host_tx_count
    nimConnArmPendingHostAclTx()
    HciStatusSuccess
  else:
    HciStatusUnsupportedFeatureParam

proc hciOwnedAclTxDataReceived(handle: uint16, pbBcFlag: uint8,
                               ownedAclTxPayload: pointer, ownedAclTxPayloadLen: uint16): uint8 =
  result = hciAclTxDataStatus(handle, pbBcFlag, ownedAclTxPayload, ownedAclTxPayloadLen)
  if ownedAclTxPayload != nil:
    ble_util_buf_acl_tx_free(ownedAclTxPayload)
  if result != HciStatusSuccess:
    sendNumberOfCompletedPackets(handle and 0x0FFF'u16, 1'u16)

proc hci_acl_tx_data_received*(handle: uint16, aclTxPayload: pointer, aclTxPayloadLen: uint16) {.exportc, cdecl.} =
  discard hciOwnedAclTxDataReceived(handle, 0x02'u8, aclTxPayload, aclTxPayloadLen)

proc hci_get_tx_queue_num*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx and bl808BleNimPureConnection:
    if nim_acl_host_tx_pending != 0'u32:
      return 1
  return 0

proc hciFormatFieldSize(ch: uint8): int =
  case ch
  of 0'u8:
    0
  of uint8('B'), uint8('b'):
    1
  of uint8('H'), uint8('h'):
    2
  of uint8('L'), uint8('l'):
    4
  of uint8('D'), uint8('d'), uint8('E'), uint8('e'):
    8
  else:
    0

proc hciUtilCopyByFormat(outBuf: pointer, inBuf: pointer, format: cstring,
                         outLen: ptr uint16) =
  if outLen != nil:
    outLen[] = 0
  if outBuf == nil or inBuf == nil or format == nil:
    return
  let outputBytes = cast[ptr UncheckedArray[uint8]](outBuf)
  let inputBytes = cast[ptr UncheckedArray[uint8]](inBuf)
  let formatBytes = cast[ptr UncheckedArray[uint8]](format)
  var formatOffset = 0
  var inputOffset = 0
  var outputOffset = 0
  var repeatCount = 0
  while formatBytes[formatOffset] != 0'u8:
    let formatToken = formatBytes[formatOffset]
    inc formatOffset
    if formatToken >= uint8('0') and formatToken <= uint8('9'):
      repeatCount = repeatCount * 10 + int(formatToken - uint8('0'))
      continue
    if formatToken == uint8(' ') or formatToken == uint8(',') or formatToken == uint8(':'):
      continue
    var fieldSize = hciFormatFieldSize(formatToken)
    if fieldSize == 0:
      repeatCount = 0
      continue
    if repeatCount > 0:
      fieldSize = fieldSize * repeatCount
      repeatCount = 0
    for fieldByteOffset in 0 ..< fieldSize:
      outputBytes[outputOffset + fieldByteOffset] =
        inputBytes[inputOffset + fieldByteOffset]
    inputOffset += fieldSize
    outputOffset += fieldSize
  if outLen != nil:
    outLen[] = outputOffset.uint16

proc hci_util_pack*(out_buf: pointer, in_buf: pointer, format: cstring, out_len: ptr uint16) {.exportc, cdecl.} =
  ## Pack HCI parameters according to the compact controller format string.
  hciUtilCopyByFormat(out_buf, in_buf, format, out_len)

proc hci_util_unpack*(out_buf: pointer, in_buf: pointer, format: cstring, out_len: ptr uint16) {.exportc, cdecl.} =
  ## Unpack HCI parameters according to the compact controller format string.
  hciUtilCopyByFormat(out_buf, in_buf, format, out_len)

# ---------------------------------------------------------------------------
# ======================== LLC (Link Layer Control) ========================
# ---------------------------------------------------------------------------

proc llc_init*() {.exportc, cdecl.} =
  for connectionHandleIndex in 0 ..< LLC_CON_MAX:
    llc_env[connectionHandleIndex] = nil
  when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
    for llcStartSlotIndex in 0 ..< nim_llc_start_env_slots.len:
      nim_llc_start_env_slots[llcStartSlotIndex] = nil

proc llc_reset*() {.exportc, cdecl.} =
  llc_init()

proc llc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_stop*(conhdl: uint16) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX:
    if llc_env[conhdl] != nil:
      ble_ke_free(llc_env[conhdl])
      llc_env[conhdl] = nil
  when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
    if conhdl < nim_llc_start_env_slots.len.uint16:
      nim_llc_start_env_slots[conhdl] = nil

proc llc_hci_command_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                               src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  return 1  # KE_MSG_CONSUMED

proc llc_hci_acl_data_tx_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                                   src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  return 1

proc llc_llcp_recv_handler*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

proc llc_llcp_get_autorize*(conhdl: uint16, opcode: uint8): uint8 {.exportc, cdecl.} =
  return 1  # Authorized

proc llc_common_cmd_complete_send*(conhdl: uint16, opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard conhdl
  sendCmdComplete(opcode, status)

proc llc_common_cmd_status_send*(conhdl: uint16, opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard conhdl
  sendCmdStatus(opcode, status)

proc llc_common_enc_change_evt_send*(conhdl: uint16, status: uint8, enabled: uint8) {.exportc, cdecl.} =
  var evt = [status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), enabled]
  sendHostEvent(HciEvtEncryptionChange, addr evt[0], evt.len.uint8)

proc llc_common_enc_key_ref_comp_evt_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF)]
  sendHostEvent(HciEvtEncryptionKeyRefreshComplete, addr evt[0],
                evt.len.uint8)

proc llc_common_flush_occurred_send*(conhdl: uint16) {.exportc, cdecl.} =
  var evt = [uint8(conhdl and 0xFF), uint8((conhdl shr 8) and 0xFF)]
  sendHostEvent(HciEvtFlushOccurred, addr evt[0], evt.len.uint8)

proc llc_common_nb_of_pkt_comp_evt_send*(conhdl: uint16, nb: uint16) {.exportc, cdecl.} =
  sendNumberOfCompletedPackets(conhdl, nb)

proc llc_con_update_complete_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [0x03'u8, status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), 0'u8, 0'u8, 0'u8, 0'u8,
             0'u8, 0'u8]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_con_update_finished*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_con_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_discon_event_complete_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    noteNimPeripheralDisconnectedFrom(4'u32, reason)
  sendDisconnectComplete(conhdl, reason)

proc nimBleCurrentRemoteFeatures(): uint64 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.peerFeaturesKnown:
      return nim_llcp_state.peerFeatures
  0'u64

proc hciPutLe16(destBytes: ptr UncheckedArray[uint8], byteOffset: int, value: uint16) =
  destBytes[byteOffset] = uint8(value and 0x00FF'u16)
  destBytes[byteOffset + 1] = uint8((value shr 8) and 0x00FF'u16)

proc nimBleCurrentChannelMap(channelMapOut: ptr UncheckedArray[uint8]) =
  if channelMapOut == nil:
    return
  channelMapOut[0] = 0xFF'u8
  channelMapOut[1] = 0xFF'u8
  channelMapOut[2] = 0xFF'u8
  channelMapOut[3] = 0xFF'u8
  channelMapOut[4] = 0x1F'u8
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active:
      for channelMapByteIndex in 0 ..< 5:
        channelMapOut[channelMapByteIndex] = nim_conn_state.channelMap[channelMapByteIndex]
      channelMapOut[4] = channelMapOut[4] and 0x1F'u8

proc nimBleCurrentPhy(): uint8 =
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active and nim_conn_state.phy != 0'u8:
      return nim_conn_state.phy
  NimBleLe1MPhy

proc nimBleSetCurrentPhy1M() =
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active:
      nim_conn_state.rate = 0'u8
      nim_conn_state.phy = NimBleLe1MPhy

proc nimBleLocalTxDataOctets(): uint16 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.localTxOctets != 0'u16:
      return nim_llcp_state.localTxOctets
  NimBleLeMaxDataOctets

proc nimBleLocalTxDataTime(): uint16 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.localTxTime != 0'u16:
      return nim_llcp_state.localTxTime
  NimBleLeMaxDataTime

proc nimBleCurrentMaxTxOctets(): uint16 =
  result = nimBleLocalTxDataOctets()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxRxOctets)

proc nimBleCurrentMaxTxTime(): uint16 =
  result = nimBleLocalTxDataTime()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxRxTime)

proc nimBleCurrentMaxRxOctets(): uint16 =
  result = NimBleLeMaxDataOctets
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxTxOctets)

proc nimBleCurrentMaxRxTime(): uint16 =
  result = NimBleLeMaxDataTime
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxTxTime)

proc nimBleDataLengthParamStatus(txOctets, txTime: uint16): uint8 =
  if txOctets < NimBleLeMinDataOctets or txTime < NimBleLeMinDataTime:
    return HciStatusInvalidParams
  if txOctets > NimBleLeSpecMaxDataOctets or
      txTime > NimBleLeSpecMaxDataTime:
    return HciStatusInvalidParams
  if txOctets > NimBleLeMaxDataOctets or txTime > NimBleLeMaxDataTime:
    return HciStatusUnsupportedFeatureParam
  return HciStatusSuccess

proc nimBleApplyLocalDataLength(handle, txOctets, txTime: uint16) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_state.localTxOctets = txOctets
    nim_llcp_state.localTxTime = txTime
    when bl808BleNimPureConnection:
      if nim_conn_state.active:
        nimConnProgramPacketDurations(handle)
  else:
    discard handle
    discard txOctets
    discard txTime

proc sendLeDataLengthChange(handle: uint16) =
  var evt: array[11, uint8]
  evt[0] = 0x07'u8
  evt[1] = uint8(handle and 0x00FF'u16)
  evt[2] = uint8((handle shr 8) and 0x00FF'u16)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 3,
             nimBleCurrentMaxTxOctets())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 5,
             nimBleCurrentMaxTxTime())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 7,
             nimBleCurrentMaxRxOctets())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 9,
             nimBleCurrentMaxRxTime())
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeReadRemoteFeaturesCommand(opcode: uint16, params: ptr uint8,
                                     paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != 2'u8:
      HciStatusInvalidParams
    else:
      connParamStatus(params, handle)
  sendCmdStatus(opcode, result)
  if result != HciStatusSuccess:
    return

  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nim_llcp_state.peerFeaturesKnown:
      sendLeRemoteFeaturesComplete(handle, HciStatusSuccess)
    else:
      nim_llcp_state.remoteFeaturesEventPending = true
      llc_llcp_feats_req_pdu_send(handle)
  else:
    sendLeRemoteFeaturesComplete(handle, HciStatusSuccess)

proc sendReadRemoteVersionInfoCommand(opcode: uint16, params: ptr uint8,
                                      paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != 2'u8:
      HciStatusInvalidParams
    else:
      connParamStatus(params, handle)
  sendCmdStatus(opcode, result)
  if result == HciStatusSuccess:
    sendRemoteVersionInfoComplete(handle, result)

proc nimBleConnectionUpdateParamStatus(params: ptr uint8, paramLen: uint8,
                                       handle: uint16): uint8 =
  if params == nil or paramLen != sizeof(HciLeConnUpdateReqView).uint8:
    return HciStatusInvalidParams
  result = connParamStatus(params, handle)
  if result != HciStatusSuccess:
    return
  let req = hciLeConnUpdateReq(params)
  if req.connIntervalMin < 6'u16 or req.connIntervalMin > 3200'u16:
    return HciStatusInvalidParams
  if req.connIntervalMax < req.connIntervalMin or
      req.connIntervalMax > 3200'u16:
    return HciStatusInvalidParams
  if req.connLatency > 499'u16:
    return HciStatusInvalidParams
  if req.supervisionTimeout < 10'u16 or req.supervisionTimeout > 3200'u16:
    return HciStatusInvalidParams
  let timeoutMargin = uint32(req.supervisionTimeout) * 4'u32
  let latencyInterval =
    uint32(req.connLatency + 1'u16) * uint32(req.connIntervalMax)
  if timeoutMargin <= latencyInterval:
    return HciStatusInvalidParams
  return HciStatusSuccess

proc sendLeConnectionUpdateCommand(opcode: uint16, params: ptr uint8,
                                   paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result = nimBleConnectionUpdateParamStatus(params, paramLen, handle)
  if result == HciStatusSuccess:
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        bl808BleNimManualConnTx:
      result = nimLlcpStartConnectionUpdate(handle, hciLeConnUpdateReq(params))
    else:
      result = HciStatusUnsupportedFeatureParam
  sendCmdStatus(opcode, result)

proc nimBleRequestedPhySupported(req: ptr HciLeSetPhyReqView): bool =
  if req == nil:
    return false
  let txUnsupported =
    (req.allPhys and 0x01'u8) == 0'u8 and
    (req.txPhys == 0'u8 or (req.txPhys and not NimBleLe1MPhy) != 0'u8)
  let rxUnsupported =
    (req.allPhys and 0x02'u8) == 0'u8 and
    (req.rxPhys == 0'u8 or (req.rxPhys and not NimBleLe1MPhy) != 0'u8)
  not txUnsupported and not rxUnsupported

proc nimBleDataLengthStatus(params: ptr uint8, handle: uint16): uint8 =
  let baseStatus = connParamStatus(params, handle)
  if baseStatus != HciStatusSuccess:
    return baseStatus
  if not nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
    return HciStatusUnsupportedFeatureParam
  let req = hciLeSetDataLenReq(params)
  result = nimBleDataLengthParamStatus(req.txOctets, req.txTime)
  if result == HciStatusSuccess:
    nimBleApplyLocalDataLength(handle, req.txOctets, req.txTime)

proc sendLeSetDataLengthComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != sizeof(HciLeSetDataLenReqView).uint8:
      HciStatusInvalidParams
    else:
      nimBleDataLengthStatus(params, handle)
  var rsp = [result, uint8(handle and 0x00FF'u16),
             uint8((handle shr 8) and 0x00FF'u16)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  if result == HciStatusSuccess:
    sendLeDataLengthChange(handle)

proc sendLeReadSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                  paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[5, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             nim_suggested_tx_octets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 3,
             nim_suggested_tx_time)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeWriteSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                   params: ptr uint8,
                                                   paramLen: uint8): uint8 =
  if params == nil or
      paramLen != sizeof(HciLeSuggestedDataLenReqView).uint8:
    result = HciStatusInvalidParams
  else:
    let req = hciLeSuggestedDataLenReq(params)
    result = nimBleDataLengthParamStatus(req.txOctets, req.txTime)
    if result == HciStatusSuccess:
      nim_suggested_tx_octets = req.txOctets
      nim_suggested_tx_time = req.txTime
  sendCmdComplete(opcode, result)

proc sendLeReadMaximumDataLengthComplete(opcode: uint16,
                                         paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[9, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 3,
             NimBleLeMaxDataTime)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 5,
             NimBleLeMaxDataOctets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 7,
             NimBleLeMaxDataTime)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc llc_end_evt_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_feats_rd_event_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [0x04'u8, status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), 0'u8, 0'u8, 0'u8, 0'u8,
             0'u8, 0'u8, 0'u8, 0'u8]
  let features = nimBleCurrentRemoteFeatures()
  for remoteFeatureByteIndex in 0 ..< 8:
    evt[4 + remoteFeatureByteIndex] = nimBleFeatureByte(features, remoteFeatureByteIndex)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_le_ch_sel_algo_evt_send*(conhdl: uint16, algo: uint8) {.exportc, cdecl.} =
  var evt = [0x14'u8, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), algo]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_le_con_cmp_evt_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt: array[19, uint8]
  evt[0] = 0x01'u8
  evt[1] = status
  evt[2] = uint8(conhdl and 0xFF)
  evt[3] = uint8((conhdl shr 8) and 0xFF)
  if status == 0:
    nim_conn_active = true
    nim_conn_handle = conhdl
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_llcp_ch_map_update_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildChannelMapInd()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_con_param_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_con_param_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_con_update_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_feats_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildFeaturePdu(LlcpFeatureReq)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_feats_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildFeatureRsp()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_length_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      var pdu = nimLlcpBuildLengthPdu(LlcpLengthReq)
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_length_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      var pdu = nimLlcpBuildLengthRsp()
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_pause_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_pause_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_ping_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureLePing):
      var pdu = nimLlcpBuildOpcodePdu(LlcpPingReq)
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_ping_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureLePing):
      var pdu = nimLlcpBuildPingRsp()
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_reject_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildRejectInd(reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard reason

proc llc_llcp_start_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_start_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_terminate_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildTerminateInd(reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard reason

proc llc_llcp_unknown_rsp_send_pdu*(conhdl: uint16, opcode: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildUnknownRsp(opcode)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard opcode

proc llc_llcp_version_ind_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildVersionInd()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_lsto_con_update*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_ltk_req_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_map_update_finished*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_map_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_acl_tx_ack_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_llcp_tx_ack_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_version_rd_event_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [
    status,
    uint8(conhdl and 0xFF),
    uint8((conhdl shr 8) and 0xFF),
    0x09'u8,
    0xBF'u8, 0x01'u8,
    0x01'u8, 0x00'u8
  ]
  sendHostEvent(HciEvtRemoteVersionInfoComplete, addr evt[0], evt.len.uint8)

proc llc_ch_assess_get_current_ch_map*(conhdl: uint16, map: ptr uint8) {.exportc, cdecl.} =
  ## Get the current channel map for the connection
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    discard c_memcpy(map, addr assess.channelMap[0], 5)

proc llc_ch_assess_get_local_ch_map*(map: ptr uint8) {.exportc, cdecl.} =
  ## Get the local channel assessment map
  discard c_memset(map, 0xFF, 5)  # All channels available by default

proc llc_ch_assess_local*() {.exportc, cdecl.} =
  ## Perform local channel assessment
  discard

proc llc_ch_assess_reass_ch*() {.exportc, cdecl.} =
  ## Reassess channels
  discard

proc llc_util_bw_mgt*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_util_clear_operation_ptr*(conhdl: uint16, op_type: uint8) {.exportc, cdecl.} =
  discard

proc llc_util_dicon_procedure*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  ## Initiate disconnection procedure
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let disconnect = llcDisconnectState(llc_env[conhdl])
    if disconnect.active != 0:
      return  # Already disconnecting
    disconnect.reason = reason
    disconnect.active = 1

proc llc_util_get_free_conhdl*(): uint16 {.exportc, cdecl.} =
  for freeConnectionHandle in 0'u16 ..< LLC_CON_MAX.uint16:
    if llc_env[freeConnectionHandle] == nil:
      return freeConnectionHandle
  return 0xFFFF'u16

proc llc_util_get_nb_active_link*(): uint8 {.exportc, cdecl.} =
  var activeLinkCount: uint8 = 0
  for connectionHandleIndex in 0 ..< LLC_CON_MAX:
    if llc_env[connectionHandleIndex] != nil:
      inc activeLinkCount
  return activeLinkCount

proc llc_util_set_auth_payl_to_margin*(conhdl: uint16, margin: uint16) {.exportc, cdecl.} =
  discard

proc llc_util_set_llcp_discard_enable*(conhdl: uint16, enable: bool) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    if enable:
      assess.flags = assess.flags or 0x0008'u16
    else:
      assess.flags = assess.flags and not 0x0008'u16

proc llc_util_update_channel_map*(conhdl: uint16, map: ptr uint8) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    discard c_memcpy(addr assess.channelMap[0], map, 5)

# ---------------------------------------------------------------------------
# ======================== LLD (Link Layer Driver) =========================
# ---------------------------------------------------------------------------

proc lld_init*(reset: bool) {.exportc, cdecl.} =
  discard reset
  blePlatformInitMark(0x200'u32)
  discard c_memset(addr lld_evt_env_storage[0], 0, sizeof(lld_evt_env_storage).csize_t)
  blePlatformInitMark(0x201'u32)
  initBleCoreRegisters()
  blePlatformInitMark(0x202'u32)
  bleVolatileCounterInc(addr nim_ble_lld_init_return_count)

proc lld_core_reset*() {.exportc, cdecl.} =
  lld_init(true)

proc lld_evt_init*() {.exportc, cdecl.} =
  discard

proc lld_evt_init_evt*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_adv_create*(params: pointer): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_scan_create*(params: pointer): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_update_create*(conhdl: uint16): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_elt_insert*(elt: pointer) {.exportc, cdecl.} =
  ea_elt_insert(cast[ptr EaEltTag](elt))

proc lld_evt_elt_delete*(elt: pointer) {.exportc, cdecl.} =
  ea_elt_remove(cast[ptr EaEltTag](elt))
  ble_ke_free(elt)

proc lld_evt_delete_elt_push*(elt: pointer) {.exportc, cdecl.} =
  lld_evt_elt_delete(elt)

proc lld_evt_delete_evt_mode_get*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_evt_end*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_end_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_rx*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_rx_afs*() {.exportc, cdecl.} =
  discard

proc lld_evt_rx_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_slot_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_timer_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_channel_next*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_schedule*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_schedule_next*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_move_to_master*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_move_to_slave*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_slave_update*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_restart*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_prevent_stop*() {.exportc, cdecl.} =
  discard

proc lld_evt_canceled*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_deffered_elt_handler*() {.exportc, cdecl.} =
  discard

proc lld_evt_deffered_elt_simple_handler*() {.exportc, cdecl.} =
  discard

proc lld_evt_elt_defferred_get*(): pointer {.exportc, cdecl.} =
  return nil

proc lld_evt_drift_compute*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  return 0

proc lld_con_start*(conhdl: uint16, params: pointer) {.exportc, cdecl.} =
  discard

proc lld_con_stop*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_param_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_param_rsp*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_after_param_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_ch_map_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_crypt_isr*() {.exportc, cdecl.} =
  discard

proc lld_set_evt_end_time*(elt: pointer, time: uint32) {.exportc, cdecl.} =
  discard

proc lld_get_mode*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_get_evt_mode*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_move_to_master*(conhdl: uint16) {.exportc, cdecl.} =
  lld_evt_move_to_master(conhdl)

proc lld_move_to_slave*(conhdl: uint16) {.exportc, cdecl.} =
  lld_evt_move_to_slave(conhdl)

proc lld_master_check_increase_instant*(conhdl: uint16): bool {.exportc, cdecl.} =
  return false

proc lld_update_adv_scan_aa*() {.exportc, cdecl.} =
  discard

proc lld_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  nim_ble_wlcoex_enabled = if en: 1'u32 else: 0'u32
  if not en:
    nim_ble_wifi_tx_window_active = 0'u32

# LLD PDU functions
proc lld_pdu_adv_pack*(params: pointer) {.exportc, cdecl.} =
  discard

proc lld_pdu_check*(conhdl: uint16): bool {.exportc, cdecl.} =
  return true

proc lld_pdu_data_send*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

proc lld_pdu_data_tx_push*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_rx_handler*() {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_flush*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_loop*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_prog*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_push*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

# LLD sleep functions
proc lld_sleep_init*() {.exportc, cdecl.} =
  let wakeLp = bflbip_us_2_lpcycles(5000)
  let slotLp = bflbip_us_2_lpcycles(625)
  let sleepCfg =
    ((wakeLp shl 21) and 0xFE000000'u32) or
    ((wakeLp shl 10) and 0x03FFFC00'u32) or
    (slotLp and 0x0000FFFF'u32)
  regWrite((BLE_BASE + 0x03C'u32).uint, sleepCfg)
  bflbip_wakeup_delay_set(5000)
  regWrite((BLE_BASE + 0x030'u32).uint,
           regRead((BLE_BASE + 0x030'u32).uint) and 0x7FFFFFFF'u32)

proc lld_sleep_enter*() {.exportc, cdecl.} =
  discard

proc lld_sleep_wakeup*() {.exportc, cdecl.} =
  discard

proc lld_sleep_wakeup_end*() {.exportc, cdecl.} =
  discard

# LLD utility functions
proc lld_util_anchor_point_move*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_compute_ce_max*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  return 0

proc lld_util_connection_param_set*(conhdl: uint16, params: pointer) {.exportc, cdecl.} =
  discard

proc lld_util_dle_set_cs_fields*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_eff_tx_time_set*(conhdl: uint16, time: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_elt_programmed*(elt: pointer): bool {.exportc, cdecl.} =
  return false

proc lld_util_flush_list*(list: ptr CoList) {.exportc, cdecl.} =
  while list.first != nil:
    let node = ble_co_list_pop_front(list)
    ble_ke_free(node)

proc lld_util_freq2chnl*(freq: uint8): uint8 {.exportc, cdecl.} =
  ## Convert frequency index to channel index
  if freq <= 10:
    return freq + 1
  elif freq == 39:
    return 0  # Advertising channel 37
  elif freq == 38:
    return 12  # Advertising channel 38
  else:
    return freq - 10 + 13

proc lld_util_get_bd_address*(addr_out: ptr BdAddr) {.exportc, cdecl.} =
  if addr_out == nil:
    return
  for publicAddressByteIndex in 0 ..< addr_out.bytes.len:
    addr_out.bytes[publicAddressByteIndex] =
      if nim_public_addr_valid: nim_public_addr[publicAddressByteIndex]
      else: fallbackLocalAddrByte(publicAddressByteIndex)

proc lld_util_set_bd_address*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  if addr_in == nil:
    return
  let publicAddrLowWord = addr_in.bytes[0].uint32 or
           (addr_in.bytes[1].uint32 shl 8) or
           (addr_in.bytes[2].uint32 shl 16) or
           (addr_in.bytes[3].uint32 shl 24)
  let publicAddrHighWord = addr_in.bytes[4].uint32 or
           (addr_in.bytes[5].uint32 shl 8)
  regWrite(BLE_BASE + 0x24'u32, publicAddrLowWord)
  regWrite(BLE_BASE + 0x28'u32, publicAddrHighWord)
  for publicAddressByteIndex in 0 ..< nim_public_addr.len:
    nim_public_addr[publicAddressByteIndex] = addr_in.bytes[publicAddressByteIndex]
  nim_public_addr_valid = true

proc lld_util_get_local_offset*(): int16 {.exportc, cdecl.} =
  return 0

proc lld_util_get_peer_offset*(): int16 {.exportc, cdecl.} =
  return 0

proc lld_util_get_tx_pkt_cnt*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  return 0

proc lld_util_instant_get*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  return 0

proc lld_util_instant_ongoing*(conhdl: uint16): bool {.exportc, cdecl.} =
  return false

proc lld_util_priority_set*(elt: pointer, prio: uint8) {.exportc, cdecl.} =
  if elt != nil:
    cast[ptr EaEltTag](elt).current_prio = prio

proc lld_util_priority_update*(elt: pointer) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# ======================== LLM (Link Layer Manager) ========================
# ---------------------------------------------------------------------------

when defined(bl808m0):
  proc sch_plan_rem*(elt: pointer) {.importc, cdecl.}
else:
  proc sch_plan_rem*(elt: pointer) {.exportc, cdecl.} =
    discard elt

proc llm_init*() {.exportc, cdecl.} =
  discard c_memset(addr llm_env_storage, 0, sizeof(LlmEnv).csize_t)
  discard c_memset(addr llm_wl[0], 0, sizeof(llm_wl).csize_t)
  discard c_memset(addr llm_wl_type[0], 0, sizeof(llm_wl_type).csize_t)
  let maps = llmChannelMaps()
  let runtimeCfg = llmRuntimeConfig()
  for leEventMaskByteIndex in 0 ..< hci_le_evt_mask.len:
    runtimeCfg.leEventMask[leEventMaskByteIndex] = hci_le_evt_mask[leEventMaskByteIndex]
  for dataChannelMapByteIndex in 0 ..< maps.localMap.len:
    maps.localMap[dataChannelMapByteIndex] = 0xFF'u8
    maps.masterMap[dataChannelMapByteIndex] = 0xFF'u8
  maps.localMap[4] = maps.localMap[4] and 0x1F'u8
  maps.masterMap[4] = maps.masterMap[4] and 0x1F'u8
  runtimeCfg.connectionAcceptTimeout = 0x1FA0'u16
  runtimeCfg.suggestedMaxTxOctets = 27'u16
  runtimeCfg.suggestedMaxTxTime = 0x0148'u16
  runtimeCfg.featureSet[0] = 0x07'u8
  runtimeCfg.featureSet[1] = 0x07'u8
  runtimeCfg.featureSet[3] = 0x2C'u8
  runtimeCfg.suggestedMaxRxOctets = 0x0384'u16

proc llm_ble_ready*() {.exportc, cdecl.} =
  discard

proc llm_le_evt_mask_check*(evtBit: uint8): uint8 {.exportc, cdecl.} =
  let eventMaskByteIndex = int(evtBit shr 3)
  if eventMaskByteIndex >= 8:
    return 0
  let bitIdx = evtBit and 0x07'u8
  if (llmRuntimeConfig().leEventMask[eventMaskByteIndex] and
      (1'u8 shl bitIdx)) != 0'u8:
    1
  else:
    0

proc llm_get_connection_accept_timeout*(): uint16 {.exportc, cdecl.} =
  llmRuntimeConfig().connectionAcceptTimeout

proc llm_set_connection_accept_timeout*(timeout: uint16) {.exportc, cdecl.} =
  llmRuntimeConfig().connectionAcceptTimeout = timeout

proc llm_clk_acc_set*(position: uint8, enable: uint8) {.exportc, cdecl.} =
  let clockAccuracyBit = 1'u32 shl (position and 0x1F'u8)
  let runtimeCfg = llmRuntimeConfig()
  var mask = runtimeCfg.clockAccuracyMask
  if enable != 0'u8:
    mask = mask or clockAccuracyBit
    rwip_prevent_sleep_set(0x0200'u16)
  else:
    mask = mask and not clockAccuracyBit
    if mask == 0'u32:
      rwip_prevent_sleep_clear(0x0200'u16)
  runtimeCfg.clockAccuracyMask = mask

proc llm_master_ch_map_get*(): ptr uint8 {.exportc, cdecl.} =
  addr llmChannelMaps().masterMap[0]

proc llm_rx_path_comp_get*(): int16 {.exportc, cdecl.} =
  llmRuntimeConfig().rxPathCompensation

proc llm_tx_path_comp_get*(): int16 {.exportc, cdecl.} =
  llmRuntimeConfig().txPathCompensation

proc llmActivityStateByte(activityId: uint8): ptr uint8 {.inline.} =
  let stateOffset = int(activityId) * 64 + 72
  if stateOffset >= llm_env_storage.storage.len:
    return nil
  if activityId < 5'u8:
    addr llmActivitySlot(activityId.int).state
  else:
    addr llm_env_storage.storage[stateOffset]

proc llmActivityPlanElementPtr(activityId: uint8; requireFullWindow: bool): pointer {.inline.} =
  let planOffset = int(activityId) * 64 + 16
  if planOffset >= llm_env_storage.storage.len:
    return nil
  if requireFullWindow and planOffset + 56 >= llm_env_storage.storage.len:
    return nil
  if activityId < 5'u8:
    cast[pointer](addr llmActivitySlot(activityId.int).schedulerPlanElement[0])
  else:
    cast[pointer](addr llm_env_storage.storage[planOffset])

proc llm_plan_elt_get*(activityId: uint8): pointer {.exportc, cdecl.} =
  llmActivityPlanElementPtr(activityId, false)

proc llm_is_adv_itf_legacy*(): uint8 {.exportc, cdecl.} =
  if llmRuntimeConfig().advertisingInterfaceMode == 1'u8: 1 else: 0

proc llm_adv_itf_extended_set*() {.exportc, cdecl.} =
  let runtimeCfg = llmRuntimeConfig()
  if runtimeCfg.advertisingInterfaceMode == 0'u8:
    runtimeCfg.advertisingInterfaceMode = 2'u8

proc llm_dev_list_empty_entry*(): uint8 {.exportc, cdecl.} =
  for emptyDeviceListIndex in 0 ..< 7:
    if (llmDeviceListEntry(emptyDeviceListIndex).flags and 1'u8) == 0'u8:
      return uint8(emptyDeviceListIndex)
  7'u8

proc llm_dev_list_search*(addrIn: ptr BdAddr, addrType: uint8): uint8
    {.exportc, cdecl.} =
  for deviceListIndex in 0 ..< 7:
    let deviceEntry = llmDeviceListEntry(deviceListIndex)
    if (deviceEntry.flags and 1'u8) != 0'u8 and
        deviceEntry.addrType == addrType and addrIn != nil:
      if co_bdaddr_compare(addr deviceEntry.deviceAddr, addrIn):
        return uint8(deviceListIndex)
  7'u8

proc llm_is_dev_connected*(addrIn: ptr BdAddr, addrType: uint8): uint8
    {.exportc, cdecl.} =
  if addrIn == nil:
    return 0
  for connectedActivityIndex in 0 ..< 5:
    let activity = llmActivitySlot(connectedActivityIndex)
    if activity.state == 9'u8 and (activity.peerAddrType xor addrType) == 0'u8:
      if co_bdaddr_compare(addrIn, addr activity.peerAddr):
        return 1
  0

proc llm_activity_free_get*(activityId: ptr uint8): uint8 {.exportc, cdecl.} =
  if activityId == nil:
    return 7
  for freeActivityIndex in 0 ..< 5:
    let activity = llmActivitySlot(freeActivityIndex)
    if activity.state == 0'u8:
      activityId[] = uint8(freeActivityIndex)
      discard c_memset(addr activity.peerAddr, 0, 32)
      return 0
  activityId[] = 5'u8
  7

proc llm_activity_free_set*(activityId: uint8) {.exportc, cdecl.} =
  let activityStateByte = llmActivityStateByte(activityId)
  let planElement = llmActivityPlanElementPtr(activityId, true)
  if activityStateByte == nil or planElement == nil:
    return
  activityStateByte[] = 0'u8
  sch_plan_rem(planElement)

proc llm_adv_hdl_to_id*(advHandle: uint8, paramOut: ptr pointer): uint8
    {.exportc, cdecl.} =
  for advertisingActivityIndex in 0 ..< 5:
    let activity = llmActivitySlot(advertisingActivityIndex)
    if activity.state >= 1'u8 and activity.state <= 3'u8:
      let advertisingParamAddr = activity.advertisingParamPtr
      if advertisingParamAddr != 0'u32:
        let advParams = cast[ptr UncheckedArray[uint8]](advertisingParamAddr.uint)
        if advParams[0] == advHandle:
          if paramOut != nil:
            paramOut[] = cast[pointer](advertisingParamAddr.uint)
          return uint8(advertisingActivityIndex)
  0xFF'u8

proc llm_cmd_cmp_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  let cmdCompleteStatusParam = ble_ke_msg_alloc(0x1100'u16, 0'u16, opcode, 1'u16)
  if cmdCompleteStatusParam != nil:
    cast[ptr uint8](cmdCompleteStatusParam)[] = status
    hci_send_2_host(cmdCompleteStatusParam)

proc llm_cmd_stat_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  let cmdStatusParam = ble_ke_msg_alloc(0x1101'u16, 0'u16, opcode, 1'u16)
  if cmdStatusParam != nil:
    cast[ptr uint8](cmdStatusParam)[] = status
    hci_send_2_host(cmdStatusParam)

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.}

proc llm_per_adv_chain_dur*(length: uint16, rate: uint8): uint8
    {.exportc, cdecl.} =
  var chainCount = uint32(length) div 240'u32 + 1'u32
  chainCount = chainCount and 0xFF'u32
  let pduLength =
    if chainCount <= 1'u32:
      let capped = uint32(length) + 15'u32
      if capped > 255'u32: 255'u16 else: uint16(capped)
    else:
      255'u16
  let phyRate = uint8((rate - 1'u8) and 0xFF'u8)
  let packetDur = uint32(ble_util_pkt_dur_in_us(pduLength, phyRate))
  let spacing = (chainCount - 1'u32) * 300'u32
  uint8((((packetDur * chainCount + spacing) shl 1) div 625'u32 + 1'u32) and
        0xFF'u32)

proc llm_common_cmd_complete_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llm_cmd_cmp_send(opcode, status)

proc llm_common_cmd_status_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llm_cmd_stat_send(opcode, status)

proc llm_con_req_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_con_req_tx_cfm*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_create_con*(params: pointer) {.exportc, cdecl.} =
  discard

proc llm_encryption_done*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_encryption_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_end_evt_defer*() {.exportc, cdecl.} =
  discard

proc llm_le_adv_report_ind*(params: pointer) {.exportc, cdecl.} =
  discard

proc llm_ll_adv_type_get*(): uint8 {.exportc, cdecl.} =
  return 0

proc llm_notify_adv_discarded*(count: uint32, reason: uint32) {.exportc, cdecl.} =
  discard reason
  if ble_adv_discarded_callback != nil:
    ble_adv_discarded_callback(count)

proc llm_pdu_defer*() {.exportc, cdecl.} =
  discard

proc llm_set_adv_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let advDataCopyLen = min(len.int, nim_adv_data.len)
  nim_adv_data_len = advDataCopyLen.uint8
  if data != nil:
    discard c_memcpy(addr nim_adv_data[0], data, advDataCopyLen.csize_t)

proc llm_set_adv_en*(en: bool) {.exportc, cdecl.} =
  discard programNimAdvertising(en)

proc llm_set_adv_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    discard c_memcpy(addr nim_adv_params[0], params,
                     nim_adv_params.len.csize_t)

proc llm_set_scan_en*(en: bool) {.exportc, cdecl.} =
  nim_scan_enabled = en

proc llm_set_scan_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    discard c_memcpy(addr nim_scan_params[0], params,
                     nim_scan_params.len.csize_t)

proc llm_set_scan_rsp_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let scanRspDataCopyLen = min(len.int, nim_scan_rsp_data.len)
  nim_scan_rsp_data_len = scanRspDataCopyLen.uint8
  if data != nil:
    discard c_memcpy(addr nim_scan_rsp_data[0], data, scanRspDataCopyLen.csize_t)
  if nim_adv_enabled:
    programBtbleLegacyAdv(nim_adv_data_len)

proc llm_util_adv_data_update*() {.exportc, cdecl.} =
  discard

proc llm_util_apply_bd_addr*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  lld_util_set_bd_address(addr_in)

proc llm_util_bd_addr_in_wl*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  for whitelistLookupSlot in 0 ..< LLM_WL_MAX:
    if llm_wl_type[whitelistLookupSlot] == addr_type and
        co_bdaddr_compare(addr llm_wl[whitelistLookupSlot], addr_in):
      return true
  return false

proc llm_util_bd_addr_wl_position*(addr_in: ptr BdAddr, addr_type: uint8): int32 {.exportc, cdecl.} =
  for whitelistPositionSlot in 0 ..< LLM_WL_MAX:
    if llm_wl_type[whitelistPositionSlot] == addr_type and
        co_bdaddr_compare(addr llm_wl[whitelistPositionSlot], addr_in):
      return whitelistPositionSlot.int32
  return -1

proc llmWlSlotAvailable(slot: int): bool {.inline.} =
  slot >= 0 and slot < LLM_WL_MAX and llm_wl_type[slot] == 0xFF'u8

proc llmWlNormalizeSlot(position: uint8): int {.inline.} =
  if position < LLM_WL_MAX.uint8:
    int(position)
  else:
    -1

proc llm_util_bl_add*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  for existingWhitelistSlot in 0 ..< LLM_WL_MAX:
    if llm_wl_type[existingWhitelistSlot] == addr_type and
        co_bdaddr_compare(addr llm_wl[existingWhitelistSlot], addr_in):
      return true
  for freeWhitelistSlot in 0 ..< LLM_WL_MAX:
    if llm_wl_type[freeWhitelistSlot] == 0xFF:  # Empty slot
      co_bdaddr_set(addr llm_wl[freeWhitelistSlot], addr_in)
      llm_wl_type[freeWhitelistSlot] = addr_type
      return true
  return false

proc llm_util_bl_check*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  return llm_util_bd_addr_in_wl(addr_in, addr_type)

proc llm_util_bl_rem*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  for removeWhitelistSlot in 0 ..< LLM_WL_MAX:
    if llm_wl_type[removeWhitelistSlot] == addr_type and
        co_bdaddr_compare(addr llm_wl[removeWhitelistSlot], addr_in):
      discard c_memset(addr llm_wl[removeWhitelistSlot], 0, sizeof(BdAddr).csize_t)
      llm_wl_type[removeWhitelistSlot] = 0xFF
      return true
  return false

proc llm_util_check_address_validity*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  ## Returns 0 on valid, error code otherwise
  return 0

proc llm_util_check_evt_mask*(evt_bit: uint8): bool {.exportc, cdecl.} =
  let byte_idx = evt_bit div 8
  let bit_idx = evt_bit mod 8
  if byte_idx < 8:
    return (hci_le_evt_mask[byte_idx] and (1'u8 shl bit_idx)) != 0
  return false

proc llm_util_check_map_validity*(map: ptr uint8): bool {.exportc, cdecl.} =
  ## Check if channel map has at least 2 used channels
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  var enabledDataChannelCount = 0
  for channelMapByteIndex in 0 ..< 5:
    let channelMapByte = mapBytes[channelMapByteIndex]
    for channelMapBitIndex in 0 ..< 8:
      if channelMapByteIndex * 8 + channelMapBitIndex < 37:  # Only 37 data channels
        if (channelMapByte and (1'u8 shl channelMapBitIndex)) != 0:
          inc enabledDataChannelCount
  return enabledDataChannelCount >= 2

proc llm_util_get_channel_map*(map: ptr uint8) {.exportc, cdecl.} =
  discard c_memset(map, 0xFF, 5)
  # Mask out bits above channel 36
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  mapBytes[4] = mapBytes[4] and 0x1F

proc llm_ch_map_update*(): uint32 {.exportc, cdecl.} =
  var nextMap: array[5, uint8]
  let maps = llmChannelMaps()
  for masterChannelMapByteIndex in 0 ..< nextMap.len:
    nextMap[masterChannelMapByteIndex] = maps.masterMap[masterChannelMapByteIndex]
  if not llm_util_check_map_validity(addr nextMap[0]):
    llm_util_get_channel_map(addr nextMap[0])
  for localChannelMapByteIndex in 0 ..< nextMap.len:
    maps.localMap[localChannelMapByteIndex] = nextMap[localChannelMapByteIndex]
  lld_ch_map_set(addr nextMap[0])
  0

proc llm_ch_map_update_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  llm_ch_map_update()

proc llm_link_disc*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX.uint16:
    llc_env[conhdl] = nil
  0

proc llm_util_get_supp_features*(): uint64 {.exportc, cdecl.} =
  return NimBleConservativeLeFeatures

proc llm_util_set_public_addr*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  lld_util_set_bd_address(addr_in)

proc llm_wl_clr*() {.exportc, cdecl.} =
  discard c_memset(addr llm_wl[0], 0, sizeof(llm_wl).csize_t)
  discard c_memset(addr llm_wl_type[0], 0xFF, sizeof(llm_wl_type).csize_t)

proc llm_wl_dev_add*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  if llm_util_bl_add(addr_in, addr_type):
    return 0
  return 0x07  # Memory capacity exceeded

proc llm_wl_dev_add_hdl*(params: pointer): uint8 {.exportc, cdecl.} =
  return 0

proc llm_wl_dev_rem*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  if llm_util_bl_rem(addr_in, addr_type):
    return 0
  return 0x02  # Unknown connection identifier

proc llm_wl_dev_rem_hdl*(params: pointer): uint8 {.exportc, cdecl.} =
  return 0

proc llm_bad_channel_sort*(ch_assess: pointer) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
