"""Exercise dynamic power-save decisions and real traffic-timer handoff.

The decision tests stub ps_dpsm_update; the transition tests run the real
machine (the harness of test_wifi_ps_table.py) with the real traffic
detector.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_ps_table import ps_source as machine_source


PLATFORM = r'''
const
  VIF_TYPE_STA = 0'u8
  MACHW_TIMLO_REG = 0x24B00120'u
  MAX_VIFS = 2
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
  tdCfmArmed: array[MAX_VIFS, bool]
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
  nullSendStatus: uint8
  onNullSend: proc(sta: uint8, callback: pointer)
  nullTimerArmed, interrupts: bool
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
proc mm_timer_set(timer: pointer; expiry: uint32) =
  schedules.add((timer, expiry))
  if timer == psTxNullTimer(): nullTimerArmed = true
proc mm_timer_clear(timer: pointer) =
  doAssert timer == psTxNullTimer()
  nullTimerArmed = false
proc irqSave(): bool =
  result = interrupts
  interrupts = false
proc irqRestore(saved: bool) = interrupts = saved
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
  tdCfmArmed = default(typeof(tdCfmArmed))
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
  nullSendStatus = 0
  onNullSend = nil
  nullTimerArmed = false
  interrupts = true
'''


def source(*, timer_only: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["PsEnvView", "BlPsParamsView", "TdEntryView", "TdConfigView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    logger_type = (FW / "global_state/c_runtime.nim").read_text().split("# Helper:", 1)[0]
    power = (FW / "power_save.nim").read_text()
    transition = r'''
proc ps_dpsm_update(enable: uint32): uint32 {.discardable.} =
  updates.add(enable)
  updateResult
'''
    notification = (r'''
proc ps_traffic_status_update(index: uint8; status: uint32): uint32 {.discardable.} =
  updateCalls.add((index, status, td_env[index].prevFlags))
  updateResult
''' if timer_only else procedure(power, "ps_traffic_status_update"))
    result = types + logger_type + PLATFORM + transition + notification
    if timer_only:
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

''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_real_traffic_timer_and_null_frame_transition(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, machine_source(td=True) + r'''
# Last active VIF becomes idle. Its old traffic flags must not keep it awake.
enter(2)
discard ps_traffic_status_update(0, 4)
doAssert ps.flags == 9 and (pmRegister and 4) == 0
frames.setLen(0)
let td = addr tdEntries[0]
td.prevFlags = 12
td.endActive = 1
td_timer_end(td)
doAssert td.prevFlags == 0
doAssert ps.flags == 13 and psOwn.kind == psSleep and ps.pendingCount == 1
doAssert (pmRegister and 4) != 0 and (ps.statusFlags and 8) == 0
doAssert frames.len == 1 and frames[0].callback == cast[pointer](ps_enable_cfm)
doAssert opCurrent(psOwn.op, frames[0].arg) and frames[0].pm
doAssert nullTimerArmed and tdArms == @[(0'u8, macNow + params.trafficPeriod)]

# New traffic wakes the station. No TIM window is handed over (the PM word is
# 0), so the periodic traffic timer is still armed.
deliver(0, TxAck)
doAssert ps.flags == 1 and psOwn.kind == psIdle
frames.setLen(0)
tdArms.setLen(0)
td.psRxCount = 1
td.endActive = 1
td_timer_end(td)
doAssert td.prevFlags == 4 and td.psRxCount == 0
doAssert ps.flags == 9 and psOwn.kind == psIdle and (pmRegister and 4) == 0
doAssert (ps.statusFlags and 8) != 0
doAssert frames.len == 1 and frames[0].callback == nil and not frames[0].pm
doAssert tdArms == @[(0'u8, macNow + params.trafficPeriod)]
doAssert not tdCfmArmed[0]

# An idle notification cannot start sleep while the other STA is busy.
enter(2, 2)
discard ps_traffic_status_update(0, 4)
frames.setLen(0)
tdArms.setLen(0)
tdEntries[0].prevFlags = 12
tdEntries[0].endActive = 1
tdEntries[1].prevFlags = 8
td_timer_end(addr tdEntries[0])
doAssert ps.flags == 9 and psOwn.kind == psIdle and frames.len == 0
doAssert tdArms == @[(0'u8, macNow + params.trafficPeriod)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dynamic_transition_completion_skips_ap_vifs(tmp_path: Path, mode: str) -> None:
    """With every frame refused the transition ends where it starts; the
    commit goes to the last STA VIF on the list, never to an AP VIF."""
    run_program(tmp_path, mode, machine_source() + r'''
for enable in [0'u32, 1]:
  for placement in 0 .. 2:
    enter(2, 2)                 # dynamic PS, asleep
    if enable == 0:
      discard ps_traffic_status_update(0, 4)
      ackAll()                  # awake
    frames.setLen(0)
    nullSendStatus = 1
    for index in 0 .. 1: vifs[index].keyPsState = 7
    case placement
    of 0: vifs[0].vifType = 1
    of 1: vifs[1].vifType = 1
    else:
      vifs[0].vifType = 1
      vifs[1].vifType = 1
    let expected =
      if placement == 0: 1 elif placement == 1: 0 else: -1
    discard ps_dpsm_update(enable)
    nullSendStatus = 0
    doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and not nullTimerArmed
    doAssert frames.len == (if expected < 0: 0 else: 1)
    for index in 0 .. 1:
      let committed = if enable == 0: 1'u32 else: 0'u32
      doAssert vifs[index].keyPsState == (if index == expected: committed else: 7'u32)
    doAssert ps.flags == (if enable == 0: 1'u8 else: 9'u8)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dynamic_null_timer_tracks_only_unfinished_batch(tmp_path: Path, mode: str) -> None:
    """The sleep's timer is armed before its frames; frames confirmed while
    the walk still sends only count, and the sleep ends with its last frame."""
    run_program(tmp_path, mode, machine_source() + r'''
proc inlineFor(mask: int): proc() =
  result = proc() =
    let index = frames.len - 1
    doAssert nullTimerArmed and psOwn.kind == psSleep
    if (mask and (1 shl (frames[index].sta.int - 2))) != 0: deliver(index, TxAck)
    onSend = inlineFor(mask)
for inlineMask in [3, 0, 1, 2]:
  enter(2, 2)
  discard ps_traffic_status_update(0, 4)
  frames.setLen(0)
  onSend = inlineFor(inlineMask)
  discard ps_dpsm_update(0)
  onSend = nil
  doAssert frames.len == 2 and interrupts
  if inlineMask == 3:
    doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and not nullTimerArmed
  else:
    doAssert psOwn.kind == psSleep and nullTimerArmed
    for i in 0 .. 1:
      if (inlineMask and (1 shl i)) == 0:
        deliver(i, TxAck)
        if ps.pendingCount != 0:
          doAssert nullTimerArmed and psOwn.kind == psSleep
    doAssert psOwn.kind == psIdle and ps.pendingCount == 0 and not nullTimerArmed
  doAssert ps.flags == 1
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
              doAssert schedules == @[(cast[pointer](td), 84'u32)]
              if active != 0 and pmStatus == 0 and changed:
                let tx = if (flags and 4) != 0: "TX" else: "nul"
                let rx = if (flags and 8) != 0: "RX" else: "nul"
                doAssert messages == @["Power Status " & tx & ":" & rx & "\r\n"]
              else:
                doAssert messages.len == 0
''')
