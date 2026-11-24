"""Check lifecycle ownership when a TX halt cannot finish."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_vif_lifetime import vif_lifetime_source
from test_wifi_station_tx_drain import PLATFORM as STATION_PLATFORM
from test_wifi_ap_start import program_source as ap_source
from test_wifi_ap_rollback import DRIVER
from test_wifi_ap_stop import STOP_HELPERS
from test_wifi_tx_key_update import queue_program
from test_wifi_beacon_update import source as beacon_source
from test_wifi_beacon_transmit import SETUP as BEACON_SETUP
from test_wifi_ps_timer_dispatch import TIMER_OWNER_PLATFORM


NULL_TIMER_PLATFORM = TIMER_OWNER_PLATFORM + r'''
type PowerState = object
  flags, mode, deferredMode, uapsdTimerActive: uint8
  pendingCount: uint32
  currentVif: pointer
var ps: PowerState
template psUapsdTimer(): pointer = cast[pointer](addr ps.uapsdTimerActive)
proc ps_set_mode(mode, requester: uint8) =
  raiseAssert "unexpected deferred mode"
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_null_timer_waits_for_halt_before_confirming(tmp_path: Path, mode: str) -> None:
    code = NULL_TIMER_PLATFORM + r'''
var haltAllowed, clearAllowed: bool
var interrupts = true
var halts, clears, enabled, disabled, rearms: int
var lastDeadline: uint32
var timer: uint32
var params: tuple[txNullTimeout: uint32] = (txNullTimeout: 20'u32)
proc psEnvView(): ptr typeof(ps) = addr ps
proc blPsParamsView(): ptr typeof(params) = addr params
proc psTxNullTimer(): pointer = addr timer
proc macTimeNow(): uint32 = 100'u32
proc mm_timer_set(p: pointer, deadline: uint32) =
  doAssert (p == addr timer) and not interrupts
  inc rearms
  lastDeadline = deadline
proc mm_timer_clear(p: pointer) = raiseAssert "unexpected U-APSD timer clear"
proc irqSave(): bool =
  result = interrupts
  interrupts = false
proc irqRestore(saved: bool) = interrupts = saved
proc txl_cntrl_halt_ac(ac: uint8): bool =
  doAssert ac == 3 and not interrupts
  inc halts
  haltAllowed
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3 and ps.pendingCount == 0 and not interrupts
  doAssert enabled == 0 and disabled == 0
  inc clears
  if not txl_cntrl_halt_ac(ac): return false
  clearAllowed
proc ps_disable_cfm_handle(p: pointer): uint32 =
  doAssert p == ps.currentVif and ps.pendingCount == 0 and
    haltAllowed and clearAllowed and clears == 3
  inc disabled
proc ps_enable_cfm_handle(p: pointer) =
  doAssert p == ps.currentVif and ps.pendingCount == 0 and
    haltAllowed and clearAllowed and clears == 3
  inc enabled
'''
    code += procedure((FW / "power_save.nim").read_text(), "ps_tx_null_timer_handle")
    run_program(tmp_path, mode, code + r'''
for flags in [1'u8, 3, 5]:
  ps = PowerState(flags: flags, pendingCount: 7, currentVif: addr timer)
  claimTimer(ps.currentVif)
  haltAllowed = false
  clearAllowed = false
  interrupts = (flags != 3)
  let beforeInterrupts = interrupts
  halts = 0
  clears = 0
  enabled = 0
  disabled = 0
  rearms = 0
  let before = ps
  ps_tx_null_timer_handle()
  doAssert ps == before and halts == 1 and clears == 1
  doAssert rearms == 1 and lastDeadline == 120
  doAssert interrupts == beforeInterrupts
  doAssert enabled == 0 and disabled == 0
  haltAllowed = true
  ps_tx_null_timer_handle()
  doAssert ps == before and halts == 2 and clears == 2
  doAssert rearms == 2 and lastDeadline == 120
  doAssert interrupts == beforeInterrupts
  doAssert enabled == 0 and disabled == 0
  clearAllowed = true
  ps_tx_null_timer_handle()
  doAssert ps.pendingCount == 0 and halts == 3 and clears == 3
  doAssert rearms == 2
  doAssert interrupts == beforeInterrupts
  doAssert enabled == (flags == 5).int and disabled == (flags == 3).int
  ps_tx_null_timer_handle()
  doAssert halts == 3 and clears == 3
  doAssert rearms == 2
for state in [(0'u8, 7'u32), (1'u8, 0'u32)]:
  ps = PowerState(flags: state[0], pendingCount: state[1])
  claimTimer(nil)
  interrupts = true
  let before = ps
  let priorHalts = halts
  let priorClears = clears
  ps_tx_null_timer_handle()
  doAssert ps == before and interrupts
  doAssert halts == priorHalts and clears == priorClears
  doAssert rearms == 2
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_null_timer_flush_callbacks_cannot_complete_twice(tmp_path: Path, mode: str) -> None:
    power = (FW / "power_save.nim").read_text()
    code = NULL_TIMER_PLATFORM + r'''
var onFlush: proc()
var timer: uint32
var params: tuple[txNullTimeout: uint32]
var interrupts = true
var clears, completions: int
proc psEnvView(): ptr typeof(ps) = addr ps
proc blPsParamsView(): ptr typeof(params) = addr params
proc macTimeNow(): uint32 = 100'u32
proc mm_timer_set(p: pointer, deadline: uint32) =
  raiseAssert "successful halt must not rearm the timer"
proc irqSave(): bool =
  result = interrupts
  interrupts = false
proc irqRestore(saved: bool) = interrupts = saved
proc psTxNullTimer(): pointer = addr timer
proc txlFrameCallbackCurrent(): bool = true
proc ps_check_tx_status_part0_nim(p, callback: pointer): uint32 =
  raiseAssert "a retired null frame must not update retry state"
proc mm_timer_clear(p: pointer) =
  raiseAssert "flush callback must not clear a timer"
proc ps_disable_cfm_handle(p: pointer): uint32 =
  doAssert p == nil and ps.pendingCount == 0 and clears == 1
  inc completions
proc ps_enable_cfm_handle(p: pointer) =
  doAssert p == nil and ps.pendingCount == 0 and clears == 1
  inc completions
'''
    code += procedure(power, "ps_disable_cfm")
    code += procedure(power, "ps_enable_cfm")
    code += r'''
proc txl_cntrl_halt_ac(ac: uint8): bool =
  doAssert ac == 3
  true
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3 and ps.pendingCount == 0 and completions == 0 and not interrupts
  inc clears
  for status in [0'u32, 0x00800000'u32]:
    if (ps.flags and 2) != 0:
      ps_disable_cfm(nil, status)
    elif (ps.flags and 4) != 0:
      ps_enable_cfm(nil, status)
  doAssert completions == 0 and ps.pendingCount == 0
  if onFlush != nil: onFlush()
  true
'''
    code += procedure(power, "ps_tx_null_timer_handle")
    run_program(tmp_path, mode, code + r'''
for flags in [1'u8, 3, 5]:
  ps = PowerState(flags: flags, pendingCount: 7)
  claimTimer(nil)
  clears = 0
  completions = 0
  ps_tx_null_timer_handle()
  doAssert ps.pendingCount == 0 and clears == 1
  doAssert interrupts
  doAssert completions == (if flags == 1: 0 else: 1)
  ps_tx_null_timer_handle()
  doAssert clears == 1 and completions == (if flags == 1: 0 else: 1)

for flags in [3'u8, 5]:
  for reset in [false, true]:
    ps = PowerState(flags: flags, pendingCount: 7)
    claimTimer(nil)
    clears = 0
    completions = 0
    onFlush = proc() =
      if reset: inc txResetEpoch
      else: inc psModeBuildSerial
      ps = PowerState(flags: 9)
    ps_tx_null_timer_handle()
    doAssert clears == 1 and completions == 0
    doAssert ps == PowerState(flags: 9) and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_vif_failure_keeps_identity_and_storage(tmp_path: Path, mode: str) -> None:
    code = vif_lifetime_source()
    stop = procedure(code, "mm_bcn_stop")
    code = code.replace(stop, stop.replace("=\n", "=\n  if not stopAllowed: return false\n", 1), 1)
    run_program(tmp_path, mode, "var stopAllowed = true\n" + code + r'''
for kind in [VIF_TYPE_STA, VIF_TYPE_AP]:
  for incoming in [false, true]:
    reset()
    interrupts = incoming
    haltAllowed = false
    vifs[0].vifType = kind
    vifs[0].state = 1
    vifs[0].chanCtxt = addr mac
    if kind == VIF_TYPE_STA: env.staCount = 1
    else: env.apCount = 1
    co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
    let beforeVifs = vifs
    let beforeEnv = env
    let beforeEpochs = rxVifEpochs
    doAssert not vif_mgmt_unregister(0)
    doAssert vifs == beforeVifs and env == beforeEnv and rxVifEpochs == beforeEpochs
    doAssert stops == 0 and resets == 0 and clearedTimers == 0
    doAssert interrupts == incoming
    doAssert not vif_mgmt_entry_init(addr vifs[0])
    doAssert not vif_mgmt_init()
    doAssert vifs == beforeVifs and env == beforeEnv and rxVifEpochs == beforeEpochs
    haltAllowed = true
    doAssert vif_mgmt_unregister(0)
    doAssert vifs[0].vifType == 4 and env.freeList.first != nil

reset()
haltAllowed = false
co_list_push_back(addr env.freeList, cast[ptr CoListHdr](addr vifs[0]))
let before = vifs[0]
var assigned = 255'u8
doAssert vif_mgmt_register(addr mac[0], VIF_TYPE_STA, false, addr assigned) != 0
doAssert assigned == 255 and vifs[0] == before
doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[0])
haltAllowed = true

reset()
vifs[0].vifType = VIF_TYPE_AP
env.apCount = 1
co_list_push_back(addr env.activeList, cast[ptr CoListHdr](addr vifs[0]))
stopAllowed = false
doAssert not vif_mgmt_unregister(0)
doAssert vifs[0].vifType == VIF_TYPE_AP and env.apCount == 1
doAssert env.activeList.first == cast[ptr CoListHdr](addr vifs[0])
doAssert env.freeList.first == nil and resets == 0 and clearedTimers == 0
stopAllowed = true
doAssert vif_mgmt_unregister(0)
doAssert env.apCount == 0 and env.activeList.first == nil
doAssert env.freeList.first == cast[ptr CoListHdr](addr vifs[0])
''')


def station_source() -> str:
    code = STATION_PLATFORM + r'''
var haltAllowed: bool
var retireCalls: int
proc txlHaltStationQueues(index: uint8; selected: var uint8): bool =
  doAssert not interruptsEnabled
  selected = 0
  haltAllowed
proc txl_retire_station(index: uint8; selected: uint8) = inc retireCalls
'''
    station = (FW / "sta_management.nim").read_text()
    for name in ["staPostponedOwner", "staPostponedOwnerCurrent", "staRemovalCurrent", "staMgmtBeginRemoval"]:
        code += procedure(station, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_station_failure_precedes_identity_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, station_source() + r'''
for incoming in [false, true]:
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  epochs = default(typeof(epochs))
  retireCalls = 0
  interruptsEnabled = incoming
  stations[2] = Sta(valid: 1, instNbr: 0, marker: 0x12345678)
  co_list_push_back(addr vifs[0].stations, addr stations[2].link)
  let beforeStations = stations
  let beforeVifs = vifs
  var owner: StaQueueIdentity
  haltAllowed = false
  doAssert staMgmtBeginRemoval(2, owner) == nil
  doAssert stations == beforeStations and vifs == beforeVifs
  doAssert epochs[2] == 0 and retireCalls == 0 and interruptsEnabled == incoming
  haltAllowed = true
  doAssert staMgmtBeginRemoval(2, owner) == cast[pointer](addr stations[2])
  doAssert stations[2].valid == 0 and epochs[2] == 1 and retireCalls == 1
  doAssert vifs[0].stations.first == nil and interruptsEnabled == incoming
''')


def ap_program() -> str:
    code = ap_source()
    code = code.replace(procedure(code, "irqSave"), r'''
proc irqSave(): uint32 =
  result = apInterrupts.uint32 * 8
  apInterrupts = false
''', 1)
    code = code.replace(procedure(code, "irqRestore"), r'''
proc irqRestore(saved: uint32) = apInterrupts = (saved and 8) != 0
''', 1)
    code = code.replace(procedure(code, "txl_retire_vif"), r'''
proc txl_retire_vif(vif: uint8; selected: uint8) = doAssert not apInterrupts
''', 1)
    old = procedure(code, "txlHaltVifQueues")
    code = code.replace(old, r'''
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool =
  doAssert not apInterrupts
  selected = 0
  haltAllowed
''', 1)
    old = procedure(code, "mm_bcn_stop")
    code = code.replace(old, old.replace("=\n", "=\n  if not beaconAllowed: return false\n", 1), 1)
    return "var apInterrupts = true\nvar haltAllowed = true\nvar beaconAllowed = true\n" + code + DRIVER + STOP_HELPERS


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_ap_stop_retains_requests_until_halt_recovery(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ap_program() + r'''
for vif in 0'u8 .. 1:
  reset(vif, true)
  haltAllowed = true
  beaconAllowed = true
  doAssert dispatchStart() == KeMsgNoFree
  doAssert apInterrupts
  drainStartup()
  vifs[vif].beaconEnabled = 1
  let request = stopRequest(vif, 10)
  let held = allocated
  let epoch = rxVifEpochs[vif]
  let context = apm.hostapdCtx
  haltAllowed = false
  doAssert apm_stop_req_handler(request) == KeMsgSaved
  doAssert apInterrupts
  doAssert not apmStopActive and allocated == held
  doAssert rxVifEpochs[vif] == epoch and apm.hostapdCtx == context
  doAssert channelDeletes == 0 and deinitialized == 0 and controlReplies.len == 0
  haltAllowed = true
  beaconAllowed = false
  doAssert apm_stop_req_handler(request) == KeMsgNoFree
  doAssert apInterrupts
  doAssert apmStopActive and apmRollbackActive and apmRollbackHaltPending
  doAssert allocated == held and apm.hostapdCtx == context
  doAssert channelDeletes == 0 and deinitialized == 0 and controlReplies.len == 0
  apmContinueStartRollback()
  doAssert allocated == held and controlReplies.len == 0
  beaconAllowed = true
  apmResumeHaltRollback()
  drainStartup()
  doAssert not apmRollbackHaltPending
  doAssert deinitialized == 1 and channelDeletes == 1
  doAssert controlReplies == @[(APM_STOP_CFM, TASK_APM, 10'u8, 0'u32)]
  expectStopped(vif, 0)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_mm_delete_does_not_confirm_an_incomplete_halt(tmp_path: Path, mode: str) -> None:
    code = r'''
const
  MmStaDelReqPayloadSize = 1'u32
  KeMsgConsumed = 0.cint
  KeMsgSaved = 1.cint
  KeMsgNoFree = 2.cint
  MM_STA_DEL_CFM = 13'u16
type
  Header = object
    paramLen: uint32
    srcId, destId: uint8
  Request = object
    staIdx: uint8
  CoListHdr = object
var header: Header
var request: Request
var blocked, failHalt: bool
var deletes, confirmations: int
var keMsgQueueSaved: pointer
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc txlResetting(): bool = blocked
proc keMsgHdrFromPayload(p: pointer): ptr Header = addr header
proc mmStaDelReqView(p: pointer): ptr Request = addr request
proc smBssAdmitRequest(p: pointer): bool = true
proc smCleanupAdmitRequest(p: pointer): bool = true
proc mmStaDelRetryPending(index: uint8): bool = false
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  inc deletes
  if failHalt: blocked = true
  not blocked
proc co_list_push_back(queue: ptr pointer; node: ptr CoListHdr) = doAssert false
proc mmStaDelQueueRetryLocked(index: uint8; saved: uint32) = doAssert false
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; destination, source: uint8) =
  doAssert id == MM_STA_DEL_CFM and destination == 8 and source == 0
  inc confirmations
'''
    code += procedure((FW / "task_handlers.nim").read_text(), "mm_sta_del_req_handler")
    run_program(tmp_path, mode, code + r'''
header = Header(paramLen: 1, srcId: 8, destId: 0)
request.staIdx = 2
let before = header
failHalt = true
doAssert mm_sta_del_req_handler(addr request) == KeMsgSaved
doAssert header == before and confirmations == 0 and deletes == 1
doAssert mm_sta_del_req_handler(addr request) == KeMsgSaved
doAssert header == before and confirmations == 0 and deletes == 1
blocked = false
failHalt = false
doAssert mm_sta_del_req_handler(addr request) == KeMsgNoFree
doAssert header.paramLen == 0 and confirmations == 1 and deletes == 2
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_key_failure_keeps_queues_and_reservations(tmp_path: Path, mode: str) -> None:
    code = queue_program().split("\nfor incoming in [false, true]:\n  queueReset", 1)[0]
    read = procedure(code, "regRead")
    code = code.replace(read, read.replace(
        "  doAssert not interrupts\n",
        "  doAssert not interrupts\n"
        "  if address == 0x24B08188'u and failedAc >= 0:\n"
        "    return [0x30'u32, 0x300, 0x3000, 0x30000, 3][failedAc]\n",
        1,
    ), 1)
    code = code.replace('  doAssert false, "unexpected halt timeout"', '  discard')
    code = code.replace('  doAssert false, "unexpected MAC recovery"', '  discard')
    code = "var failedAc = -1\n" + code
    run_program(tmp_path, mode, code + r'''
for ac in [0, 2, 3]:
  for incoming in [false, true]:
    queueReset(incoming)
    failedAc = ac
    let oldControls = controls
    let oldConfirmations = confirmations
    let oldBuffers = buffers
    let oldBindings = txSecurityReservations
    doAssert not txSecurityBeginUpdate(addr key)
    doAssert txState.resetInProgress == 1 and txSecurityUpdating == 0
    doAssert controls == oldControls and confirmations == oldConfirmations
    doAssert buffers == oldBuffers and txSecurityReservations == oldBindings
    doAssert detached == 0 and txActiveFlush == (addr ancestor)
    doAssert interrupts == incoming
    failedAc = -1
    txState.resetInProgress = 0
    doAssert txSecurityBeginUpdate(addr key)
    txSecurityEndUpdate(addr key)
    doAssert txSecurityUpdating == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_beacon_halt_failure_preserves_pool(tmp_path: Path, mode: str) -> None:
    code = beacon_source(transmit=True)
    code = code.replace(
        "import bl808/wifi/fw_constants/limits_events",
        f'include "{FW.parent / "fw_constants" / "limits_events.nim"}"',
    )
    old = procedure(code, "txl_cntrl_halt_ac")
    code = code.replace(old, old.replace("  true\n", "  haltAllowed\n"), 1)
    code = "var haltAllowed = true\n" + code + BEACON_SETUP
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  install()
  mm_bcn_transmit(0)
  interruptsEnabled = incoming
  haltAllowed = false
  let oldEnv = env
  let oldPool = pool.bytes
  let oldVifs = vifs
  let generation = mmBcnGeneration
  doAssert not mm_bcn_stop(addr vifs[0])
  doAssert env == oldEnv and pool.bytes == oldPool and vifs == oldVifs
  doAssert mmBcnGeneration == generation and not mmBcnStopping
  doAssert beaconClears == 0 and interruptsEnabled == incoming
  haltAllowed = true
  doAssert mm_bcn_stop(addr vifs[0])
  doAssert env.pendingCount == 0 and interruptsEnabled == incoming
''')
