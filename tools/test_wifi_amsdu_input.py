"""Exercise production A-MSDU delivery and its descriptor-offset contract."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "src/bl808/wifi/utils"

PLATFORM = r"""
type
  Pbuf = object
    next: ptr Pbuf
    payload: pointer
    len, tot_len: uint16
    flags: uint8
  NetifInput = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
  Netif = object
    input: NetifInput
  RxHostLease = object
var
  wifi_hw, iface: Netif
  outstanding, allocCalls, failAlloc, takeCalls, failTake, inputFail: int
  received: seq[seq[uint8]]
  wire: seq[uint8]
  expectedOffset, headerFlags: uint32
  splitAt: int
  mpduCalls: int
const
  PbufRaw = 0.cint
  PbufRam = 0x0280.cint
  RxStatusForward = 1'u32
  RxFlagIs80211Mpdu = 2'u32
  RxFlagsOff = 48'u
  RxFlagStaIdxShift = 16
  RxFlagStaIdxMask = 255'u32
  BlVifDevOff = 8'u
  BlRxStatusAmsdu = 1'u32
proc pbuf_alloc(layer: cint; length: uint16; kind: cint): ptr Pbuf =
  inc allocCalls
  if failAlloc != 0 and allocCalls == failAlloc: return nil
  result = cast[ptr Pbuf](alloc0(sizeof(Pbuf)))
  result.len = length
  result.tot_len = length
  result.payload = alloc0(max(length.int, 1))
  inc outstanding
proc pbuf_free(p: ptr Pbuf): uint8 =
  var current = p
  while current != nil:
    let next = current.next
    dealloc(current.payload)
    dealloc(current)
    dec outstanding
    inc result
    current = next
proc pbuf_take_at(p: ptr Pbuf; data: pointer; length, offset: uint16): int8 =
  inc takeCalls
  if failTake != 0 and takeCalls == failTake: return -1
  doAssert offset.uint32 + length.uint32 <= p.len.uint32
  copyMem(cast[pointer](cast[uint](p.payload) + offset.uint), data, length.int)
  0
proc pbuf_copy_partial(p: ptr Pbuf; dst: pointer; length, offset: uint16): uint16 =
  var current = p
  var skip = offset.int
  while current != nil and result < length:
    if skip >= current.len.int:
      skip -= current.len.int
    else:
      let count = min(current.len.int - skip, (length - result).int)
      copyMem(cast[pointer](cast[uint](dst) + result.uint),
              cast[pointer](cast[uint](current.payload) + skip.uint), count)
      result += count.uint16
      skip = 0
    current = current.next
proc packet(data: seq[uint8]; split = 0): ptr Pbuf =
  let first = if split > 0 and split < data.len: split else: data.len
  result = pbuf_alloc(0, first.uint16, 0)
  doAssert result != nil
  if first > 0: copyMem(result.payload, unsafeAddr data[0], first)
  if first < data.len:
    result.next = pbuf_alloc(0, (data.len - first).uint16, 0)
    doAssert result.next != nil
    copyMem(result.next.payload, unsafeAddr data[first], data.len - first)
    result.tot_len = data.len.uint16
proc bl808_nim_netif_input_call(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.} =
  if inputFail != 0: return -1
  var data = newSeq[uint8](p.tot_len.int)
  doAssert pbuf_copy_partial(p, addr data[0], p.tot_len, 0) == p.tot_len
  received.add(data)
  discard pbuf_free(p)
  0
proc noteEthernetInput(p: ptr Pbuf): bool = false
proc loadU32(p: pointer; offset: uint): uint32 = headerFlags
proc loadPtr(p: pointer; offset: uint): pointer = addr iface
proc rxVif(hw: pointer; sta: uint32): pointer = addr iface
proc csrReadMstatus(): uint = 8
proc disableInterrupts() = discard
proc enableInterrupts() = discard
proc captureRxHostLease(desc: pointer; lease: var RxHostLease): bool = true
proc rxHostLeaseCurrent(lease: RxHostLease): bool = true
proc allocFramePbuf(offset: uint32; pkt: pointer): ptr Pbuf =
  doAssert offset == expectedOffset, "descriptor offset was changed"
  packet(wire, splitAt)
proc allocMpduEthernetPbuf(offset: uint32; pkt: pointer): ptr Pbuf =
  inc mpduCalls
  packet(wire, splitAt)
proc inputMonitorFrame(header, pkt: pointer; offset: uint32;
                       lease: ptr RxHostLease = nil): cint =
  doAssert false, "Ethernet/A-MSDU test reached monitor delivery"
template noteUploadScan(args: varargs[untyped]) = discard
template noteTcpipNoPbuf(args: varargs[untyped]) = discard
"""

CHECKS = r"""
proc reset() =
  doAssert outstanding == 0
  iface.input = bl808_nim_netif_input_call
  received.setLen(0)
  allocCalls = 0
  takeCalls = 0
  failAlloc = 0
  failTake = 0
  inputFail = 0
  mpduCalls = 0
  splitAt = 0
  headerFlags = 0
proc subframe(length: int; protocol: uint16; snap = true; bridge = false): seq[uint8] =
  result = newSeq[uint8](14 + length)
  for i in 0 ..< 12: result[i] = (i + 2).uint8
  result[12] = (length shr 8).uint8
  result[13] = (length and 255).uint8
  for i in 14 ..< result.len: result[i] = (i mod 251).uint8
  if snap:
    result[14] = 0xAA
    result[15] = 0xAA
    result[16] = 3
    result[17] = 0
    result[18] = 0
    result[19] = if bridge: 0xF8'u8 else: 0'u8
    result[20] = (protocol shr 8).uint8
    result[21] = (protocol and 255).uint8
proc appendFrame(data: var seq[uint8]; frame: seq[uint8]; last: bool) =
  data.add(frame)
  if not last:
    while (data.len and 3) != 0: data.add(0xDD'u8)
proc expected(frame: seq[uint8]; stripSnap: bool): seq[uint8] =
  if not stripSnap: return frame
  result = frame[0 ..< 12] & frame[20 .. 21] & frame[22 .. ^1]

# IPv6 and unknown Ethernet protocols must not trigger speculative MPDU parsing.
for protocol in [0x86DD'u16, 0x0800, 0x0806, 0x88B5]:
  for offset in [0'u32, 10, 18, 20, 26, 32]:
    reset()
    expectedOffset = offset
    wire = subframe(40, protocol)
    wire[12] = (protocol shr 8).uint8
    wire[13] = (protocol and 255).uint8
    doAssert tcpip_stack_input(nil, 1, addr iface, offset, addr iface, 0) == 0
    doAssert received == @[wire] and mpduCalls == 0 and outstanding == 0

for payloadLength in [8, 9, 10, 11, 256, 2304]:
  for protocol in [0x0800'u16, 0x86DD, 0x8137, 0x80F3]:
    for bridge in [false, true]:
      let a = subframe(payloadLength, protocol, bridge = bridge)
      let b = subframe(7, 0, snap = false)
      var aggregate: seq[uint8]
      aggregate.appendFrame(a, false)
      aggregate.appendFrame(b, true)
      for split in [0, 1, 13, 14, 19, 21, a.len, a.len + 1]:
        reset()
        expectedOffset = 34
        wire = aggregate
        splitAt = split
        doAssert tcpip_stack_input(nil, 1, addr iface, 34, addr iface, 1) == 0
        let strip = bridge or protocol notin [0x8137'u16, 0x80F3'u16]
        doAssert received == @[expected(a, strip), b]
        doAssert outstanding == 0 and mpduCalls == 0

# Validate the entire aggregate before delivering the first subframe.
let valid = subframe(40, 0x0800)
var combined: seq[uint8]
combined.appendFrame(valid, false)
combined.appendFrame(valid, true)
for shortLength in 0 .. 13:
  reset()
  wire = newSeq[uint8](shortLength)
  doAssert inputAmsdu(packet(wire), addr iface) == -1
  doAssert received.len == 0 and outstanding == 0
for truncated in 1 ..< valid.len:
  reset()
  wire = combined[0 ..< combined.len - truncated]
  let p = packet(wire, 13)
  doAssert inputAmsdu(p, addr iface) == -1
  doAssert received.len == 0 and outstanding == 0
for badLength in [0, 2305, 65535]:
  reset()
  wire = valid
  wire[12] = (badLength shr 8).uint8
  wire[13] = (badLength and 255).uint8
  doAssert inputAmsdu(packet(wire), addr iface) == -1
  doAssert received.len == 0 and outstanding == 0
reset()
wire = valid
for i in 0 ..< 6: wire[i] = AmsduRfc1042[i]
doAssert inputAmsdu(packet(wire), addr iface) == -1
doAssert received.len == 0 and outstanding == 0
for badSource in [false, true]:
  reset()
  var bad = valid
  if badSource:
    bad[6] = 1
  else:
    for i in 0 ..< 6: bad[i] = AmsduRfc1042[i]
  wire.setLen(0)
  wire.appendFrame(valid, false)
  wire.appendFrame(bad, true)
  doAssert inputAmsdu(packet(wire, valid.len + 5), addr iface) == -1
  doAssert received.len == 0 and outstanding == 0,
    "invalid later subframe allowed partial delivery"

for failure in 1 .. 2:
  reset()
  let p = packet(combined, 13)
  failAlloc = allocCalls + failure
  doAssert inputAmsdu(p, addr iface) == -1
  doAssert outstanding == 0
for failure in 1 .. 4:
  reset()
  let p = packet(combined, 13)
  failTake = failure
  doAssert inputAmsdu(p, addr iface) == -1
  doAssert outstanding == 0
reset()
inputFail = 1
doAssert inputAmsdu(packet(combined), addr iface) == 0
doAssert outstanding == 0 and received.len == 0
"""


@pytest.mark.parametrize("release_mode", [False, True])
def test_amsdu_delivery_and_upload_offset(release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = (UTILS / "rx_delivery.nim").read_text()
    source += """
proc fixtureDelivery(): RxNetifDelivery =
  RxNetifDelivery(vif: addr iface, netif: addr iface,
                 input: bl808_nim_netif_input_call)
"""
    source += (UTILS / "tcpip_pbuf_alloc_parts/amsdu_input.nim").read_text()
    source += (UTILS / "tcpip_input.nim").read_text()
    source = source.replace("firmware.", "")
    names = sorted(set(re.findall(r"\bnimFwDbg\w+\b", source)))
    declarations = "\nvar\n" + "\n".join(f"  {name}: uint32" for name in names) + "\n"
    path = tmp_path / "amsdu.nim"
    checks = re.sub(r"(inputAmsdu\([^\n]+), addr iface\)", r"\1, fixtureDelivery())", CHECKS)
    path.write_text(PLATFORM + declarations + source + checks)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "-d:bl808WifiRxPbufInput",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
