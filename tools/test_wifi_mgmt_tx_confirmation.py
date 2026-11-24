"""Check that management TX diagnostics use the BL808 completion bits."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_management_completion_outcome(tmp_path: Path, mode: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    record = procedure(tx, "noteMgmtTxConfirm")
    code = r'''
type
  HostTxDescView = object
    frameLen: uint16
    staInfoIdx, vifIdx: uint8
    hwDesc, bufDesc: pointer
  HwDesc = object
    confirmStatus, status, flags: uint32
  Link = object
    macHeader: array[24, uint8]
proc hostTxLinkDescAt(p: pointer): ptr Link = cast[ptr Link](p)
proc hostTxHwDescAt(p: pointer): ptr HwDesc = cast[ptr HwDesc](p)
proc hostTxHeadThd(hw: ptr HwDesc): ptr HwDesc = hw
proc pointerAddrU32(p: pointer): uint32 = cast[uint](p).uint32
'''
    code += re.search(r"(?m)^const WifiTxFrameSuccessfulBit = .*$", tx)[0] + "\n"
    code += "var\n" + "".join(f"  {name}: uint32\n" for name in
                             sorted(set(re.findall(r"\bnimFwDbg\w+", record))))
    run_program(tmp_path, mode, code + record + r'''
var link: Link
var hw: HwDesc
var desc = HostTxDescView(hwDesc: addr hw, bufDesc: addr link, frameLen: 30)
for fc in [0xB0'u8, 0'u8]:
  link.macHeader[0] = fc
  for (flags, status) in [(0x80010700'u32, 0x80010700'u32),
                          (0x80800000'u32, 0x80800000'u32),
                          (0x80000000'u32, 0x40000000'u32),
                          (0x3C000000'u32, 0x00000000'u32),
                          (0x80010000'u32, 0x80800000'u32)]:
    hw.flags = flags
    hw.confirmStatus = status
    noteMgmtTxConfirm(addr desc, status, 0)
    noteMgmtTxConfirm(addr desc, status, 1)
    noteMgmtTxConfirm(addr desc, status, 2)
doAssert nimFwDbgAuthCfmFinalFail16 == 2 and nimFwDbgAssocCfmFinalFail16 == 2
doAssert nimFwDbgAuthCfmAckOk23 == 1 and nimFwDbgAssocCfmAckOk23 == 1
doAssert nimFwDbgAuthCfmAckFail == 2 and nimFwDbgAssocCfmAckFail == 2
doAssert nimFwDbgAuthCfmEvt == 5 and nimFwDbgAssocCfmEvt == 5
''')
