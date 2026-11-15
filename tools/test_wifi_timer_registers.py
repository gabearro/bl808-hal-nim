"""Check vendor timer addresses and unsigned nap intervals at their callers."""

from pathlib import Path
import re

import pytest

from test_wifi_coex_control import source as coex_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_trigger_owner import source as trigger_source


CONSTANTS = "const\n" + "\n".join(re.findall(
    r"^  (?:MACHW_BASE\*?|MACHW_INTC_BASE|MACHW_TIMLO_REG)\s+[^\n]+",
    (FW / "register_constants.nim").read_text(), re.M)) + "\n"
PLATFORM = r'''
var
  activeMask: uint32
  targets, times: array[9, uint32]
  reads: seq[uint]
  writes: seq[tuple[address: uint, value: uint32]]
  assertions: seq[tuple[condition, file: string, line: cint]]
  pendingSlot: int
  mutateMask: bool
proc regRead(address: uint): uint32 =
  reads.add(address)
  if address == MACHW_INTC_BASE + 0x8C:
    return activeMask
  if address == MACHW_BASE + 0x120:
    doAssert pendingSlot in 0 .. 8
    result = times[pendingSlot]
    pendingSlot = -1
    return
  doAssert address >= MACHW_BASE + 0x128 and address <= MACHW_BASE + 0x148
  doAssert (address and 3) == 0 and pendingSlot == -1
  pendingSlot = ((address - MACHW_BASE - 0x128) div 4).int
  result = targets[pendingSlot]
  if mutateMask: activeMask = 0x1FF
proc regWrite(address: uint; value: uint32) = writes.add((address, value))
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
proc setup(mask: uint32) =
  activeMask = mask
  targets = default(typeof(targets))
  times = default(typeof(times))
  reads.setLen(0)
  writes.setLen(0)
  assertions.setLen(0)
  pendingSlot = -1
  mutateMask = false
'''


def source() -> str:
    return (CONSTANTS + PLATFORM
            + procedure((FW / "platform_bl.nim").read_text(), "bl_nap_calculate")
            + procedure((FW / "kernel_mac_channel.nim").read_text(),
                        "blmac_abs_timer_set"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_absolute_timer_addresses_and_rejected_indices(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0)
for slot in 0'u32 .. 9'u32:
  blmac_abs_timer_set(slot, 0x10203040'u32 + slot)
  doAssert writes[^1] == (0x24B00128'u + slot.uint * 4, 0x10203040'u32 + slot)
doAssert writes.len == 10 and reads.len == 0 and assertions.len == 0
let before = writes
for slot in [10'u32, 0x7FFFFFFF'u32, 0x80000000'u32, high(uint32)]:
  blmac_abs_timer_set(slot, 0xFFFFFFFF'u32)
doAssert writes == before and reads.len == 0
doAssert assertions.len == 4
for assertion in assertions:
  doAssert assertion == ("reg_idx <= 9", "module", 0x26A0.cint)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nap_unsigned_intervals(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let cases = [
  (100'u32, 140'u32, 40'u32),
  (100'u32, 100'u32, high(uint32)),
  (101'u32, 100'u32, 0'u32),
  (1101'u32, 100'u32, 1000'u32),
  (1102'u32, 100'u32, 1001'u32),
  (0'u32, high(uint32), high(uint32)),
  (high(uint32), 0'u32, high(uint32) - 1),
  (0xFFFFFFF0'u32, 0x10'u32, 0xFFFFFFDF'u32),
  (0x10'u32, 0xFFFFFFF0'u32, 0xFFFFFFE0'u32)]
for slot in 0 .. 8:
  for value in cases:
    setup(1'u32 shl slot)
    times[slot] = value[0]
    targets[slot] = value[1]
    doAssert bl_nap_calculate() == value[2]
    doAssert reads == @[MACHW_INTC_BASE + 0x8C, MACHW_BASE + 0x128 + slot.uint * 4,
                       MACHW_BASE + 0x120]
    doAssert writes.len == 0 and assertions.len == 0
for mask in [0'u32, 1'u32 shl 9, 0xFFFFFE00'u32]:
  setup(mask)
  doAssert bl_nap_calculate() == high(uint32)
  doAssert reads == @[MACHW_INTC_BASE + 0x8C]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nap_mask_snapshot_and_per_timer_clock(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0x105)
mutateMask = true
targets[0] = 2000
times[0] = 1000
targets[2] = 3500
times[2] = 3200
targets[8] = 4000
times[8] = 4401
doAssert bl_nap_calculate() == 300
doAssert reads == @[MACHW_INTC_BASE + 0x8C,
  MACHW_BASE + 0x128, MACHW_BASE + 0x120,
  MACHW_BASE + 0x130, MACHW_BASE + 0x120,
  MACHW_BASE + 0x148, MACHW_BASE + 0x120]
doAssert activeMask == 0x1FF

setup(0x1FF)
var expectedReads = @[MACHW_INTC_BASE + 0x8C]
for slot in 0 .. 8:
  targets[slot] = 1000
  times[slot] = (1100 + slot).uint32
  expectedReads.add(MACHW_BASE + 0x128 + slot.uint * 4)
  expectedReads.add(MACHW_BASE + 0x120)
doAssert bl_nap_calculate() == 99
doAssert reads == expectedReads and writes.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_trigger_programs_real_timer_registers(tmp_path: Path, mode: str) -> None:
    code = trigger_source()
    setter = procedure((FW / "kernel_mac_channel.nim").read_text(), "blmac_abs_timer_set")
    code = CONSTANTS + code.replace(procedure(code, "blmac_abs_timer_set"), r'''
var timerWrites: seq[tuple[address: uint, value: uint32]]
proc assert_err(file, condition: cstring; line: int)
proc regWrite(address: uint; value: uint32) =
  timerWrites.add((address, value))
''' + setter, 1)
    run_program(tmp_path, mode, code + r'''
const timeouts = [200000'u32, 2000000, 400000, 200000, 50000]
for ac in 0 .. 4:
  for secondaryState in [0, 1]:
    setup(ac, host = true, secondaryState = secondaryState)
    timerWrites.setLen(0)
    txl_transmit_trigger()
    doAssert timerWrites == @[(0x24B00128'u + ac.uint * 4, timerBase + timeouts[ac])]
    doAssert routed.len == (secondaryState == 0).int
    doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_pta_uses_real_nap_intervals(tmp_path: Path, mode: str) -> None:
    code = coex_source()
    nap = procedure((FW / "platform_bl.nim").read_text(), "bl_nap_calculate")
    code = CONSTANTS + code.replace(procedure(code, "bl_nap_calculate"), r'''
var hardwareNow, hardwareTarget: uint32
proc regRead(address: uint): uint32 =
  doAssert not interrupts
  case address
  of MACHW_INTC_BASE + 0x8C: 1'u32
  of MACHW_BASE + 0x128: hardwareTarget
  of MACHW_BASE + 0x120: hardwareNow
  else: raiseAssert "unexpected timer read"
''' + nap, 1)
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  for expired in [false, true]:
    for interval in [1000'u32, 1001'u32]:
      setup(1, irq, true, @[120'u32, 122, 130])
      hardwareNow = if expired: 2000 + interval + 1 else: 2000
      hardwareTarget = if expired: 2000 else: 2000 + interval
      napDuration = interval
      coex_wifi_pta_forece_enable(false)
      checkFinished(0, 130)
      var expected = @["tick:120", "lock", "restore"]
      if interval > 1000: expected.add(@["rf-on", "sleep:1", "rf-off"])
      expected.add(@["tick:122", "log:610", "tick:130"])
      doAssert steps == expected
''')
