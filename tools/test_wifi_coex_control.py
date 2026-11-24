"""Check PTI writes and PTA transition timing against the vendor object."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/strutils
var
  control: uint32
  writes: seq[uint32]
  reads: int
  onRead: proc(index: int)
  ticks: seq[uint32]
  tickIndex: int
  napDuration: uint32
  interrupts, incomingIrq, logging: bool
  steps: seq[string]
  messages: seq[tuple[line: cint, text: string]]
  expectedOldState: uint32
  onTick: proc(index: int)
  onRf: proc()
  primaryLoggerCalls, alternateLoggerCalls: int
  alternateLogging: bool
proc wlanCoexControl(): uint32 =
  inc reads
  if onRead != nil: onRead(reads)
  control
proc wlanCoexWriteControl(value: uint32) =
  control = value
  writes.add(value)
proc irqSave(): uint32 =
  steps.add("lock")
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) =
  interrupts = (saved and 8) != 0
  steps.add("restore")
proc bl_nap_calculate(): uint32 {.exportc, cdecl.} =
  doAssert not interrupts
  steps.add("nap")
  napDuration
proc wifi_hosal_rf_turn_on(argument: pointer): cint
    {.cdecl, discardable.} =
  doAssert argument == nil and interrupts == incomingIrq
  steps.add("rf-on")
  if onRf != nil: onRf()
  0
proc wifi_hosal_rf_turn_off(argument: pointer): cint
    {.cdecl, discardable.} =
  doAssert argument == nil and interrupts == incomingIrq
  steps.add("rf-off")
  0
# Keep the old emitted no-argument calls observable in baseline runs.
proc legacyRfOn() {.exportc: "wifi_hosal_rf_turn_on", cdecl.} =
  discard wifi_hosal_rf_turn_on(nil)
proc legacyRfOff() {.exportc: "wifi_hosal_rf_turn_off", cdecl.} =
  discard wifi_hosal_rf_turn_off(nil)
proc sleepMs(duration: clong): cint {.cdecl.} =
  doAssert interrupts == incomingIrq
  doAssert duration == (napDuration div 1000).clong
  steps.add("sleep:" & $duration)
  0
proc getTick(): uint32 {.cdecl.} =
  doAssert interrupts == incomingIrq
  doAssert tickIndex < ticks.len
  result = ticks[tickIndex]
  inc tickIndex
  steps.add("tick:" & $result)
  if onTick != nil: onTick(tickIndex)
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  inc primaryLoggerCalls
  doAssert level == 2 and tag == nil and file == cstring("arch_main.c")
  doAssert format != nil and interrupts == incomingIrq
  var output: array[96, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  messages.add((line, $cast[cstring](addr output[0])))
  steps.add("log:" & $line)
proc alternateLogger(level: uint32; tag, file: cstring; line: cint;
                     format: cstring) {.cdecl, varargs.} =
  inc alternateLoggerCalls
  doAssert level == 2 and tag == nil and file == cstring("arch_main.c")
  doAssert format == cstring("[COEX] Wi-Fi Usage %ldms\r\n") and line == 610
  var elapsed: clong
  {.emit: ["va_list args; va_start(args, ", format, "); ", elapsed,
    " = va_arg(args, long); va_end(args);"].}
  doAssert elapsed == 22
  steps.add("alternate-log")
proc blOpsFunc(slot: int): pointer =
  case slot
  of 28: cast[pointer](sleepMs)
  of 200: cast[pointer](getTick)
  of 204:
    if not logging: nil
    elif alternateLogging: cast[pointer](alternateLogger)
    else: cast[pointer](logger)
  else: raiseAssert "unexpected operation slot"
'''


def source() -> str:
    state = "\n".join((FW / path).read_text() for path in [
        "global_state/storage.nim", "dispatch_tables.nim"])
    declarations = []
    for name in ["coexPtaAutoControl", "coexPtaTimestamp",
                 "pds_slept_time", "pds_woken_time"]:
        matches = re.findall(rf"^\s*(?:var )?({name}\*[^\n]+)", state, re.M)
        assert len(matches) == 1, name
        declarations.append("  " + matches[0])
    text = (FW / "coex_intc_sysctrl.nim").read_text()
    return (PLATFORM + "\nvar\n" + "\n".join(declarations) + "\n"
            + procedure(text, "coex_wifi_pti_forece_enable")
            + procedure(text, "coex_wifi_pta_forece_enable") + r'''
proc setup(state: uint32; irq, enableLog: bool; times: seq[uint32]) =
  coexPtaAutoControl = state
  coexPtaTimestamp = 100
  pds_slept_time = 7
  pds_woken_time = 11
  expectedOldState = state
  ticks = times
  tickIndex = 0
  napDuration = 0
  interrupts = irq
  incomingIrq = irq
  logging = enableLog
  steps.setLen(0)
  messages.setLen(0)
  primaryLoggerCalls = 0
  alternateLoggerCalls = 0
  alternateLogging = false
  onTick = nil
  onRf = nil
proc checkFinished(state, timestamp: uint32) =
  doAssert coexPtaAutoControl == state and coexPtaTimestamp == timestamp
  doAssert tickIndex == ticks.len and interrupts == incomingIrq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pti_write_sequence(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enable in [false, true]:
  for initial in [0xA1234521'u32, 0xAD234531'u32]:
    control = initial
    reads = 0
    writes.setLen(0)
    onRead = nil
    coex_wifi_pti_forece_enable(enable)
    var base = initial
    var expected: seq[uint32]
    if enable:
      base = (base and 0x0FFFFFFF'u32) or 0xF0000000'u32
      expected.add(base)
      base = base or 0x10'u32
    else:
      base = base and not 0x10'u32
    expected.add(base)
    var final = base and not 0x04000000'u32
    if (base and 0x08000000'u32) == 0: final = final or 0x04000000'u32
    expected.add(final)
    doAssert writes == expected
    doAssert reads == (if enable: 4 else: 3)

  for sourceBit in [false, true]:
    control = 0x92345671'u32
    reads = 0
    writes.setLen(0)
    let sourceRead = if enable: 3 else: 2
    onRead = proc(index: int) =
      if index == sourceRead:
        if sourceBit: control = control or 0x08000000'u32
        else: control = control and not 0x08000000'u32
      elif index == sourceRead + 1:
        control = control xor 0x08000001'u32
    coex_wifi_pti_forece_enable(enable)
    let target = writes[^2] xor 1'u32
    doAssert (control and 1) == (target and 1)
    doAssert ((control and 0x04000000'u32) != 0) == not sourceBit
    doAssert ((control and 0x08000000'u32) != 0) == not sourceBit
onRead = nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pti_repeated_calls_still_write(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
control = 0x12345670'u32
for (enable, expectedWrites, expectedControl) in [
    (true, 3, 0xF6345670'u32),
    (true, 6, 0xF6345670'u32),
    (false, 8, 0xF6345660'u32),
    (false, 10, 0xF6345660'u32),
]:
  coex_wifi_pti_forece_enable(enable)
  doAssert writes.len == expectedWrites
  doAssert control == expectedControl
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_initial_noop_and_unknown_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert coexPtaAutoControl == high(uint32)
for irq in [false, true]:
  for enable in [false, true]:
    setup(high(uint32), irq, true, @[123'u32])
    coex_wifi_pta_forece_enable(enable)
    checkFinished(enable.uint32, 123)
    doAssert steps == @["log:614", "tick:123"]
    doAssert messages == @[(614.cint, "[COEX] Skip report for the first time\r\n")]
    doAssert pds_slept_time == 7 and pds_woken_time == 11

    setup(enable.uint32, irq, true, @[])
    coex_wifi_pta_forece_enable(enable)
    checkFinished(enable.uint32, 100)
    doAssert steps.len == 0 and messages.len == 0

    setup(2, irq, true, @[321'u32])
    coex_wifi_pta_forece_enable(enable)
    checkFinished(enable.uint32, 321)
    doAssert steps == @["tick:321"] and messages.len == 0
    doAssert pds_slept_time == 7 and pds_woken_time == 11
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_ble_accounting_and_wrap(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for enableLog in [false, true]:
    setup(0, irq, enableLog, @[120'u32, 122, 130])
    onTick = proc(index: int) =
      if index < 3: doAssert coexPtaAutoControl == expectedOldState
      else: doAssert coexPtaAutoControl == 1
    coex_wifi_pta_forece_enable(true)
    checkFinished(1, 130)
    doAssert pds_slept_time == 27 and pds_woken_time == 11
    doAssert steps == (if enableLog: @["tick:120", "tick:122", "log:588", "tick:130"]
                      else: @["tick:120", "tick:122", "tick:130"])
    if enableLog: doAssert messages == @[(588.cint, "[COEX] BLE Usage 22ms\r\n")]
    else: doAssert messages.len == 0

    setup(0, irq, enableLog, @[0x10'u32, 0x12, 0x20])
    coexPtaTimestamp = 0xFFFFFFF0'u32
    pds_slept_time = 0xFFFFFFF8'u32
    coex_wifi_pta_forece_enable(true)
    checkFinished(1, 0x20)
    doAssert pds_slept_time == 24 and pds_woken_time == 11
    if enableLog: doAssert messages == @[(588.cint, "[COEX] BLE Usage 34ms\r\n")]

setup(0, true, true, @[0xFFFFFFF0'u32, 0xFFFFFFF1'u32, 9])
coexPtaTimestamp = 0
coex_wifi_pta_forece_enable(true)
doAssert messages == @[(588.cint, "[COEX] BLE Usage -15ms\r\n")]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_wifi_nap_boundaries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for duration in [0'u32, 1000, 1001, 2000, high(uint32)]:
    for enableLog in [false, true]:
      setup(1, irq, enableLog, @[120'u32, 122, 130])
      napDuration = duration
      onRf = proc() = doAssert coexPtaAutoControl == 1
      coex_wifi_pta_forece_enable(false)
      checkFinished(0, 130)
      doAssert pds_slept_time == 7 and pds_woken_time == 31
      var expected = @["tick:120", "lock", "nap", "restore"]
      if duration > 1000:
        expected.add(@["rf-on", "sleep:" & $(duration div 1000), "rf-off"])
      expected.add("tick:122")
      if enableLog: expected.add("log:610")
      expected.add("tick:130")
      doAssert steps == expected
      if enableLog: doAssert messages == @[(610.cint, "[COEX] Wi-Fi Usage 22ms\r\n")]
      else: doAssert messages.len == 0

setup(1, false, true, @[0x10'u32, 0x12, 0x20])
coexPtaTimestamp = 0xFFFFFFF0'u32
pds_woken_time = 0xFFFFFFF8'u32
coex_wifi_pta_forece_enable(false)
checkFinished(0, 0x20)
doAssert pds_woken_time == 24 and pds_slept_time == 7
doAssert messages == @[(610.cint, "[COEX] Wi-Fi Usage 34ms\r\n")]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_logger_lookup_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0, true, true, @[120'u32, 122, 130])
logging = false
onTick = proc(index: int) =
  if index == 1: logging = true
  elif index == 2: logging = false
coex_wifi_pta_forece_enable(true)
checkFinished(1, 130)
doAssert primaryLoggerCalls == 1
doAssert messages == @[(588.cint, "[COEX] BLE Usage 22ms\r\n")]

setup(1, true, true, @[120'u32, 122, 130])
napDuration = 2000
onRf = proc() = alternateLogging = true
onTick = proc(index: int) =
  if index == 2: alternateLogging = false
coex_wifi_pta_forece_enable(false)
checkFinished(0, 130)
doAssert primaryLoggerCalls == 0 and alternateLoggerCalls == 1
doAssert steps == @["tick:120", "lock", "nap", "restore", "rf-on", "sleep:2",
                   "rf-off", "tick:122", "alternate-log", "tick:130"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_repeated_transition_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(high(uint32), false, false,
      @[100'u32, 110, 111, 112, 120, 121, 122])
coex_wifi_pta_forece_enable(false)
doAssert coexPtaAutoControl == 0 and coexPtaTimestamp == 100
coex_wifi_pta_forece_enable(false)
doAssert coexPtaAutoControl == 0 and coexPtaTimestamp == 100
coex_wifi_pta_forece_enable(true)
doAssert coexPtaAutoControl == 1 and coexPtaTimestamp == 112
doAssert pds_slept_time == 17 and pds_woken_time == 11
coex_wifi_pta_forece_enable(true)
doAssert coexPtaAutoControl == 1 and coexPtaTimestamp == 112
coex_wifi_pta_forece_enable(false)
checkFinished(0, 122)
doAssert pds_slept_time == 17 and pds_woken_time == 19
doAssert steps == @["tick:100", "tick:110", "tick:111", "tick:112",
                   "tick:120", "lock", "nap", "restore", "tick:121", "tick:122"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_hosal_imports_and_rf_event(tmp_path: Path, mode: str) -> None:
    declarations = (FW / "global_state/forward_decls_mac.nim").read_text()
    code = r'''
{.emit: """
#include <stdlib.h>
static int coex_test_on_count, coex_test_off_count;
int wifi_hosal_rf_turn_on(void *arg) {
  if (arg != NULL) abort();
  ++coex_test_on_count;
  return 17;
}
int wifi_hosal_rf_turn_off(void *arg) {
  if (arg != NULL) abort();
  ++coex_test_off_count;
  return -3;
}
int coex_test_on_calls(void) { return coex_test_on_count; }
int coex_test_off_calls(void) { return coex_test_off_count; }
""".}
proc onCalls(): cint {.importc: "coex_test_on_calls", cdecl.}
proc offCalls(): cint {.importc: "coex_test_off_calls", cdecl.}
'''
    for name in ["wifi_hosal_rf_turn_on", "wifi_hosal_rf_turn_off"]:
        code += re.search(rf"^proc {name}\*[^\n]+", declarations, re.M)[0] + "\n"
    code += procedure((FW / "power_save.nim").read_text(), "ble_rf_ops")
    run_program(tmp_path, mode, code + r'''
doAssert ble_rf_ops(0) == 0'u32
doAssert ble_rf_ops(1) == 0'u32
doAssert ble_rf_ops(42) == 0'u32
doAssert onCalls() == 2 and offCalls() == 1
doAssert wifi_hosal_rf_turn_on() == 17
doAssert wifi_hosal_rf_turn_off() == -3
wifi_hosal_rf_turn_on(nil)
wifi_hosal_rf_turn_off(nil)
doAssert onCalls() == 4 and offCalls() == 3
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_mode_return_value(tmp_path: Path, mode: str) -> None:
    code = r'''
var
  control: uint32
  clearCount, writeCount: int
proc ptaCoexClear() = inc clearCount
proc ptaCoexUpdateControl(mask, value: uint32) =
  control = (control and mask) or value
  inc writeCount
proc wlanCoexControl(): uint32 = control
proc wlanCoexWriteControl(value: uint32) =
  control = value
  inc writeCount
'''
    code += procedure((FW / "coex_intc_sysctrl.nim").read_text(),
                      "coex_pta_force_autocontrol_set")
    run_program(tmp_path, mode, code + r'''
for modeValue in [0'u32, 1, 2, 255]:
  control = high(uint32)
  clearCount = 0
  writeCount = 0
  doAssert coex_pta_force_autocontrol_set(modeValue) == 0'u32
  doAssert clearCount == 1
  doAssert writeCount == (if modeValue == 1 or modeValue == 2: 5 else: 9)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_mode_cross_register_transitions(tmp_path: Path, mode: str) -> None:
    code = r'''
var
  ptaControl = 0x55FA00E0'u32
  wlanControl = 0xA5000000'u32
  ptaWrites, wlanWrites: seq[uint32]
  clearCount: int
proc ptaCoexClear() = inc clearCount
proc ptaCoexUpdateControl(mask, value: uint32) =
  ptaControl = (ptaControl and mask) or value
  ptaWrites.add(ptaControl)
proc wlanCoexControl(): uint32 = wlanControl
proc wlanCoexWriteControl(value: uint32) =
  wlanControl = value
  wlanWrites.add(value)
'''
    code += procedure((FW / "coex_intc_sysctrl.nim").read_text(),
                      "coex_pta_force_autocontrol_set")
    run_program(tmp_path, mode, code + r'''
for modeValue in [0'u32, 0, 1, 1, 2, 2, 0, 3, high(uint32)]:
  let oldPta = ptaControl
  let oldWlan = wlanControl
  let oldClearCount = clearCount
  ptaWrites.setLen(0)
  wlanWrites.setLen(0)
  doAssert coex_pta_force_autocontrol_set(modeValue) == 0'u32
  doAssert clearCount == oldClearCount + 1
  if modeValue == 1 or modeValue == 2:
    let priority = if modeValue == 1: 0x00030000'u32 else: 0x000C0000'u32
    doAssert ptaControl == ((oldPta and not 0x000F0001'u32) or priority)
    doAssert ptaWrites.len == 5 and ptaWrites[^1] == ptaControl
    doAssert wlanWrites.len == 0 and wlanControl == oldWlan
  else:
    doAssert ptaControl == ((oldPta and not 0x000F0000'u32) or 0x13'u32)
    doAssert ptaWrites.len == 7 and ptaWrites[^1] == ptaControl
    doAssert wlanWrites == @[oldWlan and not 1'u32, oldWlan or 1'u32]
    doAssert wlanControl == (oldWlan or 1'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_restore_return_and_calls(tmp_path: Path, mode: str) -> None:
    code = r'''
var
  rfInitArgs: seq[uint32]
  coexCalls: int
proc rf_init(config: uint32) = rfInitArgs.add(config)
proc sm_set_channel_coex_connected() = inc coexCalls
'''
    code += procedure((FW / "power_save.nim").read_text(), "rfc_channel_ops")
    run_program(tmp_path, mode, code + r'''
doAssert rfc_channel_ops(0) == 0'u32
doAssert rfc_channel_ops(high(uint32)) == 0'u32
doAssert rfInitArgs == @[0x02625A00'u32, 0x02625A00'u32]
doAssert coexCalls == 2
''')
