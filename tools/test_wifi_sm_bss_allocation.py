"""SM's BSS parameter batch (state 4): what it sends and how it ends.

The harness compiles the real station_bss.nim with station_sm.nim's smGo,
smSendReserved, smTakeReply and smTakeAnswer. A replier is modelled by
acknowledgeBss: it takes the reply SM reserved (smTakeReply, as
ke_msg_alloc_reply does) and SM takes that answer.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure, station_sm_source
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
  ps: tuple[uapsdPeriod: uint32, flags, pendingCount: uint8, currentVif: pointer]
  interruptsEnabled = true
  allocationHook, freeHook, rateHook, stateHook, sendHook, failureHook: proc()
let mac_ac2uapsd = [4'u8, 8, 2, 1]
proc smCleanupOwnsRequest(request: pointer): bool = false
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
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
  let index = allocated.find(p)
  doAssert index >= 0, "message released twice"
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
proc ke_state_get(task: uint8): uint16 = state
proc sm_connect_ind(status, reason: uint16) =
  failures.add((status, reason))
  state = 10
  if failureHook != nil: failureHook()
proc setup() =
  doAssert allocated.len == 0
  sm = default(typeof(sm))
  smOwn = default(typeof(smOwn))
  connection = Connection(vifIdx: 1, qosInfo: 5)
  sm.connectInfo = addr connection
  sm.connectIndMsg = addr indication
  channel.band = 1
  vif = Vif(vifIdx: 1, staIdx: 2, wmmQosInfo: 128,
    bssid: [2'u8, 3, 4, 5, 6, 7], operChan: addr channel, beaconIntervalTu: 100)
  vif.basicRates[0] = 1
  vif.basicRates[1] = 12
  for ac in 0 ..< 4: cast[ptr uint32](addr vif.edcaParams[ac * 4])[] = 0x11223300'u32 + ac.uint32
  for ac in 1 ..< 4: cast[ptr uint32](addr vif.edcaParams[ac * 32])[] = 0xDEADBEEF'u32
  chan.currentCtxt = addr channel
  calls = 0
  failAt = 0
  stateChanges = 0
  rateBuilds = 0
  state = 3
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
# Every request is allocated before state 4; a failure ends the attempt with
# nothing left allocated or sent.
for failure in 1 .. 9:
  setup()
  failAt = failure
  sm_set_bss_param()
  doAssert calls == failure and allocated.len == 0 and sent.len == 0
  doAssert sm.pendingBssParams.first == nil and sm.pendingBssParams.last == nil
  doAssert state == 10 and stateChanges == 0 and rateBuilds == 0
  doAssert failures == @[(14'u16, 0xFFFF'u16)]

# The nine requests go out one at a time, each with its reply reserved.
setup()
sm_set_bss_param()
doAssert calls == 10 and allocated.len == 10 and sent.len == 1 and state == 4
for step in 0 ..< 9:
  doAssert sent.len == step + 1 and smOwn.request == sent[step] and smOwn.reply != nil
  acknowledgeBss()
  if step < 8: sm_send_next_bss_param()
doAssert sm.pendingBssParams.first == nil and smOwn.answer == nil and calls == 18
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
doAssert allocated.len == 0 and failures.len == 0

for count in [0'u8, 13'u8]:
  setup()
  vif.basicRates[0] = count
  sm_set_bss_param()
  doAssert calls == 0 and allocated.len == 0 and sent.len == 0
  doAssert sm.pendingBssParams.first == nil and rateBuilds == 0
  doAssert state == 10 and failures == @[(14'u16, 0xFFFF'u16)]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_bss_allocation_is_atomic(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(types(), (FW / "scan_station_ap_me.nim").read_text())
                + CHECKS)


def types() -> str:
    from test_wifi_auth_frames import layouts
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    return layouts(*names) + "const\n" + "".join(
        f"  {name}Size = sizeof({name}).uint32\n" for name in names)


def source(types: str, scan: str) -> str:
    code = types + PLATFORM.replace("proc setup() =", station_sm_source(
        "smGo", "smSendReserved", "smAwaits", "smTakeReply", "smTakeAnswer",
        "smAttemptStaVif") + "proc setup() =", 1)
    code += (FW / "station_bss.nim").read_text()
    code += r'''
proc acknowledgeBss() =
  ## The replier answers SM's request in flight with the reply SM reserved
  ## (ke_msg_alloc_reply), then SM takes the answer. The test sends the next.
  let request = smOwn.request
  doAssert request != nil
  let reply = smTakeReply(request, keMsgHdrFromPayload(request).id + 1)
  doAssert reply != nil and smOwn.request == nil and smOwn.reply == nil
  doAssert keMsgHdrFromPayload(reply).destId == TASK_SM
  doAssert smTakeAnswer(reply) and smOwn.answer == nil
  ke_msg_free(keMsgHdrFromPayload(reply))
'''
    return code + procedure(scan, "sm_send_next_bss_param") + procedure(scan, "sm_set_bss_param")


LIFETIME = r'''
proc finish() =
  allocationHook = nil
  freeHook = nil
  rateHook = nil
  stateHook = nil
  sendHook = nil
  failureHook = nil
  discard smGo(0)
  smBssCancel()
  for message in sent: ke_msg_free(keMsgHdrFromPayload(message))
  sent.setLen(0)
  doAssert allocated.len == 0
'''

CASES = {
    # A failed reply reservation ends the attempt at that step; the teardown
    # frees what was not sent.
    "reply_allocation_failure": r'''
for step in 0 ..< 9:
  setup()
  failAt = 10 + step
  sm_set_bss_param()
  for done in 0 ..< step:
    acknowledgeBss()
    sm_send_next_bss_param()
  doAssert failures == @[(14'u16, 0xFFFF'u16)] and sent.len == step
  doAssert smOwn.request == nil and smOwn.reply == nil
  finish()
''',
    # Leaving state 4 frees the reply reserved for the request in flight; the
    # replier then drops that request (it is no longer awaited).
    "teardown_frees_the_reserved_reply": r'''
setup()
sm_set_bss_param()
let request = sent[0]
doAssert smAwaits(request) and smOwn.reply != nil
discard smGo(10)
doAssert not smAwaits(request) and smOwn.reply == nil and smOwn.answer == nil
doAssert smTakeReply(request, ME_SET_PS_DISABLE_REQ + 1) == nil
doAssert allocated.len == 9
finish()
''',
    # A replier that answers inside ke_msg_send finds SM waiting already.
    "synchronous_dispatch": r'''
setup()
sendHook = proc() =
  doAssert state == 4 and smAwaits(sent[^1])
  acknowledgeBss()
  if sm.pendingBssParams.first != nil: sm_send_next_bss_param()
sm_set_bss_param()
doAssert sent.len == 9 and state == 4 and smOwn.answer == nil
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
        sm_set_bss_param()
        while sm.pendingBssParams.first != nil:
          acknowledgeBss()
          sm_send_next_bss_param()
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
    # Without the attempt's STA VIF the attempt ends (it used to return and
    # leave SM in state 3); without an attempt nothing happens.
    "invalid_owner": r'''
for bad in 0..3:
  setup()
  case bad
  of 0: sm.connectInfo = nil
  of 1: connection.vifIdx = 2
  of 2: vif.vifIdx = 0
  else: vif.vifType = 2
  sm_set_bss_param()
  doAssert calls == 0 and stateChanges == 0 and sent.len == 0
  doAssert failures.len == int(bad != 0)
  if bad != 0: doAssert failures[0] == (14'u16, 0xFFFF'u16)
  finish()
setup()
vif.staIdx = 0xFF
sm_set_bss_param()
doAssert calls == 10 and state == 4 and sent.len == 1
finish()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_preparation_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    run_program(tmp_path, mode, source(types(), scan) + LIFETIME + CASES[case])
