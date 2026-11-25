# What SM's frame builders share: the attempt's AP, the bounds of the frame
# being built and the auth response SM expects.
#
# sm_auth_send, sm_assoc_req_send, sm_handle_connection and
# sm_handle_supplicant_result build their frame in one pass and then commit:
# enter the state that waits for it (smGo, smDeauthWait), arm the response
# deadline, push. sm_deauth_send, which nothing waits for, only pushes. The
# frame is the builder's from txl_frame_get until the push, which consumes it
# whether it accepts it or not, so nothing in the build re-checks it.
#
# Two calls of a build can run SM code: txl_frame_get, whose pool recovery
# completes queued frames (their callbacks can depart a channel and drain RX
# into the supplicant), and the supplicant's SAE frame builder. A builder
# therefore takes the live operation's stamp at entry and commits, or reports
# a failure, only while opCurrent(smOwn.op, stamp); otherwise it releases its
# frame and returns, because whatever moved SM on owns the next transition.
#
# A frame whose VIF or station was replaced after txl_frame_get, or that a TX
# reset overtook, is refused by the push (txlFramePreparationCurrent) and
# released without a callback. For auth and assoc the response deadline then
# retries, as it does for a frame the AP did not answer.

var smAuthExpected {.wifiCtrl.}: SmAuthResponseExpectation

proc smJoinPeer(vifIdx: uint8; station: var uint8; peer: var MacAddrView): bool =
  ## The AP station the attempt joined on STA VIF `vifIdx`, and its address.
  if vifIdx >= MAX_VIFS.uint8: return false
  let vif = vifChannelForIdx(vifIdx)
  if vif.vifIdx != vifIdx or vif.vifType != VIF_TYPE_STA: return false
  station = vif.staIdx
  if station >= STA_MGMT_FREE_STAS.uint8: return false
  let sta = staInfoForIdx(station)
  if sta.valid == 0 or sta.instNbr != vifIdx or sta.macAddr != vif.bssid or
      not macPtrIsSpecific(addr sta.macAddr[0]):
    return false
  peer.bytes = sta.macAddr
  true

proc smTxFits(frame: pointer; buffer: pointer; length: uint32): bool =
  ## `length` bytes at `buffer` lie in the MAC header buffer of internal frame
  ## `frame`. The exported builders pass no frame and are not bounded here.
  if buffer == nil: return false
  if frame == nil: return true
  let base = cast[uint](addr hostTxLinkDescAt(hostTxDescAt(frame).bufDesc).macHeader[0])
  let address = cast[uint](buffer)
  address >= base and address - base <= TxlFramePayloadSize.uint and
    length.uint <= TxlFramePayloadSize.uint - (address - base)

proc smAuthRecordResponse(stamp: uint32; algorithm: uint8; txSequence: uint16): bool =
  ## Expect the response to auth transaction `txSequence`, sent by SM
  ## operation `stamp` (state 6). Any later operation makes it stale.
  case algorithm
  of 0'u8:
    if txSequence != 1: return false
  of 1'u8:
    if txSequence notin [1'u16, 3'u16]: return false
  of 3'u8:
    if txSequence notin [1'u16, 2'u16]: return false
  else: return false
  smAuthExpected = SmAuthResponseExpectation(stamp: stamp, algorithm: algorithm,
    txSequence: txSequence)
  true

proc smAuthCancelResponse(stamp: uint32) =
  ## Operation `stamp` did not send its request after all.
  if smAuthExpected.stamp == stamp: smAuthExpected.txSequence = 0

proc smAuthResponseMatches(algorithm, responseSequence: uint16): bool =
  ## The response answers the request the live SM operation sent.
  var txSequence: uint16
  case algorithm
  of 0'u16:
    if responseSequence != 2: return false
    txSequence = 1
  of 1'u16:
    if responseSequence notin [2'u16, 4'u16]: return false
    txSequence = if responseSequence == 2: 1'u16 else: 3'u16
  of 3'u16:
    if responseSequence notin [1'u16, 2'u16]: return false
    txSequence = responseSequence
  else: return false
  opCurrent(smOwn.op, smAuthExpected.stamp) and
    smAuthExpected.algorithm == algorithm.uint8 and smAuthExpected.txSequence == txSequence

proc smAuthConsumeResponse(algorithm, responseSequence: uint16): bool =
  if not smAuthResponseMatches(algorithm, responseSequence): return false
  smAuthExpected.txSequence = 0
  true
