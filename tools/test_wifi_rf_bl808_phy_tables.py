"""Trace the two table-loading phases of BL808 WiFi demo phy.o:phy_init."""

import hashlib
import struct
from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type


TABLES = RF.with_name("rf_bl808_phy_tables.nim")
# SHA-256 of the copied little-endian words from agcmem.o and ldpcmem.o
# in demo Git blob a9935b475d2198000ae7b67d141f00767176a81a.
AGC_SHA = "34ab30c0f549d98a6de298d5b78cd9debedd1dbde183209e947815709e797446"
LDPC_SHA = "9ee8a06c193ec53d7c81f55b983f43e2c9495d91abb6e2370742c1e17adb951b"


def harness() -> str:
    core = RF.read_text()
    code = "".join(object_type(core, name) for name in
                   ("WifiModemBlock", "BbaAgcBlock", "WifiAgcMemoryRam"))
    for name in ("WifiModemBase", "BbaAgcBase", "WifiAgcMemoryBase", "WifiAgcMemoryWords"):
        code += "const " + next(line.strip() for line in core.splitlines()
                                if line.startswith(f"  {name} = ")) + "\n"
    for name in ("wifiModemRegs", "bbaAgcRegs", "wifiAgcMemoryRegs"):
        start = core.index(f"template {name}()")
        code += core[start:core.index("\n\n", start)] + "\n"
    return code + r'''
import std/strutils
var output: File
var gateReads, muxReads: int
proc record(op: char; address: uint; value: uint32) =
  output.writeLine(op, " ", toHex(address, 8), " ", toHex(value, 8))
proc volatileLoad(p: ptr uint32): uint32 =
  let address = cast[uint](p)
  # The second read sees unrelated bits change while the copy gate was open.
  case address
  of 0x24C0B390'u:
    result = [0xF00DC007'u32, 0xACACFFFF'u32][gateReads]
    inc gateReads
  of 0x24C00874'u:
    result = [0x80000001'u32, 0x73ABCDFF'u32][muxReads]
    inc muxReads
  of 0x24C00824'u: result = 0xFBA5210D'u32
  else: doAssert false, "unexpected read at " & toHex(address)
  record('R', address, result)
proc volatileStore(p: ptr uint32; value: uint32) = record('W', cast[uint](p), value)
proc updateReg32(p: ptr uint32; keep, bits: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or bits)
''' + f'include "{TABLES}"\n'


def check_ram(events, base, count, digest):
    assert [(op, addr) for op, addr, _ in events] == [
        ("W", base + 4 * i) for i in range(count)
    ]
    data = struct.pack(f"<{count}I", *(value for _, _, value in events))
    assert hashlib.sha256(data).hexdigest() == digest


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_native_phy_table_writes(tmp_path: Path, mode: str) -> None:
    trace = tmp_path / "table.trace"
    run_program(tmp_path, mode, harness() + f'output = open("{trace}", fmWrite)\n' + '''
programBl808PhyAgcTable()
output.writeLine("LDPC")
programBl808PhyLdpcTable()
output.close()
''')
    phases = trace.read_text().split("LDPC\n")
    agc, ldpc = [
        [(op, int(addr, 16), int(value, 16))
         for op, addr, value in (line.split() for line in phase.splitlines())]
        for phase in phases
    ]
    assert agc[:4] == [
        ("R", 0x24C0B390, 0xF00DC007), ("W", 0x24C0B390, 0xF00DD007),
        ("R", 0x24C00874, 0x80000001), ("W", 0x24C00874, 0xA0000001),
    ]
    check_ram(agc[4:-4], 0x24C0A000, 512, AGC_SHA)
    assert agc[-4:] == [
        ("R", 0x24C00874, 0x73ABCDFF), ("W", 0x24C00874, 0x53ABCDFF),
        ("R", 0x24C0B390, 0xACACFFFF), ("W", 0x24C0B390, 0xACACEFFF),
    ]
    assert ldpc[:5] == [
        ("W", 0x24C0B340, 0), ("W", 0x24C0B344, 0), ("W", 0x24C0B348, 0),
        ("R", 0x24C00824, 0xFBA5210D), ("W", 0x24C00824, 0xF8A5210D),
    ]
    check_ram(ldpc[5:], 0x24C09000, 190, LDPC_SHA)
