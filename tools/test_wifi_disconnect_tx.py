"""Exercise actual deauth construction, queue outcome, and callback contracts."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
proc txlFrameCallbackCurrent(): bool = true
proc smTxCallbackCurrent(): bool = true
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  TASK_SM = 4'u8
  SmDisconnectingState = 10'u8
type
  Header {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  Hw = object
    payloadStart, payloadEnd, frameLen: uint32
  Link = object
    before: array[16, uint8]
    macHeader: array[512, uint8]
    after: array[16, uint8]
  HostTxDescView = object
    bufDesc, hwDesc, callback, callbackArg: pointer
    vifIdx, staInfoIdx, hdrLen, secTailLen: uint8
    frameLen, seqPassthrough: uint16
  SmTxBuildContext = object
    identity: tuple[captured: bool, vif: uint8]
    frame: pointer
    ownsFrame: bool
  Vif = object
    vifType, state, staIdx, vifIdx, probeCount: uint8
    macAddr: array[6, uint8]
    bssid: array[6, uint8]
  Sta = object
    macAddr: array[6, uint8]
    instNbr, controlPortState: uint8
  ConnectInfo = object
    vifIdx: uint8
    bssid: array[6, uint8]
  SmEnv = object
    connectInfo: pointer
    saQueryActive, saQueryRetryCount, saQueryStaIdx, saQueryStaIdxTransIdPadding: uint8
    saQueryTransId, saQueryReason: uint16
  Event = tuple[kind: string, vif: pointer, status, reason: uint16]
  ManagementReasonBodyView {.packed.} = object
    reason: uint16
var
  vifs: array[2, Vif]
  stations: array[7, Sta]
  link: Link
  hw: Hw
  desc: HostTxDescView
  env: SmEnv
  connectInfo: ConnectInfo
  allocFail, pushFail, protectionFail, micFail, noLink, noHw: bool
  mode: uint32
  getCalls, pushCalls, releases, protectCalls, micCalls: int
  events: seq[Event]

proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxLinkDescAt(p: pointer): ptr Link = cast[ptr Link](p)
proc hostTxDataHeader(d: ptr HostTxDescView): ptr Header =
  cast[ptr Header](addr hostTxLinkDescAt(d.bufDesc).macHeader[0])
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc smEnvView(): ptr SmEnv = addr env
proc connectInfoView(p: pointer): ptr ConnectInfo = cast[ptr ConnectInfo](p)
proc smDisconnectReasonOrDefault(p: pointer): uint16 = 3
proc managementReasonBodyAt(p: pointer): ptr ManagementReasonBodyView =
  cast[ptr ManagementReasonBodyView](p)
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc ke_state_set(task, state: uint8) =
  doAssert task == TASK_SM and state == SmDisconnectingState
  events.add(("state", nil, 0'u16, 0'u16))
proc txl_get_seq_ctrl(): uint16 = 0x4560
proc tpc_update_frame_tx_power(vif, frame: pointer) =
  doAssert frame == addr desc
  events.add(("power", vif, 0'u16, 0'u16))
proc txl_frame_get(size: uint32): pointer =
  doAssert size == 512
  inc getCalls
  if allocFail: return nil
  desc.bufDesc = if noLink: nil else: addr link
  desc.hwDesc = if noHw: nil else: addr hw
  addr desc
proc txl_frame_release(p: pointer; callback: bool) =
  doAssert p == (addr desc) and not callback
  inc releases
proc txl_frame_push(p: pointer; ac: uint8): uint8 {.discardable.} =
  doAssert p == (addr desc) and ac == 3
  inc pushCalls
  if pushFail:
    inc releases # Failed push consumes/releases the descriptor itself.
    return 0
  1
proc smTxBeginForVif(vif: uint8): SmTxBuildContext =
  result.identity.captured = vif < 2 and vifs[vif].vifType == 0
  result.identity.vif = vif
proc smTxBegin(connection: pointer): SmTxBuildContext =
  if connection != nil: result = smTxBeginForVif(connectInfoView(connection).vifIdx)
proc smTxBindStation(build: var SmTxBuildContext; station: uint8): bool = true
proc smTxSetOwnerState(build: var SmTxBuildContext; state: uint8): bool =
  ke_state_set(TASK_SM, state)
  true
proc smTxOwnerCurrent(build: SmTxBuildContext): bool = true
proc smTxAdopt(build: var SmTxBuildContext; frame: pointer): bool =
  build.frame = frame
  build.ownsFrame = true
  let desc = hostTxDescAt(frame)
  desc.bufDesc != nil and desc.hwDesc != nil
proc smTxFrameCurrent(build: var SmTxBuildContext): bool = true
proc smTxEnd(build: var SmTxBuildContext) =
  if build.ownsFrame:
    build.ownsFrame = false
    txl_frame_release(build.frame, false)
proc smTxSubmit(build: var SmTxBuildContext; forced: bool): bool =
  build.ownsFrame = false
  txl_frame_push(build.frame, 3) != 0
proc sm_disconnect_process(vif: pointer; status, reason: uint16) {.cdecl.} =
  events.add(("disconnect", vif, status, reason))
proc sm_connect_ind(status, reason: uint16) =
  events.add(("abort", nil, status, reason))
proc failed(vif: pointer; status, reason: uint16) {.cdecl.} =
  events.add(("failure", vif, status, reason))
proc mfp_protect_mgmt_frame(frame: pointer; fc: uint32; category: uint32 = 0): uint32 =
  doAssert frame == (addr desc) and fc == 0xC0 and category == 0
  let header = hostTxDataHeader(addr desc)
  doAssert header.frameControl == 0xC0 and header.duration == 0
  doAssert header.addr1 == stations[desc.staInfoIdx].macAddr
  doAssert header.addr2 == vifs[desc.vifIdx].macAddr
  doAssert header.addr3 == header.addr1
  doAssert desc.hdrLen == 0 and desc.secTailLen == 0
  mode
proc txu_cntrl_protect_mgmt_frame(frame, bytes: pointer; length: uint32) =
  doAssert frame == (addr desc) and bytes == hostTxDataHeader(addr desc) and length == 24
  inc protectCalls
  if protectionFail: return
  hostTxDataHeader(addr desc).frameControl = hostTxDataHeader(addr desc).frameControl or 0x4000
  for i in 0 ..< 8: link.macHeader[24 + i] = (0xE0 + i).uint8
  desc.hdrLen = 8
  desc.secTailLen = 8
proc mfp_add_mgmt_mic(frame, bytes: pointer; length: uint32): uint32 =
  doAssert frame == (addr desc) and bytes == hostTxDataHeader(addr desc) and length == 26
  doAssert link.macHeader[24] == 3 and link.macHeader[25] == 0
  inc micCalls
  if micFail: return 0
  for i in 0 ..< 18: link.macHeader[26 + i] = (0x80 + i).uint8
  18

proc reset(vifIndex, staIndex: uint8) =
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  for i in 0 ..< 2:
    vifs[i] = Vif(vifIdx: i.uint8, state: 1, staIdx: staIndex,
      macAddr: [0x02'u8, 1, 2, 3, 4, i.uint8])
  for i in 0 ..< 7:
    stations[i].macAddr = [0x04'u8, 5, 6, 7, 8, i.uint8]
  desc = HostTxDescView(hdrLen: 0xEE, secTailLen: 0xDD)
  hw = Hw(payloadStart: 0x1000, payloadEnd: 0x11FF, frameLen: 516)
  for b in link.before.mitems: b = 0xA5
  for b in link.after.mitems: b = 0x5A
  for b in link.macHeader.mitems: b = 0xCC
  # Deliberately disagree with the requested VIF/peer: disconnect must not
  # fetch its destination or VIF from the old connection-info pointer.
  connectInfo = ConnectInfo(vifIdx: 1 - vifIndex,
    bssid: [0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15])
  env.connectInfo = addr connectInfo
  allocFail = false
  pushFail = false
  protectionFail = false
  micFail = false
  noLink = false
  noHw = false
  getCalls = 0
  pushCalls = 0
  releases = 0
  protectCalls = 0
  micCalls = 0
  events.setLen(0)
"""

CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for station in 0'u8 .. 6'u8:
    for requestedMode in 0'u32 .. 2'u32:
      for direct in [false, true]:
        reset(vif, station)
        mode = requestedMode
        if direct:
          sm_disconnect(vif)
        else:
          sm_handle_connection(vif, 0x1234'u16,
            cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](failed))
        doAssert getCalls == 1 and pushCalls == 1 and releases == 0
        doAssert events.len == 2 and events[0].kind == "state" and events[1].kind == "power",
          "cleanup happened before TX confirmation"
        doAssert desc.vifIdx == vif and desc.staInfoIdx == station
        doAssert desc.callbackArg == addr vifs[vif]
        let header = hostTxDataHeader(addr desc)
        doAssert header.seqCtrl == 0x4560
        let bodyOffset = if requestedMode == 1: 32 else: 24
        let frameLen = case requestedMode
          of 1: 42'u32
          of 2: 44'u32
          else: 26'u32
        doAssert header.frameControl == (if requestedMode == 1: 0x40C0'u16 else: 0x00C0'u16)
        doAssert link.macHeader[bodyOffset] == 3 and link.macHeader[bodyOffset + 1] == 0
        doAssert protectCalls == (if requestedMode == 1: 1 else: 0)
        doAssert micCalls == (if requestedMode == 2: 1 else: 0)
        doAssert hw.payloadStart == 0x1000 and hw.payloadEnd == 0x1000 + frameLen - 1
        doAssert hw.frameLen == frameLen + 4
        for i in 0 ..< 16:
          doAssert link.before[i] == 0xA5 and link.after[i] == 0x5A
        let callback = cast[proc(p: pointer; status: uint32) {.cdecl.}](desc.callback)
        callback(desc.callbackArg, 0x80000001'u32)
        doAssert events.len == 3
        doAssert events[2] == ("disconnect", cast[pointer](addr vifs[vif]), 19'u16, 3'u16)

for failure in 0 .. 5:
  for direct in [false, true]:
    reset(1, 4)
    mode = if failure == 2: 1 else: 2
    case failure
    of 0: allocFail = true
    of 1: pushFail = true
    of 2: protectionFail = true
    of 3: micFail = true
    of 4: noLink = true
    of 5: noHw = true
    else: discard
    if direct: sm_disconnect(1)
    else: sm_handle_connection(1, 0xABCD, cast[pointer](sm_disconnect_deauth_cfm), cast[pointer](failed))
    doAssert pushCalls == (if failure == 1: 1 else: 0)
    doAssert releases == (if failure == 0: 0 else: 1)
    doAssert events[^1] == ((if direct: "disconnect" else: "failure"),
      cast[pointer](addr vifs[1]), (if direct: 20'u16 else: 0xABCD'u16), 3'u16)
    var notifications = 0
    for event in events:
      if event.kind in ["failure", "disconnect"]: inc notifications
    doAssert notifications == 1

for invalid in [2'u8, 255'u8]:
  reset(0, 0)
  sm_disconnect(invalid)
  doAssert getCalls == 0 and events.len == 0
for kind in 0 .. 2:
  reset(0, 0)
  case kind
  of 0: vifs[0].state = 0
  of 1: vifs[0].vifType = 2
  else: vifs[0].staIdx = 255
  sm_disconnect(0)
  doAssert getCalls == 0 and pushCalls == 0

# The shared abort path can still queue deauth while connection is incomplete.
reset(1, 3)
vifs[1].state = 0
mode = 0
sm_handle_connection(1, 24, cast[pointer](sm_connect_abort_deauth_cfm), cast[pointer](failed))
doAssert getCalls == 1 and pushCalls == 1 and releases == 0
let abortCallback = cast[proc(p: pointer; status: uint32) {.cdecl.}](desc.callback)
abortCallback(desc.callbackArg, 0xFFFFFFFF'u32)
doAssert events[^1] == ("abort", nil, 23'u16, 3'u16)
"""


def procedure(source: str, name: str) -> str:
    start = re.search(rf"^proc {name}\*?\(", source, re.M)
    assert start
    end = re.search(r"^(?:proc|template|func|\{\.emit:) ", source[start.end():], re.M)
    return source[start.start():start.end() + end.start() if end else len(source)]


def test_disconnect_frame_and_completion(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    sm = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    source = PLATFORM + procedure(sm, "me_build_deauthenticate")
    source += procedure(sm, "sm_disconnect_deauth_cfm")
    source += procedure(sm, "sm_connect_abort_deauth_cfm")
    source += procedure(sm, "sm_handle_connection")
    source += procedure(tasks, "sm_disconnect") + CHECKS
    path = tmp_path / "disconnect.nim"
    path.write_text(source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
