## Host fuzzer/replay harness for WiFi management/EAPOL dispatch decisions.
##
## Build/run:
##   nim c -r --skipParentCfg:on --skipUserCfg:on --checks:on tools/fuzz_wifi_mgmt_replay.nim

import ../src/bl808/wifi/fw/mgmt_replay

var rngState: uint64 = 0xD1B54A32D192ED03'u64

proc rnd(): uint32 =
  var x = rngState
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rngState = x
  (x and 0xFFFFFFFF'u64).uint32

proc rndByte(): uint8 = (rnd() and 0xFF'u32).uint8

proc putLe16(buf: var seq[uint8]; off: int; value: uint16) =
  buf[off] = (value and 0xFF'u16).uint8
  buf[off + 1] = ((value shr 8) and 0xFF'u16).uint8

proc authInd(status: uint16 = 0'u16; seq: uint16 = 2'u16): seq[uint8] =
  result = newSeq[uint8](38)
  putLe16(result, 0, 38)
  putLe16(result, 2, 0x00B0'u16)
  putLe16(result, 32, 0)
  putLe16(result, 34, seq)
  putLe16(result, 36, status)

proc assocInd(status: uint16 = 0'u16; aid: uint16 = 7'u16): seq[uint8] =
  result = newSeq[uint8](38)
  putLe16(result, 0, 38)
  putLe16(result, 2, 0x0010'u16)
  putLe16(result, 34, status)
  putLe16(result, 36, aid)

proc eapolDataFrame(payloadLen: int): seq[uint8] =
  result = newSeq[uint8](24 + 8 + payloadLen)
  putLe16(result, 0, 0x0008'u16)
  let snap = 24
  result[snap + 0] = 0xAA
  result[snap + 1] = 0xAA
  result[snap + 2] = 0x03
  result[snap + 3] = 0x00
  result[snap + 4] = 0x00
  result[snap + 5] = 0x00
  putLe16(result, snap + 6, 0x8E88'u16)

proc checkStructured() =
  let authOk = replayClassifyRxuMgtInd(authInd(), ReplaySmAuthStartingState)
  doAssert authOk.kind == wrAuthOpenSuccess
  doAssert authOk.seq == 2
  doAssert replayClassifyRxuMgtInd(authInd(), ReplaySmAuthenticatingState).kind ==
    wrAuthDroppedWrongState

  let assocOk = replayClassifyRxuMgtInd(assocInd(), ReplaySmAuthenticatingState)
  doAssert assocOk.kind == wrAssocSuccess
  doAssert assocOk.aid == 7
  doAssert replayClassifyRxuMgtInd(assocInd(), ReplaySmAuthStartingState).kind ==
    wrAssocDroppedWrongState

  let eap = replayClassifyDataFrame(eapolDataFrame(99))
  doAssert eap.kind == wrEapol
  doAssert eap.eapolLen == 99
  doAssert replayClassifyDataFrameForState(
    eapolDataFrame(99), ReplaySmAuthStartingState).kind == wrIgnored
  doAssert replayClassifyDataFrameForState(
    eapolDataFrame(99), ReplaySmActivatingState).kind == wrEapol

proc main() =
  checkStructured()
  var iters = 0
  for _ in 0 ..< 250_000:
    let n = (rnd() mod 256).int
    var buf = newSeq[uint8](n)
    for i in 0 ..< n:
      buf[i] = rndByte()
    let state = uint16(rnd() mod 12)
    discard replayClassifyRxuMgtInd(buf, state)
    discard replayClassifyDataFrame(buf, int(rnd() mod 40))
    discard replayClassifyDataFrameForState(buf, state, int(rnd() mod 40))
    inc iters
  echo "fuzz_wifi_mgmt_replay: ", iters, " iterations, no OOB / dispatch stable"
  echo "PASS"

main()
