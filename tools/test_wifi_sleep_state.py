"""Check the sleep scheduler's PS/VIF conditions and PM transition contract."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  CoList = object
    first, last: pointer
  Ps = object
    enabled: uint8
    statusFlags: uint32
  Vif = object
    next: pointer
    flags, adjacentWord: uint32
    onChannel: bool
  Env = object
    freeList, activeList: CoList
var
  ps: Ps
  env: Env
  vifs: array[2, Vif]
  napScheduleState, pmState, veto: uint32
  queued, interrupts, incomingIrq: bool
  visited: seq[int]
  events: seq[tuple[kind, code: uint32, hasResult: bool]]
  steps: seq[string]
  resultAddress: pointer
  stateCalls, pendingChecks: int
proc psEnvView(): ptr Ps = addr ps
proc vifMgmtEnvView(): ptr Env = addr env
proc vifChannelAt(p: pointer): ptr Vif =
  for index in 0 .. 1:
    if p == (addr vifs[index]): return addr vifs[index]
  raiseAssert "unknown active VIF"
proc chan_is_on_channel(p: pointer): bool =
  doAssert interrupts == incomingIrq
  for index in 0 .. 1:
    if p == (addr vifs[index]):
      visited.add(index)
      return vifs[index].onChannel
  raiseAssert "channel check received an unknown VIF"
proc wifi_hosal_pm_state_run(): uint32 =
  doAssert interrupts == incomingIrq
  inc stateCalls
  steps.add("pm-state")
  pmState
proc wifiMainHasPendingWork(): bool =
  inc pendingChecks
  queued
proc wifi_hosal_pm_post_event(kind, code: uint32; resultPtr: pointer) =
  doAssert interrupts == incomingIrq
  events.add((kind, code, resultPtr != nil))
  steps.add("pm:" & $kind & ":" & $code)
  if resultPtr != nil:
    if kind == 1:
      doAssert code == 0 and resultAddress == nil
      resultAddress = resultPtr
      cast[ptr uint32](resultPtr)[] = veto
    else:
      doAssert kind == 2 and code == 0 and resultPtr == resultAddress
      doAssert cast[ptr uint32](resultPtr)[] == veto
proc setup(previousState = 0'u32; irq = true) =
  ps = Ps(enabled: 1)
  env = default(Env)
  vifs = default(typeof(vifs))
  napScheduleState = previousState
  pmState = 0
  veto = 0
  queued = false
  interrupts = irq
  incomingIrq = irq
  visited.setLen(0)
  events.setLen(0)
  steps.setLen(0)
  resultAddress = nil
  stateCalls = 0
  pendingChecks = 0
proc oneActive(onChannel: bool; flags: uint32) =
  vifs[0].onChannel = onChannel
  vifs[0].flags = flags
  vifs[0].adjacentWord = 0xDEADBEEF'u32
  env.activeList = CoList(first: addr vifs[0], last: addr vifs[0])
proc runSleep() =
  bl_sleep_schedule()
  doAssert stateCalls == 1 and pendingChecks == 1
  doAssert interrupts == incomingIrq
'''


def source() -> str:
    declaration = "proc bl_sleep_schedule*() {.exportc, cdecl.}\n"
    return (declaration + PLATFORM
            + procedure((FW / "platform_bl.nim").read_text(), "bl_sleep_schedule"))


SLEEP_EVENTS = "@[(1'u32, 0'u32, true), (1'u32, 1'u32, false)]"
WAKE_EVENTS = "@[(2'u32, 1'u32, false), (2'u32, 2'u32, false)]"


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ps_status_blocks_sleep(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for flags in [1'u32, 2, 4, 0x80000000'u32, high(uint32)]:
    for previousState in [0'u32, 1'u32]:
      setup(previousState, irq)
      ps.statusFlags = flags
      runSleep()
      doAssert napScheduleState == 0 and visited.len == 0
      if previousState == 0: doAssert events.len == 0
      else: doAssert events == WAKE_EVENTS
'''.replace("WAKE_EVENTS", WAKE_EVENTS))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unused_vif_pool_does_not_block_sleep(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for freeEntry in [false, true]:
    setup(0, irq)
    oneActive(true, 0)
    if freeEntry: env.freeList = CoList(first: addr vifs[1], last: addr vifs[1])
    runSleep()
    doAssert napScheduleState == 1 and visited == @[0]
    doAssert events == SLEEP_EVENTS
'''.replace("SLEEP_EVENTS", SLEEP_EVENTS))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_active_vif_flags_and_channel(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for flags in [0'u32, 1'u32, 0x80000000'u32]:
    for onChannel in [false, true]:
      setup(0, irq)
      oneActive(onChannel, flags)
      runSleep()
      doAssert visited == @[0]
      let allowed = not onChannel or flags == 0
      doAssert napScheduleState == allowed.uint32
      if allowed: doAssert events == SLEEP_EVENTS
      else: doAssert events.len == 0

setup()
oneActive(false, high(uint32))
vifs[0].next = addr vifs[1]
vifs[1].onChannel = true
vifs[1].flags = 2
env.activeList.last = addr vifs[1]
runSleep()
doAssert napScheduleState == 0 and visited == @[0, 1] and events.len == 0

setup()
oneActive(true, 1)
vifs[0].next = addr vifs[1]
env.activeList.last = addr vifs[1]
runSleep()
doAssert visited == @[0] and events.len == 0
'''.replace("SLEEP_EVENTS", SLEEP_EVENTS))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pm_result_and_veto_transitions(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for previousState in [0'u32, 1'u32]:
    setup(previousState, irq)
    pmState = high(uint32)
    runSleep()
    doAssert napScheduleState == 0 and events.len == 0 and visited.len == 0

    setup(previousState, irq)
    ps.enabled = 0
    runSleep()
    doAssert napScheduleState == 0 and visited.len == 0
    if previousState == 0: doAssert events.len == 0
    else: doAssert events == WAKE_EVENTS

  setup(0, irq)
  veto = 7
  runSleep()
  doAssert napScheduleState == 0
  doAssert events == @[(1'u32, 0'u32, true), (2'u32, 0'u32, true)]

  setup(1, irq)
  runSleep()
  doAssert napScheduleState == 1 and events.len == 0
'''.replace("WAKE_EVENTS", WAKE_EVENTS))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pending_work_keeps_existing_wake_guard(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for busyPm in [false, true]:
    setup(1, irq)
    pmState = busyPm.uint32
    queued = true
    oneActive(true, 0)
    runSleep()
    doAssert napScheduleState == 0 and visited.len == 0
    doAssert events == WAKE_EVENTS
'''.replace("WAKE_EVENTS", WAKE_EVENTS))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_main_service_runs_sleep_check_without_blocking(tmp_path: Path, mode: str) -> None:
    main = (FW / "task_init_main.nim").read_text()
    code = source() + r'''
var waited, drained: int
proc wifiUpdateMacPlCtrl() = steps.add("mac-ctrl")
proc ipc_emb_wait() =
  inc waited
  queued = true
proc wifiDrainScheduledWork(): bool =
  inc drained
  result = queued
  queued = false
'''
    code += procedure(main, "wifiWaitForWorkIfIdle")
    code += procedure(main, "wifiMainServiceStep")
    run_program(tmp_path, mode, code + r'''
setup()
oneActive(true, 0)
env.freeList = CoList(first: addr vifs[1], last: addr vifs[1])
doAssert not wifiMainServiceStep()
doAssert events == SLEEP_EVENTS and napScheduleState == 1
doAssert steps[0 .. 1] == @["mac-ctrl", "pm-state"]
doAssert waited == 0 and drained == 1

setup(1)
queued = true
doAssert wifiMainServiceStep()
doAssert events == WAKE_EVENTS and napScheduleState == 0
doAssert waited == 0 and drained == 2
'''.replace("SLEEP_EVENTS", SLEEP_EVENTS).replace("WAKE_EVENTS", WAKE_EVENTS))
