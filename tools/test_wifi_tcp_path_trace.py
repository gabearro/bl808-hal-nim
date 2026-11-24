"""Exercise the actual Nim TCP trace parser without firmware hardware."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program


MODULE = Path(__file__).resolve().parents[1] / "src/bl808/wifi/tcp_path_trace.nim"


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_tcp_path_header_only_trace(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, f'include "{MODULE}"\n' + r'''
var bytes: array[58, uint8] # Ethernet + IPv4 with options + minimum TCP header.
proc put16(at: int; value: uint16) =
  bytes[at] = (value shr 8).uint8
  bytes[at + 1] = (value and 255).uint8
proc put32(at: int; value: uint32) =
  put16(at, (value shr 16).uint16)
  put16(at + 2, (value and 65535).uint16)
put16(12, 0x0800)
bytes[14] = 0x46
put16(16, 24 + 28 + 5)
put16(18, 0x4f2e)
put16(20, 0x4000)
bytes[23] = 6
let tcp = 38
put16(tcp, 55000)
put16(tcp + 2, 80)
put32(tcp + 4, 0x12345678)
put32(tcp + 8, 0x98765432'u32)
bytes[tcp + 12] = 0x70
bytes[tcp + 13] = 0x18
let head = addr bytes[0]
let wireLen = 14 + 24 + 28 + 5
let packet = observeTcpPath(head, bytes.len.uint, wireLen.uint)
doAssert packet.ports == (55000'u32 or (80'u32 shl 16))
doAssert packet.seq == 0x12345678'u32 and packet.ack == 0x98765432'u32
doAssert packet.lengthId == 0x4f2e0005'u32 and packet.flags == 0x18
doAssert tcpPathEntry(packet, tcpTxConfirm, 5, 0x80800000'u32) ==
  [5'u32, 0x1805, packet.ports, packet.seq, packet.ack, packet.lengthId, 0x80800000'u32]
doAssert tcpPathEntry(packet, tcpTxConfirm, 5, 0x80010701'u32, 3, true) ==
  [5'u32, 0x03011805, packet.ports, packet.seq, packet.ack, packet.lengthId, 0x80010701'u32]
doAssert tcpPathEntry(packet, tcpTxDoorbell, high(uint32),
  tcpDoorbellDetail(0x1230, 2, 7, true)) ==
  [0xffffffff'u32, 0x180a, packet.ports, packet.seq, packet.ack, packet.lengthId, 0x070a1230'u32]
doAssert tcpDoorbellDetail(0, 0, 0xff, false) == 0xff000000'u32
doAssert tcpPathEntry(packet, tcpTxHardwareDone, 0, 0x80010700'u32)[1] == 0x180b'u32
for shortLength in 0 ..< bytes.len:
  doAssert observeTcpPath(head, shortLength.uint, wireLen.uint).ports == 0
doAssert observeTcpPath(nil, bytes.len.uint, wireLen.uint).ports == 0
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint - 1).ports == 0
put16(20, 0x2000)
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
put16(20, 1)
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
put16(20, 0)
bytes[tcp + 12] = 0x40
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
bytes[tcp + 12] = 0xf0
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
bytes[tcp + 12] = 0x70
put16(tcp + 2, 81)
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
put16(tcp, 80)
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports != 0
bytes[23] = 17
doAssert observeTcpPath(head, bytes.len.uint, wireLen.uint).ports == 0
''')
