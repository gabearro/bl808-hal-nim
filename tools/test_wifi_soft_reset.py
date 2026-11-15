"""Exercise the soft-reset getter, bounded wait, and saved MM reset request."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mm_reset import source as reset_source
from test_wifi_saved_reschedule import source as saved_source


SUPPORT = r'''
const
  WifiHwPollLimit = 4'u32
  WifiMachwSoftResetReg = 0x24B08050'u32
var
  softSamples: seq[uint32]
  softReads, reschedules: int
  pendingEvents: uint32
  tx: tuple[resetInProgress: uint8]
  unmask, genStatus: uint32
  writes: seq[tuple[address: uint, value: uint32]]
  timeouts: seq[tuple[address, mask: uint32]]
proc txControlEnv(): ptr typeof(tx) = addr tx
proc regRead(address: uint): uint32 =
  case address
  of 0x24B08050'u:
    doAssert softSamples.len > 0
    result = softSamples[min(softReads, softSamples.high)]
    inc softReads
  of 0x24B08074'u: result = unmask
  of 0x24B08080'u: result = genStatus
  else: doAssert false
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  case address
  of 0x24B08050'u: doAssert value == 1
  of 0x24B08074'u: unmask = value
  of 0x24B08080'u: genStatus = value
  else: doAssert false
proc noteHwWaitTimeout(address, mask: uint32) = timeouts.add((address, mask))
proc assert_err(condition, file: cstring; line: cint) = doAssert false
proc ke_evt_set(mask: uint32) = pendingEvents = pendingEvents or mask
proc ke_evt_clear(mask: uint32) =
  checkResetContext()
  pendingEvents = pendingEvents and not mask
proc hal_machw_reset(): bool =
  checkResetContext()
  true
proc rxl_reset(): bool =
  checkResetContext()
  true
proc txl_reset(): bool =
  checkResetContext()
  tx.resetInProgress = 0
  true
proc mm_reset() =
  checkResetContext()
  mmState = 0
proc vif_mgmt_reset() = checkResetContext()
proc apmResumeHaltRollback() = checkResetContext()
proc ke_reschedule_saved_messages(task: uint8): bool =
  checkResetContext()
  doAssert task == TASK_MM
  inc reschedules
  true
proc setupSoft(irq: bool; samples: seq[uint32]) =
  setup(irq)
  softSamples = samples
  softReads = 0
  reschedules = 0
  pendingEvents = 0
  tx.resetInProgress = 0
  unmask = 0xABCDEF01'u32
  genStatus = 0x87654321'u32
  writes.setLen(0)
  timeouts.setLen(0)
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    stop = procedure(kernel, "hal_machw_stop")
    forward = stop.splitlines()[0].rsplit(" =", 1)[0] + "\n"
    code = reset_source()
    code = code.replace(procedure(code, "hal_machw_stop"), forward, 1)
    registers = (FW / "register_constants.nim").read_text().split("  # MAC platform registers", 1)[0]
    interrupt_constants = kernel.split("const\n  # MAC HW timer registers", 1)[1].split("\nproc ", 1)[0]
    code = registers + "const\n  # MAC HW timer registers" + interrupt_constants + code
    code += SUPPORT
    code += procedure(kernel, "blmac_soft_reset_getf")
    code += procedure((FW / "global_state/late_forward_decls.nim").read_text(), "waitMacSoftResetClear")
    code += procedure(kernel, "hal_machw_disable_int") + stop
    code += procedure((FW / "platform_bl.nim").read_text(), "bl_reset_evt")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_stop_saves_request_without_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  setupSoft(irq, @[1'u32])
  let before = message
  doAssert bl_send_reset(addr hw) == KeMsgSaved
  doAssert message == before and confirmations.len == 0
  doAssert events == @["disable", "restore"] and mmState == 255
  doAssert interrupts == irq and irqDepth == 0
  doAssert tx.resetInProgress == 1 and pendingEvents == 0x80000000'u32
  doAssert unmask == 0x2BCDEF01'u32 and genStatus == 0x07654321'u32
  doAssert softReads == 5
  doAssert timeouts == @[(WifiMachwSoftResetReg, 0xFF'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_success_waits_for_clear_before_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for busyReads in 0 .. 4:
    var samples: seq[uint32]
    for index in 0 ..< busyReads: samples.add(1)
    samples.add(0)
    setupSoft(irq, samples)
    doAssert bl_send_reset(addr hw) == KeMsgConsumed
    doAssert softReads == busyReads + 1
    doAssert writes == @[(MACHW_INTC_SOFT_RESET, 1'u32)]
    doAssert timeouts.len == 0 and pendingEvents == 0 and tx.resetInProgress == 0
    doAssert events == @["disable", "phy-stop", "me-init", "mm-init",
                        "restore", "confirm", "idle-state"]
    doAssert confirmations == @[(MM_RESET_CFM, DRV_TASK_ID, TASK_MM)]
    doAssert interrupts == irq and irqDepth == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_recovery_reschedules_request_even_when_already_idle(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  setupSoft(irq, @[1'u32])
  message.header.srcId = 17
  doAssert mm_reset_req_handler(addr message.payload[0]) == KeMsgSaved
  mmState = 0
  bl_reset_evt()
  doAssert mmState == 0 and reschedules == 0
  doAssert pendingEvents == 0x80000000'u32 and tx.resetInProgress == 1
  doAssert confirmations.len == 0 and interrupts == irq
  softSamples = @[0'u32]
  softReads = 0
  bl_reset_evt()
  doAssert mmState == 0 and reschedules == 1
  doAssert pendingEvents == 0 and tx.resetInProgress == 0
  doAssert confirmations.len == 0 and interrupts == irq
  softSamples = @[1'u32, 0]
  softReads = 0
  doAssert mm_reset_req_handler(addr message.payload[0]) == KeMsgConsumed
  doAssert confirmations == @[(MM_RESET_CFM, 17'u8, TASK_MM)]
  doAssert softReads == 2 and irqDepth == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_zero_poll_budget_and_last_allowed_read(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setupSoft(true, @[0'u32])
doAssert waitMacSoftResetClear(0) and softReads == 1 and timeouts.len == 0
setupSoft(true, @[1'u32])
doAssert not waitMacSoftResetClear(0) and softReads == 1
doAssert timeouts == @[(WifiMachwSoftResetReg, 0xFF'u32)]
setupSoft(true, @[1'u32, 1, 0])
doAssert waitMacSoftResetClear(2) and softReads == 3 and timeouts.len == 0
setupSoft(true, @[1'u32, 1, 0])
doAssert not waitMacSoftResetClear(1) and softReads == 2
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_recovery_releases_real_saved_queue_without_state_change(tmp_path: Path, mode: str) -> None:
    support = r'''
proc waitMacSoftResetClear(): bool = true
proc hal_machw_reset(): bool =
  doAssert not interrupts
  true
proc rxl_reset(): bool =
  doAssert not interrupts
  true
proc txl_reset(): bool =
  doAssert not interrupts
  true
proc mm_reset() = ke_state_set(TASK_MM, 0)
proc vif_mgmt_reset() = doAssert not interrupts
proc apmResumeHaltRollback() = doAssert not interrupts
'''
    code = saved_source() + support
    code += procedure((FW / "platform_bl.nim").read_text(), "bl_reset_evt")
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  setup()
  interrupts = irq
  save(TASK_MM, 17)
  save(TASK_SM, 3)
  doAssert states[TASK_MM] == 0
  bl_reset_evt()
  doAssert states[TASK_MM] == 0 and interrupts == irq
  doAssert ke_saved_queue_count_dest(TASK_MM) == 9
  doAssert ke_saved_queue_count_dest(TASK_SM) == 3
  doAssert keMsgQueueSent.first != nil
  drain()
  doAssert delivered.len == 17 and interrupts == irq
  for index, id in delivered: doAssert id == index.uint16
  doAssert ke_saved_queue_count_dest(TASK_MM) == 0
  doAssert ke_saved_queue_count_dest(TASK_SM) == 3
''')
