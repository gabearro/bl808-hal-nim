"""Exercise power-save confirmation state and platform callback arguments."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MAX_VIFS = 2
type
  Vif = object
    flags, keyPsState: uint32
    vifIdx, state, uapsdBitmap, psFlags: uint8
  KePs = object
    flags, staPending: uint8
var
  ps: PsEnvView
  vif: Vif
  ke: KePs
  events: seq[string]
  modeRequests: seq[tuple[mode, requester, flags: uint8]]
  messages: seq[string]
  schedules: seq[uint32]
  clearCount, pmCalls, completions, lookups: int
  tdValues: seq[uint32]
  useBackend, logging: bool
  retireOnClear, retireOnComplete, resetOnComplete: bool
  retireOnPm, retireOnTd, retireOnEvent, retireOnTimer, retireOnLog: bool
  replaceModeOnLog, resetModeOnLog, deferModeOnLog, cancelModeOnLog: bool
  onWakeCallback: proc(stage: string)
  rxVifEpochs: array[MAX_VIFS, uint32]
  txResetEpoch: uint32
  psModeBuildSerial: uint32
  mmPsModeRequest: pointer
  pmResult: uint32
  macNow: uint32
proc psEnvView(): ptr PsEnvView = addr ps
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index == vif.vifIdx: addr vif else: nil
proc keEnvPsFlags(): ptr KePs = addr ke
proc macTimeNow(): uint32 = macNow
proc mm_timer_clear(timer: pointer) =
  doAssert timer == psUapsdTimer()
  inc clearCount
  events.add("clear")
  if retireOnClear:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  if onWakeCallback != nil: onWakeCallback("clear")
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == psUapsdTimer()
  schedules.add(expiry)
  events.add("timer")
  if retireOnTimer:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
proc mmPsModeComplete() =
  mmPsModeRequest = nil
  inc completions
  events.add("complete")
  if retireOnComplete:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  if resetOnComplete:
    inc txResetEpoch
proc ps_set_mode(mode, requester: uint8) =
  modeRequests.add((mode, requester, ps.flags))
  events.add("mode")
proc td_cfm_set_timer(index: uint8; value: uint32) =
  doAssert index == vif.vifIdx
  tdValues.add(value)
  events.add("td")
  if retireOnTd:
    inc rxVifEpochs[index]
    vif.flags = 0xDEADBEEF'u32
  if onWakeCallback != nil: onWakeCallback("td")
proc ke_evt_set(bits: uint32) =
  doAssert bits == 0x100 and ke.flags == 0xA1 and ke.staPending == 1
  doAssert vif.keyPsState == 0
  events.add("event")
  if retireOnEvent:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  if onWakeCallback != nil: onWakeCallback("event")
proc wifi_hosal_pm_post_event(event, code: uint32; p: pointer) =
  doAssert event == 4 and code == 0 and p != nil
  inc pmCalls
  events.add("pm")
  if useBackend:
    discard pm_post_event(event.cint, code, cast[ptr uint32](p))
  else:
    cast[ptr uint32](p)[] = pmResult
  if retireOnPm:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  if onWakeCallback != nil: onWakeCallback("pm")

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert line == 208 and format == cstring("enable cfm: UAPSD CLR\r\n")
  doAssert ps.uapsdTimerActive == 1 and schedules.len == 1
  doAssert (vif.flags and 8) != 0
  var output: array[64, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length == 23
  messages.add($cast[cstring](addr output[0]))
  events.add("log")
  if retireOnLog:
    inc rxVifEpochs[vif.vifIdx]
    vif.flags = 0xDEADBEEF'u32
  if replaceModeOnLog:
    inc psModeBuildSerial
  if resetModeOnLog:
    inc txResetEpoch
  if deferModeOnLog:
    mmPsModeRequest = addr ps
    ps.flags = ps.flags or 0x10
    ps.deferredMode = 2
    ps.mode = 6
  if cancelModeOnLog:
    mmPsModeRequest = nil
    ps.flags = ps.flags and not 0x10'u8
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc setup() =
  ps = PsEnvView(enabled: 1, mode: 4, uapsdTimerActive: 1, uapsdPeriod: 25)
  vif = Vif(vifIdx: 1, state: 1, uapsdBitmap: 8, flags: 0xFF,
            keyPsState: 0x12345678, psFlags: 1)
  ke = KePs(flags: 0xA0)
  events.setLen(0)
  modeRequests.setLen(0)
  messages.setLen(0)
  schedules.setLen(0)
  tdValues.setLen(0)
  clearCount = 0
  pmCalls = 0
  completions = 0
  lookups = 0
  useBackend = true
  logging = false
  retireOnClear = false
  retireOnComplete = false
  resetOnComplete = false
  retireOnPm = false
  retireOnTd = false
  retireOnEvent = false
  retireOnTimer = false
  retireOnLog = false
  replaceModeOnLog = false
  resetModeOnLog = false
  deferModeOnLog = false
  cancelModeOnLog = false
  onWakeCallback = nil
  rxVifEpochs = default(array[MAX_VIFS, uint32])
  txResetEpoch = 0
  psModeBuildSerial = 0
  mmPsModeRequest = nil
  pmResult = 0
  macNow = 0xFFFFFFF0'u32
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    ps_type = "type\n  PsEnvView" + layout.split("  PsEnvView", 1)[1].split(
        "\n\n  ", 1
    )[0] + "\n"
    timer = "template psUapsdTimer" + layout.split("template psUapsdTimer", 1)[1].split(
        "\ntemplate ", 1
    )[0]
    backend_source = (FW.parent / "support/runtime_facade_parts/power_management.nim").read_text()
    backend_prelude = backend_source.split("proc bl_pm_init", 1)[0]
    backend = procedure(backend_source, "pm_post_event")
    power = (FW / "power_save.nim").read_text()
    return (ps_type + "type PmEvent = cint\ntype PmCb = proc(arg: pointer): cint {.cdecl.}\n"
            + backend_prelude + backend
            + PLATFORM.replace("proc mm_timer_clear", timer + "\nproc mm_timer_clear")
            + procedure(power, "ps_disable_cfm_handle")
            + procedure(power, "ps_enable_cfm_handle"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_disable_confirmation_word_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for backend in [true, false]:
  for value in [0'u32, 1, 0x100, 0x80000001'u32, 0xFFFFFFFF'u32]:
    setup()
    ps.flags = 3
    useBackend = backend
    pmResult = value
    doAssert ps_disable_cfm_handle(addr vif) == 1
    doAssert clearCount == 1 and ps.uapsdTimerActive == 0
    doAssert ps.flags == 9 and ps.enabled == 1
    doAssert pmCalls == 1 and completions == 0
    doAssert tdValues == @[(if backend: 0'u32 else: value and 0xFF)]
    doAssert vif.keyPsState == 0 and ke.flags == 0xA1 and ke.staPending == 1
    doAssert events == @["clear", "pm", "td", "event"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_enable_confirmation_timer_and_logging(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for hasVif in [false, true]:
  for active in [false, true]:
    for eligible in [false, true]:
      for hasLogger in [false, true]:
        setup()
        ps.flags = 5
        ps.enabled = 0
        ps.psActive = active.uint8
        ps.uapsdTimerActive = 0
        logging = hasLogger
        vif.uapsdBitmap = eligible.uint8
        ps_enable_cfm_handle(if hasVif: addr vif else: nil)
        let timerExpected = hasVif and active
        let logExpected = timerExpected and eligible
        doAssert schedules == (if timerExpected: @[9'u32] else: @[])
        doAssert ps.uapsdTimerActive == timerExpected.uint8
        doAssert lookups == logExpected.int
        doAssert messages == (if logExpected and hasLogger:
          @["enable cfm: UAPSD CLR\r\n"] else: @[])
        if hasVif:
          doAssert ps.flags == 1 and ps.enabled == 0 and completions == 0
          doAssert vif.keyPsState == 1
          let expectedFlags = 0xBD'u32 and (if logExpected: not 8'u32 else: high(uint32))
          doAssert vif.flags == expectedFlags
        else:
          doAssert ps.flags == 5 and ps.enabled == 1 and completions == 1
          doAssert vif.keyPsState == 0x12345678
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_disable_confirmation_state_gates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for flags in [0'u8, 1, 2, 3, 5, 7, 9, 11]:
  for hasVif in [false, true]:
    for needsEvent in [false, true]:
      setup()
      ps.flags = flags
      vif.psFlags = needsEvent.uint8
      let dynamic = hasVif and (flags and 3) == 3
      let result = ps_disable_cfm_handle(if hasVif: addr vif else: nil)
      doAssert result == dynamic.uint32
      doAssert ps.enabled == dynamic.uint8
      doAssert ps.flags == (if dynamic: (flags and not 2'u8) or 8 else: flags)
      doAssert pmCalls == dynamic.int and completions == (not dynamic).int
      doAssert clearCount == 1 and ps.uapsdTimerActive == 0
      doAssert tdValues.len == dynamic.int
      if hasVif:
        doAssert vif.keyPsState == 0
      else:
        doAssert vif.keyPsState == 0x12345678
      doAssert ke.staPending == (hasVif and needsEvent).uint8
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_deferred_mode_keeps_requester(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enable in [false, true]:
  for hasVif in [false, true]:
    setup()
    ps.flags = 0x10
    ps.deferredMode = 2
    if enable: ps_enable_cfm_handle(if hasVif: addr vif else: nil)
    else: discard ps_disable_cfm_handle(if hasVif: addr vif else: nil)
    doAssert modeRequests == @[(2'u8, 4'u8, 0'u8)]
    doAssert events[^1] == "mode" and completions == 1
    doAssert ps.enabled == enable.uint8 and ps.flags == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_confirmation_callbacks_do_not_use_retired_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
ps.flags = 3
retireOnClear = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "pm"] and ps.uapsdTimerActive == 0
doAssert vif.keyPsState == 0x12345678 and vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 3
useBackend = false
retireOnPm = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "pm"]
doAssert tdValues.len == 0 and vif.keyPsState == 0x12345678
doAssert vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 3
useBackend = false
retireOnTd = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "pm", "td"]
doAssert vif.keyPsState == 0x12345678 and ke.staPending == 0
doAssert vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 3
useBackend = false
retireOnEvent = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "pm", "td", "event"]
doAssert vif.keyPsState == 0 and ke.staPending == 1
doAssert vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 0
retireOnComplete = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "complete"]
doAssert vif.keyPsState == 0x12345678 and vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 0x10
resetOnComplete = true
doAssert ps_disable_cfm_handle(nil) == 0
doAssert events == @["clear", "complete"] and modeRequests.len == 0

setup()
ps.flags = 5
ps.enabled = 0
ps.psActive = 1
ps.uapsdTimerActive = 0
retireOnTimer = true
ps_enable_cfm_handle(addr vif)
doAssert events == @["timer"]
doAssert ps.uapsdTimerActive == 0 and vif.keyPsState == 0x12345678
doAssert vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 5
ps.enabled = 0
ps.psActive = 1
ps.uapsdTimerActive = 0
logging = true
retireOnLog = true
ps_enable_cfm_handle(addr vif)
doAssert events == @["timer", "log"]
doAssert ps.uapsdTimerActive == 1 and vif.keyPsState == 0x12345678
doAssert vif.flags == 0xDEADBEEF'u32
doAssert completions == 0 and modeRequests.len == 0

setup()
ps.flags = 0
ps.psActive = 0
retireOnComplete = true
ps_enable_cfm_handle(addr vif)
doAssert events == @["complete"]
doAssert vif.keyPsState == 0x12345678 and vif.flags == 0xDEADBEEF'u32

setup()
ps.flags = 0x10
ps.psActive = 0
resetOnComplete = true
ps_enable_cfm_handle(nil)
doAssert events == @["complete"] and modeRequests.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retired_vif_does_not_strand_deferred_mode(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for callback in ["timer", "log", "replacement", "reset"]:
  setup()
  ps.flags = 0x1D
  ps.deferredMode = 0
  ps.psActive = 1
  ps.uapsdTimerActive = 0
  logging = true
  retireOnTimer = callback == "timer"
  retireOnLog = callback == "log"
  replaceModeOnLog = callback == "replacement"
  resetModeOnLog = callback == "reset"
  ps_enable_cfm_handle(addr vif)
  doAssert completions == 0 and vif.keyPsState == 0x12345678
  if retireOnTimer or retireOnLog:
    doAssert vif.flags == 0xDEADBEEF'u32
    doAssert events == (if retireOnTimer: @["timer", "mode"] else: @["timer", "log", "mode"])
    doAssert modeRequests == @[(0'u8, 4'u8, 1'u8)] and ps.flags == 1
  else:
    doAssert vif.flags == 0xFF and ps.flags == 0x1D
    doAssert events == @["timer", "log"] and modeRequests.len == 0

setup()
ps.flags = 5
ps.psActive = 1
ps.uapsdTimerActive = 0
logging = true
deferModeOnLog = true
ps_enable_cfm_handle(addr vif)
doAssert events == @["timer", "log", "mode"]
doAssert modeRequests == @[(2'u8, 6'u8, 1'u8)]
doAssert completions == 0 and mmPsModeRequest == addr ps

setup()
ps.flags = 0x15
ps.psActive = 1
ps.uapsdTimerActive = 0
mmPsModeRequest = addr ps
logging = true
cancelModeOnLog = true
ps_enable_cfm_handle(addr vif)
doAssert events == @["timer", "log"] and ps.flags == 1 and vif.keyPsState == 1
doAssert completions == 0 and modeRequests.len == 0 and mmPsModeRequest == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wake_completes_global_transition_without_retired_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for phase in ["clear", "pm", "td", "event"]:
  setup()
  ps.flags = 0x13
  ps.deferredMode = 2
  mmPsModeRequest = addr ps
  onWakeCallback = proc(stage: string) =
    if stage == phase:
      inc rxVifEpochs[vif.vifIdx]
      vif.flags = 0xDEADBEEF'u32
  doAssert ps_disable_cfm_handle(addr vif) == 0
  let expected = if phase in ["clear", "pm"]: @["clear", "pm", "mode"]
    elif phase == "td": @["clear", "pm", "td", "mode"]
    else: @["clear", "pm", "td", "event", "mode"]
  doAssert events == expected
  doAssert ps.uapsdTimerActive == 0 and ps.flags == 9
  doAssert modeRequests == @[(2'u8, 4'u8, 9'u8)] and completions == 0
  doAssert vif.flags == 0xDEADBEEF'u32
  doAssert vif.keyPsState == (if phase == "event": 0'u32 else: 0x12345678'u32)

for phase in ["clear", "pm", "td", "event"]:
  for reset in [false, true]:
    setup()
    ps.flags = 0x13
    onWakeCallback = proc(stage: string) =
      if stage == phase:
        if reset: inc txResetEpoch
        else: inc psModeBuildSerial
        ps.flags = 0xD5
        ps.uapsdTimerActive = 1
        vif.keyPsState = 0xABCDEF01'u32
    doAssert ps_disable_cfm_handle(addr vif) == 0
    doAssert events[^1] == phase and modeRequests.len == 0 and completions == 0
    doAssert ps.flags == 0xD5 and ps.uapsdTimerActive == 1 and vif.keyPsState == 0xABCDEF01'u32

setup()
ps.flags = 3
onWakeCallback = proc(stage: string) =
  if stage == "clear":
    mmPsModeRequest = addr ps
    ps.flags = ps.flags or 0x10
    ps.deferredMode = 2
    ps.mode = 6
doAssert ps_disable_cfm_handle(addr vif) == 1
doAssert events == @["clear", "pm", "td", "event", "mode"]
doAssert modeRequests == @[(2'u8, 6'u8, 9'u8)] and completions == 0

setup()
ps.flags = 0
mmPsModeRequest = addr ps
retireOnClear = true
doAssert ps_disable_cfm_handle(addr vif) == 0
doAssert events == @["clear", "complete"] and mmPsModeRequest == nil
doAssert ps.enabled == 0 and vif.keyPsState == 0x12345678

setup()
ps.flags = 0x13
mmPsModeRequest = addr ps
onWakeCallback = proc(stage: string) =
  if stage == "clear":
    mmPsModeRequest = nil
    ps.flags = ps.flags and not 0x10'u8
doAssert ps_disable_cfm_handle(addr vif) == 1
doAssert events == @["clear", "pm", "td", "event"] and ps.flags == 9
doAssert completions == 0 and modeRequests.len == 0 and mmPsModeRequest == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_explicit_enable_confirms_after_vif_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for phase in ["timer", "log", "reply"]:
  setup()
  ps.flags = 1
  ps.enabled = 0
  ps.psActive = 1
  ps.uapsdTimerActive = 0
  mmPsModeRequest = addr ps
  logging = true
  retireOnTimer = phase == "timer"
  retireOnLog = phase == "log"
  retireOnComplete = phase == "reply"
  ps_enable_cfm_handle(addr vif)
  doAssert completions == 1 and mmPsModeRequest == nil and ps.enabled == 1
  doAssert modeRequests.len == 0 and events[^1] == "complete"
  doAssert events == (if retireOnTimer: @["timer", "complete"] else: @["timer", "log", "complete"])
  doAssert vif.flags == 0xDEADBEEF'u32 and vif.keyPsState == 0x12345678'u32
''')
