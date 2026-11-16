"""Run the RX management producer with real MFP policy and wire layouts."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_mfp_control import KEY_CONTEXT, RX_CONTEXT, RX_MIC_MODEL, PLATFORM as MFP_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = MFP_PLATFORM.replace(
    "  Vif = object\n",
    "  Vif = object\n    next: pointer\n    macAddr: array[6, uint8]\n"
    "    vifType, vifIdx, state: uint8\n",
).replace(
    "  Sta = object\n", "  Sta = object\n    valid, instNbr: uint8\n"
    "    nonQosSeqCtrl: uint16\n"
) + r"""
type
  RxStationIdentity = object
    epoch: uint32
    vifEpochs: array[MAX_VIFS, uint32]
    keyRevision: uint64
    station, vif: uint8
    captured, associated: bool
    channelCaptured: bool
    channelGeneration: uint32
  CoList = object
    first, last: pointer
  RxEnv {.packed.} = object
    frameCtrl, seqCtrl, seqNum: uint16
    fragNum, tid, machdrLen, staIdx, vifIdx: uint8
    vifToDestinationPadding: array[25, uint8]
    flags: uint8
  MgmtEnv = object
    activeList: CoList
  MmEnv = object
    rxPromiscUploadFlag, apPromiscUploadFlag: uint32
  Frame {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
    body: array[104, uint8]
  Rx = object
    bufferChain: pointer
    mpduLengthBytes: uint16
    hwFlags, timestampLow, timestampHigh: uint32
    phyVector: array[24, uint8]
    channelInfo: array[8, uint8]
  Desc = object
    swDesc: pointer
    curDesc: pointer
  Log = proc(level: uint32; tag, file: cstring; line: cint;
             format: cstring) {.cdecl, varargs, raises: [Exception].}
const
  TASK_SCAN = 1'u8
  ScanChannelPendingState = 2'u16
  ScanChannelRunningState = 3'u16
var
  env: RxEnv
  mgmt: MgmtEnv
  mm: MmEnv
  frame: Frame
  rx: Rx
  desc: Desc
  message: array[256, uint8]
  messageLength: uint32
  destination: uint8
  allocationCalls, sent, uploads, decodes, beaconChecks, policyCalls: int
  policyVif, policySta: uint8
  forceIgnore, forceUpload, allocationFailure: bool
  wildcardApmEnabled: bool
  scanState: uint16
  rxVifEpochs: array[MAX_VIFS, uint32]
  rxKeyRevision = 1'u64
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  interrupts = true
  onPolicy, onDecode: proc()
  channelReads: int
  logging, loggerFailure: bool
  logs: seq[tuple[line: cint, text: string]]
proc rxCaptureStation(desc: pointer; flags: uint32)
proc rxStationCurrent(desc: pointer): bool
proc rxMpduDescIndex(p: pointer): int = (if p == addr desc: 0 else: -1)
proc staDeleteEpoch(station: uint8): uint32 = stationEpochs[station]
proc staRxSequence(sta: ptr Sta): ptr Sta = sta
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc rxMpduDescView(p: pointer): ptr Desc = cast[ptr Desc](p)
proc rxSwDescView(p: pointer): ptr Rx = cast[ptr Rx](p)
proc rxMpduHeader(p: pointer): ptr Rx =
  if p == (addr desc) and desc.swDesc == (addr rx): addr rx else: nil
proc rxFrameAtRef(p: pointer): ptr Frame = cast[ptr Frame](p)
proc rxuCntrlEnvView(): ptr RxEnv = addr env
proc vifMgmtEnvView(): ptr MgmtEnv = addr mgmt
proc mmEnvView(): ptr MmEnv = addr mm
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vif_mgmt_get_vif(i: uint8): pointer =
  if i < MAX_VIFS: addr vifs[i] else: nil
proc apm_embedded_enabled(p: pointer): bool =
  if p == nil: wildcardApmEnabled
  else: vifChannelAt(p).vifType == 2
proc phyif_utils_decode(p: pointer; rssi: ptr int8): uint32 =
  inc decodes
  rssi[] = -43
  if onDecode != nil: onDecode()
  0
proc phy_get_channel_raw(p: pointer; index: uint8) =
  inc channelReads
  let words = cast[ptr array[2, uint32]](p)
  words[] = [2412'u32 shl 16, 0'u32]
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logHook(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("rxu_cntrl.c")
  doAssert format != nil
  var output: array[128, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count > 0 and count < output.len.cint
  logs.add((line, $cast[cstring](addr output[0])))
  if loggerFailure: raise newException(ValueError, "receive logger stopped")
proc getLogFunc(slot: int): Log =
  doAssert slot == 204
  if logging: logHook else: nil
proc ke_state_get(task: uint8): uint16 = scanState
proc me_beacon_check(vif: uint8; length: uint16; p: pointer) = inc beaconChecks
proc rxFrameCursor(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc rxFrameBodyByte(p: ptr Frame; offset: uint8): uint8 =
  cast[ptr UncheckedArray[uint8]](p)[offset]
template rxFrameWords(p: pointer): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](p)
proc rxMgtAllocMessage(p: pointer; task: uint8; length: uint32): pointer =
  doAssert p == (addr desc) and length + 4 < message.len.uint32
  if not rxStationCurrent(p): return nil
  inc allocationCalls
  destination = task
  messageLength = length
  if allocationFailure: return nil
  addr message[0]
proc ke_msg_send(p: pointer) =
  doAssert p == addr message[0]
  inc sent
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr message[0]
proc rxu_mpdu_upload_and_indicate(p: pointer) =
  doAssert p == (addr desc) and uploads == 0
  inc uploads
  desc.curDesc = addr frame
proc assert_warn(a, b: cstring; line: cint) = doAssert false
template nimFwTrace2U32(args: varargs[untyped]) = discard
template nimFwConnectTrace2U32(args: varargs[untyped]) = discard
proc mfpIgnorePolicy(desc, param, frameBodyPtr: pointer; frameTotalLen: uint16;
                     upload: ptr uint8; flags: ptr uint8; generation: uint32): bool
proc mfpIgnoreRxMgmtFrame(desc, param, frame: pointer; length: uint16;
                         upload, flags: ptr uint8; generation: uint32): bool =
  inc policyCalls
  policyVif = env.vifIdx
  policySta = env.staIdx
  if forceIgnore:
    upload[] = forceUpload.uint8
    result = true
  else:
    result = mfpIgnorePolicy(desc, param, frame, length, upload, flags, generation)
  if onPolicy != nil: onPolicy()
proc reset(fc: uint16; vif: uint8; station: uint8 = 4; kind: uint8 = 0) =
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  for i in 0 ..< MAX_VIFS:
    vifs[i].vifIdx = i.uint8
    vifs[i].vifType = 4
    vifs[i].macAddr = [2'u8, 3, 4, 5, 6, i.uint8]
  if vif < MAX_VIFS:
    vifs[vif].vifType = kind
    mgmt.activeList.first = addr vifs[vif]
  else:
    mgmt.activeList.first = nil
  env = RxEnv(frameCtrl: fc, machdrLen: 24, staIdx: station, vifIdx: vif)
  if station < STA_INFO_TAB_ENTRIES:
    stations[station].valid = 1
    stations[station].instNbr = vif
  mm = default(MmEnv)
  frame = Frame(frameControl: fc)
  if vif < MAX_VIFS: frame.addr1 = vifs[vif].macAddr
  frame.addr3 = [2'u8, 8, 7, 6, 5, 4]
  for i in 0 ..< frame.body.len: frame.body[i] = i.uint8
  rx = Rx(bufferChain: addr frame, mpduLengthBytes: 36)
  desc.swDesc = addr rx
  if station < STA_INFO_TAB_ENTRIES and vif < MAX_VIFS:
    rx.hwFlags = 0x02006000'u32 or ((station.uint32 + 8) shl 15)
  rxCaptureStation(addr desc, rx.hwFlags)
  message = default(typeof(message))
  messageLength = 0
  destination = 255
  allocationCalls = 0
  sent = 0
  uploads = 0
  decodes = 0
  beaconChecks = 0
  policyCalls = 0
  forceIgnore = false
  forceUpload = false
  allocationFailure = false
  wildcardApmEnabled = false
  scanState = ScanChannelRunningState
  onPolicy = nil
  onDecode = nil
  channelReads = 0
  interrupts = true
  logging = false
  loggerFailure = false
  logs.setLen(0)
static:
  doAssert sizeof(RxEnv) == sizeof(MfpMgmtFramePolicyView)
  doAssert offsetof(RxEnv, flags) == 36
"""

ROUTING = r"""
for station in 0'u8 .. 6:
  for vif in 0'u8 .. 1:
    for kind in [0'u8, 2]:
      reset(0xB0, vif, station, kind)
      discard rxu_mgt_frame_check(addr desc, station)
      doAssert policyVif == vif and policySta == station,
        "station index replaced VIF before MFP"
      doAssert sent == 1 and destination == (if kind == 0: 4'u8 else: 5'u8)
      doAssert message[7] == station and message[8] == vif
      doAssert env.vifIdx == vif and env.staIdx == station
      let bodyLength = if kind == 0: 12 else: 36
      doAssert cast[ptr uint16](addr message[0])[] == bodyLength.uint16
      let bodyStart = if kind == 0: cast[pointer](addr frame.body[0]) else: addr frame
      doAssert equalMem(addr message[32], bodyStart, bodyLength)

# Unbound authentication resolves only the VIF; the wire station stays 255.
for vif in 0'u8 .. 1:
  for kind in [0'u8, 2]:
    reset(0xB0, vif, 255, kind)
    env.vifIdx = 255
    if kind == 2: frame.addr3 = frame.addr1
    discard rxu_mgt_frame_check(addr desc, 255)
    doAssert policyVif == vif and policySta == 255
    doAssert sent == 1 and message[7] == 255 and message[8] == vif,
      "unbound frame acquired a synthetic station index"

# Preserve the vendor's station-to-VIF fallback when the environment is unset.
for vif in 0'u8 .. 1:
  reset(0xB0, vif)
  env.vifIdx = 255
  discard rxu_mgt_frame_check(addr desc, 4)
  doAssert sent == 1 and message[7] == 4 and message[8] == vif
"""

FILTERING = r"""
# The real policy rejects an unprotected robust frame on an MFP station.
for vif in 0'u8 .. 1:
  for station in 0'u8 .. 6:
    reset(0xC0, vif, station)
    vifs[vif].keys.groupKeyPtr = 1
    stations[station].capabilityFlags = 8
    frame.body[0] = 1
    frame.body[1] = 0
    mm.rxPromiscUploadFlag = 1
    mm.apPromiscUploadFlag = 1
    doAssert rxu_mgt_frame_check(addr desc, station) == 0
    doAssert sent == 0 and uploads == 0 and allocationCalls == 0
    doAssert decodes == 0, "ignored frame continued into normal classification"

# A group-addressed robust frame without an MMIE is rejected by real policy.
reset(0xC0, 0)
vifs[0].keys.groupKeyPtr = 1
env.flags = 1
doAssert rxu_mgt_frame_check(addr desc, 4) == 0
doAssert sent == 0 and uploads == 0 and decodes == 0

# An already-handled filter result must not generate an ordinary indication,
# even when it separately allows raw upload.
for vif in 0'u8 .. 1:
  reset(0xB0, vif)
  forceIgnore = true
  forceUpload = true
  discard rxu_mgt_frame_check(addr desc, 4)
  doAssert sent == 0 and allocationCalls == 0 and decodes == 0
"""

OWNERSHIP = r"""
for vif in [0'u8, 1, 255]:
  for kind in [0'u8, 1, 2, 3, 4]:
    for mask in 0'u32 .. 3:
      for ignored in [false, true]:
        reset(0x50, vif, 255, kind)
        # Keep discovery traffic unresolved instead of the MAC lookup path.
        rx.hwFlags = 0x200
        mm.rxPromiscUploadFlag = mask and 1
        mm.apPromiscUploadFlag = mask and 2
        forceIgnore = ignored
        forceUpload = true
        # A supplied peer keeps the established VIF even for this probe response.
        let expectedUpload = if vif == 255: mask != 0
          elif kind == 0: (mask and 1) != 0
          elif kind == 2: (mask and 2) != 0
          elif kind in [1'u8, 3]: true
          else: false
        let owned = rxu_mgt_frame_check(addr desc, (if vif == 255: 255'u8 else: 4'u8))
        doAssert uploads == expectedUpload.int
        doAssert owned == expectedUpload.uint32,
          "raw upload returned caller-owned status (RX-lower would free it)"
        doAssert sent == (not ignored).int
        doAssert decodes == (not ignored).int

# Invalid station indexes must never become out-of-bounds fallback lookups.
for station in [7'u8, 8, 254]:
  reset(0xB0, 255, station)
  discard rxu_mgt_frame_check(addr desc, station)
  doAssert sent == 0 and uploads == 0
"""

SUBTYPES = r"""
# Vendor s6 selects whole-frame vs body-only copy; s9 selects raw upload.
for vif in 0'u8 .. 1:
  for sample in [
      (0'u8, 0xB0'u16, 0'u8, 4'u8, false, true),
      (0'u8, 0x10'u16, 0'u8, 4'u8, false, true),
      (0'u8, 0x30'u16, 0'u8, 4'u8, false, true),
      (0'u8, 0xC0'u16, 0'u8, 4'u8, true, true),
      (0'u8, 0xA0'u16, 0'u8, 4'u8, true, true),
      (0'u8, 0x80'u16, 0'u8, 2'u8, true, true),
      (0'u8, 0x50'u16, 0'u8, 2'u8, true, true),
      (0'u8, 0xD0'u16, 3'u8, 6'u8, false, false),
      (0'u8, 0xD0'u16, 8'u8, 4'u8, false, false),
      (2'u8, 0xB0'u16, 0'u8, 5'u8, true, false),
      (2'u8, 0x00'u16, 0'u8, 5'u8, true, false),
      (2'u8, 0x20'u16, 0'u8, 5'u8, true, false),
      (2'u8, 0x40'u16, 0'u8, 5'u8, true, false),
      (2'u8, 0xC0'u16, 0'u8, 5'u8, true, false),
      (2'u8, 0xA0'u16, 0'u8, 5'u8, true, false)]:
    let (kind, fc, category, target, wholeFrame, rawUpload) = sample
    reset(fc, vif, 4, kind)
    frame.body[0] = category
    mm.rxPromiscUploadFlag = 1
    mm.apPromiscUploadFlag = 1
    let owned = rxu_mgt_frame_check(addr desc, 4)
    doAssert sent == 1 and destination == target,
      "wrong task for frame " & $fc & " on VIF type " & $kind
    doAssert uploads == rawUpload.int and owned == rawUpload.uint32,
      "wrong raw-upload decision for frame " & $fc & " on VIF type " & $kind
    let bodyLength = if wholeFrame: 36 else: 12
    let bodyStart = if wholeFrame: cast[pointer](addr frame) else: addr frame.body[0]
    doAssert cast[ptr uint16](addr message[0])[] == bodyLength.uint16
    doAssert equalMem(addr message[32], bodyStart, bodyLength),
      "wrong body origin for frame " & $fc

reset(0x50, 0)
mm.rxPromiscUploadFlag = 1
allocationFailure = true
doAssert rxu_mgt_frame_check(addr desc, 4) == 0
doAssert sent == 0 and uploads == 0 and allocationCalls == 1

# SA Query handling belongs to station-mode SM, not AP-mode SM.
reset(0xD0, 1, 4, 2)
frame.body[0] = 8
discard rxu_mgt_frame_check(addr desc, 4)
doAssert sent == 0 and uploads == 0
"""

VIF_LIFETIME = r"""
for vif in 0'u8 .. 1:
  # An unbound authentication frame is resolved only after a new attempt began.
  reset(0xB0, vif, 255)
  env.vifIdx = 255
  discard rxInvalidateVif(vif)
  doAssert rxu_mgt_frame_check(addr desc, 255) == 0
  doAssert policyCalls == 0 and decodes == 0 and allocationCalls == 0 and sent == 0

  reset(0xB0, vif, 255)
  env.vifIdx = 255
  discard rxInvalidateVif(vif xor 1)
  discard rxu_mgt_frame_check(addr desc, 255)
  doAssert policyCalls == 1 and sent == 1

  for associated in [false, true]:
    reset(0xB0, vif, (if associated: 4'u8 else: 255'u8))
    onPolicy = proc() = discard rxInvalidateVif(vif)
    doAssert rxu_mgt_frame_check(addr desc, (if associated: 4'u8 else: 255'u8)) == 0
    doAssert policyCalls == 1 and decodes == 0 and allocationCalls == 0 and sent == 0
    doAssert interrupts

    reset(0xB0, vif, (if associated: 4'u8 else: 255'u8))
    onDecode = proc() = discard rxInvalidateVif(vif)
    doAssert rxu_mgt_frame_check(addr desc, (if associated: 4'u8 else: 255'u8)) == 0
    doAssert policyCalls == 1 and decodes == 1 and allocationCalls == 0 and sent == 0
    doAssert interrupts
"""

CHANNEL = r"""
for subtype in [0x50'u16, 0x80'u16, 0xB0'u16]:
  for vif in 0'u8 .. 1:
    reset(subtype, vif)
    rx.channelInfo = [1'u8, 0, 0x3C, 20, 0x3C, 20, 0, 0]
    rxStationIdentities[0].channelCaptured = true
    rxStationIdentities[0].channelGeneration = rxUploadEpochs[0]
    discard rxu_mgt_frame_check(addr desc, 4)
    let captured = rxuMgtIndMsgAt(addr message[0])
    doAssert sent == 1 and captured.freq == 5180 and captured.band == 1
    doAssert channelReads == 0 and interrupts

    reset(subtype, vif)
    discard rxu_mgt_frame_check(addr desc, 4)
    let direct = rxuMgtIndMsgAt(addr message[0])
    doAssert sent == 1 and direct.freq == 2412 and direct.band == 0
    doAssert channelReads == 1 and interrupts

    reset(subtype, vif)
    rx.channelInfo = [1'u8, 0, 0x3C, 20, 0x3C, 20, 0, 0]
    rxStationIdentities[0].channelCaptured = true
    rxStationIdentities[0].channelGeneration = rxUploadEpochs[0]
    inc rxUploadEpochs[0]
    discard rxu_mgt_frame_check(addr desc, 4)
    let replaced = rxuMgtIndMsgAt(addr message[0])
    doAssert sent == 1 and replaced.freq == 2412 and replaced.band == 0
    doAssert channelReads == 1 and interrupts
"""

BIP_SEQUENCE = r"""
for enabled in [false, true]:
  for keyId in [4'u16, 5'u16]:
    reset(0xC0, 0, 4)
    interrupts = enabled
    env.flags = 1
    env.seqCtrl = 0x1230
    frame.seqCtrl = env.seqCtrl
    frame.body[0] = 1
    frame.body[1] = 0
    rx.mpduLengthBytes = 44
    stations[4].nonQosSeqCtrl = 0x7770
    stations[3].nonQosSeqCtrl = 0x8880
    vifs[0].keys.groupKeyPtr = 1
    vifs[0].slots[keyId].installed = 1
    let mmie = mmieAt(addr frame.body[2])
    mmie[] = MmIeView(ie: Ie(id: 76, len: 16), keyId: keyId)
    mmie.ipn[0] = 3
    computedMic = 0x123456789ABCDEF0'u64
    for i in 0..<8:
      mmie.mic[i] = (((computedMic xor 1) shr (8 * i)) and 255).uint8
    discard rxu_mgt_frame_check(addr desc, 4)
    doAssert stations[4].nonQosSeqCtrl == 0x7770,
      "BIP rejection changed the management duplicate cache"
    doAssert vifs[0].slots[keyId].replayCounters[0].pnLow == 0
    doAssert sent == 0 and interrupts == enabled
    frame.frameControl = 0x08C0
    env.frameCtrl = frame.frameControl
    for i in 0..<8:
      mmie.mic[i] = ((computedMic shr (8 * i)) and 255).uint8
    discard rxu_mgt_frame_check(addr desc, 4)
    doAssert stations[4].nonQosSeqCtrl == 0x1230,
      "accepted BIP frame did not commit its management sequence"
    doAssert stations[3].nonQosSeqCtrl == 0x8880
    doAssert vifs[0].slots[keyId].replayCounters[0].pnLow == 4
    doAssert sent == 1 and interrupts == enabled
"""


LOGGING = r'''
for enabled in [false, true]:
  reset(0xC0, 0)
  logging = enabled
  discard rxu_mgt_frame_check(addr desc, 4)
  doAssert sent == 1
  doAssert logs == (if enabled:
    @[(1399.cint, "[FW] got unexpected DISASSOC/DEAUTHENT\r\n")] else: @[])

  reset(0xB0, 0)
  logging = enabled
  allocationFailure = true
  discard rxu_mgt_frame_check(addr desc, 4)
  doAssert sent == 0 and allocationCalls == 1
  doAssert logs == (if enabled:
    @[(1482.cint, "rxu msg alloc failure\r\n")] else: @[])

for allocation in [false, true]:
  reset((if allocation: 0xB0'u16 else: 0xC0'u16), 0)
  logging = true
  loggerFailure = true
  allocationFailure = allocation
  var raised = false
  try: discard rxu_mgt_frame_check(addr desc, 4)
  except ValueError: raised = true
  doAssert raised and sent == 0
  doAssert allocationCalls == allocation.int
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_management_logging(tmp_path: Path, mode: str) -> None:
    test_management_receive(tmp_path, mode, LOGGING)


def management_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    producer = (FW / "task_handlers.nim").read_text()
    code = PLATFORM
    lower = (FW / "rx_layer.nim").read_text()
    for name in ["rxInvalidateQuiescentVif", "rxInvalidateVif", "rxUploadGeneration", "rxUploadCurrent", "rxCaptureStation", "rxIdentityCurrent",
                 "rxStationCurrent", "rxCapturedChannelCurrent", "rxReadCapturedChannel", "rxBindVif"]:
        code += procedure(lower, name)
    name = "RxuMgtIndMsgView"
    code += "\ntype\n  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    code += "\nproc rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView = cast[ptr RxuMgtIndMsgView](p)\n"
    code += procedure(layout, "copyRoundedRxWords")
    code += procedure(layout, "rxMacHeaderLen")
    code += procedure(layout, "rxMgmtBodyValid")
    # The ordinary fixture stores one flat frame where hardware has a chain.
    code += r'''
type
  RxSwDescView = Rx
  MgtFixtureBuffer = object
    next, frameData: pointer
var mgtFixtureBuffer: MgtFixtureBuffer
proc rxFrameBufferChainAt(p: pointer): ptr MgtFixtureBuffer =
  if p == nil: return nil
  mgtFixtureBuffer = MgtFixtureBuffer(frameData: p)
  addr mgtFixtureBuffer
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  copyMem(dst, src, length.int)
  dst
'''
    code += procedure((FW / "rx_upper.nim").read_text(), "rxuCopyFrameBytes")
    policy = (FW / "crypto_mfp_hsu.nim").read_text()
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "mfp_is_robust_frame")
    code += KEY_CONTEXT + RX_CONTEXT + RX_MIC_MODEL + procedure(policy, "mfpIgnoreRxMgmtFrame").replace(
        "proc mfpIgnoreRxMgmtFrame", "proc mfpIgnorePolicy", 1
    )
    helpers = ""
    if "proc rxuMgtUpload(" in producer:
        helpers += procedure(producer, "rxuMgtUpload")
    body = procedure(producer, "rxu_mgt_frame_check")
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    code += "\nvar\n" + "".join(
        f"  {name}: " + ("array[16, uint32]" if name == "nimFwDbgMgtSubtypeCounts" else "uint32") + "\n"
        for name in debug
    )
    return code + helpers + body


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("checks", [ROUTING, FILTERING, OWNERSHIP, SUBTYPES, VIF_LIFETIME, CHANNEL, BIP_SEQUENCE],
                         ids=["routing", "filtering", "ownership", "subtypes", "vif-lifetime", "channel", "bip-sequence"])
def test_management_receive(tmp_path: Path, mode: str, checks: str) -> None:
    run_program(tmp_path, mode, management_source() + checks)
