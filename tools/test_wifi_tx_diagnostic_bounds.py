"""TX snapshots follow header boundaries and scatter/gather payload lengths.

The shared native fixture widens descriptor addresses to native uint so its
buffers can use real host allocations. RV32 layout is checked by the M0 build.
"""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_tx_sequence import CHECKS, program_source


def source() -> str:
    code = program_source()
    address_field = "    bufferPtrs: array[4, uint32]\n"
    assert code.count(address_field) == 1
    code = code.replace(address_field, "    bufferPtrs: array[4, uint]\n", 1)
    return code + CHECKS.split("proc checkTx(", 1)[0] + r'''
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc makeBytes(size: int; value: uint8): ptr UncheckedArray[uint8] =
  result = cast[ptr UncheckedArray[uint8]](cMalloc(size.csize_t))
  doAssert result != nil
  for i in 0..<size: result[i] = value + i.uint8

proc setup(tid: uint8; security: uint32): HostTxDescView =
  reset()
  securityHeaderLen = security
  securityTailLen = security
  result = HostTxDescView(staInfoIdx: 0, staIdx: tid, vifIdx: 0,
    frameLen: 0x0008, hdrLen: (if tid == 0xFF: 32 else: 34) + security.uint8,
    secTailLen: security.uint8, qosExtLen: 8,
    da: [2'u8, 32, 34, 36, 38, 40], sa: [2'u8, 42, 44, 46, 48, 50])

proc checkSnapshot(desc: var HostTxDescView; extra: int; expected: openArray[uint8]) =
  let size = desc.hdrLen.int + extra
  let header = makeBytes(size, 0x91)
  let endOfHeader = cast[pointer](cast[uint](header) + desc.hdrLen.uint)
  doAssert txuBuildFrame(addr desc, endOfHeader)
  let count = desc.hdrLen.int + expected.len
  doAssert nimFwDbgDhcpMacRawLen == count.uint32, "snapshot length"
  for i in 0..<desc.hdrLen.int:
    doAssert nimFwDbgDhcpMacRaw[i] == header[i], "header mismatch"
  var firstWord = 0'u32
  for i, value in expected:
    doAssert nimFwDbgDhcpMacRaw[desc.hdrLen.int + i] == value, "payload mismatch"
    if i < 4: firstWord = firstWord or (value.uint32 shl (8 * i))
  for i in count..<nimFwDbgDhcpMacRaw.len:
    doAssert nimFwDbgDhcpMacRaw[i] == 0, "stale snapshot tail"
  doAssert nimFwDbgDhcpTxLayout[5] == (if securityHeaderLen == 0: 0'u32 else: 0xD3D3D3D3'u32)
  doAssert nimFwDbgDhcpTxLayout[6] == 0x0003AAAA
  doAssert nimFwDbgDhcpTxLayout[7] == firstWord, "payload word"
  for i in desc.hdrLen.int..<size:
    doAssert header[i] == 0x91'u8 + i.uint8, "builder changed header tail"
  cFree(header)
'''


CASES = {
    "exact_header": r'''
for tid in [0'u8, 7, 0xFF]:
  for security in [0'u32, 4, 8]:
    var desc = setup(tid, security)
    nimFwDbgDhcpMacRaw = default(typeof(nimFwDbgDhcpMacRaw))
    checkSnapshot(desc, 0, [])
''',
    "inline_padding_is_not_payload": r'''
for security in [0'u32, 4, 8]:
  var desc = setup(0, security)
  let payload = makeBytes(9, 0x41)
  desc.seqPassthrough = 9
  desc.bufferPtrs[0] = cast[uint](payload)
  desc.bufferLens[0] = 9
  checkSnapshot(desc, 32, toOpenArray(payload, 0, 8))
  cFree(payload)
''',
    "fragmented_prefix": r'''
for total in 1..40:
  var desc = setup(0xFF, 0)
  var expected: seq[uint8]
  var allocations: seq[pointer]
  var remaining = total
  for i in 0..<4:
    if remaining == 0: break
    let size = if i == 3: remaining else: min(remaining, 1 + i)
    let payload = makeBytes(size, (0x20 + 16 * i).uint8)
    allocations.add(payload)
    desc.bufferPtrs[i] = cast[uint](payload)
    desc.bufferLens[i] = size.uint32
    for j in 0..<size:
      if expected.len < 32: expected.add(payload[j])
    remaining -= size
  desc.seqPassthrough = total.uint16
  checkSnapshot(desc, 0, expected)
  for p in allocations: cFree(p)
''',
    "logical_length_and_stale_tail": r'''
var desc = setup(0, 8)
let payload = makeBytes(40, 0x31)
desc.bufferPtrs[0] = cast[uint](payload)
desc.bufferLens[0] = 40
for length in [40, 32, 7, 3, 1, 0]:
  desc.seqPassthrough = length.uint16
  desc.bufferLens[0] = length.uint32
  var expected: seq[uint8]
  for i in 0..<min(length, 32): expected.add(payload[i])
  checkSnapshot(desc, 0, expected)
cFree(payload)
''',
    "unavailable_or_wrapped_span": r'''
for failure in 0..6:
  var desc = setup(0, 0)
  desc.seqPassthrough = 4
  case failure
  of 0: desc.bufferLens[0] = 4
  of 1: desc.bufferPtrs[0] = 1
  of 2:
    desc.bufferPtrs[0] = high(uint)
    desc.bufferLens[0] = 2
  of 3:
    desc.bufferPtrs[1] = 1
    desc.bufferLens[1] = 4
  of 4:
    desc.bufferPtrs[0] = 1
    desc.bufferLens[0] = 1
  of 5:
    desc.bufferPtrs[0] = 1
    desc.bufferLens[0] = 1
    desc.bufferPtrs[1] = high(uint)
    desc.bufferLens[1] = 2
  else:
    desc.seqPassthrough = 5
    desc.bufferPtrs[0] = 1
    desc.bufferLens[0] = 4
    desc.bufferPtrs[2] = 1
    desc.bufferLens[2] = 1
  checkSnapshot(desc, 0, [])
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_tx_diagnostic_bounds(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
