"""Check the nineteen PM registrations and their callback ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


ADAPTERS = {
    "pmWaitMacIdle": "wait_mac_goto_idle",
    "pmSetMacDoze": "set_mac_to_doze",
    "pmWakePre": "wakeup_from_doze_pre",
    "pmWaitMacPrestate": "wait_mac_goto_prestate",
    "pmWakeDone": "wakeup_from_doze_done",
    "pmRecoverMac": "mac_recovery",
    "pmCheckForcedSleep": "pm_force_sleep_check",
    "pmSetCoexMode": "coex_pta_force_autocontrol_set",
    "pmRestoreChannel": "rfc_channel_ops",
    "pmBleRf": "ble_rf_ops",
}

PLATFORM = r'''
type
  Registration = tuple[event: cint, code, capability: uint32, priority: uint16,
                       callback, argument: pointer, enable: cint]
  PmCallback = proc(argument: pointer): cint {.cdecl.}
var
  registrations: seq[Registration]
  napSleepActive: uint8
  registrationResult: cint
  calls: seq[string]
  values: seq[uint32]
  resultCode: uint32
  doze = (dozeInProgress: 1'u32, unused: 0)
proc blDozeEnvView(): ptr typeof(doze) = addr doze
proc wait_mac_goto_idle(): uint32 {.cdecl.} =
  calls.add("idle")
  resultCode
proc set_mac_to_doze(): uint32 {.cdecl.} =
  calls.add("doze")
  resultCode
proc wakeup_from_doze_pre(): uint32 {.cdecl.} =
  calls.add("wake-pre")
  resultCode
proc wait_mac_goto_prestate(): uint32 {.cdecl.} =
  calls.add("prestate")
  resultCode
proc wakeup_from_doze_done(): uint32 {.cdecl.} =
  calls.add("wake-done")
  resultCode
proc mac_recovery(): uint32 {.cdecl.} =
  calls.add("recover")
  resultCode
proc pm_force_sleep_check(): bool {.cdecl.} =
  calls.add("check")
  resultCode != 0
proc coex_pta_force_autocontrol_set(mode: uint32): uint32 {.cdecl.} =
  calls.add("coex")
  values.add(mode)
  0'u32
proc rfc_channel_ops(channel: uint32): uint32 {.cdecl.} =
  calls.add("channel")
  values.add(channel)
  0'u32
proc wifi_hosal_rf_turn_on(argument: pointer = nil): cint {.cdecl, discardable.} =
  doAssert argument == nil
  calls.add("rf-on")
  17
proc wifi_hosal_rf_turn_off(argument: pointer = nil): cint {.cdecl, discardable.} =
  doAssert argument == nil
  calls.add("rf-off")
  -3
proc ble_rf_ops(enable: uint32): uint32 {.cdecl.} =
  calls.add("ble")
  values.add(enable)
  if enable == 0: wifi_hosal_rf_turn_off()
  else: wifi_hosal_rf_turn_on()
  0'u32
proc recordRegistration(event: cint; code, capability: uint32; priority: uint16;
                        callback, argument: pointer; enable: cint) =
  doAssert napSleepActive == 1
  registrations.add((event, code, capability, priority, callback, argument, enable))
proc reset() =
  registrations.setLen(0)
  calls.setLen(0)
  values.setLen(0)
  napSleepActive = 0
  resultCode = 0
  registrationResult = 0
'''


def source() -> str:
    text = (FW / "platform_bl.nim").read_text()
    code = PLATFORM
    if "type PmRegFn" in procedure(text, "bl_pm_ops_register"):
        # Match the old declaration for baseline mapping checks, not ABI validation.
        code += r'''
proc registrationShim(event, code, capability, priority: uint32;
                      callback: pointer; argument, enable: uint32)
    {.exportc: "wifi_hosal_pm_event_register", cdecl.} =
  recordRegistration(event.cint, code, capability, priority.uint16,
                     callback, cast[pointer](argument.uint), enable.cint)
'''
    else:
        code += r'''
proc registrationShim(event: cint; code, capability: uint32; priority: uint16;
                      callback, argument: pointer; enable: cint): cint
    {.exportc: "wifi_hosal_pm_event_register", cdecl.} =
  recordRegistration(event, code, capability, priority, callback, argument, enable)
  registrationResult
'''
    for adapter in ADAPTERS:
        if f"proc {adapter}(" in text:
            code += procedure(text, adapter)
    code += procedure(text, "bl_pm_ops_register")
    code += "\nproc callbackName(callback: pointer): string =\n"
    for adapter, operation in ADAPTERS.items():
        if f"proc {adapter}(" in text:
            code += f'  if callback == cast[pointer]({adapter}): return "{operation}"\n'
        code += f'  if callback == cast[pointer]({operation}): return "{operation}"\n'
    for operation in ("wifi_hosal_rf_turn_on", "wifi_hosal_rf_turn_off"):
        code += f'  if callback == cast[pointer]({operation}): return "{operation}"\n'
    code += '  raiseAssert "unknown callback"\n'
    return code + r'''
proc invoke(index: int): cint =
  let entry = registrations[index]
  cast[PmCallback](entry.callback)(entry.argument)
let expected = @[
  (1, 0, 2, 13, "wait_mac_goto_idle", 0, 1),
  (1, 1, 16, 20, "coex_pta_force_autocontrol_set", 2, 1),
  (1, 1, 4, 125, "set_mac_to_doze", 0, 1),
  (1, 1, 8, 150, "wifi_hosal_rf_turn_off", 0, 1),
  (2, 2, 16, 5, "coex_pta_force_autocontrol_set", 1, 1),
  (2, 2, 8, 10, "wifi_hosal_rf_turn_on", 0, 1),
  (2, 2, 8, 11, "rfc_channel_ops", 0, 1),
  (2, 2, 4, 34, "wakeup_from_doze_pre", 0, 1),
  (2, 2, 2, 36, "wait_mac_goto_prestate", 0, 1),
  (2, 2, 4, 140, "wakeup_from_doze_done", 0, 1),
  (2, 0, 2, 60, "mac_recovery", 0, 0),
  (4, 0, 32, 20, "pm_force_sleep_check", 0, 1),
  (4, 1, 2, 8, "wifi_hosal_rf_turn_on", 0, 0),
  (4, 1, 2, 18, "rfc_channel_ops", 0, 0),
  (3, 0, 4, 100, "wifi_hosal_rf_turn_on", 0, 0),
  (3, 0, 4, 123, "rfc_channel_ops", 0, 0),
  (0, 3, 16, 35, "coex_pta_force_autocontrol_set", 0, 1),
  (5, 0, 8, 10, "ble_rf_ops", 1, 1),
  (5, 1, 8, 20, "ble_rf_ops", 0, 1)]
proc checkTable() =
  doAssert registrations.len == expected.len
  for index, entry in registrations:
    let actual = (entry.event.int, entry.code.int, entry.capability.int,
                  entry.priority.int, callbackName(entry.callback),
                  cast[uint](entry.argument).int, entry.enable.int)
    doAssert actual == expected[index], "registration " & $index
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registration_order_callbacks_and_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
reset()
doAssert bl_pm_ops_register() == 0'u32
checkTable()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registered_callbacks_use_pm_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
reset()
doAssert bl_pm_ops_register() == 0'u32
checkTable()
for value in [0'u32, 7'u32, high(uint32)]:
  resultCode = value
  for index in [0, 2, 7, 8, 9, 10]:
    doAssert invoke(index) == cast[cint](value)
let wakeCalls = calls.len
doze.dozeInProgress = 0
doAssert invoke(7) == 0 and calls.len == wakeCalls
resultCode = 0
doAssert invoke(11) == 0
resultCode = 9
doAssert invoke(11) == 1
doAssert invoke(1) == 0
doAssert invoke(4) == 0
doAssert invoke(16) == 0
doAssert values == @[2'u32, 1'u32, 0'u32]
for index in [6, 13, 15]:
  doAssert invoke(index) == 0
doAssert values[^3 .. ^1] == @[0'u32, 0'u32, 0'u32]
calls.setLen(0)
doAssert invoke(3) == -3
for index in [5, 12, 14]: doAssert invoke(index) == 17
doAssert calls == @["rf-off", "rf-on", "rf-on", "rf-on"]
calls.setLen(0)
doAssert invoke(17) == 0
doAssert invoke(18) == 0
doAssert calls == @["ble", "rf-on", "ble", "rf-off"]
doAssert values[^2 .. ^1] == @[1'u32, 0'u32]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registration_keeps_vendor_sequence_after_provider_error(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
reset()
registrationResult = -1
doAssert bl_pm_ops_register() == 0'u32
checkTable()
registrations.setLen(0)
registrationResult = 3
doAssert bl_pm_ops_register() == 0'u32
checkTable()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nap_call_returns_zero(tmp_path: Path, mode: str) -> None:
    code = procedure((FW / "platform_bl.nim").read_text(), "bl_nap_call")
    run_program(tmp_path, mode, code + "\ndoAssert bl_nap_call() == 0'u32\n")
