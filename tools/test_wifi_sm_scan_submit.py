"""Check owned SCANU request preparation and publication from the station manager."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  SmIdleState = 0'u16
  SmScanningState = 1'u16
  SmWaitingState = 2'u16
  WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL = 12
  WLAN_FW_JOIN_NETWORK_FAILURE = 14
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  TASK_SM = 4'u8
  TASK_SCANU = 2'u8
  SCANU_START_REQ = 0x800'u16
  SCANU_JOIN_REQ = 0x802'u16
  SCANU_START_CFM = 0x801'u16
  SCANU_JOIN_CFM = 0x803'u16
  ScanuStartReqPayloadSize = sizeof(ScanuStartReqPayload).uint32
  StatusCfmPayloadSize = 1'u32
  KeMsgTailSlack = 4'u32
  ScanChannelEntrySize = sizeof(ScanChannelEntry).uint32
type
  ConnectInfoView = object
    vifIdx, ssidLen: uint8
    channelDuration: uint32
    ssid: array[33, uint8]
  Vif = object
    vifIdx, vifType, staIdx: uint8
  Header = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  KeMsgHdr = Header
  StatusCfmPayload = object
    status: uint8
var
  conn, replacement: ConnectInfoView
  vifs: array[2, Vif]
  state: uint16
  sm: tuple[connectInfo, connectIndMsg: pointer, joinBssFlag: uint8]
  indication, otherIndication: uint32
  smTxSerials: array[2, uint32]
  rxVifEpochs: array[2, uint32]
  txResetEpoch: uint32
  config: ScanuChannelConfigOverlay
  channel: ScanChannelEntry
  localMac, target: array[6, uint8]
  live: seq[pointer]
  sent: seq[tuple[id, state: uint16, payload: ScanuStartReqPayload]]
  failures: seq[tuple[status, reason: uint16]]
  allocations, frees: int
  failAlloc: bool
  enabled = true
  onAlloc, onState, onSend: proc()
proc invoke(hook: var proc()) =
  if hook != nil:
    let callback = hook
    hook = nil
    callback()
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc smEnvView(): ptr typeof(sm) = addr sm
proc connectInfoView(p: pointer): ptr ConnectInfoView = cast[ptr ConnectInfoView](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc staDeleteEpoch(index: uint8): uint32 = 0
proc ke_state_get(task: uint8): uint16 = state
proc ke_state_set(task: uint8; value: uint16) =
  state = value
  invoke(onState)
proc scanSsidSlot(p: ptr ScanuStartReqPayload; index: int): ptr ScanSsidSlotView =
  doAssert index == 0
  cast[ptr ScanSsidSlotView](addr p.ssidFilter[0])
proc scanuStartReqView(p: pointer): ptr ScanuStartReqPayload = cast[ptr ScanuStartReqPayload](p)
proc scanuChannelConfig(): ptr ScanuChannelConfigOverlay = addr config
proc keMsgHdrFromPayload(p: pointer): ptr Header = cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc statusCfmView(p: pointer): ptr StatusCfmPayload = cast[ptr StatusCfmPayload](p)
proc smScanForget(header: pointer)
proc resetScanTracking()
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  if id in [SCANU_START_REQ, SCANU_JOIN_REQ]:
    doAssert dst == TASK_SCANU and src == TASK_SM and size >= ScanuStartReqPayloadSize
  else:
    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]
    doAssert dst == TASK_SM and src == TASK_SCANU and size >= 1
  inc allocations
  if not failAlloc:
    let h = cast[ptr Header](alloc0(sizeof(Header) + size.int))
    h[] = Header(id: id, destId: dst, srcId: src, paramLen: size)
    live.add(h)
    result = cast[pointer](cast[uint](h) + sizeof(Header).uint)
  invoke(onAlloc)
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  ke_msg_alloc(id, dst, src, size)
proc ke_msg_free(p: pointer) =
  smScanForget(p)
  let index = live.find(p)
  doAssert index >= 0
  live.delete(index)
  inc frees
  dealloc(p)
proc ke_msg_send(p: pointer) =
  sent.add((keMsgHdrFromPayload(p).id, state, scanuStartReqView(p)[]))
  ke_msg_free(keMsgHdrFromPayload(p))
  invoke(onSend)
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  let bytes = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< size.int: bytes[i] = value.uint8
  dst
proc sm_connect_ind(status, reason: uint16) = failures.add((status, reason))
proc setup(vifIndex = 1'u8) =
  doAssert live.len == 0
  resetScanTracking()
  conn = ConnectInfoView(vifIdx: vifIndex, ssidLen: 4, channelDuration: 0x12345678)
  conn.ssid[0..3] = [65'u8, 0, 66, 67]
  replacement = ConnectInfoView(vifIdx: vifIndex)
  sm = (cast[pointer](addr conn), cast[pointer](addr indication), 7'u8)
  state = SmIdleState
  for i in 0 ..< vifs.len: vifs[i] = Vif(vifIdx: i.uint8, staIdx: 0xFF)
  config = default(ScanuChannelConfigOverlay)
  config.count = 2
  config.entries[0] = ScanChannelEntry(prim20Freq: 2412, txPower: 19)
  config.entries[1] = ScanChannelEntry(prim20Freq: 2437, flags: 2, txPower: 18)
  channel = ScanChannelEntry(prim20Freq: 2462, band: 0, flags: 4, txPower: 17)
  localMac = [2'u8, 1, 2, 3, 4, 5]
  target = [4'u8, 6, 7, 8, 9, 10]
  sent.setLen(0)
  failures.setLen(0)
  allocations = 0
  frees = 0
  failAlloc = false
  enabled = true
  onAlloc = nil
  onState = nil
  onSend = nil
proc replaceOwner() =
  sm.connectInfo = addr replacement
  sm.connectIndMsg = addr otherIndication
  state = 6
proc submit(joining: bool; allChannels = false) =
  let chan = if allChannels: nil else: cast[pointer](addr channel)
  if joining: sm_join_bss(addr localMac[0], addr target[0], chan, 1)
  else: sm_scan_bss(addr localMac[0], addr target[0], chan)
'''


def source() -> str:
    # submit() calls the two production entry points defined below it.
    layout = (FW / "layout_types.nim").read_text()
    code = "type\n"
    for name in ["TxSessionIdentity", "SmTxBuildContext", "ScanChannelEntry",
                 "ScanSsidSlotView", "ScanuStartReqPayload", "ScanuChannelConfigOverlay"]:
        declaration = "  " + name + layout.split("  " + name, 1)[1]
        lines = declaration.splitlines()
        code += lines[0] + "\n"
        for line in lines[1:]:
            if line and not line.startswith("    "):
                break
            code += line + "\n"
    code += "\nproc sm_join_bss*(bssid, ssid, joinInfo: pointer; flag: uint32) {.exportc, cdecl.}\n"
    code += "proc sm_scan_bss*(bssid, ssid, chanInfo: pointer) {.exportc, cdecl.}\n" + PLATFORM
    owner = (FW / "station_tx_build.nim").read_text()
    for name in ["smTxCapture", "smTxBeginForVif", "smTxBegin", "smTxOwnerCurrent", "smTxSetOwnerState"]:
        code += procedure(owner, name)
    for name in ["connectInfoSsidLen", "connectInfoFillSsidSlot"]:
        code += procedure(layout, name)
    code += "\n{.pragma: wifiCtrl.}\n" + (FW / "station_scan.nim").read_text()
    code += "\nproc resetScanTracking() =\n  doAssert smScanTags == nil\n  smScanLost = default(SmScanLost)\n"
    handlers = (FW / "scan_station_ap_me.nim").read_text()
    if re.search(r"^proc smSubmitScanRequest\(", handlers, re.M):
        code += procedure(handlers, "smSubmitScanRequest")
    code += procedure(handlers, "sm_scan_bss") + procedure(handlers, "sm_join_bss")
    return code


CASES = {
    "publication_precedes_send": r'''
for joining in [false, true]:
  setup()
  onSend = proc() = state = 8
  submit(joining)
  doAssert sent.len == 1
  doAssert sent[0].state == (if joining: SmWaitingState else: SmScanningState)
  doAssert state == 8 and live.len == 0
''',
    "allocation_replaces_owner": r'''
for joining in [false, true]:
  setup()
  onAlloc = replaceOwner
  submit(joining)
  doAssert sent.len == 0 and state == 6 and live.len == 0 and failures.len == 0
''',
    "input_snapshot_before_allocation": r'''
for joining in [false, true]:
  setup()
  let expectedMac = localMac
  let expectedTarget = target
  let expectedChannel = channel
  onAlloc = proc() =
    localMac = default(typeof(localMac))
    target = default(typeof(target))
    channel = default(ScanChannelEntry)
    conn.ssid = default(typeof(conn.ssid))
    conn.channelDuration = 0
  submit(joining)
  doAssert sent.len == 1
  let payload = sent[0].payload
  doAssert payload.localMac == expectedMac and payload.bssid == expectedTarget
  doAssert payload.channelList[0].prim20Freq == expectedChannel.prim20Freq
  doAssert payload.flags == 0x12345678 and payload.ssidFilter[1..4] == [65'u8, 0, 66, 67]
''',
    "state_callback_replaces_owner": r'''
for joining in [false, true]:
  setup()
  onState = replaceOwner
  submit(joining)
  doAssert sent.len == 0 and state == 6 and live.len == 0
''',
    "allocation_failure": r'''
for joining in [false, true]:
  setup()
  failAlloc = true
  submit(joining)
  doAssert sent.len == 0 and live.len == 0 and state == SmIdleState
  doAssert failures == @[(14'u16, 0xFFFF'u16)]
''',
    "request_fields": r'''
for vifIndex in 0'u8 .. 1'u8:
  for joining in [false, true]:
    setup(vifIndex)
    submit(joining)
    doAssert sent.len == 1 and allocations == 2 and frees == 2
    let request = sent[0]
    doAssert request.id == (if joining: SCANU_JOIN_REQ else: SCANU_START_REQ)
    doAssert request.payload.vifIdx == vifIndex and request.payload.scanType == 1
    doAssert request.payload.channelCount == 1 and request.payload.probeReqIe == nil
    doAssert request.payload.probeReqIeLen == 0 and request.payload.ssidFilter[0] == 4
    doAssert request.payload.channelList[0].flags == (if joining: 5'u8 else: 4'u8)
    doAssert sm.joinBssFlag == (if joining: 1'u8 else: 7'u8)
''',
    "filtered_channel_list": r'''
setup()
submit(false, true)
doAssert sent.len == 1 and sent[0].payload.channelCount == 1
doAssert sent[0].payload.channelList[0] == config.entries[0]
doAssert live.len == 0
''',
    "invalid_channel_count": r'''
setup()
config.count = 15
submit(false, true)
doAssert sent.len == 0 and allocations == 0 and failures == @[(12'u16, 0xFFFF'u16)]
''',
    "no_eligible_channel": r'''
setup()
config.entries[0].flags = 2
submit(false, true)
doAssert sent.len == 0 and allocations == 0 and failures == @[(12'u16, 0xFFFF'u16)]
''',
    "invalid_state_or_owner": r'''
for mutation in 0 .. 4:
  setup()
  case mutation
  of 0: state = 6
  of 1: sm.connectInfo = nil
  of 2: sm.connectIndMsg = nil
  of 3: conn.vifIdx = 2
  else: vifs[1].vifType = 2
  submit(true)
  doAssert allocations == 0 and sent.len == 0 and failures.len == 0
''',
    "nil_inputs": r'''
for missing in 0 .. 2:
  setup()
  sm_join_bss((if missing == 0: nil else: addr localMac[0]),
              (if missing == 1: nil else: addr target[0]),
              (if missing == 2: nil else: addr channel), 1)
  doAssert allocations == 0 and sent.len == 0 and failures == @[(12'u16, 0xFFFF'u16)]
''',
    "disabled_interrupts": r'''
setup()
enabled = false
submit(true)
doAssert not enabled and sent.len == 1
''',
    "nested_allocation_submission": r'''
setup()
onAlloc = proc() = sm_scan_bss(addr localMac[0], nil, addr channel)
submit(true)
doAssert sent.len == 1 and sent[0].id == SCANU_START_REQ
doAssert allocations == 3 and frees == 3 and live.len == 0
doAssert state == SmScanningState and sm.joinBssFlag == 7
''',
    "nested_state_submission": r'''
setup()
onState = proc() = sm_scan_bss(addr localMac[0], nil, addr channel)
submit(true)
doAssert sent.len == 1 and sent[0].id == SCANU_START_REQ
doAssert state == SmScanningState and allocations == 4 and frees == 4
''',
    "owner_generation_changes": r'''
for mutation in 0 .. 2:
  setup()
  onAlloc = proc() =
    case mutation
    of 0: inc rxVifEpochs[1]
    of 1: inc smTxSerials[1]
    else: sm.connectIndMsg = addr otherIndication
  submit(true)
  doAssert sent.len == 0 and live.len == 0 and failures.len == 0
  doAssert state == SmIdleState
''',
    "all_channel_count_boundaries": r'''
for count in 0 .. 14:
  setup()
  config.count = count.uint8
  var expected: seq[ScanChannelEntry]
  for index in 0 ..< count:
    config.entries[index] = ScanChannelEntry(prim20Freq: (2412 + index * 5).uint16,
      flags: (if index mod 3 == 0: 2'u8 else: 0'u8), txPower: 17)
    if index mod 3 != 0: expected.add(config.entries[index])
  submit(false, true)
  if expected.len == 0:
    doAssert sent.len == 0 and failures == @[(12'u16, 0xFFFF'u16)]
  else:
    doAssert sent.len == 1 and sent[0].payload.channelCount.int == expected.len
    for index, channel in expected: doAssert sent[0].payload.channelList[index] == channel
  doAssert live.len == 0
''',
    "channel_snapshot_before_allocation": r'''
setup()
onAlloc = proc() = config = default(ScanuChannelConfigOverlay)
submit(false, true)
doAssert sent.len == 1 and sent[0].payload.channelCount == 1
doAssert sent[0].payload.channelList[0].prim20Freq == 2412
''',
    "join_flags_and_scan_wildcard": r'''
for flags in [0'u32, 1, 255, 256, high(uint32)]:
  setup()
  sm_join_bss(addr localMac[0], addr target[0], addr channel, flags)
  doAssert sent.len == 1 and sm.joinBssFlag == cast[uint8](flags)
  doAssert sent[0].payload.channelList[0].flags == (if flags == 0: 4'u8 else: 5'u8)
setup()
sm_scan_bss(addr localMac[0], nil, nil)
doAssert sent.len == 1
for value in sent[0].payload.bssid: doAssert value == 255
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_scan_submission(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
