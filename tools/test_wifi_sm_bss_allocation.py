"""Verify SM publishes either a complete BSS configuration batch or nothing."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import FW, run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_SM = 4'u8
  TASK_API = 9'u8
  TASK_SCAN = 1'u8
  SmWaitingState = 2'u16
  SmScanningState = 1'u16
  SmAuthenticatingState = 6'u16
  SmAssocRspState = 8'u16
  SM_ACTIVATING_STATE = 9'u16
  SM_CONNECT_ABORT_CFM = 0x100B'u16
  SCAN_ABORT_REQ = 0x402'u16
  StatusCfmPayloadSize = 1'u32
  KeMsgSaved = 2.cint
  KeMsgConsumed = 0.cint
  KeMsgTailSlack = 4'u32
  MeIdleState = 0'u16
  SmSettingBssState = 4'u16
  WLAN_FW_JOIN_NETWORK_FAILURE = 14
  ME_SET_PS_DISABLE_REQ = 0xC0F'u16
  ME_SET_ACTIVE_REQ = 0xC0D'u16
  MM_SET_BSSID_REQ = 20'u16
  MM_SET_BASIC_RATES_REQ = 18'u16
  MM_SET_BEACON_INT_REQ = 16'u16
  MM_SET_EDCA_REQ = 22'u16
type
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  CoListHdr = KeMsgHdr
  CoList = object
    first, last: ptr CoListHdr
  Vif = object
    vifIdx, vifType, staIdx, wmmQosInfo: uint8
    bssid: array[6, uint8]
    basicRates: array[13, uint8]
    operChan: pointer
    beaconIntervalTu: uint16
    edcaParams: array[128, uint8]
  ScanChannelEntry = object
    band: uint8
  Connection = object
    vifIdx, qosInfo: uint8
  StatusCfmPayload = object
    status: uint8
var
  connection: Connection
  vif: Vif
  channel: ScanChannelEntry
  sm: tuple[connectInfo, connectIndMsg: pointer, pendingBssParams: CoList,
            cancelRequested, deauthPending: uint8]
  indication, otherIndication: uint8
  chan: tuple[currentCtxt: pointer]
  allocated: seq[pointer]
  sent: seq[pointer]
  calls, failAt, stateChanges, rateBuilds: int
  state: uint16
  failures: seq[tuple[status, reason: uint16]]
  rxVifEpochs: array[2, uint32]
  txResetEpoch: uint32
  stationEpochs: array[7, uint32]
  smTxSerials: array[2, uint32]
  ps: tuple[uapsdPeriod: uint32]
  interruptsEnabled = true
  allocationHook, freeHook, rateHook, stateHook, sendHook, failureHook: proc()
  meControlCommand, meControlReply: pointer
proc smBssForget(header: pointer)
proc meControlReset() = doAssert false
proc meCancelQueuedPayload(payload: pointer) = discard
proc smBssCancelControl(request, reply: pointer; vifIndex: uint8): bool = false
let mac_ac2uapsd = [4'u8, 8, 2, 1]
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 7: stationEpochs[index] else: 0
proc psEnvView(): ptr typeof(ps) = addr ps
proc calloc(count, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc smEnvView(): ptr typeof(sm) = addr sm
proc connectInfoView(p: pointer): ptr Connection = cast[ptr Connection](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == 1
  addr vif
proc chanEnvView(): ptr typeof(chan) = addr chan
proc vifEdcaPsGate(vif: ptr Vif): int8 = cast[int8](vif.wmmQosInfo)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr = cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(h: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](h) + sizeof(KeMsgHdr).uint)
proc ke_msg_alloc(id: uint16; dest, source: uint8; size: uint32): pointer =
  inc calls
  if calls == failAt: return nil
  let header = cast[ptr KeMsgHdr](calloc(1, (sizeof(KeMsgHdr).uint32 + size).csize_t))
  doAssert header != nil
  header[] = KeMsgHdr(id: id, destId: dest, srcId: source, paramLen: size)
  allocated.add(header)
  result = keMsgPayload(header)
  if allocationHook != nil: allocationHook()
proc ke_msg_try_alloc(id: uint16; dest, source: uint8; size: uint32): pointer =
  ke_msg_alloc(id, dest, source, size)
proc ke_msg_free(p: pointer) =
  smBssForget(p)
  let index = allocated.find(p)
  doAssert index >= 0
  allocated.delete(index)
  free(p)
  if freeHook != nil: freeHook()
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): ptr CoListHdr =
  result = list.first
  if result != nil:
    list.first = result.next
    if list.first == nil: list.last = nil
    result.next = nil
proc ke_msg_send(p: pointer) =
  sent.add(p)
  if sendHook != nil: sendHook()
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SM
  inc stateChanges
  state = value
  if stateHook != nil: stateHook()
proc me_legacy_rate_bitfield_build(p: pointer; basic: uint8): uint32 =
  inc rateBuilds
  if rateHook != nil: rateHook()
  0x1234
proc c_memcpy(dest, source: pointer; length: csize_t): pointer =
  copyMem(dest, source, length.int)
  dest
proc assert_err(a, b: cstring; line: int) = doAssert false
proc ke_state_get(task: uint8): uint16 = state
proc ke_msg_send_basic(id: uint16; dst, src: uint8) = doAssert false
proc scanu_cached_scanresult_clear() = doAssert false
proc smReqVifIdxOrZero(p: pointer): uint8 = 1
proc sm_handle_connection(vif: uint8; status: uint16; callback, failure: pointer) = doAssert false
proc sm_connect_abort_deauth_cfm() = discard
proc sm_connect_abort_process() = discard
proc sm_connect_ind(status, reason: uint16) =
  failures.add((status, reason))
  state = 10
  if failureHook != nil: failureHook()
proc setup() =
  doAssert allocated.len == 0
  sm = default(typeof(sm))
  connection = Connection(vifIdx: 1, qosInfo: 5)
  sm.connectInfo = addr connection
  sm.connectIndMsg = addr indication
  channel.band = 1
  vif = Vif(vifIdx: 1, staIdx: 2, wmmQosInfo: 128,
    bssid: [2'u8, 3, 4, 5, 6, 7], operChan: addr channel, beaconIntervalTu: 100)
  for ac in 0 ..< 4: cast[ptr uint32](addr vif.edcaParams[ac * 4])[] = 0x11223300'u32 + ac.uint32
  for ac in 1 ..< 4: cast[ptr uint32](addr vif.edcaParams[ac * 32])[] = 0xDEADBEEF'u32
  chan.currentCtxt = addr channel
  calls = 0
  failAt = 0
  stateChanges = 0
  rateBuilds = 0
  state = 3
  rxVifEpochs = [1'u32, 1]
  ps.uapsdPeriod = 100
  allocationHook = nil
  freeHook = nil
  rateHook = nil
  stateHook = nil
  sendHook = nil
  failureHook = nil
  sent.setLen(0)
  failures.setLen(0)
'''

CHECKS = r'''
for failure in 1 .. 18:
  setup()
  failAt = failure
  sm_set_bss_param(nil)
  doAssert calls == 18 and allocated.len == 0 and sent.len == 0
  doAssert sm.pendingBssParams.first == nil and sm.pendingBssParams.last == nil
  doAssert state == 10 and stateChanges == 0 and rateBuilds == 0
  doAssert failures == @[(14'u16, 0xFFFF'u16)]

setup()
sm_set_bss_param(nil)
doAssert calls == 18 and allocated.len == 18 and sent.len == 1 and state == 4
while sm.pendingBssParams.first != nil:
  acknowledgeBss()
  sm_send_next_bss_param(nil)
acknowledgeBss()
let expected = [ME_SET_PS_DISABLE_REQ, MM_SET_BSSID_REQ, MM_SET_BASIC_RATES_REQ,
  MM_SET_BEACON_INT_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ, MM_SET_EDCA_REQ,
  MM_SET_EDCA_REQ, ME_SET_ACTIVE_REQ]
for i, message in sent:
  doAssert keMsgHdrFromPayload(message).id == expected[i]
  doAssert keMsgHdrFromPayload(message).srcId == TASK_SM
  if i in 4 .. 7:
    let edca = cast[ptr MmSetEdcaReqPayload](message)
    doAssert edca.edcaParam == 0x11223300'u32 + (i - 4).uint32
    doAssert edca.vifIdx == 1 and edca.acmFlag == (i - 4).uint8
    doAssert edca.uapsdAc == (if i in [4, 7]: 1'u8 else: 0'u8)
  ke_msg_free(keMsgHdrFromPayload(message))
doAssert allocated.len == 0

# A repeated call cannot discard a batch already retained by SM.
setup()
let original = ke_msg_alloc(0x777, TASK_MM, TASK_SM, 1)
co_list_push_back(addr sm.pendingBssParams, keMsgHdrFromPayload(original))
let before = calls
sm_set_bss_param(nil)
doAssert calls == before and sm.pendingBssParams.first == keMsgHdrFromPayload(original)
discard co_list_pop_front(addr sm.pendingBssParams)
ke_msg_free(keMsgHdrFromPayload(original))
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_bss_allocation_is_atomic(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    for name in names:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    types += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = source(types, scan)
    run_program(tmp_path, mode, code + CHECKS)


def source(types: str, scan: str) -> str:
    code = types + PLATFORM
    if "smTxBegin(" in procedure(scan, "sm_set_bss_param"):
        from test_wifi_auth_frames import layouts
        code += layouts("TxSessionIdentity", "SmTxBuildContext")
        helper = (FW / "station_tx_build.nim").read_text()
        for name in ["smTxBeginForVif", "smTxBegin", "smTxOwnerCurrent", "smTxBindStation", "smTxSetOwnerState"]:
            code += procedure(helper, name)
    code += (FW / "station_bss.nim").read_text()
    code += r'''
proc acknowledgeBss() =
  let reply = smBssTakeReply(smBss.request, SmBssRequests[smBss.step] + 1, 0)
  doAssert reply != nil and smBssConsumeReply(reply)
  ke_msg_free(keMsgHdrFromPayload(reply))
'''
    return code + procedure(scan, "sm_send_next_bss_param") + procedure(scan, "sm_set_bss_param")


LIFETIME = r'''
var replacement = Connection(vifIdx: 1, qosInfo: 10)
proc replaceCurrent() =
  sm.connectInfo = addr replacement
  state = 9
  let marker = ke_msg_alloc(0x777, TASK_MM, TASK_SM, 1)
  co_list_push_back(addr sm.pendingBssParams, keMsgHdrFromPayload(marker))
proc finish() =
  allocationHook = nil
  freeHook = nil
  rateHook = nil
  stateHook = nil
  sendHook = nil
  failureHook = nil
  smBssCancel()
  while sm.pendingBssParams.first != nil:
    ke_msg_free(co_list_pop_front(addr sm.pendingBssParams))
  for message in sent: ke_msg_free(keMsgHdrFromPayload(message))
  sent.setLen(0)
  doAssert allocated.len == 0
'''

CASES = {
    "allocation_replacement": r'''
for point in 1..18:
  setup()
  allocationHook = proc() =
    if calls == point:
      allocationHook = nil
      replaceCurrent()
  sm_set_bss_param(nil)
  doAssert state == 9 and sent.len == 0 and allocated.len == 1
  doAssert sm.pendingBssParams.first.id == 0x777
  finish()
''',
    "rate_replacement": r'''
setup()
rateHook = proc() =
  rateHook = nil
  replaceCurrent()
sm_set_bss_param(nil)
doAssert state == 9 and sent.len == 0 and allocated.len == 1
doAssert sm.pendingBssParams.first.id == 0x777
finish()
''',
    "state_replacement": r'''
setup()
stateHook = proc() =
  stateHook = nil
  replaceCurrent()
sm_set_bss_param(nil)
doAssert state == 9 and sent.len == 0 and allocated.len == 1
doAssert sm.pendingBssParams.first.id == 0x777
finish()
''',
    "nested_builder": r'''
setup()
allocationHook = proc() =
  allocationHook = nil
  sm_set_bss_param(nil)
sm_set_bss_param(nil)
doAssert state == 4 and allocated.len == 18 and sent.len == 1
finish()
''',
    "owner_changes": r'''
for site in 0..2:
  for change in 0..5:
    setup()
    let invalidate = proc() =
      case change
      of 0: inc rxVifEpochs[1]
      of 1: inc stationEpochs[2]
      of 2: vif.staIdx = 3
      of 3: vif.vifType = 2
      of 4: state = 7
      else: sm.connectInfo = nil
    if site == 0:
      allocationHook = proc() =
        if calls == 5:
          allocationHook = nil
          invalidate()
    elif site == 1: rateHook = invalidate
    else: stateHook = invalidate
    sm_set_bss_param(nil)
    doAssert sent.len == 0 and allocated.len == 0
    doAssert sm.pendingBssParams.first == nil
    finish()
''',
    "cleanup_reentrancy": r'''
setup()
failAt = 4
freeHook = proc() =
  freeHook = nil
  replaceCurrent()
sm_set_bss_param(nil)
doAssert state == 9 and sent.len == 0 and allocated.len == 1
doAssert sm.pendingBssParams.first.id == 0x777
doAssert failures.len == 0
finish()
''',
    "failure_after_release": r'''
for point in 1..18:
  setup()
  failAt = point
  failureHook = proc() =
    doAssert allocated.len == 0 and smBssTags == nil
    doAssert sent.len == 0 and sm.pendingBssParams.first == nil
    failureHook = nil
    replaceCurrent()
  sm_set_bss_param(nil)
  doAssert failures == @[(14'u16, 0xFFFF'u16)] and state == 9
  finish()
''',
    "indication_replacement": r'''
for site in 0..3:
  setup()
  let replaceIndication = proc() = sm.connectIndMsg = addr otherIndication
  case site
  of 0: allocationHook = replaceIndication
  of 1: rateHook = replaceIndication
  of 2: stateHook = replaceIndication
  else:
    failAt = 4
    freeHook = replaceIndication
  sm_set_bss_param(nil)
  doAssert sm.connectIndMsg == addr otherIndication
  doAssert failures.len == 0 and sent.len == 0 and allocated.len == 0
  finish()
''',
    "synchronous_dispatch": r'''
setup()
sendHook = proc() =
  doAssert state == 4
  acknowledgeBss()
  if sm.pendingBssParams.first != nil:
    sm_send_next_bss_param(nil)
  else:
    sm.connectInfo = addr replacement
    state = 9
sm_set_bss_param(nil)
doAssert sent.len == 9 and state == 9 and sm.connectInfo == addr replacement
doAssert sm.pendingBssParams.first == nil
finish()
''',
    "uapsd_matrix": r'''
for period in [0'u32, 100'u32]:
  for qosFlag in [0'u8, 128'u8]:
    for qosMask in 0'u8..15:
      for hasChannel in [false, true]:
        setup()
        ps.uapsdPeriod = period
        vif.wmmQosInfo = qosFlag
        connection.qosInfo = qosMask
        chan.currentCtxt = if hasChannel: addr channel else: nil
        sm_set_bss_param(nil)
        while sm.pendingBssParams.first != nil:
          acknowledgeBss()
          sm_send_next_bss_param(nil)
        acknowledgeBss()
        doAssert sent.len == 9
        for ac in 0..3:
          let req = cast[ptr MmSetEdcaReqPayload](sent[ac + 4])
          let enabled = period != 0 and qosFlag == 128 and
                        (mac_ac2uapsd[ac] and qosMask) != 0
          doAssert req.uapsdAc == enabled.uint8
          doAssert req.edcaParam == 0x11223300'u32 + ac.uint32
        finish()
''',
    "interrupt_state": r'''
for enabled in [false, true]:
  for failure in [0, 1, 9]:
    setup()
    interruptsEnabled = enabled
    failAt = failure
    sm_set_bss_param(nil)
    doAssert interruptsEnabled == enabled
    finish()
''',
    "invalid_owner": r'''
for bad in 0..5:
  setup()
  case bad
  of 0: sm.connectInfo = nil
  of 1: connection.vifIdx = 2
  of 2: vif.vifIdx = 0
  of 3: vif.vifType = 2
  of 4: vif.staIdx = 7
  else: sm.connectIndMsg = nil
  sm_set_bss_param(nil)
  doAssert calls == 0 and stateChanges == 0 and sent.len == 0 and failures.len == 0
  finish()
setup()
vif.staIdx = 0xFF
sm_set_bss_param(nil)
doAssert calls == 18 and state == 4 and sent.len == 1
finish()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_preparation_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    from test_wifi_auth_frames import layouts
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    types = layouts(*names)
    types += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    run_program(tmp_path, mode, source(types, scan) + LIFETIME + CASES[case])
