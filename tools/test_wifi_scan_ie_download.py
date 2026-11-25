"""Check the scan IE buffer and request-pointer ownership at download."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    finder = procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    finder = finder.replace("proc mac_ie_find*", "proc scanTestMacIeFind*")
    return r'''
type
  MacIeView = object
    id, len: uint8
  ScanStartReqPayload = object
    ieBodyLen: uint16
  ScanEnvObj = object
    paramPtr: pointer
    chanInfoPtr: pointer
    channelIndex: uint8
  ScanProbeReqIeObj {.packed.} = object
    dmaDesc: array[16, uint8]
    magic, probeIeStateWord, ieDataPtr, endOffset, writeOffset: uint32
    ieData: array[200, uint8]
    after: uint8
var
  scan_env: ScanEnvObj
  scan_probe_req_ie: ScanProbeReqIeObj
  findCalls, channelCalls: int
  mutateArgument: bool
  argumentToMutate: ptr ScanStartReqPayload
proc scanStartReqView(p: pointer): ptr ScanStartReqPayload =
  cast[ptr ScanStartReqPayload](p)
proc scanProbeReqIeDataPtr(ie: var ScanProbeReqIeObj): pointer =
  addr ie.ieData[0]
proc scanProbeReqIeDataBase(ie: var ScanProbeReqIeObj): uint32 =
  ie.ieDataPtr
proc macIeAt(pos: uint): ptr MacIeView = cast[ptr MacIeView](pos)
template totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2'u
''' + finder + r'''
proc mac_ie_find(buf: pointer; bufLen: uint32; ieId: uint8): pointer =
  inc findCalls
  doAssert buf == addr scan_probe_req_ie.ieData[0]
  doAssert bufLen in [3'u32, 200'u32] and ieId == 3
  scanTestMacIeFind(buf, bufLen, ieId)
proc scan_set_channel_request() =
  inc channelCalls
  if scan_env.chanInfoPtr != nil:
    cast[ptr UncheckedArray[uint8]](scan_env.chanInfoPtr)[2] = 1
  if mutateArgument:
    argumentToMutate.ieBodyLen = 199
''' + procedure(scan, "scan_ie_download")


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_scan_init_points_to_ie_data_and_resets_state(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = r'''
type
  ScanEnvObj = object
    paramPtr, chanInfoPtr: pointer
    requester, channelIndex, abortFlag, padding: uint8
    passiveDuration, activeDuration, joinActiveDuration: uint32
  ScanProbeReqIeObj = object
    hdr: array[16, uint8]
    magic, probeIeStateWord: uint32
    ieDataPtr: pointer
    endOffset, writeOffset: uint32
    ieData: array[200, uint8]
var
  scan_env: ScanEnvObj
  scan_probe_req_ie: ScanProbeReqIeObj
  stateCalls, releases: int
const ScanIdleState = 0'u16
proc scanRelease(failed = false) =
  doAssert not failed and stateCalls == 0
  inc releases
proc scanGo(state: uint16) =
  doAssert state == ScanIdleState and releases == 1
  inc stateCalls
proc c_memset(dst: pointer; value: cint; length: csize_t): pointer =
  zeroMem(dst, length.int)
  dst
proc nimFwTrace(message: cstring) = discard
'''
    code += procedure(scan, "scan_init") + r'''
scan_env.paramPtr = cast[pointer](0x1234)
scan_env.chanInfoPtr = cast[pointer](0x5678)
scan_probe_req_ie.probeIeStateWord = 99
scan_probe_req_ie.writeOffset = 99
scan_init()
doAssert releases == 1 and stateCalls == 1
doAssert scan_env.paramPtr == nil and scan_env.chanInfoPtr == nil
doAssert scan_env.passiveDuration == 0x35B60'u32
doAssert scan_env.activeDuration == 0x35B60'u32
doAssert scan_env.joinActiveDuration == 0x35B60'u32
doAssert scan_probe_req_ie.magic == 0xCAFEFADE'u32
doAssert scan_probe_req_ie.probeIeStateWord == 0 and scan_probe_req_ie.writeOffset == 0
doAssert scan_probe_req_ie.ieDataPtr == addr scan_probe_req_ie.ieData[0]
'''
    run_program(tmp_path, mode, code)


def test_scan_ie_download_uses_data_buffer_and_distinct_lengths(tmp_path: Path) -> None:
    run_program(tmp_path, "checked", source() + r'''
var active = ScanStartReqPayload(ieBodyLen: 3)
var argument = ScanStartReqPayload(ieBodyLen: 5)
scan_probe_req_ie.ieData[0] = 3
scan_probe_req_ie.ieData[1] = 1
scan_probe_req_ie.ieData[2] = 11
scan_env.paramPtr = addr active
scan_env.channelIndex = 2
scan_probe_req_ie.ieDataPtr = 0x1234_5000'u32
scan_probe_req_ie.writeOffset = 77
scan_ie_download(addr argument)
doAssert findCalls == 1 and channelCalls == 1
doAssert scan_env.chanInfoPtr == addr scan_probe_req_ie.ieData[0]
doAssert scan_probe_req_ie.writeOffset == 0
doAssert scan_probe_req_ie.endOffset == 0x1234_5004'u32

# IE lengths beyond the buffer (refused at admission) skip the DS lookup and
# the end marker; the dwell is still submitted, as the blob always does.
scan_probe_req_ie.writeOffset = 88
scan_probe_req_ie.endOffset = 99
active.ieBodyLen = 201
scan_env.chanInfoPtr = addr scan_probe_req_ie.ieData[0]
scan_ie_download(addr argument)
doAssert findCalls == 1 and channelCalls == 2
doAssert scan_env.chanInfoPtr == nil
doAssert scan_probe_req_ie.writeOffset == 88 and scan_probe_req_ie.endOffset == 99

active.ieBodyLen = 3
argument.ieBodyLen = 201
scan_ie_download(addr argument)
doAssert findCalls == 1 and channelCalls == 3
doAssert scan_env.chanInfoPtr == nil
doAssert scan_probe_req_ie.writeOffset == 88 and scan_probe_req_ie.endOffset == 99

mutateArgument = true
argumentToMutate = addr argument
argument.ieBodyLen = 5
scan_ie_download(addr argument)
doAssert findCalls == 2 and channelCalls == 4
doAssert argument.ieBodyLen == 199
doAssert scan_probe_req_ie.endOffset == 0x1234_5004'u32

active.ieBodyLen = 200
argument.ieBodyLen = 200
for byte in scan_probe_req_ie.ieData.mitems: byte = 0
scan_probe_req_ie.ieData[198] = 3
scan_probe_req_ie.ieData[199] = 0
scan_probe_req_ie.after = 0xA5
scan_ie_download(addr argument)
doAssert scan_env.chanInfoPtr == nil
doAssert findCalls == 3 and channelCalls == 5
doAssert scan_probe_req_ie.after == 0xA5
''')
