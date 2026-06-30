const
  ReplaySmAuthStartingState* = 5'u16
  ReplaySmAuthenticatingState* = 6'u16
  ReplaySmActivatingState* = 9'u16

type
  WifiReplayKind* = enum
    wrTooShort,
    wrIgnored,
    wrAuthDroppedWrongState,
    wrAuthOpenSuccess,
    wrAuthFailure,
    wrAssocDroppedWrongState,
    wrAssocSuccess,
    wrAssocFailure,
    wrEapol,
    wrData

  WifiReplayTimeoutAction* = enum
    wrTimeoutIgnored,
    wrTimeoutRetryAuth,
    wrTimeoutFail

  WifiReplayEvent* = object
    kind*: WifiReplayKind
    frameCtrl*: uint16
    status*: uint16
    seq*: uint16
    aid*: uint16
    eapolLen*: uint32

proc replayLe16*(buf: openArray[uint8]; off: int): uint16 {.inline.} =
  buf[off].uint16 or (buf[off + 1].uint16 shl 8)

proc replayClassifyRxuMgtInd*(buf: openArray[uint8]; smState: uint16):
    WifiReplayEvent =
  ## Classify the RXU management indication shape used by rxu_mgt_ind_handler_sm:
  ## frame control at +2, auth fixed fields at +32, assoc status at +34.
  if buf.len < 4:
    return WifiReplayEvent(kind: wrTooShort)
  result.frameCtrl = replayLe16(buf, 2)
  case result.frameCtrl and 0xFC'u16
  of 0xB0'u16:
    if buf.len < 38:
      result.kind = wrTooShort
      return
    if smState != ReplaySmAuthStartingState:
      result.kind = wrAuthDroppedWrongState
      return
    let authAlgo = replayLe16(buf, 32)
    result.seq = replayLe16(buf, 34)
    result.status = replayLe16(buf, 36)
    if authAlgo == 0'u16 and result.seq == 2'u16 and result.status == 0'u16:
      result.kind = wrAuthOpenSuccess
    else:
      result.kind = wrAuthFailure
  of 0x10'u16, 0x30'u16:
    if buf.len < 38:
      result.kind = wrTooShort
      return
    if smState != ReplaySmAuthenticatingState:
      result.kind = wrAssocDroppedWrongState
      return
    result.status = replayLe16(buf, 34)
    result.aid = replayLe16(buf, 36) and 0x3FFF'u16
    result.kind =
      if result.status == 0'u16 and result.aid != 0'u16: wrAssocSuccess
      else: wrAssocFailure
  else:
    result.kind = wrIgnored

proc replayClassifyDataFrame*(buf: openArray[uint8]; machdrLen: int = 24):
    WifiReplayEvent =
  ## Minimal local model of rx_upper's EAPOL classifier: RFC1042 SNAP followed
  ## by little-endian EtherType 0x888E at the MSDU start.
  if machdrLen < 0 or buf.len < machdrLen + 8:
    return WifiReplayEvent(kind: wrTooShort)
  result.frameCtrl = replayLe16(buf, 0)
  if (result.frameCtrl and 0x000C'u16) != 0x0008'u16:
    result.kind = wrIgnored
    return
  let snap = machdrLen
  let hasRfc1042 =
    buf[snap + 0] == 0xAA'u8 and buf[snap + 1] == 0xAA'u8 and
    buf[snap + 2] == 0x03'u8 and buf[snap + 3] == 0x00'u8 and
    buf[snap + 4] == 0x00'u8 and buf[snap + 5] == 0x00'u8
  if not hasRfc1042:
    result.kind = wrData
    return
  let etherType = replayLe16(buf, snap + 6)
  if etherType == 0x8E88'u16:
    result.kind = wrEapol
    result.eapolLen = (buf.len - machdrLen - 8).uint32
  else:
    result.kind = wrData

proc replayClassifyDataFrameForState*(buf: openArray[uint8]; smState: uint16;
                                      machdrLen: int = 24): WifiReplayEvent =
  ## State-aware EAPOL classifier matching the station connect contract: EAPOL
  ## is only meaningful once association has completed and SM is activating.
  result = replayClassifyDataFrame(buf, machdrLen)
  if result.kind == wrEapol and smState != ReplaySmActivatingState:
    result.kind = wrIgnored

proc replayMgmtTimeoutAction*(smState: uint16; retryCount, maxRetries: uint32):
    WifiReplayTimeoutAction =
  ## A management TX ACK only proves the AP received the frame at MAC level.
  ## It must not advance auth/assoc state without a matching management
  ## response, otherwise local tests hide the exact failure seen on hardware.
  if smState != ReplaySmAuthStartingState and
      smState != ReplaySmAuthenticatingState:
    return wrTimeoutIgnored
  if retryCount >= maxRetries:
    return wrTimeoutFail
  wrTimeoutRetryAuth
