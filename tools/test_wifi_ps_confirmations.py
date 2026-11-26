"""Exercise the power-save commits (ps_disable_cfm_handle, ps_enable_cfm_handle).

psFinish calls one of them at the end of every transition while the
transition's kind is still recorded (ps_machine.nim): ps_disable_cfm_handle
for a DPSM wake or an explicit PS off, ps_enable_cfm_handle for a DPSM sleep or
an explicit PS on. The kind, not ps_env+52 bits 0-2 and the VIF as in ps.o,
says which commit runs; psFinish has already cleared bits 1 and 2 and answers
the request itself. Nothing the commits call (timer clear and set, the PM
event, the traffic detector, the event bit, the logger) can run power-save
code, so they check nothing again.
"""

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
  PsKind = enum
    psIdle, psExplicit, psSleep, psWake
var
  ps: PsEnvView
  psOwn: tuple[kind: PsKind]
  vif: Vif
  ke: KePs
  events: seq[string]
  messages: seq[string]
  schedules: seq[uint32]
  clearCount, pmCalls, lookups: int
  tdValues: seq[uint32]
  useBackend, logging: bool
  pmResult: uint32
  macNow: uint32
proc psEnvView(): ptr PsEnvView = addr ps
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc keEnvPsFlags(): ptr KePs = addr ke
proc macTimeNow(): uint32 = macNow
proc mm_timer_clear(timer: pointer) =
  doAssert timer == psUapsdTimer()
  inc clearCount
  events.add("clear")
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == psUapsdTimer()
  schedules.add(expiry)
  events.add("timer")
proc td_cfm_set_timer(index: uint8; value: uint32) =
  doAssert index == vif.vifIdx
  tdValues.add(value)
  events.add("td")
proc ke_evt_set(bits: uint32) =
  doAssert bits == 0x100 and ke.flags == 0xA1 and ke.staPending == 1
  doAssert vif.keyPsState == 0
  events.add("event")
proc wifi_hosal_pm_post_event(event, code: uint32; p: pointer) =
  doAssert event == 4 and code == 0 and p != nil
  inc pmCalls
  events.add("pm")
  if useBackend:
    discard pm_post_event(event.cint, code, cast[ptr uint32](p))
  else:
    cast[ptr uint32](p)[] = pmResult

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
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc setup() =
  ps = PsEnvView(enabled: 1, mode: 4, uapsdTimerActive: 1, uapsdPeriod: 25)
  psOwn.kind = psIdle
  vif = Vif(vifIdx: 1, state: 1, uapsdBitmap: 8, flags: 0xFF,
            keyPsState: 0x12345678, psFlags: 1)
  ke = KePs(flags: 0xA0)
  events.setLen(0)
  messages.setLen(0)
  schedules.setLen(0)
  tdValues.setLen(0)
  clearCount = 0
  pmCalls = 0
  lookups = 0
  useBackend = true
  logging = false
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
def test_wake_commit_hands_the_pm_word_to_traffic_detection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for backend in [true, false]:
  for value in [0'u32, 1, 0x100, 0x80000001'u32, 0xFFFFFFFF'u32]:
    setup()
    psOwn.kind = psWake
    ps.flags = 1       # psFinish cleared bit 1
    useBackend = backend
    pmResult = value
    doAssert ps_disable_cfm_handle(addr vif) == 1
    doAssert clearCount == 1 and ps.uapsdTimerActive == 0
    doAssert ps.flags == 9 and ps.enabled == 1
    doAssert pmCalls == 1
    doAssert tdValues == @[(if backend: 0'u32 else: value and 0xFF)]
    doAssert vif.keyPsState == 0 and ke.flags == 0xA1 and ke.staPending == 1
    doAssert events == @["clear", "pm", "td", "event"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_enable_commit_timer_and_logging(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in [psSleep, psExplicit]:
  for hasVif in [false, true]:
    for active in [false, true]:
      for eligible in [false, true]:
        for hasLogger in [false, true]:
          setup()
          psOwn.kind = kind
          ps.flags = (if kind == psSleep: 9'u8 else: 0'u8)  # bit 2 cleared
          ps.enabled = (if kind == psSleep: 1'u8 else: 0'u8)
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
          doAssert ps.enabled == 1
          doAssert ps.flags == (if kind == psSleep: 1'u8 else: 0'u8)
          if hasVif:
            doAssert vif.keyPsState == 1
            var expectedFlags = 0xFF'u32
            if logExpected: expectedFlags = expectedFlags and not 8'u32
            if kind == psSleep: expectedFlags = expectedFlags and not 0x42'u32
            doAssert vif.flags == expectedFlags
          else:
            doAssert vif.keyPsState == 0x12345678 and vif.flags == 0xFF
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_disable_commit_by_kind(tmp_path: Path, mode: str) -> None:
    """A wake commits awake and hands traffic detection its TIM window; an
    explicit off turns PS off. ps.o tells them apart by ps_env+52 and the
    VIF, so its wake without a VIF turned PS off; here the kind decides."""
    run_program(tmp_path, mode, source() + r'''
for kind in [psWake, psExplicit]:
  for flags in [0'u8, 1]:
    for hasVif in [false, true]:
      for needsEvent in [false, true]:
        setup()
        psOwn.kind = kind
        ps.flags = flags
        vif.psFlags = needsEvent.uint8
        let waking = kind == psWake
        let result = ps_disable_cfm_handle(if hasVif: addr vif else: nil)
        doAssert result == (waking and hasVif).uint32
        doAssert ps.enabled == waking.uint8
        doAssert ps.flags == (if waking: flags or 8 else: flags)
        doAssert pmCalls == waking.int
        doAssert clearCount == 1 and ps.uapsdTimerActive == 0
        doAssert tdValues.len == (waking and hasVif).int
        if hasVif:
          doAssert vif.keyPsState == 0
        else:
          doAssert vif.keyPsState == 0x12345678
        doAssert ke.staPending == (hasVif and needsEvent).uint8
''')
