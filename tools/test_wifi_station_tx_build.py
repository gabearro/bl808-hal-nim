"""Run complete station auth/association builders across callback boundaries."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, ROOT, procedure

PLATFORM = r'''
import bl808/wifi/fw_constants/states
import bl808/wifi/fw_constants/status_codes
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  TxlFramePayloadSize = 512'u32
  TASK_SM = 4'u8
  SM_RSP_TIMEOUT_IND = 0x1006'u16
  MACHW_BASE = 0'u
  MACHW_RX_CNTRL_REG = 0x60'u
  SCAN_ACTIVE_RX_FILTER_BITS = 0x10'u32
  IE_ID_RSN = 48'u8
type
  Header {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  MacDataFrameHeaderView = Header
  Hw = object
    payloadStart, payloadEnd, frameLen, ackPolicyControl, retryLimitControl: uint32
  Link = object
    macHeader: array[512, uint8]
    ackPolicyControl, retryLimitControl: uint32
  HostTxDescView = object
    bufDesc, hwDesc, callback, callbackArg: pointer
    vifIdx, staIdx, staInfoIdx, hdrLen, secTailLen: uint8
    frameLen, seqPassthrough: uint16
  TxSessionIdentity = object
    vifEpoch, stationEpoch, resetEpoch: uint32
    vif, station: uint8
    captured: bool
  Conn = object
    vifIdx, authType, qosInfo: uint8
    listenInterval: uint16
  SmEnv = object
    connectInfo, connectIndMsg: pointer
    connectFlags: uint8
    primaryFreq, centerFreq: uint16
  Vif = object
    vifIdx, vifType, state, staIdx: uint8
    macAddr, bssid, currentBssid: array[6, uint8]
    basicRates: array[13, uint8]
    channelFreqPair: uint32
    rsnIePtr: pointer
    rsnIeLen: uint16
  Sta = object
    macAddr: array[6, uint8]
    valid, instNbr: uint8
  Indication = object
    assocReqIeLen: uint16
  Mm = object
    rxFilterExtra, rxFilterBase: uint32
  MacAddress = object
    bytes: array[6, uint8]
  KeTimerGuard = proc(context: pointer): bool {.nimcall.}
  TxFrameIdentity = object
    resetEpoch: uint32
    smTracked: bool
    smConnection: pointer
    smSerial: uint32
    smState: uint16
  TxFrameCallbackScope = object
    identity: TxFrameIdentity
    vif, station: uint8
var
  sm: SmEnv
  conn, replacementConn: Conn
  vifs: array[2, Vif]
  stas: array[7, Sta]
  indication: Indication
  mm: Mm
  descriptors: array[2, HostTxDescView]
  hardware: array[2, Hw]
  links: array[2, Link]
  leased: array[2, bool]
  generations: array[2, uint32]
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[7, uint32]
  txResetEpoch: uint32
  activeFrame: ptr HostTxDescView
  replacementDesc: HostTxDescView
  replacementHw: Hw
  replacementLink: Link
  currentState: uint16
  timerDelay: uint32
  smConnecting: bool
  allocationFailure, pushFailure, timerFailure: bool
  hook, action: int
  hookFired: bool
  pushes, releases, failures: int
  failureStatus: uint16
  encodedLength: uint32
  invalidCursor: bool
  onHandoff: proc()
  txActiveFrameCallback: ptr TxFrameCallbackScope
  interruptsEnabled = true
proc observe(point: int)
proc smEnvView(): ptr SmEnv = addr sm
proc connectInfoView(p: pointer): ptr Conn = cast[ptr Conn](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc mmEnvView(): ptr Mm = addr mm
proc vifSecurity(p: ptr Vif): ptr Vif = p
proc vifHtCapabilities(p: ptr Vif): ptr Vif = p
proc smConnectIndPayloadAt(p: pointer): ptr Indication = cast[ptr Indication](p)
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxLinkDescAt(p: pointer): ptr Link = cast[ptr Link](p)
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc hostTxDataHeader(p: ptr HostTxDescView): ptr Header =
  cast[ptr Header](addr hostTxLinkDescAt(p.bufDesc).macHeader[0])
proc macAddrAt(p: pointer): ptr MacAddress = cast[ptr MacAddress](p)
proc lowLe(p: ptr MacAddress): uint32 = 0
proc highLe(p: ptr MacAddress): uint16 = 0
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc regWrite(p: uint; value: uint32) = discard
proc regRead(p: uint): uint32 = 0
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc c_memset(dst: pointer; value: cint; n: csize_t): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0..<n.int: bytes[i] = value.uint8
  dst
proc macPtrIsSpecific(p: pointer): bool = p != nil
proc macPtrEquals(a, b: pointer): bool =
  a != nil and b != nil and cast[ptr array[6, uint8]](a)[] == cast[ptr array[6, uint8]](b)[]
proc ensureVifMgmtMac(p: ptr Vif): pointer = addr p.macAddr[0]
proc vifMgmtTxSa(p: ptr Vif): pointer = addr p.macAddr[0]
proc frameIndex(p: pointer): int =
  for i in 0..1:
    if p == addr descriptors[i]: return i
  doAssert false
proc txlFrameLeaseToken(p: ptr HostTxDescView): uint32 = generations[frameIndex(p)]
proc txlFrameBindSmOwner(p: ptr HostTxDescView; connection: pointer;
                         serial: uint32; state: uint16): bool = true
proc txlFrameLeaseMatches(p: ptr HostTxDescView; generation: uint32): bool =
  let i = frameIndex(p)
  leased[i] and generations[i] == generation
proc staDeleteEpoch(i: uint8): uint32 =
  if i < 7: stationEpochs[i] else: 0
proc txl_frame_release(p: pointer; callback: bool) =
  let i = frameIndex(p)
  doAssert leased[i] and not callback, "frame released twice"
  leased[i] = false
  inc releases
proc txlSessionCurrent(identity: TxSessionIdentity; p: ptr HostTxDescView): bool =
  identity.resetEpoch == txResetEpoch and
    p.vifIdx == identity.vif and p.staInfoIdx == identity.station and
    rxVifEpochs[identity.vif] == identity.vifEpoch and
    staDeleteEpoch(identity.station) == identity.stationEpoch
proc txlStationAdmits(p: ptr HostTxDescView): bool =
  p.staInfoIdx == 0xFF or
    (stas[p.staInfoIdx].valid != 0 and stas[p.staInfoIdx].instNbr == p.vifIdx)
proc txlFramePreparationCurrent(p: ptr HostTxDescView; identity: TxSessionIdentity; generation: uint32): bool =
  if not txlFrameLeaseMatches(p, generation): return false
  if not txlSessionCurrent(identity, p) or not txlStationAdmits(p) or
      p.bufDesc == nil or p.hwDesc == nil:
    txl_frame_release(p, false)
    return false
  true
proc ke_state_get(task: uint8): uint16 = currentState
proc ke_state_set(task: uint8; state: uint16) =
  currentState = state
  observe(7)
proc ke_timer_set(id: uint16; task: uint8; delay: uint32) =
  timerDelay = delay
  observe(8)
proc ke_timer_try_set(id: uint16; task: uint8; delay: uint32;
                     guard: KeTimerGuard = nil; context: pointer = nil): bool =
  observe(8)
  if timerFailure or (guard != nil and not guard(context)): return false
  timerDelay = delay
  true
proc ke_timer_clear(id: uint16; task: uint8) = timerDelay = 0
proc sm_connect_ind(status, reason: uint16) =
  inc failures
  failureStatus = status
  currentState = 10
  timerDelay = 0
  sm.connectInfo = nil
proc txl_frame_get(size: uint32): pointer =
  doAssert size == 512
  if allocationFailure: return nil
  for i in 0..1:
    if not leased[i]:
      leased[i] = true
      inc generations[i]
      descriptors[i] = HostTxDescView(bufDesc: addr links[i], hwDesc: addr hardware[i])
      hardware[i].payloadStart = 0x1000
      activeFrame = addr descriptors[i]
      result = activeFrame
      observe(1)
      return
  nil
proc tpc_update_frame_tx_power(vif, frame: pointer) = observe(2)
proc txl_get_seq_ctrl(): uint16 = 0x1230
proc txu_cntrl_protect_mgmt_frame(p, hdr: pointer; n: uint32) =
  hostTxDescAt(p).hdrLen = 4
  hostTxDescAt(p).secTailLen = 4
  hostTxDataHeader(hostTxDescAt(p)).frameControl = 0x40B0
  observe(3)
proc me_build_authenticate(buf: pointer; algo, sequence, status: uint16; challenge: pointer): uint32 =
  cast[ptr AuthFixedBodyView](buf)[] = AuthFixedBodyView(authAlgo: algo, authSeq: sequence, statusCode: status)
  observe(3)
  6
proc me_build_sae_authenticate(buf: pointer; algo, sequence, status: uint16; vif: uint32): uint32 =
  me_build_authenticate(buf, algo, sequence, status, nil)
proc me_build_associate_req_impl(buf, assocInfo, reassoc, cap, cursorOut, lengthOut, info: pointer): uint32 =
  let bytes = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0..<10: bytes[i] = 0
  bytes[4] = 48
  bytes[5] = 4
  cast[ptr pointer](cursorOut)[] = cast[pointer](cast[uint](buf) +
    (if invalidCursor: 1'u else: encodedLength.uint))
  cast[ptr uint16](lengthOut)[] = 6
  observe(3)
  encodedLength
proc nimFwTrace2U32(s: string; a, b: uint32) = observe(4)
proc nimFwConnectTrace2U32(s: string; a, b: uint32) = observe(4)
proc nimFwConnectTraceBytes(s: string; p: pointer; n, limit: uint32) = observe(4)
proc nimFwConnectTraceHw(s: string) = observe(4)
proc wifi_nimfw_prepare_sta_tx_channel() = observe(5)
proc mm_rx_filter_set() = observe(5)
proc rfPriApplyWb03AuthTxLatches() = observe(5)
proc applyConservativeMgmtTxRetryPolicy(p: ptr Link) = observe(5)
proc rfPriCaptureWb03AuthTxPrePush() = observe(5)
proc applyForcedInternalMgmtTxPower(p: ptr Hw) = observe(5)
proc captureAuthTxHwPrePush(p: ptr HostTxDescView; hw: ptr Hw) = observe(5)
proc txl_frame_push(p: pointer; ac: uint8): uint8 {.discardable.} =
  doAssert ac == 3
  inc pushes
  observe(6)
  if onHandoff != nil: onHandoff()
  if pushFailure:
    txl_frame_release(p, false)
    return 0
  1
proc txl_frame_push_force(p: pointer; ac: uint8) = discard txl_frame_push(p, ac)
proc txl_frame_try_push_force(p: pointer; ac: uint8): uint8 = txl_frame_push(p, ac)
'''

CHECKS = r'''
proc observe(point: int) =
  if hookFired or hook != point: return
  hookFired = true
  case action
  of 1:
    sm.connectInfo = addr replacementConn
    inc rxVifEpochs[1]
    currentState = 9
    timerDelay = 12345
    smConnecting = false
  of 2:
    doAssert activeFrame != nil
    let i = frameIndex(activeFrame)
    txl_frame_release(activeFrame, false)
    leased[i] = true
    inc generations[i]
    descriptors[i] = HostTxDescView(bufDesc: addr links[i], hwDesc: addr hardware[i],
      callback: cast[pointer](0x1234), callbackArg: cast[pointer](0x5678),
      frameLen: 321, vifIdx: 0, staIdx: 0, staInfoIdx: 0)
    for b in links[i].macHeader.mitems: b = 0xA5
    hardware[i] = Hw(payloadStart: 0xDEAD, payloadEnd: 0xBEEF, frameLen: 123)
    replacementDesc = descriptors[i]
    replacementHw = hardware[i]
    replacementLink = links[i]
  of 3: inc stationEpochs[2]
  of 4: activeFrame.bufDesc = nil
  of 5: stas[2].valid = 0
  of 6: vifs[1].staIdx = 3
  else: discard
proc setup(kind: int) =
  sm = SmEnv(connectInfo: addr conn, connectIndMsg: addr indication)
  conn = Conn(vifIdx: 1, authType: 0)
  replacementConn = conn
  currentState = if kind == 0: 5 else: 7
  timerDelay = 0
  smConnecting = false
  rxVifEpochs = [1'u32, 1]
  stationEpochs = default(typeof(stationEpochs))
  for i in 0..1:
    vifs[i] = Vif(vifIdx: i.uint8, staIdx: 2, state: 0,
      macAddr: [2'u8, 3, 4, 5, 6, 7], bssid: [4'u8, 5, 6, 7, 8, 9])
  stas[2] = Sta(valid: 1, instNbr: 1, macAddr: vifs[1].bssid)
  descriptors = default(typeof(descriptors))
  hardware = default(typeof(hardware))
  links = default(typeof(links))
  leased = [false, false]
  activeFrame = nil
  allocationFailure = false
  pushFailure = false
  timerFailure = false
  hook = 0
  action = 0
  hookFired = false
  pushes = 0
  releases = 0
  failures = 0
  encodedLength = 10
  invalidCursor = false
  onHandoff = nil
proc perform(kind: int) =
  if kind == 0: sm_auth_send(1, nil)
  else: sm_assoc_req_send()
'''

CASES = {
    "handoff_replacement": r'''
for kind in 0..1:
  setup(kind)
  hook = 6
  action = 1
  perform(kind)
  doAssert hookFired
  doAssert currentState == 9 and timerDelay == 12345 and not smConnecting,
    "older TX handoff overwrote replacement connection state"
''',
    "failed_submission": r'''
for kind in 0..1:
  setup(kind)
  pushFailure = true
  perform(kind)
  doAssert pushes == 1 and failures == 1 and currentState == 10,
    "failed TX submission left the connection waiting"
  doAssert timerDelay == 0
''',
    "response_visible_at_handoff": r'''
for kind in 0..1:
  setup(kind)
  let expected = if kind == 0: 6'u16 else: 8'u16
  onHandoff = proc() =
    doAssert currentState == expected and timerDelay != 0,
      "TX handoff preceded response-state publication"
    sm.connectInfo = nil
    currentState = 0
    timerDelay = 0
    smConnecting = false
  perform(kind)
  doAssert currentState == 0 and timerDelay == 0 and not smConnecting
''',
    "preparation_replacement": r'''
for kind in 0..1:
  for stage in 1..5:
    setup(kind)
    hook = stage
    action = 1
    perform(kind)
    doAssert hookFired
    doAssert pushes == 0 and failures == 0 and currentState == 9 and timerDelay == 12345
''',
    "lease_reuse": r'''
for kind in 0..1:
  for stage in 2..5:
    setup(kind)
    hook = stage
    action = 2
    perform(kind)
    doAssert hookFired
    let i = frameIndex(activeFrame)
    doAssert descriptors[i] == replacementDesc and hardware[i] == replacementHw and links[i] == replacementLink,
      "older builder modified a replacement frame"
    doAssert pushes == 0 and leased[i]
''',
    "normal": r'''
for kind in 0..1:
  setup(kind)
  perform(kind)
  doAssert pushes == 1 and failures == 0
  doAssert currentState == (if kind == 0: 6'u16 else: 8'u16) and timerDelay == 0x7D000
''',
    "timer_and_state_replacement": r'''
for kind in 0..1:
  for stage in 7..8:
    setup(kind)
    hook = stage
    action = 1
    perform(kind)
    doAssert hookFired and pushes == 0 and failures == 0
    doAssert currentState == 9 and timerDelay == 12345 and not smConnecting
''',
    "station_replacement": r'''
for kind in 0..1:
  for stage in 1..5:
    setup(kind)
    hook = stage
    action = 3
    perform(kind)
    doAssert hookFired and pushes == 0 and failures == 0 and releases == 1
''',
    "timer_failure": r'''
for kind in 0..1:
  setup(kind)
  timerFailure = true
  perform(kind)
  doAssert pushes == 0 and failures == 1 and releases == 1 and timerDelay == 0
''',
    "timer_descriptor_change": r'''
for kind in 0..1:
  for change in [4, 5]:
    setup(kind)
    hook = 8
    action = change
    perform(kind)
    doAssert pushes == 0 and failures == 1 and releases == 1 and timerDelay == 0
''',
    "allocation_failure": r'''
for kind in 0..1:
  setup(kind)
  allocationFailure = true
  perform(kind)
  doAssert pushes == 0 and failures == 1 and releases == 0 and timerDelay == 0
''',
    "failed_handoff_replacement": r'''
for kind in 0..1:
  setup(kind)
  pushFailure = true
  hook = 6
  action = 1
  perform(kind)
  doAssert pushes == 1 and failures == 0 and releases == 1
  doAssert currentState == 9 and timerDelay == 12345 and not smConnecting
''',
    "association_ie_and_length": r'''
setup(1)
var securityIe = [48'u8, 4, 0, 0, 0, 0]
vifs[1].rsnIePtr = addr securityIe[0]
vifs[1].rsnIeLen = 6
perform(1)
doAssert pushes == 1 and descriptors[0].frameLen == 34,
  "association duplicated an existing security IE"
for length in [0'u32, 3, 489, high(uint32)]:
  setup(1)
  encodedLength = length
  perform(1)
  doAssert pushes == 0 and failures == 1 and releases == 1
setup(1)
invalidCursor = true
perform(1)
doAssert pushes == 0 and failures == 1 and releases == 1
''',
    "response_delays": r'''
for kind in 0..1:
  for algo in [0'u8, 3]:
    for flag in 0'u8..1:
      setup(kind)
      conn.authType = algo
      sm.connectFlags = flag
      perform(kind)
      let expected = if flag != 0 and (kind == 1 or algo != 3): 0x1E000'u32 else: 0x7D000'u32
      doAssert pushes == 1 and timerDelay == expected
''',
}


def program_source() -> str:
    sm = (FW / "scan_station_ap_me.nim").read_text()
    functions = procedure(sm, "sm_auth_send") + procedure(sm, "sm_assoc_req_send")
    code = layouts("AuthFixedBodyView", "AuthBodyTraceView", "AssocReqFixedBodyView", "MacIeView")
    code += PLATFORM
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    arrays = {"nimFwDbgVifMac": 6, "nimFwDbgAuthTxRaw": 256, "nimFwDbgAssocReqRaw": 256}
    code += "\nvar\n" + "".join(
        f"  {name}: array[{arrays[name]}, uint8]\n" if name in arrays else f"  {name}: uint32\n"
        for name in debug)
    helper = FW / "station_tx_build.nim"
    if helper.exists():
        layout = (FW / "layout_types.nim").read_text()
        code += "type\n  SmTxBuildContext" + layout.split("  SmTxBuildContext", 1)[1].split("\n\n  ", 1)[0] + "\n"
        code += helper.read_text()
        code += r'''
proc meBuildSaeAuthenticate(buf: pointer; algo, sequence, status: uint16; vif: uint32;
                            build: ptr SmTxBuildContext): uint32 =
  me_build_sae_authenticate(buf, algo, sequence, status, vif)
proc meBuildAssociateReq(buf, assocInfo, reassoc, cap, cursorOut, lengthOut, info: pointer;
                         build: ptr SmTxBuildContext): uint32 =
  me_build_associate_req_impl(buf, assocInfo, reassoc, cap, cursorOut, lengthOut, info)
'''
    return code + functions + CHECKS


def run_case(tmp_path: Path, case: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "station_tx.nim"
    path.write_text(program_source() + "\n" + CASES[case])
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"],
             "forced_trace": ["-d:bl808WifiForceAuthAssocPush", "-d:bl808WifiConnectTrace"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", f"--path:{ROOT / 'src'}", *flags,
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan", "forced_trace"])
def test_station_tx_build(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)
