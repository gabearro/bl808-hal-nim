"""Run host station entry points with controlled firmware command results."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

MAIN = ROOT / "src/bl808/wifi/main"
PLATFORM = r"""
type
  BlHw = object
  SmAbortCfm = object
  Cfg80211ConnectParams = object
var
  hardware: BlHw
  commandResult: cint
  response = 42'u8
  calls: int
proc hwPtr(): ptr BlHw = addr hardware
proc ptrAt(base: pointer; offset: uint): pointer = cast[pointer](cast[uint](base) + offset)
proc zero(base: pointer; length: int) = zeroMem(base, length)
proc loadU8(base: pointer; offset: uint): uint8 = cast[ptr uint8](ptrAt(base, offset))[]
proc storeU8(base: pointer; offset: uint; value: uint8) = cast[ptr uint8](ptrAt(base, offset))[] = value
proc storeU16(base: pointer; offset: uint; value: uint16) = cast[ptr uint16](ptrAt(base, offset))[] = value
proc storeU32(base: pointer; offset: uint; value: uint32) = cast[ptr uint32](ptrAt(base, offset))[] = value
proc storePtr(base: pointer; offset: uint; value: pointer) = cast[ptr pointer](ptrAt(base, offset))[] = value
proc bl_send_sm_connect_abort_req(hw: ptr BlHw; cfm: ptr SmAbortCfm): cint =
  inc calls
  storeU8(cfm, 0, response)
  commandResult
proc bl_cfg80211_connect(hw: ptr BlHw; request: ptr Cfg80211ConnectParams): cint =
  inc calls
  commandResult
proc bl_send_sm_disconnect_req(hw: ptr BlHw): cint =
  inc calls
  commandResult
proc bl_send_start(hw: ptr BlHw): cint =
  inc calls
  commandResult
"""


def program(case: str, status: int) -> str:
    source = "".join((MAIN / "layout_parts" / name).read_text() for name in [
        "status_values.nim", "confirmations.nim", "connect_request.nim"])
    source += PLATFORM
    source += procedure((MAIN / "host_ops_parts/connect_abort.nim").read_text(), "bl_main_connect_abort")
    source += procedure((MAIN / "host_ops_parts/station.nim").read_text(), "bl_main_connect")
    source += procedure((MAIN / "host_ops_parts/station.nim").read_text(), "bl_main_disconnect")
    source += procedure((MAIN / "host_ops_parts/radio_controls.nim").read_text(), "bl_main_phy_up")
    source += f"\ncommandResult = {status}\n"
    if case == "abort":
        source += """
var output = 77'u8
doAssert bl_main_connect_abort(addr output) == commandResult
doAssert output == (if commandResult == 0: response else: 77'u8),
  "failed transport published a confirmation byte"
"""
    elif case == "null_abort":
        source += "doAssert bl_main_connect_abort(nil) != 0\ndoAssert calls == 0\n"
    elif case == "connect":
        source += "doAssert bl_main_connect(nil, 0, nil, 0, nil, 0, nil, 0, 0, 0) == commandResult\n"
    elif case == "disconnect":
        source += "doAssert bl_main_disconnect() == commandResult\n"
    elif case == "start":
        source += "doAssert bl_main_phy_up() == commandResult\n"
    if case != "null_abort": source += "doAssert calls == 1\n"
    return source


@pytest.mark.parametrize("case", ["abort", "connect", "disconnect", "start", "null_abort"])
@pytest.mark.parametrize("status", [0, -5, -32, -110])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_command_results(tmp_path: Path, case: str, status: int, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    source = tmp_path / "station_results.nim"
    source.write_text(program(case, status))
    flags = {"checked": [], "release": ["-d:release"],
             "asan": ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
                             *flags, "--checks:on", f"--nimcache:{tmp_path / 'cache'}",
                             f"-o:{tmp_path / 'test'}", str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
