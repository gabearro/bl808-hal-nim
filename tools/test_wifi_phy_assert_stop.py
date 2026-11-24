"""Verify the RF assertion wrapper stops by default like the vendor archive."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure


ROOT = Path(__file__).resolve().parents[1]
ASSERTS = ROOT / "src/bl808/wifi/fw/global_state/rf_core_init_asserts.nim"


@pytest.mark.parametrize("debug_continue", [False, True])
def test_phy_error_assertion_requires_explicit_debug_bypass(
    tmp_path: Path, debug_continue: bool
) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = r'''
import os, strutils
type ModemRegs = object
  versionScratch3c: uint32
var
  modem: ModemRegs
  nimFwDbgRfAssertCount, nimFwDbgRfAssertLine, nimFwDbgRfAssertReg3c: uint32
proc wifiModemRegs(): ptr ModemRegs = addr modem
proc volatileLoad(reg: ptr uint32): uint32 = reg[]
proc nimFwConnectTrace2U32(message: string; first, second: uint32) = discard
'''
    source += procedure(ASSERTS.read_text(), "wrapPhyAssertErr")
    source += r'''
wrapPhyAssertErr(nil, nil, parseInt(paramStr(1)).cint)
doAssert nimFwDbgRfAssertCount == 1
'''
    path = tmp_path / "phy_assert.nim"
    path.write_text(source)
    binary = tmp_path / "phy_assert"
    flags = ["-d:bl808WifiDebugContinuePhyAssert"] if debug_continue else []
    compile_result = subprocess.run(
        [nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{binary}", *flags, str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=90,
    )
    assert compile_result.returncode == 0, compile_result.stdout

    known_lines = (586, 0x20FA, 0x2A60)
    for line in (*known_lines, 1):
        try:
            run = subprocess.run([str(binary), str(line)], timeout=0.3,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except subprocess.TimeoutExpired:
            returned = False
        else:
            assert run.returncode == 0, run.stdout
            returned = True
        assert returned == (debug_continue and line in known_lines), line
