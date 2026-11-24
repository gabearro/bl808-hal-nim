"""Verify the BL808 command strobe with sticky TRIGGER readback."""

from pathlib import Path
import shutil
import subprocess

import pytest


HAL = Path(__file__).resolve().parents[1] / "src/bl808"


def test_sticky_trigger_does_not_delay_or_suppress_next_command(tmp_path):
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")

    # Replace only volatile loads/stores; exercise the real send and poll loops.
    mmio = (HAL / "mmio.nim").read_text()
    assert "from std/volatile import" in mmio
    (tmp_path / "mmio.nim").write_text(mmio.replace("from std/volatile import", "from bus import"))
    (tmp_path / "bus.nim").write_text("""
type Access* = tuple[op: char, address: uint, value: uint32]
var expected*: seq[Access]
var cursor*: int

proc next(op: char, address: uint): uint32 =
  doAssert cursor < expected.len, "unexpected MMIO after command completed"
  let access = expected[cursor]
  doAssert (op, address) == (access.op, access.address), "unexpected MMIO at " & $cursor
  inc cursor
  access.value

proc volatileLoad*[T](p: ptr T): T = T(next('R', cast[uint](p)))
proc volatileStore*[T](p: ptr T, value: T) =
  doAssert next('W', cast[uint](p)) == uint32(value)
""")
    shutil.copyfile(HAL / "flash.nim", tmp_path / "flash.nim")
    probe = tmp_path / "probe.nim"
    probe.write_text("""
include flash
import bus

proc expectCommand(previous, owner, command, control: uint32) =
  expected.add @[
    ('R', SfCtrlIfSahb0, previous),                 # pre-strobe BUSY poll
    ('R', SfCtrlCfg1, owner),
    ('W', SfCtrlCfg1, SfCtrlCfg1IfEn),
    ('R', SfCtrlIfSahb0, previous),
    ('W', SfCtrlIfSahb0, previous and not 2'u32),   # clear before staging
    ('W', SfCtrlIfSahb1, command),
    ('W', SfCtrlIfSahb2, 0'u32),
    ('W', SfCtrlIfSahb0, control),
    ('W', SfCtrlIfSahb0, control or 2'u32),        # fresh rising edge
    ('R', SfCtrlIfSahb0, control or 3'u32),        # BUSY and TRIGGER
    ('R', SfCtrlIfSahb0, control or 2'u32)]        # idle, TRIGGER still set

expectCommand(0, SfCtrlCfg1OwnerIahb, 0x06000000, 0x08000000)
sfCtrlSendCmd(FlashCmdWriteEn)
doAssert cursor == expected.len
expectCommand(0x08000002, SfCtrlCfg1IfEn, 0x9F000000'u32, 0x09000008)
sfCtrlSendCmd(FlashCmdReadId, dataLen = 3)
doAssert cursor == expected.len
""")
    subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{HAL}", f"--nimcache:{tmp_path / 'cache'}", str(probe)],
        cwd=tmp_path, check=True,
    )
