"""Run production TX admission, sequence assignment, and MAC header construction.

Only platform/crypto dependencies are replaced.
Station-table bytes use target offsets; header types and layout code are taken
directly from the firmware. No radio or hardware accesses occur.
"""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const STA_ENTRY_SIZE = 368
const STA_INFO_TAB_ENTRIES = 7
const MAX_VIFS = 2
type
  StaInfoView {.packed.} = object
    link: uint32
    macAddr: array[6, uint8]
    prefix: array[18, uint8]
    paidGid: uint32
    beforeValid: array[10, uint8]
    valid: uint8
    beforeSeq: array[9, uint8]
    seqStorage: array[18, uint8]
    rateWord: uint16
    controlPortState: uint8
    beforeKey: array[171, uint8]
    keyMat: pointer
    tail: array[124 - sizeof(pointer), uint8]
  HostTxDescView = object
    staIdx, staInfoIdx, vifIdx, hostVifType: uint8
    frameLen, seqAssigned, seqPassthrough, seqOut: uint16
    hdrLen, qosExtLen, secTailLen: uint8
    policy, bufDesc, hwDesc, queueFirst: pointer
    da, sa: array[6, uint8]
    bufferPtrs: array[4, uint32]
    bufferLens: array[4, uint32]
  KeyList = object
    pairwiseKey: pointer
  Vif = object
    vifType, psFlags: uint8
    keyPsState: uint32
    macAddr, bssid: array[6, uint8]
    keys: tuple[flags: uint32]
var
  sta_info_tab: array[STA_INFO_TAB_ENTRIES * STA_ENTRY_SIZE + 64, uint8]
  vifs: array[2, Vif]
  securityHeaderLen, securityTailLen: uint32
  ready = true
  calls: seq[string]
  pushedDesc: pointer
  pushedAc: uint8
  pushResult: uint8
  droppedStatus: uint32
  policyMarker: uint32
  retiringVif: int = -1
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[5, uint32]
  txResetEpoch: uint32
  interrupts = true
  onStage: proc(stage: string)

proc visit(stage: string) =
  if onStage != nil: onStage(stage)
proc staDeleteEpoch(station: uint8): uint32 =
  if station < 5: stationEpochs[station] else: 0
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txSecurityCurrent(d: ptr HostTxDescView): bool = true
proc txSecurityLengthsCurrent(d: ptr HostTxDescView): tuple[header, tail: int] =
  (securityHeaderLen.int, securityTailLen.int)
proc txSecurityForget(d: pointer) = discard
proc txlVifIsRetiring(vif: uint8): bool = vif.int == retiringVif
proc txlResetting(): bool = false
proc txlConfirmUnqueuedHost(p: pointer; status: uint32; ac: uint8) =
  doAssert false, "unexpected reset cancellation"
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifKeyPointers(v: ptr Vif): ptr tuple[flags: uint32] = addr v.keys
proc txSecurityKeyListAt(p: pointer): ptr KeyList = cast[ptr KeyList](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc debugLoadLe32(p: pointer): uint32 = cast[ptr uint32](p)[]
proc nimFwConnectTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-CT] txu_push_eapol ": visit("entry")
  elif s == "[WIFI-CT] txu_sec ": visit("security_trace")
proc txl_cntrl_tx_check(v: pointer): bool =
  visit("ready")
  ready
proc txl_cntrl_inc_pck_cnt(ac: uint8) = calls.add("drop-count")
proc irqSave(): uint32 =
  calls.add("irq-save")
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(state: uint32) =
  doAssert state in [0'u32, 8'u32]
  interrupts = state == 8
  calls.add("irq-restore")
proc txl_cfm_push(p: pointer; flags, ac: uint32) =
  droppedStatus = flags
  calls.add("confirm")
proc txu_cntrl_sechdr_len_compute(p: pointer; tail: ptr uint32): uint32 =
  tail[] = securityTailLen
  calls.add("security")
  visit("security")
  securityHeaderLen
proc me_check_rc(station: uint8) =
  calls.add("rate")
  visit("rate")
proc me_update_buffer_control(p: pointer): pointer =
  calls.add("policy")
  visit("policy")
  addr policyMarker
proc txl_cntrl_push(p: pointer; ac: uint8): uint8 =
  pushedDesc = p
  pushedAc = ac
  calls.add("push")
  pushResult
proc txu_cntrl_sec_hdr_append(p, dest: pointer; enabled: uint32): pointer =
  let start = cast[pointer](cast[uint](dest) - securityHeaderLen.uint)
  let bytes = cast[ptr UncheckedArray[uint8]](start)
  for i in 0 ..< securityHeaderLen.int: bytes[i] = 0xD3
  start
"""

CHECKS = r"""
static:
  doAssert sizeof(StaInfoView) == STA_ENTRY_SIZE
  doAssert offsetof(StaInfoView, paidGid) == 28
  doAssert offsetof(StaInfoView, seqStorage) == 52
  doAssert offsetof(StaInfoView, rateWord) == 70
  doAssert offsetof(StaInfoView, keyMat) == 244
  doAssert offsetof(StaTxSequenceOverlay, seqCounters) == 52
  doAssert sizeof(StaTxSequenceOverlay) == 70

proc readSeq(station: int; tid: uint8): uint16 =
  let offset = station * STA_ENTRY_SIZE + 52 + 2 * tid.int
  sta_info_tab[offset].uint16 or (sta_info_tab[offset + 1].uint16 shl 8)

proc reset() =
  onStage = nil
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  retiringVif = -1
  interrupts = true
  for b in sta_info_tab.mitems: b = 0xA5
  for station in 0 ..< STA_INFO_TAB_ENTRIES:
    let sta = staInfoForIdx(station.uint8)
    sta.valid = 1
    sta.controlPortState = 2
    sta.rateWord = 0x888E
    sta.keyMat = nil
    sta.macAddr = [2'u8, 4, 6, 8, 10, station.uint8]
    for tid in 0 ..< 9:
      staTxSequence(sta).seqCounters[tid] =
        ((4090 + station * 37 + tid * 11) mod 4096).uint16
  vifs = default(typeof(vifs))
  vifs[1].vifType = 2
  for v in vifs.mitems:
    v.macAddr = [2'u8, 12, 14, 16, 18, 20]
    v.bssid = [2'u8, 22, 24, 26, 28, 30]
  ready = true
  securityHeaderLen = 0
  securityTailLen = 0

proc checkTx(station: int; tid, vifIndex: uint8; etherType: uint16;
             protectedFrame = false) =
  var desc = HostTxDescView(staInfoIdx: station.uint8, staIdx: tid,
    vifIdx: vifIndex, frameLen: lmacGateHalfword(etherType),
    seqPassthrough: 0x1234, seqAssigned: 0x7777,
    da: [2'u8, 32, 34, 36, 38, 40], sa: [2'u8, 42, 44, 46, 48, 50])
  let sequence = if tid == 0xFF: 0x7777'u16 else: readSeq(station, tid)
  var expected = sta_info_tab
  if tid != 0xFF:
    let offset = station * STA_ENTRY_SIZE + 52 + 2 * tid.int
    let next = (sequence + 1) mod 4096
    expected[offset] = (next and 0xFF).uint8
    expected[offset + 1] = (next shr 8).uint8
  calls.setLen(0)
  pushedDesc = nil
  let ac = tid and 3
  doAssert txu_cntrl_push(addr desc, ac) == (pushResult != 0)
  doAssert calls == @["irq-save", "security", "rate", "policy", "push", "irq-restore"]
  doAssert pushedDesc == cast[pointer](addr desc) and pushedAc == ac
  doAssert sta_info_tab == expected, "TX modified another TID or station field"
  doAssert desc.seqAssigned == sequence
  doAssert desc.seqOut == 0x1234
  doAssert desc.policy == cast[pointer](addr policyMarker)
  doAssert vifs[vifIndex].psFlags == 0
  let macLength = if tid == 0xFF: 24 else: 26
  let snapLength = if etherType >= 1536: 8 else: 0
  let headerLength = macLength + snapLength + securityHeaderLen.int
  doAssert desc.hdrLen.int == headerLength
  doAssert desc.qosExtLen.int == snapLength
  doAssert desc.secTailLen.uint32 == securityTailLen

  var buffer: array[160, uint8]
  for b in buffer.mitems: b = 0xC7
  txu_cntrl_frame_build(addr desc, addr buffer[128])
  doAssert sta_info_tab == expected
  for i in 0 ..< 128 - headerLength: doAssert buffer[i] == 0xC7
  for i in 128 ..< buffer.len: doAssert buffer[i] == 0xC7
  let header = cast[ptr MacQosDataFrameHeaderView](addr buffer[128 - headerLength])
  let sequenceOnWire = if tid == 0xFF: 0'u16 else: sequence shl 4
  doAssert header.header.seqCtrl == sequenceOnWire
  let baseFc = if tid == 0xFF: 0x0008'u16 else: 0x0088'u16
  let direction = if vifs[vifIndex].vifType == 0: 0x0100'u16
    elif vifs[vifIndex].vifType == 2: 0x0200'u16 else: 0'u16
  doAssert header.header.frameControl ==
    (baseFc or direction or (if protectedFrame: 0x4000'u16 else: 0'u16))
  if tid != 0xFF: doAssert header.qosCtrl == tid.uint16
  doAssert header.header.addr2 == vifs[vifIndex].macAddr
  case vifs[vifIndex].vifType
  of 0:
    doAssert header.header.addr1 == staInfoForIdx(station.uint8).macAddr
    doAssert header.header.addr3 == desc.da
  of 2:
    doAssert header.header.addr1 == desc.da
    doAssert header.header.addr3 == desc.sa
  else:
    doAssert header.header.addr1 == desc.da
    doAssert header.header.addr3 == vifs[vifIndex].bssid
  for i in 0 ..< securityHeaderLen.int:
    doAssert buffer[128 - snapLength - securityHeaderLen.int + i] == 0xD3
  if snapLength != 0:
    let ouiEnd = if etherType in [0x80F3'u16, 0x8137]: 0xF8'u8 else: 0'u8
    doAssert buffer[120 .. 125] == [0xAA'u8, 0xAA, 3, 0, 0, ouiEnd]
    doAssert buffer[126] == (etherType shr 8).uint8
    doAssert buffer[127] == (etherType and 0xFF).uint8

reset()
# Exercise the wrap boundary of every counter independently.
for station in 0 ..< STA_INFO_TAB_ENTRIES:
  for tid in 0'u8 .. 7'u8:
    staTxSequence(staInfoForIdx(station.uint8)).seqCounters[tid] = 4095
    for etherType in [0x0800'u16, 0x0806, 0x888E, 1500]:
      checkTx(station, tid, (station and 1).uint8, etherType)
  checkTx(station, 0xFF, (station and 1).uint8, 0x0800)

for value in 0 ..< 4097:
  checkTx(2, 5, 0, 0x0800)

var random = 0x39AB48'u32
for event in 0 ..< 5000:
  random = random xor (random shl 13)
  random = random xor (random shr 17)
  random = random xor (random shl 5)
  let station = (random mod STA_INFO_TAB_ENTRIES.uint32).int
  let tid = ((random shr 8) mod 8).uint8
  pushResult = (random and 1).uint8
  checkTx(station, tid, (random and 1).uint8, 0x0806)

# Security/SNAP bytes must not overwrite the emitted sequence or QoS fields.
var keyMarker: uint32
var keys = KeyList(pairwiseKey: addr keyMarker)
for secLength in [4'u32, 8'u32]:
  reset()
  securityHeaderLen = secLength
  securityTailLen = 12
  staInfoForIdx(0).keyMat = addr keys
  for vifIndex in 0'u8 .. 1'u8:
    vifs[vifIndex].keys.flags = 2
    checkTx(0, 7, vifIndex, 0x0800, protectedFrame = true)
    checkTx(0, 7, vifIndex, 0x888E, protectedFrame = false)

# Admission failures must not consume any sequence number or enqueue a frame.
for reason in 0 ..< 6:
  reset()
  var desc = HostTxDescView(staInfoIdx: 1, staIdx: 6, vifIdx: 0,
                             frameLen: 0x0008, seqAssigned: 0x7777)
  var status = 0xC0020000'u32
  case reason
  of 0: desc.staInfoIdx = 0xFF
  of 1: staInfoForIdx(1).valid = 0
  of 2: staInfoForIdx(1).controlPortState = 0
  of 3: staInfoForIdx(1).controlPortState = 1
  of 4:
    vifs[0].keyPsState = 1
    status = 0xC0080000'u32
  else:
    ready = false
    status = 0xC0100000'u32
  let before = sta_info_tab
  calls.setLen(0)
  pushedDesc = nil
  doAssert not txu_cntrl_push(addr desc, 2)
  doAssert calls == @["irq-save", "drop-count", "confirm", "irq-restore"]
  doAssert droppedStatus == status
  doAssert pushedDesc == nil and desc.seqAssigned == 0x7777
  doAssert sta_info_tab == before

# Cancelled host wrappers and retiring sessions never index or modify a VIF.
for vif in 0 .. 255:
  for retiring in [false, true]:
    if vif < MAX_VIFS and not retiring: continue
    reset()
    retiringVif = if retiring: vif else: -1
    let beforeVifs = vifs
    let beforeStations = sta_info_tab
    var desc = HostTxDescView(vifIdx: vif.uint8, staInfoIdx: 255)
    calls.setLen(0)
    doAssert not txu_cntrl_push(addr desc, 2)
    doAssert calls == @["irq-save", "drop-count", "confirm", "irq-restore"]
    doAssert droppedStatus == (0xC0000000'u32 or TxuDropStatusOrdinary)
    doAssert vifs == beforeVifs and sta_info_tab == beforeStations
retiringVif = -1
"""


def program_source() -> str:
    base = ROOT / "src/bl808/wifi/fw"
    tx = (base / "tx_upper.nim").read_text()
    layout = (base / "layout_types.nim").read_text()
    types = "  MacDataFrameHeaderView" + layout.split(
        "  MacDataFrameHeaderView", 1
    )[1].split("\n  TxPolicyView", 1)[0]
    types += "\n  StaTxSequenceOverlay" + layout.split(
        "  StaTxSequenceOverlay", 1
    )[1].split("\n  StaRxSequenceOverlay", 1)[0]
    types += "\n  TxSessionIdentity" + layout.split(
        "  TxSessionIdentity", 1
    )[1].split("\n  TxFrameCallbackScope", 1)[0]
    helpers = "template staInfoAt(p: pointer)" + layout.split(
        "template staInfoAt(p: pointer)", 1
    )[1].split("\ntemplate staConnectionStartWord", 1)[0]
    helpers += "\ntemplate staTxSequence" + layout.split(
        "template staTxSequence", 1
    )[1].split("\ntemplate staRxSequence", 1)[0]
    helpers += "\nproc lmacGateHalfword" + layout.split(
        "proc lmacGateHalfword", 1
    )[1].split("\ntemplate apmStartInfoView", 1)[0]
    lower = (base / "tx_layer.nim").read_text()
    helpers += procedure(lower, "txlCaptureSession") + procedure(lower, "txlSessionCurrent")
    frame_build = procedure(tx, "txuBuildFrame") + procedure(tx, "txu_cntrl_frame_build")
    push = procedure(tx, "txuCancelFrame") + procedure(tx, "txu_cntrl_push")
    debug_types = {"nimFwDbgDhcpTxLayout": "array[8, uint32]",
                   "nimFwDbgDhcpMacRaw": "array[96, uint8]"}
    debug_vars = "\nvar\n" + "".join(
        f"  {name}: {debug_types.get(name, 'uint32')}\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", frame_build + push)))
    )
    constants = tx.split("const\n", 1)[1].split("\nproc txu_cntrl_init", 1)[0]
    return (PLATFORM + "\nconst\n" + constants + "\ntype\n" + types
            + debug_vars + helpers + "\n" + frame_build + "\n" + push)


@pytest.mark.parametrize("trace", [False, True])
def test_tx_sequence_assignment_and_headers(tmp_path: Path, trace: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = tmp_path / "tx_sequence_test.nim"
    source.write_text(program_source() + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
               f"-o:{tmp_path / 'tx_sequence_test'}"]
    if trace:
        command.append("-d:bl808WifiConnectTrace")
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
