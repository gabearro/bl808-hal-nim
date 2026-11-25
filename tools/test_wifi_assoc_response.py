"""Exercise association response parsing and activation preparation."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure, station_sm_source
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_SM = 4'u8
  TASK_MM = 0'u8
  SM_RSP_TIMEOUT_IND = 0x1006'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SM_ACTIVATING_STATE = 9'u16
  SmAssocRspState = 8'u16
  SmAuthenticatingState = 6'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MmSetVifStateReqPayloadSize = sizeof(MmSetVifStateReqPayload).uint32
  WLAN_FW_ASSOCIATE_FAIILURE = 5
type
  KeMsgHdr = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Conn = object
    vifIdx, retry: uint8
  Vif = object
    vifIdx, vifType, staIdx: uint8
    operChan: pointer
    bss: tuple[powerConstraint: uint8]
    security: tuple[cipher: uint8]
  Sta = object
    valid, instNbr: uint8
  ScanChannelEntry = object
    txPower: int8
  Wps = object
    staAddConfirm: pointer
var
  conn, replacement: Conn
  vif: Vif
  sta: Sta
  channel: ScanChannelEntry
  ind, otherInd: SmConnectIndPayload
  sm: tuple[connectInfo, connectIndMsg: pointer, state, saQueryActive: uint8]
  state: uint16
  rxVifEpochs: array[2, uint32]
  txResetEpoch: uint32
  stationEpochs: array[7, uint32]
  smTxSerials: array[2, uint32]
  wps: Wps
  wps_cbs: pointer
  nimFwWpaPendingMask: uint32
  live: seq[pointer]
  sent: seq[MmSetVifStateReqPayload]
  sentStates: seq[uint16]
  delays: seq[uint64]
  clears: seq[uint16]
  powers: seq[uint8]
  failures: seq[tuple[status, reason: uint16]]
  order: seq[string]
  rates, wpsCalls: int
  enabled = true
  failAlloc, failTimer, failRateInit: bool
  onAlloc, onClear, onState, onSend, onRate, onPower, onCopy, onTrace, onWps: proc()
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc smEnvView(): ptr typeof(sm) = addr sm
proc connectInfoView(p: pointer): ptr Conn = cast[ptr Conn](p)
proc connectInfoAuthRetry(p: pointer): ptr uint8 = addr connectInfoView(p).retry
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == 1
  addr vif
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index == 2
  addr sta
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 7: stationEpochs[index] else: 0
proc vifSecurity(p: ptr Vif): ptr typeof(vif.security) = addr p.security
proc vifBssStatus(p: ptr Vif): ptr typeof(vif.bss) = addr p.bss
proc ke_state_get(task: uint8): uint16 = state
proc ke_state_set(task: uint8; value: uint16) =
  state = value
  order.add("state")
  invoke(onState)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(p: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](p) + sizeof(KeMsgHdr).uint)
proc newMessage(length: uint32): pointer =
  let h = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + length.int))
  h.paramLen = length
  live.add(h)
  keMsgPayload(h)
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  if not failAlloc:
    result = newMessage(length)
    let h = keMsgHdrFromPayload(result)
    h.id = id
    h.destId = dst
    h.srcId = src
  invoke(onAlloc)
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  ke_msg_alloc(id, dst, src, length)
proc ke_msg_free(header: pointer) =
  let index = live.find(header)
  doAssert index >= 0
  live.delete(index)
  dealloc(header)
proc ke_msg_send(p: pointer) =
  doAssert keMsgHdrFromPayload(p).id == MM_SET_VIF_STATE_REQ
  sent.add(cast[ptr MmSetVifStateReqPayload](p)[])
  sentStates.add(state)
  order.add("send")
  ke_msg_free(keMsgHdrFromPayload(p))
  invoke(onSend)
proc ke_timer_clear(id: uint16; task: uint8) =
  clears.add(id)
  invoke(onClear)
proc ke_timer_set(id: uint16; task: uint8; delay: uint32) =
  delays.add(delay.uint64)
proc smRspTimerSetComeback(owner: SmTxBuildContext; intervalTu: uint32): bool =
  delays.add(max(1'u64, intervalTu.uint64 * 1024))
  not failTimer
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  copyMem(dst, src, length.int)
  invoke(onCopy)
  dst
proc smConnectIndPayloadAt(p: pointer): ptr SmConnectIndPayload = cast[ptr SmConnectIndPayload](p)
proc smAssocRspFrameView(p: pointer): ptr SmAssocRspFrameView = cast[ptr SmAssocRspFrameView](p)
proc smAssocRspBodyPtr(p: ptr SmAssocRspFrameView): pointer = addr p.capabilityInfo
proc smAssocRspIePtr(p: ptr SmAssocRspFrameView): pointer = addr p.iesFirst
proc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)
proc timeoutIntervalIeAt(p: pointer): ptr TimeoutIntervalIeView = cast[ptr TimeoutIntervalIeView](p)
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
template totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc blOpsFunc(offset: int): pointer = nil
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
proc meTryInitRate(p: pointer): bool =
  doAssert p == addr sta
  inc rates
  order.add("rate")
  invoke(onRate)
  not failRateInit
proc me_init_rate(p: pointer) = discard meTryInitRate(p)
proc tpc_update_vif_tx_power(p, power, output: pointer) =
  doAssert p == addr vif
  powers.add(cast[ptr uint8](power)[])
  order.add("power")
  invoke(onPower)
proc wpsCallbacks(): ptr Wps = addr wps
proc notifyWps() {.cdecl.} =
  inc wpsCalls
  order.add("wps")
  invoke(onWps)
proc sm_connect_ind(status, reason: uint16) = failures.add((status, reason))
proc setup(): pointer =
  doAssert live.len == 0
  conn = Conn(vifIdx: 1, retry: 2)
  replacement = Conn(vifIdx: 1)
  sm = (connectInfo: cast[pointer](addr conn), connectIndMsg: cast[pointer](addr ind),
        state: 0'u8, saQueryActive: 1'u8)
  ind = default(SmConnectIndPayload)
  vif = Vif(vifIdx: 1, staIdx: 2, operChan: addr channel)
  sta = Sta(valid: 1, instNbr: 1)
  channel.txPower = 20
  vif.bss.powerConstraint = 3
  state = 8
  rxVifEpochs = [1'u32, 1]
  stationEpochs[2] = 1
  sent.setLen(0)
  sentStates.setLen(0)
  delays.setLen(0)
  clears.setLen(0)
  powers.setLen(0)
  failures.setLen(0)
  order.setLen(0)
  rates = 0
  wpsCalls = 0
  failAlloc = false
  failTimer = false
  failRateInit = false
  enabled = true
  nimFwWpaPendingMask = 0
  onAlloc = nil
  onClear = nil
  onState = nil
  onSend = nil
  onRate = nil
  onPower = nil
  onCopy = nil
  onTrace = nil
  onWps = nil
  wps_cbs = nil
  wps.staAddConfirm = cast[pointer](notifyWps)
  result = newMessage(38)
  let f = smAssocRspFrameView(result)
  f.frameLen = 6
  f.aid = 0xC007
  rxuMgtDispatchView(result).frameCtrl = 0x10
  cast[ptr UncheckedArray[uint8]](result)[7] = 2
  cast[ptr UncheckedArray[uint8]](result)[8] = 1
proc response(ies: openArray[uint8]; status = 0'u16): pointer =
  let initial = setup()
  ke_msg_free(keMsgHdrFromPayload(initial))
  result = newMessage(38 + ies.len.uint32)
  let f = smAssocRspFrameView(result)
  f.frameLen = 6'u16 + ies.len.uint16
  f.statusCode = status
  f.aid = 0xC007
  rxuMgtDispatchView(result).frameCtrl = 0x10
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  bytes[7] = 2
  bytes[8] = 1
  for i, value in ies: bytes[38 + i] = value
proc replaceOwner() =
  sm.connectInfo = addr replacement
  sm.connectIndMsg = addr otherInd
  state = 6
proc finish(p: pointer) =
  ke_msg_free(keMsgHdrFromPayload(p))
  doAssert live.len == 0
'''


def source(trace: bool = False) -> str:
    code = "{.define: bl808WifiConnectTrace.}\n" if trace else ""
    code += layouts("TxSessionIdentity", "SmTxBuildContext", "SmActivationPrepared", "SmAssocRspFrameView",
                    "RxuMgtDispatchView", "MacIeView", "TimeoutIntervalIeView",
                    "SmConnectIndPayload", "MmSetVifStateReqPayload") + PLATFORM
    owner = (FW / "station_tx_build.nim").read_text()
    code += station_sm_source()
    for name in ["smTxBeginForVif", "smTxBegin", "smTxSessionCurrent", "smTxOwnerCurrent", "smTxSameSession", "smTxBindStation", "smTxSetOwnerState"]:
        code += procedure(owner, name)
    # Share the real response timer ownership check, including its TX serial.
    timer = (FW / "station_response_timeout.nim").read_text()
    code += "type KeTimerEntry = object\n  id: uint16\n"
    code += timer.split("proc smRspNextSerial", 1)[0].replace(" {.wifiCtrl.}", "")
    for name in ["smRspNextSerial", "smRspTimeoutCurrent", "smRspTimerBegin", "smRspTimerPublish"]:
        code += procedure(timer, name)
    # This suite isolates RX preparation; activation's full exchange has its own suite.
    code += r'''
proc smActivationReleasePrepared(prepared: var SmActivationPrepared) =
  if prepared.requests[0] != nil:
    ke_msg_free(keMsgHdrFromPayload(prepared.requests[0]))
    prepared.requests[0] = nil
proc smActivationPrepare(owner: SmTxBuildContext; indication: pointer;
                         aid: uint16; prepared: var SmActivationPrepared): bool =
  prepared.requests[0] = ke_msg_try_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_SM,
                                         MmSetVifStateReqPayloadSize)
  if prepared.requests[0] == nil: return false
  cast[ptr MmSetVifStateReqPayload](prepared.requests[0])[] =
    MmSetVifStateReqPayload(aid: aid, state: 1, vifIdx: owner.identity.vif)
  true
proc smActivationStart(owner: SmTxBuildContext; indication: pointer;
                       prepared: var SmActivationPrepared): bool =
  if not smTxOwnerCurrent(owner) or smEnvView().connectIndMsg != indication: return false
  if prepared.notifyWps and wps_cbs != nil:
    let callback = wpsCallbacks().staAddConfirm
    if callback != nil: cast[proc() {.cdecl.}](callback)()
    if not smTxOwnerCurrent(owner) or smEnvView().connectIndMsg != indication: return false
  if vifSecurity(vifChannelForIdx(owner.identity.vif)).cipher >= 2:
    nimFwWpaPendingMask = nimFwWpaPendingMask or (1'u32 shl owner.identity.vif)
  let message = prepared.requests[0]
  prepared.requests[0] = nil
  ke_msg_send(message)
  true
'''
    scan = (FW / "scan_station_ap_me.nim").read_text()
    for name in ["smAssocOwnerCurrent", "smAssocIesValid", "smAssocIePrefix", "smAssocDone"]:
        if "proc " + name + "(" in scan: code += procedure(scan, name)
    code += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    code += procedure(scan, "sm_assoc_done") + procedure(scan, "sm_assoc_rsp_handler")
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", code)))
    return "\n".join(f"var {name}: uint32" for name in debug) + "\n" + code


CASES = {
    "comeback_interval": r'''
let p = response([56'u8, 5, 3, 128, 0, 0, 0], 30)
sm_assoc_rsp_handler(p)
doAssert delays == @[131072'u64], "comeback delay was narrowed"
doAssert conn.retry == 0 and sent.len == 0 and failures.len == 0
finish(p)
''',
    "power_constraint": r'''
let p = response([])
sm_assoc_rsp_handler(p)
doAssert powers == @[17'u8], "association ignored the BSS power constraint"
doAssert sent.len == 1 and sent[0].aid == 7
finish(p)
''',
    "invalid_success_aid": r'''
for invalid in [0'u16, 2008'u16, 0x3FFF'u16]:
  let p = response([])
  smAssocRspFrameView(p).aid = invalid or 0xC000'u16
  sm_assoc_rsp_handler(p)
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  doAssert sent.len == 0 and rates == 0 and powers.len == 0
  finish(p)
''',
    "max_valid_aid": r'''
let p = response([])
smAssocRspFrameView(p).aid = 0xC000'u16 or 2007'u16
sm_assoc_rsp_handler(p)
doAssert sent.len == 1 and sent[0].aid == 2007
doAssert failures.len == 0
finish(p)
''',
    "clear_replaces_connection": r'''
let p = response([])
onClear = replaceOwner
sm_assoc_rsp_handler(p)
doAssert rates == 0 and powers.len == 0 and sent.len == 0
doAssert state == 6
finish(p)
''',
    "activation_state_before_send": r'''
let p = response([])
sm_assoc_rsp_handler(p)
doAssert sentStates == @[9'u16]
doAssert order == @["rate", "power", "state", "send"]
doAssert sm.saQueryActive == 0 and enabled
finish(p)
''',
    "full_comeback_field": r'''
let p = response([56'u8, 5, 3, 255, 255, 255, 255], 30)
sm_assoc_rsp_handler(p)
doAssert delays == @[0xFFFFFFFF'u64 * 1024]
doAssert sent.len == 0 and failures.len == 0
finish(p)
''',
    "zero_comeback": r'''
let p = response([56'u8, 5, 3, 0, 0, 0, 0], 30)
sm_assoc_rsp_handler(p)
doAssert delays == @[1'u64]
finish(p)
''',
    "comeback_allocation_failure": r'''
let p = response([56'u8, 5, 3, 128, 0, 0, 0], 30)
failTimer = true
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 0xFFFF'u16)] and sent.len == 0
finish(p)
''',
    "incorrect_timeout_type": r'''
let p = response([56'u8, 5, 2, 128, 0, 0, 0], 30)
sm_assoc_rsp_handler(p)
doAssert delays.len == 0 and failures == @[(5'u16, 30'u16)]
finish(p)
''',
    "incorrect_timeout_length": r'''
let p = response([56'u8, 4, 3, 128, 0, 0], 30)
sm_assoc_rsp_handler(p)
doAssert delays.len == 0 and failures == @[(5'u16, 30'u16)]
finish(p)
''',
    "failure_status": r'''
let p = response([], 17)
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 17'u16)]
doAssert sent.len == 0 and rates == 0
finish(p)
''',
    "failure_status_malformed_ie": r'''
let p = response([1'u8], 17)
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 17'u16)] and clears == @[SM_RSP_TIMEOUT_IND]
doAssert sent.len == 0 and rates == 0 and delays.len == 0
finish(p)
''',
    "comeback_malformed_ie_tail": r'''
let p = response([56'u8, 5, 3, 128, 0, 0, 0, 1], 30)
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 30'u16)] and clears == @[SM_RSP_TIMEOUT_IND]
doAssert sent.len == 0 and rates == 0 and delays.len == 0
finish(p)
''',
    "allocation_failure": r'''
let p = response([])
failAlloc = true
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 0xFFFF'u16)]
doAssert state == 8 and sent.len == 0 and sm.saQueryActive == 1
finish(p)
''',
    "allocation_replacement": r'''
let p = response([])
onAlloc = replaceOwner
sm_assoc_rsp_handler(p)
doAssert state == 6 and sent.len == 0 and failures.len == 0
doAssert sm.saQueryActive == 1 and nimFwWpaPendingMask == 0
finish(p)
''',
    "allocation_failure_replacement": r'''
let p = response([])
failAlloc = true
onAlloc = replaceOwner
sm_assoc_rsp_handler(p)
doAssert state == 6 and sent.len == 0 and failures.len == 0
finish(p)
''',
    "rate_replacement": r'''
let p = response([])
onRate = replaceOwner
sm_assoc_rsp_handler(p)
doAssert rates == 1 and powers.len == 0 and sent.len == 0
doAssert state == 6
finish(p)
''',
    "power_replacement": r'''
let p = response([])
onPower = replaceOwner
sm_assoc_rsp_handler(p)
doAssert powers.len == 1 and sent.len == 0 and state == 6
finish(p)
''',
    "copy_replacement": r'''
let p = response([1'u8, 2, 3, 4])
onCopy = replaceOwner
sm_assoc_rsp_handler(p)
doAssert rates == 0 and sent.len == 0 and state == 6
doAssert otherInd.assocRspIeLen == 0
finish(p)
''',
    "state_replacement": r'''
let p = response([])
vif.security.cipher = 2
onState = replaceOwner
sm_assoc_rsp_handler(p)
doAssert sent.len == 0 and state == 6
doAssert sm.saQueryActive == 1 and nimFwWpaPendingMask == 0
finish(p)
''',
    "sa_query_clear_replacement": r'''
let p = response([])
vif.security.cipher = 2
onState = proc() = onClear = replaceOwner
sm_assoc_rsp_handler(p)
doAssert sent.len == 0 and state == 6 and nimFwWpaPendingMask == 0
finish(p)
''',
    "wps_precedes_handoff": r'''
let p = response([])
sm.state = 2
wps_cbs = addr wps
sm_assoc_rsp_handler(p)
doAssert order == @["rate", "power", "state", "wps", "send"]
doAssert wpsCalls == 1
finish(p)
''',
    "wps_replacement": r'''
let p = response([])
sm.state = 2
wps_cbs = addr wps
onWps = replaceOwner
sm_assoc_rsp_handler(p)
doAssert wpsCalls == 1 and sent.len == 0 and state == 6
finish(p)
''',
    "synchronous_completion": r'''
let p = response([1'u8, 2, 3, 4])
vif.security.cipher = 2
onSend = proc() =
  doAssert state == 9 and ind.assocRspIeLen == 4
  doAssert rates == 1 and powers == @[17'u8]
  doAssert nimFwWpaPendingMask == 2 and sm.saQueryActive == 0
  replaceOwner()
  nimFwWpaPendingMask = 0
  sm.saQueryActive = 9
sm_assoc_rsp_handler(p)
doAssert sent.len == 1 and state == 6
doAssert sm.saQueryActive == 9 and nimFwWpaPendingMask == 0
finish(p)
''',
    "interrupt_state": r'''
let p = response([])
enabled = false
sm_assoc_rsp_handler(p)
doAssert sent.len == 1 and not enabled
finish(p)
''',
    "reassociation_unknown_rx_station": r'''
let p = response([])
rxuMgtDispatchView(p).frameCtrl = 0x30
rxuMgtDispatchView(p).staIdx = 0xFF
sm_assoc_rsp_handler(p)
doAssert sent.len == 1
finish(p)
''',
    "bounded_ie_prefix": r'''
let p = response([1'u8, 2, 3, 4, 2, 2, 5, 6])
ind.assocReqIeLen = 794
ind.assocIeBuffer[793] = 91
ind.assocIeBuffer[798] = 92
sm_assoc_rsp_handler(p)
doAssert ind.assocRspIeLen == 4 and sent.len == 1
doAssert ind.assocIeBuffer[794..797] == [1'u8, 2, 3, 4]
doAssert ind.assocIeBuffer[793] == 91 and ind.assocIeBuffer[798] == 92
finish(p)
''',
    "full_ie_buffer": r'''
var ies: array[800, uint8]
let p = response(ies)
sm_assoc_rsp_handler(p)
doAssert ind.assocRspIeLen == 800 and sent.len == 1
finish(p)
''',
    "no_ie_capacity": r'''
let p = response([1'u8, 2, 3, 4])
ind.assocReqIeLen = 800
sm_assoc_rsp_handler(p)
doAssert ind.assocRspIeLen == 0 and sent.len == 1
finish(p)
''',
    "invalid_request_ie_length": r'''
let p = response([])
ind.assocReqIeLen = 801
sm_assoc_rsp_handler(p)
doAssert failures == @[(5'u16, 0xFFFF'u16)] and sent.len == 0
finish(p)
''',
    "power_constraint_byte_wrap": r'''
let p = response([])
channel.txPower = -5
vif.bss.powerConstraint = 3
sm_assoc_rsp_handler(p)
doAssert powers == @[248'u8] and sent.len == 1
finish(p)
''',
    "power_constraint_overflow": r'''
for constraint in [148'u8, 149, 200, 255]:
  let p = response([])
  channel.txPower = 20
  vif.bss.powerConstraint = constraint
  sm_assoc_rsp_handler(p)
  doAssert powers == @[cast[uint8](max(20 - constraint.int, -128).int8)]
  doAssert sent.len == 1
  finish(p)
''',
    "nil_channel": r'''
let p = response([])
vif.operChan = nil
sm_assoc_rsp_handler(p)
doAssert powers.len == 0 and sent.len == 1
finish(p)
''',
    "fallback_activation": r'''
let p = response([])
sm_assoc_done(1)
doAssert sent.len == 1 and sent[0].aid == 1 and sentStates == @[9'u16]
doAssert sm.saQueryActive == 0
finish(p)
''',
    "fallback_invalid_aid": r'''
for invalid in [0'u16, 2008'u16, 0x3FFF'u16]:
  let p = response([])
  sm_assoc_done(invalid)
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  doAssert sent.len == 0 and rates == 0
  finish(p)
''',
    "fallback_ignores_other_state": r'''
let p = response([])
state = 0
let serial = smTxSerials[1]
sm_assoc_done(1)
doAssert sent.len == 0 and state == 0 and smTxSerials[1] == serial
finish(p)
''',
}

for name, change in {
    "wrong_vif": "rxuMgtDispatchView(p).vifIdx = 0",
    "wrong_station": "rxuMgtDispatchView(p).staIdx = 3",
    "invalid_station": "vif.staIdx = 7",
    "invalid_vif": "conn.vifIdx = 2",
    "wrong_subtype": "rxuMgtDispatchView(p).frameCtrl = 0xB0",
    "wrong_state": "state = 6",
    "no_connection": "sm.connectInfo = nil",
    "no_indication": "sm.connectIndMsg = nil",
    "short_body": "smAssocRspFrameView(p).frameLen = 5",
    "overstated_body": "smAssocRspFrameView(p).frameLen = 7",
}.items():
    CASES[name] = f'''
let p = response([])
{change}
let serial = smTxSerials[1]
sm_assoc_rsp_handler(p)
doAssert clears.len == 0 and sent.len == 0 and rates == 0
doAssert smTxSerials[1] == serial
finish(p)
'''

for length in [0, 1, 31, 32, 37]:
    CASES[f"short_message_{length}"] = f'''
let initial = setup()
finish(initial)
let p = newMessage({length})
sm_assoc_rsp_handler(p)
doAssert clears.len == 0 and sent.len == 0
finish(p)
'''

for name, ies in {"short_ie_header": "[1'u8]", "short_ie_body": "[1'u8, 2, 3]"}.items():
    CASES[name] = f'''
let p = response({ies})
var timer = KeTimerEntry(id: SM_RSP_TIMEOUT_IND)
let timerSerial = smRspTimerBegin(SM_RSP_TIMEOUT_IND, TASK_SM, 0)
doAssert smRspTimerPublish(SM_RSP_TIMEOUT_IND, TASK_SM, timerSerial, addr timer)
let queuedExpiry = smRspIdentity
sm_assoc_rsp_handler(p)
doAssert clears.len == 0 and sent.len == 0
doAssert smRspEntry == (addr timer) and smRspTimeoutCurrent(queuedExpiry),
  "an ignored association response invalidated the timeout owner"
finish(p)
'''


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assoc_response(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_assoc_response_trace_reentry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(trace=True) + r'''
let p = response([])
onTrace = replaceOwner
sm_assoc_rsp_handler(p)
doAssert state == 6 and sent.len == 0 and rates == 0
finish(p)
''')
