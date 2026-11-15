"""Restore the caller's IRQ state when TX queue clearing exits through a callback error."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_reset import PLATFORM, SETUP


def source() -> str:
    code = "var haltReads, failReadAt: int\n" + PLATFORM
    code = code.replace(
        "proc regRead(address: uint): uint32 =\n",
        """proc regRead(address: uint): uint32 =
  if address == 0x24B08188'u:
    inc haltReads
    if haltReads == failReadAt:
      raise newException(ValueError, "halt observation stopped")
""",
        1,
    )
    tx = (FW / "tx_layer.nim").read_text()
    for name in [
        "txl_cntrl_halt_ac", "txlDetachAc", "txl_cntrl_flush_ac",
        "txl_cntrl_clear_ac", "txl_cntrl_clear_bcn_ac", "txl_cntrl_clear_all_ac",
    ]:
        code += procedure(tx, name)
    return code + SETUP + r'''
proc setupClear(enabled: bool) =
  setup()
  interrupts = enabled
  haltReads = 0
  failReadAt = -1
  statusSamples = @[0'u32, 0, 0, 0, 0]
proc clearQueues(operation: int; ac: uint8) =
  case operation
  of 0: discard txl_cntrl_clear_ac(ac)
  of 1: discard txl_cntrl_clear_bcn_ac()
  else: discard txl_cntrl_clear_all_ac()
proc order(operation: int; ac: uint8): seq[uint8] =
  case operation
  of 0: @[ac, ac]
  of 1: @[4'u8, 4]
  else: @[4'u8, 4, 0, 0, 1, 1, 2, 2, 3, 3]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_flush_error_restores_irq_for_each_clear_entry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for operation in 0 .. 2:
  for ac in 0'u8 .. 4:
    for enabled in [false, true]:
      let expected = order(operation, ac)
      for failAt in 1 .. expected.len:
        setupClear(enabled)
        var flushes = 0
        onFlush = proc(queue: uint8) =
          inc flushes
          if flushes == failAt:
            raise newException(ValueError, "completion callback stopped")
        var raised = false
        try: clearQueues(operation, ac)
        except ValueError: raised = true
        doAssert raised and flushes == failAt
        doAssert flushAcs == expected[0 ..< failAt]
        doAssert txActiveFlush == nil
        doAssert interrupts == enabled, "clear lost the incoming interrupt state"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_halt_error_restores_irq_before_any_later_queue_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for operation in 0 .. 2:
  for ac in 0'u8 .. 4:
    for enabled in [false, true]:
      let expected = order(operation, ac)
      for failAt in 1 .. expected.len div 2:
        setupClear(enabled)
        failReadAt = failAt
        var raised = false
        try: clearQueues(operation, ac)
        except ValueError: raised = true
        doAssert raised and haltReads == failAt
        doAssert statusIndex == failAt - 1
        doAssert flushAcs.len == 2 * (failAt - 1)
        if failAt > 1:
          doAssert flushAcs == expected[0 ..< 2 * (failAt - 1)]
        doAssert txActiveFlush == nil
        doAssert interrupts == enabled, "halt error kept interrupts masked"
''')
