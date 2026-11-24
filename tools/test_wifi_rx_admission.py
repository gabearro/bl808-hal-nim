"""Exercise descriptor identity and frame bounds before RX peer processing."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_policy import compile_and_run

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const STA_INFO_TAB_ENTRIES = 7
const STA_MGMT_FREE_STAS = 5
const MAX_VIFS = 2
type
  RxStationIdentity = object
    epoch: uint32
    vifEpochs: array[MAX_VIFS, uint32]
    keyRevision: uint64
    station, vif: uint8
    captured, associated: bool
    channelCaptured: bool
    channelGeneration: uint32
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  RxMpduDescView = object
    link: CoListHdr
    swDesc: pointer
    bufferChain: uint
    prevDesc, curDesc: pointer
    descFlag, descCount: uint8
  RxSwTableDescView = RxMpduDescView
  RxSwDescView = object
    next: pointer
    swDesc, bufferAddr: uint32
    bufferChain: pointer
    mpduLengthBytes, frameLen: uint16
    flags, status, hwFlags, uploadDone: uint32
    channelInfo: array[8, uint8]
  RxHeaderHwDescView = RxSwDescView
  RxlSubmittedDescView = RxSwDescView
  RxPayloadHwDescView = object
    next: pointer
    bufferAddr, bufferStart: uint32
    frameData: pointer
    status, usedFlag: uint32
    frameLen: uint16
  RxDmaProgressDescView = RxPayloadHwDescView
  RxPayloadBufferView = object
    payloadBytes: array[1736, uint8]
  StaInfoView = object
    valid, instNbr: uint8
    connectionStart: uint32
  VifChannelView = object
    vifType, vifIdx, state: uint8
    chanCtxt: pointer
    tbttTimer: tuple[expiry: uint32]
  RxlCntrlEnvView = object
    queue: CoList
    submittedHead: pointer
    processingFlag: uint8
  RxuEnv = object
    uploadList: CoList
  Frame = object
    frameControl: uint16
  RxFrameAdmission = enum
    rxFrameCorrupt, rxFrameDrop, rxFrameReady
var
  rx_dma_hdrdesc: array[41 * sizeof(RxHeaderHwDescView), uint8]
  rx_swdesc_tab: array[41 * sizeof(RxSwTableDescView), uint8]
  rx_payload_desc: array[41 * sizeof(RxPayloadHwDescView), uint8]
  buffers: array[41, RxPayloadBufferView]
  env: RxlCntrlEnvView
  upperEnv: RxuEnv
  stas: array[7, StaInfoView]
  vifs: array[2, VifChannelView]
  powerCalls, clockCalls, upperCalls, freed, recovered, appended: int
  beaconStorage: pointer
  beaconAllocations, beaconFrees, timChecks, meChecks: int
  onBeaconAllocate: proc()
  beaconAllocationFails: bool
  uploadResult: uint32
  lastUpperFlags: uint32
  interrupts = true
  events: uint32
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  rxInitializationEpoch: uint32
  rxVifEpochs: array[MAX_VIFS, uint32]
  rxKeyRevision = 1'u64
  stationEpochs: array[5, uint32]
  onTick, onPower: proc()
  assertIrqs: seq[bool]
  rxlControlActive: bool
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc rxCaptureStation(desc: pointer; flags: uint32; statusWord: ptr uint32 = nil)
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc rxHeaderHwDescAt(i: int): ptr RxHeaderHwDescView =
  cast[ptr RxHeaderHwDescView](addr rx_dma_hdrdesc[i * sizeof(RxHeaderHwDescView)])
proc rxHeaderHwDescView(p: pointer): ptr RxHeaderHwDescView = cast[ptr RxHeaderHwDescView](p)
proc rxSwTableDescAt(i: int): ptr RxSwTableDescView =
  cast[ptr RxSwTableDescView](addr rx_swdesc_tab[i * sizeof(RxSwTableDescView)])
proc rxPayloadHwDescAt(i: int): ptr RxPayloadHwDescView =
  cast[ptr RxPayloadHwDescView](addr rx_payload_desc[i * sizeof(RxPayloadHwDescView)])
proc rxPayloadBufferAt(i: int): ptr RxPayloadBufferView = addr buffers[i]
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc rxMpduDescView(p: pointer): ptr RxMpduDescView = cast[ptr RxMpduDescView](p)
proc rxMpduDescView(p: uint32): ptr RxMpduDescView = cast[ptr RxMpduDescView](p.uint)
proc rxDmaProgressDescAt(p: pointer): ptr RxDmaProgressDescView = cast[ptr RxDmaProgressDescView](p)
proc rxFrameBufferChainAt(p: pointer): ptr RxPayloadHwDescView = cast[ptr RxPayloadHwDescView](p)
proc rxFramePayload(sw: ptr RxSwDescView): pointer = rxFrameBufferChainAt(sw.bufferChain).frameData
proc beaconRxDescView(p: pointer): ptr RxSwDescView = rxSwDescView(p)
proc macDataFrameAt(p: pointer): ptr Frame = cast[ptr Frame](p)
proc rxlCntrlEnvView(): ptr RxlCntrlEnvView = addr env
proc rxuCntrlEnvView(): ptr RxuEnv = addr upperEnv
proc staInfoForIdx(i: uint8): ptr StaInfoView = addr stas[i]
proc staConnectionStartWord(p: ptr StaInfoView): ptr uint32 = addr p.connectionStart
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc co_list_pop_front(list: ptr CoList): pointer =
  doAssert not interrupts
  result = list.first
  list.first = list.first.next
  if list.first == nil: list.last = nil
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc assert_rec(condition, file: cstring; line: int) =
  assertIrqs.add(interrupts)
  inc recovered
proc ke_evt_clear(mask: uint32) = events = events and not mask
proc ke_evt_set(mask: uint32) = events = events or mask
proc regWrite(address: uint; value: uint32) = discard
proc phy_get_channel_raw(info: pointer; index: uint8) =
  zeroMem(info, 8)
proc tick(): uint32 {.cdecl.} =
  inc clockCalls
  if onTick != nil: onTick()
  0x12345678
proc allocateBeacon(size: uint32): pointer {.cdecl.} =
  doAssert interrupts and beaconStorage == nil and size > 1736 and size <= 2328
  inc beaconAllocations
  if onBeaconAllocate != nil: onBeaconAllocate()
  if beaconAllocationFails: return nil
  beaconStorage = alloc(size.int)
  beaconStorage
proc freeBeacon(p: pointer) {.cdecl.} =
  doAssert interrupts and p == beaconStorage
  inc beaconFrees
  beaconStorage = nil
  dealloc(p)
proc blOpsFunc(slot: int): pointer =
  case slot
  of 184: cast[pointer](allocateBeacon)
  of 188: cast[pointer](freeBeacon)
  of 200: cast[pointer](tick)
  else: nil
proc rxlHandleApPowerSave(vif: ptr VifChannelView; sta: ptr StaInfoView;
                          index: uint8; frame: pointer) =
  inc powerCalls
  if onPower != nil: onPower()
proc rxu_cntrl_frame_handle(p: pointer): uint32 =
  doAssert beaconStorage == nil, "beacon scratch escaped into RX upper"
  inc upperCalls
  lastUpperFlags = rxSwDescView(rxMpduDescView(p).swDesc).hwFlags
  uploadResult
proc rxl_mpdu_free(p: pointer) = inc freed
proc rxl_hd_append(p: pointer) =
  inc appended
  rxHeaderHwDescView(p).flags = 0
  rxHeaderHwDescView(p).status = 0
var beaconChange: uint32
var beaconChecks, wmmChecks: int
proc td_pck_ind(vif, sta, count: uint8) = discard
proc mm_check_beacon(p, vif, sta: pointer; tim: ptr uint32): uint32 =
  inc beaconChecks
  beaconChange
proc mmCheckBeaconFrame(p, vif, sta, data: pointer; tim: var pointer): uint32 =
  inc beaconChecks
  doAssert data != nil and data == beaconStorage
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  doAssert bytes[1735] == 5 and bytes[1736] == 4
  if rxSwDescView(p).mpduLengthBytes >= 1741:
    tim = addr bytes[1735]
  beaconChange
proc rxlObserveStaWmm(p: pointer; vif: ptr VifChannelView; sta: ptr StaInfoView;
                     data: pointer) =
  doAssert data == beaconStorage
  inc wmmChecks
proc ps_check_beacon(tim: pointer; length: uint32; vif: pointer) =
  if tim != nil:
    let bytes = cast[ptr UncheckedArray[uint8]](tim)
    doAssert beaconStorage != nil and bytes[0] == 5 and bytes[1] == 4
    doAssert bytes[4] == 0x22 and bytes[5] == 0x33
    inc timChecks
proc me_beacon_check(vif: uint8; length: uint16; frame: pointer) =
  doAssert vif == 0 and length == 1741 and frame == beaconStorage
  let bytes = cast[ptr UncheckedArray[uint8]](frame)
  doAssert bytes[1735] == 5 and bytes[1736] == 4 and bytes[1740] == 0x33
  inc meChecks
proc vif_mgmt_bcn_recv(vif: pointer) = discard
proc chan_tbtt_switch_update(vif: pointer; expiry: uint32) = discard
proc ps_check_frame(p: pointer; flags: uint32; vif: pointer) = discard
proc nimFwTrace2U32(label: string; a, b: uint32) = discard
proc reset(fc: uint16; length: uint16; count = 1) =
  zeroMem(addr rx_dma_hdrdesc[0], sizeof(rx_dma_hdrdesc))
  zeroMem(addr rx_swdesc_tab[0], sizeof(rx_swdesc_tab))
  zeroMem(addr rx_payload_desc[0], sizeof(rx_payload_desc))
  env = default(RxlCntrlEnvView)
  upperEnv = default(RxuEnv)
  powerCalls = 0
  clockCalls = 0
  beaconChange = 1
  beaconChecks = 0
  wmmChecks = 0
  beaconAllocations = 0
  beaconFrees = 0
  timChecks = 0
  meChecks = 0
  onBeaconAllocate = nil
  beaconAllocationFails = false
  uploadResult = 0
  upperCalls = 0
  lastUpperFlags = 0
  freed = 0
  recovered = 0
  assertIrqs.setLen(0)
  appended = 0
  interrupts = true
  events = 0x100000
  rxInitializationEpoch = 0
  onTick = nil
  onPower = nil
  for i in 0 ..< 41:
    rxSwTableDescAt(i).swDesc = rxHeaderHwDescAt(i)
    rxHeaderHwDescAt(i).swDesc = pointerAddrU32(rxSwTableDescAt(i))
  let sw = rxHeaderHwDescAt(0)
  sw.mpduLengthBytes = length
  sw.frameLen = length
  sw.hwFlags = 0x02006000'u32 or (12'u32 shl 15)
  sw.flags = sw.hwFlags or 0x4000
  sw.status = sw.flags
  if count > 0:
    sw.bufferChain = rxPayloadHwDescAt(0)
    sw.bufferAddr = pointerAddrU32(sw.bufferChain)
  for i in 0 ..< count:
    let pd = rxPayloadHwDescAt(i)
    pd.bufferAddr = pointerAddrU32(addr buffers[i].payloadBytes[0])
    pd.bufferStart = pd.bufferAddr
    pd.frameData = addr buffers[i].payloadBytes[0]
    if i + 1 < count: pd.next = rxPayloadHwDescAt(i + 1)
    else: pd.status = 1
  cast[ptr uint16](addr buffers[0].payloadBytes[0])[] = fc
  stas[4] = StaInfoView(valid: 1)
  vifs[0] = VifChannelView(vifIdx: 0, vifType: 2)
  for i in 0 ..< 41:
    rxCaptureStation(rxSwTableDescAt(i), sw.hwFlags)
proc dispatch() =
  env.queue.first = addr rxSwTableDescAt(0).link
  env.queue.last = env.queue.first
  rxl_cntrl_evt()
"""

CHECKS = r"""
# Truncated data and QoS frames must be dropped before peer activity or PS work.
for pair in [(0x0208'u16, 23'u16), (0x0288'u16, 25'u16),
             (0x0388'u16, 31'u16), (0x8388'u16, 35'u16),
             (0x0080'u16, 35'u16), (0x10A4'u16, 15'u16), (0x00D4'u16, 9'u16)]:
  reset(pair[0], pair[1])
  dispatch()
  doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0, "short frame reached peer processing"
  doAssert freed == 1 and recovered == 0 and stas[4].connectionStart == 0

for pair in [(0x0208'u16, 24'u16), (0x0288'u16, 26'u16),
             (0x0388'u16, 32'u16), (0x8388'u16, 36'u16),
             (0x0080'u16, 36'u16), (0x10A4'u16, 16'u16), (0x00D4'u16, 10'u16)]:
  reset(pair[0], pair[1])
  dispatch()
  doAssert powerCalls == 1 and clockCalls == 1 and upperCalls == 1
  doAssert freed == 1 and recovered == 0 and interrupts

when declared(rxAdmitMpdu):
  var header: ptr RxSwDescView
  for index in 0 ..< 41:
    reset(0x0208, 24)
    rxHeaderHwDescAt(index)[] = rxHeaderHwDescAt(0)[]
    rxHeaderHwDescAt(index).swDesc = pointerAddrU32(rxSwTableDescAt(index))
    doAssert rxAdmitMpdu(rxSwTableDescAt(index), header) == rxFrameReady
    doAssert header == rxHeaderHwDescAt(index)
    for wrong in 0 ..< 41:
      if wrong == index: continue
      rxSwTableDescAt(index).swDesc = rxHeaderHwDescAt(wrong)
      doAssert rxAdmitMpdu(rxSwTableDescAt(index), header) == rxFrameCorrupt
    rxSwTableDescAt(index).swDesc = rxHeaderHwDescAt(index)
  for variant in 0 .. 10:
    reset(0x0208, 24)
    let desc = rxSwTableDescAt(0)
    case variant
    of 0: desc.swDesc = nil
    of 1: desc.swDesc = cast[pointer](1'u)
    of 2: desc.swDesc = rxHeaderHwDescAt(1)
    of 3: rxHeaderHwDescAt(0).swDesc = pointerAddrU32(rxSwTableDescAt(1))
    of 4: rxHeaderHwDescAt(0).bufferChain = nil
    of 5: rxPayloadHwDescAt(0).next = rxPayloadHwDescAt(0); rxPayloadHwDescAt(0).status = 0
    of 6: rxPayloadHwDescAt(0).bufferAddr = 1
    of 7: rxPayloadHwDescAt(0).bufferStart = 1
    of 8: rxHeaderHwDescAt(0).uploadDone = 1
    of 9: rxPayloadHwDescAt(0).usedFlag = 1
    else: rxHeaderHwDescAt(0).hwFlags = rxHeaderHwDescAt(0).hwFlags and not 0x4000'u32
    dispatch()
    doAssert recovered == 1 and freed == 0 and powerCalls == 0 and clockCalls == 0
    doAssert assertIrqs == @[true]
  for invalid in [cast[pointer](1'u), cast[pointer](addr rx_swdesc_tab[1]),
                  cast[pointer](cast[uint](addr rx_swdesc_tab[0]) + sizeof(rx_swdesc_tab).uint)]:
    reset(0x0208, 24)
    env.queue.first = cast[ptr CoListHdr](invalid)
    rxl_cntrl_evt()
    doAssert recovered == 1 and powerCalls == 0 and clockCalls == 0
    doAssert assertIrqs == @[true]
  for length in [0'u16, 1737'u16, 65535'u16]:
    reset(0x0208, length)
    dispatch()
    doAssert freed == 1 and recovered == 0 and powerCalls == 0
  reset(0x0208, 1737, 2)
  dispatch()
  doAssert recovered == 0 and upperCalls == 1 and freed == 1
  reset(0x0208, 24, 2)
  dispatch()
  doAssert recovered == 0 and upperCalls == 0 and freed == 1
  for fc in [0x0209'u16, 0x020A'u16, 0x020B'u16, 0x000C'u16]:
    reset(fc, 40)
    dispatch()
    doAssert recovered == 0 and powerCalls == 0 and clockCalls == 0 and freed == 1
  reset(0x0208, 24)
  rxHeaderHwDescAt(0).hwFlags = rxHeaderHwDescAt(0).hwFlags and not 0x2000'u32
  dispatch()
  doAssert recovered == 0 and powerCalls == 0 and clockCalls == 0 and freed == 1
  reset(0x0208, 24)
  rxSwTableDescAt(0).link.next = cast[ptr CoListHdr](1'u)
  dispatch()
  doAssert recovered == 1 and powerCalls == 0 and clockCalls == 0 and freed == 0
  doAssert assertIrqs == @[true]

  # Timer identity validation happens before publishing a queue node.
  for variant in 0 .. 5:
    reset(0x0208, 24)
    env.submittedHead = rxHeaderHwDescAt(0)
    case variant
    of 0: env.submittedHead = cast[pointer](1'u)
    of 1: env.submittedHead = addr rx_dma_hdrdesc[1]
    of 2: rxHeaderHwDescAt(0).swDesc = 1
    of 3: rxHeaderHwDescAt(0).swDesc = pointerAddrU32(rxSwTableDescAt(1))
    of 4: rxSwTableDescAt(0).swDesc = rxHeaderHwDescAt(1)
    else: rxHeaderHwDescAt(0).next = rxHeaderHwDescAt(0)
    rxl_timer_int_handler()
    doAssert recovered == 1 and powerCalls == 0
    doAssert assertIrqs == @[false] and interrupts
  reset(0x0208, 24)
  env.submittedHead = rxHeaderHwDescAt(0)
  rxl_timer_int_handler()
  doAssert recovered == 0 and env.queue.first == addr rxSwTableDescAt(0).link
  reset(0, 0, 0)
  env.submittedHead = rxHeaderHwDescAt(0)
  rxl_timer_int_handler()
  doAssert recovered == 0 and appended == 1 and env.queue.first == nil
  reset(0x0208, 24)
  rxHeaderHwDescAt(0).flags = 0
  rxHeaderHwDescAt(0).swDesc = 1
  env.submittedHead = rxHeaderHwDescAt(0)
  rxl_timer_int_handler()
  doAssert recovered == 0 and appended == 0 and env.queue.first == nil
"""


def admission_source(checks=""):
    lower = (FW / "rx_layer.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    names = ["rxMacHeaderLen", "rxHeaderDescIndex", "rxMpduDescIndex", "rxMpduHeader",
             "rxForgetStation", "rxUploadGeneration", "rxUploadCurrent", "rxInvalidateQuiescentVif", "rxInvalidateVif",
             "rxCaptureStation", "rxIdentityCurrent", "rxStationCurrent", "rxCaptureChannel",
             "rxCapturedChannelCurrent", "rxReadCapturedChannel",
             "rxPayloadDescIndex", "rxPayloadBufferValid", "rxPayloadChainBounds", "rxBeaconLengthSupported", "rxAdmitMpdu",
             "rxFrameCurrent", "rxCaptureFrame", "rxCaptureFrameHeader", "rxReleaseUpload",
             "rxOpenBeaconView", "rxCloseBeaconView", "rxReleaseControlFrame",
             "rxl_cntrl_evt", "rxlScheduleQueuedRx", "submittedRxReady", "rxl_timer_int_handler"]
    procedures = ""
    for name in names:
        source = layout if name == "rxMacHeaderLen" else lower
        if re.search(rf"proc {name}\*?\(", source):
            procedures += procedure(source, name)
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", procedures))))
    platform, setup = PLATFORM.split("proc dispatch()", 1)
    identity = re.search(r"(?m)^  RxFrameIdentity = object\n(?:    [^\n]*\n)+", layout)
    beacon_view = re.search(r"(?m)^  RxBeaconView = object\n(?:    [^\n]*\n)+", layout)
    identity_source = "type\n" + identity.group(0) + beacon_view.group(0)
    upper = procedure((FW / "task_handlers.nim").read_text(), "rxuCheckBeaconParams")
    return identity_source + platform + debug + procedures + upper + "\nproc dispatch()" + setup + checks


def run_admission(mode, tmp_path, checks):
    compile_and_run(tmp_path, mode, admission_source(checks))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_admission(mode, tmp_path):
    run_admission(mode, tmp_path, CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_update_runs_without_crc_change(mode, tmp_path):
    run_admission(mode, tmp_path, r"""
for status in [0'u32, 1, high(uint32)]:
  reset(0x0080, 36)
  vifs[0].vifType = 0
  vifs[0].state = 1
  beaconChange = status
  dispatch()
  doAssert beaconChecks == 1 and wmmChecks == int(status != high(uint32))
  doAssert upperCalls == int(status == 1)
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_split_beacon_uses_nonadjacent_buffers_and_preserves_rx_ownership(mode, tmp_path):
    run_admission(mode, tmp_path, r"""
proc splitBeacon(length: uint16) =
  reset(0x0080, length, 3)
  # The intervening physical buffer is not in the MPDU chain.
  rxPayloadHwDescAt(0).next = rxPayloadHwDescAt(2)
  buffers[0].payloadBytes[1735] = 5
  buffers[1].payloadBytes[0] = 0xFF
  buffers[2].payloadBytes[0 .. 4] = [4'u8, 0, 1, 0x22, 0x33]
  vifs[0].vifType = 0
  vifs[0].state = 1

for length in [1737'u16, 1741'u16, 2328'u16]:
  for transfer in [0'u32, 1'u32]:
    splitBeacon(length)
    uploadResult = transfer
    dispatch()
    doAssert beaconChecks == 1 and wmmChecks == 1 and upperCalls == 1
    doAssert timChecks == int(length >= 1741)
    doAssert beaconAllocations == 1 and beaconFrees == 1 and recovered == 0
    doAssert freed == int(transfer == 0) and interrupts
    doAssert rxPayloadHwDescAt(0).next == rxPayloadHwDescAt(2)

splitBeacon(1741)
let desc = cast[pointer](rxSwTableDescAt(0))
doAssert rxuCheckBeaconParams(desc, 0, 1741, addr buffers[0].payloadBytes[0])
doAssert meChecks == 1 and beaconAllocations == 1 and beaconFrees == 1 and freed == 0

for fault in 0 ..< 4:
  splitBeacon(if fault == 0: 2329'u16 else: 1741'u16)
  case fault
  of 1: beaconAllocationFails = true
  of 2: onBeaconAllocate = proc() = inc rxUploadEpochs[0]
  of 3: onBeaconAllocate = proc() = rxPayloadHwDescAt(2).bufferStart = 0
  else: discard
  dispatch()
  doAssert beaconChecks == 0 and wmmChecks == 0 and upperCalls == 0
  doAssert beaconAllocations == int(fault != 0) and beaconFrees == int(fault >= 2)
  doAssert freed == int(fault != 2) and beaconStorage == nil and interrupts

reset(0x0050, 1737, 2)
dispatch()
doAssert upperCalls == 1 and freed == 1 and beaconAllocations == 0
reset(0x0050, 2353, 2)
dispatch()
doAssert upperCalls == 0 and freed == 1 and beaconAllocations == 0
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_station_tag_is_cleared_before_rx_queue_publication(mode, tmp_path):
    run_admission(mode, tmp_path, r"""
for frameControl in [0x0050'u16, 0x0080'u16]:
  for reuseSlot in [false, true]:
    reset(frameControl, 36)
    let header = rxHeaderHwDescAt(0)
    let expected = header.hwFlags and not 0x02000000'u32
    stas[4].valid = 0
    env.submittedHead = header
    rxl_timer_int_handler()
    doAssert header.hwFlags == expected and rxStationCurrent(rxSwTableDescAt(0))
    if reuseSlot:
      inc stationEpochs[4]
      stas[4] = StaInfoView(valid: 1, instNbr: 1, connectionStart: 123)
    rxl_cntrl_evt()
    doAssert upperCalls == 1 and lastUpperFlags == expected and freed == 1
    doAssert clockCalls == 0 and powerCalls == 0
    if reuseSlot: doAssert stas[4].connectionStart == 123

  reset(frameControl, 36)
  let header = rxHeaderHwDescAt(0)
  env.submittedHead = header
  rxl_timer_int_handler()
  inc stationEpochs[4]
  stas[4].valid = 0
  rxl_cntrl_evt()
  doAssert upperCalls == 0 and freed == 1
  doAssert (header.hwFlags and 0x02000000'u32) != 0

for hardwareIndex in [7'u32, 8'u32 + STA_INFO_TAB_ENTRIES.uint32]:
  reset(0x0080, 36)
  let header = rxHeaderHwDescAt(0)
  header.hwFlags = 0x02006000'u32 or (hardwareIndex shl 15)
  env.submittedHead = header
  rxl_timer_int_handler()
  rxl_cntrl_evt()
  doAssert upperCalls == 0 and freed == 1
  doAssert (header.hwFlags and 0x02000000'u32) != 0
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_queued_station_reuse(mode, tmp_path):
    run_admission(mode, tmp_path, r"""
reset(0x0208, 24)
# The slot is still valid and on the same VIF, but belongs to a new session.
inc stationEpochs[4]
dispatch()
doAssert freed == 1 and recovered == 0
doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0,
  "old RX frame reached a reused station"

when declared(rxStationCurrent):
  for index in 0 ..< 41:
    for station in 0'u8 .. 6:
      for vif in 0'u8 .. 1:
        reset(0x0208, 24)
        stas[station] = StaInfoView(valid: 1, instNbr: vif)
        let desc = cast[pointer](rxSwTableDescAt(index))
        rxCaptureStation(desc, 0x02006000'u32 or ((station.uint32 + 8) shl 15))
        doAssert rxStationCurrent(desc)
        stas[station].valid = 0
        doAssert not rxStationCurrent(desc)
        stas[station].valid = 1
        stas[station].instNbr = vif xor 1
        doAssert not rxStationCurrent(desc)
        stas[station].instNbr = vif
        if station < 5:
          inc stationEpochs[station]
          doAssert not rxStationCurrent(desc)
          rxCaptureStation(desc, 0x02006000'u32 or ((station.uint32 + 8) shl 15))
          doAssert rxStationCurrent(desc)
        rxForgetStation(rxHeaderHwDescAt(index))
        doAssert not rxStationCurrent(desc)

  # Capture is done while transferring a completed descriptor to software.
  reset(0x0208, 24)
  rxStationIdentities = default(typeof(rxStationIdentities))
  env.submittedHead = rxHeaderHwDescAt(0)
  rxl_timer_int_handler()
  doAssert rxStationCurrent(rxSwTableDescAt(0))
  inc stationEpochs[4]
  rxl_cntrl_evt()
  doAssert freed == 1 and powerCalls == 0 and upperCalls == 0

  # A returning platform callback must not update the newly reused slot.
  reset(0x0208, 24)
  onTick = proc() =
    inc stationEpochs[4]
    stas[4].connectionStart = 0xFEED
  dispatch()
  doAssert stas[4].connectionStart == 0xFEED
  doAssert clockCalls == 1 and powerCalls == 0 and upperCalls == 0 and freed == 1
  reset(0x0208, 24)
  onPower = proc() = inc stationEpochs[4]
  dispatch()
  doAssert powerCalls == 1 and upperCalls == 0 and freed == 1

  reset(0x0208, 24)
  rxCaptureStation(rxSwTableDescAt(0), 0x6000)
  inc stationEpochs[4]
  doAssert rxStationCurrent(rxSwTableDescAt(0)), "unbound frame gained a station"
  rxStationIdentities = default(typeof(rxStationIdentities))
  doAssert not rxStationCurrent(rxSwTableDescAt(0))
  doAssert not rxStationCurrent(cast[pointer](1))
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_queued_vif_reuse(mode, tmp_path):
    run_admission(mode, tmp_path, r"""
for station in 0'u8 .. 6:
  for vif in 0'u8 .. 1:
    reset(0x0208, 24)
    stas[station] = StaInfoView(valid: 1, instNbr: vif)
    let flags = 0x02006000'u32 or ((station.uint32 + 8) shl 15)
    rxHeaderHwDescAt(0).hwFlags = flags
    rxCaptureStation(rxSwTableDescAt(0), flags)
    discard rxInvalidateVif(vif xor 1)
    doAssert rxStationCurrent(rxSwTableDescAt(0))
    discard rxInvalidateVif(vif)
    dispatch()
    doAssert freed == 1 and recovered == 0
    doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_header_lengths(mode, tmp_path):
    layout = (FW / "layout_types.nim").read_text()
    source = ""
    if "proc rxMacHeaderLen(" in layout:
        source += procedure(layout, "rxMacHeaderLen")
    source += procedure((FW / "rx_upper.nim").read_text(), "rxu_cntrl_machdr_len_get")
    source += r"""
for raw in 0 .. 65535:
  let fc = raw.uint16
  var expected = 0
  case fc and 12
  of 0:
    expected = 24 + (if (fc and 0x8000) != 0: 4 else: 0)
  of 4:
    expected = if (fc and 0xE0) == 0xC0: 10 else: 16
  of 8:
    expected = if (fc and 0x300) == 0x300: 30 else: 24
    if (fc and 0x80) != 0:
      expected += 2
      if (fc and 0x8000) != 0: expected += 4
  else: discard
  doAssert rxu_cntrl_machdr_len_get(fc).int == expected, "incorrect header length for " & $raw
"""
    compile_and_run(tmp_path, mode, source)
