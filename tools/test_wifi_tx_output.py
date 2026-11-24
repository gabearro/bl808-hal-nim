"""Check host TX admission and diagnostic reads before packet enqueue."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


TX = ROOT / "src/bl808/wifi/tx"
HOST_TABLE = (
    f'from "{TX.parent / "host_table_layout"}" import '
    "WifiHostStaTableCount, WifiHostStaTableOffset, WifiHostStaEntrySize, WifiHostVifCount\n"
)


def output_source(enqueue: str = "") -> str:
    helpers = (TX.parent / "dhcp_flow_trace.nim").read_text()
    helpers += "".join((TX / "packet_helpers_parts" / name).read_text() for name in [
        "endian.nim", "udp_checksum.nim", "dhcp_checksum_diag.nim"])
    admission = (TX / "output_parts/admission.nim").read_text()
    diagnostics = (TX / "output_parts/protocol_diag.nim").read_text()
    diagnostics += (TX / "output_parts/dhcp_tx.nim").read_text()
    names = set(re.findall(r"\bnimFwDbg\w+", helpers + diagnostics))
    functions = set(re.findall(r"\b(nimFwDbg\w+)\(", helpers + diagnostics))
    arrays = {"nimFwDbgDhcpTxMsgHist": "array[8, uint32]",
              "nimFwDbgDhcpTxRaw": "array[384, uint8]"}
    debug = "\nvar\n" + "".join(
        f"  {name}: {arrays.get(name, 'uint32')}\n" for name in sorted(names - functions))
    output = procedure((TX / "output.nim").read_text(), "bl_output")
    return debug + helpers + r'''
proc storeBe16(bytes: ptr UncheckedArray[uint8]; offset: uint; value: uint16) =
  bytes[offset] = (value shr 8).uint8
  bytes[offset + 1] = value.uint8
''' + admission + diagnostics + enqueue + output


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
    return HOST_TABLE + layout + types + views + output_source()


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
    let checksumOffset = 14 + ihl * 4 + 16
    if checksumOffset + 1 < size:
      storeBe16(bytes, checksumOffset.uint, 0xBEEF)
    packets[0] = PbufView(payload: bytes, len: size.uint16, totLen: size.uint16)
    doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
    if checksumOffset + 1 < size:
      doAssert loadBe16(bytes, checksumOffset.uint) == 0xBEEF
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
tcp[47] = 0x18
storeBe16(tcp, 50, 0xBEEF)
packets[0] = PbufView(payload: tcp, len: 54, totLen: 54)
let tcpCount = nimFwDbgTxTcp
let httpCount = nimFwDbgTxTcp80
doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
doAssert nimFwDbgTxTcp == tcpCount + 1 and nimFwDbgTxTcp80 == httpCount + 1
doAssert nimFwDbgTxTcpFlags == 0x5018
doAssert loadBe16(tcp, 50) == 0xBEEF
cFree(tcp)

reset()
let udp = allocPacket(286)
for i in 0..5: udp[6 + i] = (i + 1).uint8
udp[12] = 8
udp[14] = 0x45
udp[16] = 1
udp[17] = 16
udp[23] = 17
udp[35] = 68
udp[37] = 67
udp[39] = 252
storeBe16(udp, 40, 0xBEEF)
udp[42] = 1
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
doAssert nimFwDbgDhcpTxSrcLo == 0x04030201'u32 and nimFwDbgDhcpTxSrcHi == 0x0605'u32
doAssert (nimFwDbgDhcpTxMsg and 255) == 3
doAssert loadBe16(udp, 40) == 0xBEEF
doAssert nimFwDbgDhcpReqUdpChecksumBefore == 0xBEEF
doAssert nimFwDbgDhcpReqUdpChecksumAfter == 0xBEEF
doAssert nimFwDbgDhcpReqUdpChecksumCalc != 0xBEEF
doAssert nimFwDbgDhcpReqUdpChecksumVerifyBefore == nimFwDbgDhcpReqUdpChecksumVerifyAfter
doAssert nimFwDbgDhcpReqUdpChecksumAtCopy == 0xBEEF

# Ethernet trailing bytes cannot supply a DHCP option outside the UDP length.
udp[39] = 248
let requests = nimFwDbgDhcpTxMsgHist[3]
doAssert bl_output(addr hw, 0, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
doAssert (nimFwDbgDhcpTxMsg and 255) == 0 and nimFwDbgDhcpTxMsgHist[3] == requests
cFree(udp)
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_output(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


def submission_fixture() -> str:
    from test_wifi_tx_submission import CHECKS, source as submission_source

    code = submission_source("chained_packet").split(CHECKS["chained_packet"], 1)[0]
    code = code.replace("array[4, array[256, uint8]]", "array[4, array[1600, uint8]]")
    code += procedure((TX / "views.nim").read_text(), "udpHeaderAt")
    code += r'''
type
  BlHw = BlHwView
  BlTxCfm = object
{.emit: "volatile unsigned int nimfw_dbg_bl_output_eapol;".}
proc nimFwDbgDhcpRequestTxBreakpoint() = discard
proc nimFwDbgDhcpTxBreakpoint() = discard
'''
    return code + output_source(r'''
# Model lwIP adding headroom and queue the host-size header for real TX/IPC.
proc enqueueTxPacket(isSta: cint; p: ptr Pbuf; v: ptr PbufView;
                     eth: ptr EthernetHeaderView; cfm: ptr BlTxCfm): int8 =
  doAssert isSta == 1 and cfm == nil and cast[pointer](p) == v
  let bytes = addr packetBytes[0][0]
  doAssert v.payload == bufferAt(bytes, PbufLinkEncapsulationHlen.uint)
  v.payload = bytes
  v.len += PbufLinkEncapsulationHlen
  v.totLen += PbufLinkEncapsulationHlen
  let header = txHdrView(bufferAt(bytes, alignPads(bytes).uint))
  header.pbuf = p
  header.len = v.totLen
  setTxHdrVifType(header, isSta.uint8)
  listPushBack(addr wifi_hw.stas[0].waitingList, header)
  txCntrlStaTrigger = 1
  ErrOk
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_admitted_chain_copy(tmp_path: Path, mode: str) -> None:
    checks = r'''
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
  doAssert bl_output(addr wifi_hw, 1, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
  bl_tx_try_flush(0, nil)
  doAssert publications.len == 1 and publications[0].length == (size - 14).uint32
  doAssert publications[0].marker == 7 and released[0] == 1
  let copied = cast[ptr UncheckedArray[uint8]](txbufHostBuf(publications[0].buffer))
  for i in 0..<(size - 14): doAssert copied[62 + i] == (i mod 251).uint8
  doAssert enabled
'''
    run_program(tmp_path, mode, submission_fixture() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dhcp_request_preserved_through_ipc(tmp_path: Path, mode: str) -> None:
    checks = r'''
for (ipHeaderLen, checksum) in [(20, 0'u16), (24, 0xBEEF'u16), (60, 0xBEEF'u16)]:
  let udpOff = 14 + ipHeaderLen
  let bootpOff = udpOff + 8
  let frameLen = udpOff + 252
  for headLen in [14, frameLen - 1, frameLen]:
    install()
    incoming = true
    enabled = true
    var frame = newSeq[uint8](frameLen)
    let bytes = cast[ptr UncheckedArray[uint8]](addr frame[0])
    frame[5] = 7
    frame[12] = 8
    frame[14] = (0x40 or (ipHeaderLen div 4)).uint8
    storeBe16(bytes, 16, (frameLen - 14).uint16)
    frame[23] = 17
    frame[udpOff + 1] = 68
    frame[udpOff + 3] = 67
    frame[udpOff + 5] = 252
    storeBe16(bytes, (udpOff + 6).uint, checksum)
    frame[bootpOff] = 1
    frame[bootpOff + 4 .. bootpOff + 7] = [0x12'u8, 0x34, 0x56, 0x78]
    frame[^8..^1] = [0x63'u8, 0x82, 0x53, 0x63, 53, 1, 3, 255]
    let head = PbufLinkEncapsulationHlen.int
    packets[0] = PbufView(payload: addr packetBytes[0][head],
                          len: headLen.uint16, totLen: frame.len.uint16)
    for i in 0..<headLen: packetBytes[0][head + i] = frame[i]
    if headLen < frame.len:
      let tailLen = (frame.len - headLen).uint16
      packets[0].next = addr packets[1]
      packets[1] = PbufView(payload: addr packetBytes[1][0], len: tailLen, totLen: tailLen)
      for i in headLen..<frame.len: packetBytes[1][i - headLen] = frame[i]

    doAssert bl_output(addr wifi_hw, 1, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
    if headLen >= frameLen - 1:
      doAssert nimFwDbgDhcpTxMsg == 0x34567803'u32
      doAssert nimFwDbgDhcpReqUdpChecksumAtCopy == checksum.uint32
      doAssert (nimFwDbgDhcpReqUdpChecksumCalc == high(uint32)) == (headLen < frameLen)
    bl_tx_try_flush(0, nil)
    doAssert publications.len == 1 and released[0] == 1
    let copied = cast[ptr UncheckedArray[uint8]](txbufHostBuf(publications[0].buffer))
    for i in 0..<frame.len:
      doAssert copied[head + i] == frame[i], "IPC changed DHCP byte " & $i
'''
    run_program(tmp_path, mode, submission_fixture() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_http_reply_preserved_through_ipc(tmp_path: Path, mode: str) -> None:
    checks = r'''
import std/strutils

# The TCP sequence number was chosen so the canonical checksum is zero.
let frame =
  "\x02\x00\x00\x00\x00\x02\x02\x00\x00\x00\x00\x01\x08\x00" &
  "\x45\x00\x05\xdc\x12\x34\x40\x00\x40\x06\x36\x96\xc0\x00\x02\x0a\xc6\x33\x64\x14" &
  "\x00\x50\xc0\x00\x12\x34\x92\xd5\x34\x56\x78\x9a\x50\x18\x0b\x68\x00\x00\x00\x00" &
  "HTTP/1.1 200 OK\r\nContent-Length: 1400\r\nConnection: close\r\n\r\n" & repeat('x', 1400)
doAssert frame.len == 1514 and frame[50..51] == "\x00\x00"
proc wordAt(offset: int): uint32 =
  (frame[offset].uint32 shl 8) or frame[offset + 1].uint32
var sum = 6'u32 + (frame.len - 34).uint32
for i in countup(26, frame.len - 2, 2): sum += wordAt(i)
while sum > 0xFFFF: sum = (sum and 0xFFFF) + (sum shr 16)
doAssert sum == 0xFFFF, "fixture must have a valid TCP checksum"

for headLen in [113, frame.len]:
  install()
  incoming = true
  enabled = true
  let head = PbufLinkEncapsulationHlen.int
  packets[0] = PbufView(payload: addr packetBytes[0][head],
                        len: headLen.uint16, totLen: frame.len.uint16)
  for i in 0..<headLen: packetBytes[0][head + i] = frame[i].uint8
  if headLen < frame.len:
    let tailLen = frame.len - headLen
    packets[0].next = addr packets[1]
    packets[1] = PbufView(payload: addr packetBytes[1][0],
                          len: tailLen.uint16, totLen: tailLen.uint16)
    for i in 0..<tailLen: packetBytes[1][i] = frame[headLen + i].uint8

  let tcpCount = nimFwDbgTxTcp
  let httpCount = nimFwDbgTxTcp80
  doAssert bl_output(addr wifi_hw, 1, cast[ptr Pbuf](addr packets[0]), nil) == ErrOk
  doAssert nimFwDbgTxTcp == tcpCount + 1 and nimFwDbgTxTcp80 == httpCount + 1
  bl_tx_try_flush(0, nil)
  doAssert publications.len == 1 and released[0] == 1
  let published = publications[0]
  let desc = txdescUpperHost(published.node)
  let buf = txbufHostBuf(published.buffer)
  let copied = cast[ptr UncheckedArray[uint8]](buf)
  doAssert desc.ethertype == 0x0008 and desc.packetLen == 1500
  doAssert desc.pbufChainedLen == 1500
  doAssert desc.pbufChainedPtr == cast[uint](bufferAt(buf, LinkOffsetLen.uint)).uint32
  doAssert loadBe16(copied, (head + 50).uint) == 0, "IPC rewrote the valid TCP checksum"
  for i in 0..<frame.len:
    doAssert copied[head + i] == frame[i].uint8, "IPC changed Ethernet byte " & $i
'''
    run_program(tmp_path, mode, submission_fixture() + checks)
