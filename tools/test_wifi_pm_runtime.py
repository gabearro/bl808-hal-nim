"""Exercise the pure Nim PM runtime against the pinned BL808 SDK contract."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program


PM = Path(__file__).resolve().parents[1] / "src/bl808/wifi/support/runtime_facade_parts/power_management.nim"


def source() -> str:
    return r'''
type
  PmEvent = enum control, enterSleep, exitSleep, beaconLoss, sendNull, bleControl
  PmLevel = enum noPower, idle, mesh, doze, coex, down, apIdle
  PmEventAble = enum disabled, enabled
  PmCb = proc(arg: pointer): cint {.cdecl.}
var
  calls: seq[uint]
  failureArgument: uint
proc callback(arg: pointer): cint {.cdecl.} =
  let value = cast[uint](arg)
  calls.add(value)
  if value == failureArgument: -1 else: 0
proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint
    {.exportc, cdecl.}
''' + PM.read_text()


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pm_registration_order_capabilities_and_results(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert bl_pm_init() == 0
doAssert bl_pm_capacity_set(doze) == 0
doAssert bl_pm_event_register(enterSleep, 0, 2, 20, callback,
  cast[pointer](1'u), enabled) == 0
doAssert bl_pm_event_register(enterSleep, 0, 2, 10, callback,
  cast[pointer](2'u), enabled) == 0
doAssert bl_pm_event_register(enterSleep, 0, 2, 20, callback,
  cast[pointer](3'u), enabled) == 0
doAssert bl_pm_event_register(enterSleep, 0, 16, 5, callback,
  cast[pointer](4'u), enabled) == 0
doAssert bl_pm_event_register(enterSleep, 0, 8, 2, callback,
  cast[pointer](5'u), disabled) == 0
doAssert bl_pm_event_register(enterSleep, 1, 2, 1, callback,
  cast[pointer](6'u), enabled) == 0
var resultBits = 99'u32
doAssert pm_post_event(enterSleep, 0, addr resultBits) == 0
doAssert resultBits == 0 and calls.len == 0
doAssert pm_post_event(control, 0, nil) == 0
doAssert bl_pm_state_run() == 0
failureArgument = 2
doAssert pm_post_event(enterSleep, 0, addr resultBits) == 0
doAssert calls == @[2'u, 1'u, 3'u]
doAssert resultBits == 1
doAssert bl_pm_event_switch(enterSleep, 0, disabled) == 0
calls.setLen(0)
doAssert pm_post_event(enterSleep, 0, addr resultBits) == 0
doAssert calls.len == 0 and resultBits == 0
doAssert bl_pm_event_switch(enterSleep, 0, enabled) == 0
doAssert bl_pm_event_switch(beaconLoss, 0, enabled) == -1
calls.setLen(0)
doAssert pm_post_event(enterSleep, 0, nil) == 0
doAssert calls == @[5'u, 2'u, 1'u, 3'u]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pm_state_and_capacity_transitions(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert bl_pm_state_run() == -1
doAssert bl_pm_capacity_set(idle) == -1
doAssert pm_post_event(control, 0, nil) == -1
doAssert bl_pm_init() == 0 and bl_pm_init() == 0
for entry in [(idle, 0x03'u32), (mesh, 0x33'u32),
    (doze, 0x2F'u32), (coex, 0x1F'u32), (down, 0x0E'u32),
    (apIdle, 0x06'u32)]:
  doAssert bl_pm_capacity_set(entry[0]) == 0
  doAssert pmWlanCapacity == entry[1]
doAssert bl_pm_capacity_set(noPower) == -1
doAssert pmWlanCapacity == 0x06'u32
doAssert bl_pm_capacity_set(doze) == 0
doAssert bl_pm_event_register(control, 2, 2, 1, callback,
  cast[pointer](10'u), enabled) == 0
doAssert bl_pm_event_register(control, 3, 2, 1, callback,
  cast[pointer](11'u), enabled) == 0
doAssert bl_pm_event_register(exitSleep, 0, 2, 1, callback,
  cast[pointer](12'u), enabled) == 0
doAssert bl_pm_state_run() == -1
doAssert pm_post_event(control, 0, nil) == 0
doAssert bl_pm_state_run() == 0 and calls == @[10'u]
doAssert pm_post_event(exitSleep, 0, nil) == 0 and calls[^1] == 12'u
doAssert pm_post_event(control, 1, nil) == 0
doAssert bl_pm_state_run() == -1 and calls[^1] == 11'u
let before = calls.len
doAssert pm_post_event(exitSleep, 0, nil) == 0 and calls.len == before
doAssert pm_post_event(control, 0, nil) == 0
doAssert bl_pm_state_run() == 0 and calls[^1] == 10'u
doAssert bl_pm_deinit() == 0
doAssert pm_post_event(control, 0, nil) == -1
doAssert bl_pm_state_run() == -1
doAssert bl_pm_deinit() == -1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pm_registration_capacity_is_bounded(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert bl_pm_init() == 0
for index in 0 ..< PmMaxNodes:
  doAssert bl_pm_event_register(control, index.uint32, 2, index.uint16,
    callback, cast[pointer](index.uint), enabled) == 0
doAssert pmNodeCount == PmMaxNodes
doAssert bl_pm_event_register(control, 99, 2, 0, callback, nil, enabled) == -1
doAssert pmNodeCount == PmMaxNodes
doAssert pm_post_event(cast[PmEvent](6), 0, nil) == -1
doAssert bl_pm_deinit() == 0
doAssert bl_pm_init() == 0 and pmNodeCount == 0
''')
