"""Correlate the owned RX copy with the synchronous netif callback."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program

WIFI = Path(__file__).resolve().parents[1] / "src/bl808/wifi"


CONTEXT = r'''
{.define: bl808WifiDiagDhcpTxAttempts.}
from std/volatile import volatileLoad
type
  Pbuf = object
    payload: pointer
    len, tot_len: uint16
    next: ptr Pbuf
  NetifInput = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
  Netif = object
    input: NetifInput
  RxHostLease = bool
var
  wifi_hw, device: Netif
  irq = true
  released, reject, noDhcpClient: bool
  calls, advances: uint32
  nimFwDbgTcpipInputDhcpRx, nimFwDbgTcpipInputOk, nimFwDbgTcpipInputFail: uint32
const BlVifDevOff = 0
proc csrReadMstatus(): uint32 =
  if irq: 8'u32 else: 0'u32
proc disableInterrupts() = irq = false
proc enableInterrupts() = irq = true
proc rxHostLeaseCurrent(lease: RxHostLease): bool = not irq and lease
proc rxVif(hw: pointer; station: uint32): pointer = addr device
proc loadPtr(vif: pointer; offset: int): pointer = addr device
proc loadU8(p: pointer; i: uint): uint8 = cast[ptr UncheckedArray[uint8]](p)[i]
proc loadBe16(p: pointer; i: uint): uint16 =
  (loadU8(p, i).uint16 shl 8) or loadU8(p, i + 1).uint16
proc pbuf_free(p: ptr Pbuf): int =
  doAssert not released
  released = true
  p[] = default(Pbuf)
  1
proc pbufCopyDhcpPrefix(p: ptr Pbuf; dest: pointer; length, offset: uint16): uint16 =
  doAssert offset == 0 and not released
  var part = p
  while part != nil and result < length:
    let n = min(part.len, length - result)
    copyMem(cast[pointer](cast[uint](dest) + result.uint), part.payload, n.int)
    result += n
    part = part.next
'''

CHECKS = r'''
proc receive(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.} =
  doAssert irq and netif == (addr device) and not released
  inc calls
  if reject: return -1
  nimfw_dbg_lwip_dhcp_recv_count += advances
  if noDhcpClient:
    # Older SDK trace patches leave the previous receive's metadata intact.
    nimfw_dbg_lwip_dhcp_recv_code = 1
  else:
    nimfw_dbg_lwip_dhcp_recv_code = 0x85
    nimfw_dbg_lwip_dhcp_recv_meta = 0x45670501
  discard pbuf_free(p)
  0

var frame: array[290, uint8]
frame[12] = 8; frame[14] = 0x46 # IPv4 with four bytes of options
frame[16] = 1; frame[17] = 20; frame[23] = 17
frame[39] = 67; frame[41] = 68; frame[43] = 252
frame[46] = 2
frame[50] = 0x01; frame[51] = 0x23; frame[52] = 0x45; frame[53] = 0x67
frame[282] = 0x63; frame[283] = 0x82; frame[284] = 0x53; frame[285] = 0x63
frame[286] = 53; frame[287] = 1; frame[288] = 5; frame[289] = 255

for n in 0 .. frame.len:
  let parsed = parseDhcpWire(addr frame, n.uint, frame.len.uint, true)
  doAssert parsed.present == (n >= 46)
  doAssert parsed.xidValid == (n >= 286)
  doAssert parsed.kind == (if n >= 289: 5'u8 else: 0'u8)
doAssert not parseDhcpWire(addr frame, frame.len.uint, frame.len.uint, false).present
frame[287] = 3
doAssert parseDhcpWire(addr frame, frame.len.uint, frame.len.uint, true).kind == 0
frame[287] = 1

device.input = receive
proc deliverSplit(split: int; live: bool): RxDeliveryResult =
  released = false
  var tail = Pbuf(payload: addr frame[split], len: (frame.len - split).uint16)
  var head = Pbuf(payload: addr frame[0], len: split.uint16,
    tot_len: frame.len.uint16, next: addr tail)
  result = deliverRxPacket(addr head, RxNetifDelivery(lease: live,
    vif: addr device, netif: addr device, input: receive))
  doAssert irq and released

advances = 1
nimfw_dbg_lwip_dhcp_recv_count = high(uint32)
for split in [1, 13, 24, 41, 128, 287, 289]:
  let row = dhcpRxTraceCount and 7
  doAssert deliverSplit(split, true) == rxDelivered
  doAssert dhcpRxTraceLog[row] == [0x01234567'u32, 0x905, 1, 0x85, 0x45670501]
doAssert dhcpRxTraceCount == 7 and nimFwDbgTcpipInputDhcpRx == 7
doAssert calls == 7 and nimFwDbgTcpipInputOk == 7
doAssert deliverSplit(128, false) == rxDeliveryStale and calls == 7
doAssert dhcpRxTraceLog[7] == [0x01234567'u32, 0x505, 0, 0, 0]
reject = true
doAssert deliverSplit(128, true) == rxInputRejected and calls == 8
doAssert dhcpRxTraceLog[0] == [0x01234567'u32, 0x305, 0, 0, 0]
reject = false
advances = 0
doAssert deliverSplit(128, true) == rxDelivered
doAssert dhcpRxTraceLog[1] == [0x01234567'u32, 0x105, 0, 0, 0]
advances = 2
doAssert deliverSplit(128, true) == rxDelivered
doAssert dhcpRxTraceLog[2] == [0x01234567'u32, 0x105, 2, 0, 0]

advances = 1
doAssert deliverSplit(128, true) == rxDelivered
doAssert dhcpRxTraceLog[3] == [0x01234567'u32, 0x905, 1, 0x85, 0x45670501]
noDhcpClient = true
frame[53] = 0x68
doAssert deliverSplit(128, true) == rxDelivered
doAssert nimfw_dbg_lwip_dhcp_recv_meta == 0x45670501
doAssert dhcpRxTraceLog[4] == [0x01234568'u32, 0x905, 1, 1, 0]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dhcp_rx_trace(tmp_path: Path, mode: str) -> None:
    parser = (WIFI / "dhcp_flow_trace.nim").read_text()
    root = WIFI / "utils"
    trace = (root / "dhcp_rx_trace.nim").read_text().replace(" {.importc.}", "")
    start = trace.index("proc pbufCopyDhcpPrefix")
    trace = trace[:start] + trace[trace.index("proc parseChainedDhcpRx", start):]
    delivery = (root / "rx_delivery.nim").read_text().replace("firmware.", "")
    run_program(tmp_path, mode, CONTEXT + parser + trace + delivery + CHECKS)
