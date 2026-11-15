"""Exercise real RX diagnostic readers with exact frame and DMA boundaries."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    body = (FW / "global_state/debug_rx_helpers.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    names = set(re.findall(r"\bnimFwDbg\w+", body))
    defined = set(re.findall(r"^proc (\w+)\*?\(", body, re.M))
    debug = "\nvar\n"
    for name in sorted(names - defined):
        kind = "uint32"
        if "Trace" in name and not name.endswith("Count"):
            kind = "array[8, uint32]"
        elif name == "nimFwDbgRxuAssocTcpRaw":
            kind = "array[64, uint8]"
        debug += f"  {name}: {kind}\n"
    return layouts("MacDataFrameHeaderView", "LlcSnapHeaderView",
                   "RxMsduSnapView", "RxPayloadBufferView") + r'''
const RxuDupTraceEntries = 8
const RxuPnDropTraceEntries = 8
const RxuPnAcceptTraceEntries = 8
type Env = object
  secInfo0, secInfo1: uint32
var env: Env
proc rxuCntrlEnvView(): ptr Env = addr env
template rxFrameBytes(p: pointer): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](p)
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc makeFrame(size: int): ptr UncheckedArray[uint8] =
  result = cast[ptr UncheckedArray[uint8]](cMalloc(size.csize_t))
  zeroMem(result, size)
  result[0] = 8
  result[1] = 8
proc setDhcp(bytes: ptr UncheckedArray[uint8]; header: int) =
  bytes[header] = 0xAA
  bytes[header + 1] = 0xAA
  bytes[header + 2] = 3
  bytes[header + 6] = 8
  bytes[header + 8] = 0x45
  bytes[header + 17] = 17
  bytes[header + 29] = 67
  bytes[header + 31] = 68
''' + debug + "".join(procedure(layout, name) for name in [
        "debugLoadLe32", "rxMsduView", "rxMsduPayload", "rxSnapPrefixIs",
        "rxSnapIsRfc1042", "rxSnapTraceLo", "rxSnapTraceHi"]) + body + r'''
proc capture(bytes: ptr UncheckedArray[uint8]; header, length: uint16) =
  let frame = cast[ptr MacDataFrameHeaderView](bytes)
  nimFwDbgRxuIpv4Preupload(frame, header.uint8, 0, length)
  discard nimFwDbgRxuDhcpMsg(frame, header.uint8, length)
  nimFwDbgRecordRxuDupDrop(frame, 0, 0, 0, header.uint8, 0, length)
  nimFwDbgRecordRxuPnDrop(frame, 0, 0, 0, header.uint8, length)
  nimFwDbgRecordRxuPnAccept(1, frame, 0, 0, 0, header.uint8, length)
'''


CASES = {
    "short_snap": r'''
for header in [24, 26, 30, 32, 36]:
  for suffix in 0..<8:
    let size = header + suffix
    let bytes = makeFrame(size)
    for i in 0..<8:
      nimFwDbgRxuDupTraceSnapLo[i] = high(uint32)
      nimFwDbgRxuDupTraceSnapHi[i] = high(uint32)
      nimFwDbgRxuPnDropTraceSnapLo[i] = high(uint32)
      nimFwDbgRxuPnDropTraceSnapHi[i] = high(uint32)
      nimFwDbgRxuPnAcceptTraceSnapLo[i] = high(uint32)
      nimFwDbgRxuPnAcceptTraceSnapHi[i] = high(uint32)
    capture(bytes, header.uint16, size.uint16)
    let slot = (nimFwDbgRxuDupTraceCount - 1) mod 8
    doAssert nimFwDbgRxuDupTraceSnapLo[slot] == 0
    doAssert nimFwDbgRxuDupTraceSnapHi[slot] == 0
    doAssert nimFwDbgRxuPnDropTraceSnapLo[slot] == 0
    doAssert nimFwDbgRxuPnDropTraceSnapHi[slot] == 0
    doAssert nimFwDbgRxuPnAcceptTraceSnapLo[slot] == 0
    doAssert nimFwDbgRxuPnAcceptTraceSnapHi[slot] == 0
    cFree(bytes)
''',
    "exact_end": r'''
for options in 0..4:
  let size = 300 + options
  let bytes = makeFrame(size)
  setDhcp(bytes, 24)
  capture(bytes, 24, size.uint16)
  doAssert nimFwDbgRxuDhcpMsg(cast[ptr MacDataFrameHeaderView](bytes), 24, size.uint16) == 0
  cFree(bytes)
''',
    "logical_end": r'''
let bytes = makeFrame(308)
setDhcp(bytes, 24)
bytes[300] = 53
bytes[301] = 1
bytes[302] = 7
capture(bytes, 24, 300)
doAssert nimFwDbgRxuDhcpMsg(cast[ptr MacDataFrameHeaderView](bytes), 24, 300) == 0
let slot = (nimFwDbgRxuDupTraceCount - 1) mod 8
doAssert nimFwDbgRxuDupTraceDhcpMsg[slot] == 0
doAssert nimFwDbgRxuPnDropTraceDhcpMsg[slot] == 0
doAssert nimFwDbgRxuPnAcceptTraceDhcpMsg[slot] == 0
cFree(bytes)
''',
    "dma_end": r'''
let bytes = makeFrame(1736)
setDhcp(bytes, 24)
var offset = 300
while offset + 257 <= 1736:
  bytes[offset] = 1
  bytes[offset + 1] = 255
  offset += 257
bytes[offset] = 1
bytes[offset + 1] = (1736 - offset - 2).uint8
capture(bytes, 24, 4000)
doAssert nimFwDbgRxuDhcpMsg(cast[ptr MacDataFrameHeaderView](bytes), 24, 4000) == 0
cFree(bytes)
''',
    "complete": r'''
for header in [24, 26, 30, 32, 36]:
  let size = header + 8 + 20 + 8 + 240 + 3
  let bytes = makeFrame(size)
  setDhcp(bytes, header)
  bytes[size - 3] = 53
  bytes[size - 2] = 1
  bytes[size - 1] = 3
  capture(bytes, header.uint16, size.uint16)
  doAssert nimFwDbgRxuDhcpMsg(cast[ptr MacDataFrameHeaderView](bytes), header.uint8, size.uint16) == 3
  let slot = (nimFwDbgRxuDupTraceCount - 1) mod 8
  doAssert nimFwDbgRxuDupTraceDhcpMsg[slot] == 3
  doAssert nimFwDbgRxuPnDropTraceDhcpMsg[slot] == 3
  doAssert nimFwDbgRxuPnAcceptTraceDhcpMsg[slot] == 3
  doAssert nimFwDbgRxuDupTraceSnapLo[slot] == 0x0003AAAA
  cFree(bytes)
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_diagnostic_bounds(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
