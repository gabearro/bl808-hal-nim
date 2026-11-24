"""Exercise support timing with volatile-register and delay-loop models.

The native fixture uses the target's 32-bit long ABI. No real delay, polling
backend or hardware access runs in these tests.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


SUPPORT = FW.parent / "support"


def source(timing: str | None = None, events: str | None = None,
           memory: str | None = None) -> str:
    timing = timing if timing is not None else (SUPPORT / "delay_parts/mtime.nim").read_text()
    events = events if events is not None else (SUPPORT / "os_adapter_parts/events_tasks.nim").read_text()
    memory = memory if memory is not None else (SUPPORT / "os_adapter_parts/memory_timeouts.nim").read_text()
    code = r'''
type clong = int32
const MtimeBase = 0x100'u
var
  clock, advance, pollAdvance, rawLoops: uint64
  clockMode, rawMode, reads, rawCalls, polls, saves, restores: int
  maxReads = 10000000
  maxRawCalls = 1000000
  maxPolls = 1000000
  highRead: uint32
  script: seq[uint32]
  interrupts = true
  incoming = true
  requireCriticalReads = false
proc osEnterCritical(): uint32 =
  inc saves
  result = interrupts.uint32 * 8
  interrupts = false
proc osExitCritical(saved: uint32) =
  inc restores
  interrupts = (saved and 8) != 0
proc regRead32(address: uint): uint32 =
  doAssert address in [MtimeBase, MtimeBase + 4]
  inc reads
  doAssert reads <= maxReads, "counter sampling did not terminate"
  if requireCriticalReads: doAssert not interrupts
  if script.len != 0:
    result = script[0]
    script.delete(0)
  elif clockMode == 1:
    if address == MtimeBase + 4:
      inc highRead
      result = highRead
    else: result = 0
  elif address == MtimeBase + 4: result = (clock shr 32).uint32
  else: result = (clock and 0xFFFFFFFF'u64).uint32
proc rawDelay(loops: uint32) =
  doAssert interrupts == incoming
  inc rawCalls
  doAssert rawCalls <= maxRawCalls, "delay did not terminate"
  rawLoops += loops.uint64
  if rawMode == 1: clock = 1000 + (rawCalls and 1).uint64
  else: clock += advance
proc vendorPollOnce() =
  doAssert interrupts == incoming
  inc polls
  doAssert polls <= maxPolls, "adapter sleep did not terminate"
  clock += pollAdvance
'''
    code += (SUPPORT / "delay_parts/debug_state.nim").read_text() + timing
    for name in ["osSleepUs", "osMsleep", "osSleep"]:
        if f"proc {name}(" in events:
            code += procedure(events, name)
    code += procedure(memory, "osGetTimeMs") + procedure(memory, "osGetTick")
    return code


CASES = {
    "coherent_rollover": r'''
script = @[0'u32, 0xFFFFFFFF'u32, 1, 1, 0, 1]
doAssert readMtimeUs() == 0x100000000'u64
doAssert reads == 6
''',
    "unstable_read_fallback": r'''
clockMode = 1
maxReads = 100
delayMtimeUs(7)
doAssert reads <= 24 and rawLoops == 7'u64 * 96 + 2048
doAssert nimWifiDbgDelayFallbacks == 1
''',
    "cached_coherent_timestamp": r'''
requireCriticalReads = true
clock = 0x123456789ABC'u64
doAssert readMtimeUs() == clock
clockMode = 1
maxReads = 100
doAssert readMtimeUs() == clock
doAssert reads <= 27 and saves == 2 and restores == 2 and interrupts
''',
    "normal_delay_and_wrap": r'''
for enabled in [false, true]:
  incoming = enabled
  interrupts = enabled
  for start in [1000'u64, 0xFFFFFFF0'u64, high(uint64) - 7]:
    clock = start
    advance = 3
    let beforeCalls = rawCalls
    delayMtimeUs(10)
    doAssert rawCalls == beforeCalls + 4
    doAssert clock - start == 12 and nimWifiDbgDelayFallbacks == 0
    doAssert interrupts == enabled
''',
    "zero_delay": r'''
maxReads = 0
clockMode = 1
nimWifiDbgDelayLastStale = 999
delayMtimeUs(0)
doAssert reads == 0 and rawCalls == 0 and nimWifiDbgDelayFallbacks == 0
doAssert nimWifiDbgDelayLastStale == 0
''',
    "stalled_delay_full_budget": r'''
for us in [1'u32, 100, 44739222, high(uint32)]:
  clock = 1000
  advance = 0
  let beforeLoops = rawLoops
  delayMtimeUs(us)
  doAssert rawLoops - beforeLoops == 1025'u64 * 32 + us.uint64 * 96 + 2048
doAssert nimWifiDbgDelayFallbacks == 4
''',
    "jitter_total_cap": r'''
clock = 1000
rawMode = 1
let us = 0x40000000'u32
delayMtimeUs(us)
let budget = us.uint64 * 96 + 2048
doAssert rawLoops == 262144'u64 * 32 + budget
doAssert nimWifiDbgDelayFallbacks == 1
doAssert rawCalls == 262144 + int((budget + high(uint32).uint64 - 1) div high(uint32).uint64)
''',
    "sleep_stalled_clock": r'''
maxPolls = 16
advance = 0
doAssert osMsleep(1) == 1
doAssert polls == 10
doAssert nimWifiDbgDelayFallbacks == 10
''',
    "sleep_large_and_rollover": r'''
for enabled in [false, true]:
  incoming = enabled
  interrupts = enabled
  for start in [1000'u64, high(uint64) - 7]:
    for seconds in [1.cuint, 2147484.cuint, high(cuint)]:
      clock = start
      advance = 100
      pollAdvance = seconds.uint64 * 1000000'u64
      polls = 0
      maxPolls = 2
      doAssert osSleep(seconds) == 1 and polls == 1
      doAssert interrupts == enabled
''',
    "sleep_nonpositive": r'''
maxReads = 0
doAssert osMsleep(0) == 1 and osMsleep(-1) == 1
doAssert osSleep(0) == 1
doAssert reads == 0 and polls == 0 and rawCalls == 0
''',
    "tick_wrap": r'''
for milliseconds in [0'u64, 1234, 0xFFFFFFFF'u64, 0x100000000'u64, 0x100000123'u64]:
  clock = milliseconds * 1000
  doAssert osGetTimeMs() == milliseconds
  doAssert osGetTick() == (milliseconds and 0xFFFFFFFF'u64).uint32
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_support_timing(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
