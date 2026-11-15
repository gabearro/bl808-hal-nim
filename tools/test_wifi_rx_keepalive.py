"""Keep null-frame activity accounting current across trace and clock callbacks."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx


PLATFORM = r'''
type
  Activity = object
    keepAliveTimestamp, keepAliveCounter: uint32
var
  mm: Activity
  txResetEpoch, tickValue: uint32
  resetting, missingClock: bool
  enabled = true
  clockCalls: int
  onClock: proc()
proc mmEnvView(): ptr Activity = addr mm
proc txlResetting(): bool = resetting
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc tick(): uint32 {.cdecl.} =
  inc clockCalls
  result = tickValue
  if onClock != nil: onClock()
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 200
  if missingClock: nil else: cast[pointer](tick)
proc initialize(irq: bool) =
  mm = Activity(keepAliveTimestamp: 17, keepAliveCounter: 3)
  enabled = irq
  txResetEpoch = 0
  tickValue = 1000
  clockCalls = 0
  resetting = false
  missingClock = false
  onClock = nil
'''


def helper() -> str:
    return procedure((FW / "kernel_mac_channel.nim").read_text(),
                     "mm_cfg_element_keepalive_timestamp_update")


def receiver_source() -> str:
    code = rx.dispatch_source()
    for name in ["mm_cfg_element_keepalive_timestamp_update", "irqSave", "irqRestore", "blOpsFunc"]:
        code = code.replace(procedure(code, name), "")
    before, receiver = code.split("proc rxu_cntrl_frame_handle*", 1)
    setup = rx.CHECKS.split("proc checkFrame(", 1)[0]
    return "{.define: bl808WifiConnectTrace.}\n" + before + PLATFORM + helper() + r'''
var onNullTrace: proc()
var traceStage: string
const TASK_SM = 4
const SmAuthStartingState = 2'u16
proc ke_state_get(task: int): uint16 = 0
proc nimFwConnectTrace2U32(prefix: string; a, b: uint32) =
  if prefix == traceStage and onNullTrace != nil:
    onNullTrace()
proc nimFwConnectTraceBytes(prefix: string; p: pointer; length, limit: uint32) =
  if prefix == traceStage and onNullTrace != nil: onNullTrace()
''' + setup + "proc rxu_cntrl_frame_handle*" + receiver


UNIT_CASES = {
    "normal_and_unavailable": r'''
for irq in [false, true]:
  for count in [0'u32, 7, 0xFFFFFFFF'u32]:
    initialize(irq)
    mm.keepAliveCounter = count
    mm_cfg_element_keepalive_timestamp_update()
    doAssert enabled == irq and clockCalls == 1
    doAssert mm.keepAliveTimestamp == 1000 and mm.keepAliveCounter == count + 1
  initialize(irq)
  missingClock = true
  let before = mm
  mm_cfg_element_keepalive_timestamp_update()
  doAssert enabled == irq and mm == before and clockCalls == 0
  initialize(irq)
  resetting = true
  let blocked = mm
  mm_cfg_element_keepalive_timestamp_update()
  doAssert enabled == irq and mm == blocked and clockCalls == 0
''',
    "reset_and_errors": r'''
for irq in [false, true]:
  for action in 0 .. 2:
    initialize(irq)
    onClock = proc() =
      doAssert enabled == irq
      if action == 0:
        inc txResetEpoch
        mm = Activity(keepAliveTimestamp: 0xABCD, keepAliveCounter: 0x1234)
      elif action == 1: resetting = true
      else: raise newException(ValueError, "clock callback interrupted")
    var raised = false
    try: mm_cfg_element_keepalive_timestamp_update()
    except ValueError: raised = true
    doAssert enabled == irq and clockCalls == 1 and raised == (action == 2)
    let expected = if action == 0:
      Activity(keepAliveTimestamp: 0xABCD, keepAliveCounter: 0x1234)
      else: Activity(keepAliveTimestamp: 17, keepAliveCounter: 3)
    doAssert mm == expected, "old activity update changed reset MM state"
''',
    "nested_activity": r'''
for irq in [false, true]:
  for count in [0'u32, 0xFFFFFFFF'u32]:
    initialize(irq)
    mm.keepAliveCounter = count
    onClock = proc() =
      if clockCalls == 1:
        tickValue = 2000
        mm_cfg_element_keepalive_timestamp_update()
    mm_cfg_element_keepalive_timestamp_update()
    doAssert enabled == irq and clockCalls == 2
    doAssert mm.keepAliveCounter == count + 2
    doAssert mm.keepAliveTimestamp == 2000, "older clock result overwrote nested activity"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", UNIT_CASES)
def test_activity_clock(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, PLATFORM + helper() + UNIT_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_retired_null_frame_skips_activity(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, receiver_source() + r'''
for stage in ["[WIFI-CT] rx_enter ", "[WIFI-CT] rx_len ",
              "[WIFI-RAW] rx_any ", "[WIFI-CT] rx_drop "]:
  for change in 0 .. 3:
    setup(0x0248, 24, 0)
    initialize(true)
    traceStage = stage
    onNullTrace = proc() =
      case change
      of 0: inc rxGeneration
      of 1: sessionCurrent = false
      of 2: mpdu.swDesc = nil
      else: discard
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert clockCalls == (change == 3).int
    doAssert mm.keepAliveCounter == (if change == 3: 4'u32 else: 3'u32)
    doAssert transferred == 0 and prepared == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_null_frame_clock_reset_keeps_new_mm_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, receiver_source() + r'''
setup(0x0248, 24, 0)
initialize(true)
onNullTrace = nil
onClock = proc() =
  inc txResetEpoch
  mm = Activity(keepAliveTimestamp: 0xAABB, keepAliveCounter: 0xCCDD)
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert clockCalls == 1 and enabled
doAssert mm == Activity(keepAliveTimestamp: 0xAABB, keepAliveCounter: 0xCCDD)
doAssert transferred == 0 and prepared == 0
''')
