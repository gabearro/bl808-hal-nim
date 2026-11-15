"""Exercise traffic detector startup and TIM/confirmation timer contracts."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MACHW_TIMLO_REG = 0x24B00120'u
type
  Vif = object
    flags: uint32
    vifIdx, psFlags: uint8
var
  td_env: array[2, TdEntryView]
  params: array[5, uint32]
  ps: tuple[enabled, flags: uint8]
  vif: Vif
  now: uint32
  reads: int
  logging: bool
  slots: seq[int]
  messages: seq[string]
  schedules: seq[tuple[index: int, expiry: uint32]]
  clears: seq[int]
  onSchedule: proc(index: int)
  onPrint: proc()
proc blPsParamsView(): ptr BlPsParamsView = cast[ptr BlPsParamsView](addr params[0])
proc psEnvView(): ptr typeof(ps) = addr ps
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  inc reads
  now
proc timerIndex(timer: pointer): int =
  for i in 0 .. 1:
    if timer == addr td_env[i]: return i
  raiseAssert "timer outside TD environment"
proc mm_timer_set(timer: pointer; expiry: uint32) =
  let index = timerIndex(timer)
  schedules.add((index, expiry))
  if onSchedule != nil: onSchedule(index)
proc mm_timer_clear(timer: pointer) = clears.add(timerIndex(timer))
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0 and length == sizeof(TdEntryView).csize_t
  zeroMem(p, length.int)
  p
proc td_timer_end(p: pointer) {.cdecl.} = discard

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc printMessage(format: cstring) {.cdecl, varargs.} =
  doAssert format != nil
  var output: array[96, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  if onPrint != nil: onPrint()
proc blOpsFunc(slot: int): pointer =
  slots.add(slot)
  if slot == 4 and logging: cast[pointer](printMessage) else: nil
proc getLogFunc(slot: int): pointer = blOpsFunc(slot)
proc setup() =
  td_env = default(typeof(td_env))
  params = [1000'u32, 40'u32, 2'u32, 6'u32, 10000'u32]
  now = 0xFFFFFFF0'u32
  reads = 0
  logging = false
  slots.setLen(0)
  messages.setLen(0)
  schedules.setLen(0)
  clears.setLen(0)
  onSchedule = nil
  onPrint = nil
  ps = (1'u8, 0'u8)
  vif = Vif(vifIdx: 1, psFlags: 1, flags: 0x80000000'u32)
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TdEntryView", "BlPsParamsView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    logger_type = (FW / "global_state/c_runtime.nim").read_text().split("# Helper:", 1)[0]
    td = (FW / "traffic_detection.nim").read_text()
    counters = procedure(layout, "clearTrafficCounters").split("\nstatic:", 1)[0]
    return (types + logger_type + PLATFORM + counters
            + "\n".join(procedure(td, name) for name in [
                "tdEntryForVif", "td_reset", "td_init", "td_start",
                "td_set_tim_time", "td_pack_tim_ind", "td_cfm_set_timer"])
            + procedure((FW / "power_save.nim").read_text(), "ps_check_tbtt"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_start_uses_default_period_and_preserves_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in 0 .. 1:
  for enabled in [false, true]:
    setup()
    logging = enabled
    td_env[index] = TdEntryView(period: 17, timTime: 19, rxCount: 2, txCount: 3,
      psRxCount: 4, psTxCount: 5, vifIdx: 99, prevFlags: 12, endActive: 1)
    var expected = td_env[index]
    expected.active = 1
    expected.timTime = 0
    td_start(index.uint8)
    doAssert td_env[index] == expected
    doAssert schedules == @[(index, now + params[0])] and reads == 1
    doAssert slots == @[4]
    doAssert messages == (if enabled: @["td_start idx=" & $index & "\r\n"] else: @[])
    td_start(index.uint8)
    doAssert td_env[index] == expected and schedules.len == 1 and reads == 1
    doAssert slots == @[4]

setup()
logging = true
let originalTime = now
onPrint = proc() =
  now = 2000
  params[0] = 3000
td_start(0)
doAssert schedules == @[(0, originalTime + 3000)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tim_immediate_schedule_and_followup_period(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in 0 .. 1:
  for active in [0'u8, 1]:
    for oldPeriod in [0'u32, 17, 0xFFFFFFFF'u32]:
      for override in [0'u32, 19, 0xFFFFFFFF'u32]:
        setup()
        td_env[index].active = active
        td_env[index].period = oldPeriod
        td_set_tim_time(index.uint8, override)
        td_pack_tim_ind(index.uint8)
        if active != 0:
          doAssert schedules == @[(index, now)] and reads == 1
          doAssert td_env[index].period == (if override == 0: params[1] else: override)
        else:
          doAssert schedules.len == 0 and reads == 0
          doAssert td_env[index].period == oldPeriod
        doAssert td_env[index].timTime == override
        doAssert slots.len == 0

setup()
td_env[0].active = 1
td_env[0].period = 11
onSchedule = proc(index: int) =
  doAssert index == 0
  td_env[0].timTime = 77
td_pack_tim_ind(0)
doAssert schedules == @[(0, now)] and td_env[0].period == 77
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_confirmation_consumes_saved_period(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for index in 0 .. 1:
  for status in [0'u32, 1, 0x80000000'u32]:
    for period in [0'u32, 40, 0xFFFFFFFF'u32]:
      setup()
      td_env[index].period = period
      td_env[index].timTime = 71
      td_cfm_set_timer(index.uint8, status)
      doAssert td_env[index].period == 0 and td_env[index].timTime == 71
      doAssert schedules == (if status != 0: @[(index, now + period)] else: @[])
      doAssert reads == (status != 0).int
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_and_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for active in [0'u8, 1]:
  setup()
  logging = true
  for i in 0 .. 1:
    td_env[i] = TdEntryView(active: active, rxCount: 3, period: 19, prevFlags: 12)
  td_init()
  for i in 0 .. 1:
    let expected = TdEntryView(callback: cast[pointer](td_timer_end),
      env: cast[uint32](cast[uint](addr td_env[i])), vifIdx: i.uint8)
    doAssert td_env[i] == expected
  doAssert clears == (if active != 0: @[0, 1] else: @[])
  doAssert messages == @["td_init\r\n", "td_reset idx=0\r\n", "td_reset idx=1\r\n"]
  doAssert slots == @[4, 4, 4] and schedules.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tbtt_uses_real_tim_timer_path(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [0'u8, 1]:
  for awake in [false, true]:
    for psEnabled in [0'u8, 1]:
      setup()
      ps.enabled = enabled
      ps.flags = if awake: 8 else: 0
      vif.psFlags = psEnabled
      td_env[1].active = 1
      td_env[1].period = 999
      let invoked = enabled != 0 and not awake and psEnabled != 0
      ps_check_tbtt(addr vif)
      doAssert schedules == (if invoked: @[(1, now)] else: @[])
      doAssert td_env[1].period == (if invoked: params[1] else: 999'u32)
      doAssert vif.flags == (if invoked: 0x80000040'u32 else: 0x80000000'u32)
''')
