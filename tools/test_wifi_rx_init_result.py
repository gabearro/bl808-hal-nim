"""Propagate RX descriptor initialization results through startup and recovery."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_init_owner import source as owner_source


SUPPORT = r'''
const
  TASK_MM = 0'u8
  HW_ACTIVE = 3'u8
var
  steps: seq[string]
  mm: MmEnvView
  fw_nap_chain: array[8, uint8]
  fw_nap_chain_ptr: pointer
  bl_env: array[2, uint32]
  states: seq[uint16]
proc nimFwTrace(message: string) = discard
proc mmEnvView(): ptr MmEnvView = addr mm
proc hal_machw_init(): bool =
  steps.add("mac-init")
  true
proc mm_env_init() = steps.add("env")
proc vif_mgmt_init(): bool =
  steps.add("vif-init")
  true
proc sta_mgmt_init() = steps.add("sta")
proc td_init() = steps.add("td")
proc ps_init() = steps.add("ps")
proc txl_cntrl_init() =
  steps.add("tx-init")
  txControlState.resetInProgress = 0
proc mm_timer_init() = steps.add("timer")
proc scan_init() = steps.add("scan")
proc chan_init() = steps.add("chan")
proc mm_bcn_init() = steps.add("beacon")
proc me_init() = steps.add("me")
proc ke_init() =
  steps.add("ke")
  resetEvents = 0
proc bl_supplicant_init() = steps.add("supplicant")
proc waitMacSoftResetClear(): bool = true
template smSaQueryResetScope() = discard
proc smSaQueryClearResetTimer() = discard
proc hal_machw_reset(): bool =
  doAssert irqLevel == 0
  steps.add("mac-reset")
  true
proc txl_reset(): bool =
  doAssert irqLevel == 0
  steps.add("tx-reset")
  txControlState.resetInProgress = 0
  true
proc mm_reset() =
  doAssert irqLevel == 0
  steps.add("mm-reset")
proc vif_mgmt_reset() =
  doAssert irqLevel == 0
  steps.add("vif-reset")
proc apmResumeHaltRollback() = doAssert irqLevel == 0
proc ke_evt_clear(mask: uint32) =
  doAssert irqLevel == 0
  steps.add("clear:" & $mask)
  resetEvents = resetEvents and not mask
proc ke_state_set(task: uint8; state: uint16) =
  doAssert irqLevel == 0 and task == TASK_MM and state == HW_ACTIVE.uint16
  steps.add("state")
  states.add(state)
proc ke_reschedule_saved_messages(task: uint8): bool =
  doAssert irqLevel == 0 and task == TASK_MM
  steps.add("saved")
  true
proc setupRun(incoming: uint32) =
  setup()
  irqLevel = incoming
  steps.setLen(0)
  states.setLen(0)
  mm = default(MmEnvView)
  mm.previousState = 7
  mm.hardwareMode = 9
  resetEvents = 0x04000000'u32
  markReplacement()
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    platform = (FW / "platform_bl.nim").read_text()
    code = owner_source() + layouts("MmEnvView") + SUPPORT
    code += procedure(kernel, "mm_init") + ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n" + procedure(kernel, "mm_force_idle_req"))
    code += procedure(platform, "bl_init") + procedure(platform, "bl_reset_evt")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_callbacks_stop_startup_and_allow_retry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for top in [false, true]:
  for missing in 0 .. 1:
    for incoming in [0'u32, 8]:
      setupRun(incoming)
      missingEntry = missing == 0
      missingExit = missing == 1
      onProbe = proc() = steps.add("rx")
      let ok = if top: bl_init() else: mm_init()
      doAssert not ok, "startup reported success without RX initialization"
      var expected = @["mac-init", "env", "vif-init", "sta", "td", "ps", "tx-init"]
      if top: expected.insert("me", 0)
      doAssert steps == expected
      doAssert irqLevel == incoming and disabledMacIrqs == 1
      doAssert txControlState.resetInProgress == 1 and resetEvents == 0x84000000'u32
      doAssert triggers.len == 0 and listClears == 0 and upperInitializations == 0
      checkReplacement()

      missingEntry = false
      missingExit = false
      steps.setLen(0)
      doAssert (if top: bl_init() else: mm_init())
      expected.add(@["rx", "timer", "scan", "chan", "beacon"])
      if top: expected.add(@["ke", "supplicant"])
      doAssert steps == expected and irqLevel == incoming
      doAssert txControlState.resetInProgress == 0
      doAssert lower.queue.first == nil and upper.uploadList.first == nil
      doAssert upperInitializations == 1 and listClears == 1
      if top: doAssert resetEvents == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_callbacks_stop_recovery_before_tx_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for forced in [false, true]:
  for missing in 0 .. 1:
    for incoming in [0'u32, 8]:
      setupRun(incoming)
      let before = mm
      missingEntry = missing == 0
      missingExit = missing == 1
      if forced: doAssert not mm_force_idle_req()
      else: bl_reset_evt()
      let expected = if forced: @["mac-reset"]
                     else: @["clear:2147483648", "mac-reset"]
      doAssert steps == expected and mm == before and states.len == 0
      doAssert txControlState.resetInProgress == 1 and resetEvents == 0x84000000'u32
      doAssert irqLevel == incoming and disabledMacIrqs == 1 and triggers.len == 0
      checkReplacement()

      missingEntry = false
      missingExit = false
      steps.setLen(0)
      if forced: doAssert mm_force_idle_req()
      else: bl_reset_evt()
      if forced:
        doAssert steps == @["mac-reset", "tx-reset", "state"]
        doAssert mm.previousState == 0 and mm.hardwareMode == 0
        doAssert states == @[HW_ACTIVE.uint16]
      else:
        doAssert steps == @["clear:2147483648", "mac-reset", "tx-reset",
                            "mm-reset", "vif-reset", "clear:67108864", "saved"]
        doAssert resetEvents == 0
      doAssert txControlState.resetInProgress == 0 and irqLevel == incoming
      doAssert lower.queue.first == nil and upper.uploadList.first == nil
      doAssert listClears == 2
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_low_level_results_cover_missing_and_superseded_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, owner_source() + r'''
for operation in 0 .. 2:
  for incoming in [0'u32, 8]:
    for phase in 0 .. 4:
      setup()
      irqLevel = incoming
      if phase == 4:
        missingEntry = true
      else:
        let action = proc() =
          doAssert rxl_hwdesc_init(1)
          markReplacement()
        case phase
        of 0: onEnter = action
        of 1: onProbe = action
        of 2: onTrace = action
        else: onExit = action
      let ok = case operation
               of 0: rxl_hwdesc_init(1)
               of 1: rxl_init()
               else: rxl_reset()
      doAssert not ok and irqLevel == incoming
      doAssert txControlState.resetInProgress == 1
      doAssert resetEvents == 0x80000000'u32 and disabledMacIrqs == 1
      doAssert listClears == 0 and upperInitializations == 0
      if phase != 4: checkReplacement()

    setup()
    irqLevel = incoming
    let ok = case operation
             of 0: rxl_hwdesc_init(1)
             of 1: rxl_init()
             else: rxl_reset()
    doAssert ok and irqLevel == incoming and disabledMacIrqs == 0
    doAssert txControlState.resetInProgress == 0 and resetEvents == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_superseded_rx_stops_outer_startup_and_recovery(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for operation in 0 .. 2:
  for incoming in [0'u32, 8]:
    for phase in 0 .. 3:
      setupRun(incoming)
      let before = mm
      let action = proc() =
        doAssert rxl_hwdesc_init(1)
        markReplacement()
      case phase
      of 0: onEnter = action
      of 1: onProbe = action
      of 2: onTrace = action
      else: onExit = action
      case operation
      of 0: doAssert not bl_init()
      of 1: doAssert not mm_force_idle_req()
      else: bl_reset_evt()
      doAssert "tx-reset" notin steps and "state" notin steps
      doAssert "timer" notin steps and "ke" notin steps and "saved" notin steps
      doAssert "mm-reset" notin steps and "vif-reset" notin steps
      doAssert states.len == 0 and mm == before
      doAssert txControlState.resetInProgress == 1 and resetEvents == 0x84000000'u32
      doAssert disabledMacIrqs == 1 and irqLevel == incoming
      checkReplacement()
''')
