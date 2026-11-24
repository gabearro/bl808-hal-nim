"""Stop MAC idle transitions when the port's fatal assertion returns."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_switch_request import source as switch_source


PLATFORM = r'''
const
  TASK_MM = 0'u8
  MM_IDLE = 0'u16
  MM_ACTIVE_STATE = 1'u16
  MM_GOING_TO_IDLE = 2'u16
  HW_ACTIVE = 3'u16
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  MACHW_BASE = 0x24B00000'u
  MACHW_STATE_CNTRL_REG = MACHW_BASE + 0x38
type
  Header = object
    paramLen, padding: uint32
  Message = object
    header: Header
    callback: pointer
  Mm = object
    idleFlag: uint8
var
  mm: Mm
  mmConfigIdle: tuple[epoch: uint32]
  state: uint16
  hardwareState, power: uint32
  stateChanges: seq[uint16]
  writes: seq[tuple[address: uint, value: uint32]]
  assertions: seq[cint]
  completions, idleRequests: int
  interrupts, incomingIrq: bool
  assertionHook: proc()
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc mmEnvView(): ptr Mm = addr mm
proc mmConfigCancelIdle() = discard
proc ke_state_get(task: uint8): uint16 = state
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_MM
  stateChanges.add(value)
  state = value
proc regRead(address: uint): uint32 =
  if address == MACHW_STATE_CNTRL_REG: hardwareState else: power
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  if address == MACHW_BASE + 0x4C: power = value
proc assert_err(condition, file: cstring; line: cint) =
  if line == 1013:
    doAssert $condition == "blmac_current_state_getf() == HW_IDLE"
    doAssert $file == "module"
  assertions.add(line)
  if assertionHook != nil: assertionHook()
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc chanSwitchAdmit(p: pointer): bool = true
proc chanSwitchTrackIdle(p: pointer; state: uint16): uint32 = mmConfigIdle.epoch
proc chanSwitchInvoke(p: pointer): bool = false
proc hal_machw_idle_req() =
  doAssert not interrupts
  inc idleRequests
proc completed() {.cdecl.} =
  doAssert interrupts == incomingIrq
  inc completions
proc setup(irq = true) =
  mm = default(Mm)
  mmConfigIdle.epoch = 0
  state = HW_ACTIVE
  hardwareState = 0
  power = 0xABCD1234'u32
  stateChanges.setLen(0)
  writes.setLen(0)
  assertions.setLen(0)
  completions = 0
  idleRequests = 0
  interrupts = irq
  incomingIrq = irq
  assertionHook = nil
proc mm_force_idle_req_handler*(param: pointer): cint {.exportc, cdecl.}
proc request(): cint =
  var message = Message(header: Header(paramLen: sizeof(pointer).uint32),
                        callback: cast[pointer](completed))
  mm_force_idle_req_handler(addr message.callback)
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return (PLATFORM.replace("proc request(): cint =", "proc request(): cint\nproc invokeRequest(): cint =")
            + procedure(kernel, "blmac_pwr_mgt_setf")
            + procedure(kernel, "mm_active")
            + procedure(kernel, "mm_back_to_host_idle")
            + procedure((FW / "task_handlers.nim").read_text(), "mm_force_idle_req_handler")
            + "\nproc request(): cint = invokeRequest()\n")


CASES = {
    "return_to_idle": r'''
for sourceState in [0'u16, 1, 2, 3, 4, 65535]:
  for flag in [0'u8, 1]:
    setup()
    state = sourceState
    mm.idleFlag = flag
    mm_back_to_host_idle()
    if sourceState != HW_ACTIVE:
      doAssert assertions == @[1470.cint]
      doAssert stateChanges.len == 0 and writes.len == 0,
        "invalid forced-idle state still reactivated or published idle"
      doAssert state == sourceState
    elif flag == 0:
      doAssert assertions.len == 0 and stateChanges == @[MM_ACTIVE_STATE]
      doAssert writes == @[(MACHW_STATE_CNTRL_REG, 0x30'u32)]
    else:
      doAssert assertions.len == 0 and stateChanges == @[MM_IDLE]
      doAssert writes.len == 0
''',
    "force_idle_completion": r'''
for irq in [false, true]:
  for hw in [0'u32, 1, 2, 15, 0xABCDEF00'u32, 0xABCDEF01'u32]:
    setup(irq)
    state = MM_IDLE
    hardwareState = hw
    doAssert request() == KeMsgConsumed and interrupts == irq
    if (hw and 15) == 0:
      doAssert assertions.len == 0 and stateChanges == @[HW_ACTIVE]
      doAssert completions == 1
    else:
      doAssert assertions == @[1013.cint]
      doAssert stateChanges.len == 0 and completions == 0 and state == MM_IDLE,
        "non-idle hardware was reported as ready to switch"
    doAssert idleRequests == 0
  for sourceState in [MM_ACTIVE_STATE, MM_GOING_TO_IDLE, HW_ACTIVE]:
    setup(irq)
    state = sourceState
    doAssert request() == KeMsgSaved and interrupts == irq
    doAssert assertions.len == 0 and completions == 0
    doAssert idleRequests == (sourceState != MM_GOING_TO_IDLE).int
''',
    "power_management_field": r'''
for value in [0'u32, 1, 2, 3, 255, 65535]:
  setup()
  let original = power
  blmac_pwr_mgt_setf(value)
  if value <= 1:
    doAssert assertions.len == 0
    doAssert writes == @[(MACHW_BASE + 0x4C, (original and not 4'u32) or (value shl 2))]
  else:
    doAssert assertions == @[0x952.cint]
    doAssert power == original and writes.len == 0,
      "invalid power-management field changed other register bits"
''',
    "assertion_reentry": r'''
for operation in 0 .. 2:
  setup(false)
  state = MM_IDLE
  hardwareState = 1
  assertionHook = proc() =
    state = 17
    power = 0x76543210
  case operation
  of 0: mm_back_to_host_idle()
  of 1: discard request()
  else: blmac_pwr_mgt_setf(2)
  doAssert assertions.len == 1 and not interrupts
  doAssert state == 17 and power == 0x76543210
  doAssert stateChanges.len == 0 and writes.len == 0 and completions == 0,
    "assertion recovery was followed by stale transition work"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_idle_assert_returns(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_owned_force_idle_rejection(tmp_path: Path, mode: str) -> None:
    code = switch_source()
    code = code.replace(procedure(code, "regRead"), r'''
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_STATE_CNTRL_REG
  rejectedHardware
''')
    code = code.replace(procedure(code, "assert_err"), r'''
proc assert_err(condition, file: cstring; line: int) =
  doAssert line == 1013
  inc rejectedAssertions
''')
    code = "var rejectedHardware: uint32\nvar rejectedAssertions: int\n" + code
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  for hardware in [1'u32, 15]:
    resetSwitch()
    enabled = irq
    rejectedHardware = 0
    rejectedAssertions = 0
    let request = beginSwitch(newTarget())
    rejectedHardware = hardware
    doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
    doAssert rejectedAssertions == 1 and enabled == irq
    doAssert callbacks == 0 and forced == 0 and mmState == MM_IDLE
    release(request)
    finishSwitch()
''')
