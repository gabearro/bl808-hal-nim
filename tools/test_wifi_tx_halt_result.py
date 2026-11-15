"""Bound TX halt polling without returning DMA-owned queues to software."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_reset import PLATFORM, SETUP


def source(tx: str | None = None) -> str:
    tx = tx if tx is not None else (FW / "tx_layer.nim").read_text()
    code = "var invalidations: int\n" + PLATFORM
    code = code.replace(
        procedure(code, "txlInvalidateDmaAll"),
        "proc txlInvalidateDmaAll() = inc invalidations\n",
    )
    for name in [
        "txl_cntrl_halt_ac", "txlDetachAc", "txl_cntrl_flush_ac",
        "txl_cntrl_clear_ac", "txl_cntrl_clear_bcn_ac", "txl_cntrl_clear_all_ac",
    ]:
        code += procedure(tx, name)
    return code + SETUP + r'''
proc halt(ac: uint8): bool =
  when compiles(txl_cntrl_halt_ac(ac) == true):
    txl_cntrl_halt_ac(ac)
  else:
    txl_cntrl_halt_ac(ac)
    true
proc prepare(incoming: bool) =
  setup()
  interrupts = incoming
  events = 0x4000
  invalidations = 0
  statusSamples.setLen(0)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_stuck_ac_stops_at_budget_without_clearing_halt(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in 0'u8 .. 4:
  for state in 1'u32 .. 3:
    for incoming in [false, true]:
      prepare(incoming)
      let before = control
      let oldBuffers = buffers
      let oldConfirms = confirms
      for _ in 0'u32 .. WifiHwPollLimit:
        statusSamples.add(state shl shifts[ac])
      doAssert not halt(ac)
      doAssert statusIndex == WifiHwPollLimit.int + 1
      doAssert writes == @[(0x24B08180'u, triggers[ac])]
      doAssert waitTimeouts == @[(0x24B08188'u32, 3'u32 shl shifts[ac])]
      doAssert operations == @["disable-mac"] and invalidations == 1
      var expected = before
      expected.resetInProgress = 1
      doAssert control == expected and buffers == oldBuffers and confirms == oldConfirms
      doAssert flushAcs.len == 0 and txActiveFlush == nil
      doAssert events == 0x80004000'u32 and interrupts == incoming
      for other in 0'u8 .. 4:
        doAssert not halt(other)
      doAssert statusIndex == WifiHwPollLimit.int + 1 and writes.len == 1
      doAssert waitTimeouts.len == 1 and invalidations == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_last_budgeted_sample_can_complete(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in 0'u8 .. 4:
  for incoming in [false, true]:
    prepare(incoming)
    let before = control
    let unrelated = 0xFFFFFFFF'u32 and not (3'u32 shl shifts[ac])
    for _ in 0'u32 ..< WifiHwPollLimit:
      statusSamples.add(unrelated or (2'u32 shl shifts[ac]))
    statusSamples.add(unrelated)
    doAssert halt(ac)
    doAssert statusIndex == WifiHwPollLimit.int + 1
    doAssert writes == @[(0x24B08180'u, triggers[ac]), (0x24B08184'u, triggers[ac])]
    doAssert control == before and waitTimeouts.len == 0 and invalidations == 0
    doAssert events == 0x4000 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_clear_stops_before_the_failed_ac_is_detached(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
const order = [4'u8, 0, 1, 2, 3]
for operation in 0 .. 2:
  for failedAt in 0 .. (if operation == 2: 4 else: 0):
    for incoming in [false, true]:
      prepare(incoming)
      let failedAc = if operation == 0: 2'u8
                     elif operation == 1: 4'u8
                     else: order[failedAt]
      let before = control.ac[failedAc]
      let oldBuffer = buffers.backupQueues[failedAc]
      let oldConfirm = confirms[failedAc]
      for _ in 0 ..< failedAt: statusSamples.add(0)
      for _ in 0'u32 .. WifiHwPollLimit:
        statusSamples.add(3'u32 shl shifts[failedAc])
      let complete = case operation
        of 0: txl_cntrl_clear_ac(failedAc)
        of 1: txl_cntrl_clear_bcn_ac()
        else: txl_cntrl_clear_all_ac()
      doAssert not complete and control.resetInProgress == 1
      doAssert control.ac[failedAc] == before
      doAssert buffers.backupQueues[failedAc] == oldBuffer
      doAssert confirms[failedAc] == oldConfirm
      doAssert flushAcs.len == failedAt * 2
      for index in 0 ..< failedAt:
        doAssert flushAcs[index * 2] == order[index]
        doAssert flushAcs[index * 2 + 1] == order[index]
      doAssert writes[^1] == (0x24B08180'u, triggers[failedAc])
      doAssert invalidations == 1 and txActiveFlush == nil
      doAssert interrupts == incoming and events == 0x80004000'u32
''')
