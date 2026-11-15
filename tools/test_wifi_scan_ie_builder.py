"""Run bounded probe IE assembly and the full SCANU scan request builder."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  IE_ID_DS_PARAM = 3'u8
  IE_LEN_DS_PARAM = 1'u8
  IE_ID_HT_CAP = 45'u8
  IE_LEN_HT_CAP = 26'u8
  IE_ID_SUPPORTED_RATES = 1'u8
  PROBE_REQ_SUPPORTED_RATE_COUNT = 8'u8
  SCAN_START_REQ = 0x400'u16
  SCAN_STATUS_BAD_PARAM = 4'u8
  SCAN_STATUS_FAIL = 1'u8
  TASK_SCAN = 1'u8
  TASK_SCANU = 2'u8
  MAX_VIFS = 2
  KeMsgSaved = 2.cint
  ScanStartReqPayloadSize = sizeof(ScanStartReqPayload).uint32
type
  IeBuffer = object
    before: uint64
    ieData: array[200, uint8]
    after: uint64
  MeEnvView = object
    htSupp: uint8
    caps: array[26, uint8]
  ScanEnv = object
    paramPtr: pointer
    scanBand, bssidFilterEnabled: uint8
    extraIePtr: pointer
    extraIeLen: uint16
var
  scan_probe_req_ie, hostIes, extraIes: IeBuffer
  mac_id2rate: array[12, uint8]
  me: MeEnvView
  request: ScanuStartReqPayload
  child: ScanStartReqPayload
  scanu_env: ScanEnv
  allocations, frees, sends, confirmations: int
  lastStatus: uint8
  allocatorFails: bool
  sentBytes: seq[uint8]
  scanuRequestEpoch: uint32
  scanuProducerRequest: pointer
  scanuProducerEpoch: uint32
  interruptsEnabled = true
proc smScanAdmitRequest(p: pointer): bool = true
proc smScanOwnsRequest(p: pointer): bool = false
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc scanSsidSlot(req: ptr ScanuStartReqPayload; index: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](addr req.ssidFilter[index * 34])
proc scanProbeReqIeDataPtr(ie: var IeBuffer): pointer = addr ie.ieData[0]
proc scanuAddIeDataAddr(): uint = cast[uint](addr hostIes.ieData[0])
proc activeScanuReq(): ptr ScanuStartReqPayload = cast[ptr ScanuStartReqPayload](scanu_env.paramPtr)
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = 2 + ie.len.uint
proc meEnvView(): ptr MeEnvView = addr me
proc meHtCapsPtr(p: ptr MeEnvView): pointer = addr p.caps[0]
proc co_pack8p(dst, src: pointer; length: uint32) =
  let address = cast[uint](dst)
  let shared = cast[uint](addr scan_probe_req_ie.ieData[0])
  doAssert address < shared or address >= shared + 200,
    "assembly modified the shared IE buffer before publication"
  doAssert length <= 200
  copyMem(dst, src, length.int)
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  doAssert length <= 200
  copyMem(dst, src, length.int)
  dst
proc ke_msg_alloc(id: uint16; dest, source: uint8; length: uint32): pointer =
  doAssert id == SCAN_START_REQ and dest == TASK_SCAN and source == TASK_SCANU
  doAssert length == ScanStartReqPayloadSize
  inc allocations
  if allocatorFails: return nil
  child = default(ScanStartReqPayload)
  addr child
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) =
  doAssert p == addr child
  inc frees
  doAssert frees == 1
proc ke_msg_send(p: pointer) =
  doAssert p == (addr child) and frees == 0
  inc sends
  doAssert child.ieBodyLen <= 200
  sentBytes = @[]
  for i in 0 ..< child.ieBodyLen.int: sentBytes.add(scan_probe_req_ie.ieData[i])
proc scanu_confirm(status: uint8) =
  inc confirmations
  lastStatus = status
proc finishAdvancedScanuScanBand() = scanu_confirm(0)
"""

CHECKS = r"""
proc reset() =
  for b in scan_probe_req_ie.ieData.mitems: b = 0xCC
  for b in hostIes.ieData.mitems: b = 0xA5
  for b in extraIes.ieData.mitems: b = 0xA5
  for buffer in [addr scan_probe_req_ie, addr hostIes, addr extraIes]:
    buffer.before = 0x123456789ABCDEF0'u64
    buffer.after = 0xFEDCBA9876543210'u64
  allocations = 0
  frees = 0
  sends = 0
  confirmations = 0
  allocatorFails = false
  sentBytes.setLen(0)
  request = default(ScanuStartReqPayload)
  child = default(ScanStartReqPayload)
  request.channelCount = 1
  request.channelList[0] = ScanChannelEntry(prim20Freq: 2412, band: 0, txPower: 11)
  request.scanType = 1
  request.vifIdx = 1
  request.ssidFilter[0] = 3
  request.ssidFilter[1] = 0x41
  request.bssid = [1'u8, 2, 3, 4, 5, 6]
  request.localMac = [7'u8, 8, 9, 10, 11, 12]
  scanu_env = ScanEnv(paramPtr: addr request)
  scanuRequestEpoch = 1
  interruptsEnabled = true
  me.htSupp = 1
  for i in 0 ..< me.caps.len: me.caps[i] = (0x80 + i).uint8
  for i in 0 ..< mac_id2rate.len: mac_id2rate[i] = (0x10 + i).uint8

proc guards() =
  for buffer in [addr scan_probe_req_ie, addr hostIes, addr extraIes]:
    doAssert buffer.before == 0x123456789ABCDEF0'u64
    doAssert buffer.after == 0xFEDCBA9876543210'u64

proc setHost(bytes: openArray[uint8]) =
  doAssert bytes.len <= 200
  for i, value in bytes: hostIes.ieData[i] = value
  request.probeReqIe = addr hostIes.ieData[0]
  request.probeReqIeLen = bytes.len.uint16
proc setExtra(bytes: openArray[uint8]) =
  for i, value in bytes: extraIes.ieData[i] = value
  scanu_env.extraIePtr = addr extraIes.ieData[0]
  scanu_env.extraIeLen = bytes.len.uint16
proc expectedPrefix(noCck, ht: bool): seq[uint8] =
  result = @[1'u8, 8]
  let start = if noCck: 4 else: 0
  for i in 0 ..< 8: result.add(mac_id2rate[start + i])
  if not noCck: result.add(@[50'u8, 4, 0x18, 0x19, 0x1A, 0x1B])
  result.add(@[3'u8, 1, 0])
  if ht:
    result.add(@[45'u8, 26])
    result.add(me.caps)

for noCck in [false, true]:
  for ht in [false, true]:
    reset()
    request.passive = noCck.uint8
    me.htSupp = ht.uint8
    scanu_scan_next()
    doAssert sends == 1 and confirmations == 0 and frees == 0
    doAssert sentBytes == expectedPrefix(noCck, ht)
    doAssert child.channelCount == 1 and child.channelList[0] == request.channelList[0]
    doAssert child.vifIdx == 1 and child.scanType == 1
    doAssert child.bssid == request.bssid and child.localMac == request.localMac
    doAssert child.ssidFilter == request.ssidFilter
    guards()

# Request/Operating-Classes IEs precede HT; all other supplied IEs follow it.
reset()
setHost([10'u8, 1, 0xAA, 59, 1, 0xBB, 221, 2, 0xC1, 0xC2])
setExtra([127'u8, 1, 0xDD])
scanu_scan_next()
var expected = expectedPrefix(false, false)
expected = expected[0 ..< 10] & @[10'u8, 1, 0xAA] & expected[10 .. ^1]
expected.add(@[59'u8, 1, 0xBB, 45, 26])
expected.add(me.caps)
expected.add(@[221'u8, 2, 0xC1, 0xC2, 127, 1, 0xDD])
doAssert sends == 1 and sentBytes == expected
guards()

# Exact fit is valid; one more byte cannot publish a truncated probe.
for total in [199, 200, 201]:
  reset()
  let supplied = total - expectedPrefix(false, true).len
  var bytes = newSeq[uint8](supplied)
  bytes[0] = 221
  bytes[1] = (supplied - 2).uint8
  for i in 2 ..< bytes.len: bytes[i] = i.uint8
  setHost(bytes)
  let before = scan_probe_req_ie.ieData
  scanu_scan_next()
  if total <= 200:
    doAssert sends == 1 and sentBytes.len == total and frees == 0
  else:
    doAssert sends == 0 and frees == 1 and lastStatus == 4 and confirmations == 1
    doAssert scan_probe_req_ie.ieData == before
  guards()

for which in 0 .. 8:
  reset()
  case which
  of 0: setHost([10'u8])
  of 1: setHost([10'u8, 5, 1])
  of 2: setHost([59'u8, 255, 1])
  of 3: setHost([221'u8, 0, 59])
  of 4: setExtra([59'u8])
  of 5: setExtra([221'u8, 255])
  of 6: request.probeReqIeLen = 201
  of 7: request.probeReqIeLen = 1 # nonzero size, nil pointer
  else: scanu_env.extraIeLen = 1
  let before = scan_probe_req_ie.ieData
  scanu_scan_next()
  doAssert sends == 0 and allocations == 1 and frees == 1
  doAssert confirmations == 1 and lastStatus == 4
  doAssert child.ieBodyLen == 0 and scan_probe_req_ie.ieData == before
  guards()

# The writer's capacity and sticky failure are independent of the scan caller.
for length in [0'u32, 1, 199, 200, 201, 65535, 0xFFFFFFFF'u32]:
  reset()
  var writer: ProbeIeWriter
  writer.appendBytes(addr hostIes.ieData[0], length)
  if length <= 200:
    doAssert not writer.failed and writer.len == length.uint16
  else:
    doAssert writer.failed and writer.len == 0
    let before = writer.bytes
    writer.appendByte(7)
    writer.appendIeHeader(1, 0)
    writer.skip(4)
    doAssert writer.len == 0 and writer.bytes == before
  for b in scan_probe_req_ie.ieData: doAssert b == 0xCC
  guards()
reset()
var writer: ProbeIeWriter
writer.appendBytes(nil, 1)
doAssert writer.failed and writer.len == 0
writer = default(ProbeIeWriter)
for b in writer.bytes.mitems: b = 0xE1
writer.skip(200)
doAssert writer.len == 200 and not writer.failed
for b in writer.bytes: doAssert b == 0
writer.appendByte(1)
doAssert writer.failed and writer.len == 200
writer = default(ProbeIeWriter)
writer.len = 199
let before = writer.bytes
writer.appendIeHeader(1, 0)
doAssert writer.failed and writer.len == 199 and writer.bytes == before
reset()
allocatorFails = true
scanu_scan_next()
doAssert allocations == 1 and sends == 0 and frees == 0 and confirmations == 1
doAssert lastStatus == 1
for b in scan_probe_req_ie.ieData: doAssert b == 0xCC
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "capacity", "exact_fit", "tlv", "failed_publish",
                                      "skip", "release", "status", "length"])
def test_scan_ie_builder(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = (FW / "scan_station_ap_me.nim").read_text()
    writer_type = source.split("type ProbeIeWriter = object", 1)[1].split("\nproc ", 1)[0]
    functions = "type ProbeIeWriter = object" + writer_type + "\n"
    functions += "".join(procedure(source, name) for name in [
        "scanuRequestCurrent", "reserveProbeIeBytes", "cursor", "appendByte", "appendIeHeader", "skip", "appendDsParamPlaceholder",
        "appendBytes", "probeIesValid", "appendHtCapabilities", "macId2RatePtr", "appendSupportedRates",
        "finishScanStartReq", "sendScanStartReq", "initScanStartReq", "appendScanBandChannel",
        "copyScanBandChannels", "firstScanBandChannel", "clampedProbeReqIeLen", "supportedRateStart",
        "appendScanSupportedRates", "appendScanHtCapabilities", "allocScanStartReq", "allocInitializedScanStartReq",
        "copyScanSsidFilterIfPresent", "scanu_scan_next",
    ])
    if mutation == "capacity":
        functions = functions.replace("count > w.bytes.len.uint32 - w.len.uint32", "false")
    elif mutation == "exact_fit":
        functions = functions.replace("count > w.bytes.len.uint32 - w.len.uint32", "count >= w.bytes.len.uint32 - w.len.uint32")
    elif mutation == "tlv":
        body = procedure(functions, "probeIesValid")
        functions = functions.replace(body, "proc probeIesValid(data: pointer; length: uint32): bool = true\n")
    elif mutation == "failed_publish":
        functions = functions.replace("if ies.failed or not probeIesValid", "if not probeIesValid")
    elif mutation == "skip":
        functions = functions.replace("w.bytes[w.len.int + i] = 0", "discard")
    elif mutation == "release":
        functions = functions.replace("    ke_msg_free(keMsgHdrFromPayload(msg))\n", "")
    elif mutation == "status":
        functions = functions.replace("    scanu_confirm(SCAN_STATUS_BAD_PARAM)\n", "    scanu_confirm(0)\n")
    elif mutation == "length":
        functions = functions.replace("msg.ieBodyLen = ies.len", "msg.ieBodyLen = ies.len - 1")
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["ScanChannelEntry", "ScanSsidSlotView", "ScanStartReqPayload", "ScanuStartReqPayload", "MacIeView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    program = tmp_path / "scan_ies.nim"
    program.write_text(types + PLATFORM + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(marker in result.stdout for marker in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer"]), result.stdout
