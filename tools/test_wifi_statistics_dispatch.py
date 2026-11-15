"""Check statistics event dispatch, callback ABI, and diagnostic ordering."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
var
  events: uint32
  calls: seq[string]
  messages: seq[tuple[line: cint, text: string]]
  interruptsEnabled: bool
  loggerEnabled = true
  allocations, frees: int
  logAction: proc(line: cint)
  childAction: proc(name: string)
proc irqSave(): uint32 =
  calls.add("lock")
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) =
  calls.add("restore")
  interruptsEnabled = (saved and 8) != 0
proc ke_evt_set(mask: uint32) =
  doAssert mask == 64
  events = events or mask
  calls.add("set")
proc ke_evt_clear(mask: uint32) =
  doAssert mask == 64
  events = events and not mask
  calls.add("clear")
proc observe(name: string) =
  doAssert not interruptsEnabled
  calls.add(name)
  if childAction != nil: childAction(name)
proc bl_utils_dump() {.exportc, cdecl.} = observe("utils")
proc txl_frame_dump() = observe("frame")
proc ipc_emb_dump() = observe("ipc")
proc txl_cntrl_env_dump() = observe("tx")
proc txl_cfm_dump() = observe("confirm")
proc rxl_hwdesc_dump() = observe("rx-desc")
proc rxl_cntrl_dump() = observe("rx")
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("ke_event.c")
  doAssert not interruptsEnabled and cast[uint](format) > 4096
  var output: array[192, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  calls.add("log:" & $line)
  messages.add((line, $cast[cstring](addr output[0])))
  if logAction != nil: logAction(line)
proc allocate(size: uint32): pointer {.cdecl.} =
  inc allocations
  nil
template platformFree(p: pointer) = inc frees
proc blOpsFunc(offset: int): pointer =
  case offset
  of 204: (if loggerEnabled: cast[pointer](logger) else: nil)
  of 184: cast[pointer](allocate)
  else: raiseAssert "unexpected operation slot"
proc setup(irq: bool) =
  events = 0x140'u32
  calls.setLen(0)
  messages.setLen(0)
  allocations = 0
  frees = 0
  interruptsEnabled = irq
  loggerEnabled = true
  logAction = nil
  childAction = nil
let expectedMessages = @[
  (158.cint, "\r\n==========================FW STATISTIC DUMP S===================\r\n"),
  (175.cint, "==========================FW STATISTIC DUMP E===================\r\n")]
let expectedChildren = @["utils", "frame", "ipc", "tx", "confirm", "rx-desc", "rx"]
'''


CASES = {
    "logging": r'''
for irq in [false, true]:
  for enabled in [false, true]:
    setup(irq)
    loggerEnabled = enabled
    bl_fw_statistic_dump()
    var expected = @["clear", "lock"]
    if enabled: expected.add("log:158")
    expected.add(expectedChildren)
    if enabled: expected.add("log:175")
    expected.add("restore")
    doAssert calls == expected
    doAssert messages == (if enabled: expectedMessages else: @[])
    doAssert allocations == 0 and frees == 0
    doAssert events == 0x100 and interruptsEnabled == irq
''',
    "routing": r'''
for irq in [false, true]:
  setup(irq)
  loggerEnabled = false
  bl60x_fw_dump_statistic(0)
  doAssert calls == @["set"], "deferred request ran the dump immediately"
  doAssert events == 0x140 and interruptsEnabled == irq
  doAssert allocations == 0 and messages.len == 0
  bl60x_fw_dump_statistic(0)
  doAssert calls == @["set", "set"] and events == 0x140
  calls.setLen(0)
  bl_fw_statistic_dump()
  doAssert calls == @["clear", "lock"] & expectedChildren & @["restore"]
  doAssert events == 0x100
  for forced in [-1.cint, 1.cint, 99.cint]:
    setup(irq)
    bl60x_fw_dump_statistic(forced)
    doAssert calls[0] == "clear" and "set" notin calls
    doAssert messages == expectedMessages and events == 0x100
    doAssert allocations == 0 and interruptsEnabled == irq
''',
    "reschedule": r'''
for irq in [false, true]:
  setup(irq)
  logAction = proc(line: cint) =
    if line == 158: bl60x_fw_dump_statistic(0)
  bl_fw_statistic_dump()
  doAssert calls[0 .. 3] == @["clear", "lock", "log:158", "set"]
  doAssert events == 0x140, "new dump event was cleared by the executing dump"
  logAction = nil
  calls.setLen(0)
  bl_fw_statistic_dump()
  doAssert events == 0x100 and calls[0] == "clear"
  doAssert allocations == 0 and interruptsEnabled == irq
''',
    "logger_replacement": r'''
for irq in [false, true]:
  setup(irq)
  logAction = proc(line: cint) =
    if line == 158: loggerEnabled = false
  bl_fw_statistic_dump()
  doAssert messages == @[expectedMessages[0]]
  doAssert calls == @["clear", "lock", "log:158"] & expectedChildren & @["restore"]
  setup(irq)
  loggerEnabled = false
  childAction = proc(name: string) =
    if name == "frame": loggerEnabled = true
  bl_fw_statistic_dump()
  doAssert messages == @[expectedMessages[1]]
  doAssert calls == @["clear", "lock"] & expectedChildren & @["log:175", "restore"]
  doAssert allocations == 0 and interruptsEnabled == irq
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_statistics_dispatch(tmp_path: Path, mode: str, case: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + procedure(kernel, "bl_fw_statistic_dump")
    code += procedure(kernel, "bl60x_fw_dump_statistic")
    run_program(tmp_path, mode, code + CASES[case])
