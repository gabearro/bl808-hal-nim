"""Check the beacon log ABI, elapsed clock, and callback ownership."""

from pathlib import Path

import pytest

from test_wifi_beacon_owner import source as owner_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


LOGGING = r'''
type
  RecordedLog = tuple[target: int, text: string]
var
  selectedLogger: int
  recorded: seq[RecordedLog]
  failLogger: bool
  seenLogTimestamp: uint32
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc capture(target: int; level: uint32; tag, file: cstring; line: cint;
             format: cstring; text: string) =
  doAssert level == 1 and tag == nil and file == cstring("mm.c") and line == 272,
    "beacon log metadata does not match the platform ABI"
  doAssert format == cstring("bcn --> %ld\r\n"), "beacon log format is missing"
  recorded.add((target, text))
  seenLogTimestamp = mmLastBeaconLogTime
  boundary("log")
  if failLogger: raise newException(ValueError, "beacon log interrupted")
template defineLogger(name: untyped; target: static int) =
  proc name(level: uint32; tag, file: cstring; line: cint;
            format: cstring) {.cdecl, varargs.} =
    doAssert file == cstring("mm.c"), "beacon logger received the wrong fixed arguments"
    doAssert format != nil
    var output: array[96, char]
    var length: cint
    {.emit: ["va_list args; va_start(args, ", format, "); ", length,
      " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
      format, ", args); va_end(args);"].}
    doAssert length > 0 and length < output.len.cint
    capture(target, level, tag, file, line, format,
            $cast[cstring](addr output[0]))
defineLogger(loggerOne, 1)
defineLogger(loggerTwo, 2)
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 204
  case selectedLogger
  of 1: cast[pointer](loggerOne)
  of 2: cast[pointer](loggerTwo)
  else: nil
'''


def source() -> str:
    code = owner_source()
    code = code.replace(procedure(code, "beaconLog"), "")
    runtime = (FW / "global_state/c_runtime.nim").read_text()
    log_lookup = procedure(runtime, "getLogFunc")
    code = code.replace(procedure(code, "getLogFunc"), LOGGING + log_lookup)
    # The fixture also builds against the pre-fix function for regression proof.
    if "  mmLastBeaconLogTime: uint32\n" not in code:
        code = "var mmLastBeaconLogTime: uint32\n" + code
    return code + r'''
proc initialize() =
  prepare()
  mm.flagsHigh = 0
  selectedLogger = 1
  recorded.setLen(0)
  failLogger = false
  seenLogTimestamp = 0
  mmLastBeaconLogTime = 0
'''


CASES = {
    "clock_and_metadata": r'''
for sample in [(0'u32, 0'u32, 0), (0'u32, 1024'u32, 1),
               (1024'u32, 2047'u32, 0), (2048'u32, 1024'u32, -1),
               (0xFFFFFC00'u32, 1024'u32, 2),
               (0'u32, 0x80000000'u32, -2097152)]:
  initialize()
  let (previous, now, expected) = sample
  mmLastBeaconLogTime = previous
  clock = now
  process()
  doAssert recorded == @[(1, "bcn --> " & $expected & "\r\n")]
  doAssert seenLogTimestamp == now and mmLastBeaconLogTime == now
''',
    "logger_replacement": r'''
for initial in 0 .. 2:
  for replacement in 0 .. 2:
    initialize()
    selectedLogger = initial
    clock = 3072
    onBoundary = proc(name: string) =
      if name == "rssi": selectedLogger = replacement
    process()
    let expected = if replacement == 0: newSeq[RecordedLog]()
      else: @[(replacement, "bcn --> 3\r\n")]
    doAssert recorded == expected, "beacon used a logger captured before the RSSI callback"
    doAssert mmLastBeaconLogTime == 3072
''',
    "callback_failure_and_retirement": r'''
for retire in [false, true]:
  initialize()
  clock = 4096
  failLogger = not retire
  onBoundary = proc(name: string) =
    if name == "log" and retire: recycle()
  var raised = false
  try: process()
  except ValueError: raised = true
  doAssert raised == (not retire)
  doAssert recorded == @[(1, "bcn --> 4\r\n")]
  doAssert seenLogTimestamp == 4096 and mmLastBeaconLogTime == 4096
  doAssert steps == @["rssi", "log"], "beacon continued after its callback ended processing"
  if retire:
    doAssert timOut == 0 and vif.beaconCrc == 0xAABBCCDD'u32
    doAssert vif.tbttTimer.expiry == 0x55667788 and mm.keepAliveLimit == 77
''',
    "nested_clock_publication": r'''
initialize()
clock = 4096
var nested = false
onBoundary = proc(name: string) =
  if name == "log" and not nested:
    nested = true
    clock = 6144
    process()
process()
doAssert recorded == @[(1, "bcn --> 4\r\n"), (1, "bcn --> 2\r\n")]
doAssert mmLastBeaconLogTime == 6144, "outer beacon overwrote the nested clock publication"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_beacon_logging(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
