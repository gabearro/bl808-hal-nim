"""Run beacon stop/reset ownership and VIF teardown ordering without hardware."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import FW, ROOT, procedure
from test_wifi_beacon_transmit import SETUP
from test_wifi_beacon_update import run


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_stop_quiesces_and_cancels_all_owned_updates(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
install()
mm_bcn_transmit(0)
let held = request(makeFrame(prefix = 8), prefix = 8)
mm_bcn_change(held)
queueTim(17, 1)
let queued = request(makeFrame(prefix = 9), prefix = 9)
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(queued))
let savedTim = message(47, TASK_MM, 5, 4)
cast[ptr MmTimUpdatePayload](savedTim)[] = MmTimUpdatePayload(aid: 25, setFlag: 1, vifIdx: 0)
co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(savedTim))
let activation = message(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_APM, 4)
cast[ptr MmSetVifStateReqPayload](activation)[] = MmSetVifStateReqPayload(state: 1, vifIdx: 0)
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(activation))
let unrelated = message(999, TASK_MM, 5, 0)
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(unrelated))
let otherVif = request(makeFrame(), 1)
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(otherVif))
let before = pool.bytes
clearHook = proc() =
  doAssert mmBcnStopping and not mmBeaconPoolIdle()
  doAssert vifs[0].beaconEnabled == 0 and env.templatePtr == nil
  doAssert env.timQueue.first == nil
  mm_bcn_transmit(0)
  mm_bcn_change(request(makeFrame()))
  queueTim(40, 1)
  let late = request(makeFrame(prefix = 4), prefix = 4)
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(late))
  doAssert mm_bcn_stop(addr vifs[0])
doAssert mm_bcn_stop(addr vifs[0])
doAssert beaconClears == 1 and pushes == 1
doAssert not mmBcnStopping and env.pendingCount == 0 and mmBeaconPoolIdle()
doAssert pool.bytes == before and vifs[0].timCount == 0
doAssert confirmations == @[1'u8, 1, 8, 1]
doAssert keMsgQueueSaved.first == nil
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(unrelated)
doAssert keMsgQueueSent.last == keMsgHdrFromPayload(otherVif)
doAssert allocated.len == 2
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
doAssert allocated.len == 0
clearHook = nil
queueTim(17, 1)
doAssert vifs[0].timCount == 0 and allocated.len == 0
''', mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_releases_private_messages_without_stale_confirmations(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
install()
mm_bcn_transmit(0)
mm_bcn_change(request(makeFrame(prefix = 2), prefix = 2))
queueTim(17, 1)
queueTim(25, 1)
doAssert allocated.len == 3
mm_bcn_init()
doAssert allocated.len == 0 and env.pendingCount == 0
doAssert env.templatePtr == nil and env.timQueue.first == nil
doAssert confirmations.len == 0 and sentDestinations.len == 0
doAssert mmBcnInitDone and not mmBcnStopping and mmBeaconPoolIdle()
doAssert beaconClears == 0, "reset init must not access a stopped/reinitialized MAC"
let freed = frees
mm_bcn_init()
doAssert frees == freed
''', mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_busy_template_is_not_overwritten_or_leaked(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
install()
mm_bcn_transmit(0)
let first = request(makeFrame(prefix = 3), prefix = 3)
mm_bcn_change(first)
doAssert env.templatePtr == first and allocated.len == 1
mm_bcn_change(request(makeFrame(prefix = 7), prefix = 7))
doAssert confirmations == @[8'u8]
doAssert env.templatePtr == first and allocated.len == 1
mm_bcn_change(nil)
mm_bcn_change(first)
doAssert confirmations == @[8'u8] and allocated.len == 1
mm_bcn_transmitted(addr vifs[0])
doAssert confirmations == @[8'u8, 0]
doAssert allocated.len == 0 and env.templatePtr == nil
doAssert descriptors[0].payloadEnd == pointerAddrU32(addr pool.bytes[348]) + 40
''', mode, transmit=True)


VIF_PLATFORM = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
  MACHW_BASE = 0x24B00000'u
  MACHW_RX_CNTRL_REG = MACHW_BASE + 0x60
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Timer = object
    callback: pointer
    env: uint32
  Vif = object
    next: pointer
    vifIdx, vifType, state, beaconEnabled, staIdx: uint8
    txPower, maxTxPower: int8
    chanCtxt: pointer
    macAddr, currentBssid: array[6, uint8]
    edcaRegs: array[4, uint32]
    tbttNode: tuple[vifIdx: uint8]
    tbttTimer, beaconTimeoutTimer, keepAliveTimer, securityTimer: Timer
    rssiStatePadding: array[4, uint8]
  Env = object
    activeList, freeList: CoList
    staCount, apCount: uint8
  VifMgmtEnvView = Env
const VIF_ENTRY_SIZE = sizeof(Vif)
var
  vifs: array[2, Vif]
  env: Env
  mm: tuple[rxFilterExtra, rxFilterBase: uint32]
  callbacks: tuple[init, deinit: pointer]
  wpa_cbs: pointer
  poolBusy: bool
  removalReady: bool
  stops, starts, hwSets, hwResets, resets, deinitializations, clearedTimers: int
  events: seq[string]
  stopHook, deinitHook, initHook, startHook: proc()
  retireHook: proc(vif: uint8)
  rxVifEpochs: array[MAX_VIFS, uint32]
  interrupts = true
  haltAllowed = true
  mac = [2'u8, 3, 4, 5, 6, 7]
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
# vif_mgmt_unregister's retirement of a STA VIF: ME's mask bits and SM.
var
  meMasks: tuple[activeMask, psDisableMask: uint32]
  retiredStaVifs: seq[tuple[vif, vifTypeThen: uint8]]
proc meEnvView(): ptr typeof(meMasks) = addr meMasks
proc smStaVifRetired(vifIdx: uint8) = retiredStaVifs.add((vifIdx, vifs[vifIdx].vifType))
proc txlResetting(): bool = false
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool =
  selected = 0
  haltAllowed
proc txl_cntrl_halt_ac(ac: uint8): bool = haltAllowed
proc txl_retire_vif(vif: uint8; selected: uint8) =
  if retireHook != nil: retireHook(vif)
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelAt(p: uint): ptr Vif = cast[ptr Vif](p)
template vif_info_tab: untyped = vifs
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc vifMgmtEnvView(): ptr Env = addr env
proc mmEnvView(): ptr typeof(mm) = addr mm
proc wpaCallbacks(): ptr typeof(callbacks) = addr callbacks
proc mmBeaconPoolIdle(): bool = not poolBusy
proc apmPrepareVifRemoval(i: uint8): bool = removalReady
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc regRead(address: uint): uint32 =
  if address == MACHW_BASE + 0x10: 0x05040302'u32
  elif address == MACHW_BASE + 0x14: 0x0706'u32
  else: 0'u32
proc regWrite(address: uint; value: uint32) = discard
proc mm_hw_info_set(p: pointer) = inc hwSets
proc mm_hw_ap_info_set(i: uint8) = discard
proc mm_hw_ap_info_reset(i: uint8) = inc hwResets
proc mm_bcn_init_vif(p: pointer) =
  inc starts
  if startHook != nil: startHook()
proc mm_bcn_stop(p: pointer): bool =
  doAssert vifChannelAt(p).vifType == VIF_TYPE_AP
  inc stops
  events.add("stop")
  if stopHook != nil: stopHook()
  true
proc td_start(i: uint8) = discard
proc td_reset(i: uint8) = inc resets
proc mm_timer_clear(p: pointer) = inc clearedTimers
proc mm_sta_timer_bcn_timeout(p: pointer) {.cdecl.} = discard
proc mm_sta_tbtt(p: pointer) {.cdecl.} = discard
proc mm_sta_timer_data_timeout(p: pointer) {.cdecl.} = discard
proc vif_mgmt_bcn_to_evt(p: pointer) {.cdecl.} = discard
proc deinit() {.cdecl.} =
  inc deinitializations
  if deinitHook != nil: deinitHook()
proc init() {.cdecl.} =
  if initHook != nil: initHook()
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc c_memset(dst: pointer; value: cint; n: csize_t): pointer =
  doAssert n in [sizeof(Vif).csize_t, sizeof(Env).csize_t] and value == 0
  events.add("zero")
  zeroMem(dst, n.int)
  dst
proc assert_err(a, b: cstring; line: cint) = doAssert false
proc reset() =
  env = default(Env)
  vifs = default(typeof(vifs))
  for i in 0 .. 1:
    vifs[i].vifIdx = i.uint8
    vifs[i].vifType = 4
  stops = 0
  starts = 0
  hwSets = 0
  hwResets = 0
  resets = 0
  clearedTimers = 0
  deinitializations = 0
  poolBusy = false
  removalReady = true
  wpa_cbs = addr callbacks
  callbacks.deinit = cast[pointer](deinit)
  callbacks.init = cast[pointer](init)
  events.setLen(0)
  stopHook = nil
  deinitHook = nil
  initHook = nil
  startHook = nil
  retireHook = nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vif_registration_and_unregister_use_current_owner(tmp_path: Path, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    vif = (FW / "vif_management.nim").read_text()
    code = VIF_PLATFORM.replace(
        "  Timer = object\n", "  Timer = object\n    next: ptr CoListHdr\n"
    ).replace("proc mm_timer_clear(p: pointer) = inc clearedTimers\n", "")
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    for name in ["co_list_init", "co_list_push_front", "co_list_push_back", "co_list_pop_front", "co_list_extract", "co_list_find"]:
        code += procedure(kernel, name)
    code += r'''
var timerQueue: CoList
proc mm_timer_clear(p: pointer) =
  inc clearedTimers
  co_list_extract(addr timerQueue, cast[ptr CoListHdr](p))
'''
    for name in ["vif_mgmt_entry_init", "vif_mgmt_init", "vif_mgmt_register", "vif_mgmt_unregister"]:
        code += procedure(vif, name)
    code += r'''
for removed in 0'u8 .. 1:
  for kind in [VIF_TYPE_STA, VIF_TYPE_AP]:
    reset()
    vifs[removed].vifType = kind
    vifs[removed xor 1].vifType = (if kind == VIF_TYPE_AP: VIF_TYPE_STA else: VIF_TYPE_AP)
    env.staCount = 1
    env.apCount = 1
    let epoch = rxVifEpochs[removed]
    let otherEpoch = rxVifEpochs[removed xor 1]
    co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
    co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[1]))
    let watchdog = cast[ptr CoListHdr](addr vifs[removed].keepAliveTimer)
    let security = cast[ptr CoListHdr](addr vifs[removed].securityTimer)
    let unrelated = cast[ptr CoListHdr](addr vifs[removed xor 1].beaconTimeoutTimer)
    co_list_init(addr timerQueue)
    if kind == VIF_TYPE_STA:
      co_list_push_back(addr timerQueue, watchdog)
    co_list_push_back(addr timerQueue, unrelated)
    if kind == VIF_TYPE_STA:
      # Linked after the survivor: a removal that zeroes it while linked
      # leaves it as the list's tail.
      co_list_push_back(addr timerQueue, security)
    stopHook = proc() =
      doAssert rxVifEpochs[removed] == epoch + 1
      vif_mgmt_unregister(removed)
    deinitHook = proc() =
      doAssert rxVifEpochs[removed] == epoch + 1
      vif_mgmt_unregister(removed)
    var retireCalls = 0
    retireHook = proc(vif: uint8) =
      inc retireCalls
      doAssert vif == removed and not interrupts
      doAssert rxVifEpochs[removed] == epoch + 1
      doAssert not co_list_find(addr env.activeList, cast[ptr CoListHdr](addr vifs[removed]))
      doAssert env.freeList.first == nil
      doAssert vif_mgmt_unregister(removed)
      doAssert retireCalls == 1 and clearedTimers == 0 and resets == 0
    if kind == VIF_TYPE_AP:
      removalReady = false
      doAssert not vif_mgmt_unregister(removed)
      doAssert rxVifEpochs[removed] == epoch
      doAssert events.len == 0 and env.apCount == 1 and env.staCount == 1
      doAssert env.freeList.first == nil and vifs[removed].vifType == VIF_TYPE_AP
      doAssert co_list_find(addr env.activeList, cast[ptr CoListHdr](addr vifs[removed]))
      removalReady = true
    vif_mgmt_unregister(removed)
    doAssert retireCalls == 1
    doAssert rxVifEpochs[removed] == epoch + 1
    doAssert rxVifEpochs[removed xor 1] == otherEpoch
    doAssert stops == (kind == VIF_TYPE_AP).int
    doAssert deinitializations == (kind == VIF_TYPE_STA).int
    if kind == VIF_TYPE_AP: doAssert events == @["stop", "zero"]
    else: doAssert events == @["zero"]
    doAssert vifs[removed].vifType == 4
    doAssert timerQueue.first == unrelated and timerQueue.last == unrelated and
      unrelated.next == nil, "VIF removal did not preserve the unrelated timer"
    doAssert clearedTimers == (if kind == VIF_TYPE_STA: 4 else: 2) and resets == 1
    doAssert env.activeList.first == cast[ptr CoListHdr](addr vifs[removed xor 1])
    doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[removed])
    let before = events
    vif_mgmt_unregister(removed)
    vif_mgmt_unregister(255)
    doAssert rxVifEpochs[removed] == epoch + 1
    doAssert events == before

reset()
let epochsBefore = rxVifEpochs
co_list_push_back(addr env.freeList, cast[ptr CoListHdr](addr vifs[0]))
co_list_push_back(addr env.freeList, cast[ptr CoListHdr](addr vifs[1]))
var index = 255'u8
poolBusy = true
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_AP, false, addr index) == 1
doAssert index == 255 and hwSets == 0 and starts == 0
doAssert rxVifEpochs == epochsBefore
poolBusy = false
startHook = proc() = doAssert rxVifEpochs[0] == epochsBefore[0] + 1
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_AP, false, addr index) == 0
doAssert index == 0 and starts == 1 and hwSets == 1
index = 255
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_AP, false, addr index) == 1
doAssert index == 255 and starts == 1 and hwSets == 1
doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[1])
doAssert rxVifEpochs[0] == epochsBefore[0] + 1 and rxVifEpochs[1] == epochsBefore[1]

# Cold/global VIF initialization advances, rather than resets, both epochs.
let beforeInit = rxVifEpochs
doAssert vif_mgmt_init()
for i in 0 .. 1:
  doAssert rxVifEpochs[i] == beforeInit[i] + 1
  doAssert vifs[i].vifType == 4
doAssert env.activeList.first == nil
doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[0])
doAssert env.freeList.last == cast[ptr CoListHdr](addr vifs[1])

# STA registration also advances before its external WPA initializer runs.
let beforeSta = rxVifEpochs
initHook = proc() = doAssert rxVifEpochs[0] == beforeSta[0] + 1
index = 255
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr index) == 0
doAssert index == 0 and rxVifEpochs[1] == beforeSta[1] and interrupts
let beforeEntryReset = rxVifEpochs
doAssert vif_mgmt_entry_init(addr vifs[0])
doAssert rxVifEpochs[0] == beforeEntryReset[0] + 1
doAssert rxVifEpochs[1] == beforeEntryReset[1] and vifs[0].vifType == 4
'''
    path = tmp_path / "vif.nim"
    path.write_text(code)
    options = {"checked": [], "release": ["-d:release"], "asan": ["--cc:clang",
               "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", *options[mode], str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
