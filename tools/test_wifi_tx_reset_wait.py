"""Keep TX ownership intact when the DMA-idle handshake cannot complete."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_reset_timeout import source as recovery_source
from test_wifi_tx_reset_owner import source


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_stalled_wait_respects_budget_and_retains_queues(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for status in [0'u32, 1, 0x7FFF, 0xFFFE, 0xFFFF0000'u32, 0xFFFFFFFE'u32]:
    setup()
    resetMode = true
    interrupts = enabled
    resetSamples = @[status]
    maxResetStatusReads = WifiHwPollLimit.int + 1
    events = 0x04000000'u32
    let oldControl = control
    let oldBuffers = buffers
    let oldConfirms = confirms
    let oldEpoch = txResetEpoch
    txl_reset()
    var expected = oldControl
    expected.resetInProgress = 1
    doAssert control == expected and buffers == oldBuffers and confirms == oldConfirms
    doAssert writes.len == 0 and flushAcs.len == 0
    doAssert operations == @["disable-mac"]
    doAssert waitTimeouts == @[(0x24A00010'u32, 0xFFFF'u32)]
    doAssert resetStatusReads == WifiHwPollLimit.int + 1
    doAssert events == 0x84000000'u32
    doAssert interrupts == enabled and not txResetActive and txResetEpoch == oldEpoch + 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_all_low_status_bits_must_be_set(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(check_initialization=True) + r'''
for highBits in [0'u32, 0xABCD0000'u32, 0xFFFF0000'u32]:
  setup()
  resetMode = true
  resetSamples = @[0xFFFE'u32 or highBits, 0x7FFF'u32 or highBits, 0xFFFF'u32 or highBits]
  doAssert txl_reset()
  doAssert resetStatusReads == 3 and flushAcs.len == 10
  doAssert waitTimeouts.len == 0 and control.resetInProgress == 0
  doAssert not txResetActive and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_last_allowed_read_and_later_retry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(check_initialization=True) + r'''
setup()
resetMode = true
for index in 0 ..< WifiHwPollLimit.int: resetSamples.add(0)
resetSamples.add(0xFFFF)
doAssert txl_reset()
doAssert resetStatusReads == WifiHwPollLimit.int + 1 and waitTimeouts.len == 0

setup()
resetMode = true
for index in 0 .. WifiHwPollLimit.int: resetSamples.add(0)
resetSamples.add(0xFFFF)
let before = control
doAssert not txl_reset()
doAssert control.seqCounter == before.seqCounter and control.packetCounter == before.packetCounter
doAssert control.resetInProgress == 1 and not txResetActive
let failedEpoch = txResetEpoch
resetSamples = @[0xFFFF'u32]
resetStatusReads = 0
events = events and not 0x80000000'u32
doAssert txl_reset()
doAssert txResetEpoch == failedEpoch + 1 and flushAcs.len == 10
doAssert control.resetInProgress == 0 and not txResetActive
doAssert control.seqCounter == before.seqCounter
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reentrant_reset_reports_incomplete_without_replaying(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
resetMode = true
events = 0
var entered = false
onFlush = proc(ac: uint8) =
  if entered: return
  entered = true
  let epoch = txResetEpoch
  let reads = resetStatusReads
  let count = operations.len
  doAssert not txl_reset()
  doAssert txResetEpoch == epoch and resetStatusReads == reads
  doAssert operations.len == count and txResetActive and control.resetInProgress == 1
  doAssert (events and 0x80000000'u32) != 0
doAssert txl_reset()
doAssert entered and not txResetActive and control.resetInProgress == 0
doAssert flushAcs.len == 10 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callers_do_not_publish_completion_on_tx_failure(tmp_path: Path, mode: str) -> None:
    code = recovery_source()
    original = procedure(code, "txl_reset")
    code = code.replace(original, r'''
proc txl_reset(): bool =
  doAssert not interrupts
  steps.add("tx")
  tx.resetInProgress = 1
  ke_evt_set(0x80000000'u32)
  false
''', 1)
    run_program(tmp_path, mode, code + r'''
for enabled in [false, true]:
  resetFixture(enabled, false)
  let before = mm
  doAssert not mm_force_idle_req()
  doAssert steps == @["rx", "tx"] and mm == before and interrupts == enabled
  doAssert tx.resetInProgress == 1 and (eventField and 0x80000000'u32) != 0

  resetFixture(enabled, false)
  bl_reset_evt()
  doAssert steps == @["clear:2147483648", "rx", "tx"]
  doAssert interrupts == enabled and tx.resetInProgress == 1
  doAssert (eventField and 0x80000000'u32) != 0
''')
