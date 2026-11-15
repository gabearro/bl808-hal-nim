"""Exercise nested TX reset calls without replaying an in-progress reset."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_reset import PLATFORM, SETUP


def source(*, check_initialization: bool = False, real_seed: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    seed_name = "ipcTxHwDescWordHalfword"
    platform = PLATFORM
    if check_initialization:
        platform = platform.replace(
            procedure(platform, seed_name),
            f"proc {seed_name}(ac: uint32): uint16 =\n"
            "  doAssert control.resetInProgress == 1\n"
            "  (0x1234 + ac).uint16\n",
        )
    if real_seed:
        table_start = layout.index("  IpcTxHwDescWordTableView ")
        table_end = layout.index("\n\n", table_start)
        support = "type\n" + layout[table_start:table_end] + r'''
var
  seedTable: IpcTxHwDescWordTableView
  seedReads: seq[int]
template ipcTxHwDescWordTable(): ptr IpcTxHwDescWordTableView = addr seedTable
'''
        platform = platform.replace("proc volatileLoad(", support + "\nproc volatileLoad(", 1)
        platform = platform.replace(
            "proc volatileLoad(p: ptr uint32): uint32 =\n",
            "proc volatileLoad(p: ptr uint32): uint32 =\n"
            "  for i in 0 .. 4:\n"
            "    if p == addr seedTable.descriptorWords[i]:\n"
            "      seedReads.add(i)\n"
            "      return p[]\n",
            1,
        )
        platform = platform.replace(procedure(platform, seed_name), procedure(layout, seed_name))
        platform += r'''
var txlCntrlBusy: uint16
proc txSecurityReset() = discard
proc txl_hwdesc_init() = discard
proc txl_buffer_init() = discard
proc txl_frame_init(preserve: uint32) = discard
'''
    tx = (FW / "tx_layer.nim").read_text()
    return platform + "".join(procedure(tx, name) for name in [
        "txl_buffer_reinit", "txl_reset",
    ] + (["txl_cntrl_init"] if real_seed else [])) + SETUP


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_reentry_is_coalesced(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for boundary in 1 .. 10:
  for enabled in [false, true]:
    setup()
    resetMode = true
    interrupts = enabled
    var nested = false
    onFlush = proc(ac: uint8) =
      if nested or flushAcs.len != boundary: return
      nested = true
      let before = operations.len
      txl_reset()
      doAssert operations.len == before, "nested reset repeated state changes"
      doAssert control.resetInProgress == 1
    txl_reset()
    doAssert nested and interrupts == enabled
    doAssert resetStatusReads == 3 and flushAcs.len == 10
    doAssert control.seqCounter == 0xFFF and control.resetInProgress == 0
    doAssert txActiveFlush == nil and not txResetActive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_keeps_flag_until_initialization_finishes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(check_initialization=True) + r'''
for enabled in [false, true]:
  setup()
  resetMode = true
  interrupts = enabled
  txl_reset()
  doAssert interrupts == enabled and control.resetInProgress == 0
  doAssert control.seqCounter == 0xFFF and control.packetCounter == 0
  for ac in 0 .. 4:
    doAssert control.ac[ac].packetCount == (0x1234 + ac).uint16
    doAssert control.ac[ac].current == nil
    doAssert control.ac[ac].pending.first == nil
    doAssert buffers.backupQueues[ac].first == nil
  # A later independent reset must still run normally.
  setup()
  resetMode = true
  txl_reset()
  doAssert flushAcs.len == 10 and resetStatusReads == 3
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_restores_irq_after_interrupted_flush(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  setup()
  resetMode = true
  interrupts = enabled
  onFlush = proc(ac: uint8) =
    raise newException(ValueError, "stop during reset")
  var caught = false
  try:
    txl_reset()
  except ValueError:
    caught = true
  doAssert caught and interrupts == enabled
  # An incomplete reset must not advertise TX availability.
  doAssert control.resetInProgress == 1 and not txResetActive
  # A later call can retry the reset after the interrupted one has unwound.
  onFlush = nil
  flushAcs.setLen(0)
  operations.setLen(0)
  resetStatusReads = 0
  txl_reset()
  doAssert flushAcs.len == 10 and interrupts == enabled
  doAssert control.resetInProgress == 0 and not txResetActive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_init_and_reset_read_descriptor_word_values(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_seed=True) + r'''
for reset in [false, true]:
  for change in 0'u32 .. 1:
    setup()
    resetMode = reset
    seedReads.setLen(0)
    seedTable.descriptorWords = [0xABCD1234'u32, 0xDEAD0000'u32,
      0x8000FFFF'u32, 0x12348000'u32, 0x620155AA'u32]
    for i in 0 .. 4:
      seedTable.descriptorWords[i] = seedTable.descriptorWords[i] xor change
    if reset: txl_reset()
    else: txl_cntrl_init()
    doAssert seedReads == @[0, 1, 2, 3, 4], "init/reset did not read the MMIO words"
    for i in 0 .. 4:
      doAssert control.ac[i].packetCount ==
        (seedTable.descriptorWords[i] and 0xFFFF'u32).uint16
''')
