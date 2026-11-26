"""Check that a MAC reset timeout cannot publish software reset completion."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_channel_control import OP_STUBS, PLATFORM as CHANNEL_PLATFORM
from test_wifi_switch_request import run_case as run_switch_case
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_mac_state_poll import source as polling_source
from test_wifi_message_allocation import run_program
from test_wifi_tx_reset_owner import source as tx_reset_source


SUPPORT = r'''
const
  TASK_MM = 0'u8
  HW_ACTIVE = 3'u8
var
  mm: MmEnvView
  interrupts: bool
  steps: seq[string]
  onRx: proc()
proc mmEnvView(): ptr MmEnvView = addr mm
proc waitMacSoftResetClear(): bool = true
template smSaQueryResetScope() = discard
proc smSaQueryClearResetTimer() = discard
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc ke_evt_clear(mask: uint32) =
  doAssert not interrupts
  steps.add("clear:" & $mask)
  eventField = eventField and not mask
proc rxl_reset(): bool =
  doAssert not interrupts
  steps.add("rx")
  if onRx != nil: onRx()
  true
proc txl_reset(): bool =
  doAssert not interrupts
  steps.add("tx")
  tx.resetInProgress = 0
  true
proc mm_reset() =
  doAssert not interrupts
  steps.add("mm")
proc vif_mgmt_reset() =
  doAssert not interrupts
  steps.add("vif")
proc apmResumeHaltRollback() =
  doAssert not interrupts
  steps.add("apm")
proc ke_state_set(task: uint8; state: uint16) =
  doAssert not interrupts and task == TASK_MM and state == HW_ACTIVE.uint16
  steps.add("state")
proc ke_reschedule_saved_messages(task: uint8): bool =
  doAssert not interrupts and task == TASK_MM
  steps.add("saved")
  false
proc resetFixture(irq: bool; frozen: bool) =
  setup(if frozen: @[3'u32] else: @[3'u32, 0x30'u32])
  mm = default(MmEnvView)
  mm.previousState = 7
  mm.hardwareMode = 9
  mm.keepAliveInterval = 123
  interrupts = irq
  steps.setLen(0)
  onRx = nil
  eventField = 0x84004000'u32
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return (
        polling_source() + layouts("MmEnvView") + SUPPORT
        + ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n" + procedure(kernel, "mm_force_idle_req"))
        + procedure((FW / "platform_bl.nim").read_text(), "bl_reset_evt")
    )


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_hardware_timeout_keeps_work_and_interrupts_gated(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
resetFixture(true, true)
let before = ps
hal_machw_reset()
doAssert ps == before
doAssert tx.resetInProgress == 1
doAssert (eventField and 0x80000000'u32) != 0
doAssert (registers[MACHW_STATUS_REG] and 0x80) == 0
doAssert (registers[MACHW_INTC_UNMASK_REG] and 0x80000000'u32) == 0
doAssert (registers[MACHW_INTC_GEN_STATUS] and 0x80000000'u32) == 0
doAssert writes.len == 5 and steps.len == 0
doAssert timeouts == @[(MACHW_STATE_CNTRL_REG.uint32, 0xF'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_forced_idle_failure_does_not_reset_queues_or_publish_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  resetFixture(irq, true)
  let before = mm
  doAssert not mm_force_idle_req()
  doAssert steps.len == 0 and mm == before and interrupts == irq
  doAssert tx.resetInProgress == 1 and (eventField and 0x80000000'u32) != 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_event_retries_without_false_completion(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  resetFixture(irq, true)
  bl_reset_evt()
  doAssert steps == @["clear:2147483648"] and interrupts == irq
  doAssert eventField == 0x84004000'u32 and tx.resetInProgress == 1

  stateSamples = @[3'u32, 0x30'u32]
  stateReads = 0
  steps.setLen(0)
  bl_reset_evt()
  doAssert steps == @["clear:2147483648", "rx", "tx", "mm", "vif", "apm", "clear:67108864", "saved"]
  doAssert eventField == 0x4000'u32 and tx.resetInProgress == 0 and interrupts == irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_forced_idle_success_preserves_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  resetFixture(irq, false)
  let before = mm
  doAssert mm_force_idle_req()
  doAssert steps == @["rx", "tx", "state"] and interrupts == irq
  var expected = before
  expected.previousState = 0
  expected.hardwareMode = 0
  doAssert mm == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_callers_restore_interrupts_on_cleanup_failure(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for forced in [false, true]:
    resetFixture(irq, false)
    onRx = proc() = raise newException(ValueError, "modeled cleanup failure")
    try:
      if forced: discard mm_force_idle_req()
      else: bl_reset_evt()
      doAssert false
    except ValueError:
      doAssert interrupts == irq and steps[^1] == "rx"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pending_retry_preempts_other_events(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    event_support = r'''
const KE_EVT_MAX = 32
template keEvtField: untyped = eventField
template keEnvEventField(): ptr uint32 = addr eventField
var
  keEvtHandlers: array[32, tuple[handler, param: pointer]]
  lowerEvents: int
proc nimFwTrace2U32(label: string; a, b: uint32) = discard
proc assert_err(condition, file: cstring; line: cint) = doAssert false
proc resetEvent(p: pointer) {.cdecl.} = bl_reset_evt()
proc lowerEvent(p: pointer) {.cdecl.} =
  inc lowerEvents
  eventField = 0
'''
    code = source() + event_support
    code += "".join(procedure(kernel, name) for name in (
        "eventIndex32", "keDispatchEvent", "ke_evt_schedule"))
    run_program(tmp_path, mode, code + r'''
resetFixture(true, true)
keEvtHandlers[0].handler = cast[pointer](resetEvent)
keEvtHandlers[5].handler = cast[pointer](lowerEvent)
keEvtHandlers[17].handler = cast[pointer](lowerEvent)
for attempt in 0 .. 1:
  ke_evt_schedule()
  doAssert lowerEvents == 0 and tx.resetInProgress == 1
  doAssert (eventField and 0x80000000'u32) != 0
stateSamples = @[3'u32, 0'u32]
stateReads = 0
ke_evt_schedule()
doAssert lowerEvents == 0 and tx.resetInProgress == 0
ke_evt_schedule()
doAssert lowerEvents == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_gate_reaches_real_tx_admission(tmp_path: Path, mode: str) -> None:
    support = r'''
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
type
  HostTxDescView = object
    vifIdx, staInfoIdx: uint8
  Station = object
    instNbr, valid: uint8
var station = Station(instNbr: 0, valid: 1)
proc txlVifIsRetiring(index: uint8): bool = false
proc txlFrameSessionCurrent(desc: ptr HostTxDescView): bool = true
proc staInfoForIdx(index: uint8): ptr Station = addr station
'''
    tx = (FW / "tx_layer.nim").read_text()
    code = source() + support
    code += procedure(tx, "txlResetting") + procedure(tx, "txlStationAdmits")
    run_program(tmp_path, mode, code + r'''
resetFixture(true, true)
var frame = HostTxDescView(vifIdx: 0, staInfoIdx: 0)
doAssert txlStationAdmits(addr frame)
bl_reset_evt()
doAssert not txlStationAdmits(addr frame)
stateSamples = @[3'u32, 0'u32]
stateReads = 0
bl_reset_evt()
doAssert txlStationAdmits(addr frame)
''')


@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_channel_switch_stops_after_failed_idle(tmp_path: Path, mode: str) -> None:
    """A forced idle that times out never retunes the MAC it failed to stop.

    MM is handed back (never left in HW_ACTIVE) and the switch asks MM again;
    it completes once the posted recovery has made the forced idle succeed.
    """
    run_switch_case(tmp_path, r'''
var failForceAt: int
for failAt in 1 .. 2:
  resetSwitch()
  failForceAt = failAt
  onIdle = proc() = forceFailed = forced == failForceAt
  let home = newTarget(2412)
  linkHome(home, VIF_TYPE_STA, 0)
  activateVifs(1)
  operate(home)
  let away = newTarget(2437)
  chan_switch_start(away)
  doAssert dispatch()                # MM active: idle request, saved
  idleInterrupt()
  doAssert dispatch()                # chan_goto_idle_cb: forced idle 1
  if failAt == 1:
    doAssert forced == 1 and frames.len == 0 and chanSw.phase == swQueued
  else:
    doAssert frames.len == 1 and chanSw.phase == swProtecting
    completeFrame(0)                 # the departure's forced idle 2 fails
    doAssert forced == 2 and chanSw.phase == swDeparting
  doAssert tuned.len == 0, "retuned a MAC that failed to stop"
  doAssert requestLinked() and mmState == MM_ACTIVE_STATE
  settle()                           # after the posted recovery, the retry succeeds
  if failAt == 1:
    doAssert frames.len == 1 and tuned.len == 0
    completeFrame(0)
  doAssert tuned == @[away] and channelEnv.currentCtxt == away and idleSwitch()
  finishSwitch()
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_completion_does_not_reactivate_failed_mac(tmp_path: Path, mode: str) -> None:
    platform = CHANNEL_PLATFORM + OP_STUBS
    original = procedure(platform, "mm_force_idle_req")
    platform = platform.replace(original, r'''
proc mm_force_idle_req(): bool =
  events.add(("force-idle", 0'u))
  false
''', 1)
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = platform
    code += procedure((FW / "task_handlers.nim").read_text(), "chan_get_dominant_chan")
    code += procedure(kernel, "chanCtxtOpEvent")
    code += procedure(kernel, "chan_ctxt_op_evt")
    run_program(tmp_path, mode, code + r'''
reset()
contexts[3].status = 4
env.currentCtxt = addr contexts[3]
env.ctxtCount = 0
chan_ctxt_op_evt(addr contexts[3])
filterIrqEvents()
doAssert events[^1].kind == "force-idle"
for event in events: doAssert event.kind != "host-idle"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_real_tx_reset_clears_preexisting_timeout_gate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, tx_reset_source(check_initialization=True) + r'''
setup()
resetMode = true
control.resetInProgress = 1
txl_reset()
doAssert control.resetInProgress == 0 and not txResetActive
doAssert flushAcs.len == 10 and resetStatusReads == 3
for ac in 0 .. 4:
  doAssert control.ac[ac].packetCount == (0x1234 + ac).uint16
  doAssert control.ac[ac].current == nil
  doAssert control.ac[ac].pending.first == nil
''')
