"""Exercise activation requests, ME forwarding, and station publication."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure, station_sm_source
from test_wifi_message_allocation import run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_SM = 4'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_API = 9'u8
  TASK_NONE = 0xFF'u8
  SM_ACTIVATING_STATE = 9'u16
  SmAssocRspState = 8'u16
  SmAuthenticatingState = 6'u16
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  SmSettingBssState = 4'u16
  MeIdleState = 0'u16
  MeBusyState = 1'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_SET_VIF_STATE_CFM = 25'u16
  MM_SET_PS_OPTIONS_REQ = 57'u16
  MM_SET_PS_OPTIONS_CFM = 58'u16
  MM_SET_IDLE_REQ = 26'u16
  MM_SET_IDLE_CFM = 27'u16
  MM_SET_PS_MODE_REQ = 31'u16
  MM_SET_PS_MODE_CFM = 32'u16
  ME_SET_PS_DISABLE_REQ = 0xC0F'u16
  ME_SET_PS_DISABLE_CFM = 0xC10'u16
  SM_STA_ADD_IND = 0x100A'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  WLAN_FW_ASSOCIATE_FAIILURE = 5
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  KeMsgTailSlack = 4'u32
  MmSetVifStateReqPayloadSize = sizeof(MmSetVifStateReqPayload).uint32
  MmSetPsOptionsReqPayloadSize = sizeof(MmSetPsOptionsReqPayload).uint32
  MeSetPsDisableReqPayloadSize = sizeof(MeSetPsDisableReqPayload).uint32
  SmStaAddIndPayloadSize = sizeof(SmStaAddIndPayload).uint32
  WifiKeyMgmtPsk = 2'u32
  WifiKeyMgmtPskSha256 = 256'u32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: ptr CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Connection = object
    vifIdx, psOptions, authType: uint8
    listenInterval, ctrlPortEthertype: uint16
  Sta = object
    valid, instNbr, controlPortState: uint8
    rateWord: uint16
    macAddr: array[6, uint8]
    keyHolder: pointer
  Vif = object
    vifIdx, vifType, staIdx, state: uint8
    listenInterval: uint16
    psOptions: uint8
    key: tuple[flags: uint32]
    security: tuple[cipher, connected: uint8, keyMgmt: uint32]
    ap: tuple[securityFlags: uint32]
  Wps = object
    staAddConfirm: pointer
var
  connection, replacement: Connection
  stations: array[7, Sta]
  vifs: array[2, Vif]
  indication, otherIndication: uint32
  sm: tuple[connectInfo, connectIndMsg: pointer, saQueryActive, state: uint8]
  mm: tuple[rxPromiscUploadFlag: uint8, rxFilterBase: uint32]
  vifMgmt: tuple[apCount: uint8]
  me: tuple[requesterId, psOn: uint8, activeMask, psDisableMask: uint32]
  state, meState: uint16
  rxVifEpochs: array[2, uint32]
  txResetEpoch, psModeBuildSerial: uint32
  ps: tuple[flags, pendingCount: uint8, currentVif: pointer]
  stationEpochs: array[7, uint32]
  rxKeyLastChanged: array[7, uint64]
  smTxSerials: array[2, uint32]
  nimFwWpaPendingMask: uint32
  keMsgQueueSent, keMsgQueueSaved: CoList
  meControlCommand, meControlReply, apmStartRequest, apmStartReply, mmPsModeRequest: pointer
  meControlReplyReady, apmStartReplyPublished, meConfigInProgress: bool
  meControlEpoch: uint32
  meControlExpectedId, meControlFinalId: uint16
  meControlRequester: uint8
  wps: Wps
  wps_cbs: pointer
  allocated: seq[pointer]
  events: seq[tuple[id: uint16, dst, src: uint8]]
  applied: seq[uint16]
  failures: seq[tuple[status, reason: uint16]]
  stationReady, connected, filterUpdates, calls: int
  lastStation: SmStaAddIndPayload
  lastAllocId, lastSendId: uint16
  failAt, replaceAt: int
  enabled = true
  holdMMMode: bool
  onPeer: proc(p: pointer)
  onEapol: proc(station: uint8; source, data: pointer; length: uint16)
  onAlloc, onFree, onSend, onState, onFilter, onTrace, onReady, onClear: proc()
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
proc mmEnvView(): ptr typeof(mm) = addr mm
proc vifMgmtEnvView(): ptr typeof(vifMgmt) = addr vifMgmt
proc meEnvView(): ptr typeof(me) = addr me
proc psEnvView(): ptr typeof(ps) = addr ps
proc connectInfoView(p: pointer): ptr Connection = cast[ptr Connection](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < 7
  addr stations[index]
proc vifSecurity(p: ptr Vif): ptr typeof(vifs[0].security) = addr p.security
proc vifKeyPointers(p: ptr Vif): ptr typeof(vifs[0].key) = addr p.key
proc vifApConfig(p: ptr Vif): ptr typeof(vifs[0].ap) = addr p.ap
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 7: stationEpochs[index] else: 0
proc ke_state_get(task: uint8): uint16 =
  if task == TASK_SM: state else: meState
proc ke_state_set(task: uint8; value: uint16) =
  if task == TASK_SM: state = value
  else: meState = value
  invoke(onState)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(h: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](h) + sizeof(KeMsgHdr).uint)
proc smActivationForget(header: pointer)
proc sm_handle_eapol_input(station: uint8; source, data: pointer; length: uint16) =
  if onEapol != nil: onEapol(station, source, data, length)
proc co_list_push_back*(list: ptr CoList; elem: ptr CoListHdr) {.exportc, cdecl, noinline.}
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  inc calls
  lastAllocId = id
  if calls != failAt:
    let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + length.int + 4))
    header[] = KeMsgHdr(id: id, destId: dst, srcId: src, paramLen: length)
    allocated.add(header)
    result = keMsgPayload(header)
  invoke(onAlloc)
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  ke_msg_try_alloc(id, dst, src, length)
proc ke_msg_free(header: pointer) =
  smActivationForget(header)
  let index = allocated.find(header)
  doAssert index >= 0, "message released twice"
  allocated.delete(index)
  dealloc(header)
  invoke(onFree)
proc ke_msg_send(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  lastSendId = header.id
  events.add((header.id, header.destId, header.srcId))
  if header.id == SM_STA_ADD_IND and onPeer != nil:
    inc stationReady
    onPeer(p)
    ke_msg_free(header)
    return
  co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](header))
  invoke(onSend)
proc smActivationCancel()
proc sm_connect_ind(status, reason: uint16) =
  if status == 0: inc connected
  else:
    failures.add((status, reason))
    smActivationCancel()
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  state = SmIdleState
proc mm_rx_filter_set() =
  inc filterUpdates
  invoke(onFilter)
proc ke_timer_clear(id: uint16; task: uint8) = invoke(onClear)
proc wpsCallbacks(): ptr Wps = addr wps
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
proc assert_err(a, b: cstring; line: cint) = doAssert false, $a & ":" & $line
proc smBssOwnsRequest(p: pointer): bool = false
proc smBssAdmitRequest(p: pointer): bool = true
proc smBssAdmitControlReply(p: pointer): bool = true
proc smBssConsumeReply(p: pointer): bool = false
proc smBssTakeReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc smCleanupOwnsRequest(p: pointer): bool = false
proc smCleanupAdmitRequest(p: pointer): bool = true
proc smCleanupConsumeReply(p: pointer): bool = false
proc smCleanupTakeReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc apmTakeStartReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc sm_send_next_bss_param() = doAssert false
proc meCancelQueuedPayload(payload: pointer)
proc smActivationCancelControl(request, reply: pointer; owner: SmTxBuildContext): bool
proc meTakeControlReply(request: pointer; id: uint16; length: uint32): pointer
proc ke_msg_alloc_reply*(request: pointer; id: uint16; length: uint32): pointer
'''


WORKER = r'''
proc setup(vifIndex = 1'u8; staIndex = 2'u8; cipher = 0'u8; flags = 0'u32) =
  doAssert allocated.len == 0
  connection = Connection(vifIdx: vifIndex, psOptions: 3, listenInterval: 17,
                          ctrlPortEthertype: 0x8E88)
  replacement = Connection(vifIdx: vifIndex)
  sm = (connectInfo: cast[pointer](addr connection), connectIndMsg: cast[pointer](addr indication),
        saQueryActive: 1'u8, state: 0'u8)
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  vifs[vifIndex] = Vif(vifIdx: vifIndex, staIdx: staIndex)
  vifs[vifIndex].key.flags = flags
  vifs[vifIndex].security.cipher = cipher
  stations[staIndex] = Sta(valid: 1, instNbr: vifIndex)
  state = 8
  meState = MeIdleState
  me = (requesterId: TASK_NONE, psOn: 1'u8, activeMask: 0'u32,
        psDisableMask: 1'u32 shl vifIndex)
  meControlCommand = nil
  meControlReply = nil
  meControlReplyReady = false
  mmPsModeRequest = nil
  rxVifEpochs = [1'u32, 1]
  stationEpochs = [1'u32, 1, 1, 1, 1, 1, 1]
  smTxSerials = [1'u32, 1]
  nimFwWpaPendingMask = 0
  events.setLen(0)
  applied.setLen(0)
  failures.setLen(0)
  stationReady = 0
  connected = 0
  filterUpdates = 0
  vifMgmt.apCount = 0
  calls = 0
  failAt = 0
  enabled = true
  holdMMMode = false
  onPeer = nil
  onEapol = nil
  wps_cbs = nil
  onAlloc = nil
  onFree = nil
  onSend = nil
  onState = nil
  onFilter = nil
  onTrace = nil
  onReady = nil
  onClear = nil
proc replaceOwner() =
  sm.connectInfo = addr replacement
  sm.connectIndMsg = addr otherIndication
  state = 6
proc replaceAtAllocation() =
  if calls == replaceAt: replaceOwner()
  else: onAlloc = replaceAtAllocation
proc begin(vifIndex = 1'u8; staIndex = 2'u8; cipher = 0'u8; flags = 0'u32) =
  setup(vifIndex, staIndex, cipher, flags)
  sm_assoc_done(7)
  doAssert smActivation.active and state == 9 and calls == 7
proc consumeReply(p: pointer) =
  case keMsgHdrFromPayload(p).id
  of MM_SET_VIF_STATE_CFM:
    doAssert cast[proc(p: pointer): cint {.cdecl.}](mm_set_vif_state_cfm_handler)(p) == KeMsgConsumed
  of MM_SET_PS_OPTIONS_CFM: discard smActivationOptionsCfmHandler(p)
  of ME_SET_PS_DISABLE_CFM:
    doAssert cast[proc(p: pointer): cint {.cdecl.}](me_set_ps_disable_cfm_handler_sm)(p) == KeMsgConsumed
  else: doAssert false
proc dispatchOne(): bool =
  let node = co_list_pop_front(addr keMsgQueueSent)
  if node == nil: return false
  let header = cast[ptr KeMsgHdr](node)
  let p = keMsgPayload(header)
  var outcome = KeMsgConsumed
  case header.destId
  of TASK_SM: consumeReply(p)
  of TASK_ME:
    if header.id == ME_SET_PS_DISABLE_REQ: outcome = me_set_ps_disable_req_handler(p)
    else: outcome = meCompleteControl(p, header.id)
  of TASK_MM:
    if smActivationAdmitRequest(p):
      applied.add(header.id)
      case header.id
      of MM_SET_VIF_STATE_REQ:
        let req = cast[ptr MmSetVifStateReqPayload](p)
        doAssert req.aid == 7 and req.state == 1
        vifs[req.vifIdx].state = 1
        ke_msg_send_basic_reply(p, MM_SET_VIF_STATE_CFM)
      of MM_SET_PS_OPTIONS_REQ:
        outcome = cast[proc(p: pointer): cint {.cdecl.}](mm_set_ps_options_req_handler)(p)
      of MM_SET_PS_MODE_REQ:
        if holdMMMode:
          mmPsModeRequest = p
          outcome = KeMsgNoFree
        else: ke_msg_send_basic_reply(p, MM_SET_PS_MODE_CFM)
      else: doAssert false
  of TASK_API:
    doAssert header.id == SM_STA_ADD_IND
    lastStation = cast[ptr SmStaAddIndPayload](p)[]
    inc stationReady
    invoke(onReady)
  else: doAssert false
  if outcome == KeMsgConsumed: ke_msg_free(header)
  elif outcome == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, cast[ptr CoListHdr](header))
  true
proc drain() =
  var steps = 0
  while dispatchOne():
    inc steps
    doAssert steps < 64
proc takeReply(index: int): pointer =
  while true:
    let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
    doAssert header != nil
    if header.destId == TASK_SM and smActivation.step == index:
      discard co_list_pop_front(addr keMsgQueueSent)
      return keMsgPayload(header)
    doAssert dispatchOne()
proc finish() =
  onAlloc = nil
  onFree = nil
  onSend = nil
  onState = nil
  onFilter = nil
  onTrace = nil
  onReady = nil
  onClear = nil
  smActivationCancel()
  while keMsgQueueSent.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
  while keMsgQueueSaved.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSaved))
  doAssert allocated.len == 0 and smActivationTags == nil
  doAssert meControlCommand == nil and meControlReply == nil and mmPsModeRequest == nil
'''


def source(trace: bool = False) -> str:
    code = "{.define: bl808WifiConnectTrace.}\n" if trace else ""
    code += layouts("TxSessionIdentity", "SmTxBuildContext", "SmActivationPrepared",
                    "MmSetVifStateReqPayload", "MmSetPsOptionsReqPayload",
                    "MeSetPsDisableReqPayload", "SmStaAddIndPayload") + PLATFORM
    code += procedure((FW / "layout_types.nim").read_text(), "lmacGateHalfword")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_pop_front", "co_list_push_back", "ke_queue_extract"]:
        code += procedure(kernel, name)
    owner = (FW / "station_tx_build.nim").read_text()
    code += station_sm_source()
    for name in ["smTxBeginForVif", "smTxBegin", "smTxSessionCurrent", "smTxOwnerCurrent", "smTxSameSession", "smTxBindStation", "smTxSetOwnerState"]:
        code += procedure(owner, name)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(scan, "smAssocOwnerCurrent")
    code += (FW / "station_activation.nim").read_text()
    task = (FW / "task_handlers.nim").read_text()
    code += "\nwhen not declared(ke_reschedule_saved_messages):\n  proc ke_reschedule_saved_messages(task: uint8): bool {.discardable.} = false\n"
    for name in ["meControlMessageMatches", "meCancelQueuedPayload", "mmPsModeCancel",
                 "meControlReset", "meTakeControlReply", "smActivationCancelControl",
                 "meReserveControl", "meForwardControl", "meBeginControl", "meCompleteControl"]:
        code += procedure(task, name)
    code += procedure(kernel, "ke_msg_alloc_reply") + procedure(kernel, "ke_msg_send_basic_reply")
    for name in ["mm_set_ps_options_req_handler", "mm_set_vif_state_cfm_handler",
                 "smActivationOptionsCfmHandler", "me_set_ps_disable_req_handler",
                 "me_set_ps_disable_cfm_handler_sm"]:
        code += procedure(task, name)
    code += procedure(scan, "smAssocDone") + procedure(scan, "sm_assoc_done")
    code += "proc smRetireEstablishedSupplicantLink(station: uint8; reason: uint16) = doAssert false\n"
    code += "proc sm_handle_supplicant_result*" + scan.split(
        "proc sm_handle_supplicant_result*", 1
    )[1].split("\n  if reason == 15:", 1)[0] + "\n"
    code += WORKER
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", code)))
    return "\n".join(f"var {name}: uint32" for name in debug) + "\n" + code


CASES = {
    "psk_peer_requires_current_host_link": r'''
for failure in 0..3:
  setup(cipher=3)
  vifs[1].security.connected = 1
  vifs[1].security.keyMgmt = WifiKeyMgmtPsk
  onPeer = proc(p: pointer) =
    case failure
    of 0: discard # host never linked the peer
    of 1: doAssert not smActivationAcceptPeer(p, 0, 2, true)
    of 2: doAssert not smActivationAcceptPeer(p, 1, 1, true)
    else:
      inc stationEpochs[2]
      doAssert not smActivationAcceptPeer(p, 1, 2, true)
  sm_assoc_done(7)
  drain()
  doAssert stations[2].controlPortState == 0 and connected == 0
  doAssert failures.len == int(failure < 3)
  finish()
''',
    "non_psk_publication_unchanged": r'''
for profile in 0..3:
  setup(cipher=3)
  vifs[1].security.connected = 1
  vifs[1].security.keyMgmt = WifiKeyMgmtPsk
  case profile
  of 0:
    connection.authType = 3
    vifs[1].security.cipher = 4
    vifs[1].security.keyMgmt = 1024
  of 1: sm.state = 2
  of 2: connection.ctrlPortEthertype = 0x3412
  else: vifs[1].security.keyMgmt = 1
  sm_assoc_done(7)
  let vifReply = takeReply(0)
  consumeReply(vifReply)
  ke_msg_free(keMsgHdrFromPayload(vifReply))
  doAssert events[^1].id == MM_SET_PS_OPTIONS_REQ and stationReady == 0
  drain()
  doAssert stationReady == 1 and connected == 0
  finish()
''',
    "psk_peer_at_vif_confirmation": r'''
setup(cipher=3)
vifs[1].security.connected = 1
vifs[1].security.keyMgmt = WifiKeyMgmtPsk
onPeer = proc(p: pointer) =
  smActivationTrackPeer(p, nil, 1, proc(hw: pointer; station: uint8; token: uint32; retire: bool): bool = true)
  doAssert smActivationAcceptPeer(p, 1, 2, true)
sm_assoc_done(7)
let vifReply = takeReply(0)
consumeReply(vifReply)
doAssert events[^2].id == SM_STA_ADD_IND and events[^1].id == MM_SET_PS_OPTIONS_REQ
doAssert stations[2].controlPortState == 1 and connected == 0
ke_msg_free(keMsgHdrFromPayload(vifReply))
drain()
doAssert stationReady == 1
finish()
''',
    "control_policy_matrix": r'''
for vifIndex in 0'u8 .. 1'u8:
  for staIndex in 0'u8 .. 6'u8:
    for cipher in 0'u8 .. 4'u8:
      for flags in 0'u32 .. 3'u32:
        for psOn in 0'u8 .. 1'u8:
          begin(vifIndex, staIndex, cipher, flags)
          me.psOn = psOn
          drain()
          let expected = if cipher >= 2: 1'u8 else: 2'u8 - (flags and 1).uint8
          doAssert stations[staIndex].controlPortState == expected
          doAssert stations[staIndex].rateWord == 0x888E
          doAssert connected == (if cipher <= 1: 1 else: 0)
          doAssert stationReady == 1 and calls == 7
          doAssert lastStation.vifIdx == vifIndex and lastStation.staIdx == staIndex
          doAssert vifs[vifIndex].listenInterval == 17 and vifs[vifIndex].psOptions == 3
          doAssert not smActivation.active
          finish()
''',
    "complete_exchange": r'''
begin()
drain()
doAssert calls == 7 and connected == 1 and stationReady == 1
doAssert applied == @[MM_SET_VIF_STATE_REQ, MM_SET_PS_OPTIONS_REQ, MM_SET_PS_MODE_REQ]
doAssert vifs[1].listenInterval == 17 and vifs[1].psOptions == 3
doAssert me.psDisableMask == 0 and stations[2].controlPortState == 2
doAssert lastStation.vifIdx == 1 and lastStation.staIdx == 2
finish()
''',
    "station_preserves_registered_ap_filter": r'''
for base in [0x3507858C'u32, 0x3507A58C'u32]:
  begin()
  vifMgmt.apCount = 1
  mm.rxFilterBase = base
  drain()
  doAssert connected == 1 and stationReady == 1
  doAssert mm.rxFilterBase == base and filterUpdates == 0
  finish()
''',
    "unrelated_confirmation": r'''
begin()
let p = ke_msg_alloc(MM_SET_VIF_STATE_CFM, TASK_SM, TASK_MM, 0)
mm_set_vif_state_cfm_handler(p)
doAssert stationReady == 0 and connected == 0 and filterUpdates == 0
doAssert smActivation.step == 0
ke_msg_free(keMsgHdrFromPayload(p))
drain()
doAssert connected == 1
finish()
''',
    "filter_replacement": r'''
begin()
onFilter = replaceOwner
drain()
doAssert stationReady == 0 and connected == 0 and failures.len == 0
finish()
''',
    "allocation_failure_every_buffer": r'''
for failed in 1..7:
  setup()
  failAt = failed
  sm_assoc_done(7)
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  doAssert events.len == 0 and stationReady == 0 and connected == 0
  doAssert allocated.len == 0 and not smActivation.active
  finish()
''',
    "allocation_replaces_connection": r'''
for selected in 1..7:
  setup()
  replaceAt = selected
  onAlloc = replaceAtAllocation
  sm_assoc_done(7)
  doAssert events.len == 0 and failures.len == 0 and allocated.len == 0
  doAssert state == 6 and sm.connectInfo == addr replacement
  finish()
''',
    "failed_allocation_replaces_connection": r'''
for selected in 1..7:
  setup()
  failAt = selected
  replaceAt = selected
  onAlloc = replaceAtAllocation
  sm_assoc_done(7)
  doAssert failures.len == 0 and events.len == 0 and allocated.len == 0
  finish()
''',
    "cancel_each_dispatch_stage": r'''
for stage in 0..7:
  begin()
  for step in 0..<stage: doAssert dispatchOne()
  smActivationCancel()
  drain()
  doAssert stationReady == 0 and connected == 0 and failures.len == 0
  finish()
''',
    "stale_reply_each_stage": r'''
for index in 0..2:
  begin()
  let old = takeReply(index)
  replaceOwner()
  smActivationCancel()
  state = 8
  sm_assoc_done(7)
  let before = events.len
  consumeReply(old)
  doAssert smActivation.step == 0 and events.len == before
  ke_msg_free(keMsgHdrFromPayload(old))
  drain()
  doAssert connected == 1 and stationReady == 1
  finish()
''',
    "duplicate_reply_each_stage": r'''
for index in 0..2:
  begin()
  let reply = takeReply(index)
  consumeReply(reply)
  let before = events.len
  consumeReply(reply)
  doAssert events.len == before
  ke_msg_free(keMsgHdrFromPayload(reply))
  drain()
  doAssert connected == 1 and stationReady == 1
  finish()
''',
    "reply_metadata": r'''
for index in 0..2:
  for field in 0..3:
    begin()
    let reply = takeReply(index)
    let header = keMsgHdrFromPayload(reply)
    let original = header[]
    case field
    of 0: header.id = 0xFFFF
    of 1: header.srcId = TASK_API
    of 2: header.destId = TASK_ME
    else: header.paramLen = 1
    doAssert smActivationConfirm(reply, index)
    doAssert smActivation.step == index and stationReady == 0
    header[] = original
    consumeReply(reply)
    ke_msg_free(header)
    drain()
    doAssert connected == 1
    finish()
''',
    "lost_request_and_reply": r'''
for loseReply in [false, true]:
  begin()
  let lost = if loseReply: keMsgHdrFromPayload(takeReply(0))
    else: cast[ptr KeMsgHdr](co_list_pop_front(addr keMsgQueueSent))
  ke_msg_free(lost)
  doAssert smActivationNeedsService()
  smActivationService()
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  doAssert not smActivation.active and stationReady == 0
  finish()
''',
    "ME_busy_saved_request": r'''
begin()
let initial = takeReply(0)
consumeReply(initial)
ke_msg_free(keMsgHdrFromPayload(initial))
let options = takeReply(1)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
meState = MeBusyState
doAssert dispatchOne()
doAssert keMsgQueueSaved.first != nil and smActivation.active
meState = MeIdleState
co_list_push_back(addr keMsgQueueSent, co_list_pop_front(addr keMsgQueueSaved))
drain()
doAssert connected == 1
finish()
''',
    "cancel_held_MM_request": r'''
begin()
holdMMMode = true
drain()
doAssert mmPsModeRequest != nil and meControlCommand != nil and smActivation.active
smActivationCancel()
doAssert me.psDisableMask == 0 and connected == 0
finish()
''',
    "private_tag_alignment": r'''
begin()
var tag = smActivationTags
var count = 0
while tag != nil:
  doAssert cast[uint](tag) mod alignof(SmActivationTag).uint == 0
  doAssert tag.header.paramLen == (if tag.command: SmActivationLengths[tag.index.int] else: 0'u32)
  tag = tag.next
  inc count
doAssert count == 6
drain()
finish()
''',
    "interrupt_state": r'''
begin()
enabled = false
drain()
doAssert not enabled and connected == 1
finish()
''',
    "state_change_during_preparation": r'''
setup()
onState = replaceOwner
sm_assoc_done(7)
doAssert events.len == 0 and allocated.len == 0 and state == 6
finish()
''',
    "station_indication_replacement": r'''
begin()
proc replaceOnStationSend() =
  if lastSendId == SM_STA_ADD_IND: replaceOwner()
  else: onSend = replaceOnStationSend
onSend = replaceOnStationSend
drain()
doAssert connected == 0 and state == 6
finish()
''',
    "filter_starts_replacement_activation": r'''
begin()
onFilter = proc() =
  replaceOwner()
  vifs[1].key.flags = 1
  state = 8
  sm_assoc_done(7)
drain()
doAssert connected == 1 and stationReady == 1
doAssert stations[2].controlPortState == 1
doAssert calls == 14 and not smActivation.active
finish()
''',
    "cleanup_free_starts_replacement_activation": r'''
begin(flags = 1)
let options = takeReply(1)
onFree = proc() =
  replaceOwner()
  state = 8
  sm_assoc_done(7)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
drain()
doAssert connected == 1 and stationReady == 1 and calls == 14
finish()
''',
    "request_payload_identity": r'''
begin()
let initial = keMsgPayload(cast[ptr KeMsgHdr](keMsgQueueSent.first))
let req = cast[ptr MmSetVifStateReqPayload](initial)
req.vifIdx = 0
doAssert not smActivationAdmitRequest(initial)
req.vifIdx = 1
req.state = 0
doAssert not smActivationAdmitRequest(initial)
req.state = 1
doAssert smActivationAdmitRequest(initial)
drain()
doAssert connected == 1
finish()
''',
    "unforwarded_MM_command_rejected": r'''
begin()
let options = takeReply(1)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
let command = cast[ptr KeMsgHdr](keMsgQueueSent.first)
let original = command[]
command.id = MM_SET_PS_MODE_REQ
command.srcId = TASK_ME
command.destId = TASK_MM
command.paramLen = 1
doAssert not smActivationAdmitRequest(keMsgPayload(command))
command[] = original
drain()
doAssert connected == 1
finish()
''',
    "cancel_during_ME_state_publication": r'''
begin()
let options = takeReply(1)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
onState = proc() =
  replaceOwner()
  smActivationCancel()
drain()
doAssert meState == MeIdleState and connected == 0 and stationReady == 0
finish()
''',
    "completion_waits_for_control_acknowledgements": r'''
begin()
let last = takeReply(2)
doAssert connected == 0 and stationReady == 0
doAssert meState == MeIdleState and me.psDisableMask == 0
consumeReply(last)
ke_msg_free(keMsgHdrFromPayload(last))
doAssert connected == 1 and not smActivation.active
drain()
doAssert stationReady == 1
finish()
''',
    "forwarded_reply_metadata": r'''
begin()
while true:
  let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
  doAssert header != nil
  if header.id == MM_SET_PS_MODE_CFM and header.destId == TASK_ME: break
  doAssert dispatchOne()
let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
let original = header[]
let reply = keMsgPayload(header)
for field in 0..3:
  case field
  of 0: header.id = 0xFFFF
  of 1: header.srcId = TASK_SM
  of 2: header.destId = TASK_SM
  else: header.paramLen = 1
  doAssert meCompleteControl(reply, MM_SET_PS_MODE_CFM) == KeMsgConsumed
  doAssert meState == MeBusyState and smActivation.step == 2
  header[] = original
drain()
doAssert connected == 1 and stationReady == 1
finish()
''',
    "standalone_station_ready": r'''
setup()
state = 9
doAssert smActivationNotifyCurrent()
drain()
doAssert stationReady == 1 and connected == 0
finish()
''',
    "station_ready_allocation_replacement": r'''
setup()
state = 9
onAlloc = replaceOwner
doAssert not smActivationNotifyCurrent()
doAssert events.len == 0 and failures.len == 0 and allocated.len == 0
finish()
''',
    "station_ready_allocation_failure": r'''
setup()
state = 9
failAt = 1
doAssert not smActivationNotifyCurrent()
doAssert failures == @[(5'u16, 0xFFFF'u16)] and events.len == 0
finish()
''',
    "owner_fields_independent": r'''
for changed in 0..9:
  begin()
  case changed
  of 0: sm.connectInfo = addr replacement
  of 1: sm.connectIndMsg = addr otherIndication
  of 2: inc rxVifEpochs[1]
  of 3: inc stationEpochs[2]
  of 4: vifs[1].vifType = 2
  of 5: vifs[1].vifIdx = 0
  of 6: stations[2].valid = 0
  of 7: stations[2].instNbr = 0
  of 8: state = 10
  else: inc smTxSerials[1]
  drain()
  doAssert applied.len == 0 and stationReady == 0 and connected == 0
  doAssert smActivationNeedsService()
  smActivationService()
  doAssert not smActivation.active and failures.len == 0
  finish()
''',
    "request_vif_each_phase": r'''
for index in 0..2:
  begin()
  while smActivation.step < index: doAssert dispatchOne()
  let request = smActivation.request
  if index == 0: cast[ptr MmSetVifStateReqPayload](request).vifIdx = 0
  elif index == 1: cast[ptr MmSetPsOptionsReqPayload](request).vifIdx = 0
  else: cast[ptr MeSetPsDisableReqPayload](request).vifIdx = 0
  doAssert not smActivationAdmitRequest(request)
  if index == 0: cast[ptr MmSetVifStateReqPayload](request).vifIdx = 1
  elif index == 1: cast[ptr MmSetPsOptionsReqPayload](request).vifIdx = 1
  else: cast[ptr MeSetPsDisableReqPayload](request).vifIdx = 1
  drain()
  doAssert connected == 1
  finish()
''',
    "cleanup_does_not_cancel_replacement": r'''
begin()
let oldConnection = sm.connectInfo
replaceOwner()
state = 8
sm_assoc_done(7)
doAssert smActivation.active and smActivation.owner.connection == addr replacement
smActivationCancelConnection(oldConnection)
doAssert smActivation.active
drain()
doAssert connected == 1 and stationReady == 1
finish()
''',
    "WPA_success_before_control_completes": r'''
begin(cipher = 3)
sm_handle_supplicant_result(2, 0)
doAssert connected == 0 and smActivation.supplicantReady
drain()
doAssert connected == 1 and stationReady == 1
doAssert stations[2].controlPortState == 2
finish()
''',
    "WPA_success_during_final_free": r'''
begin(cipher = 3, flags = 1)
let finalReply = takeReply(1)
onFree = proc() = sm_handle_supplicant_result(2, 0)
consumeReply(finalReply)
ke_msg_free(keMsgHdrFromPayload(finalReply))
drain()
doAssert connected == 1 and stationReady == 1
doAssert stations[2].controlPortState == 2
finish()
''',
    "WPA_success_during_station_publication": r'''
begin(cipher = 3)
proc completeWhenReady() =
  if lastSendId == SM_STA_ADD_IND: sm_handle_supplicant_result(2, 0)
  else: onSend = completeWhenReady
onSend = completeWhenReady
drain()
doAssert connected == 1 and stationReady == 1
doAssert stations[2].controlPortState == 2
finish()
''',
    "unrelated_WPA_success_does_not_complete_activation": r'''
begin(cipher = 3)
sm_handle_supplicant_result(3, 0)
doAssert not smActivation.supplicantReady and connected == 0
drain()
doAssert connected == 0 and stationReady == 1
doAssert stations[2].controlPortState == 1
finish()
''',
    "WPS_callback_completes_WPA_early": r'''
proc wpsSuccess() {.cdecl.} = sm_handle_supplicant_result(2, 0)
setup(cipher = 3)
wps_cbs = addr wps
wps.staAddConfirm = cast[pointer](wpsSuccess)
var owner = smTxBegin(sm.connectInfo)
doAssert smTxBindStation(owner, 2)
doAssert smAssocDone(owner, sm.connectIndMsg, 7, true)
doAssert smActivation.supplicantReady and connected == 0
drain()
doAssert connected == 1 and stationReady == 1 and stations[2].controlPortState == 2
finish()
''',
    "synchronous_queue_drain": r'''
setup()
onSend = drain
sm_assoc_done(7)
doAssert connected == 1 and stationReady == 1 and calls == 7
doAssert not smActivation.active and allocated.len == 0
finish()
''',
    "control_reset_preserves_reentrant_activation": r'''
begin()
holdMMMode = true
drain()
doAssert mmPsModeRequest != nil and meState == MeBusyState
onFree = proc() =
  replaceOwner()
  me.psDisableMask = 2
  meState = MeIdleState
  state = 8
  sm_assoc_done(7)
  drain()
smActivationCancel()
doAssert smActivation.active and meControlCommand != nil and mmPsModeRequest != nil
doAssert meState == MeBusyState, "old reset overwrote the new control state"
holdMMMode = false
let request = mmPsModeRequest
mmPsModeRequest = nil
ke_msg_send_basic_reply(request, MM_SET_PS_MODE_CFM)
ke_msg_free(keMsgHdrFromPayload(request))
drain()
doAssert connected == 1 and stationReady == 1
finish()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_activation_exchange(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_activation_trace_reentry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(trace=True) + r'''
begin()
onTrace = replaceOwner
drain()
doAssert connected == 0 and stationReady == 0 and state == 6
finish()
''')


def test_activation_dispatcher_result_types() -> None:
    handlers = (FW / "task_handlers.nim").read_text()
    for name in ["mm_set_vif_state_cfm_handler", "mm_set_ps_options_req_handler",
                 "me_set_ps_disable_cfm_handler_sm", "smActivationOptionsCfmHandler"]:
        body = procedure(handlers, name)
        assert ": cint" in body.splitlines()[0]
        assert "KeMsgConsumed" in body


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_queue_cancel_allocation_reuse(tmp_path: Path, mode: str) -> None:
    platform = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = CoListHdr
var
  node: CoListHdr
  keMsgQueueSent, keMsgQueueSaved: CoList
  freed: int
proc irqSave(): uint32 = 8
proc irqRestore(saved: uint32) = doAssert saved == 8
proc assert_err(a, b: cstring; line: cint) = doAssert false
proc keMsgPayload(header: ptr KeMsgHdr): pointer = cast[pointer](header)
proc co_list_push_back*(list: ptr CoList; elem: ptr CoListHdr) {.exportc, cdecl, noinline.}
proc ke_msg_free(p: pointer) =
  inc freed
  if freed == 1: co_list_push_back(addr keMsgQueueSaved, cast[ptr CoListHdr](p))
'''
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    code = platform + procedure(kernel, "co_list_push_back") + procedure(kernel, "ke_queue_extract")
    code += procedure(handlers, "meControlMessageMatches") + procedure(handlers, "meCancelQueuedPayload")
    code += r'''
co_list_push_back(addr keMsgQueueSent, addr node)
meCancelQueuedPayload(addr node)
doAssert freed == 1 and keMsgQueueSaved.first == addr node,
  "queue cancellation consumed a replacement allocation"
'''
    run_program(tmp_path, mode, code)
