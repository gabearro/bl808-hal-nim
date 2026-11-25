# SM's BSS parameter batch (state 4).
#
# Once MM has registered the AP station, sm_set_bss_param (smBssBegin)
# queues the nine requests of pinned sm_set_bss_param on sm_env's
# pendingBssParams, enters state 4 and sends the first. Every answer goes
# through smBssNext, which ends the attempt if its STA VIF is gone and
# otherwise sends the next request (sm_send_next_bss_param); after the answer
# to the last, ME_SET_ACTIVE_REQ, authentication starts
# (me_set_active_cfm_handler_sm). Each request goes out with smSendReserved,
# so its answer needs no allocation and always arrives (station_sm.nim). Every
# end of the attempt leaves state 4, and its teardown frees the requests not
# sent yet. The batch does not watch the AP station; nor does the blob.

const
  SmBssRequests = [ME_SET_PS_DISABLE_REQ, MM_SET_BSSID_REQ, MM_SET_BASIC_RATES_REQ,
    MM_SET_BEACON_INT_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ,
    MM_SET_EDCA_REQ, ME_SET_ACTIVE_REQ]
  SmBssTasks = [TASK_ME, TASK_MM, TASK_MM, TASK_MM, TASK_MM, TASK_MM,
    TASK_MM, TASK_MM, TASK_ME]
  SmBssLengths = [MeSetPsDisableReqPayloadSize, MmSetBssidReqPayloadSize,
    MmSetBasicRatesReqPayloadSize, MmSetBeaconIntReqPayloadSize,
    MmSetEdcaReqPayloadSize, MmSetEdcaReqPayloadSize, MmSetEdcaReqPayloadSize,
    MmSetEdcaReqPayloadSize, MeSetActiveReqPayloadSize]

proc smBssCancel() =
  ## Free the requests the batch has not sent.
  let pending = addr smEnvView().pendingBssParams
  while pending.first != nil:
    ke_msg_free(co_list_pop_front(pending))

proc smBssFail() =
  sm_connect_ind(WLAN_FW_JOIN_NETWORK_FAILURE.uint16, 0xFFFF)

proc smBssNext(): bool {.discardable.} =
  ## The batch starts, or SM took the answer to its request in flight: end
  ## the attempt if its STA VIF is gone or the next request's reply cannot be
  ## reserved, else send that request. True when no request is left: the
  ## last, ME_SET_ACTIVE_REQ, is answered and authentication may start.
  let sm = smEnvView()
  if not smAttemptStaVif(connectInfoView(sm.connectInfo).vifIdx):
    smBssFail()
    return false
  let node = co_list_pop_front(addr sm.pendingBssParams)
  if node == nil: return true
  if not smSendReserved(keMsgPayload(cast[ptr KeMsgHdr](node))): smBssFail()

proc smBssBegin() =
  ## Queue the batch, enter state 4 and send its first request; or end the
  ## attempt. SM is in state 3 and MM has registered the AP station.
  let sm = smEnvView()
  let connection = sm.connectInfo
  if connection == nil: return
  let vifIdx = connectInfoView(connection).vifIdx
  if not smAttemptStaVif(vifIdx):
    smBssFail()
    return
  let vif = vifChannelForIdx(vifIdx)
  if vif.basicRates[0] == 0 or vif.basicRates[0].int >= vif.basicRates.len:
    smBssFail()
    return
  var requests: array[SmBssRequests.len, pointer]
  for index, id in SmBssRequests:
    requests[index] = ke_msg_try_alloc(id, SmBssTasks[index], TASK_SM, SmBssLengths[index])
    if requests[index] == nil:
      for request in requests:
        if request != nil: ke_msg_free(keMsgHdrFromPayload(request))
      smBssFail()
      return
  let band = if vif.operChan == nil: 0'u8
             else: cast[ptr ScanChannelEntry](vif.operChan).band
  let uapsd = psEnvView().uapsdPeriod != 0 and vifEdcaPsGate(vif) < 0
  let qosMask = connectInfoView(connection).qosInfo
  cast[ptr MeSetPsDisableReqPayload](requests[0])[] =
    MeSetPsDisableReqPayload(disable: 1, vifIdx: vifIdx)
  cast[ptr MmSetBssidReqPayload](requests[1])[] =
    MmSetBssidReqPayload(bssid: vif.bssid, vifIdx: vifIdx)
  cast[ptr MmSetBasicRatesReqPayload](requests[2])[] = MmSetBasicRatesReqPayload(
    rateBitfield: me_legacy_rate_bitfield_build(cast[pointer](addr vif.basicRates[0]), 1),
    vifIdx: vifIdx, band: band)
  cast[ptr MmSetBeaconIntReqPayload](requests[3])[] =
    MmSetBeaconIntReqPayload(interval: vif.beaconIntervalTu, vifIdx: vifIdx)
  # The four access categories are programmed before ME activates the VIF.
  for ac in 0'u8 ..< 4'u8:
    cast[ptr MmSetEdcaReqPayload](requests[4 + ac.int])[] = MmSetEdcaReqPayload(
      edcaParam: cast[ptr uint32](addr vif.edcaParams[ac.uint * 4])[],
      acmFlag: ac, vifIdx: vifIdx,
      uapsdAc: (uapsd and (mac_ac2uapsd[ac] and qosMask) != 0).uint8)
  cast[ptr MeSetActiveReqPayload](requests[8])[] =
    MeSetActiveReqPayload(active: 1, vifIdx: vifIdx)
  for request in requests:
    co_list_push_back(addr sm.pendingBssParams,
                      cast[ptr CoListHdr](keMsgHdrFromPayload(request)))
  smGo(SmSettingBssState)
  smBssNext()
