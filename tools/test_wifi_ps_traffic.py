"""Exercise dynamic power-save decisions and real traffic-timer handoff."""

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
    next, chanCtxt: pointer
    vifIdx, vifType, state, staIdx, psNullRetry: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
  ChanEnv = object
    currentCtxt: pointer
var
  ps: PsEnvView
  params: BlPsParamsView
  vifs: array[2, Vif]
  vifEnv: VifEnv
  chanEnv: ChanEnv
  td_env: array[2, TdEntryView]
  cfgElements: array[2, uint32]
  updates: seq[uint32]
  updateCalls: seq[tuple[index: uint8, status: uint32, oldFlags: uint8]]
  updateResult, pmResult: uint32
  messages: seq[string]
  tdReads: seq[uint8]
  logging: bool
  lookups: int
  onLog: proc()
  powerControl, macNow: uint32
  sends: seq[tuple[sta: uint8, callback: pointer, arg: uint32]]
  schedules: seq[tuple[timer: pointer, expiry: uint32]]
  completions: seq[tuple[kind: string, vif: pointer, flags: uint8, pending: uint8]]
proc psEnvView(): ptr PsEnvView = addr ps
proc blPsParamsView(): ptr BlPsParamsView = addr params
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc chanEnvView(): ptr ChanEnv = addr chanEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc tdEntryForVif(index: uint8): ptr TdEntryView =
  tdReads.add(index)
  doAssert index < 2
  addr td_env[index]
template tdConfig(): ptr TdConfigView = cast[ptr TdConfigView](addr cfgElements[0])
template psTxNullTimer(): pointer = cast[pointer](addr ps.txNullTimerWord)
proc clearTrafficCounters(td: ptr TdEntryView) =
  td.rxCount = 0
  td.txCount = 0
  td.psRxCount = 0
  td.psTxCount = 0
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macNow
proc macTimeNow(): uint32 = regRead(MACHW_TIMLO_REG)
proc volatileLoad(p: ptr uint32): uint32 =
  doAssert cast[uint](p) == 0x24B0004C'u
  powerControl
proc volatileStore(p: ptr uint32; value: uint32) =
  doAssert cast[uint](p) == 0x24B0004C'u
  powerControl = value
proc chan_is_on_channel(p: pointer): bool = true
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  sends.add((sta, callback, arg))
  0
proc ps_enable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc ps_disable_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc ps_enable_cfm_handle(p: pointer) =
  completions.add(("enable", p, ps.flags, ps.pendingCount))
proc ps_disable_cfm_handle(p: pointer): uint32 =
  completions.add(("disable", p, ps.flags, ps.pendingCount))
  1
proc mm_timer_set(timer: pointer; expiry: uint32) = schedules.add((timer, expiry))
proc wifi_hosal_pm_post_event(event, value: uint32; p: pointer) =
  doAssert event == 4 and value == 0
  cast[ptr uint32](p)[] = pmResult

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil
  if line == 1187:
    doAssert file == cstring("ps.c") and format == cstring("%s:%d\r\n")
  else:
    doAssert line == 200 and file == cstring("td.c")
    doAssert format == cstring("Power Status %s:%s\r\n")
  var output: array[96, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  if onLog != nil: onLog()
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 204, "traffic status used the wrong platform callback"
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc getLogFunc(slot: int): PlatformLogFunc = cast[PlatformLogFunc](blOpsFunc(slot))
proc setup() =
  ps = PsEnvView(enabled: 1, flags: 1, statusFlags: 0xA0000000'u32)
  params = BlPsParamsView(trafficPeriod: 100, trafficThreshold: 1, txNullTimeout: 50)
  td_env = default(typeof(td_env))
  for index in 0 .. 1:
    vifs[index] = Vif(vifIdx: index.uint8, state: 1, staIdx: (index + 2).uint8)
    td_env[index].vifIdx = index.uint8
  vifs[0].next = addr vifs[1]
  vifEnv.activeList.first = addr vifs[0]
  chanEnv = default(ChanEnv)
  cfgElements = [99'u32, 12345'u32] # Not the vendor's traffic configuration.
  updates.setLen(0)
  updateCalls.setLen(0)
  updateResult = 0
  pmResult = 0
  messages.setLen(0)
  tdReads.setLen(0)
  sends.setLen(0)
  schedules.setLen(0)
  completions.setLen(0)
  logging = false
  lookups = 0
  onLog = nil
  powerControl = 0xA5000004'u32
  macNow = 1000
'''


def source(*, real_transition: bool = False, timer: bool = False,
           timer_only: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["PsEnvView", "BlPsParamsView", "TdEntryView", "TdConfigView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    logger_type = (FW / "global_state/c_runtime.nim").read_text().split("# Helper:", 1)[0]
    power = (FW / "power_save.nim").read_text()
    transition = (procedure(power, "ps_dpsm_update") if real_transition else r'''
proc ps_dpsm_update(enable: uint32): uint32 {.discardable.} =
  updates.add(enable)
  updateResult
''')
    notification = (r'''
proc ps_traffic_status_update(index: uint8; status: uint32): uint32 {.discardable.} =
  updateCalls.add((index, status, td_env[index].prevFlags))
  updateResult
''' if timer_only else procedure(power, "ps_traffic_status_update"))
    result = types + logger_type + PLATFORM + transition + notification
    if timer or timer_only:
        result += procedure(power, "td_timer_end")
    return result


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_traffic_transition_table(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [0'u8, 1]:
  for flags in 0'u8 .. 31'u8:
    for status in [1'u32, 0, 4, 8, 12, 0xFFFFFFFF'u32]:
      for traffic in [0'u8, 3, 4, 8, 12]:
        setup()
        ps.enabled = enabled
        ps.flags = flags
        td_env[0].prevFlags = 12 # The notifying VIF still has its old flags.
        td_env[1].prevFlags = traffic
        updateResult = 0x80000001'u32
        let actual = ps_traffic_status_update(0, status)
        var expected: seq[uint32]
        let admitted = enabled != 0 and (flags and 7) == 1
        let active = status != 0 or (traffic and 12) != 0
        let awake = (flags and 8) != 0
        if admitted and active != awake: expected.add(active.uint32)
        doAssert updates == expected
        doAssert actual == (if expected.len == 0: 0'u32 else: updateResult)
        doAssert ps.enabled == enabled and ps.flags == flags
        doAssert tdReads == (if admitted and status == 0: @[1'u8] else: @[])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_other_vif_selection_and_logging(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
vifs[0].next = nil
ps.flags = 9
ps_traffic_status_update(0, 0)
doAssert updates == @[0'u32]

for notifying in [0'u8, 1]:
  for hasLogger in [false, true]:
    setup()
    logging = hasLogger
    td_env[notifying].prevFlags = 12
    td_env[notifying xor 1].prevFlags = 4
    ps_traffic_status_update(notifying, 0)
    doAssert updates == @[1'u32] and tdReads == @[notifying xor 1]
    doAssert lookups == 1
    doAssert messages == (if hasLogger: @["ps_traffic_status_update:1187\r\n"] else: @[])

for gate in 0 .. 3:
  setup()
  ps.flags = 9
  td_env[0].prevFlags = 12
  td_env[1].prevFlags = 12
  case gate
  of 0: vifs[1].state = 0
  of 1: vifs[1].vifType = 2
  of 2: td_env[1].prevFlags = 3
  of 3: vifEnv.activeList.first = nil
  else: discard
  ps_traffic_status_update(0, 0)
  doAssert updates == @[0'u32] and lookups == 0

# The state may change while logging. Vendor reloads it before deciding.
setup()
logging = true
td_env[1].prevFlags = 8
onLog = proc() = ps.flags = 9
ps_traffic_status_update(0, 0)
doAssert messages.len == 1 and updates.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_real_traffic_timer_and_null_frame_transition(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_transition=True, timer=True) + r'''
# Last active VIF becomes idle. Its old traffic flags must not keep it awake.
setup()
vifs[0].next = nil
ps.flags = 9
logging = true
td_env[0].prevFlags = 12
td_env[0].endActive = 1
td_timer_end(addr td_env[0])
doAssert td_env[0].prevFlags == 0
doAssert ps.flags == 13 and ps.statusFlags == 0xA0000000'u32
doAssert ps.pendingCount == 1 and ps.currentVif == cast[pointer](addr vifs[0])
doAssert powerControl == 0xA5000004'u32
doAssert sends == @[(2'u8, cast[pointer](ps_enable_cfm), pointerAddrU32(addr vifs[0]))]
doAssert schedules == @[(psTxNullTimer(), 1050'u32), (cast[pointer](addr td_env[0]), 1100'u32)]
doAssert completions.len == 0 and messages == @["Power Status nul:nul\r\n"]

# New traffic while asleep sends the wake notification without a callback.
setup()
vifs[0].next = nil
logging = true
td_env[0].psRxCount = 1
td_env[0].endActive = 1
td_timer_end(addr td_env[0])
doAssert td_env[0].prevFlags == 4 and td_env[0].psRxCount == 0
doAssert ps.flags == 3 and ps.statusFlags == 0xA0000008'u32
doAssert ps.pendingCount == 0 and powerControl == 0xA5000000'u32
doAssert sends == @[(2'u8, cast[pointer](nil), 0'u32)]
doAssert schedules.len == 0
doAssert completions == @[("disable", cast[pointer](addr vifs[0]), 3'u8, 0'u8)]
doAssert messages == @["Power Status TX:nul\r\n"]

# An idle notification cannot start sleep while the other STA is busy.
setup()
ps.flags = 9
logging = true
td_env[0].prevFlags = 12
td_env[0].endActive = 1
td_env[1].prevFlags = 8
td_timer_end(addr td_env[0])
doAssert ps.flags == 9 and ps.pendingCount == 0
doAssert sends.len == 0 and completions.len == 0
doAssert schedules == @[(cast[pointer](addr td_env[0]), 1100'u32)]
doAssert messages == @["Power Status nul:nul\r\n", "ps_traffic_status_update:1187\r\n"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timer_configuration_and_transition_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(timer_only=True) + r'''
for active in [0'u8, 1]:
  for oldFlags in [0'u8, 4, 8, 12]:
    for counts in [0'u8, 1, 2, 4, 8, 12]:
      for pendingPeriod in [0'u32, 9]:
        for pmStatus in [0'u32, 1]:
          for resultCode in [0'u32, 1]:
            for sameChannel in [false, true]:
              setup()
              logging = true
              params.trafficThreshold = 2
              macNow = 0xFFFFFFF0'u32
              updateResult = resultCode
              pmResult = pmStatus
              chanEnv.currentCtxt = cast[pointer](0x1000)
              vifs[0].chanCtxt = if sameChannel: chanEnv.currentCtxt else: cast[pointer](0x2000)
              var td = addr td_env[0]
              td.endActive = active
              td.prevFlags = oldFlags
              td.period = pendingPeriod
              td.rxCount = if (counts and 1) != 0: 2 else: 1
              td.txCount = if (counts and 2) != 0: 2 else: 1
              td.psRxCount = if (counts and 4) != 0: 2 else: 1
              td.psTxCount = if (counts and 8) != 0: 2 else: 1
              let flags = counts or (if pendingPeriod != 0: 8'u8 else: 0'u8)
              let changed = ((oldFlags xor flags) and 12) != 0
              let notify = active != 0 and (pmStatus != 0 or changed)
              td_timer_end(td)
              if notify:
                let expectedStatus = if pmStatus != 0: (pendingPeriod != 0).uint32
                                     else: (flags and 12).uint32
                doAssert updateCalls == @[(0'u8, expectedStatus, oldFlags)]
              else:
                doAssert updateCalls.len == 0
              doAssert td.prevFlags == (if active != 0: flags else: oldFlags)
              doAssert td.endActive == sameChannel.uint8
              doAssert td.rxCount == 0 and td.txCount == 0
              doAssert td.psRxCount == 0 and td.psTxCount == 0
              if notify and resultCode != 0:
                doAssert schedules.len == 0
              else:
                doAssert schedules == @[(cast[pointer](td), 84'u32)]
              if active != 0 and pmStatus == 0 and changed:
                let tx = if (flags and 4) != 0: "TX" else: "nul"
                let rx = if (flags and 8) != 0: "RX" else: "nul"
                doAssert messages == @["Power Status " & tx & ":" & rx & "\r\n"]
              else:
                doAssert messages.len == 0
''')
