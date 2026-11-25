# SM's registration of the AP station with MM (state 3).
#
# scanu_join_cfm_handler links the channel context to the STA VIF and sends
# MM_STA_ADD_REQ with smSend. MM answers SM's request in place
# (smStaAddAnswer), so the confirmation needs no allocation and always
# arrives. A request SM no longer waits on is not applied. An answer SM no
# longer waits on registered a station nobody will use: it is deleted.

type SmStaAddAnswer = object
  ## MM_STA_ADD_CFM as MM sends it to SM: the pinned three-byte confirmation,
  ## then the registered station's delete epoch (port-only).
  cfm: MmStaAddCfmPayload
  stationEpoch: uint32

static: doAssert sizeof(SmStaAddAnswer).uint32 <= MmStaAddReqPayloadSize

proc smStaAddAnswer(request: pointer; status, station, hardware: uint8) =
  ## MM's answer to SM's MM_STA_ADD_REQ: the request becomes MM_STA_ADD_CFM.
  cast[ptr SmStaAddAnswer](request)[] = SmStaAddAnswer(
    cfm: MmStaAddCfmPayload(status: status, staIdx: station, hwStaIdx: hardware),
    stationEpoch: staDeleteEpoch(station))
  keMsgHdrFromPayload(request).paramLen = sizeof(SmStaAddAnswer).uint32
  ke_msg_forward_and_change_id(request, MM_STA_ADD_CFM, TASK_SM, TASK_MM)

proc smStaAddStation(answer: pointer): uint8 =
  ## The station `answer` registered and that is still registered, or 0xFF.
  if answer == nil or
      keMsgHdrFromPayload(answer).paramLen != sizeof(SmStaAddAnswer).uint32: return 0xFF
  let registered = cast[ptr SmStaAddAnswer](answer)
  if registered.cfm.status != 0 or
      not staDeleteIsCurrent(registered.cfm.staIdx, registered.stationEpoch): return 0xFF
  registered.cfm.staIdx

proc smStaAddRetire(answer: pointer) =
  ## An answer SM no longer waits on (SM was reset or the attempt ended):
  ## delete the station it registered, unless that is already gone. If the
  ## attempt ended because its STA VIF was removed, the station is on no
  ## VIF's list and mm_sta_del leaves it valid, as every station of a
  ## removed VIF (mmStaDelTry). The blob asserts state 3 here instead.
  let station = smStaAddStation(answer)
  if station != 0xFF: mm_sta_del(station)
