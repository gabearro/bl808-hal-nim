"""Replay incomplete BL808 PM wake transactions with the real Nim handlers."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_mac_pm import source as mac_source
from test_wifi_message_allocation import run_program
from test_wifi_pm_runtime import source as pm_source


PLATFORM = r'''
const BlNapWaking = 2'u32
var
  napScheduleState: uint32
  queued, holdWake, holdRestore: bool
  wakeStarts: int
  ps = (enabled: 1'u8, statusFlags: 0'u32)
  vif = (flags: 0'u32, next: pointer(nil))
  env = (activeList: (first: pointer(nil), last: pointer(nil)), unused: 0)
proc wifi_hosal_pm_state_run(): uint32 = cast[uint32](bl_pm_state_run())
proc wifi_hosal_pm_post_event(kind, code: uint32; resultPtr: pointer) =
  discard pm_post_event(PmEvent(kind), code, cast[ptr uint32](resultPtr))
proc psEnvView(): ptr typeof(ps) = addr ps
proc vifMgmtEnvView(): ptr typeof(env) = addr env
proc vifChannelAt(p: pointer): ptr typeof(vif) = addr vif
proc chan_is_on_channel(p: pointer): bool = true
proc wifiMainHasPendingWork(): bool = queued
'''

DRIVER = r'''
const wakeReg = MACHW_INTC_BASE + 0x048'u
const wakeBit = 0x80000000'u32

proc beginNap() =
  setup()
  registers[MACHW_STATE_CNTRL_REG] = 3
  onWrite = proc(address: uint; value: uint32) =
    if address == wakeReg and (value and wakeBit) != 0:
      inc wakeStarts
      registers[MACHW_STATE_CNTRL_REG] = if holdWake: 2'u32 else: 0'u32
    if address == MACHW_STATE_CNTRL_REG:
      case value
      of 0x20: registers[address] = 2
      of 0x30: registers[address] = if holdRestore: 0'u32 else: 3'u32
      else: discard
  doAssert bl_pm_init() == 0
  doAssert bl_pm_capacity_set(apIdle) == 0
  doAssert bl_pm_event_register(enterSleep, 0, 2, 13, pmWaitMacIdle, nil, enabled) == 0
  doAssert bl_pm_event_register(enterSleep, 1, 4, 125, pmSetMacDoze, nil, enabled) == 0
  doAssert bl_pm_event_register(exitSleep, 2, 4, 34, pmWakePre, nil, enabled) == 0
  doAssert bl_pm_event_register(exitSleep, 2, 2, 36, pmWaitMacPrestate, nil, enabled) == 0
  doAssert bl_pm_event_register(exitSleep, 2, 4, 140, pmWakeDone, nil, enabled) == 0
  doAssert pm_post_event(control, 0, nil) == 0
  bl_sleep_schedule()
  doAssert napScheduleState == 1 and blDozeEnvView().dozeInProgress == 1
  doAssert registers[MACHW_STATE_CNTRL_REG] == 2 and wakeStarts == 0

proc requireAwake() =
  doAssert napScheduleState == 0 and blDozeEnvView().dozeInProgress == 0
  doAssert registers[MACHW_STATE_CNTRL_REG] == 3
  doAssert (registers[wakeReg] and wakeBit) == 0
'''

CASES = {
    "stop_while_asleep": r'''
beginNap()
# A later profile must not remove the capabilities needed to exit this nap.
doAssert bl_pm_capacity_set(idle) == 0
doAssert pm_post_event(control, 1, nil) == 0
bl_sleep_schedule()
doAssert napScheduleState == 0 and wakeStarts == 1, "STOP forgot to wake the MAC"
requireAwake()
bl_sleep_schedule()
doAssert wakeStarts == 1
''',
    "wake_times_out": r'''
beginNap()
holdWake = true
queued = true
bl_sleep_schedule()
doAssert napScheduleState != 0, "timed-out wake published awake"
doAssert blDozeEnvView().dozeInProgress == 1 and wakeStarts == 1
doAssert registers[MACHW_STATE_CNTRL_REG] == 2 and (registers[wakeReg] and wakeBit) != 0
holdWake = false
queued = false
bl_sleep_schedule()
requireAwake()
doAssert wakeStarts == 2
''',
    "restore_times_out": r'''
beginNap()
holdRestore = true
queued = true
bl_sleep_schedule()
doAssert napScheduleState != 0, "failed pre-state restore published awake"
doAssert blDozeEnvView().dozeInProgress == 0 and wakeStarts == 1
doAssert registers[MACHW_STATE_CNTRL_REG] == 0 and (registers[wakeReg] and wakeBit) != 0
holdRestore = false
queued = false
doAssert pm_post_event(control, 1, nil) == 0
bl_sleep_schedule()
requireAwake()
doAssert wakeStarts == 1, "retry unnecessarily restarted wake pre-phase"
''',
    "deinit_while_asleep": r'''
beginNap()
doAssert bl_pm_deinit() == -1 and pmInitialized
bl_sleep_schedule()
requireAwake()
doAssert bl_pm_deinit() == 0 and not pmInitialized
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_mac_wake_transaction(tmp_path: Path, mode: str, case: str) -> None:
    platform = (FW / "platform_bl.nim").read_text()
    handlers = "".join(procedure(platform, name) for name in (
        "pmWaitMacIdle", "pmSetMacDoze", "pmWakePre", "pmWaitMacPrestate", "pmWakeDone",
    ))
    run_program(tmp_path, mode, mac_source() + pm_source() + PLATFORM + handlers
                + procedure(platform, "bl_sleep_schedule") + DRIVER + CASES[case])
