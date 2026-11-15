"""Check MAC timing initialization and propagation of fatal preconditions."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_init_failure import mac_source
from test_wifi_message_allocation import run_program


def source() -> str:
    code = mac_source()
    code = code.replace(procedure(code, "assert_err"), r'''
var
  assertionLines: seq[cint]
  onAssert: proc()
  writesAtAssertion: int
  callsAtAssertion: seq[string]
  antennaCount: uint8
proc assert_err(condition, file: cstring; line: cint) =
  inc diagnostics
  assertionLines.add(line)
  writesAtAssertion = writes.len
  callsAtAssertion = calls
  if onAssert != nil: onAssert()
''', 1)
    code = code.replace(procedure(code, "phy_get_ntx"), r'''
proc phy_get_ntx(): uint8 =
  calls.add("chains")
  antennaCount
''', 1)
    return code + r'''
const failureLines = [0x1D59.cint, 0x1EA2, 0x228A, 0x22A4, 0x22BE, 351, 0x1539]
proc setupTiming() =
  setupMac(true)
  assertionLines.setLen(0)
  callsAtAssertion.setLen(0)
  writesAtAssertion = -1
  onAssert = nil
  antennaCount = 0
proc prepareFailure(which: int) =
  setupTiming()
  if which < 5: registers[MACHW_BASE + 0xE4] = 1
  case which
  of 0: registers[MACHW_BASE + 0xE4] = (26'u32 shl 8) or 1
  of 1: registers[MACHW_BASE + 0xEC] = 26'u32 shl 10
  of 2: registers[MACHW_BASE + 0x104] = 26'u32 shl 20
  of 3: registers[MACHW_BASE + 0x104] = 26'u32 shl 10
  of 4: registers[MACHW_BASE + 0x104] = 26
  of 5: registers[MACHW_BASE + 0xD8] = 0x0B000000'u32
  else: antennaCount = 7
'''


CASES = {
    "fault_stops": r'''
var continued: seq[int]
for which in 0 ..< failureLines.len:
  prepareFailure(which)
  let initialized = hal_machw_init()
  if initialized or assertionLines != @[failureLines[which]] or
      writes.len != writesAtAssertion or calls != callsAtAssertion:
    continued.add(which)
doAssert continued.len == 0, "continued after failed MAC preconditions: " & $continued
''',
    "fault_preserves_replacement": r'''
var continued: seq[int]
const watched = [0x4C'u, 0x9C, 0xD8, 0xE4, 0xE8, 0xEC, 0xF0, 0xF4, 0xF8, 0x104]
for which in 0 ..< failureLines.len:
  prepareFailure(which)
  onAssert = proc() =
    for offset in watched: registers[MACHW_BASE + offset] = 0xA5C31234'u32
    calls.setLen(0)
    pending = 0x81234567'u32
    tx.resetInProgress = 77
  let initialized = hal_machw_init()
  var unchanged = not initialized and writes.len == writesAtAssertion and
    calls.len == 0 and pending == 0x81234567'u32 and tx.resetInProgress == 77
  for offset in watched:
    unchanged = unchanged and registers[MACHW_BASE + offset] == 0xA5C31234'u32
  if not unchanged: continued.add(which)
doAssert continued.len == 0, "changed callback replacement: " & $continued
''',
    "caller_stops": r'''
var continued: seq[int]
for platform in [false, true]:
  for which in 0 ..< failureLines.len:
    prepareFailure(which)
    let initialized = if platform: bl_init() else: mm_init()
    if initialized or assertionLines != @[failureLines[which]] or
        writes.len != writesAtAssertion or calls != callsAtAssertion:
      continued.add(which)
doAssert continued.len == 0, "caller continued after failed MAC initialization: " & $continued
''',
    "valid_fields": r'''
for oldClock in [20'u32, 40, 80]:
  for seed in 0'u32 .. 20:
    setupTiming()
    antennaCount = (seed mod 7).uint8
    let limit = min(1023'u32, 1023 * oldClock div 40)
    let slot = seed * 67 mod (limit + 1)
    let ecMid = seed * 31 mod (limit + 1)
    let high = seed * 73 mod (limit + 1)
    let mid = seed * 47 mod (limit + 1)
    let low = seed * 53 mod (limit + 1)
    let e4 = 0xB0000000'u32 or (slot shl 8) or oldClock
    let e8 = 0xD50000A5'u32 or ((seed * 4095 mod 65536) shl 8)
    let ec = 0xC0000000'u32 or (ecMid shl 10) or 0x155
    let f0 = 0xA5341203'u32
    let f4 = 0x9600005A'u32 or ((seed * 3059 mod 65536) shl 8)
    let f8 = 0x87000043'u32 or ((seed * 2003 mod 65536) shl 8)
    let r104 = 0xC0000000'u32 or (high shl 20) or (mid shl 10) or low
    let r9c = 0xF1234567'u32
    registers[MACHW_BASE + 0xE4] = e4
    registers[MACHW_BASE + 0xE8] = e8
    registers[MACHW_BASE + 0xEC] = ec
    registers[MACHW_BASE + 0xF0] = f0
    registers[MACHW_BASE + 0xF4] = f4
    registers[MACHW_BASE + 0xF8] = f8
    registers[MACHW_BASE + 0x104] = r104
    registers[MACHW_BASE + 0x9C] = r9c
    doAssert hal_machw_init() and diagnostics == 0
    doAssert registers[MACHW_BASE + 0xE4] ==
      ((e4 and 0xF0000000'u32) or 0x02200000'u32 or ((slot * 40 div oldClock) shl 8) or 40)
    doAssert registers[MACHW_BASE + 0xEC] ==
      ((ec and 0xC0000000'u32) or 0x02700000'u32 or ((ecMid * 40 div oldClock) shl 10) or 180)
    for item in [(0xE8'u, e8), (0xF4'u, f4), (0xF8'u, f8)]:
      let scaled = ((((item[1] shr 8) and 0xFFFF) * 40 div oldClock) and 0xFFFF) shl 8
      doAssert registers[MACHW_BASE + item[0]] == ((item[1] and 0xFF0000FF'u32) or scaled)
    doAssert registers[MACHW_BASE + 0xF0] == ((f0 and not 3'u32) or 2)
    doAssert registers[MACHW_BASE + 0x104] ==
      (0xC0000000'u32 or ((high * 40 div oldClock) shl 20) or
       ((mid * 40 div oldClock) shl 10) or (low * 40 div oldClock))
    doAssert registers[MACHW_BASE + 0x9C] ==
      ((r9c and 0xE3FFFFFF'u32) or ((antennaCount.uint32 + 1) shl 26))
    doAssert calls == @["clock", "chains", "rf-baseline"]
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_mac_timing(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
