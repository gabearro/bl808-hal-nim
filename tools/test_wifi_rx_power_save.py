"""Run production RX event/power-save logic with message and ownership checks."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
proc rxStationCurrent(p: pointer): bool = true
import bl808/wifi/fw_messages
const VIF_TYPE_AP = 2'u8
const STA_INFO_TAB_ENTRIES = 7
const STA_MGMT_FREE_STAS = 5
const MAX_VIFS = 2
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  RxMpdu = object
    link: CoListHdr
    swDesc: pointer
  SwDesc = object
    bufferChain: pointer
    hwFlags: uint32
    frameLen: uint16
  RxSwDescView = SwDesc
  BufferChain = object
    frameData: pointer
  RxFrameAdmission = enum
    rxFrameCorrupt, rxFrameDrop, rxFrameReady
  StaInfoView = object
    valid, instNbr, psMode, psState, uapsdBitmap, infoIdx, trafficFlags: uint8
    psStatus, connectionStart: uint32
    aid: uint16
  VifChannelView = object
    vifType, vifIdx, state, psBaCounter: uint8
    chanCtxt: pointer
    tbttTimer: tuple[expiry: uint32]
  RxlCntrlEnvView = object
    queue: CoList
    processingFlag: uint8
  Action = tuple[kind: string, a, b, c: uint32]
var
  stas: array[7, StaInfoView]
  vifs: array[2, VifChannelView]
  env: RxlCntrlEnvView
  actions: seq[Action]
  txCount: uint32
  afterTraffic: uint8
  uploadResult: uint8
  interruptsEnabled = true
  eventBits: uint32
  clearCount: int
  allocation: array[8, uint8]
  allocId: uint16
  beaconInput: pointer
  beaconResult: uint32
  beaconTim = 0x12345678'u32
  currentFrame: pointer
  psFrameCount: int
  rxlControlActive: bool
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[7, uint32]

proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc ke_msg_free_payload(p: pointer) = discard
proc staInfoForIdx(i: uint8): ptr StaInfoView = addr stas[i]
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc rxlCntrlEnvView(): ptr RxlCntrlEnvView = addr env
proc rxMpduDescView(p: pointer): ptr RxMpdu = cast[ptr RxMpdu](p)
proc rxSwDescView(p: pointer): ptr SwDesc = cast[ptr SwDesc](p)
proc rxFrameBufferChainAt(p: pointer): ptr BufferChain = cast[ptr BufferChain](p)
proc rxMpduDescIndex(p: pointer): int = (if p == nil: -1 else: 0)
proc rxAdmitMpdu(p: pointer; header: var ptr SwDesc): RxFrameAdmission =
  header = rxSwDescView(rxMpduDescView(p).swDesc)
  if header.bufferChain == nil or rxFrameBufferChainAt(header.bufferChain).frameData == nil:
    rxFrameDrop
  else:
    rxFrameReady
proc beaconRxDescView(p: pointer): ptr SwDesc = cast[ptr SwDesc](p)
proc macDataFrameAt(p: pointer): ptr MacDataFrameHeaderView = cast[ptr MacDataFrameHeaderView](p)
proc macQosDataFrameAt(p: pointer): ptr MacQosDataFrameHeaderView = cast[ptr MacQosDataFrameHeaderView](p)
proc macQos4AddrFrameAt(p: pointer): ptr MacQos4AddrFrameHeaderView = cast[ptr MacQos4AddrFrameHeaderView](p)
proc staConnectionStartWord(p: ptr StaInfoView): ptr uint32 = addr p.connectionStart
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc nimFwTrace2U32(s: string; a, b: uint32) = discard
proc tick(): uint32 {.cdecl.} = 0xABCD1234'u32
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 200, "RX last-seen time must use platform slot 200"
  cast[pointer](tick)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(previous: uint32) = interruptsEnabled = (previous and 8) != 0
proc co_list_pop_front(list: ptr CoList): pointer =
  doAssert not interruptsEnabled
  let node = list.first
  if node == nil: return nil
  list.first = node.next
  if list.first == nil: list.last = nil
  cast[pointer](node)
proc ke_evt_clear(bits: uint32) =
  eventBits = eventBits and not bits
  inc clearCount
proc ke_evt_set(bits: uint32) = eventBits = eventBits or bits
proc assert_rec(cond, file: cstring; line: int) = doAssert false, "unexpected RX assertion"
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert dest == 9 and src == 0
  doAssert (id == 55 and size == 2) or (id == 56 and size == 3)
  allocation = default(typeof(allocation))
  allocId = id
  addr allocation[0]
proc ke_msg_send(p: pointer) =
  doAssert p == addr allocation[0]
  if allocId == 55:
    actions.add(("ps", allocation[0].uint32, allocation[1].uint32, 0'u32))
  else:
    actions.add(("traffic", allocation[0].uint32, allocation[1].uint32, allocation[2].uint32))
proc apm_tx_int_ps_clear(vif: pointer; sta: uint8) =
  doAssert vif == addr vifs[1]
  actions.add(("clear", sta.uint32, 0'u32, 0'u32))
proc sta_mgmt_send_postponed_frame(vif, sta: pointer; budget: uint32): uint32 =
  doAssert vif == cast[pointer](addr vifs[1]) and sta == cast[pointer](addr stas[4])
  actions.add(("send", 4'u32, budget, stas[4].psStatus))
  stas[4].trafficFlags = afterTraffic
  txCount
proc txl_frame_send_qosnull_frame(sta: uint8; qos: uint16; cb: pointer; arg: uint32): uint8 =
  doAssert cb == nil and arg == 0
  actions.add(("null", sta.uint32, qos.uint32, stas[4].psStatus))
  1
proc rxu_cntrl_frame_handle(p: pointer): uint8 =
  actions.add(("upper", 0'u32, 0'u32, 0'u32))
  uploadResult
proc rxl_mpdu_free(p: pointer) = actions.add(("free", 0'u32, 0'u32, 0'u32))
proc td_pck_ind(vif, sta, count: uint8) = actions.add(("td", vif.uint32, sta.uint32, count.uint32))
proc mm_check_beacon(p, vif, sta: pointer; tim: ptr uint32): uint32 =
  doAssert p == beaconInput and vif == cast[pointer](addr vifs[0]) and sta == cast[pointer](addr stas[4])
  tim[] = beaconTim
  actions.add(("beacon", 0'u32, 0'u32, 0'u32))
  beaconResult
proc ps_check_beacon(tim: pointer; length: uint32; vif: pointer) =
  doAssert cast[uint](tim) == beaconTim.uint and length == 123 and vif == cast[pointer](addr vifs[0])
  actions.add(("beacon-ps", 0'u32, 0'u32, 0'u32))
proc vif_mgmt_bcn_recv(vif: pointer) = actions.add(("beacon-vif", 0'u32, 0'u32, 0'u32))
proc chan_tbtt_switch_update(vif: pointer; expiry: uint32) =
  doAssert vif == cast[pointer](addr vifs[0]) and expiry == 0x3456
  actions.add(("tbtt", 0'u32, 0'u32, 0'u32))
proc ps_check_frame(p: pointer; flags: uint32; vif: pointer) =
  doAssert p == currentFrame and vif == cast[pointer](addr vifs[0])
  inc psFrameCount

proc reset() =
  stas = default(typeof(stas))
  vifs = default(typeof(vifs))
  env = default(typeof(env))
  actions.setLen(0)
  txCount = 0
  afterTraffic = 0
  uploadResult = 0
  interruptsEnabled = true
  eventBits = 0x00100000
  clearCount = 0
  psFrameCount = 0
  stas[4] = StaInfoView(valid: 1, infoIdx: 4, instNbr: 1)
  stas[6] = StaInfoView(infoIdx: 6, instNbr: 1)
  vifs[0].vifIdx = 0
  vifs[1].vifIdx = 1

proc expectedTrigger(traffic, mask, tid, budget: uint8; service, sent: uint32;
                     nextTraffic: uint8): tuple[actions: seq[Action], service: uint32, traffic: uint8] =
  result.service = service
  result.traffic = traffic
  let triggerBit = 1'u8 shl [3, 2, 2, 3, 1, 1, 0, 0][tid]
  if (mask and triggerBit) == 0 or (service and 6) != 0: return
  if (traffic and 12) == 0:
    result.actions.add(("null", 4'u32, tid.uint32 or 16, 2'u32))
    result.service = 0
    return
  if (traffic and 8) != 0:
    result.actions.add(("send", 4'u32, budget.uint32, 2'u32))
    result.service = 2
    result.traffic = nextTraffic
    if budget > 0 and sent >= budget.uint32:
      result.actions.add(("null", 4'u32, tid.uint32 or 16, 2'u32))
      result.service = 0
      return
  if (result.traffic and 4) != 0:
    result.actions.add(("traffic", 4'u32, budget.uint32, 1'u32))
    result.service = 4
  else:
    result.actions.add(("null", 4'u32, tid.uint32 or 16, result.service))
    result.service = 0
"""

RX_IDENTITY_MODELS = r"""
# This fixture retains its descriptors without recycling them during callbacks.
type RxFrameIdentity = object
  generation: uint32

proc rxUploadGeneration(p: pointer): uint32 = 1
proc rxUploadCurrent(p: pointer; generation: uint32): bool =
  p != nil and generation == 1
proc rxCaptureFrame(p: pointer): RxFrameIdentity =
  doAssert p != nil
  RxFrameIdentity(generation: 1)
proc rxFrameCurrent(identity: RxFrameIdentity): bool = identity.generation == 1
proc rxReleaseUpload(p: pointer; generation: uint32) =
  doAssert rxUploadCurrent(p, generation)
  rxl_mpdu_free(p)
proc rxReleaseControlFrame(p: pointer; generation: uint32;
                          header: ptr RxSwDescView; buffer: pointer) =
  doAssert rxUploadCurrent(p, generation)
  doAssert header == rxSwDescView(rxMpduDescView(p).swDesc)
  doAssert header.bufferChain == buffer
  rxl_mpdu_free(p)
"""

CHECKS = r"""
static:
  doAssert MM_PS_CHANGE_IND == 55 and MM_TRAFFIC_REQ_IND == 56
  doAssert sizeof(MmTrafficReqIndPayload) == 3

# Exhaustive U-APSD trigger masks, traffic flags and service-period state.
for tid in 0'u8 .. 7'u8:
  for mask in 0'u8 .. 15'u8:
    for traffic in 0'u8 .. 15'u8:
      for service in [0'u32, 1, 2, 4, 8, 9]:
        for budget in [0'u8, 1, 4]:
          for sent in [0'u32, 1, 4]:
            for nextTraffic in [0'u8, 4, 8, 12]:
              reset()
              stas[4].psMode = 1
              stas[4].psState = mask
              stas[4].trafficFlags = traffic
              stas[4].psStatus = service
              stas[4].uapsdBitmap = budget
              vifs[1].vifType = 2
              txCount = sent
              afterTraffic = nextTraffic
              var header: MacQos4AddrFrameHeaderView
              header.header.frameControl = if (sent and 1) == 0: 0x1188'u16 else: 0x1388'u16
              if (sent and 1) == 0:
                cast[ptr MacQosDataFrameHeaderView](addr header).qosCtrl = tid.uint16
                header.qosCtrl = (tid xor 7).uint16
              else:
                header.qosCtrl = tid.uint16
                header.addr4[0] = tid xor 7
              let expected = expectedTrigger(traffic, mask, tid, budget, service, sent, nextTraffic)
              rxlHandleApPowerSave(addr vifs[1], addr stas[4], 4, addr header)
              doAssert actions == expected.actions
              doAssert stas[4].psStatus == expected.service and stas[4].trafficFlags == expected.traffic
              doAssert stas[4].psMode == 1 and vifs[1].psBaCounter == 0

# Wake/sleep transitions apply to ordinary data too, only on AP VIFs.
for vifType in 0'u8 .. 3'u8:
  for asleep in [false, true]:
    for count in [0'u8, 1, 2, 255]:
      for fc in [0x0008'u16, 0x0088, 0x1008, 0x1088, 0x1408, 0x1488, 0x00B0]:
        reset()
        vifs[1] = VifChannelView(vifIdx: 1, vifType: vifType, psBaCounter: count)
        stas[4].psMode = asleep.uint8
        var header = MacQosDataFrameHeaderView(header: MacDataFrameHeaderView(frameControl: fc))
        rxlHandleApPowerSave(addr vifs[1], addr stas[4], 4, addr header)
        var expected: seq[Action]
        var expectedCount = count
        var expectedSleep = asleep
        if vifType == 2:
          if asleep and (fc and 0x140C'u16) == 8:
            expected = @[("ps", 4'u32, 0'u32, 0'u32), ("clear", 4'u32, 0'u32, 0'u32)]
            expectedCount = count - 1
            expectedSleep = false
            if count == 1:
              expected.add(("ps", 6'u32, 0'u32, 0'u32))
              expected.add(("clear", 6'u32, 0'u32, 0'u32))
          elif not asleep and (fc and 0x1400'u16) == 0x1000:
            expected.add(("ps", 4'u32, 1'u32, 0'u32))
            if count == 0: expected.add(("ps", 6'u32, 1'u32, 0'u32))
            expectedCount = count + 1
            expectedSleep = true
        doAssert actions == expected and vifs[1].psBaCounter == expectedCount
        doAssert stas[4].psMode == expectedSleep.uint8

# PS-Poll notifies the host for one packet, or drains internal traffic while
# preserving other service-period bits. The frame still goes to RX upper.
for traffic in 0'u8 .. 15'u8:
  for service in [0'u32, 2, 8, 10]:
    for upload in [0'u8, 1]:
      reset()
      stas[4].psMode = 1
      stas[4].psStatus = service
      stas[4].trafficFlags = traffic
      vifs[1].vifType = 2
      uploadResult = upload
      var header = MacDataFrameHeaderView(frameControl: 0x10A4)
      var chain = BufferChain(frameData: addr header)
      var sw = SwDesc(bufferChain: addr chain, hwFlags: 0x20020000'u32 or (12'u32 shl 15))
      var mpdu = RxMpdu(swDesc: addr sw)
      env.queue = CoList(first: addr mpdu.link, last: addr mpdu.link)
      rxl_cntrl_evt()
      let first = if (traffic and 2) != 0: ("send", 4'u32, 1'u32, service or 1)
                  else: ("traffic", 4'u32, 1'u32, 0'u32)
      var expected = @[first, ("upper", 0'u32, 0'u32, 0'u32)]
      if upload == 0: expected.add(("free", 0'u32, 0'u32, 0'u32))
      doAssert actions == expected
      doAssert stas[4].psStatus == (if (traffic and 2) != 0: service and not 1'u32 else: service)
      doAssert stas[4].connectionStart == 0xABCD1234'u32
      doAssert env.queue.first == nil and clearCount == 2 and eventBits == 0
      doAssert interruptsEnabled

# STA-mode QoS frames must not start AP service periods or be dropped.
reset()
stas[4].psMode = 1
stas[4].psState = 15
stas[4].trafficFlags = 12
vifs[1].vifType = 0
var header = MacQosDataFrameHeaderView(header: MacDataFrameHeaderView(frameControl: 0x1188))
var chain = BufferChain(frameData: addr header)
var sw = SwDesc(bufferChain: addr chain, hwFlags: 0x20020000'u32 or (12'u32 shl 15))
var mpdu = RxMpdu(swDesc: addr sw)
env.queue = CoList(first: addr mpdu.link, last: addr mpdu.link)
rxl_cntrl_evt()
doAssert actions == @[("upper", 0'u32, 0'u32, 0'u32), ("free", 0'u32, 0'u32, 0'u32)]
doAssert stas[4].psStatus == 0

# Blocked/non-delivery AP triggers still retain the ordinary RX-upper path.
for mask in [0'u8, 15]:
  for service in [0'u32, 2, 4]:
    reset()
    stas[4].psMode = 1
    stas[4].psState = mask
    stas[4].psStatus = service
    vifs[1].vifType = 2
    var hdr = MacQosDataFrameHeaderView(header: MacDataFrameHeaderView(frameControl: 0x1188))
    var buffer = BufferChain(frameData: addr hdr)
    var descriptor = SwDesc(bufferChain: addr buffer, hwFlags: 0x20020000'u32 or (12'u32 shl 15))
    var packet = RxMpdu(swDesc: addr descriptor)
    env.queue = CoList(first: addr packet.link, last: addr packet.link)
    rxl_cntrl_evt()
    doAssert actions[^2] == ("upper", 0'u32, 0'u32, 0'u32)
    doAssert actions[^1] == ("free", 0'u32, 0'u32, 0'u32)

# Beacon processing gets the RX descriptor and its length, not the payload chain.
for changed in [0'u32, 1]:
  reset()
  stas[4].instNbr = 0
  vifs[0].state = 1
  vifs[0].chanCtxt = cast[pointer](1)
  vifs[0].tbttTimer.expiry = 0x3456
  vifs[1].vifType = 0
  var hdr = MacDataFrameHeaderView(frameControl: 0x0080)
  var buffer = BufferChain(frameData: addr hdr)
  var descriptor = SwDesc(bufferChain: addr buffer,
    hwFlags: 0x20020000'u32 or (12'u32 shl 15), frameLen: 123)
  var packet = RxMpdu(swDesc: addr descriptor)
  beaconInput = addr descriptor
  beaconResult = changed
  env.queue = CoList(first: addr packet.link, last: addr packet.link)
  rxl_cntrl_evt()
  var expected: seq[Action] = @[("td", 0'u32, 4'u32, 1'u32), ("beacon", 0'u32, 0'u32, 0'u32),
    ("beacon-ps", 0'u32, 0'u32, 0'u32), ("beacon-vif", 0'u32, 0'u32, 0'u32), ("tbtt", 0'u32, 0'u32, 0'u32)]
  if changed != 0: expected.add(("upper", 0'u32, 0'u32, 0'u32))
  expected.add(("free", 0'u32, 0'u32, 0'u32))
  doAssert actions == expected

# Malformed hardware indexes/payloads are freed before peer processing.
for invalidIndex in [15'u32, 0x108, 0x3FF]:
  reset()
  var hdr = MacDataFrameHeaderView(frameControl: 0x0208)
  var buffer = BufferChain(frameData: addr hdr)
  var descriptor = SwDesc(bufferChain: addr buffer,
    hwFlags: 0x20020000'u32 or (invalidIndex shl 15))
  var packet = RxMpdu(swDesc: addr descriptor)
  env.queue = CoList(first: addr packet.link, last: addr packet.link)
  rxl_cntrl_evt()
  doAssert actions == @[("free", 0'u32, 0'u32, 0'u32)]
  doAssert env.queue.first == nil and interruptsEnabled
for badVif in [false, true]:
  reset()
  if badVif: vifs[1].vifIdx = 255
  else: stas[4].instNbr = 255
  var hdr = MacDataFrameHeaderView(frameControl: 0x0208)
  var buffer = BufferChain(frameData: addr hdr)
  var descriptor = SwDesc(bufferChain: addr buffer,
    hwFlags: 0x20020000'u32 or (12'u32 shl 15))
  var packet = RxMpdu(swDesc: addr descriptor)
  env.queue = CoList(first: addr packet.link, last: addr packet.link)
  rxl_cntrl_evt()
  doAssert actions == @[("free", 0'u32, 0'u32, 0'u32)]
  doAssert env.queue.first == nil and interruptsEnabled
reset()
var emptyBuffer: BufferChain
var emptyDescriptor = SwDesc(bufferChain: addr emptyBuffer,
  hwFlags: 0x20020000'u32 or (12'u32 shl 15))
var emptyPacket = RxMpdu(swDesc: addr emptyDescriptor)
env.queue = CoList(first: addr emptyPacket.link, last: addr emptyPacket.link)
rxl_cntrl_evt()
doAssert actions == @[("free", 0'u32, 0'u32, 0'u32)]
doAssert env.queue.first == nil and interruptsEnabled

# The scheduler processes four MPDUs per turn and preserves pending ownership.
reset()
var headers: array[6, MacDataFrameHeaderView]
var chains: array[6, BufferChain]
var descriptors: array[6, SwDesc]
var packets: array[6, RxMpdu]
for i in 0 ..< 6:
  chains[i].frameData = addr headers[i]
  descriptors[i].bufferChain = addr chains[i]
  packets[i].swDesc = addr descriptors[i]
  if i < 5: packets[i].link.next = addr packets[i + 1].link
env.queue = CoList(first: addr packets[0].link, last: addr packets[5].link)
rxl_cntrl_evt()
doAssert env.queue.first == addr packets[4].link
doAssert actions.len == 8 and clearCount == 5 and eventBits == 0x00100000
rxl_cntrl_evt()
doAssert env.queue.first == nil and actions.len == 12 and eventBits == 0

reset()
env.processingFlag = 1
env.queue = CoList(first: addr packets[0].link, last: addr packets[5].link)
rxl_cntrl_evt()
doAssert env.queue.first == addr packets[0].link
doAssert actions.len == 0 and clearCount == 1
"""


def test_rx_power_save_and_ownership(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    base = ROOT / "src/bl808/wifi/fw"
    layout = (base / "layout_types.nim").read_text()
    def structure(name: str) -> str:
        return "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"

    types = "type\n" + "\n".join(structure(name) for name in [
        "MacDataFrameHeaderView", "MacQosDataFrameHeaderView", "MacQos4AddrFrameHeaderView",
        "MmTrafficReqIndPayload", "MmPsChangeIndPayload",
        "ApmPsSession",
    ])
    constants = "\nconst\n  MmTrafficReqIndPayloadSize = sizeof(MmTrafficReqIndPayload).uint32\n  MmPsChangeIndPayloadSize = sizeof(MmPsChangeIndPayload).uint32\n"
    storage = (base / "global_state/storage.nim").read_text()
    tables = ""
    for name in ["mac_ac2uapsd", "mac_tid2ac"]:
        tables += "\nvar " + name + "*" + storage.split("var " + name + "*", 1)[1].split("\n]", 1)[0] + "\n]\n"
    rx = (base / "rx_layer.nim").read_text()
    procedures = "proc rxlRequestBufferedTraffic" + rx.split("proc rxlRequestBufferedTraffic", 1)[1].split(
        "\nproc nimfw_dbg_rxl_processing_flag", 1
    )[0]
    mm = (base / "kernel_mac_channel.nim").read_text()
    ps_change = "proc mm_ps_change_ind*" + mm.split("proc mm_ps_change_ind*", 1)[1].split(
        "\nproc mm_set_wpa_rsn_ie*", 1
    )[0]
    apm = (base / "scan_station_ap_me.nim").read_text()
    ps_helpers = "proc apmPsCapture" + apm.split("proc apmPsCapture", 1)[1].split(
        "\nproc apmPsTimRequest", 1
    )[0]
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", procedures)))
    )
    # Types must precede the host helper declarations that reference them.
    platform = PLATFORM.replace("import bl808/wifi/fw_messages", "import bl808/wifi/fw_messages\n" + types + constants)
    source = tmp_path / "rx_power_save_test.nim"
    source.write_text(platform + RX_IDENTITY_MODELS + tables + debug + ps_helpers + ps_change + procedures + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{ROOT / 'src'}", "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'test'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
