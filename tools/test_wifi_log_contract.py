"""Check SDK log/printf/puts routing and the direct diagnostic callers."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/strutils
const
  TASK_LAST_EMB = 8'u8
  TASK_RXU = 7'u8
type
  CoList = object
    first, last: pointer
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  slots: seq[int]
  messages, printed, putLines: seq[string]
  dumpedQueues: seq[pointer]
  states: seq[uint8]
  live: seq[pointer]
  allocated, freed: int
  failPrint, failLog, failAllocation: bool
  allowPrint, allowPuts, allowLog: bool
  failPutsAt: int
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc c_sprintf(p: pointer; format: cstring): cint
    {.importc: "sprintf", header: "<stdio.h>", varargs, discardable.}
proc c_strlen(p: pointer): csize_t {.importc: "strlen", header: "<string.h>".}

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logHook(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs, raises: [Exception].} =
  doAssert level == 2 and tag == nil and file == cstring("contract.c") and line == 17
  var output: array[256, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count >= 0 and count < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  if failLog: raise newException(ValueError, "log stopped")
proc printHook(format: cstring) {.cdecl, varargs, raises: [Exception].} =
  doAssert format != nil
  var output: array[256, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count >= 0 and count < output.len.cint
  printed.add($cast[cstring](addr output[0]))
  if failPrint: raise newException(ValueError, "print stopped")
proc putsHook(text: cstring) {.cdecl, raises: [Exception].} =
  doAssert text != nil
  putLines.add($text)
  if putLines.len == failPutsAt: raise newException(ValueError, "puts stopped")
proc allocHook(size: uint32): pointer {.cdecl.} =
  doAssert size == 128
  inc allocated
  if failAllocation: return nil
  result = malloc(size.csize_t)
  doAssert result != nil
  live.add(result)
proc platformFree(p: pointer) =
  doAssert p in live
  free(p)
  live.delete(live.find(p))
  inc freed
proc freeHook(p: pointer) {.cdecl.} = platformFree(p)
proc blOpsFunc(slot: int): pointer =
  slots.add(slot)
  case slot
  of 4:
    if allowPrint: cast[pointer](printHook) else: nil
  of 8:
    if allowPuts: cast[pointer](putsHook) else: nil
  of 184: cast[pointer](allocHook)
  of 188: cast[pointer](freeHook)
  of 204:
    if allowLog: cast[pointer](logHook) else: nil
  else: raiseAssert "unexpected operation slot"
proc bugkiller_fw_queue_dump(list: ptr CoList) =
  dumpedQueues.add(list)
proc ke_state_get(task: uint8): uint16 =
  states.add(task)
  task.uint16 + 100
proc cfgApiElementEntryAt(p: pointer): ptr CfgApiElementEntryView =
  cast[ptr CfgApiElementEntryView](p)
proc setup() =
  doAssert live.len == 0
  slots.setLen(0)
  messages.setLen(0)
  printed.setLen(0)
  putLines.setLen(0)
  dumpedQueues.setLen(0)
  states.setLen(0)
  allocated = 0
  freed = 0
  failPrint = false
  failLog = false
  failAllocation = false
  allowPrint = true
  allowPuts = true
  allowLog = true
  failPutsAt = -1
'''


def source() -> str:
    runtime = (FW / "global_state/c_runtime.nim").read_text()
    aliases = runtime.split("# Helper:", 1)[0]
    layout = (FW / "layout_types.nim").read_text()
    entry = re.search(
        r"(?ms)^  CfgApiElementEntryView\b.*?(?=^  \w|\Z)", layout
    )
    assert entry
    code = aliases + "\ntype\n" + entry.group(0) + PLATFORM
    code += procedure(runtime, "getLogFunc")
    diagnostics = (FW / "mac_config_debug.nim").read_text()
    for name in ["bugkiller_fw_queue_sent_dump", "bugkiller_fw_queue_saved_dump",
                 "bugkillerPutLine", "puts_space", "dump_ke_task", "bugkiller_fw_task_dump",
                 "cfg_api_element_general_set"]:
        if name == "dump_ke_task":
            # The first occurrence is the forward declaration.
            definition = diagnostics.index("proc dump_ke_task*")
            definition = diagnostics.index("proc dump_ke_task*", definition + 1)
            code += procedure(diagnostics[definition:], name)
        else:
            code += procedure(diagnostics, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_log_type_matches_the_five_fixed_argument_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
static:
  doAssert not compiles(getLogFunc(4))
  doAssert not compiles(getLogFunc(8))
  doAssert not compiles(getLogFunc(76))
  doAssert not compiles(getLogFunc(204)(2, nil, "contract.c", 17))

setup()
let typed: PlatformLogFunc = logHook
typed(2, nil, "contract.c", 17, "count=%u text=%s", 123.cuint, cstring("sample"))
doAssert messages == @["count=123 text=sample"]
let loaded = getLogFunc(204)
loaded(2, nil, "contract.c", 17, "%08x", 0xABCD.cuint)
doAssert messages[^1] == "0000abcd" and slots == @[204]
failLog = true
var raised = false
try: loaded(2, nil, "contract.c", 17, "stop")
except ValueError: raised = true
doAssert raised and messages[^1] == "stop"
allowLog = false
doAssert getLogFunc(204) == nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_configuration_update_uses_printf_before_the_write(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for typeId in 0'u16 .. 9'u16:
  for enabled in [false, true]:
    setup()
    allowPrint = enabled
    var storage = [0xA5A5A5A5'u32, 0xA5A5A5A5'u32, 0xA5A5A5A5'u32]
    var value = 0xFEDCAB34'u32
    var entry = CfgApiElementEntryView(typeId: typeId,
      name: cast[pointer](cstring("element")), valueStorage: addr storage[1])
    cfg_api_element_general_set(addr entry, addr value)
    let count = case typeId
      of 1, 2, 3: 1
      of 4, 5: 2
      of 6, 7: 4
      else: 0
    let bytes = cast[ptr UncheckedArray[uint8]](addr storage[0])
    let valueBytes = cast[ptr UncheckedArray[uint8]](addr value)
    for i in 0 ..< sizeof(storage):
      doAssert bytes[i] == (if i >= 4 and i < 4 + count: valueBytes[i - 4] else: 0xA5'u8)
    doAssert slots == @[4]
    doAssert messages.len == 0
    doAssert printed == (if enabled: @["  updating element: element\r\n"] else: @[])

setup()
var target = 0xA5A5A5A5'u32
var value = 1'u32
var entry = CfgApiElementEntryView(typeId: 7,
  name: cast[pointer](cstring("element")), valueStorage: addr target)
failPrint = true
var raised = false
try: cfg_api_element_general_set(addr entry, addr value)
except ValueError: raised = true
doAssert raised and target == 0xA5A5A5A5'u32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_queue_headers_use_printf_and_keep_the_queue_argument(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  setup()
  allowPrint = enabled
  bugkiller_fw_queue_sent_dump()
  bugkiller_fw_queue_saved_dump()
  doAssert slots == @[4, 4]
  doAssert dumpedQueues == @[cast[pointer](addr keMsgQueueSent), cast[pointer](addr keMsgQueueSaved)]
  doAssert printed == (if enabled:
    @["[BugKiller] WIFI QUEUE SENT\r\n", "[BugKiller] WIFI QUEUE SAVED\r\n"] else: @[])

setup()
failPrint = true
var raised = false
try: bugkiller_fw_queue_sent_dump()
except ValueError: raised = true
doAssert raised and dumpedQueues.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_task_dump_uses_puts_and_typed_task_state_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
bugkiller_fw_task_dump()
doAssert putLines[0 .. 1] == @["[BugKiller] WIFI TASK\r\n", "task_id   state     \r\n"]
doAssert states == @[0'u8, 1, 2, 3, 4, 5, 6, 8]
doAssert printed.len == 0 and messages.len == 0
doAssert allocated == 8 and freed == 8 and live.len == 0
for row, task in states:
  doAssert putLines[2 + row * 2] == ($task).alignLeft(10) & ($(task.uint16 + 100)).alignLeft(10)
  doAssert putLines[3 + row * 2] == "\r\n"

for failAt in 1 .. 2:
  setup()
  failPutsAt = failAt
  var raised = false
  try: bugkiller_fw_task_dump()
  except ValueError: raised = true
  doAssert raised and states.len == 0 and allocated == 0

setup()
failAllocation = true
bugkiller_fw_task_dump()
doAssert allocated == 8 and freed == 0 and live.len == 0
doAssert putLines.len == 2
''')
