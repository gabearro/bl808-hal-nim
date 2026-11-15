"""Check U-APSD timeout, trigger selection, and timer restart behavior."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  VIF_TYPE_STA = 0'u8
  MACHW_TIMLO_REG = 0x24B00120'u
type
  Vif = object
    next: pointer
    flags, psLastTime: uint32
    vifType, state, uapsdBitmap, staIdx: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
var
  ps: PsEnvView
  vifs: array[3, Vif]
  vifEnv: VifEnv
  onChannel: array[3, bool]
  clocks: seq[uint32]
  clockIndex: int
  logging: bool
  lookups: int
  sendResult: uint8
  sends: seq[tuple[station: uint8, qos: uint16]]
  schedules: seq[uint32]
  messages: seq[string]
  events: seq[string]

proc psEnvView(): ptr PsEnvView = addr ps
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chan_is_on_channel(p: pointer): bool =
  for index in 0 ..< vifs.len:
    if p == addr vifs[index]:
      events.add("channel:" & $index)
      return onChannel[index]
  raiseAssert "unexpected VIF pointer"
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG and clockIndex < clocks.len
  result = clocks[clockIndex]
  inc clockIndex
  events.add("time:" & $result)
proc macTimeNow(): uint32 = regRead(MACHW_TIMLO_REG)
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == psUapsdTimer()
  schedules.add(expiry)
  events.add("schedule:" & $expiry)
proc txl_frame_send_qosnull_frame(station: uint8; qos: uint16;
                                 callback: pointer; arg: uint32): uint8 =
  doAssert callback == nil and arg == 0
  for vif in vifs:
    if vif.staIdx == station: doAssert (vif.flags and 8) != 0
  sends.add((station, qos))
  events.add("send:" & $station)
  sendResult

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert line == 567 and format == cstring("apsd timer: UAPSD\r\n")
  var output: array[64, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length == 19
  messages.add($cast[cstring](addr output[0]))
  events.add("log")
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc setup() =
  ps = PsEnvView(enabled: 1, uapsdTimerActive: 1, psActive: 1,
                 uapsdTimerState: 0xA5, uapsdPeriod: 20)
  vifs = default(typeof(vifs))
  for index in 0 ..< vifs.len:
    vifs[index] = Vif(state: 1, uapsdBitmap: 8, staIdx: (index + 1).uint8,
                      flags: 0x80000000'u32, psLastTime: 100)
  vifEnv.activeList.first = addr vifs[0]
  onChannel = [true, true, true]
  clocks.setLen(0)
  clockIndex = 0
  logging = false
  lookups = 0
  sendResult = 0
  sends.setLen(0)
  schedules.setLen(0)
  messages.setLen(0)
  events.setLen(0)
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    logger_type = (FW / "global_state/c_runtime.nim").read_text().split("# Helper:", 1)[0]
    ps_type = "type\n  PsEnvView" + layout.split("  PsEnvView", 1)[1].split(
        "\n\n  ", 1
    )[0] + "\n"
    timer = "template psUapsdTimer" + layout.split(
        "template psUapsdTimer", 1
    )[1].split("\ntemplate ", 1)[0]
    power = (FW / "power_save.nim").read_text()
    # The production view retains native pointers in host tests. M0 builds
    # separately enforce its 32-bit field offsets.
    return (ps_type + logger_type
            + PLATFORM.replace("proc mm_timer_set", timer + "\nproc mm_timer_set")
            + procedure(power, "ps_uapsd_set")
            + procedure(power, "ps_uapsd_timer_handle"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_expiry_boundaries_and_trigger_tid(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for last in [0'u32, 100, 0xFFFFFFF8'u32]:
  for period in [0'u32, 1, 20, 21]:
    for offset in [-1, 0, 1]:
      for status in [0'u8, 1]:
        setup()
        ps.uapsdPeriod = period
        vifs[0].psLastTime = last
        sendResult = status
        let deadline = last + period div 2
        let now = if offset < 0: deadline - 1 else: deadline + offset.uint32
        let due = offset == 1
        clocks = if due: @[now, now + 2, now + 5] else: @[now, now + 5]
        ps_uapsd_timer_handle()
        if due:
          doAssert sends == @[(1'u8, 7'u16)]
          doAssert vifs[0].flags == 0x80000008'u32
          doAssert vifs[0].psLastTime == now + 2
          doAssert lookups == 1
        else:
          doAssert sends.len == 0 and vifs[0].flags == 0x80000000'u32
          doAssert vifs[0].psLastTime == last and lookups == 0
        doAssert schedules == @[now + 5 + period]
        doAssert clockIndex == clocks.len
        doAssert ps.uapsdTimerActive == 1 and ps.uapsdTimerState == 0xA5
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_each_vif_uses_current_time(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
vifs[0].next = addr vifs[1]
vifs[0].psLastTime = 0
vifs[1].psLastTime = 12
clocks = @[11'u32, 20, 30, 40, 50]
ps_uapsd_timer_handle()
doAssert sends == @[(1'u8, 7'u16), (2'u8, 7'u16)]
doAssert vifs[0].psLastTime == 20 and vifs[1].psLastTime == 40
doAssert schedules == @[70'u32] and clockIndex == 5
doAssert events == @["channel:0", "time:11", "send:1", "time:20",
                      "channel:1", "time:30", "send:2", "time:40",
                      "time:50", "schedule:70"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_stopped_timer_can_restart(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for reason in 0 .. 4:
  setup()
  clocks = @[77'u32]
  case reason
  of 0: vifEnv.activeList.first = nil
  of 1: vifs[0].vifType = 2
  of 2: vifs[0].state = 0
  of 3: vifs[0].uapsdBitmap = 0
  of 4: onChannel[0] = false
  else: discard
  ps_uapsd_timer_handle()
  doAssert ps.uapsdTimerActive == 0 and ps.uapsdTimerState == 0xA5
  doAssert ps.psActive == 1 and schedules.len == 0
  doAssert clockIndex == 0 and sends.len == 0 and lookups == 0

  # Exercise the real re-arm guard in ps_uapsd_set after the timer stopped.
  clocks = @[200'u32]
  ps_uapsd_set(addr vifs[0], 3, 1)
  doAssert ps.uapsdTimerActive == 1 and ps.uapsdTimerState == 0xA5
  doAssert (vifs[0].uapsdBitmap and 8) != 0 and schedules == @[220'u32]
  ps_uapsd_set(addr vifs[0], 3, 1)
  doAssert schedules.len == 1 and clockIndex == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_logging_and_ineligible_vifs(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = true
clocks = @[111'u32, 123, 130]
ps_uapsd_timer_handle()
doAssert messages == @["apsd timer: UAPSD\r\n"]
doAssert events == @["channel:0", "time:111", "log", "send:1", "time:123",
                      "time:130", "schedule:150"]
doAssert sends == @[(1'u8, 7'u16)]

for gate in 0 .. 3:
  setup()
  vifs[0].next = addr vifs[1]
  case gate
  of 0: vifs[0].vifType = 2
  of 1: vifs[0].state = 0
  of 2: vifs[0].uapsdBitmap = 0
  of 3: onChannel[0] = false
  else: discard
  clocks = @[111'u32, 120, 130]
  ps_uapsd_timer_handle()
  doAssert sends == @[(2'u8, 7'u16)] and schedules == @[150'u32]
  doAssert vifs[0].psLastTime == 100 and vifs[0].flags == 0x80000000'u32
  doAssert clockIndex == 3 and ps.uapsdTimerActive == 1
''')
