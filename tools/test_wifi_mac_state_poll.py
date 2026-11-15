"""Check MAC current-state polling independently of requested-state bits."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/tables
const WifiHwPollLimit = 4'u32
type
  Write = tuple[address: uint, value: uint32]
  Timeout = tuple[address, mask: uint32]
var
  ps: PsEnvView
  tx: tuple[resetInProgress: uint8]
  eventField: uint32
  registers = initTable[uint, uint32]()
  stateSamples: seq[uint32]
  stateReads: int
  writes: seq[Write]
  timeouts: seq[Timeout]
proc psEnvView(): ptr PsEnvView = addr ps
proc txControlEnv(): ptr typeof(tx) = addr tx
proc ke_evt_set(mask: uint32) = eventField = eventField or mask
proc regRead(address: uint): uint32 =
  if address == MACHW_STATE_CNTRL_REG:
    doAssert stateSamples.len != 0
    result = stateSamples[min(stateReads, stateSamples.high)]
    inc stateReads
  else:
    result = registers.getOrDefault(address)
proc regWrite(address: uint; value: uint32) =
  registers[address] = value
  writes.add((address, value))
proc noteHwWaitTimeout(address, mask: uint32) =
  timeouts.add((address, mask))
proc setup(samples: seq[uint32]) =
  registers.clear()
  stateSamples = samples
  stateReads = 0
  writes.setLen(0)
  timeouts.setLen(0)
  ps = default(PsEnvView)
  tx.resetInProgress = 0
  eventField = 0
  ps.enabled = 1
  ps.mode = 2
  ps.statusFlags = 0xA5A5000F'u32
  registers[MACHW_STATUS_REG] = 0x123456FF'u32
  registers[MACHW_INTC_IRQ_STAT_REG] = 0xABCDEF7F'u32
  registers[MACHW_INTC_UNMASK_REG] = 0x12345678'u32
  registers[MACHW_INTC_GEN_STATUS] = 0x080005A5'u32
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    polling = (FW / "global_state/late_forward_decls.nim").read_text()
    constants = (FW / "register_constants.nim").read_text().split("\nwhen defined", 1)[0]
    interrupt_constants = re.findall(r"^  MACHW_INTC_.*$", kernel, re.M)
    code = constants + "\nconst\n" + "\n".join(interrupt_constants) + "\n"
    code += layouts("PsEnvView") + PLATFORM
    for name in ["waitRegLowNibbleClear", "waitRegLowNibbleEquals"]:
        code += procedure(polling, name)
    return code + procedure(kernel, "hal_machw_disable_int") + procedure(kernel, "hal_machw_reset")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_clear_ignores_every_noncurrent_state_bit(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bit in 4 .. 31:
  for value in [1'u32 shl bit, not 0xF'u32]:
    for limit in [0'u32, 1, 4]:
      setup(@[value])
      doAssert waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG, limit)
      doAssert stateReads == 1 and writes.len == 0 and timeouts.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_equals_uses_only_the_current_state_nibble(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for current in 0'u32 .. 255:
  for wanted in 0'u32 .. 15:
    setup(@[0xA5A50000'u32 or current])
    let matched = (current and 0xF) == wanted
    doAssert waitRegLowNibbleEquals(MACHW_STATE_CNTRL_REG,
                                    0xFFFFFFF0'u32 or wanted, 1) == matched
    doAssert stateReads == (if matched: 1 else: 2) and writes.len == 0
    if matched:
      doAssert timeouts.len == 0
    else:
      doAssert timeouts == @[(MACHW_STATE_CNTRL_REG.uint32, 0xF'u32 or (wanted shl 8))]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_poll_budgets_and_timeout_diagnostics(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for limit in 0'u32 .. 4:
  for current in 1'u32 .. 15:
    setup(@[0xFFFFFFF0'u32 or current])
    doAssert not waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG, limit)
    doAssert stateReads == limit.int + 1
    doAssert timeouts == @[(MACHW_STATE_CNTRL_REG.uint32, 0xF'u32)]
    doAssert writes.len == 0

  for transitionAt in 0 .. limit.int + 1:
    var samples: seq[uint32]
    for index in 0 ..< transitionAt: samples.add(0xFFFFFFF3'u32)
    samples.add(0xFFFFFFF0'u32)
    setup(samples)
    let cleared = transitionAt <= limit.int
    doAssert waitRegLowNibbleClear(MACHW_STATE_CNTRL_REG, limit) == cleared
    doAssert stateReads == min(transitionAt + 1, limit.int + 1)
    doAssert timeouts.len == (not cleared).int

    for index in 0 ..< samples.len: samples[index] = samples[index] or 2
    setup(samples)
    doAssert waitRegLowNibbleEquals(MACHW_STATE_CNTRL_REG, 0xA2, limit) == cleared
    doAssert stateReads == min(transitionAt + 1, limit.int + 1)
    if cleared:
      doAssert timeouts.len == 0
    else:
      doAssert timeouts == @[(MACHW_STATE_CNTRL_REG.uint32, 0x20F'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_waits_for_current_state_and_preserves_other_fields(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for nextState in [0'u32, 0x10, 0x20, 0x30, 0xFFFFFFF0'u32]:
  setup(@[3'u32, nextState or 3, nextState])
  let before = ps
  hal_machw_reset()
  doAssert timeouts.len == 0 and stateReads == 3
  var expected = before
  expected.statusFlags = expected.statusFlags and not 4'u32
  doAssert ps == expected
  doAssert writes == @[
    (MACHW_STATUS_REG, 0x1234567F'u32),
    (MACHW_STATE_CNTRL_REG, 0'u32),
    (MACHW_DOZE_CNTRL2_REG, 0x7C'u32),
    (MACHW_DOZE_CNTRL2_REG, 0x1007C'u32),
    (MACHW_INTC_IRQ_STAT_REG, 0xABCDEF40'u32),
    (MACHW_INTC_FORCE_REG, 0xFFFFFFFF'u32),
    (MACHW_INTC_STATUS_ACK, 0x037FF187'u32),
    (MACHW_INTC_UNMASK_REG, 0x92345678'u32),
    (MACHW_INTC_GEN_STATUS, 0x880005A5'u32),
    (MACHW_STATUS_REG, 0x123456FF'u32)]
''')
