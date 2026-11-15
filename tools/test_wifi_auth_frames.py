"""Exercise production auth body construction and shared-key RX routing."""

from pathlib import Path

from test_wifi_deferred_auth import run_nim
from test_wifi_disconnect_tx import FW, procedure


def layouts(*names: str) -> str:
    source = (FW / "layout_types.nim").read_text()
    return "type\n" + "".join(
        "  " + name + source.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
        for name in names
    )


BODY_PLATFORM = r"""
const TxlFramePayloadSize = 512'u32
type
  SmTxBuildContext = object
    valid: bool
  Header {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  Link = object
    before: array[16, uint8]
    macHeader: array[512, uint8]
    after: array[16, uint8]
  Desc = object
    bufDesc, hwDesc, callback, callbackArg: pointer
    vifIdx, hdrLen, secTailLen, staIdx, staInfoIdx: uint8
    frameLen, seqPassthrough: uint16
  Hw = object
    payloadStart, payloadEnd, frameLen: uint32
  Vif = object
    vifIdx: uint8
var
  link: Link
  desc: Desc
  hw: Hw
  releases, failures, protections: int
  securityLength: uint32
  saeFailed: bool
  interruptsEnabled = true
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc hostTxDescAt(p: pointer): ptr Desc = cast[ptr Desc](p)
proc macFrameControlAt(p: pointer): ptr Header = cast[ptr Header](p)
proc authChallengeBodyAt(p: pointer): ptr AuthChallengeBodyView =
  cast[ptr AuthChallengeBodyView](p)
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc txl_get_seq_ctrl(): uint16 = 0x4560
proc txl_frame_release(p: pointer; callback: bool) =
  doAssert p == (addr desc) and not callback
  inc releases
proc sm_connect_ind(status, reason: uint16) =
  doAssert status == 2 and reason == 0xFFFF
  inc failures
proc txu_cntrl_sechdr_len_compute(p: pointer; tail: ptr uint32): uint32 =
  doAssert p == addr desc
  inc protections
  tail[] = securityLength
  securityLength
proc txu_cntrl_sec_hdr_append(p, endAddress: pointer; update: uint32): pointer =
  let start = cast[ptr UncheckedArray[uint8]](cast[uint](endAddress) - securityLength.uint)
  for i in 0 ..< securityLength.int: start[i] = (0xD0 + i).uint8
  start
proc me_build_sae_authenticate(p: pointer; algo, sequence, status: uint16; vif: uint32): uint32 =
  doAssert algo == 3 and status == 0 and vif == 1
  if saeFailed: return 0
  let body = cast[ptr AuthFixedBodyView](p)
  body[] = AuthFixedBodyView(authAlgo: algo, authSeq: sequence, statusCode: status)
  6
proc meBuildSaeAuthenticate(p: pointer; algo, sequence, status: uint16; vif: uint32;
                            build: ptr SmTxBuildContext): uint32 =
  me_build_sae_authenticate(p, algo, sequence, status, vif)
proc smTxFrameCurrent(build: var SmTxBuildContext): bool = true
proc smTxFail(build: var SmTxBuildContext; status: uint16) =
  txl_frame_release(addr desc, false)
  sm_connect_ind(status, 0xFFFF)
proc reset() =
  desc = Desc(hwDesc: addr hw)
  hw = Hw(payloadStart: 0x60001000)
  for b in link.before.mitems: b = 0xA5
  for b in link.after.mitems: b = 0xA5
  for b in link.macHeader.mitems: b = 0xA5
  releases = 0
  failures = 0
  protections = 0
  securityLength = 4
  saeFailed = false
"""

BODY_CHECKS = r"""
var challenge: array[128, uint8]
for i in 0 ..< challenge.len: challenge[i] = (i xor 0xC3).uint8
for algo in [0'u8, 1, 3]:
  for sequence in [1'u16, 2, 3, 4]:
    for hasChallenge in [false, true]:
      reset()
      build(algo, sequence, if hasChallenge: addr challenge[0] else: nil)
      let sharedThird = algo == 1 and sequence == 3
      if sharedThird and not hasChallenge:
        doAssert releases == 1 and failures == 1 and protections == 0
        continue
      doAssert failures == 0 and releases == 0
      let secLen = if sharedThird: 4 else: 0
      let bodyLen = if hasChallenge and algo != 3: 136 else: 6
      let total = 24 + secLen + bodyLen + secLen
      doAssert desc.frameLen == total.uint16 and desc.seqPassthrough == total.uint16
      doAssert hw.frameLen == total.uint32 + 4
      doAssert hw.payloadEnd == hw.payloadStart + total.uint32 - 1
      doAssert desc.callback == nil and desc.callbackArg == addr desc
      doAssert desc.hdrLen == secLen.uint8 and desc.secTailLen == secLen.uint8
      doAssert protections == sharedThird.int
      let header = cast[ptr Header](addr link.macHeader[0])
      doAssert header.frameControl == (if sharedThird: 0x40B0'u16 else: 0x00B0'u16)
      doAssert header.duration == 0 and header.seqCtrl == 0x4560
      doAssert header.addr1 == [6'u8, 5, 4, 3, 2, 1]
      doAssert header.addr2 == [2'u8, 3, 4, 5, 6, 7]
      doAssert header.addr3 == header.addr1
      let body = cast[ptr AuthChallengeBodyView](addr link.macHeader[24 + secLen])
      doAssert body.fixed == AuthFixedBodyView(authAlgo: algo.uint16, authSeq: sequence, statusCode: 0)
      if bodyLen == 136:
        doAssert body.challengeTag == 16 and body.challengeLen == 128
        doAssert body.challengeText == challenge
      for i in total ..< link.macHeader.len: doAssert link.macHeader[i] == 0xA5
      for b in link.before: doAssert b == 0xA5
      for b in link.after: doAssert b == 0xA5
      if sharedThird:
        for i in 0 ..< 4: doAssert link.macHeader[24 + i] == (0xD0 + i).uint8
        # Encryption hardware writes the ICV; the builder only reserves it.
        for i in 164 ..< 168: doAssert link.macHeader[i] == 0xA5
for length in [0'u32, 8, 12, high(uint32)]:
  reset()
  securityLength = length
  build(1, 3, addr challenge[0])
  doAssert releases == 1 and failures == 1 and desc.frameLen == 0
reset()
saeFailed = true
build(3, 1, nil)
doAssert releases == 1 and failures == 1 and desc.frameLen == 0
"""


def test_auth_frame_bytes_and_lengths(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    sender = procedure(source, "sm_auth_send")
    body = sender.split("  # Build auth frame header.\n", 1)[1].split("  let authRawLen", 1)[0]
    wrapper = r"""
proc build(authAlgo: uint8; authSeqNum: uint16; challenge: pointer) =
  var build: SmTxBuildContext
  let authChallenge = challenge
  let frame = cast[pointer](addr desc)
  let desc = addr desc
  let link = addr link
  let hdr = cast[ptr Header](addr link.macHeader[0])
  let vifIdx = 1'u8
  var vif = Vif(vifIdx: vifIdx)
  let effectiveStaIdx = 3'u8
  var bssid = [6'u8, 5, 4, 3, 2, 1]
  var own = [2'u8, 3, 4, 5, 6, 7]
  let bssidPtr = cast[pointer](addr bssid[0])
  let vifTxSa = cast[pointer](addr own[0])
"""
    run_nim(tmp_path, layouts("AuthFixedBodyView", "AuthChallengeBodyView")
            + BODY_PLATFORM
            + procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_protect_mgmt_frame")
            + procedure(source, "me_build_authenticate") + wrapper + body + BODY_CHECKS)


def test_shared_auth_rx_uses_transaction_three(tmp_path: Path) -> None:
    from test_wifi_auth_response import CASES, source

    run_nim(tmp_path, source() + CASES["owned_shared_challenge"]
            + CASES["open_and_shared_completion"])
