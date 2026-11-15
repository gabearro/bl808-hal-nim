"""Check MAC doze state ownership, transition order, and bounded failures."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/tables
const
  MACHW_STATUS_REG = 0x24B0004C'u
  MACHW_STATE_CNTRL_REG = 0x24B00038'u
  MACHW_INTC_BASE = 0x24B08000'u
  WifiHwPollLimit = 3'u32
  TASK_MM = 0'u8
type
  BlDozeEnvView {.packed.} = object
    preState: uint8
    preStateTailPadding: array[3, uint8]
    dozeInProgress: uint32
  OldPsDozeEnvView {.packed.} = object
    base: array[56, uint8]
    dozeInProgress: uint32
    preState: uint8
var
  bl_env: array[2, uint32]
  ps_env: array[64, uint8]
  mm_env: array[64, uint32]
  registers: Table[uint, uint32]
  reads: seq[uint]
  writes: seq[tuple[address: uint, value: uint32]]
  assertions: seq[tuple[condition, file: string, line: cint]]
  messages: seq[string]
  timeouts: seq[tuple[address, mask: uint32]]
  steps: seq[string]
  ticks: seq[uint32]
  tickIndex: int
  interrupts, logging: bool
  onRead: proc(address: uint)
  onWrite: proc(address: uint; value: uint32)
proc blDozeEnvView(): ptr BlDozeEnvView = cast[ptr BlDozeEnvView](addr bl_env[0])
proc psDozeEnvView(): ptr OldPsDozeEnvView = cast[ptr OldPsDozeEnvView](addr ps_env[0])
proc regRead(address: uint): uint32 =
  reads.add(address)
  steps.add("read:" & $address)
  if onRead != nil: onRead(address)
  registers.getOrDefault(address)
proc regWrite(address: uint; value: uint32) =
  registers[address] = value
  writes.add((address, value))
  steps.add("write:" & $address)
  if onWrite != nil: onWrite(address, value)
proc macTimeNow(): uint32 =
  doAssert ticks.len != 0
  result = ticks[min(tickIndex, ticks.high)]
  inc tickIndex
  steps.add("time")
proc noteHwWaitTimeout(address, mask: uint32) = timeouts.add((address, mask))
proc assert_rec(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 4 and tag == nil and file == cstring("bl.c") and line == 286
  doAssert format == cstring("mac state not idle, assert.\r\n")
  messages.add($format)
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 204
  if logging: cast[pointer](logWrite) else: nil
proc waitRegLowNibbleClear(address: uint): bool = false
proc waitRegLowNibbleEquals(address: uint; value: uint32): bool = false
proc setup() =
  bl_env = [0xA1B2C303'u32, 0x11223344'u32]
  for value in ps_env.mitems: value = 0x5A
  mm_env = default(typeof(mm_env))
  registers.clear()
  registers[MACHW_STATUS_REG] = 0xA5A50005'u32
  registers[MACHW_STATE_CNTRL_REG] = 0
  registers[MACHW_INTC_BASE + 0x074] = 0xA0000080'u32
  registers[MACHW_INTC_BASE + 0x06C] = 4
  registers[MACHW_INTC_BASE + 0x048] = 0x12345678'u32
  reads.setLen(0)
  writes.setLen(0)
  assertions.setLen(0)
  messages.setLen(0)
  timeouts.setLen(0)
  steps.setLen(0)
  ticks = @[100'u32]
  tickIndex = 0
  interrupts = true
  logging = true
  onRead = nil
  onWrite = nil
proc checkPsUnchanged() =
  for value in ps_env: doAssert value == 0x5A
  for value in mm_env: doAssert value == 0
'''


def source() -> str:
    text = (FW / "power_save.nim").read_text()
    code = PLATFORM
    layout = (FW / "layout_types.nim").read_text()
    type_pattern = r"^  BlDozeEnvView \{\.packed\.\} = object\n(?:^    [^\n]*\n)+"
    definition = re.search(type_pattern, layout, re.M)
    if definition:
        code = re.sub(type_pattern, lambda _: definition[0], code, count=1, flags=re.M)
        accessor = re.search(
            r"^template blDozeEnvView\(\): ptr BlDozeEnvView =\n  [^\n]+\n", layout, re.M)
        assert accessor
        code = code.replace(
            "proc blDozeEnvView(): ptr BlDozeEnvView = cast[ptr BlDozeEnvView](addr bl_env[0])\n",
            accessor[0], 1)
    for name in ["waitMacPmInterrupt", "waitMacPmState"]:
        if f"proc {name}(" in text:
            code += procedure(text, name)
    for name in ["set_mac_to_doze", "wait_mac_goto_idle", "wait_mac_goto_prestate",
                 "wakeup_from_doze_pre", "wakeup_from_doze_done"]:
        code += procedure(text, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_doze_uses_bl_state_and_low_current_nibble(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for current in [0'u32, 0x20'u32, 0xF0'u32]:
  setup()
  registers[MACHW_STATE_CNTRL_REG] = current
  doAssert set_mac_to_doze() == 0
  doAssert bl_env == [0xA1B2C303'u32, 1'u32]
  doAssert writes == @[(MACHW_STATUS_REG, 0xA5A50045'u32),
                      (MACHW_STATE_CNTRL_REG, 0x20'u32)]
  doAssert assertions.len == 0 and messages.len == 0
  checkPsUnchanged()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_busy_mac_reports_and_does_not_enter_doze(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for current in [1'u32, 3'u32, 15'u32]:
    setup()
    logging = enabled
    registers[MACHW_STATE_CNTRL_REG] = current
    doAssert set_mac_to_doze() == 1
    doAssert bl_env == [0xA1B2C303'u32, 0x11223344'u32]
    doAssert writes == @[(MACHW_STATUS_REG, 0xA5A50045'u32)]
    doAssert assertions == @[("0", "bl.c", 287.cint)]
    doAssert messages.len == enabled.int
    checkPsUnchanged()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_idle_captures_state_before_second_read(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
registers[MACHW_STATE_CNTRL_REG] = 0xAB
var stateReads = 0
onRead = proc(address: uint) =
  if address == MACHW_STATE_CNTRL_REG:
    inc stateReads
    if stateReads == 2: registers[address] = 0x20
doAssert wait_mac_goto_idle() == 0
doAssert bl_env == [0xA1B2C30B'u32, 0x11223344'u32]
doAssert stateReads == 2 and writes.len == 0 and tickIndex == 0
checkPsUnchanged()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_idle_handshake_preserves_register_bits_and_bounds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
registers[MACHW_STATE_CNTRL_REG] = 3
doAssert wait_mac_goto_idle() == 0
doAssert bl_env == [0xA1B2C303'u32, 0x11223344'u32]
doAssert steps[0 .. 2] == @["read:" & $MACHW_STATE_CNTRL_REG,
                           "read:" & $MACHW_STATE_CNTRL_REG, "time"]
doAssert writes == @[(MACHW_INTC_BASE + 0x074, 0x20000080'u32),
                    (MACHW_INTC_BASE + 0x074, 0x20000084'u32),
                    (MACHW_STATE_CNTRL_REG, 0'u32),
                    (MACHW_INTC_BASE + 0x070, 4'u32),
                    (MACHW_INTC_BASE + 0x074, 0x20000080'u32),
                    (MACHW_INTC_BASE + 0x074, 0xA0000080'u32)]
checkPsUnchanged()

for frozen in [false, true]:
  setup()
  registers[MACHW_STATE_CNTRL_REG] = 3
  registers[MACHW_INTC_BASE + 0x06C] = 0
  ticks = if frozen: @[0'u32] else: @[0'u32, 5_000_000'u32]
  onWrite = proc(address: uint; value: uint32) =
    if address == MACHW_STATE_CNTRL_REG: registers[address] = 3
  doAssert wait_mac_goto_idle() == 1
  doAssert timeouts == @[(uint32(MACHW_INTC_BASE + 0x06C), 4'u32)]
  doAssert writes[^3 .. ^1] == @[(MACHW_INTC_BASE + 0x070, 4'u32),
    (MACHW_INTC_BASE + 0x074, 0x20000080'u32),
    (MACHW_INTC_BASE + 0x074, 0xA0000080'u32)]
  doAssert tickIndex <= 6
  checkPsUnchanged()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_idle_doze_wake_restores_saved_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
registers[MACHW_STATE_CNTRL_REG] = 3
doAssert wait_mac_goto_idle() == 0
doAssert set_mac_to_doze() == 0
doAssert bl_env[1] == 1
doAssert wakeup_from_doze_pre() == 0
doAssert bl_env[1] == 0
onWrite = proc(address: uint; value: uint32) =
  if address == MACHW_STATE_CNTRL_REG: registers[address] = value or 3
doAssert wait_mac_goto_prestate() == 0
doAssert writes[^1] == (MACHW_STATE_CNTRL_REG, 0x30'u32)
doAssert wakeup_from_doze_done() == 0
doAssert registers[MACHW_INTC_BASE + 0x048] == 0x12345678
doAssert bl_env[0] == 0xA1B2C303'u32 and timeouts.len == 0
checkPsUnchanged()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_restore_rejects_bad_state_and_reports_timeout(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for state in [16'u8, 255'u8]:
  setup()
  blDozeEnvView().preState = state
  doAssert wait_mac_goto_prestate() == 1
  doAssert writes.len == 0 and assertions.len == 1
  checkPsUnchanged()
setup()
blDozeEnvView().preState = 0
doAssert wait_mac_goto_prestate() == 0 and writes.len == 0

setup()
doAssert wait_mac_goto_prestate() == 1
doAssert timeouts.len == 1 and writes == @[(MACHW_STATE_CNTRL_REG, 0x30'u32)]
checkPsUnchanged()

setup()
registers[MACHW_STATE_CNTRL_REG] = 2
doAssert wakeup_from_doze_pre() == 1
doAssert bl_env[1] == 0 and timeouts.len == 1
doAssert writes[^1] == (MACHW_INTC_BASE + 0x074, 0xA0000080'u32)
checkPsUnchanged()
''')
