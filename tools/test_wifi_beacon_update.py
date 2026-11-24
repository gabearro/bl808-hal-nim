"""Execute beacon parsing and template commits without MMIO or a radio."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import FW, ROOT, procedure


PLATFORM = r'''
proc smCleanupOwnsRequest(request: pointer): bool = false
proc smBssOwnsRequest(request: pointer): bool = false
proc smBssTakeReply(request: pointer; id: uint16; length: uint32): pointer = nil
proc smCleanupTakeReply(request: pointer; id: uint16; length: uint32): pointer = nil
proc smActivationOwnsRequest(request: pointer): bool = false
proc smActivationTakeReply(request: pointer; id: uint16; length: uint32): pointer = nil
import bl808/wifi/fw_constants/limits_events
const
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_APM = 5'u8
  TASK_SCAN = 2'u8
  ScanChannelPendingState = 2'u16
  ScanChannelRunningState = 3'u16
  VIF_TYPE_AP = 2'u8
  MM_CHAN_CTXT_UPDATE_REQ = 41'u16
  MM_BCN_CHANGE_CFM = 46'u16
  MM_BCN_CHANGE_REQ = 45'u16
  MM_TIM_UPDATE_REQ = 47'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_TRAFFIC_REQ_IND = 56'u16
  TASK_API = 9'u8
  MmTrafficReqIndPayloadSize = 3'u32
  MmChanCtxtUpdatePayloadSize = 12'u32
  MmTimUpdatePayloadSize = 4'u32
type
  Header = object
    next: ptr Header
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  KeMsgHdr = Header
  CoListHdr = Header
  CoList = object
    first, last: ptr Header
  Env = object
    templatePtr: pointer
    pendingCount: uint32
    active, deferredChange, transmitRequested: uint8
    timQueue: CoList
  MmBcnEnvView = Env
  Vif = object
    next: pointer
    vifIdx, vifType, state, beaconEnabled, timMin, timMax, timFlags: uint8
    beaconCountdown, beaconDivisor, timCountdown: uint8
    timCount, timLength, beaconBodyLength: uint16
    operChan, chanCtxt, beaconTxDesc: pointer
    channelFreqPair: uint32
    bss: array[176, uint8]
    frame: tuple[vifIdx, staInfoIdx: uint8]
  Context = object
    contextIndexOrMarker: uint8
    channel: tuple[txPower: uint8]
  Hw = object
    payloadStart, payloadEnd, status: uint
    frameLen, retryLimitControl, controlFlags: uint32
    chainedThd: pointer
  GuardedPool = object
    before: array[16, uint8]
    bytes: array[860, uint8]
    after: array[16, uint8]
var
  env: Env
  keMsgQueueSent, keMsgQueueSaved: CoList
  mmBcnStopping, mmBcnInitDone: bool
  mmBcnGeneration: uint32
  txResetEpoch: uint32
  mmBcnActiveUpdate: ptr MmBcnUpdateScope
  rxVifEpochs: array[2, uint32]
  chanCtxtLinkEpochs: array[2, uint32]
  interruptsEnabled = true
  beaconClears: int
  clearHook, clearDoneHook, freeHook: proc()
  powerHook, confirmationHook, copyHook: proc()
  channelHook, framePowerHook, pushHook, postponedHook: proc()
  allocationHook: proc(id: uint16)
  vifs: array[2, Vif]
  channels: array[2, ScanChannelEntry]
  contexts: array[2, Context]
  descriptors: array[2, Hw]
  pool: GuardedPool
  txl_tim_desc: array[sizeof(TimDescView), uint8]
  txl_bcn_end_desc: array[sizeof(BeaconEndDescView), uint8]
  txl_tim_ie_pool: array[6, uint8]
  txl_tim_bitmap_pool: array[252, uint8]
  control: tuple[txPower: int32]
  allocated: seq[pointer]
  confirmations: seq[uint8]
  powerUpdates: seq[tuple[vif: uint8, power: int8]]
  channelUpdates: seq[MmChanCtxtUpdatePayload]
  sentDestinations: seq[uint8]
  frees, transmissions, assertions: int
  newBandwidth, expectedCommit: int
  failAllocation: bool
  management: tuple[activeList: CoList]
  txControl: tuple[poison: uint32, seqCounter: uint16]
  stations: array[7, tuple[trafficFlags: uint8, psStatus: uint32]]
  onChannel, pushAccept, completeImmediately: bool
  pushes, framePowerCalls, channelCalls, multicastRequests, postponed: int
  transmittedCounts: seq[uint8]
  transmittedSequences: seq[uint16]
  transmittedTimCounts: seq[uint16]
template txl_bcn_pool: untyped = pool.bytes
proc bcnEnvView(): ptr Env = addr env
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(value: uint32) = interruptsEnabled = (value and 8) != 0
proc vifMgmtEnvView(): ptr typeof(management) = addr management
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifApBeaconFrameDesc(v: ptr Vif): ptr typeof(v.frame) = addr v.frame
proc staInfoForIdx(i: uint8): ptr typeof(stations[0]) = addr stations[i]
proc txControlEnv(): ptr typeof(txControl) = addr txControl
proc nextTxSeqCtrl(): uint16 =
  inc txControl.seqCounter
  txControl.seqCounter shl 4
proc beaconFrameFixedView(p: pointer): ptr BeaconFrameFixedView = cast[ptr BeaconFrameFixedView](p)
proc chan_is_on_operational_channel(p: pointer): bool =
  inc channelCalls
  result = onChannel
  if channelHook != nil: channelHook()
proc tpc_update_frame_tx_power(p, frame: pointer) =
  doAssert frame == cast[pointer](vifApBeaconFrameDesc(vifChannelAt(p)))
  inc framePowerCalls
  if framePowerHook != nil: framePowerHook()
proc sta_mgmt_send_postponed_frame(p, sta: pointer; limit: uint32): uint32 =
  doAssert limit == 0 and cast[ptr typeof(stations[0])](sta).psStatus == 9
  inc postponed
  if postponedHook != nil: postponedHook()
  0
proc ke_state_get(task: uint8): uint16 = ScanChannelRunningState
proc apm_embedded_enabled(p: pointer): bool = false
proc vifBssInfoBase(v: ptr Vif): pointer = addr v.bss[0]
proc vifBssStatus(v: ptr Vif): ptr VifBssStatusOverlay = cast[ptr VifBssStatusOverlay](addr v.bss[128])
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc txBufferControl24G(): ptr typeof(control) = addr control
proc timDescView(): ptr TimDescView = cast[ptr TimDescView](addr txl_tim_desc[0])
proc beaconEndDesc(): ptr BeaconEndDescView = cast[ptr BeaconEndDescView](addr txl_bcn_end_desc[0])
proc timIeAt(p: pointer): ptr TimIeView = cast[ptr TimIeView](p)
proc beaconChangeReqAt(p: pointer): ptr BeaconChangeReqView = cast[ptr BeaconChangeReqView](p)
proc powerConstraintOutputAt(p: pointer): ptr PowerConstraintOutputOverlay = cast[ptr PowerConstraintOutputOverlay](p)
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc pointerAddrU32(p: pointer): uint = cast[uint](p)
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  if copyHook != nil: copyHook()
  dst
proc c_memset(dst: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, n.int)
  dst
proc regRead(address: uint): uint32 = 0x12345678
TRANSMIT_DECLARATION
proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.}
proc txlFrameCallbackCurrent(): bool = true
proc txl_cntrl_halt_ac(ac: uint8): bool =
  doAssert ac == 4 and not interruptsEnabled
  true
proc txl_cntrl_clear_bcn_ac(): bool =
  inc beaconClears
  doAssert mmBcnStopping and not interruptsEnabled
  if clearHook != nil: clearHook()
  while env.pendingCount != 0:
    mm_bcn_transmitted(addr vifs[0])
  if clearDoneHook != nil: clearDoneHook()
  true
proc txl_frame_push(p: pointer; ac: uint8): uint8 =
  doAssert ac == 4 and env.pendingCount == 1
  var selected = -1
  for i in 0 .. 1:
    if p == cast[pointer](addr vifs[i].frame): selected = i
  doAssert selected >= 0
  inc pushes
  if pushHook != nil: pushHook()
  if not pushAccept: return 0
  transmittedCounts.add(txl_tim_ie_pool[2])
  transmittedTimCounts.add(vifs[selected].timCount)
  transmittedSequences.add(beaconFrameFixedView(cast[pointer](descriptors[selected].payloadStart)).seqCtrl)
  if completeImmediately:
    completeImmediately = false
    mm_bcn_transmitted(addr vifs[selected])
  1
proc assert_err(a, b: cstring; line: cint) = inc assertions
proc calloc(count, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgHdrFromPayload(p: pointer): ptr Header = cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc chanUpdateBindVif(p: pointer; vifIndex: uint8): bool = true
proc keMsgPayload(h: ptr Header): pointer = cast[pointer](cast[uint](h) + sizeof(Header).uint)
# Session tracking is exercised by test_wifi_tim_message_lifetime.py.
proc mmTimMessageCurrent(header: ptr KeMsgHdr): bool = true
proc message(id: uint16; dest, src: uint8; size: uint32): pointer =
  let h = cast[ptr Header](calloc(1, (sizeof(Header).uint32 + size).csize_t))
  doAssert h != nil
  h[] = Header(id: id, destId: dest, srcId: src, paramLen: size)
  result = keMsgPayload(h)
  allocated.add(result)
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  if failAllocation: return nil
  result = message(id, dest, src, size)
  if allocationHook != nil: allocationHook(id)
proc apmTakeStartReply(request: pointer; id: uint16; length: uint32): pointer = nil
proc meTakeControlReply(request: pointer; id: uint16; length: uint32): pointer = nil
let meControlCommand, apmStartRequest: pointer = nil
proc ke_msg_free(h: pointer) =
  let p = keMsgPayload(cast[ptr Header](h))
  let index = allocated.find(p)
  doAssert index >= 0, "double free"
  allocated.delete(index)
  inc frees
  free(h)
  if freeHook != nil: freeHook()
proc ke_msg_send_basic(id: uint16; dest, src: uint8) =
  doAssert src == TASK_MM
  if id == MM_BCN_CHANGE_CFM:
    confirmations.add(0)
    doAssert expectedCommit >= 0 and vifs[expectedCommit].beaconEnabled == 1
    doAssert env.active == 0 and env.templatePtr == nil, "confirmation published before commit"
  else: doAssert id == 0x30
  sentDestinations.add(dest)
proc ke_msg_send(p: pointer) =
  let h = keMsgHdrFromPayload(p)
  if h.id == MM_CHAN_CTXT_UPDATE_REQ:
    doAssert h.destId == TASK_MM and h.srcId == TASK_ME and h.paramLen == 12
    channelUpdates.add(cast[ptr MmChanCtxtUpdatePayload](p)[])
  elif h.id == MM_TRAFFIC_REQ_IND:
    doAssert h.paramLen == 3 and h.destId == TASK_API and h.srcId == TASK_MM
    let req = cast[ptr MmTrafficReqIndPayload](p)
    doAssert req.staIdx in [5'u8, 6] and req.packetCount == 0 and req.uapsd == 0
    inc multicastRequests
  else:
    doAssert h.id == MM_BCN_CHANGE_CFM and h.paramLen <= 1
    if h.paramLen == 0:
      doAssert expectedCommit >= 0 and vifs[expectedCommit].beaconEnabled == 1
      doAssert env.active == 0 and env.templatePtr == nil
    confirmations.add(if h.paramLen == 0: 0'u8 else: cast[ptr MmBcnChangeCfmPayload](p).status)
    if confirmationHook != nil: confirmationHook()
  sentDestinations.add(h.destId)
  ke_msg_free(h)
proc tpc_update_vif_tx_power(p, power, index: pointer) =
  let v = cast[ptr Vif](p)
  powerUpdates.add((v.vifIdx, cast[ptr int8](power)[]))
  cast[ptr uint8](index)[] = 4
  if newBandwidth >= 0: vifBssStatus(v).phyBandwidth = newBandwidth.uint8
  if powerHook != nil: powerHook()
proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.}
proc mmBcnApplyUpdate(request: pointer; callbackIrq: uint32): pointer
proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.}
'''

HELPERS = r'''
proc reset() =
  doAssert allocated.len == 0
  doAssert mmBcnActiveUpdate == nil
  env = default(Env)
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  mmBcnStopping = false
  mmBcnInitDone = true
  beaconClears = 0
  clearHook = nil
  clearDoneHook = nil
  freeHook = nil
  powerHook = nil
  confirmationHook = nil
  copyHook = nil
  channelHook = nil
  channelCalls = 0
  framePowerHook = nil
  pushHook = nil
  postponedHook = nil
  allocationHook = nil
  mmBcnGeneration = 0
  txResetEpoch = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  interruptsEnabled = true
  vifs = default(typeof(vifs))
  descriptors = default(typeof(descriptors))
  confirmations.setLen(0)
  powerUpdates.setLen(0)
  channelUpdates.setLen(0)
  sentDestinations.setLen(0)
  transmissions = 0
  frees = 0
  assertions = 0
  newBandwidth = -1
  expectedCommit = -1
  failAllocation = false
  management = default(typeof(management))
  txControl = (0xDEADBEEC'u32, 0'u16)
  stations = default(typeof(stations))
  onChannel = true
  pushAccept = true
  completeImmediately = false
  pushes = 0
  framePowerCalls = 0
  multicastRequests = 0
  postponed = 0
  transmittedCounts.setLen(0)
  transmittedSequences.setLen(0)
  transmittedTimCounts.setLen(0)
  for value in pool.before.mitems: value = 0xA5
  for value in pool.after.mitems: value = 0xA5
  for value in pool.bytes.mitems: value = 0xA5
  for i in 0 .. 1:
    vifs[i].vifIdx = i.uint8
    vifs[i].vifType = VIF_TYPE_AP
    vifs[i].state = 1
    vifs[i].timMin = 255
    vifs[i].timLength = 6
    vifs[i].operChan = addr channels[i]
    vifs[i].chanCtxt = addr contexts[i]
    vifs[i].beaconTxDesc = addr descriptors[i]
    vifs[i].channelFreqPair = 2422'u32 or (2442'u32 shl 16)
    channels[i] = ScanChannelEntry(prim20Freq: 2412, band: 0, txPower: 17)
    contexts[i] = Context(contextIndexOrMarker: (i + 1).uint8, channel: (txPower: 13'u8))
  txl_tim_ie_pool = [5'u8, 4, 0, 1, 0, 0]
  txl_tim_bitmap_pool = default(typeof(txl_tim_bitmap_pool))
  timDescView()[] = TimDescView(magic: 0xCAFEFADE'u32,
    next: addr txl_bcn_end_desc[0], payloadStart: addr txl_tim_ie_pool[0],
    payloadEnd: addr txl_tim_ie_pool[5], bitmapMagic: 0xCAFEFADE'u32,
    bitmapNext: addr txl_bcn_end_desc[0], bitmapStart: addr txl_tim_bitmap_pool[0],
    bitmapEnd: addr txl_tim_bitmap_pool[0])
proc guard(length: int) =
  for value in pool.before: doAssert value == 0xA5
  for value in pool.after: doAssert value == 0xA5
  for i in 0 ..< 348: doAssert pool.bytes[i] == 0xA5
  for i in 348 + length ..< pool.bytes.len: doAssert pool.bytes[i] == 0xA5
proc makeFrame(prefix = 0; suffix = 0; dtim = 3'u8): seq[uint8] =
  result = newSeq[uint8](36)
  result[0] = 0x80
  result.add([0'u8, prefix.uint8])
  for i in 0 ..< prefix: result.add((i and 255).uint8)
  result.add([5'u8, 4, 0, dtim, 0, 0])
  if suffix >= 0:
    result.add([127'u8, suffix.uint8])
    for i in 0 ..< suffix: result.add((i xor 0x55).uint8)
proc request(bytes: seq[uint8]; vif = 0'u8; prefix = 0): pointer =
  result = message(45, TASK_MM, 5, (12 + bytes.len).uint32)
  let req = beaconChangeReqAt(result)
  req.frameLen = bytes.len.uint16
  req.vifIdx = vif
  req.timOffset = (38 + prefix).uint16
  req.timLength = 6
  copyMem(addr req.frameData[0], unsafeAddr bytes[0], bytes.len)
proc tim(aid: uint16; value: uint8; vif = 0'u8) =
  let p = message(47, TASK_MM, 5, 4)
  cast[ptr MmTimUpdatePayload](p)[] = MmTimUpdatePayload(aid: aid, setFlag: value, vifIdx: vif)
  mm_tim_update_proceed(p)
'''


def source(*, transmit: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    result = "type\n"
    for name in ["MacIeView", "PowerConstraintOutputOverlay", "VifBssStatusOverlay",
                 "ScanChannelEntry", "MmChanCtxtUpdatePayload", "BeaconChangeReqView",
                 "MmBcnChangeCfmPayload", "MmBcnUpdateScope", "TimDescView", "BeaconEndDescView", "TimIeView",
                 "MmTimUpdatePayload", "MmTrafficReqIndPayload", "MmSetVifStateReqPayload", "BeaconFrameFixedView"]:
        body = layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0]
        if name == "BeaconEndDescView":
            body = body.replace("payloadStart*: uint32", "payloadStart*: uint")
            body = body.replace("payloadEnd*: uint32", "payloadEnd*: uint")
        result += "  " + name + body + "\n"
    transmit_decl = ("proc mm_bcn_transmit*(vifIdx: uint8) {.exportc, cdecl.}" if transmit
                     else "proc mm_bcn_transmit(vif: uint8) = inc transmissions")
    result += PLATFORM.replace("TRANSMIT_DECLARATION", transmit_decl)
    result += procedure(layout, "totalLen").split("\n\ntemplate", 1)[0] + "\n"
    result += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    result += procedure(scan, "me_extract_power_constraint") + procedure(scan, "me_beacon_check")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_init", "co_list_pop_front", "co_list_push_back", "ke_queue_extract", "ke_msg_alloc_reply", "mmBeaconTemplateValid", "mmBeaconChangeConfirm",
                 "mmBeaconPoolIdle", "mmBcnOwnerCurrent", "mmBcnRequestExecuting", "mmBcnReleaseUpdate", "mmBcnFlushUpdates", "mm_bcn_flush_updates", "mmBcnQueuedUpdateForVif", "mmBcnCancelQueuedUpdates", "mm_bcn_stop", "mm_bcn_init",
                 "mmBcnFinishUpdate", "mmBcnApplyUpdate", "mm_bcn_update", "mm_bcn_change", "mm_bcn_transmitted", "mm_tim_update"]:
        result += procedure(kernel, name)
    if transmit:
        result += procedure(kernel, r"mm_bcn_transmit\b")
    result += procedure((FW / "task_handlers.nim").read_text(), "mm_tim_update_proceed")
    rx = procedure((FW / "task_handlers.nim").read_text(), "rxu_mgt_frame_check")
    beacon = rx.split("    of 0x80:", 1)[1].split("    of 0x10:", 1)[0]
    result += (
        "proc rxuCheckBeaconParams(desc: pointer; vif: uint8; length: uint16; frame: pointer): bool =\n"
        "  me_beacon_check(vif, length, frame)\n"
        "  true\n"
        "proc receiveBeacon(frameHdr: pointer; bodyLen: uint16; staIdx, rxuEnvVifIdx: uint8): uint8 {.discardable.} =\n"
        "  let param: pointer = nil\n"
        "  let vifEntry = cast[pointer](addr vifs[rxuEnvVifIdx])\n"
        "  var skipSecHdr = false\n"
        "  var msgSubtype = 0xFF'u8\n"
        "  var frameAccepted = 1'u8\n"
        "  template currentFrame(): bool = true\n"
        "  case 0x80\n"
        "  of 0x80:" + beacon + "  else: discard\n"
    )
    return result + HELPERS


def run(tmp_path: Path, code: str, mode: str, *, transmit: bool = False) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "beacon_update.nim"
    path.write_text(source(transmit=transmit) + code)
    modes = {"checked": [], "release": ["-d:release"], "asan": ["--cc:clang",
             "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", *modes[mode], str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ie_search_requires_complete_element(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for size in 1 .. 3:
  let p = calloc(1, size.csize_t)
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  bytes[0] = 32
  if size >= 2: bytes[1] = 1
  if size >= 3: bytes[2] = 9
  doAssert mac_ie_find(p, size.uint32, 32) ==
    (if size == 3: p else: nil)
  free(p)
var random = 0x12345678'u32
for size in 0 .. 128:
  for iteration in 0 ..< 24:
    let p = calloc(1, max(size, 1).csize_t)
    let bytes = cast[ptr UncheckedArray[uint8]](p)
    for i in 0 ..< size:
      random = random * 1664525'u32 + 1013904223'u32
      bytes[i] = (random shr 24).uint8
    for id in [0'u8, 1, 32, 42, 255]:
      var expected: pointer
      var offset = 0
      while offset < size:
        if size - offset < 2: break
        let length = bytes[offset + 1].int + 2
        if length > size - offset: break
        if bytes[offset] == id:
          expected = cast[pointer](cast[uint](p) + offset.uint)
          break
        offset += length
      doAssert mac_ie_find(p, size.uint32, id) == expected
    free(p)
doAssert mac_ie_find(nil, 100, 0) == nil
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_parser_rejects_malformed_ies(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for suffix in [@[32'u8, 0], @[42'u8, 0], @[221'u8, 3, 1], @[99'u8]]:
  reset()
  let bss = vifBssStatus(addr vifs[0])
  bss.protectionFlags = 7
  bss.powerConstraint = 5
  var frame = newSeq[uint8](36)
  frame.add([42'u8, 1, 3, 32, 1, 9])
  frame.add(suffix)
  me_beacon_check(0, frame.len.uint16, addr frame[0])
  doAssert bss.protectionFlags == 7 and bss.powerConstraint == 5
  doAssert powerUpdates.len == 0 and channelUpdates.len == 0
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_parser_uses_bss_state_and_full_ie_length(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for vif in 0'u8 .. 1:
  for band in 0'u8 .. 1:
    for erp in 0'u8 .. 7:
      for constraint in [0'u8, 3, 17, 20, 100, 200, 255]:
        reset()
        channels[vif].band = band
        let bss = vifBssStatus(addr vifs[vif])
        bss[] = VifBssStatusOverlay(protectionFlags: 0xFFFF, bandwidth: 2,
          phyBandwidth: 1, powerConstraint: 5)
        var frame = newSeq[uint8](36)
        frame.add([0'u8, 50])
        for i in 0 ..< 50: frame.add(0)
        frame.add([42'u8, 1, erp, 32, 1, constraint])
        me_beacon_check(vif, frame.len.uint16, addr frame[0])
        doAssert bss.protectionFlags == (if band == 0: erp.uint16 else: 0'u16)
        doAssert bss.bandwidth == 2 and bss.phyBandwidth == 1
        doAssert bss.powerConstraint == constraint
        doAssert powerUpdates == @[(vif, max(17 - constraint.int, -128).int8)]
        doAssert vifs[vif xor 1].bss == default(typeof(vifs[0].bss))
        doAssert channelUpdates.len == 0
        me_beacon_check(vif, frame.len.uint16, addr frame[0])
        doAssert powerUpdates.len == 1, "unchanged constraint must not update power twice"
reset()
var frame = newSeq[uint8](36)
frame.add([42'u8, 0, 32, 0, 32, 1, 7])
me_beacon_check(0, 40, addr frame[0])
doAssert vifBssStatus(addr vifs[0]).powerConstraint == 0
doAssert vifBssStatus(addr vifs[0]).protectionFlags == 0
doAssert powerUpdates.len == 0, "read an IE beyond the supplied length"
for vif in 0'u8 .. 1:
  reset()
  frame = newSeq[uint8](36)
  frame.add([32'u8, 1, 3])
  contexts[vif].channel.txPower = 13'u8 + vif
  newBandwidth = 2
  me_beacon_check(vif, frame.len.uint16, addr frame[0])
  doAssert channelUpdates.len == 1
  let channel = channelUpdates[0]
  doAssert channel.ctxtIdx == vif + 1 and channel.band == 0 and channel.secChan == 2
  doAssert channel.primFreq == 2412 and channel.centerFreq1 == 2422
  doAssert channel.centerFreq2 == 2442 and channel.txPower == 13'u8 + vif
  doAssert channel.ctxtIdxBandPadding == 0 and channel.txPowerTailPadding == 0
reset()
let before = vifs
me_beacon_check(2, frame.len.uint16, addr frame[0])
me_beacon_check(0, 35, addr frame[0])
me_beacon_check(0, 36, nil)
doAssert vifs == before
vifs[0].operChan = nil
me_beacon_check(0, frame.len.uint16, addr frame[0])
doAssert powerUpdates.len == 0 and allocated.len == 0
reset()
frame = newSeq[uint8](36)
frame.add([42'u8, 1, 7, 32, 1, 3])
vifs[1].vifType = 0
receiveBeacon(addr frame[0], frame.len.uint16, 0, 1)
doAssert vifBssStatus(addr vifs[1]).protectionFlags == 7
doAssert vifBssStatus(addr vifs[1]).powerConstraint == 3
doAssert powerUpdates == @[(1'u8, 14'i8)]
doAssert vifs[0].bss == default(typeof(vifs[0].bss))
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_template_descriptor_ranges_and_deferred_commit(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for vif in 0'u8 .. 1:
  for prefix in [0, 1, 8, 100, 200, 255]:
    for suffix in [-1, 0, 30, 200, 211]:
      for nonempty in [false, true]:
        reset()
        var bytes = makeFrame(prefix, suffix)
        if bytes.len > 512: continue
        bytes[40 + prefix] = 0xA5
        bytes[42 + prefix] = 0x5A
        bytes[43 + prefix] = 0xC3
        if nonempty:
          vifs[vif].beaconEnabled = 1
          tim(17, 1, vif)
        let bitmapBefore = txl_tim_bitmap_pool
        var timBefore = txl_tim_ie_pool
        timBefore[3] = 3
        expectedCommit = vif.int
        let p = request(bytes, vif, prefix)
        env.transmitRequested = 1
        env.pendingCount = 1
        mm_bcn_change(p)
        doAssert env.templatePtr == p and env.deferredChange == 1
        doAssert confirmations.len == 0 and transmissions == 0
        guard(0)
        mm_bcn_transmitted(addr vifs[vif])
        doAssert confirmations == @[0'u8] and sentDestinations[^1] == 5
        doAssert allocated.len == 0 and transmissions == 1
        doAssert env.templatePtr == nil and env.pendingCount == 0
        let d = descriptors[vif]
        let base = pointerAddrU32(addr pool.bytes[348])
        doAssert d.payloadStart == base and d.payloadEnd == base + (37 + prefix).uint32
        doAssert d.status == pointerAddrU32(timDescView())
        doAssert d.chainedThd == cast[pointer](addr control)
        doAssert d.retryLimitControl == 0 and d.controlFlags == 0
        doAssert control.txPower == 0x78
        doAssert vifs[vif].beaconBodyLength == (bytes.len - 6).uint16
        doAssert txl_tim_ie_pool == timBefore
        doAssert txl_tim_bitmap_pool == bitmapBefore
        for i, value in bytes: doAssert pool.bytes[348 + i] == value
        guard(bytes.len)
        let next = if suffix >= 0: cast[pointer](beaconEndDesc()) else: nil
        doAssert timDescView().bitmapNext == next
        if nonempty:
          doAssert timDescView().next == addr timDescView().bitmapMagic
          tim(17, 0, vif)
        else:
          tim(17, 1, vif)
          doAssert timDescView().next == addr timDescView().bitmapMagic
          tim(17, 0, vif)
        doAssert timDescView().next == next
        if suffix >= 0:
          doAssert beaconEndDesc().payloadStart == base + (44 + prefix).uint32
          doAssert beaconEndDesc().payloadEnd == base + bytes.len.uint32 - 1
        else:
          doAssert beaconEndDesc().payloadStart == 0 and beaconEndDesc().payloadEnd == 0
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_template_does_not_publish_success_or_modify_beacon(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for failure in 0 .. 12:
  reset()
  var bytes = makeFrame()
  if failure == 0: bytes[0] = 0x50
  if failure == 1: bytes.setLen(35)
  if failure == 2: bytes[38] = 9
  if failure == 3: bytes[39] = 255
  if failure == 4: bytes[41] = 0
  if failure == 5: bytes.add([5'u8, 4, 0, 1, 0, 0])
  if failure == 6: bytes.setLen(513)
  let p = request(bytes)
  let req = beaconChangeReqAt(p)
  case failure
  of 7: req.timOffset = 37
  of 8: req.timLength = 5
  of 9: req.vifIdx = 255
  of 10: vifs[0].vifType = 0
  of 11: vifs[0].beaconTxDesc = nil
  of 12: keMsgHdrFromPayload(p).paramLen = 11
  else: discard
  let beforeVifs = vifs
  let beforeDescriptors = descriptors
  let beforeTim = txl_tim_desc
  mm_bcn_change(p)
  doAssert confirmations == @[1'u8] and allocated.len == 0
  doAssert vifs == beforeVifs and descriptors == beforeDescriptors
  doAssert txl_tim_desc == beforeTim and transmissions == 0
  doAssert env.templatePtr == nil and env.active == 0 and env.deferredChange == 0
  guard(0)
doAssert mm_bcn_update(nil) == nil
''', mode)
