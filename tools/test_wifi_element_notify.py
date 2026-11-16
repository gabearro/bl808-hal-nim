"""Exercise the configuration notifier's typed log ABI and zero return."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    runtime = (FW / "global_state/c_runtime.nim").read_text()
    return (runtime.split("# Helper:", 1)[0]
            + layouts("CfgApiElementEntryView") + r'''
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
var
  slots: seq[int]
  messages: seq[string]
  enabled = true
  throws = false
  onLog: proc()
proc logHook(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs, raises: [Exception].} =
  doAssert level == 1 and tag == nil
  doAssert $file == "mm.c" and line == 1826, "notification source metadata"
  doAssert $format == "[MM] %s is notfied, with ops %d\r\n", "notification format"
  var output: array[160, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count >= 0 and count < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  if onLog != nil: onLog()
  if throws: raise newException(ValueError, "notification log stopped")
proc blOpsFunc(slot: int): pointer =
  slots.add(slot)
  doAssert slot == 204
  if enabled: cast[pointer](logHook) else: nil
proc cfgApiElementEntryAt(p: pointer): ptr CfgApiElementEntryView =
  cast[ptr CfgApiElementEntryView](p)
''' + procedure(runtime, "getLogFunc")
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "element_notify") + r'''
type NotifyFn = proc(entry, arg1, arg2: pointer; operation: uint8): cint {.cdecl.}
proc notify(entry, arg1, arg2: pointer; operation: uint8): cint =
  let callback = cast[NotifyFn](cast[pointer](element_notify))
  callback(entry, arg1, arg2, operation)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_element_notification_metadata_and_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var value = 0xAABBCCDD'u32
var entry = CfgApiElementEntryView(name: cast[pointer](cstring("Keep Alive Frame Counter")),
  id: 0x87654321'u32, subId: 7, typeId: 7, valueStorage: addr value)
let original = entry
for operation in [0'u8, 1, 2, 3, 4, 127, 128, 255]:
  doAssert notify(addr entry, cast[pointer](1), cast[pointer](2), operation) == 0
  doAssert messages[^1] == "[MM] Keep Alive Frame Counter is notfied, with ops " & $operation & "\r\n"
  doAssert entry == original and value == 0xAABBCCDD'u32
doAssert slots == @[204, 204, 204, 204, 204, 204, 204, 204]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_element_notification_absent_and_raising_log(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var entry = CfgApiElementEntryView(name: cast[pointer](cstring("counter")))
enabled = false
doAssert notify(addr entry, nil, nil, 0) == 0 and messages.len == 0
enabled = true
throws = true
var raised = false
try: discard notify(addr entry, nil, nil, 4)
except ValueError: raised = true
doAssert raised and messages == @["[MM] counter is notfied, with ops 4\r\n"]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_element_notification_does_not_reuse_entry_after_log(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var entry = CfgApiElementEntryView(name: cast[pointer](cstring("original")))
onLog = proc() = entry = default(CfgApiElementEntryView)
doAssert notify(addr entry, nil, nil, 3) == 0
doAssert messages == @["[MM] original is notfied, with ops 3\r\n"]
doAssert entry == default(CfgApiElementEntryView)
''')
