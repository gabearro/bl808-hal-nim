"""Execute the real Ethernet RX copier against a bounded DMA-buffer model."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

UTILS = ROOT / "src/bl808/wifi/utils"

PLATFORM = r"""
type
  Pbuf = object
    next: ptr Pbuf
    payload: pointer
    len, tot_len: uint16
  Packet = object
    buffers, holders: array[4, uint32]
    lengths: array[4, uint16]
var
  packet: Packet
  buffers: array[4, array[1736, uint8]]
  expected: seq[uint8]
  enabled = true
  pending: proc()
  onAllocate, onRead: proc()
  outstanding, allocations, takes, failAlloc, failTake, sourceReads: int
const
  PbufRaw = 0.cint
  PbufRam = 0x0280.cint
  WifiPktFragCount = 4
  WifiPktFragmentSize = 1736'u32
  WifiPktPktOff = 0'u
  WifiPktLenOff = 32'u
proc csrReadMstatus(): uint = (if enabled: 8'u else: 0'u)
proc disableInterrupts() = enabled = false
proc enableInterrupts() =
  enabled = true
  if pending != nil:
    let action = pending
    pending = nil
    action()
proc interrupt(action: proc()) =
  if enabled: action()
  else: pending = action
proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc resolve(p: pointer; count: uint): pointer =
  let address = cast[uint](p)
  for i in 0 .. 3:
    let base = ((i + 1) * 0x10000).uint
    if address >= base and address < base + 0x10000:
      doAssert address - base + count <= 1736, "DMA read exceeds fragment capacity"
      inc sourceReads
      return addr buffers[i][address - base]
  doAssert false, "DMA read uses an invalid buffer address"
proc loadU8(p: pointer; offset: uint): uint8 =
  if p == addr packet:
    result = cast[ptr UncheckedArray[uint8]](p)[offset]
  else:
    result = cast[ptr uint8](resolve(ptrAt(p, offset), 1))[]
proc loadU16(p: pointer; offset: uint): uint16 =
  result = loadU8(p, offset).uint16 or (loadU8(p, offset + 1).uint16 shl 8)
  if onRead != nil:
    let action = onRead
    onRead = nil
    interrupt(action)
proc loadU32(p: pointer; offset: uint): uint32 =
  for i in 0'u .. 3: result = result or (loadU8(p, offset + i).uint32 shl (i * 8))
proc pbuf_alloc(layer: cint; length: uint16; kind: cint): ptr Pbuf =
  inc allocations
  if onAllocate != nil:
    let action = onAllocate
    onAllocate = nil
    interrupt(action)
  if allocations == failAlloc: return nil
  result = cast[ptr Pbuf](alloc0(sizeof(Pbuf)))
  result.payload = alloc0(max(1, length.int))
  result.len = length
  result.tot_len = length
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
proc pbuf_take(p: ptr Pbuf; data: pointer; length: uint16): int8 =
  inc takes
  if takes == failTake: return -1
  doAssert length <= p.len
  copyMem(p.payload, resolve(data, length.uint), length.int)
  0
proc pbuf_cat(head, tail: ptr Pbuf) =
  var current = head
  while true:
    current.tot_len += tail.tot_len
    if current.next == nil: break
    current = current.next
  current.next = tail
proc prepare(length: int; offset = 0'u32) =
  doAssert outstanding == 0
  packet = default(Packet)
  buffers = default(typeof(buffers))
  pending = nil
  onAllocate = nil
  onRead = nil
  enabled = true
  allocations = 0
  takes = 0
  failAlloc = 0
  failTake = 0
  sourceReads = 0
  expected = newSeq[uint8](length)
  for i in 0 ..< length: expected[i] = ((i * 43 + 9) mod 256).uint8
  var remaining = length + offset.int
  var copied = 0
  for i in 0 .. 3:
    if remaining == 0: break
    let count = min(remaining, 1736)
    packet.buffers[i] = ((i + 1) * 0x10000).uint32
    packet.lengths[i] = count.uint16
    for j in 0 ..< count:
      if copied + j >= offset.int:
        buffers[i][j] = expected[copied + j - offset.int]
    copied += count
    remaining -= count
  doAssert remaining == 0
proc resetDma() =
  packet = default(Packet)
  buffers = default(typeof(buffers))
proc checkCopy(p: ptr Pbuf) =
  doAssert p != nil
  doAssert p.tot_len.int == expected.len, "copied packet length changed"
  var bytes: seq[uint8]
  var current = p
  while current != nil:
    for i in 0 ..< current.len.int:
      bytes.add(cast[ptr UncheckedArray[uint8]](current.payload)[i])
    current = current.next
  doAssert bytes == expected, "DMA data changed while copying"
"""

CHECKS = {
    "copy": r"""
for state in [false, true]:
  for offset in [0'u32, 1, 32, 1735]:
    for length in [14, 64, 1736, 2000, 5000]:
      prepare(length, offset)
      enabled = state
      let p = allocFramePbuf(offset, addr packet)
      checkCopy(p)
      doAssert enabled == state
      discard pbuf_free(p)
      doAssert outstanding == 0
prepare(6944)
let p = allocFramePbuf(0, addr packet)
checkCopy(p)
discard pbuf_free(p)
""",
    "allocate_reset": r"""
for state in [false, true]:
  prepare(3500, 32)
  enabled = state
  onAllocate = resetDma
  let p = allocFramePbuf(32, addr packet)
  checkCopy(p)
  doAssert enabled == state
  if not state:
    doAssert pending != nil and packet.lengths[0] != 0
    enableInterrupts()
  doAssert packet.lengths[0] == 0
  discard pbuf_free(p)
  doAssert outstanding == 0
""",
    "metadata_reset": r"""
prepare(3500, 32)
onRead = resetDma
let p = allocFramePbuf(32, addr packet)
checkCopy(p)
doAssert enabled and packet.lengths[0] == 0
discard pbuf_free(p)
doAssert outstanding == 0
""",
    "invalid": r"""
for code in 0 .. 7:
  prepare(3500)
  case code
  of 0: packet.lengths[0] = 0
  of 1: packet.buffers[0] = 0
  of 2: packet.lengths[0] = 1737
  of 3: packet.buffers[1] = 0
  of 4: packet.lengths[1] = 1737
  of 5: packet.lengths[1] = 0
  of 6:
    packet.lengths[1] = 0
    packet.lengths[2] = 0
    packet.lengths[3] = 10
    packet.buffers[3] = 0x40000
  else: packet.buffers[0] = 0xFFFF_FFF0'u32
  let p = allocFramePbuf(if code == 7: 32'u32 else: 0'u32, addr packet)
  doAssert p == nil, "accepted invalid fragment metadata"
  doAssert allocations == 0 and outstanding == 0 and sourceReads == 0,
    "invalid metadata reached allocation or DMA reads"
prepare(64)
doAssert allocFramePbuf(64, addr packet) == nil
doAssert allocFramePbuf(1736, addr packet) == nil
doAssert allocFramePbuf(0, nil) == nil
""",
    "failures": r"""
for state in [false, true]:
  for stage in 1 .. 4:
    for takeFailure in [false, true]:
      prepare(6000)
      enabled = state
      if takeFailure: failTake = stage
      else: failAlloc = stage
      doAssert allocFramePbuf(0, addr packet) == nil
      doAssert outstanding == 0 and enabled == state
""",
    "diagnostic_invalid": r"""
for state in [false, true]:
  for code in 0 .. 3:
    prepare(128)
    enabled = state
    case code
    of 0: packet.lengths[0] = 0
    of 1: packet.lengths[0] = 1737
    of 2: packet.buffers[0] = 0
    else: packet.buffers[0] = 0xFFFF_FFF0'u32
    noteTcpipNoPbuf(1, 1, 0, 0, false, addr packet)
    doAssert enabled == state and sourceReads == 0
    doAssert nimFwDbgTcpipInputNoPbufRaw == default(typeof(nimFwDbgTcpipInputNoPbufRaw))
""",
    "diagnostic_irq": r"""
for state in [false, true]:
  prepare(128)
  enabled = state
  onRead = resetDma
  noteTcpipNoPbuf(1, 1, 0, 0, false, addr packet)
  doAssert enabled == state
  for i in 0 ..< 64: doAssert nimFwDbgTcpipInputNoPbufRaw[i] == expected[i]
  if not state: enableInterrupts()
  doAssert packet.lengths[0] == 0
""",
    "scan_diagnostics": r"""
prepare(128)
buffers[0][0] = 0x45
buffers[0][2] = 0
buffers[0][3] = 40
buffers[0][9] = 17
buffers[0][20] = 0xFD
buffers[0][21] = 0xE8
buffers[0][22] = 0
buffers[0][23] = 9
for i in 0 ..< 128: expected[i] = buffers[0][i]
let p = allocFramePbuf(0, addr packet)
checkCopy(p)
doAssert nimFwDbgTcpipInputScanHit == 1
doAssert nimFwDbgTcpipInputScanPorts == (65000'u32 or (9'u32 shl 16))
for i in 0 ..< 96: doAssert nimFwDbgTcpipInputScanRaw[i] == expected[i]
discard pbuf_free(p)
""",
}


MUTANTS = {
    "copy_lock": "allocate_reset",
    "capacity": "invalid",
    "gap": "invalid",
    "address": "invalid",
    "offset": "copy",
    "take_result": "failures",
    "release": "failures",
    "diagnostic_lock": "diagnostic_irq",
    "diagnostic_capacity": "diagnostic_invalid",
}


def source(case: str, mutation: str | None = None) -> str:
    body = (UTILS / "tcpip_pbuf_alloc_parts/frame_pbuf.nim").read_text()
    scan = (UTILS / "tcpip_pbuf_diag_parts/upload_scan.nim").read_text()
    diagnostic = procedure((UTILS / "tcpip_diag.nim").read_text(), "noteTcpipNoPbuf")
    endian = (UTILS / "tcpip_pbuf_diag_parts/byte_loads.nim").read_text()
    mutations = {
        "copy_lock": ("  disableInterrupts()\n", "  discard\n"),
        "capacity": ("if ended or fragmentLength > WifiPktFragmentSize:", "if ended:"),
        "gap": ("if ended or fragmentLength > WifiPktFragmentSize:",
                "if fragmentLength > WifiPktFragmentSize:"),
        "address": ("if address == 0 or address > high(uint32) - (fragmentLength - 1):", "if false:"),
        "offset": ("let offset = if index == 0: msduOffset else: 0'u32", "let offset = 0'u32"),
        "take_result": ("!= 0'i8:", "== 123'i8:"),
        "release": ("    discard pbuf_free(result)\n", "    discard\n"),
    }
    if mutation in mutations:
        old, new = mutations[mutation]
        assert old in body
        body = body.replace(old, new)
    elif mutation == "diagnostic_lock":
        diagnostic = diagnostic.replace("  disableInterrupts()\n", "  discard\n")
    elif mutation == "diagnostic_capacity":
        diagnostic = diagnostic.replace("if firstLen == 0 or firstLen > WifiPktFragmentSize:",
                                        "if firstLen == 0:")
    names = sorted(set(re.findall(r"\bnimFwDbg\w+", body + scan + diagnostic)))
    arrays = {"nimFwDbgTcpipInputScanRaw": 96, "nimFwDbgTcpipInputNoPbufRaw": 64}
    debug = "\nvar\n" + "".join(
        f"  {name}: {'array[' + str(arrays[name]) + ', uint8]' if name in arrays else 'uint32'}\n"
        for name in names
    )
    return PLATFORM + debug + endian + scan + body + diagnostic + CHECKS[case]


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CHECKS)
def test_rx_copy(tmp_path: Path, mode: str, case: str) -> None:
    run(tmp_path, mode, case)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", MUTANTS)
def test_rx_copy_guards(tmp_path: Path, mode: str, mutation: str) -> None:
    run(tmp_path, mode, MUTANTS[mutation], mutation)


def run(tmp_path: Path, mode: str, case: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "rx_copy.nim"
    path.write_text(source(case, mutation))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
