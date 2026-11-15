"""Run raw-monitor upload and pbuf ownership using production Nim procedures."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "src/bl808/wifi/utils"

PLATFORM = r'''
type
  BlRxInfo = object
    rssi: int8
    legRate, formatMod: uint8
  Pbuf = object
    next: ptr Pbuf
    payload: pointer
    tot_len, len, refs: uint16
  NetifInput = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
  Netif = object
    input: NetifInput
  RxHostLease = object
  Packet = object
    buffers, reserved: array[4, uint32]
    lengths: array[4, uint16]
var
  packet: Packet
  header: array[64, uint8]
  buffers: array[4, array[1736, uint8]]
  expected: seq[uint8]
  expectedInfo: BlRxInfo
  wifi_hw, netif: Netif
  irq = true
  expectedIrq = true
  outstanding, allocations, takes, failTake: int
  failAlloc, badPbuf, retain, mutate, hasVif: bool
  retained: ptr Pbuf
  lastAllocated: ptr Pbuf
  delivered, ethernet, aggregates, lookups: int
const
  PbufRaw = 0.cint
  PbufRam = 0x0280.cint
  RxStatusForward = 1'u32
  RxFlagsOff = 48'u
  RxFlagIs80211Mpdu = 2'u32
  RxFlagStaIdxShift = 16
  RxFlagStaIdxMask = 255'u32
  BlVifDevOff = 8'u
  BlRxStatusAmsdu = 1'u32
  WifiPktFragCount = 4
  WifiPktFragmentSize = 1736'u32
  WifiPktPktOff = 0'u
  WifiPktLenOff = 32'u
proc ptrAt(p: pointer; offset: uint): pointer =
  let address = cast[uint](p)
  for i in 0 .. 3:
    let base = ((i + 1) * 0x10000).uint
    if address >= base and address < base + 1736:
      doAssert address - base + offset < 1736
      return addr buffers[i][address - base + offset]
  cast[pointer](address + offset)
proc loadU8(p: pointer; offset: uint): uint8 = cast[ptr uint8](ptrAt(p, offset))[]
proc loadU16(p: pointer; offset: uint): uint16 =
  loadU8(p, offset).uint16 or (loadU8(p, offset + 1).uint16 shl 8)
proc loadU32(p: pointer; offset: uint): uint32 =
  for i in 0'u .. 3: result = result or (loadU8(p, offset + i).uint32 shl (i * 8))
proc csrReadMstatus(): uint = irq.uint * 8
proc captureRxHostLease(desc: pointer; lease: var RxHostLease): bool = true
proc rxHostLeaseCurrent(lease: RxHostLease): bool = true
proc disableInterrupts() = irq = false
proc enableInterrupts() = irq = true
proc pbuf_alloc(layer: cint; length: uint16; kind: cint): ptr Pbuf =
  inc allocations
  doAssert not irq
  if failAlloc: return nil
  result = cast[ptr Pbuf](alloc0(sizeof(Pbuf)))
  result.payload = alloc0(length.int)
  result.len = length
  result.tot_len = length
  result.refs = 1
  lastAllocated = result
  if badPbuf: dec result.len
  inc outstanding
proc pbuf_free(p: ptr Pbuf): uint8 =
  doAssert p != nil and p.refs > 0
  dec p.refs
  if p.refs != 0: return 0
  dealloc(p.payload)
  dealloc(p)
  dec outstanding
  1
proc pbuf_take_at(p: ptr Pbuf; data: pointer; length, offset: uint16): int8 =
  doAssert not irq
  inc takes
  if takes == failTake: return -1
  doAssert offset.uint32 + length.uint32 <= p.len.uint32
  copyMem(cast[pointer](cast[uint](p.payload) + offset.uint), data, length.int)
  0
proc bl_rx_pkt_cb(data: ptr uint8; length: cint; wrapper: pointer; info: ptr BlRxInfo) =
  doAssert irq == expectedIrq
  let p = cast[ptr Pbuf](wrapper)
  doAssert data == p.payload and length == expected.len and p.len == length.uint16
  doAssert p.refs == 1 and info[] == expectedInfo
  doAssert cmpMem(data, addr expected[0], expected.len) == 0
  inc delivered
  if mutate:
    header = default(typeof(header))
    packet = default(Packet)
    buffers = default(typeof(buffers))
    doAssert cmpMem(data, addr expected[0], expected.len) == 0
    doAssert info[] == expectedInfo
  if retain:
    inc p.refs
    retained = p
proc rxVif(hw: pointer; station: uint32): pointer =
  inc lookups
  if hasVif: addr netif else: nil
proc loadPtr(p: pointer; offset: uint): pointer = addr netif
proc allocFramePbuf(offset: uint32; pkt: pointer): ptr Pbuf =
  inc ethernet
  cast[ptr Pbuf](1)
template inputAmsdu(args: varargs[untyped]): cint =
  block:
    inc aggregates
    0
proc bl808_nim_netif_input_call(p: ptr Pbuf; n: ptr Netif): int8 = 0
proc noteEthernetInput(p: ptr Pbuf): bool = false
template noteUploadScan(args: varargs[untyped]) = discard
template noteTcpipNoPbuf(args: varargs[untyped]) = discard

proc prepare(length: int; offset: uint32; rssi: int8; rate, format: uint8) =
  doAssert outstanding == 0
  header = default(typeof(header))
  packet = default(Packet)
  buffers = default(typeof(buffers))
  allocations = 0
  delivered = 0
  ethernet = 0
  aggregates = 0
  lookups = 0
  takes = 0
  failTake = 0
  failAlloc = false
  badPbuf = false
  retain = false
  mutate = false
  hasVif = false
  retained = nil
  header[0] = (length and 255).uint8
  header[1] = (length shr 8).uint8
  header[13] = (rate shl 4) or 15
  header[18] = format or 0xF8
  header[23] = cast[uint8](rssi)
  header[48] = 2
  header[50] = 255
  expectedInfo = BlRxInfo(rssi: rssi, legRate: rate, formatMod: format)
  expected = newSeq[uint8](length)
  for i in 0 ..< length: expected[i] = ((i * 37 + 9) mod 256).uint8
  var remaining = length + offset.int
  var copied = 0
  for i in 0 .. 3:
    if remaining == 0: break
    let size = min(remaining, 1736)
    packet.buffers[i] = ((i + 1) * 0x10000).uint32
    packet.lengths[i] = size.uint16
    for j in 0 ..< size:
      if copied + j >= offset.int:
        buffers[i][j] = expected[copied + j - offset.int]
    remaining -= size
    copied += size
  doAssert remaining == 0
'''

CHECKS = r'''
for length in [1, 2, 24, 64, 1736, 2000, 5000]:
  for offset in [0'u32, 1, 32, 1735]:
    for enabled in [false, true]:
      prepare(length, offset, -95, 11, 5)
      expectedIrq = enabled
      irq = enabled
      retain = (length and 1) == 0
      mutate = true
      doAssert tcpip_stack_input(nil, 1, addr header[0], offset, addr packet, 1) == 0
      doAssert irq == enabled and delivered == 1 and lookups == 0
      doAssert ((wifi_nimfw_tcpip_input_drop_flags() shr 8) and 255) == 0
      doAssert ethernet == 0 and aggregates == 0
      doAssert outstanding == retain.int
      if retained != nil:
        doAssert retained.refs == 1
        doAssert cmpMem(retained.payload, addr expected[0], expected.len) == 0
        discard pbuf_free(retained)
      doAssert outstanding == 0

for code in 0 .. 9:
  prepare(2000, 0, -128, 15, 7)
  expectedIrq = true
  irq = true
  case code
  of 0: header[0] = 0; header[1] = 0
  of 1: packet.lengths[0] = 0
  of 2: packet.buffers[0] = 0
  of 3: packet.lengths[0] = 1737
  of 4: packet.lengths[1] = 1
  of 5: packet.buffers[1] = 0
  of 6:
    header[0] = 64
    header[1] = 0
    packet.lengths[1] = 0
    packet.lengths[2] = 1
    packet.buffers[2] = 0x30000
  of 7: failAlloc = true
  of 8: badPbuf = true
  else: header[0] = 255; header[1] = 255
  doAssert tcpip_stack_input(nil, 1, addr header[0], 0, addr packet, 0) == -1
  doAssert irq and outstanding == 0 and delivered == 0 and lookups == 0
for failure in 1 .. 4:
  prepare(6000, 0, 0, 0, 0)
  irq = true
  failTake = failure
  doAssert tcpip_stack_input(nil, 1, addr header[0], 0, addr packet, 0) == -1
  doAssert irq and outstanding == 0 and delivered == 0
prepare(64, 0, 0, 0, 0)
irq = true
doAssert tcpip_stack_input(nil, 0, addr header[0], 0, addr packet, 0) == -1
doAssert tcpip_stack_input(nil, 1, nil, 0, addr packet, 0) == -1
doAssert tcpip_stack_input(nil, 1, addr header[0], 0, nil, 0) == -1
doAssert tcpip_stack_input(nil, 1, addr header[0], 64, addr packet, 0) == -1
doAssert tcpip_stack_input(nil, 1, addr header[0], 1736, addr packet, 0) == -1
doAssert outstanding == 0 and delivered == 0
doAssert ((wifi_nimfw_tcpip_input_drop_flags() shr 8) and 255) ==
  (nimFwDbgMonitorInputFail and 255)

# A raw flag always selects monitor delivery, even with an ordinary data VIF.
prepare(64, 0, 12, 0, 0)
hasVif = true
expectedIrq = true
irq = true
doAssert tcpip_stack_input(nil, 1, addr header[0], 0, addr packet, 0) == 0
doAssert delivered == 1 and lookups == 0 and ethernet == 0

for rssi in [-128'i8, -1, 0, 127]:
  for rate in 0'u8 .. 15:
    for format in 0'u8 .. 7:
      prepare(64, 0, rssi, rate, format)
      irq = true
      expectedIrq = true
      doAssert tcpip_stack_input(nil, 1, addr header[0], 0, addr packet, 0) == 0
      doAssert delivered == 1 and outstanding == 0
for fc in [0x80'u8, 0xD4, 0x08, 0x88]:
  prepare(64, 5, -50, 3, 2)
  expected[0] = fc
  expected[1] = 0
  buffers[0][5] = fc
  buffers[0][6] = 0
  doAssert tcpip_stack_input(nil, 1, addr header[0], 5, addr packet, 0) == 0
  doAssert delivered == 1 and ethernet == 0 and aggregates == 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("pbuf_input", [False, True])
@pytest.mark.parametrize("mutation", [None, "route", "offset", "short", "free", "irq",
    "gap", "capacity", "metadata", "copy", "drop_count"])
def test_monitor_routing_and_copy(
    tmp_path: Path, mode: str, pbuf_input: bool, mutation: str | None
) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    body = (UTILS / "rx_delivery.nim").read_text()
    body += (UTILS / "monitor_input.nim").read_text() + (UTILS / "tcpip_input.nim").read_text()
    body = body.replace("firmware.", "")
    body += procedure((UTILS / "tcpip_diag.nim").read_text(), "wifi_nimfw_tcpip_input_drop_flags")
    mutations = {
        "route": ("if (flags and RxFlagIs80211Mpdu) != 0'u32:", "if false:"),
        "offset": ("let offset = if index == 0: msduOffset else: 0'u32", "let offset = 0'u32"),
        "short": ("if length.uint32 > available:", "if false:"),
        "free": ("defer: discard pbuf_free(packet)", "discard"),
        "irq": ("enableInterrupts()", "discard"),
        "gap": ("if ended or fragmentLength > WifiPktFragmentSize:", "if fragmentLength > WifiPktFragmentSize:"),
        "capacity": ("if ended or fragmentLength > WifiPktFragmentSize:", "if ended:"),
        "metadata": ("info.rssi = cast[int8](loadU8(hwhdr, 23))", "info.rssi = 0"),
        "copy": ("pbuf_take_at(result, fragment.data, count, copied) != 0", "pbuf_take_at(result, fragment.data, count, copied) == 123"),
        "drop_count": ("nimFwDbgMonitorInputFail and 0xff'u32", "nimFwDbgTcpipInputMpdu and 0xff'u32"),
    }
    if mutation is not None:
        old, new = mutations[mutation]
        assert body.count(old) >= 1 if mutation == "irq" else body.count(old) == 1
        body = body.replace(old, new)
    debug = "var\n" + "".join(f"  {name}: uint32\n" for name in
        sorted(set(re.findall(r"\bnimFwDbg\w+", body))))
    path = tmp_path / "monitor.nim"
    path.write_text(PLATFORM + debug + body + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    if pbuf_input:
        options[mode].append("-d:bl808WifiRxPbufInput")
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(path)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "RangeDefect", "AddressSanitizer", "SIGSEGV", "SIGBUS"]), result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_real_monitor_callbacks_borrow_and_retain(tmp_path: Path, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    platform = PLATFORM.replace("proc bl_rx_pkt_cb(data:", "proc monitorObserver(data:")
    callbacks = r'''
type
  PktCb = proc(env: pointer; data: ptr uint8; length: cint; info: ptr BlRxInfo) {.cdecl.}
  PktAdvCb = proc(env, wrapper: pointer; info: ptr BlRxInfo) {.cdecl.}
var
  basicCalls, advancedCalls: int
'''
    rx = ROOT / "src/bl808/wifi/rx"
    callbacks += (rx / "callback_runtime.nim").read_text()
    callbacks += "\n".join(line for line in (rx / "callback_state.nim").read_text().splitlines()
                           if line.startswith(("var cbPkt:", "var cbPktAdv:"))) + "\n"
    packet_source = (ROOT / "src/bl808/wifi/rx/callback_registers_parts/packet.nim").read_text()
    body = (UTILS / "monitor_input.nim").read_text().replace("firmware.", "")
    debug = "var\n" + "".join(f"  {name}: uint32\n" for name in
        sorted(set(re.findall(r"\bnimFwDbg\w+", body))))
    checks = r'''
proc basic(env: pointer; data: ptr uint8; length: cint; info: ptr BlRxInfo) {.cdecl.} =
  doAssert env == cast[pointer](17) and irq
  doAssert info[] == expectedInfo and length == expected.len
  doAssert cmpMem(data, addr expected[0], expected.len) == 0
  inc basicCalls
  header = default(typeof(header))
  packet = default(Packet)
  buffers = default(typeof(buffers))
proc advanced(env, wrapper: pointer; info: ptr BlRxInfo) {.cdecl.} =
  let p = cast[ptr Pbuf](wrapper)
  doAssert env == cast[pointer](17) and irq and basicCalls == 1
  doAssert p.refs == 1 and info[] == expectedInfo
  doAssert cmpMem(p.payload, addr expected[0], expected.len) == 0
  inc p.refs
  retained = p
  inc advancedCalls
prepare(5000, 32, -101, 9, 6)
discard bl_rx_pkt_cb_register(cast[pointer](17), basic)
discard bl_rx_pkt_adv_cb_register(cast[pointer](17), advanced)
doAssert inputMonitorFrame(addr header[0], addr packet, 32) == 0
doAssert basicCalls == 1 and advancedCalls == 1 and outstanding == 1
doAssert retained.refs == 1
discard pbuf_free(retained)
discard bl_rx_pkt_cb_unregister(nil)
discard bl_rx_pkt_adv_cb_unregister(nil)
prepare(64, 0, 0, 0, 0)
doAssert inputMonitorFrame(addr header[0], addr packet, 0) == 0
doAssert basicCalls == 1 and advancedCalls == 1 and outstanding == 0
'''
    path = tmp_path / "callbacks.nim"
    path.write_text(platform + callbacks + packet_source + debug + body + checks)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(path)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
