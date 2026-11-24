"""The optional host TX trace records bounded packet metadata, not payload."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


TX = Path(__file__).resolve().parents[1] / "src/bl808/wifi/tx"


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_host_tx_trace(mode: str, tmp_path: Path) -> None:
    endian = (TX / "packet_helpers_parts/endian.nim").read_text()
    trace = (TX / "confirm_parts/data_trace.nim").read_text()
    run_program(tmp_path, mode, procedure(endian, "loadBe16") + trace + r"""
proc setBe16(data: var openArray[uint8]; offset: int; value: uint16) =
  data[offset] = (value shr 8).uint8
  data[offset + 1] = (value and 0xFF).uint8

var shortHeader: array[33, uint8]
noteHostDataTxConfirm(addr shortHeader[0], shortHeader.len.uint, high(uint32), 0, 1)
noteHostDataTxConfirm(nil, 68, high(uint32), 0, 2)
doAssert hostDataTxConfirmCount == 0

var udp: array[46, uint8]
udp.setBe16(12, 0x0800)
udp[14] = 0x45
udp.setBe16(16, 32)
udp.setBe16(18, 0xBEEF)
udp.setBe16(20, 0x4000) # DF is not a fragment.
udp[23] = 17
udp.setBe16(34, 65000)
udp.setBe16(36, 59999)
udp.setBe16(38, 12)
udp[42] = 0xAA
noteHostDataTxConfirm(addr udp[0], udp.len.uint, 0x80010701'u32, 3, 0xFEDCBA98'u32)
doAssert hostDataTxConfirmCount == 1
doAssert hostDataTxConfirmLog[0] == [
  65000'u32 or (59999'u32 shl 16), 0x0020BEEF'u32, 0x00030011'u32,
  0xFEDCBA98'u32, 0x80010701'u32]

for variant in 0 ..< 7:
  var bad = udp
  var length = bad.len.uint
  case variant
  of 0: bad.setBe16(12, 0x86DD)
  of 1: bad[14] = 0x44
  of 2: bad[14] = 0x65
  of 3: bad.setBe16(20, 1)
  of 4: bad.setBe16(38, 13)
  of 5: dec length
  else: bad[23] = 1
  noteHostDataTxConfirm(addr bad[0], length, high(uint32), 0, 0)
doAssert hostDataTxConfirmCount == 1

var tcp: array[64, uint8]
tcp.setBe16(12, 0x0800)
tcp[14] = 0x46 # IPv4 options.
tcp.setBe16(16, 50)
tcp.setBe16(18, 0xFEED)
tcp[23] = 6
tcp.setBe16(38, 80)
tcp.setBe16(40, 50001)
tcp.setBe16(42, 0x1234)
tcp.setBe16(44, 0x5678)
tcp[50] = 0x70 # 28-byte TCP header would overrun the IP frame.
noteHostDataTxConfirm(addr tcp[0], tcp.len.uint, 0x80800001'u32, 2, 123)
doAssert hostDataTxConfirmCount == 1
tcp[50] = 0x60
tcp[51] = 0x19
noteHostDataTxConfirm(addr tcp[0], tcp.len.uint, 0x80800001'u32, 2, 124)
doAssert hostDataTxConfirmCount == 2
doAssert hostDataTxConfirmLog[1] == [
  80'u32 or (50001'u32 shl 16), 0x0032FEED'u32, 0x00021906'u32,
  0x12345678'u32, 0x80800001'u32]

for i in 2 .. HostDataTxTraceEntries:
  noteHostDataTxConfirm(addr udp[0], udp.len.uint, i.uint32, 0, i.uint32)
doAssert hostDataTxConfirmCount == HostDataTxTraceEntries.uint32 + 1
doAssert hostDataTxConfirmLog[0][3] == HostDataTxTraceEntries.uint32
doAssert hostDataTxConfirmLog[0][4] == HostDataTxTraceEntries.uint32
doAssert hostDataTxConfirmLog[1][4] == 0x80800001'u32
""")
