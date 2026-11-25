"""Drive received WMM profiles through the real BL808 MM idle transaction."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_channel_update import mm_config_idle_source


PLATFORM = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
  API_AC_BK = 0'u8
  API_AC_BE = 1'u8
  TASK_MM = 0'u8
  MM_SET_EDCA_REQ = 22'u16
  MM_SET_EDCA_CFM = 23'u16
  MM_REMOVE_IF_REQ = 8'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_CHAN_CTXT_UPDATE_REQ = 41'u16
  MM_HOST_BYPASSED = 3'u8
  TaskIdleState = 0'u16
  TaskGoingIdleState = 2'u16
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  MmChanCtxtUpdatePayloadSize = 12'u32
  MmSetEdcaReqPayloadSize = sizeof(MmSetEdcaReqPayload).uint32
  MACHW_BASE = 0x24B00000'u
  MACHW_STATE_CNTRL_REG = MACHW_BASE + 0x38'u
  MACHW_EDCA_AC_BK_REG = MACHW_BASE + 0x200'u
  WMM_OUI = [0'u8, 0x50, 0xF2, 2, 1]
type
  VifChannelView = object
    next, chanCtxt: pointer
    vifIdx, vifType, state, staIdx: uint8
    wmmQosInfo, wmmAcFlags: uint8
    currentBssid: array[6, uint8]
    edcaRegs: array[4, uint32]
    config: array[96, uint8]
  StaInfoView = object
    infoIdx, instNbr, valid: uint8
    macAddr: array[6, uint8]
  Header = object
    id: uint16
    srcId, destId: uint8
    paramLen: uint32
  Context = object
    status, contextIndexOrMarker: uint8
    channel: tuple[primFreq: uint16]
  MmRemoveIfReqPayload = object
    vifIdx: uint8
var
  vifs: array[2, VifChannelView]
  contexts: array[4, Context]
  sta: StaInfoView
  channel: tuple[currentCtxt, scheduledCtxt: pointer]
  management: tuple[activeList: tuple[first: pointer]]
  mm: tuple[hardwareMode, previousState: uint8]
  rx: tuple[processingFlag: uint8]
  mmEdcaRefresh: tuple[message, context: pointer; vif: uint8;
                       vifEpoch, bindingEpoch: uint32]
  rxVifEpochs, chanCtxtLinkEpochs: array[2, uint32]
  txResetEpoch: uint32
  bank: array[4, uint32]
  header: Header
  payloadStorage: array[8, uint8]
  pending: pointer
  mmState: uint16
  hardwareMode: uint32
  writes: seq[tuple[address: uint, value: uint32]]
  refreshes, attempts, idleRequests, confirms: int
  failAllocation: bool
  interruptsEnabled: bool
  allocationHook: proc()
proc irqSave(): bool =
  result = interruptsEnabled
  interruptsEnabled = false
proc irqRestore(saved: bool) = interruptsEnabled = saved
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
template macIePayload(ie: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](ie) + 2)
proc wmmParameterIeAt(p: pointer): ptr WmmParameterIeView = cast[ptr WmmParameterIeView](p)
proc beaconFrameFixedView(p: pointer): ptr BeaconFrameFixedView = cast[ptr BeaconFrameFixedView](p)
proc beaconFrameIeBody(b: ptr BeaconFrameFixedView): pointer = addr b.body[0]
proc vifApConfig(v: ptr VifChannelView): ptr VifApConfigOverlay =
  cast[ptr VifApConfigOverlay](addr v.config[0])
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc vifChannelAt(p: uint): ptr VifChannelView = cast[ptr VifChannelView](p)
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc vifEntryAddr(i: uint8): uint = cast[uint](addr vifs[i])
proc vifMgmtEnvView(): ptr typeof(management) = addr management
proc chanEnvView(): ptr typeof(channel) = addr channel
proc mmEnvView(): ptr typeof(mm) = addr mm
proc rxlCntrlEnvView(): ptr typeof(rx) = addr rx
proc regRead(address: uint): uint32 =
  if address == MACHW_STATE_CNTRL_REG: return hardwareMode
  bank[(address - MACHW_EDCA_AC_BK_REG) div 4]
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  if address != MACHW_STATE_CNTRL_REG:
    doAssert not interruptsEnabled and hardwareMode == 0
    bank[(address - MACHW_EDCA_AC_BK_REG) div 4] = value
proc mm_env_max_ampdu_duration_set(duration: uint32) =
  doAssert not interruptsEnabled and duration == 0
  inc refreshes
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr payloadStorage[0]
  addr header
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; length: uint32): pointer =
  doAssert id == MM_SET_EDCA_REQ and dest == TASK_MM and src == TASK_MM and length == 0
  inc attempts
  if failAllocation: return nil
  header = Header(id: id, srcId: src, destId: dest, paramLen: length)
  if allocationHook != nil: allocationHook()
  addr payloadStorage[0]
proc ke_msg_send(p: pointer) =
  doAssert pending == nil
  pending = p
proc mmEdcaForget(header: pointer)
proc ke_msg_free(p: pointer) =
  doAssert p == addr header
  mmEdcaForget(p)
proc ke_state_get(task: uint8): uint16 = mmState
proc ke_state_set(task: uint8; state: uint16) = mmState = state
proc ke_evt_field_get(): uint32 = 0
const MM_IDLE = TaskIdleState
const MM_GOING_TO_IDLE = TaskGoingIdleState
const KE_EVT_IDLE = 0x04000000'u32
proc ke_evt_clear(bits: uint32) = doAssert bits == KE_EVT_IDLE
proc ke_msg_free_payload(p: pointer) = doAssert false
proc hal_machw_idle_req() = inc idleRequests
proc ke_msg_send_basic_reply(p: pointer; id: uint16) = inc confirms
proc smStaleRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc chanUpdateAdmit(p: pointer): bool = true
proc apmPrepareVifRemoval(vif: uint8): bool = true
proc ps_uapsd_set(vif: pointer; queue: uint8; enabled: uint32) = doAssert false
proc assert_err(a, b: cstring; line: int) = doAssert false
'''


CHECKS = r'''
const peer = [2'u8, 3, 4, 5, 6, 7]
const initial = [0xA47'u32, 0xA43, 0x5E432, 0x2F322]
const updated = [0xA49'u32, 0xA45, 0x5E434, 0x2F324]
const other = [0xA4B'u32, 0xA47, 0x5E436, 0x2F326]
var bytes: array[88, uint8]
let frame = beaconFrameFixedView(addr bytes[0])
let wmm = wmmParameterIeAt(addr bytes[36])
proc beacon(count, delta: uint8) =
  bytes = default(typeof(bytes))
  frame.frameControl = 0x80
  frame.addr1 = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
  frame.addr2 = peer
  frame.addr3 = peer
  wmm.ie = MacIeView(id: 221, len: 24)
  wmm.oui = [0'u8, 0x50, 0xF2]
  wmm.ouiType = 2
  wmm.ouiSubtype = 1
  wmm.version = 1
  wmm.qosInfo = count
  for i, word in [0x002F3262'u32, 0x0000A403'u32, 0x005E4352'u32, 0x0000A427'u32]:
    wmm.ac[i].setLe32(word + delta.uint32)
proc receive(freq = 2462'u16; length = 62'u16): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  result = updateStaWmmFromBeacon(addr vifs[0], addr sta, frame, length, freq)
  if result: mmRequestStaEdcaRefresh(addr vifs[0])
proc complete() =
  doAssert pending != nil
  doAssert mm_hw_config_handler(pending) == KeMsgSaved
  doAssert idleRequests == 1 and mmState == TaskGoingIdleState
  doAssert mm_hw_config_handler(pending) == KeMsgSaved
  hardwareMode = 0
  mm_hw_idle_evt()
  doAssert mm_hw_config_handler(pending) == KeMsgConsumed
  doAssert mmState == 1 and writes[^1] == (MACHW_STATE_CNTRL_REG, 0x30'u32)
  doAssert confirms == 0 and interruptsEnabled
  idleRequests = 0
  hardwareMode = 3
  ke_msg_free(keMsgHdrFromPayload(pending))
  pending = nil

interruptsEnabled = true
contexts[0] = Context(status: 5, channel: (primFreq: 2462'u16))
contexts[1] = Context(status: 4, contextIndexOrMarker: 1, channel: (primFreq: 2412'u16))
contexts[3] = Context(status: 4, contextIndexOrMarker: 3)
channel.currentCtxt = addr contexts[0]
vifs[0] = VifChannelView(vifType: VIF_TYPE_STA, state: 1, staIdx: 2,
  chanCtxt: addr contexts[0], currentBssid: peer, wmmQosInfo: 0x8F, edcaRegs: initial)
vifApConfig(addr vifs[0]).securityFlags = 1
sta = StaInfoView(infoIdx: 2, valid: 1, macAddr: peer)
management.activeList.first = addr vifs[0]
bank = initial
mmState = 1
hardwareMode = 3

# A matching count does not replace a profile, even if the payload differs.
beacon(15, 2)
doAssert receive() and vifs[0].edcaRegs == initial and attempts == 0
for invalid in 0 ..< 10:
  beacon(0, 2)
  var freq = 2462'u16
  var length = 62'u16
  case invalid
  of 0: frame.addr2[5] = 42
  of 1: frame.addr3[5] = 42
  of 2: frame.addr1 = peer
  of 3: frame.seqCtrl = 1
  of 4: frame.frameControl = 0x480
  of 5: freq = 2412
  of 6: wmm.version = 2
  of 7: wmm.ac[0] = wmm.ac[1]
  of 8: length = 61
  else:
    copyMem(addr bytes[62], addr bytes[36], 26)
    length = 88
  doAssert not receive(freq, length)
  doAssert vifs[0].wmmQosInfo == 0x8F and vifs[0].edcaRegs == initial and attempts == 0

beacon(0, 2)  # Fifteen to zero wraps, while the U-APSD bit is preserved.
failAllocation = true
doAssert receive() and pending == nil and attempts == 1
doAssert vifs[0].wmmQosInfo == 0x80 and vifs[0].wmmAcFlags == 4
doAssert vifs[0].edcaRegs == updated and bank == initial and writes.len == 0
failAllocation = false
doAssert receive() and pending != nil and attempts == 2
beacon(1, 4)  # A newer beacon coalesces into the same idle request.
doAssert receive() and attempts == 2 and bank == initial
complete()
doAssert bank == other and writes.len == 5 and refreshes == 1

beacon(2, 2)
doAssert receive() and pending != nil
inc chanCtxtLinkEpochs[0]
writes.setLen(0)
complete()
doAssert writes.len == 1 and bank == other and refreshes == 1

# A replacement during allocation cannot publish a stale request.
allocationHook = proc() = inc rxVifEpochs[0]
doAssert receive() and pending == nil and bank == other
allocationHook = nil

vifs[1] = VifChannelView(vifType: VIF_TYPE_AP, state: 1, vifIdx: 1,
  chanCtxt: addr contexts[1], edcaRegs: initial)
vifs[0].next = addr vifs[1]
channel.currentCtxt = addr contexts[1]
hardwareMode = 0
mmReplayEdca()
doAssert bank == initial and refreshes == 2
beacon(3, 4)
doAssert receive() and pending == nil and bank == initial and vifs[0].edcaRegs == other
channel.currentCtxt = addr contexts[3]
mmReplayEdca()
doAssert bank == initial and refreshes == 2
channel.currentCtxt = addr contexts[0]
channel.scheduledCtxt = addr contexts[1]
mmReplayEdca()
doAssert bank == initial and refreshes == 2
channel.scheduledCtxt = nil
vifs[1].chanCtxt = addr contexts[0]
mmReplayEdca() # A shared context cannot program a STA-only profile.
doAssert bank == initial and refreshes == 2
vifs[1].chanCtxt = addr contexts[1]
# The context's status does not matter: a lone context is left at status 1
# by its operation timer and still owns the bank (MMCH-S6).
contexts[0].status = 1
mmReplayEdca()
doAssert bank == other and refreshes == 3
channel.currentCtxt = addr contexts[1]
mmReplayEdca()
doAssert bank == initial and refreshes == 4
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wmm_beacon_profile_and_channel_ownership(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code = layouts("MacIeView", "WmmAcParamRecord", "WmmParameterIeView", "VifApConfigOverlay",
                   "BeaconFrameFixedView", "MmSetVifStateReqPayload", "MmSetEdcaReqPayload") + PLATFORM
    code += procedure(layout[layout.index("proc le32*(rec:"):], "le32") + procedure(layout, "setLe32")
    code += "template vifApEdcaWord" + layout.split("template vifApEdcaWord", 1)[1].split("\n\n", 1)[0] + "\n"
    code += scan[scan.index("type StaWmmParameters"):scan.index("proc isWmmParameterIe")]
    for name in ["isWmmParameterIe", "decodeStaWmmParameters", "updateStaWmmFromBeacon"]:
        code += procedure(scan, name)
    for name in ["mmEdcaForget", "mmEdcaOwner", "mmEdcaWord", "mmProgramEdca", "mmReplayEdca", "mmEdcaRefreshCurrent",
                 "mmRequestStaEdcaRefresh"]:
        code += procedure(kernel, name)
    handler = procedure(tasks, "mm_hw_config_handler")
    prefix = handler.split("  # Main dispatch on msgId", 1)[0]
    branch = handler.split("  of 22:", 1)[1].split("  of 24:", 1)[0]
    tail = handler.split("  # Restore local MM state", 1)[1]
    code += mm_config_idle_source()
    code += prefix + "  case msgId.int\n  of 22:" + branch + "  else: doAssert false\n  # Restore local MM state" + tail
    run_program(tmp_path, mode, code + CHECKS)
