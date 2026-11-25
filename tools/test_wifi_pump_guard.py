"""Check the firmware step guard against a host callback that polls.

The real firmware entries (wifi_main_poll_once -> wifiMainServiceStep and the
facade's wifi_nimfw_service_tx) run with the real support poll
(vendorPollOnce) and osSleepUs. A firmware handler that sleeps, as a host
callback can, must not see the firmware entered again, while MAC interrupt
servicing still runs on every poll.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


SUPPORT = FW.parent / "support"

HARNESS = r'''
const BlNapWaking = 2'u32
var
  wifiStepActive: bool
  nimFwDbgNestedPump: uint32
  napScheduleState: uint32
  fwStarted = true
  hostPollEnabled = false
  clock: uint64
  inHandler, nested, handled, macIrqPolls, hostDrains, pmSteps, txServices: int
  pending: int          # firmware work queued for the next step
  sleepInHandler = 0'u64
  waits: int
  onWait: proc()
proc wifiUpdateMacPlCtrl() = discard
proc bl_sleep_schedule() = discard
proc wifiMainHasPendingWork(): bool = pending != 0
proc ipc_emb_wait() =
  inc waits
  if onWait != nil: onWait()
proc osSleepUs(duration: uint64)
proc handler() =
  ## A firmware handler that runs a host callback which sleeps.
  if inHandler != 0: inc nested
  inc inHandler
  inc handled
  if sleepInHandler != 0: osSleepUs(sleepInHandler)
  dec inHandler
proc wifiDrainScheduledWork(): bool =
  if pending == 0: return false
  dec pending
  handler()
  true
proc wifi_nimfw_service_sta_postponed(limit: uint32): uint32 = 0
proc txl_transmit_trigger() = discard
proc txl_frame_evt() =
  inc txServices
  handler()
proc bl808WifiBackendPollEmbEvents() = discard
proc bl808WifiBackendPollMacIrq() = inc macIrqPolls
proc vendorDrainScheduledWork() = inc hostDrains
proc mgmrPmProcessOne(): bool =
  inc pmSteps
  false
proc wifiHwRaw(): pointer = nil
proc loadPtr(base: pointer; offset: int): pointer = nil
proc bl_main_event_handle(event: int; arg: pointer) = doAssert false
proc osTimerPoll() = discard
proc aosPollEvents() = discard
proc aosPollDelayedActions() = discard
proc sampleMtimeUs(value: var uint64): bool =
  value = clock
  true
proc delayMtimeUs(us: uint32) = clock += us.uint64
proc reset() =
  doAssert not wifiStepActive and inHandler == 0
  nimFwDbgNestedPump = 0
  nested = 0
  handled = 0
  macIrqPolls = 0
  hostDrains = 0
  pmSteps = 0
  txServices = 0
  pending = 0
  sleepInHandler = 0
  waits = 0
  onWait = nil
'''


def source() -> str:
    main = (FW / "task_init_main.nim").read_text()
    code = HARNESS
    for name in ("wifiStepEnter", "wifiStepLeave", "wifi_nimfw_step_active",
                 "wifiWaitForWorkIfIdle", "wifi_nimfw_service_tx", "wifiMainServiceStep",
                 "wifiMainServiceNonblocking", "wifi_main_poll_once"):
        code += procedure(main, name)
    code += procedure((SUPPORT / "backend_runtime_parts/poll.nim").read_text(), "vendorPollOnce")
    code += procedure((SUPPORT / "os_adapter_parts/events_tasks.nim").read_text(), "osSleepUs")
    return code


CASES = {
    "handler_sleep_does_not_reenter": r'''
reset()
pending = 2
sleepInHandler = 300            # three 100 us quanta, each a vendorPollOnce
vendorPollOnce()
doAssert handled == 1 and nested == 0, "a sleeping handler reentered the firmware"
doAssert pending == 1, "a nested poll ran queued firmware work"
doAssert nimFwDbgNestedPump == 3
# MAC servicing ran on the outer poll and on each nested one; host queue work
# waited for the outer poll, which ran it after the step.
doAssert macIrqPolls == 4 and hostDrains == 1 and pmSteps == 1
doAssert not wifiStepActive
vendorPollOnce()
doAssert handled == 2 and pending == 0 and nested == 0 and hostDrains == 2
''',
    "facade_tx_service_is_one_step": r'''
reset()
pending = 1
sleepInHandler = 200
wifi_nimfw_service_tx(2)
# Each confirmation event runs a handler that sleeps for two quanta: the
# nested polls neither run the queued work nor enter the TX service again.
doAssert txServices == 2 and handled == 2 and nested == 0
doAssert pending == 1 and nimFwDbgNestedPump == 4 and macIrqPolls == 4
doAssert hostDrains == 0 and not wifiStepActive
# Asked for from inside a firmware step, the TX service is refused.
reset()
wifiStepActive = true
wifi_nimfw_service_tx(1)
doAssert txServices == 0 and nimFwDbgNestedPump == 1
wifiStepLeave()
''',
    "idle_wait_releases_the_step": r'''
reset()
# The blocking form waits for the host with no handler on the stack; the
# host's wait may run the firmware.
onWait = proc() =
  doAssert not wifiStepActive
  pending = 1
  vendorPollOnce()
discard wifiMainServiceStep(blockWhenIdle = true)
doAssert waits == 1 and handled == 1 and pending == 0 and nimFwDbgNestedPump == 0
doAssert not wifiStepActive
''',
}


@pytest.mark.parametrize("mode", ["checked", "release"])
@pytest.mark.parametrize("case", CASES)
def test_pump_guard(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case], defines=("bl808WifiOpCheck",))


def test_guarded_entries() -> None:
    """Every host-side firmware entry is a step; MAC servicing is outside it."""
    main = (FW / "task_init_main.nim").read_text()
    for name in ("wifiMainServiceStep", "wifi_nimfw_service_tx"):
        body = procedure(main, name)
        assert "if not wifiStepEnter(): return" in body
        assert "defer: wifiStepLeave()" in body
    poll = procedure((SUPPORT / "backend_runtime_parts/poll.nim").read_text(), "vendorPollOnce")
    assert poll.index("bl808WifiBackendPollMacIrq()") < poll.index("wifi_main_poll_once()")
    assert "if not wifi_nimfw_step_active():" in poll
    facade = (FW.parent / "facade_parts/runtime_wrappers_parts/firmware_station.nim").read_text()
    service = facade.split("proc wifiNimFirmwareServiceTx", 1)[1]
    assert "wifi_nimfw_service_tx(count)" in service
    assert "txl_frame_evt()" not in service and "txl_transmit_trigger()" not in service
