"""Exercise coexistence diagnostic fields and the real C logger ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/strutils
var
  rawValues, fieldValues: array[4, uint32]
  readCounts: array[4, int]
  messages: seq[tuple[line: cint, text: string]]
  events: seq[string]
  logging, useAlternate: bool
  primaryCalls, alternateCalls, lookups: int
  onLog: proc(line: cint)
proc readRegister(index: int): uint32 =
  inc readCounts[index]
  events.add("read:" & $index & ":" & $readCounts[index])
  case readCounts[index]
  of 1: rawValues[index]
  of 2: fieldValues[index]
  else: raiseAssert "unexpected extra register read"
proc ptaCoexControl(): uint32 = readRegister(0)
proc wlanCoexControl(): uint32 = readRegister(1)
proc wlanCoexPti(): uint32 = readRegister(2)
proc wlanCoexStatus(): uint32 = readRegister(3)
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc appendLog(line: cint; text: string) =
  messages.add((line, text))
  events.add("log:" & $line)
  if onLog != nil: onLog(line)
proc primaryLogger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  inc primaryCalls
  doAssert level == 2 and tag == nil and file == cstring("arch_main.c")
  doAssert format != nil
  var output: array[128, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  appendLog(line, $cast[cstring](addr output[0]))
proc alternateLogger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  inc alternateCalls
  doAssert level == 2 and tag == nil and file == cstring("arch_main.c")
  doAssert format != nil
  var output: array[128, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  appendLog(line, $cast[cstring](addr output[0]))
proc wrongNotify(task: pointer) {.cdecl.} =
  doAssert false, "coexistence dump called task-notify instead of log-write"
proc blOpsFunc(slot: int): pointer =
  inc lookups
  case slot
  of 204:
    if not logging: nil
    elif useAlternate: cast[pointer](alternateLogger)
    else: cast[pointer](primaryLogger)
  of 76: cast[pointer](wrongNotify)
  else: raiseAssert "unexpected platform callback slot"
proc getLogFunc(slot: int): pointer = blOpsFunc(slot)
proc setup() =
  rawValues = [0xF1234567'u32, 0x89ABCDEF'u32, 0x80000000'u32, 0xFFFFFFFF'u32]
  fieldValues = [0x55AA55AA'u32, 0xABCD1234'u32, 0xFEDCBA98'u32, 0x87654321'u32]
  readCounts = default(typeof(readCounts))
  messages.setLen(0)
  events.setLen(0)
  logging = true
  useAlternate = false
  primaryCalls = 0
  alternateCalls = 0
  lookups = 0
  onLog = nil
proc header(line: cint; kind: string) =
  messages.add((line, "=============    Coex " & kind & "==================\r\n"))
proc raw(line: cint; value: uint32) =
  messages.add((line, "value is " & toHex(value, 8).toLowerAscii & "\r\n"))
proc fields(firstLine: int; value: uint32;
            specs: openArray[tuple[name: string, shift: int, mask: uint32]]) =
  for offset, field in specs:
    messages.add(((firstLine + offset).cint,
      field.name & " is " & $((value shr field.shift) and field.mask) & "\r\n"))
proc expectedPta(rawValue, fieldValue: uint32): seq[tuple[line: cint, text: string]] =
  let saved = messages
  messages.setLen(0)
  header(400, "PTA: enable")
  raw(363, rawValue)
  fields(382, fieldValue, [
    ("abortrxwhentx", 20, 1'u32), ("swwlanrxabort", 19, 1'u32),
    ("swwlantxabort", 18, 1'u32), ("swbtrxabort", 17, 1'u32),
    ("swbttxabort", 16, 1'u32), ("chanmargin", 8, 63'u32),
    ("wlanptimode", 7, 1'u32), ("bteventmask", 6, 1'u32),
    ("chanenable", 5, 1'u32), ("ptienable", 4, 1'u32),
    ("nosimrx", 3, 1'u32), ("nosimtx", 2, 1'u32),
    ("basicpriority", 1, 1'u32), ("ptaenable", 0, 1'u32)])
  result = messages
  messages = saved
proc expectedWifi(rawValue, fieldValue: array[4, uint32]): seq[tuple[line: cint, text: string]] =
  let saved = messages
  messages.setLen(0)
  header(513, "WiFi: cntl")
  raw(421, rawValue[1])
  fields(439, fieldValue[1], [
    ("coexforcewlanpti", 28, 15'u32), ("coexforcewlanptitoggle", 27, 1'u32),
    ("coexforcewlanchanbw", 26, 1'u32), ("coexforcewlanrx", 25, 1'u32),
    ("coexforcewlantx", 24, 1'u32), ("coexwlanchanfreq", 16, 127'u32),
    ("coexwlanchanoffset", 12, 1'u32), ("coexautoptiadjincr", 6, 3'u32),
    ("coexautoptiadjenable", 5, 1'u32), ("coexforceenable", 4, 1'u32),
    ("coexpostponetxenable", 3, 1'u32), ("coexphyrxabortenable", 2, 1'u32),
    ("coexphytxabortenable", 1, 1'u32), ("coexenable", 0, 1'u32)])
  header(515, "WiFi: pti")
  raw(466, rawValue[2])
  fields(470, fieldValue[2], [
    ("coexptibcndata", 28, 15'u32), ("coexptibkdata", 24, 15'u32),
    ("coexptibedata", 20, 15'u32), ("coexptividata", 16, 15'u32),
    ("coexptivodata", 12, 15'u32), ("coexptimgt", 8, 15'u32),
    ("coexpticntl", 4, 15'u32), ("coexptiack", 0, 15'u32)])
  header(517, "WiFi: status")
  raw(490, rawValue[3])
  fields(502, fieldValue[3], [
    ("coexwlanptistate", 8, 15'u32), ("coexwlanptitogglestate", 5, 1'u32),
    ("coexwlanchanbwstate", 4, 1'u32), ("coexwlanrxstate", 3, 1'u32),
    ("coexwlantxstate", 2, 1'u32), ("coexwlanrxabortstate", 1, 1'u32),
    ("coexwlantxabortstate", 0, 1'u32)])
  result = messages
  messages = saved
'''


def source() -> str:
    text = (FW / "coex_intc_sysctrl.nim").read_text()
    helpers = text[:text.index("proc coex_dump_pta")]
    return (PLATFORM + helpers + procedure(text, "coex_dump_pta")
            + procedure(text, "coex_dump_wifi"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_fields_and_logger_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bit in -2 .. 31:
  setup()
  let value = if bit == -2: 0'u32
              elif bit == -1: high(uint32)
              else: 1'u32 shl bit
  fieldValues[0] = value
  let expected = expectedPta(rawValues[0], value)
  coex_dump_pta()
  doAssert messages == expected
  doAssert readCounts == [2, 0, 0, 0]
  doAssert lookups == 16 and primaryCalls == 16
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wifi_fields_and_logger_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bit in -2 .. 31:
  setup()
  let value = if bit == -2: 0'u32
              elif bit == -1: high(uint32)
              else: 1'u32 shl bit
  for index in 1 .. 3: fieldValues[index] = value
  let expected = expectedWifi(rawValues, fieldValues)
  coex_dump_wifi()
  doAssert messages == expected
  doAssert readCounts == [0, 2, 2, 2]
  doAssert lookups == 35 and primaryCalls == 35
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_register_reads_and_captured_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
let old = fieldValues
onLog = proc(line: cint) =
  if line == 400: rawValues[0] = 0x80000000'u32
  elif line == 363: fieldValues[0] = high(uint32)
  elif line == 382: fieldValues[0] = 0
coex_dump_pta()
doAssert messages == expectedPta(0x80000000'u32, high(uint32))
doAssert events[0 .. 5] == @["log:400", "read:0:1", "log:363", "read:0:2",
                           "log:382", "log:383"]
doAssert events[^1] == "log:395" and readCounts == [2, 0, 0, 0]

setup()
var expectedRaw = rawValues
var expectedFields = fieldValues
expectedRaw[1] = 0xFFFFFFFE'u32
expectedRaw[2] = 0x80000000'u32
expectedRaw[3] = 0x12345678'u32
expectedFields[1] = 0x87654321'u32
expectedFields[2] = 0xABCDEF12'u32
expectedFields[3] = 0x12345678'u32
let expected = expectedWifi(expectedRaw, expectedFields)
onLog = proc(line: cint) =
  case line
  of 513: rawValues[1] = expectedRaw[1]
  of 421: fieldValues[1] = expectedFields[1]
  of 439: fieldValues[1] = 0
  of 515: rawValues[2] = expectedRaw[2]
  of 466: fieldValues[2] = expectedFields[2]
  of 470: fieldValues[2] = 0
  of 517: rawValues[3] = expectedRaw[3]
  of 490: fieldValues[3] = expectedFields[3]
  of 502: fieldValues[3] = 0
  else: discard
coex_dump_wifi()
doAssert messages == expected and readCounts == [0, 2, 2, 2]
for i, marker in ["log:513", "read:1:1", "log:421", "read:1:2", "log:439"]:
  doAssert events[i] == marker
doAssert events[18 .. 22] == @["log:515", "read:2:1", "log:466", "read:2:2", "log:470"]
doAssert events[30 .. 34] == @["log:517", "read:3:1", "log:490", "read:3:2", "log:502"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_and_replaced_loggers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = false
coex_dump_pta()
coex_dump_wifi()
doAssert messages.len == 0 and lookups == 51
doAssert readCounts == [2, 2, 2, 2]

setup()
let expected = expectedPta(rawValues[0], fieldValues[0])
onLog = proc(line: cint) =
  if line == 400: useAlternate = true
coex_dump_pta()
doAssert messages == expected
doAssert primaryCalls == 1 and alternateCalls == 15

setup()
let expectedWifiLines = expectedWifi(rawValues, fieldValues)
onLog = proc(line: cint) =
  if line == 421: logging = false
coex_dump_wifi()
doAssert messages == expectedWifiLines[0 .. 1]
doAssert readCounts == [0, 2, 2, 2] and lookups == 35
''')
