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
  txResetEpoch: uint32
  ps: tuple[flags, pendingCount: uint8, currentVif: pointer]
  stationEpochs: array[7, uint32]
  rxKeyLastChanged: array[7, uint64]
  nimFwWpaPendingMask: uint32
  keMsgQueueSent, keMsgQueueSaved: CoList
  meControlCommand, meControlReply, apmStartRequest, apmStartReply, psHeldRequest: pointer
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
proc smConnectIndModel(status, reason: uint16)
proc sm_connect_ind(status, reason: uint16) = smConnectIndModel(status, reason)
proc mm_rx_filter_set() =
  inc filterUpdates
  invoke(onFilter)
proc ke_timer_clear(id: uint16; task: uint8) = invoke(onClear)
proc wpsCallbacks(): ptr Wps = addr wps
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
proc assert_err(a, b: cstring; line: cint) = doAssert false, $a & ":" & $line
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  index < 7 and stations[index].valid != 0 and stationEpochs[index] == epoch
proc smCleanupConfirmed() = doAssert false, "no cleanup runs here"
proc apmTakeStartReply(p: pointer; id: uint16; length: uint32): pointer = nil
proc sm_send_next_bss_param() = doAssert false
proc meTakeControlReply(request: pointer; id: uint16; length: uint32): pointer
proc ke_msg_alloc_reply*(request: pointer; id: uint16; length: uint32): pointer
proc ke_msg_send_basic_reply*(request: pointer; id: uint16)
'''


WORKER = r"""
proc smConnectIndModel(status, reason: uint16) =
  ## sm_connect_ind: a success ends the attempt in state 0; a failure starts
  ## its teardown, which withdraws the activation (smCleanupBegin).
  if status == 0: inc connected
  else: failures.add((status, reason))
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  discard smGo(if status == 0: SmIdleState else: SmDisconnectingState)
  if status != 0: smActivationCancel()
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
  smOwn = default(typeof(smOwn))
  smActivation = default(typeof(smActivation))
  state = 8
  meState = MeIdleState
  me = (requesterId: TASK_NONE, psOn: 1'u8, activeMask: 0'u32,
        psDisableMask: 1'u32 shl vifIndex)
  meControlCommand = nil
  meControlReply = nil
  meControlReplyReady = false
  psHeldRequest = nil
  rxVifEpochs = [1'u32, 1]
  stationEpochs = [1'u32, 1, 1, 1, 1, 1, 1]
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
proc endAttempt() =
  ## The attempt ends (its teardown): SM leaves state 9.
  smConnectIndModel(9, 1)
proc allocateAttempt() =
  ## The attempt's SM_CONNECT_REQ and SM_CONNECT_IND as allocated messages,
  ## which smAbandon frees.
  let info = ke_msg_try_alloc(0x1000'u16, TASK_SM, TASK_API, sizeof(Connection).uint32)
  cast[ptr Connection](info)[] = connectInfoView(sm.connectInfo)[]
  sm.connectInfo = info
  sm.connectIndMsg = ke_msg_try_alloc(0x1002'u16, TASK_API, TASK_SM, 4)
proc retireVif(index: uint8) =
  ## vif_mgmt_unregister: the slot is freed, ME forgets the VIF's mask bits
  ## and SM is told (smStaVifRetired).
  vifs[index] = Vif(vifIdx: 127, vifType: 4, staIdx: 0xFF)
  me.activeMask = me.activeMask and not (1'u32 shl index)
  me.psDisableMask = me.psDisableMask and not (1'u32 shl index)
  smStaVifRetired(index)
proc replaceOwner() =
  ## SM has moved on to another attempt, in state 6.
  sm.connectInfo = addr replacement
  sm.connectIndMsg = addr otherIndication
  discard smGo(6)
proc begin(vifIndex = 1'u8; staIndex = 2'u8; cipher = 0'u8; flags = 0'u32) =
  setup(vifIndex, staIndex, cipher, flags)
  sm_assoc_done(7)
  doAssert smActivationLive() and state == 9 and calls == 2
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
    if not smStaleRequest(p):
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
          psHeldRequest = p
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
proc releaseMM() =
  ## MM's PS transition ends and answers the request it held (psFinish).
  let request = psHeldRequest
  doAssert request != nil
  psHeldRequest = nil
  holdMMMode = false
  ke_msg_send_basic_reply(request, MM_SET_PS_MODE_CFM)
  ke_msg_free(keMsgHdrFromPayload(request))
proc drain() =
  var steps = 0
  while dispatchOne():
    inc steps
    doAssert steps < 64
proc takeReply(index: int): pointer =
  ## The answer to the activation's request `index`; earlier ones are handled.
  while true:
    let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
    doAssert header != nil
    if header.destId == TASK_SM:
      discard co_list_pop_front(addr keMsgQueueSent)
      result = keMsgPayload(header)
      if smActivation.step == index: return
      consumeReply(result)
      ke_msg_free(header)
    else: doAssert dispatchOne()
proc finish() =
  onAlloc = nil
  onFree = nil
  onSend = nil
  onState = nil
  onFilter = nil
  onTrace = nil
  onReady = nil
  onClear = nil
  # SM stops waiting, so its repliers drop what is still queued; ME and MM
  # finish an exchange already started.
  discard smGo(SmIdleState)
  smActivationCancel()
  if psHeldRequest != nil: releaseMM()
  drain()
  while keMsgQueueSent.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
  while keMsgQueueSaved.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSaved))
  doAssert allocated.len == 0
  doAssert meControlCommand == nil and meControlReply == nil and psHeldRequest == nil
"""


def source(trace: bool = False) -> str:
    code = "{.define: bl808WifiConnectTrace.}\n" if trace else ""
    code += layouts("TxSessionIdentity",
                    "MmSetVifStateReqPayload", "MmSetPsOptionsReqPayload",
                    "MeSetPsDisableReqPayload", "SmStaAddIndPayload") + PLATFORM
    code += procedure((FW / "layout_types.nim").read_text(), "lmacGateHalfword")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_pop_front", "co_list_push_back", "ke_queue_extract"]:
        code += procedure(kernel, name)
    code += station_sm_source("smGo", "smSendReserved", "smAwaits", "smStaleRequest",
                              "smTakeReply", "smTakeAnswer", "smAbandon", "smStaVifRetired")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += (FW / "station_activation.nim").read_text()
    task = (FW / "task_handlers.nim").read_text()
    code += "\nwhen not declared(ke_reschedule_saved_messages):\n  proc ke_reschedule_saved_messages(task: uint8): bool {.discardable.} = false\n"
    for name in ["meTakeControlReply", "meReserveControl", "meForwardControl", "meBeginControl",
                 "meCompleteControl"]:
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
    # A WPA2-PSK TX peer must be linked by the host while it handles the
    # indication; otherwise the attempt fails (it is reported, whatever the
    # host did to the station).
    "psk_peer_requires_current_host_link": r"""
for failure in 0..3:
  setup(cipher=3)
  vifs[1].security.connected = 1
  vifs[1].security.keyMgmt = WifiKeyMgmtPsk
  onPeer = proc(p: pointer) =
    case failure
    of 0: discard # host never linked the peer
    of 1: doAssert not smActivationAcceptPeer(p, 0, 2, true)
    of 2: doAssert not smActivationAcceptPeer(p, 1, 1, true)
    else: inc stationEpochs[2]
  sm_assoc_done(7)
  drain()
  doAssert stations[2].controlPortState == 0 and connected == 0
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  finish()
""",
    "non_psk_publication_unchanged": r"""
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
""",
    "psk_peer_at_vif_confirmation": r"""
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
""",
    # Each request goes out with its reply reserved: two allocations per
    # request, one for the station indication.
    "control_policy_matrix": r"""
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
          doAssert stationReady == 1 and calls == (if (flags and 1) == 0: 7 else: 5)
          doAssert lastStation.vifIdx == vifIndex and lastStation.staIdx == staIndex
          doAssert vifs[vifIndex].listenInterval == 17 and vifs[vifIndex].psOptions == 3
          doAssert not smActivationLive()
          finish()
""",
    "complete_exchange": r"""
begin()
drain()
doAssert calls == 7 and connected == 1 and stationReady == 1 and state == SmIdleState
doAssert applied == @[MM_SET_VIF_STATE_REQ, MM_SET_PS_OPTIONS_REQ, MM_SET_PS_MODE_REQ]
doAssert vifs[1].listenInterval == 17 and vifs[1].psOptions == 3
doAssert me.psDisableMask == 0 and stations[2].controlPortState == 2
doAssert lastStation.vifIdx == 1 and lastStation.staIdx == 2
doAssert smOwn.request == nil and smOwn.reply == nil and smOwn.answer == nil
finish()
""",
    "station_preserves_registered_ap_filter": r"""
for base in [0x3507858C'u32, 0x3507A58C'u32]:
  begin()
  vifMgmt.apCount = 1
  mm.rxFilterBase = base
  drain()
  doAssert connected == 1 and stationReady == 1
  doAssert mm.rxFilterBase == base and filterUpdates == 0
  finish()
""",
    "unrelated_confirmation": r"""
begin()
let p = ke_msg_alloc(MM_SET_VIF_STATE_CFM, TASK_SM, TASK_MM, 0)
mm_set_vif_state_cfm_handler(p)
doAssert stationReady == 0 and connected == 0 and filterUpdates == 0
doAssert smActivation.step == 0
ke_msg_free(keMsgHdrFromPayload(p))
drain()
doAssert connected == 1
finish()
""",
    # A request or reply allocation, or the station indication's, that fails
    # ends the attempt with WLAN_FW_ASSOCIATE_FAIILURE.
    "allocation_failure_every_buffer": r"""
for failed in 1..7:
  setup()
  failAt = failed
  sm_assoc_done(7)
  drain()
  doAssert failures == @[(5'u16, 0xFFFF'u16)]
  doAssert stationReady == 0 and connected == 0 and state == SmDisconnectingState
  doAssert not smActivationLive()
  finish()
""",
    # The attempt ends at each point of the exchange. ME and MM finish what
    # they started (as in the blob, nothing is cancelled); SM ignores the
    # answer and nothing is reported twice or left allocated.
    "attempt_ends_each_dispatch_stage": r"""
for stage in 0..7:
  begin()
  for step in 0..<stage: discard dispatchOne()
  let reported = failures.len + connected
  endAttempt()
  drain()
  doAssert failures.len + connected == reported + 1
  doAssert stationReady <= 1 and meState == MeIdleState
  finish()
""",
    "stale_reply_each_stage": r"""
for index in 0..2:
  begin()
  let old = takeReply(index)
  endAttempt()
  # The next attempt reaches state 9 before the old answer is handled.
  sm.connectInfo = addr connection
  sm.connectIndMsg = addr indication
  state = 8
  sm_assoc_done(7)
  let before = events.len
  consumeReply(old)
  doAssert smActivation.step == 0 and events.len == before
  ke_msg_free(keMsgHdrFromPayload(old))
  drain()
  doAssert connected == 1 and stationReady == 1
  finish()
""",
    "duplicate_reply_each_stage": r"""
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
""",
    "ME_busy_saved_request": r"""
begin()
let initial = takeReply(0)
consumeReply(initial)
ke_msg_free(keMsgHdrFromPayload(initial))
let options = takeReply(1)
consumeReply(options)
ke_msg_free(keMsgHdrFromPayload(options))
meState = MeBusyState
doAssert dispatchOne()
doAssert keMsgQueueSaved.first != nil and smActivationLive()
meState = MeIdleState
co_list_push_back(addr keMsgQueueSent, co_list_pop_front(addr keMsgQueueSaved))
drain()
doAssert connected == 1
finish()
""",
    # The attempt ends while MM holds ME's forward of the last request: the
    # exchange completes and ME goes idle; SM ignores the answer.
    "attempt_ends_with_MM_holding_the_forward": r"""
begin()
holdMMMode = true
drain()
doAssert psHeldRequest != nil and meControlCommand != nil and smActivationLive()
endAttempt()
releaseMM()
drain()
doAssert meState == MeIdleState and connected == 0 and stationReady == 0
doAssert failures.len == 1
finish()
""",
    "interrupt_state": r"""
begin()
enabled = false
drain()
doAssert not enabled and connected == 1
finish()
""",
    "completion_waits_for_control_acknowledgements": r"""
begin()
let last = takeReply(2)
doAssert connected == 0 and stationReady == 0
doAssert meState == MeIdleState and me.psDisableMask == 0
consumeReply(last)
ke_msg_free(keMsgHdrFromPayload(last))
doAssert connected == 1 and not smActivationLive()
drain()
doAssert stationReady == 1
finish()
""",
    "forwarded_reply_metadata": r"""
begin()
while true:
  let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
  doAssert header != nil
  if header.id == MM_SET_PS_MODE_CFM and header.destId == TASK_ME: break
  doAssert dispatchOne()
let header = cast[ptr KeMsgHdr](keMsgQueueSent.first)
let original = header[]
let reply = keMsgPayload(header)
for field in 0..2:
  case field
  of 0: header.id = 0xFFFF
  of 1: header.srcId = TASK_SM
  else: header.destId = TASK_SM
  doAssert meCompleteControl(reply, MM_SET_PS_MODE_CFM) == KeMsgConsumed
  doAssert meState == MeBusyState and smActivation.step == 2
  header[] = original
drain()
doAssert connected == 1 and stationReady == 1
finish()
""",
    "standalone_station_ready": r"""
setup()
state = 9
doAssert smActivationNotifyCurrent()
drain()
doAssert stationReady == 1 and connected == 0
finish()
""",
    "station_ready_allocation_failure": r"""
setup()
state = 9
failAt = 1
doAssert not smActivationNotifyCurrent()
doAssert failures == @[(5'u16, 0xFFFF'u16)] and events.len == 0
finish()
""",
    # SMCONN-F6 by construction: only SM's own operation ends the exchange.
    # A TX reset or a VIF epoch does not; a station deleted under it ends
    # the attempt, reported.
    "only_the_sm_operation_ends_the_activation": r"""
for changed in 0..2:
  begin()
  case changed
  of 0: inc txResetEpoch
  of 1: inc rxVifEpochs[1]
  else: inc stationEpochs[2]
  drain()
  if changed < 2:
    doAssert connected == 1 and stationReady == 1 and failures.len == 0
  else:
    doAssert connected == 0 and failures == @[(5'u16, 0xFFFF'u16)]
  finish()
""",
    # The removal of the STA VIF (vif_mgmt_unregister) ends the attempt at
    # once, unreported, with any request in flight: its replier drops it
    # unapplied and ME forgets the VIF's PS-disable bit.
    "vif_removal_ends_the_activation": r"""
for step in 0..2:
  begin()
  allocateAttempt()
  while smActivation.step < step:
    doAssert dispatchOne()
  let sent = smOwn.request
  doAssert sent != nil
  let before = applied.len
  retireVif(1)
  doAssert state == SmIdleState and not smActivationLive() and smOwn.request == nil
  doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
  doAssert me.psDisableMask == 0
  drain()
  doAssert applied.len == before, "a request was applied to the removed VIF"
  doAssert connected == 0 and failures.len == 0 and meState == MeIdleState
  finish()
""",
    # The host ends the attempt while it handles SM_STA_ADD_IND (a send to
    # TASK_API is a synchronous host callout): the activation does not
    # report the attempt again.
    "station_indication_ends_the_attempt": r"""
begin()
proc endOnStationSend() =
  if lastSendId == SM_STA_ADD_IND: endAttempt()
  else: onSend = endOnStationSend
onSend = endOnStationSend
drain()
doAssert connected == 0 and failures == @[(9'u16, 1'u16)]
finish()
""",
    # The WPS callback ends the attempt: no request is sent for it.
    "wps_callback_ends_the_attempt": r"""
proc wpsEnd() {.cdecl.} = endAttempt()
setup()
wps_cbs = addr wps
wps.staAddConfirm = cast[pointer](wpsEnd)
smAssocDone(1, 2, 7, true)
doAssert failures == @[(9'u16, 1'u16)] and connected == 0
doAssert events.len == 0 and smOwn.request == nil and not smActivationLive()
finish()
""",
    "WPA_success_before_control_completes": r"""
begin(cipher = 3)
sm_handle_supplicant_result(2, 0)
doAssert connected == 0 and smActivation.supplicantReady
drain()
doAssert connected == 1 and stationReady == 1
doAssert stations[2].controlPortState == 2
finish()
""",
    "WPA_success_during_station_publication": r"""
begin(cipher = 3)
proc completeWhenReady() =
  if lastSendId == SM_STA_ADD_IND: sm_handle_supplicant_result(2, 0)
  else: onSend = completeWhenReady
onSend = completeWhenReady
drain()
doAssert stationReady == 1
doAssert connected == 1 and stations[2].controlPortState == 2
finish()
""",
    "unrelated_WPA_success_does_not_complete_activation": r"""
begin(cipher = 3)
sm_handle_supplicant_result(3, 0)
doAssert not smActivation.supplicantReady and connected == 0
drain()
doAssert connected == 0 and stationReady == 1
doAssert stations[2].controlPortState == 1
finish()
""",
    "WPS_callback_completes_WPA_early": r"""
proc wpsSuccess() {.cdecl.} = sm_handle_supplicant_result(2, 0)
setup(cipher = 3)
wps_cbs = addr wps
wps.staAddConfirm = cast[pointer](wpsSuccess)
smAssocDone(1, 2, 7, true)
doAssert smActivation.supplicantReady and connected == 0
drain()
doAssert connected == 1 and stationReady == 1 and stations[2].controlPortState == 2
finish()
""",
    "synchronous_queue_drain": r"""
setup()
onSend = drain
sm_assoc_done(7)
doAssert connected == 1 and stationReady == 1 and calls == 7
doAssert not smActivationLive() and allocated.len == 0
finish()
""",
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_activation_exchange(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


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
