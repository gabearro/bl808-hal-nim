## Stateful host fuzzer for WiFi connect management-frame sequencing.
##
## This exercises the simplified host replay model with malformed scan RSNs,
## auth/assoc responses, deauth/disassoc noise, and EAPOL/data frames in random
## order. The point is not RF fidelity; it catches parser and state-machine
## assumptions before they become device-only failures.

import ../src/bl808/wifi/fw/mgmt_replay
import ../src/bl808/wifi/fw/rsn_parse

type
  ModelState = enum
    msIdle,
    msAuthStarting,
    msAuthenticating,
    msActivating,
    msConnected,
    msFailed

var rngState: uint64 = 0xA5A5_7E57_C0DE_2026'u64

proc rnd(): uint32 =
  var x = rngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rngState = x
  (x and 0xFFFF_FFFF'u64).uint32

proc rndByte(): uint8 = (rnd() and 0xFF'u32).uint8

proc putLe16(buf: var seq[uint8]; off: int; value: uint16) =
  buf[off] = (value and 0xFF'u16).uint8
  buf[off + 1] = ((value shr 8) and 0xFF'u16).uint8

proc ptrFor(buf: var seq[uint8]): pointer =
  if buf.len == 0: nil else: addr buf[0]

proc validRsnIe(akms: openArray[uint8]): seq[uint8] =
  result = @[
    WifiIeIdRsn, 0,
    0x01'u8, 0x00'u8,
    0x00'u8, 0x0F'u8, 0xAC'u8, 0x04'u8,
    0x01'u8, 0x00'u8,
    0x00'u8, 0x0F'u8, 0xAC'u8, 0x04'u8
  ]
  let akmCountOffset = result.len
  result.setLen(result.len + 2)
  putLe16(result, akmCountOffset, akms.len.uint16)
  for akm in akms:
    result.add 0x00'u8
    result.add 0x0F'u8
    result.add 0xAC'u8
    result.add akm
  result[1] = (result.len - 2).uint8

proc randomIeBuffer(): seq[uint8] =
  result = newSeq[uint8]((rnd() mod 192).int)
  for i in 0 ..< result.len:
    result[i] = rndByte()
  case rnd() mod 6
  of 0:
    result.add validRsnIe([0x02'u8])
  of 1:
    result.add validRsnIe([0x08'u8])
  of 2:
    result.add validRsnIe([0x02'u8, 0x08'u8])
  of 3:
    var truncated = validRsnIe([0x02'u8, 0x08'u8])
    truncated.setLen((rnd() mod truncated.len.uint32).int)
    result.add truncated
  else:
    discard

proc mgtInd(fc, a, b, c: uint16): seq[uint8] =
  result = newSeq[uint8](38)
  putLe16(result, 0, 38)
  putLe16(result, 2, fc)
  putLe16(result, 32, a)
  putLe16(result, 34, b)
  putLe16(result, 36, c)

proc randomMgtInd(): seq[uint8] =
  case rnd() mod 8
  of 0:
    result = mgtInd(0x00B0'u16, 0, 2, 0) # valid open-system auth response
  of 1:
    result = mgtInd(0x00B0'u16, 0, uint16(rnd() and 0xFFFF'u32), 0) # bad seq likely
  of 2:
    result = mgtInd(0x0010'u16, 0, 0, uint16((rnd() mod 64) + 1)) # assoc success
  of 3:
    result = mgtInd(0x0010'u16, 0, uint16(rnd() and 0xFFFF'u32), 0) # assoc fail/zero aid
  of 4:
    result = mgtInd(0x00C0'u16, 0, 0, uint16(rnd() and 0xFFFF'u32)) # deauth
  of 5:
    result = mgtInd(0x00A0'u16, 0, 0, uint16(rnd() and 0xFFFF'u32)) # disassoc
  else:
    result = newSeq[uint8]((rnd() mod 64).int)
    for i in 0 ..< result.len:
      result[i] = rndByte()

proc randomDataFrame(): seq[uint8] =
  let machdrLen = int(rnd() mod 40)
  let payloadLen = int(rnd() mod 256)
  result = newSeq[uint8](machdrLen + 8 + payloadLen)
  for i in 0 ..< result.len:
    result[i] = rndByte()
  if result.len >= 2:
    let fc =
      if (rnd() and 1) == 0: 0x0008'u16
      else: uint16(rnd() and 0xFFFF'u32)
    putLe16(result, 0, fc)
  if result.len >= machdrLen + 8 and (rnd() mod 3) != 0:
    result[machdrLen + 0] = 0xAA
    result[machdrLen + 1] = 0xAA
    result[machdrLen + 2] = 0x03
    result[machdrLen + 3] = 0x00
    result[machdrLen + 4] = 0x00
    result[machdrLen + 5] = 0x00
    putLe16(result, machdrLen + 6, 0x8E88'u16)

proc smReplayState(state: ModelState): uint16 =
  case state
  of msAuthStarting: ReplaySmAuthStartingState
  of msAuthenticating: ReplaySmAuthenticatingState
  of msActivating, msConnected: ReplaySmActivatingState
  else: 0'u16

proc step(state: var ModelState; ev: WifiReplayEvent) =
  case ev.kind
  of wrAuthOpenSuccess:
    doAssert state == msAuthStarting
    doAssert ev.seq == 2'u16
    state = msAuthenticating
  of wrAuthFailure:
    if state == msAuthStarting:
      state = msFailed
  of wrAssocSuccess:
    doAssert state == msAuthenticating
    doAssert ev.aid != 0'u16
    state = msActivating
  of wrAssocFailure:
    if state == msAuthenticating:
      state = msFailed
  of wrEapol:
    doAssert state == msActivating or state == msConnected
    if state == msActivating:
      state = msConnected
  else:
    discard

proc checkStructuredBreaks() =
  doAssert replayClassifyRxuMgtInd(
    mgtInd(0x00B0'u16, 0, 1, 0), ReplaySmAuthStartingState).kind == wrAuthFailure
  doAssert replayClassifyRxuMgtInd(
    mgtInd(0x0010'u16, 0, 0, 0), ReplaySmAuthenticatingState).kind == wrAssocFailure
  doAssert replayMgmtTimeoutAction(
    ReplaySmAuthStartingState, retryCount = 0, maxRetries = 3) == wrTimeoutRetryAuth
  doAssert replayMgmtTimeoutAction(
    ReplaySmAuthenticatingState, retryCount = 0, maxRetries = 3) == wrTimeoutRetryAuth
  doAssert replayMgmtTimeoutAction(
    ReplaySmAuthStartingState, retryCount = 3, maxRetries = 3) == wrTimeoutFail
  doAssert replayMgmtTimeoutAction(
    ReplaySmActivatingState, retryCount = 0, maxRetries = 3) == wrTimeoutIgnored
  var fakeMgmtWithSnap = randomDataFrame()
  if fakeMgmtWithSnap.len >= 2:
    putLe16(fakeMgmtWithSnap, 0, 0x00B0'u16)
    doAssert replayClassifyDataFrame(fakeMgmtWithSnap).kind != wrEapol

proc main() =
  checkStructuredBreaks()
  var attempts = 0
  var frames = 0
  for _ in 0 ..< 50_000:
    var ies = randomIeBuffer()
    let mask = wifiRsnAuthMaskFromIeBuffer(ptrFor(ies), ies.len.uint32)
    let keyMgmt = wifiPreferredKeyMgmtFromMask(mask, pmfCapable = (rnd() and 1) != 0)
    discard wifiDot11AuthTypeFromKeyMgmt(keyMgmt)
    doAssert (mask and not (WifiAuthMaskPsk or WifiAuthMaskPskSha256 or
        WifiAuthMaskSae)) == 0

    var state =
      if keyMgmt == WifiKeyMgmtNone and (rnd() mod 4) == 0: msFailed
      else: msAuthStarting
    for _ in 0 ..< int((rnd() mod 32) + 1):
      if (rnd() and 1) == 0:
        let ev = replayClassifyRxuMgtInd(randomMgtInd(), smReplayState(state))
        step(state, ev)
      else:
        let machdrLen = int(rnd() mod 40)
        let ev = replayClassifyDataFrameForState(
          randomDataFrame(), smReplayState(state), machdrLen)
        step(state, ev)
      let timeoutAction = replayMgmtTimeoutAction(
        smReplayState(state), rnd() mod 5, 3)
      doAssert timeoutAction != wrTimeoutIgnored or
        (state != msAuthStarting and state != msAuthenticating)
      doAssert timeoutAction != wrTimeoutRetryAuth or
        (state == msAuthStarting or state == msAuthenticating)
      inc frames
      if state == msFailed:
        break
    inc attempts

  echo "fuzz_wifi_connect_state: ", attempts, " attempts, ", frames,
       " frames, no invalid state transitions"
  echo "PASS"

main()
