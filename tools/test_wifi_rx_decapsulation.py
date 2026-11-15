"""Run the production RX dispatcher with host-side descriptors and MAC state."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw/rx_upper.nim"

PLATFORM = r"""
var sessionCurrent = true
var rxGeneration: uint32
proc rxStationCurrent(p: pointer): bool = sessionCurrent
proc rxUploadGeneration(p: pointer): uint32 = rxGeneration
proc rxUploadCurrent(p: pointer; generation: uint32): bool = generation == rxGeneration
proc rxKeyCurrent(desc, key: pointer): bool = true
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  RxuMgmtPnTid = 8'u8
  RxuCcmpHeaderScratchLen = 64
  RxuCcmpDataScratchLen = 2352
type
  CoList = object
    first: pointer
  MacDataFrameHeaderView {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  FourAddr {.packed.} = object
    header: MacDataFrameHeaderView
    addr4: array[6, uint8]
  LlcSnapHeaderView {.packed.} = object
    prefix: array[6, uint8]
    ethertype: uint16
  Msdu {.packed.} = object
    snap: LlcSnapHeaderView
  Ethernet {.packed.} = object
    da, sa: array[6, uint8]
    ethertype: uint16
  Key = object
    keyMaterial: array[152, uint8]
    cipherType, staIdx: uint8
  VifKeySlotView = Key
  Sequences = object
    nonQosSeqCtrl: uint16
    qosSeqCtrl: array[8, uint16]
  StaInfoView = object
    valid, instNbr, controlPortState: uint8
    rateWord: uint16
    macAddr: array[6, uint8]
    sequences: Sequences
  Security = object
    cipher: uint8
  Vif = object
    vifType, vifIdx: uint8
    macAddr: array[6, uint8]
    security: Security
  RxSwDescView = object
    hwFlags, frameControlFlags, bufferOffset: uint32
    mpduLengthBytes: uint16
    bufferChain: pointer
  Mpdu = object
    swDesc: pointer
    curDesc: pointer
  Chain = object
    next, frameData: pointer
  RxuCntrlEnvView = object
    secInfo0, secInfo1, hwRxhdr: uint32
    secKeyPtr: pointer
    secFlags, meshFlag, stripLen, staIdx, vifIdx, dstIdx: uint8
    frameCtrl, seqCtrl, seqNum, bssidSeq: uint16
    fragNum, tid, machdrLen: uint8
    da, sa: array[6, uint8]
    uploadList: CoList
  MicFailure = object
    bssid: array[6, uint8]
    pnLow, pnHigh: uint32
    isGroup, keyId, vifIdx: uint8
var
  envState: RxuCntrlEnvView
  stations: array[7, StaInfoView]
  vifs: array[2, Vif]
  key: Key
  rxu_mgmt_dup_addr: array[6, uint8]
  rxu_cntrl_duplicate_flag: uint8
  rxuCcmpHeaderScratch: array[64, uint8]
  rxuCcmpDataScratch, rxuCcmpPlainScratch: array[2352, uint8]
  bytes: array[2048, uint8]
  chain: Chain
  sw: RxSwDescView
  mpdu: Mpdu
  transferred, prepared, eapolCalls, replayCalls, softwareCalls: int
  eapolLength: uint32
  eapolBytes: seq[uint8]
  micCalls, micBytes, allocations, frees: int
  allocationFails, badMic: bool
  replayFresh = true
  nimFwDbgRxuSwCcmpFail, nimFwDbgRxuSwCcmpAttempt: uint32
  nimFwDbgRxuSwCcmpOk, nimFwDbgRxuSwCcmpLen: uint32

proc rxuCntrlEnvView(): ptr RxuCntrlEnvView = addr envState
proc rxMpduDescView(p: pointer): ptr Mpdu = cast[ptr Mpdu](p)
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  if p == (addr mpdu) and mpdu.swDesc == (addr sw): addr sw else: nil
proc rxFramePayload(p: ptr RxSwDescView): pointer = cast[ptr Chain](p.bufferChain).frameData
proc macDataFrameAt(p: pointer): ptr MacDataFrameHeaderView = cast[ptr MacDataFrameHeaderView](p)
proc macQos4AddrFrameAt(p: pointer): ptr FourAddr = cast[ptr FourAddr](p)
proc rxFrameBufferChainAt(p: pointer): ptr Chain = cast[ptr Chain](p)
proc rxFrameBytes(p: pointer): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](p)
proc rxFrameCursor(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc rxMsdu(p: pointer; offset: uint8): ptr LlcSnapHeaderView =
  cast[ptr LlcSnapHeaderView](rxFrameCursor(p, offset.uint))
proc rxMsduView(p: pointer; offset: uint8): ptr Msdu =
  cast[ptr Msdu](rxFrameCursor(p, offset.uint))
proc rxMsduPayload(p: ptr Msdu): pointer = rxFrameCursor(p, 8)
proc rxQosControl(p: pointer; headerLen: uint8): uint16 =
  let header = macDataFrameAt(p)
  let offset = if (header.frameControl and 0x0300) == 0x0300: 30 else: 24
  cast[ptr uint16](rxFrameCursor(p, offset.uint))[]
proc rxAddrPtr(p: pointer): pointer = p
proc rxCopyAddr(dst, src: pointer) = copyMem(dst, src, 6)
proc rxEthernetRewriteHeader(p: pointer; offset: uint8): ptr Ethernet =
  cast[ptr Ethernet](rxFrameCursor(p, offset.uint))
proc rxSnapIsRfc1042(p: ptr LlcSnapHeaderView): bool =
  p.prefix == [0xAA'u8, 0xAA, 3, 0, 0, 0]
proc rxSnapIsBridgeTunnel(p: ptr LlcSnapHeaderView): bool =
  p.prefix == [0xAA'u8, 0xAA, 3, 0, 0, 0xF8]
proc rxSnapTraceLo(p: ptr LlcSnapHeaderView): uint32 = 0
proc rxSnapTraceHi(p: ptr LlcSnapHeaderView): uint32 = 0
proc staInfoForIdx(i: uint8): ptr StaInfoView = addr stations[i]
proc staRxSequence(p: ptr StaInfoView): ptr Sequences = addr p.sequences
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifSecurity(p: ptr Vif): ptr Security = addr p.security
proc hal_machw_search_addr(p: pointer; index: int): int = 0
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc c_memcmp(a, b: pointer; size: csize_t): cint =
  cmpMem(a, b, size.int).cint
proc rxu_cntrl_protected_handle(p: pointer; flags: uint32): cint =
  envState.machdrLen += (if (flags and 0x1C) == 20: 4'u8 else: 8'u8)
  envState.secFlags = if (flags and 0x1C) == 24: 3 else: 2
  envState.secKeyPtr = addr key
  1
proc rxu_cntrl_check_pn(p: pointer; tid: uint8): cint =
  inc replayCalls
  1
proc rxuPnFresh(p: pointer; tid: uint8): bool = replayFresh
proc nim_ccmp_decrypt(tk, hdr, data: pointer; length: uint32;
                       output: pointer; outputLen: ptr uint32): bool =
  inc softwareCalls
  false
proc mm_cfg_element_keepalive_timestamp_update() = discard
proc apm_handle_eapol_input(sta: uint8; data: pointer; length: uint32) =
  inc eapolCalls
  eapolLength = length
  eapolBytes = newSeq[uint8](length.int)
  copyMem(addr eapolBytes[0], data, length.int)
proc sm_handle_eapol_input(sta: uint8; sa, data: pointer; length: uint32) =
  inc eapolCalls
  eapolLength = length
  eapolBytes = newSeq[uint8](length.int)
  copyMem(addr eapolBytes[0], data, length.int)
proc me_mic_init(ctx, key, da, sa: pointer; priority: uint8) = inc micCalls
proc me_mic_calc(ctx, data: pointer; length: uint32) = micBytes += length.int
proc me_mic_end(ctx: pointer) =
  let words = cast[ptr array[4, uint32]](ctx)
  words[0] = if badMic: 0'u32 else: 0x04030201'u32
  words[1] = 0x08070605'u32
proc allocateEapol(length: uint32): pointer {.cdecl.} =
  inc allocations
  if not allocationFails: result = alloc(length.int)
proc freeEapol(p: pointer) {.cdecl.} =
  inc frees
  dealloc(p)
proc blOpsFunc(offset: int): pointer =
  case offset
  of 184: cast[pointer](allocateEapol)
  of 188: cast[pointer](freeEapol)
  else: nil
proc assert_rec(file, fn: cstring; line: int) = doAssert false
proc ke_msg_alloc(id: uint16; dst, src, length: int): pointer = nil
proc rxMicFailureIndAt(p: pointer): ptr MicFailure = cast[ptr MicFailure](p)
proc ke_msg_send(p: pointer) = discard
proc ke_msg_free_payload(p: pointer) = discard
proc rxTransferFrame(p: pointer): bool =
  inc transferred
  mpdu.curDesc = cast[pointer](1)
  true
proc rxl_mpdu_transfer(p: pointer) = discard rxTransferFrame(p)
proc rxu_cntrl_desc_prepare(p: pointer) = inc prepared
proc rxu_mpdu_upload_and_indicate(p: pointer) = discard
proc irqSave(): uint32 = 0
proc irqRestore(flags: uint32) = discard
proc rxu_mgt_frame_check(p: pointer; sta: uint8): uint32 = 0
proc vif_mgmt_get_first_ap_inf(): pointer = nil
proc apm_send_mlme(vif: pointer; fc: uint16; dest, callback, arg, extra: pointer) = discard
proc ke_evt_set(mask: uint32) = discard
proc nimFwDbgRxuDhcpMsg(p: pointer; headerLen: uint8; length: uint16): uint32 = 0
template nimFwTrace2U32(args: varargs[untyped]) = discard
template nimFwDbgRecordRxuDupDrop(args: varargs[untyped]) = discard
template nimFwDbgRecordRxuPnDrop(args: varargs[untyped]) = discard
template nimFwDbgRecordRxuPnAccept(args: varargs[untyped]) = discard
template nimFwDbgRxuIpv4Preupload(args: varargs[untyped]) = discard
template nimFwDbgRecordRxuDataDrop(args: varargs[untyped]) = discard
const TASK_API = 9
const TASK_ME = 3
"""

CHECKS = r"""
proc setup(fc: uint16; headerLen, payloadLen: int; secure = false) =
  sessionCurrent = true
  rxGeneration = 0
  envState = default(RxuCntrlEnvView)
  for b in bytes.mitems: b = 0x35
  for sta in stations.mitems:
    sta = StaInfoView(valid: 1, controlPortState: 2, rateWord: 0x888E,
      sequences: Sequences(nonQosSeqCtrl: 0xFFFF))
  vifs = default(typeof(vifs))
  vifs[0].security.cipher = secure.uint8
  key = Key(cipherType: 2)
  chain = Chain(frameData: addr bytes[0])
  sw = RxSwDescView(bufferChain: addr chain, hwFlags: 0x0204201C,
    mpduLengthBytes: (headerLen + payloadLen).uint16)
  mpdu = Mpdu(swDesc: addr sw)
  let hdr = macDataFrameAt(addr bytes[0])
  hdr.frameControl = fc
  hdr.seqCtrl = 0x1230
  hdr.addr1 = [0x02'u8, 1, 2, 3, 4, 5]
  hdr.addr2 = [0x04'u8, 6, 7, 8, 9, 10]
  hdr.addr3 = [0x06'u8, 11, 12, 13, 14, 15]
  vifs[0].macAddr = hdr.addr1
  if (fc and 0x0300) == 0x0300:
    macQos4AddrFrameAt(hdr).addr4 = [0x08'u8, 16, 17, 18, 19, 20]
  if (fc and 0x0080) != 0:
    let offset = if (fc and 0x0300) == 0x0300: 30 else: 24
    bytes[offset] = 3
    bytes[offset + 1] = 0
  transferred = 0
  prepared = 0
  eapolCalls = 0
  replayCalls = 0
  softwareCalls = 0
  micCalls = 0
  micBytes = 0
  allocations = 0
  frees = 0
  badMic = false
  allocationFails = false
  replayFresh = true
  eapolBytes.setLen(0)

proc snapAt(offset: int; etherType: uint16; bridge = false) =
  let p = rxMsdu(addr bytes[0], offset.uint8)
  p.prefix = [0xAA'u8, 0xAA, 3, 0, 0, (if bridge: 0xF8'u8 else: 0'u8)]
  p.ethertype = ((etherType shr 8) or (etherType shl 8))
  if etherType == 0x888E:
    bytes[offset + 8] = 2
    bytes[offset + 9] = 3
    let bodyLength = max(0, sw.mpduLengthBytes.int - offset - 12)
    bytes[offset + 10] = (bodyLength shr 8).uint8
    bytes[offset + 11] = (bodyLength and 255).uint8

proc checkFrame(fc: uint16; headerLen: int; ethernetII, bridge: bool;
                etherType: uint16; payloadLen: int; rfcLlc = false;
                hardwareCipher = 28'u32) =
  setup(fc, headerLen, payloadLen)
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or hardwareCipher
  if ethernetII or bridge or rfcLlc: snapAt(headerLen, etherType, bridge)
  # An inner SNAP-like byte pattern is payload, never a header-location hint.
  if payloadLen >= 24: snapAt(headerLen + 10, 0x0800)
  let original = bytes
  let strip = headerLen - (if ethernetII or bridge: 6 else: 14)
  let hdr = macDataFrameAt(addr bytes[0])
  let toDs = (fc and 0x0100) != 0
  let fromDs = (fc and 0x0200) != 0
  let expectedDa = if toDs: hdr.addr3 else: hdr.addr1
  let expectedSa = if toDs and fromDs: macQos4AddrFrameAt(hdr).addr4
    elif fromDs: hdr.addr3
    else: hdr.addr2
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
  doAssert transferred == 1 and prepared == 1 and eapolCalls == 0
  if (fc and 0x80) != 0:
    doAssert (sw.frameControlFlags and 0x70) == 0x30, "lost QoS TID in upload metadata"
  doAssert softwareCalls == 0, "hardware RX must not retry software decryption"
  doAssert envState.machdrLen.int == headerLen
  doAssert sw.bufferOffset.int == strip, "payload signature changed header offset"
  doAssert sw.mpduLengthBytes.int == headerLen + payloadLen - strip
  let eth = rxEthernetRewriteHeader(addr bytes[0], strip.uint8)
  doAssert eth.da == expectedDa and eth.sa == expectedSa
  for i in 0 ..< strip: doAssert bytes[i] == original[i]
  for i in headerLen + payloadLen ..< bytes.len:
    doAssert bytes[i] == original[i], "write beyond MPDU length"
  if ethernetII or bridge:
    doAssert bytes[strip + 12] == (etherType shr 8).uint8
    doAssert bytes[strip + 13] == (etherType and 255).uint8
    for i in headerLen + 8 ..< headerLen + payloadLen:
      doAssert bytes[i] == original[i], "payload changed during decapsulation"
  else:
    doAssert bytes[strip + 12] == (payloadLen shr 8).uint8
    doAssert bytes[strip + 13] == (payloadLen and 255).uint8
    for i in headerLen ..< headerLen + payloadLen:
      doAssert bytes[i] == original[i], "LLC payload was truncated or rewritten"

# Unprotected IP must not bypass the BSS security policy; EAPOL still works.
setup(0x0208, 24, 40, secure = true)
snapAt(24, 0x0800)
let unprotected = bytes
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0, "accepted unprotected secured-BSS data"
doAssert transferred == 0 and prepared == 0 and bytes == unprotected
setup(0x0208, 24, 40, secure = true)
snapAt(24, 0x888E)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert eapolCalls == 1 and eapolLength == 32 and transferred == 0
for protocol in 1'u8 .. 5'u8:
  for vif in 0'u8 .. 1'u8:
    setup(0x0208, 24, 40)
    vifs[vif].security.cipher = protocol
    stations[0].instNbr = vif
    snapAt(24, 0x0806)
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 0 and eapolCalls == 0
for vifType in [0'u8, 1, 2]:
  setup(0x0208, 24, 40, secure = true)
  vifs[0].vifType = vifType
  snapAt(24, 0x888E)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert eapolCalls == (if vifType in [0'u8, 2'u8]: 1 else: 0)
  doAssert transferred == 0

# Test the actual offset selected by base MAC, QoS, HT, WEP and CCMP headers.
for fc in [0x0008'u16, 0x0108, 0x0208, 0x8208, 0x0288, 0x0298, 0x02A8, 0x02B8,
           0x8288, 0x8298, 0x4208, 0x4288,
           0x0308, 0x0388, 0x8388, 0x4308, 0x4388]:
  let baseLen = (if (fc and 0x0300) == 0x0300: 30 else: 24) +
    (if (fc and 0x80) != 0: 2 else: 0) +
    (if (fc and 0x8080) == 0x8080: 4 else: 0)
  let headerLen = baseLen + (if (fc and 0x4000) != 0: 8 else: 0)
  for etherType in [0x0800'u16, 0x0806, 0x86DD]:
    checkFrame(fc, headerLen, true, false, etherType, 42)
  for length in [3, 7, 8, 30, 300, 1800]:
    checkFrame(fc, headerLen, false, false, 0, length)
  checkFrame(fc, headerLen, false, true, 0x8137, 40)
  checkFrame(fc, headerLen, false, false, 0x8137, 40, rfcLlc = true)
  checkFrame(fc, headerLen, false, false, 0x80F3, 40, rfcLlc = true)

checkFrame(0x4208, 28, true, false, 0x0800, 40, hardwareCipher = 20)
checkFrame(0x4208, 28, false, false, 0, 40, hardwareCipher = 20)
for payloadLen in 0 ..< 8:
  setup(0x0208, 24, payloadLen, secure = true)
  snapAt(24, 0x888E)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert eapolCalls == 0 and transferred == 0

for index in [0'u32, 7, 15, 0x108, 0x3FF]:
  setup(0x0208, 24, 40)
  sw.hwFlags = (sw.hwFlags and not (0x3FF'u32 shl 15)) or (index shl 15)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 0
setup(0x0208, 24, 40)
stations[0].instNbr = 2
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert transferred == 0
doAssert rxu_cntrl_frame_handle(nil) == 0
setup(0x0208, 24, 40)
mpdu.swDesc = nil
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
mpdu.swDesc = addr sw
sw.bufferChain = nil
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
sw.bufferChain = addr chain
chain.frameData = nil
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0

# Truncated MAC, security and EAPOL headers must not read bytes beyond the MPDU.
for length in 0 ..< 24:
  setup(0x0208, 24, 20)
  sw.mpduLengthBytes = length.uint16
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 0 and eapolCalls == 0
for length in 24 ..< 32:
  setup(0x4208, 32, 20)
  sw.mpduLengthBytes = length.uint16
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 0 and replayCalls == 0
"""


def procedure(source: str, name: str) -> str:
    match = re.search(rf"^proc {name}\*?\(", source, re.M)
    assert match, name
    end = re.search(r"^(?:proc|template|func|\{\.emit:) ", source[match.end():], re.M)
    return source[match.start():match.end() + end.start() if end else len(source)]


def dispatch_source() -> str:
    source = FW.read_text()
    handler = procedure(source, "rxu_cntrl_frame_handle")
    variables = sorted(set(re.findall(r"\bnimFwDbg\w+\b(?!\s*\()", handler)))
    diagnostic_vars = "\nvar\n" + "\n".join(f"  {name}: uint32" for name in variables) + "\n"
    test_source = PLATFORM + diagnostic_vars
    layout = (ROOT / "src/bl808/wifi/fw/layout_types.nim").read_text()
    for name in ["RxEapolHeaderView", "RxAmsduSubframeHeaderView"]:
        test_source += "\ntype\n  " + name + layout.split(
            "  " + name, 1
        )[1].split("\n\n  ", 1)[0] + "\n"
    test_source += procedure(layout, "rxMacHeaderLen")
    test_source += procedure(layout, "lmacGateHalfword")
    for name in ["rxu_cntrl_machdr_len_get", "rxuQosSeqCachePtr",
                 "rxuCipherIsCcmp", "rxuFindSnapOffset", "rxuTrySoftwareCcmpDecrypt",
                 "rxuCopyFrameBytes", "rxuPortAllows", "rxuAmsduValid"]:
        if re.search(rf"^proc {name}\*?\(", source, re.M):
            # Allows the same test to demonstrate the pre-fix runtime mismatch.
            test_source += procedure(source, name)
    return test_source + handler


def run_dispatch_checks(release_mode: bool, tmp_path: Path, checks: str,
                        address_sanitizer: bool = False) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "rx_dispatch.nim"
    path.write_text(dispatch_source() + checks)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    if address_sanitizer:
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(
        command + [str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("release_mode", [False, True])
def test_rx_dispatch_decapsulation_and_security(release_mode: bool, tmp_path: Path) -> None:
    run_dispatch_checks(release_mode, tmp_path, CHECKS)


@pytest.mark.parametrize("release_mode", [False, True])
def test_rx_stale_session_before_state_updates(release_mode: bool, tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
setup(0x4208, 24, 40, true)
let before = bytes
let sequenceBefore = stations[0].sequences
sessionCurrent = false
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert bytes == before and stations[0].sequences == sequenceBefore
doAssert transferred == 0 and prepared == 0 and replayCalls == 0 and eapolCalls == 0
"""
    run_dispatch_checks(release_mode, tmp_path, checks)


@pytest.mark.parametrize("release_mode", [False, True])
def test_rx_fragment_rejection(release_mode: bool, tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
for fc in [0x0208'u16, 0x0288, 0x4208, 0x4288]:
  let headerLen = 24 + (if (fc and 0x80) != 0: 2 else: 0) +
    (if (fc and 0x4000) != 0: 8 else: 0)
  for fragment in 0'u16 .. 15'u16:
    for moreFragments in [false, true]:
      if fragment == 0 and not moreFragments: continue
      setup(fc or (if moreFragments: 0x0400'u16 else: 0'u16), headerLen, 40)
      macDataFrameAt(addr bytes[0]).seqCtrl = 0x1230'u16 or fragment
      snapAt(headerLen, 0x0800)
      let original = bytes
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0, "fragment uploaded without reassembly"
      doAssert transferred == 0 and prepared == 0 and eapolCalls == 0
      doAssert bytes == original
"""
    run_dispatch_checks(release_mode, tmp_path, checks)


@pytest.mark.parametrize("release_mode", [False, True])
@pytest.mark.parametrize("address_sanitizer", [False, True])
def test_rx_eapol_integrity_and_scatter_delivery(
        release_mode: bool, address_sanitizer: bool, tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
for fc in [0x0208'u16, 0x0288, 0x4208, 0x4288]:
  let headerLen = 24 + (if (fc and 0x80) != 0: 2 else: 0) +
    (if (fc and 0x4000) != 0: 8 else: 0)
  for fragment in 0'u16 .. 15'u16:
    for more in [false, true]:
      if fragment == 0 and not more: continue
      setup(fc or (if more: 0x0400'u16 else: 0'u16), headerLen, 40)
      macDataFrameAt(addr bytes[0]).seqCtrl = 0x1230'u16 or fragment
      snapAt(headerLen, 0x888E)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert eapolCalls == 0 and replayCalls == 0 and micCalls == 0,
        "fragment reached EAPOL or changed replay state"
      doAssert stations[0].sequences.nonQosSeqCtrl == 0xFFFF
      doAssert stations[0].sequences.qosSeqCtrl[3] == 0

for extra in 0 ..< 4:
  setup(0x0208, 24, 8 + extra)
  snapAt(24, 0x888E)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert eapolCalls == 0, "truncated EAPOL header was forwarded"
for bodyLength in [29, 65535]:
  setup(0x0208, 24, 40)
  snapAt(24, 0x888E)
  bytes[34] = (bodyLength shr 8).uint8
  bytes[35] = (bodyLength and 255).uint8
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert eapolCalls == 0, "truncated EAPOL body was forwarded"

for eapol in [false, true]:
  for invalid in [false, true]:
    setup(0x4208, 32, 48, secure = true)
    sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 24
    snapAt(32, if eapol: 0x888E'u16 else: 0x0800'u16)
    # 40-byte MSDU (8-byte SNAP + 32-byte EAPOL), then 8-byte Michael MIC.
    bytes[42] = 0
    bytes[43] = 28
    for i in 0 ..< 8: bytes[72 + i] = (i + 1).uint8
    badMic = invalid
    let result = rxu_cntrl_frame_handle(addr mpdu)
    doAssert micCalls == 1 and micBytes == 40, "Michael verification was bypassed"
    if invalid:
      doAssert result == 0 and eapolCalls == 0 and transferred == 0
      doAssert replayCalls == 0 and stations[0].sequences.nonQosSeqCtrl == 0xFFFF
    else:
      doAssert replayCalls == 1
      if eapol:
        doAssert result == 0 and eapolCalls == 1 and eapolLength == 32
      else:
        doAssert result == 1 and transferred == 1
        doAssert sw.mpduLengthBytes == 46, "Michael trailer leaked into Ethernet payload"

for trailerBytes in 0 ..< 8:
  setup(0x4208, 32, trailerBytes, secure = true)
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 24
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert micCalls == 0 and replayCalls == 0

setup(0x4208, 32, 48, secure = true)
sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or 24
snapAt(32, 0x0800)
replayFresh = false
badMic = true
discard rxu_cntrl_frame_handle(addr mpdu)
doAssert micCalls == 0 and replayCalls == 0

# EAPOL padding is not part of the PDU passed to the callback.
setup(0x0208, 24, 40)
snapAt(24, 0x888E)
bytes[34] = 0
bytes[35] = 5
discard rxu_cntrl_frame_handle(addr mpdu)
doAssert eapolLength == 9

# The first subframe's DA must never be parsed as the outer SNAP header.
setup(0x0288, 26, 80)
bytes[24] = 0x83
snapAt(26, 0x888E)
discard rxu_cntrl_frame_handle(addr mpdu)
doAssert eapolCalls == 0, "A-MSDU destination address was treated as EAPOL"

for vifType in [0'u8, 2'u8]:
  for failAllocation in [false, true]:
    setup(0x0208, 24, 1800)
    vifs[0].vifType = vifType
    snapAt(24, 0x888E)
    var tailBytes: array[1736, uint8]
    var tail = Chain(frameData: addr tailBytes[0])
    for i in 0 ..< 88: tailBytes[i] = ((i * 7) and 255).uint8
    for i in 1736 ..< bytes.len: bytes[i] = 0xEE
    var expected = newSeq[uint8](1792)
    copyMem(addr expected[0], addr bytes[32], 1704)
    copyMem(addr expected[1704], addr tailBytes[0], 88)
    chain.next = addr tail
    allocationFails = failAllocation
    discard rxu_cntrl_frame_handle(addr mpdu)
    if failAllocation:
      doAssert eapolCalls == 0 and allocations == 1 and frees == 0
    else:
      doAssert eapolCalls == 1 and eapolBytes == expected,
        "EAPOL callback did not receive the DMA chain contents"
      doAssert allocations == 1 and frees == 1

# A short chain must release its temporary allocation without invoking WPA.
setup(0x0208, 24, 1800)
snapAt(24, 0x888E)
discard rxu_cntrl_frame_handle(addr mpdu)
doAssert eapolCalls == 0 and allocations == 1 and frees == 1
"""
    run_dispatch_checks(release_mode, tmp_path, checks, address_sanitizer)


@pytest.mark.parametrize("release_mode", [False, True])
@pytest.mark.parametrize("address_sanitizer", [False, True])
def test_rx_control_port(release_mode: bool, address_sanitizer: bool, tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
var localAddress = [2'u8, 3, 4, 5, 6, 7]
for state in [0'u8, 1, 2, 255]:
  var station = StaInfoView(controlPortState: state, rateWord: 0x88B5)
  for protocol in 0'u32 .. 65535'u32:
    let wireProtocol = lmacGateHalfword(protocol.uint16)
    let expected = state == 2 or (state == 1 and protocol == 0x88B5)
    doAssert rxuPortAllows(addr station, wireProtocol, true,
                          addr localAddress, addr localAddress) == expected
  doAssert rxuPortAllows(addr station, 0xB588, false,
                        addr localAddress, addr localAddress) == (state == 2)

for state in [0'u8, 1, 2, 255]:
  for configured in [0x888E'u16, 0x88B5]:
    for protocol in [0x0800'u16, 0x0806, 0x86DD, 0x888E, 0x88B5]:
      for mode in [0'u8, 2'u8]:
        setup(0x4208, 32, 40, secure = true)
        vifs[0].vifType = mode
        stations[0].controlPortState = state
        stations[0].rateWord = configured
        snapAt(32, protocol)
        let before = bytes
        let accepted = state == 2 or (state == 1 and protocol == configured)
        let result = rxu_cntrl_frame_handle(addr mpdu)
        if accepted:
          if protocol == 0x888E:
            doAssert eapolCalls == 1 and result == 0 and transferred == 0
          else:
            doAssert transferred == 1 and result == 1
        else:
          doAssert eapolCalls == 0 and transferred == 0 and result == 0,
            "closed controlled port accepted ordinary data"
          doAssert replayCalls == 0 and bytes == before
          doAssert stations[0].sequences.nonQosSeqCtrl == 0xFFFF

# A configured control protocol retains its plaintext exception.
setup(0x0208, 24, 40, secure = true)
stations[0].controlPortState = 1
stations[0].rateWord = 0x88B5
snapAt(24, 0x88B5)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1

for state in [1'u8, 2'u8]:
  for protocol in [0x888E'u16, 0x88B5]:
    for group in [false, true]:
      setup(0x4208, 32, 40)
      stations[0].controlPortState = state
      stations[0].rateWord = protocol
      snapAt(32, protocol)
      let hdr = macDataFrameAt(addr bytes[0])
      hdr.addr1 = if group: [1'u8, 0x80, 0xC2, 0, 0, 3]
        else: [2'u8, 0xEE, 0, 0, 0, 1]
      let result = rxu_cntrl_frame_handle(addr mpdu)
      if group:
        doAssert eapolCalls + transferred == 1
      else:
        doAssert result == 0 and eapolCalls == 0 and transferred == 0,
          "control protocol was sent to a foreign destination"

setup(0x0208, 24, 40)
stations[0].controlPortState = 1
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0, "native LLC bypassed port policy"

# Apply the port restriction to every subframe, not just the first.
for state in [0'u8, 1, 2]:
  for mixed in [false, true]:
    setup(0x4288, 34, 92, secure = true)
    stations[0].controlPortState = state
    stations[0].rateWord = 0x88B5
    bytes[24] = 0x83
    let hdr = macDataFrameAt(addr bytes[0])
    for offset in [34, 82]:
      copyMem(addr bytes[offset], addr hdr.addr1[0], 6)
      copyMem(addr bytes[offset + 6], addr hdr.addr3[0], 6)
      bytes[offset + 12] = 0
      bytes[offset + 13] = if offset == 34: 32 else: 30
      snapAt(offset + 14, if mixed and offset == 82: 0x0800'u16 else: 0x88B5'u16)
    let result = rxu_cntrl_frame_handle(addr mpdu)
    let accepted = state == 2 or (state == 1 and not mixed)
    doAssert (result == 1) == accepted
    doAssert transferred == accepted.int
    if not accepted:
      doAssert replayCalls == 0 and stations[0].sequences.qosSeqCtrl[3] == 0
"""
    run_dispatch_checks(release_mode, tmp_path, checks, address_sanitizer)


@pytest.mark.parametrize("release_mode", [False, True])
def test_rx_amsdu_preserves_subframes(release_mode: bool, tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
for fc in [0x0288'u16, 0x0388, 0x8288, 0x4288, 0x4388]:
  let headerLen = (if (fc and 0x300) == 0x300: 30 else: 24) + 2 +
    (if (fc and 0x8000) != 0: 4 else: 0) +
    (if (fc and 0x4000) != 0: 8 else: 0)
  setup(fc, headerLen, 80)
  let qosOffset = if (fc and 0x300) == 0x300: 30 else: 24
  bytes[qosOffset] = 0x83
  let hdr = macDataFrameAt(addr bytes[0])
  copyMem(addr bytes[headerLen], addr hdr.addr1[0], 6)
  for i in 0 ..< 6: bytes[headerLen + 6 + i] = (0x20 + i).uint8
  bytes[headerLen + 12] = 0
  bytes[headerLen + 13] = 66
  snapAt(headerLen + 14, 0x86DD)
  let original = bytes
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
  doAssert transferred == 1 and prepared == 1 and eapolCalls == 0
  doAssert (sw.frameControlFlags and 0x71) == 0x31
  doAssert sw.bufferOffset.int == headerLen, "A-MSDU offset points inside the MAC header"
  doAssert sw.mpduLengthBytes == 80
  doAssert envState.stripLen.int == headerLen
  doAssert bytes == original, "A-MSDU subframe was rewritten as one Ethernet packet"
"""
    run_dispatch_checks(release_mode, tmp_path, checks)


@pytest.mark.parametrize("release_mode", [False, True])
@pytest.mark.parametrize("address_sanitizer", [False, True])
def test_rx_amsdu_address_policy(release_mode: bool, address_sanitizer: bool,
                                tmp_path: Path) -> None:
    checks = CHECKS.split("# Unprotected IP")[0] + r"""
proc setupAggregate(fc: uint16; vifType = 0'u8; firstLength = 40): tuple[header, second: int] =
  result.header = (if (fc and 0x300) == 0x300: 30 else: 24) + 2 +
    (if (fc and 0x4000) != 0: 8 else: 0)
  let firstSize = (14 + firstLength + 3) and not 3
  result.second = result.header + firstSize
  setup(fc, result.header, firstSize + 14 + 8)
  vifs[0].vifType = vifType
  let qosOffset = if (fc and 0x300) == 0x300: 30 else: 24
  bytes[qosOffset] = 0x83
  let frame = macDataFrameAt(addr bytes[0])
  let da = if (fc and 0x100) != 0: frame.addr3 else: frame.addr1
  let sa = if (fc and 0x200) != 0: frame.addr3 else: frame.addr2
  for offset in [result.header, result.second]:
    copyMem(addr bytes[offset], unsafeAddr da[0], 6)
    copyMem(addr bytes[offset + 6], unsafeAddr sa[0], 6)
    let length = if offset == result.header: firstLength else: 8
    bytes[offset + 12] = (length shr 8).uint8
    bytes[offset + 13] = (length and 255).uint8

for protected in [false, true]:
  let secureBit = if protected: 0x4000'u16 else: 0'u16
  for ds in [0x0000'u16, 0x0100, 0x0200, 0x0300]:
    let mode = if ds == 0x100: 2'u8 else: 0'u8
    let offsets = setupAggregate(0x0088'u16 or ds or secureBit, mode)
    let before = bytes
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
    doAssert transferred == 1 and bytes == before
    doAssert (sw.frameControlFlags and 1) != 0

  for invalid in 0 .. 5:
    let fc = (if invalid == 1: 0x0188'u16 else: 0x0288'u16) or secureBit
    let offsets = setupAggregate(fc, if invalid == 1: 2'u8 else: 0'u8)
    case invalid
    of 0: bytes[offsets.second] = 0x22  # Wrong individual DA on STA RX.
    of 1: bytes[offsets.second + 6] = 0x22  # Forged source on AP RX.
    of 2: bytes[offsets.second + 6] = 0x01  # Group source is never valid.
    of 3:
      let snapDa = [0xAA'u8, 0xAA, 3, 0, 0, 0]
      copyMem(addr bytes[offsets.second], unsafeAddr snapDa[0], 6)
    of 4: macDataFrameAt(addr bytes[0]).addr1[0] = 1  # Group receiver.
    else: bytes[offsets.second + 13] = 0xFF  # Incomplete final payload.
    let before = bytes
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0,
      "invalid aggregate address or length reached the host"
    doAssert transferred == 0 and prepared == 0 and replayCalls == 0
    doAssert stations[0].sequences.qosSeqCtrl[3] == 0 and bytes == before

# STA may receive multicast subframes inside a unicast MPDU; AP may receive
# traffic for other destinations, and four-address bridging preserves both.
for mode in [0'u8, 2'u8]:
  let offsets = setupAggregate(if mode == 0: 0x0288'u16 else: 0x0188'u16, mode)
  bytes[offsets.second] = if mode == 0: 1'u8 else: 0x44'u8
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
let bridgedSource = setupAggregate(0x0288)
bytes[bridgedSource.second + 6] = 0x44
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
let bridgeOffsets = setupAggregate(0x0388)
bytes[bridgeOffsets.second] = 0x44
bytes[bridgeOffsets.second + 6] = 0x66
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1

# Exercise each padding length and reject incomplete final headers/payloads.
for firstLength in 1 .. 8:
  discard setupAggregate(0x0288, firstLength = firstLength)
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
  for missing in 1 .. 21:
    discard setupAggregate(0x0288, firstLength = firstLength)
    sw.mpduLengthBytes -= missing.uint16
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 0 and replayCalls == 0
for badLength in [0, 2305, 65535]:
  for first in [false, true]:
    let offsets = setupAggregate(0x0288)
    let offset = if first: offsets.header else: offsets.second
    bytes[offset + 12] = (badLength shr 8).uint8
    bytes[offset + 13] = (badLength and 255).uint8
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 0

for cipher in [20'u32, 24'u32]:
  discard setupAggregate(0x4288)
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or cipher
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
  doAssert transferred == 0 and micCalls == 0 and replayCalls == 0

# The second subframe header straddles the physical DMA boundary.
let splitOffsets = setupAggregate(0x4288, firstLength = 1680)
doAssert splitOffsets.second < 1736 and splitOffsets.second + 14 > 1736
var tailBytes: array[1736, uint8]
let tailLength = sw.mpduLengthBytes.int - 1736
copyMem(addr tailBytes[0], addr bytes[1736], tailLength)
var tail = Chain(frameData: addr tailBytes[0])
chain.next = addr tail
for index in 1736 ..< bytes.len: bytes[index] = 0xEE
doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
"""
    run_dispatch_checks(release_mode, tmp_path, checks, address_sanitizer)


@pytest.mark.parametrize("address_sanitizer", [False, True])
def test_rx_scatter_copy_boundaries(address_sanitizer: bool, tmp_path: Path) -> None:
    checks = r"""
var payloads: array[38, array[1744, uint8]]
var nodes: array[38, Chain]
for index in 0 ..< nodes.len:
  nodes[index].frameData = addr payloads[index][0]
  if index + 1 < nodes.len: nodes[index].next = addr nodes[index + 1]
  for byteIndex in 0 ..< 1736:
    payloads[index][byteIndex] = (((index * 1736 + byteIndex) * 13) and 255).uint8
  for guard in 1736 ..< 1744: payloads[index][guard] = 0xDE
var desc = RxSwDescView(bufferChain: addr nodes[0], mpduLengthBytes: 65535)
let original = payloads
for offset in [0'u32, 1, 24, 32, 1735, 1736, 1737, 3471, 65530, 65535]:
  for length in [0'u32, 1, 2, 4, 8, 1735, 1736, 1737, 3472, 65535]:
    var output = newSeq[uint8](length.int + 16)
    for b in output.mitems: b = 0xDD
    let accepted = rxuCopyFrameBytes(addr desc, offset, length, addr output[8])
    doAssert accepted == (length <= 65535 - offset)
    if accepted:
      for i in 0 ..< length.int:
        doAssert output[i + 8] == (((offset.int + i) * 13) and 255).uint8
    else:
      for b in output: doAssert b == 0xDD
    for i in 0 ..< 8:
      doAssert output[i] == 0xDD and output[output.len - 1 - i] == 0xDD
    doAssert payloads == original
doAssert not rxuCopyFrameBytes(addr desc, 65536, 0, addr bytes[0])
doAssert not rxuCopyFrameBytes(addr desc, 0, 1, nil)
nodes[0].next = nil
doAssert not rxuCopyFrameBytes(addr desc, 1735, 2, addr bytes[0])
"""
    run_dispatch_checks(False, tmp_path, checks, address_sanitizer)
