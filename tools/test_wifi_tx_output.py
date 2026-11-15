"""Check host TX admission and diagnostic reads before packet enqueue."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


TX = ROOT / "src/bl808/wifi/tx"


def source() -> str:
    layout = (TX / "layout.nim").read_text()
    types = (TX / "types_parts/packet_views.nim").read_text()
    views = r'''
type
  BlHw = object
  Pbuf = object
  BlTxCfm = object
{.emit: "volatile unsigned int nimfw_dbg_bl_output_eapol;".}
var
  hw: BlHw
  packets: array[5, PbufView]
  storage: array[5, array[1601, uint8]]
  enqueued: int
  protocol: uint16
template pbufView(p: pointer): ptr PbufView = cast[ptr PbufView](p)
template ethernetHeaderAt(p: pointer): ptr EthernetHeaderView = cast[ptr EthernetHeaderView](p)
proc bl_os_printf(text: cstring) = discard
proc enqueueTxPacket(isSta: cint; p: ptr Pbuf; v: ptr PbufView;
                     eth: ptr EthernetHeaderView; cfm: ptr BlTxCfm): int8 =
  inc enqueued
  protocol = eth.ethertype
  ErrOk
proc nimFwDbgDhcpRequestTxBreakpoint() = discard
proc nimFwDbgDhcpTxBreakpoint() = discard
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc allocPacket(size: int): ptr UncheckedArray[uint8] =
  result = cast[ptr UncheckedArray[uint8]](cMalloc(size.csize_t))
  zeroMem(result, size)
proc reset() =
  packets = default(typeof(packets))
  storage = default(typeof(storage))
  enqueued = 0
proc packet(index, size: int): ptr Pbuf =
  packets[index] = PbufView(payload: addr storage[index][0],
    len: size.uint16, totLen: size.uint16)
  cast[ptr Pbuf](addr packets[index])
'''
    native_views = (TX / "views.nim").read_text()
    views += "template ipv4HeaderAt" + native_views.split("template ipv4HeaderAt", 1)[1].split(
        "\ntemplate byteView", 1)[0] + procedure(native_views, "udpHeaderAt")
    helpers = "".join((TX / "packet_helpers_parts" / name).read_text() for name in [
        "endian.nim", "udp_checksum.nim", "dhcp_checksum_repair.nim", "dhcp_options.nim"])
    admission_body = (TX / "output_parts/admission.nim").read_text()
    output = procedure((TX / "output.nim").read_text(), "bl_output")
    diagnostics = (TX / "output_parts/protocol_diag.nim").read_text()
    diagnostics += (TX / "output_parts/dhcp_tx.nim").read_text()
    names = set(re.findall(r"\bnimFwDbg\w+", helpers + diagnostics))
    functions = set(re.findall(r"\b(nimFwDbg\w+)\(", helpers + diagnostics))
    arrays = {"nimFwDbgDhcpTxMsgHist": "array[256, uint32]",
              "nimFwDbgDhcpTxRaw": "array[512, uint8]"}
    debug = "\nvar\n" + "".join(
        f"  {name}: {arrays.get(name, 'uint32')}\n" for name in sorted(names - functions))
    return layout + types + views + debug + helpers + admission_body + diagnostics + output


CASES = {
    "invalid": r'''
for failure in 0..10:
  reset()
  let p = packet(0, 60)
  case failure
  of 0:
    packets[0].len = 13
    packets[0].totLen = 13
  of 1: packets[0].payload = nil
  of 2:
    packets[0].len = 1553
    packets[0].totLen = 1553
  of 3: packets[0].totLen = 59
  of 4: packets[0].totLen = 61
  of 5:
    discard packet(1, 20)
    packets[0].totLen = 80
    packets[0].next = addr packets[1]
    packets[1].payload = nil
  of 6:
    discard packet(1, 20)
    packets[0].totLen = 80
    packets[0].next = addr packets[1]
    packets[1].totLen = 21
  of 7:
    discard packet(1, 20)
    packets[0].next = addr packets[1]
  of 8:
    discard packet(1, 0)
    packets[0].next = addr packets[1]
    packets[1].next = addr packets[1]
  of 9:
    discard packet(1, 0)
    discard packet(2, 0)
    packets[0].next = addr packets[1]
    packets[1].next = addr packets[2]
    packets[2].next = addr packets[1]
  else:
    packets[0].len = 13
    packets[0].totLen = 60
    discard packet(1, 47)
    packets[0].next = addr packets[1]
  let before = packets
  let bytesBefore = storage
  doAssert bl_output(addr hw, 0, p, nil) == ErrBuf, "invalid TX accepted: " & $failure
  doAssert enqueued == 0 and packets == before and storage == bytesBefore

doAssert bl_output(nil, 0, packet(0, 60), nil) == ErrConn
doAssert bl_output(addr hw, 0, nil, nil) == ErrConn
''',
    "valid": r'''
for count in 1..5:
  for total in [14, 60, 1552]:
    reset()
    let p = packet(0, total)
    packets[0].len = 14
    var remaining = total - 14
    for i in 1..<count:
      let length = if i == count - 1: remaining else: 0
      discard packet(i, length)
      packets[i].totLen = remaining.uint16
      remaining -= length
      packets[i - 1].next = addr packets[i]
    if count == 1: packets[0].len = total.uint16
    storage[0][12] = 0x88
    storage[0][13] = 0x8e
    doAssert bl_output(addr hw, 0, p, nil) == ErrOk
    doAssert enqueued == 1 and protocol == 0x8e88
''',
    "diagnostic_bounds": r'''
# Exact-sized allocations let ASan check diagnostic reads and writes.
for size in 14..81:
  for transport in [6'u8, 17'u8]:
    reset()
    let bytes = allocPacket(size)
    bytes[12] = 8
    bytes[13] = 0
    if size > 14: bytes[14] = 0x45
    if size > 16: bytes[16] = 0
    if size > 17: bytes[17] = 40
    if size > 23: bytes[23] = transport
    if size > 34: bytes[34] = 0
    if size > 35: bytes[35] = (if transport == 6: 80'u8 else: 68'u8)
    packets[0] = PbufView(payload: bytes, len: size.uint16, totLen: size.uint16)
    doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
    doAssert enqueued == 1
    cFree(bytes)

# Variable IP header length and short declared TCP length must not expose a
# checksum field beyond the first segment or rewrite an incomplete header.
for ihl in [5, 6, 15]:
  for size in [42, 49, 50, 51, 52, 53, 54, 81]:
    reset()
    let bytes = allocPacket(size)
    bytes[12] = 8
    bytes[14] = (0x40 or ihl).uint8
    bytes[17] = (ihl * 4 + 16).uint8
    bytes[23] = 6
    if 14 + ihl * 4 + 1 < size: bytes[14 + ihl * 4 + 1] = 80
    packets[0] = PbufView(payload: bytes, len: size.uint16, totLen: size.uint16)
    let checksumRepairs = nimFwDbgTxTcp80ChecksumRepair
    doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
    doAssert nimFwDbgTxTcp80ChecksumRepair == checksumRepairs
    cFree(bytes)
''',
    "complete_diagnostics": r'''
reset()
let tcp = allocPacket(54)
tcp[12] = 8
tcp[14] = 0x45
tcp[17] = 40
tcp[23] = 6
tcp[35] = 80
tcp[46] = 0x50
packets[0] = PbufView(payload: tcp, len: 54, totLen: 54)
let tcpCount = nimFwDbgTxTcp80
doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
doAssert nimFwDbgTxTcp80 == tcpCount + 1
doAssert nimFwDbgTxTcp80ChecksumVerifyAfter == high(uint16).uint32
doAssert loadBe16(tcp, 50) == 0xAF95
cFree(tcp)

reset()
let udp = allocPacket(286)
udp[12] = 8
udp[14] = 0x45
udp[16] = 1
udp[17] = 16
udp[23] = 17
udp[35] = 68
udp[37] = 67
udp[39] = 252
udp[278] = 0x63
udp[279] = 0x82
udp[280] = 0x53
udp[281] = 0x63
udp[282] = 53
udp[283] = 1
udp[284] = 3
udp[285] = 255
packets[0] = PbufView(payload: udp, len: 286, totLen: 286)
let dhcpCount = nimFwDbgDhcpTx
doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
doAssert enqueued == 1 and nimFwDbgDhcpTx == dhcpCount + 1
doAssert (nimFwDbgDhcpTxMsg and 255) == 3
doAssert verifyUdpPacket(udp, 14, 34, 252) == high(uint16)
cFree(udp)
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_output(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_admitted_chain_copy(tmp_path: Path, mode: str) -> None:
    from test_wifi_tx_submission import CHECKS, source as submission_source

    code = submission_source("chained_packet").split(CHECKS["chained_packet"], 1)[0]
    code = code.replace("array[4, array[256, uint8]]", "array[4, array[1600, uint8]]")
    code += (TX / "output_parts/admission.nim").read_text()
    code += r'''
for size in [14, 60, 1552]:
  install()
  incoming = true
  enabled = true
  let bytes = addr packetBytes[0][0]
  packets[0] = PbufView(payload: bufferAt(bytes, 48), len: 14, totLen: size.uint16)
  if size > 14:
    packets[0].next = addr packets[1]
    packets[1] = PbufView(payload: addr packetBytes[1][0],
      len: (size - 14).uint16, totLen: (size - 14).uint16)
    for i in 0..<(size - 14): packetBytes[1][i] = (i mod 251).uint8
  let ethernet = ethernetHeaderAt(packets[0].payload)
  ethernet.dst[5] = 7
  ethernet.ethertype = 0x8e88
  doAssert txPbufAdmissible(addr packets[0])
  packets[0].payload = bytes
  packets[0].len += 48
  packets[0].totLen += 48
  let header = txHdrView(bytes)
  header.pbuf = addr packets[0]
  header.len = packets[0].totLen
  listPushBack(addr wifi_hw.stas[0].waitingList, header)
  txCntrlStaTrigger = 1
  bl_tx_try_flush(0, nil)
  doAssert publications.len == 1 and publications[0].length == (size - 14).uint32
  doAssert publications[0].marker == 7 and released[0] == 1
  let copied = cast[ptr UncheckedArray[uint8]](txbufHostBuf(publications[0].buffer))
  for i in 0..<(size - 14): doAssert copied[62 + i] == (i mod 251).uint8
  doAssert enabled
'''
    run_program(tmp_path, mode, code)
