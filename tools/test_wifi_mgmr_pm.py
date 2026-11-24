"""Exercise the manager PM callbacks against the pure Nim PM registry."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


ROOT = Path(__file__).resolve().parents[1]
PM = ROOT / "src/bl808/wifi/support/runtime_facade_parts/power_management.nim"
MGMR = ROOT / "src/bl808/wifi/support/mgmr_facade_parts/power_management.nim"
CALLBACKS = ROOT / "src/bl808/wifi/support/mgmr_facade_parts/callbacks.nim"
LAYOUT = ROOT / "src/bl808/wifi/support/defs_parts/vendor_layout_parts"


def source() -> str:
    return r'''
type
  PmEvent = enum control, enterSleep, exitSleep, beaconLoss, sendNull, bleControl
  PmLevel = enum noPower, idle, mesh, doze, coex, down, apIdle
  PmEventAble = enum disabled, enabled
  PmCb = proc(arg: pointer): cint {.cdecl.}
var
  wifiStarted: bool
  sentModes: seq[cint]
  registrationFailureCode = high(uint32)
  registrationCalls: int
  criticalDepth: int
proc mgmrPmProcessOne(): bool
proc osEnterCritical(): uint32 =
  inc criticalDepth
  criticalDepth.uint32
proc osExitCritical(saved: uint32) =
  doAssert saved == criticalDepth.uint32
  dec criticalDepth
proc bl_main_powersaving(mode: cint): cint =
  doAssert criticalDepth == 0
  doAssert not mgmrPmProcessOne()
  sentModes.add(mode)
  0
proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint
    {.exportc, cdecl.}
''' + PM.read_text() + r'''
proc wifi_hosal_pm_event_register(event: PmEvent; code, capBit: uint32;
    priority: uint16; callback: PmCb; argument: pointer;
    enable: PmEventAble): cint =
  inc registrationCalls
  if code == registrationFailureCode:
    return -1
  bl_pm_event_register(event, code, capBit, priority, callback, argument, enable)
proc wifi_hosal_pm_event_switch(event: PmEvent; code: uint32;
    enable: PmEventAble): cint =
  bl_pm_event_switch(event, code, enable)
proc wifi_hosal_pm_capacity_set(level: PmLevel): cint = bl_pm_capacity_set(level)
proc wifi_hosal_pm_post_event(event: PmEvent; code: uint32;
    retval: ptr uint32): cint = pm_post_event(event, code, retval)
''' + MGMR.read_text()


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_manager_pm_start_stop_and_deferred_command(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert bl_pm_init() == 0
doAssert bl_pm_event_register(beaconLoss, 0, 4, 100, nil, nil, disabled) == 0
doAssert bl_pm_event_register(sendNull, 1, 2, 8, nil, nil, disabled) == 0
doAssert bl_pm_event_register(exitSleep, 0, 2, 60, nil, nil, disabled) == 0
doAssert wifi_mgmr_pm_ops_register() == 0
doAssert wifi_mgmr_pm_ops_register() == 0
doAssert registrationCalls == 2 and pmNodeCount == 5
doAssert wifi_mgmr_fw_affair_ops() == 0
for nodeIndex in 2 .. 4:
  doAssert pmNodes[nodeIndex].enabled
wifiStarted = true
doAssert wifi_mgmr_sta_ps_enter(3) == 0
doAssert pmState == pmStart and pmWlanCapacity == 0x2F'u32
doAssert sentModes.len == 0 and mgmrPmCount == 1
doAssert mgmrPmProcessOne() and sentModes == @[2.cint]
doAssert bl_pm_state_run() == 0
doAssert wifi_mgmr_sta_ps_exit() == 0
doAssert pmState == pmStop and mgmrPmCount == 1
doAssert mgmrPmProcessOne() and sentModes == @[2.cint, 0.cint]
doAssert bl_pm_state_run() == -1 and pmState == pmStopped
doAssert not mgmrPmProcessOne() and criticalDepth == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_manager_pm_retries_registration_and_preserves_queue_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert bl_pm_init() == 0
registrationFailureCode = 1
doAssert wifi_mgmr_pm_ops_register() == -1
doAssert pmNodeCount == 1 and registrationCalls == 2
registrationFailureCode = high(uint32)
doAssert wifi_mgmr_pm_ops_register() == 0
doAssert pmNodeCount == 2 and registrationCalls == 3
wifiStarted = true
doAssert wifi_mgmr_sta_ps_enter(0x101'u32) == -1
doAssert wifi_mgmr_sta_ps_enter(0) == -1
doAssert pmState == pmInited
for value in 0 ..< MgmrPmQueueCapacity:
  doAssert wifi_mgmr_api_fw_powersaving(value.cint) == 0
doAssert wifi_mgmr_api_fw_powersaving(99) == -1
for value in 0 ..< MgmrPmQueueCapacity:
  doAssert mgmrPmProcessOne()
  doAssert sentModes[^1] == value.cint
doAssert sentModes.len == MgmrPmQueueCapacity
doAssert mgmrPmCount == 0 and criticalDepth == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_disconnect_posts_stop_and_defers_ps_off(tmp_path: Path, mode: str) -> None:
    callbacks = CALLBACKS.read_text()
    callback = "".join(procedure(callbacks, name) for name in
                       ("publishStationResult", "connectCb", "disconnectCb"))
    layout = "\n".join((LAYOUT / name).read_text() for name in ("mgmr_state.nim", "events.nim"))
    run_program(tmp_path, mode, source() + layout + r'''
var
  disconnectDone, connectDone, lastStatusCode, lastReasonCode: int32
  manager: array[(MgmrStatInfoOff + 4).int, uint8]
proc mgmrRaw(): pointer = addr manager[0]
proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc loadU16(p: pointer; offset: uint): uint16 = cast[ptr uint16](ptrAt(p, offset))[]
proc storeU16(p: pointer; offset: uint; value: uint16) =
  cast[ptr uint16](ptrAt(p, offset))[] = value
''' + callback + r'''
doAssert bl_pm_init() == 0
doAssert wifi_mgmr_pm_ops_register() == 0
wifiStarted = true
doAssert wifi_mgmr_sta_ps_enter(3) == 0
doAssert mgmrPmProcessOne() and sentModes == @[2.cint]
doAssert bl_pm_state_run() == 0
var connected = [0'u16, 0'u16]
connectCb(nil, addr connected[0])
var indication = [7'u16, 42'u16]
disconnectCb(nil, addr indication[0])
doAssert disconnectDone == 1 and connectDone == -1
doAssert lastStatusCode == 7 and lastReasonCode == 42
let info = ptrAt(mgmrRaw(), MgmrStatInfoOff)
doAssert loadU16(info, StatStatusOff) == 7 and loadU16(info, StatReasonOff) == 42
connectCb(nil, addr connected[0])
doAssert loadU16(info, StatStatusOff) == 0 and loadU16(info, StatReasonOff) == 0
doAssert pmState == pmStop and mgmrPmCount == 1
doAssert sentModes == @[2.cint]
doAssert mgmrPmProcessOne() and sentModes == @[2.cint, 0.cint]
doAssert bl_pm_state_run() == -1 and pmState == pmStopped
''')
