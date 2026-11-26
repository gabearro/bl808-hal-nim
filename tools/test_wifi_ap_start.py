"""Run the AP startup transaction and its pointer ABIs without a radio."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import procedure
from test_wifi_beacon_frames import AP_EXTRAS_PLATFORM
from test_wifi_disconnect_tx import procedure as fw_procedure, ps_machine_source


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_AP = 2'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_APM = 5'u8
  TASK_API = 9'u8
  TASK_NONE = 255'u8
  ApmIdleState = 0'u16
  ApmActiveState = 1'u16
  ApmStartingState = 2'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  APM_START_CFM = 0x1401'u16
  APM_STOP_CFM = 0x1403'u16
  APM_STA_CONNECT_TIMEOUT_IND = 0x1406'u16
  WLAN_FW_APM_DELETECONNECTION_TIMEOUT = 4
  ME_SET_PS_DISABLE_REQ = 0xC0F'u16
  ME_SET_PS_DISABLE_CFM = 0xC10'u16
  ME_SET_ACTIVE_REQ = 0xC0D'u16
  ME_SET_ACTIVE_CFM = 0xC0E'u16
  ME_CONFIG_REQ = 0xC00'u16
  ME_CONFIG_CFM = 0xC01'u16
  MeBusyState = 1'u16
  MeIdleState = 0'u16
  MM_IDLE = 0'u16
  HW_ACTIVE = 3'u16
  TaskGoingIdleState = 2'u16
  MACHW_STATE_CNTRL_REG = 0x24B00038'u
  MM_SET_BSSID_REQ = 20'u16
  MM_SET_BASIC_RATES_REQ = 18'u16
  MM_SET_BEACON_INT_REQ = 16'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_SET_VIF_STATE_CFM = 25'u16
  MM_BCN_CHANGE_REQ = 45'u16
  MM_BCN_CHANGE_CFM = 46'u16
  MM_SET_IDLE_REQ = 26'u16
  MM_SET_IDLE_CFM = 27'u16
  MM_SET_PS_MODE_REQ = 31'u16
  MM_SET_PS_MODE_CFM = 32'u16
  StaTxPolicyUpdateTxPower = 16'u8
type
  Header = object
    next: ptr Header
    id: uint16
    srcId, destId: uint8
    paramLen: uint32
  CoListHdr = Header
  KeMsgHdr = Header
  CoList = object
    first, last: ptr Header
  VifChannelView = object
    vifIdx, vifType, state, beaconEnabled: uint8
    next, chanCtxt, operChan: pointer
    channelFreqPair: uint32
    config: array[100, uint8]
    security: tuple[cipher: uint8, rsnIeLen: uint16, rsnIePtr: uint32]
    key: tuple[flags: uint32]
    beaconIntervalTu, apStartBeaconInterval: uint16
    psBaCounter, wmmQosInfo: uint8
    supportedRatesLong: array[34, uint8]
    basicRates: array[13, uint8]
    macAddr, bssid: array[6, uint8]
    edcaRegs: array[4, uint32]
  Station = object
    rateSeed: array[13, uint8]
    vifType, txPolicyUpdateFlags, status, valid, infoIdx, instNbr: uint8
    connectionStart: uint32
  Apm = object
    connectInfo, pendingBeaconBuffer, hostapdCtx: pointer
    pendingBssParams: CoList
    embeddedEnabled, flags, vifIdx, cryptoType, selfStaIdx, maxSta, staCount: uint8
    securityIe: array[64, uint8]
  Context = object
    contextIndexOrMarker, invalidMarker: uint8
  Callbacks = object
    beaconRegister, apStopped: pointer
  PlatformLogFunc = proc(level, severity: uint32; file: pointer;
    line: uint32) {.cdecl, varargs.}
  PsKind = enum
    psIdle, psExplicit, psSleep, psWake
var
  apm: Apm
  vifs: array[2, VifChannelView]
  stations: array[7, Station]
  channel: ScanChannelEntry
  contexts: array[3, Context]
  callbacks: Callbacks
  wpa_cbs: pointer
  apmStartConfirmation, apmStartBeaconMessage, apmStartVifMessage: pointer
  apmStartReplyPool: array[6, pointer]
  apmStartReplyIndex: int
  apmStartRequest, apmStartReply: pointer
  apmStartReplyId: uint16
  apmStartReplySource: uint8
  apmStartReplyPublished: bool
  apmRollbackCommands, apmRollbackReplies: array[3, pointer]
  apmStartSideEffects, apmRollbackActive, apmRollbackHaltPending: bool
  apmRollbackStatus: uint8
  apmStopActive: bool
  apmStopVifIdx: uint8
  apmStopRequest: pointer
  meControlCommand, meControlReply: pointer
  # ps_machine.nim's record, as far as an explicit transition needs it.
  psOwn: tuple[kind: PsKind, request: pointer]
  txResetEpoch: uint32
  meControlReplyReady: bool
  meControlExpectedId, meControlFinalId: uint16
  meControlRequester: uint8
  keMsgQueueSent, keMsgQueueSaved: CoList
  apmPendingCancelMask, apmStoppingVifs: uint8
  rxVifEpochs: array[MAX_VIFS, uint32]
  apmPendingAssociations: array[5, int]
  me: tuple[htSupp, psOn, requesterId, nss, htCapByte: uint8,
            activeMask, psDisableMask: uint32, htCaps: array[32, uint8], defKey: uint16]
  mm: tuple[idleFlag, previousState, hardwareMode: uint8]
  vifMgmt: tuple[activeList: CoList]
  ps: tuple[mode, pendingCount, flags: uint8, currentVif: pointer, statusFlags: uint32]
  state, meState, mmState: uint16
  psDeferred: bool
  psModes: seq[uint8]
  idleRequests: int
  phyNss: uint8
  allocated: seq[pointer]
  cfms: seq[ApmStartCfmPayload]
  controlReplies: seq[tuple[id: uint16, src, dst: uint8, length: uint32]]
  configCfmSawCommand: bool
  configCfmSawOriginalRequest: bool
  configCfmSeenFields: tuple[htSupp, psOn, nss, htCapByte: uint8, defKey: uint16]
  configCfmSeenRequester: uint8
  configCfmSeenCapInfo: uint16
  configCfmHook: proc()
  meConfigInProgress: bool
  meControlEpoch: uint32
  timers: seq[uint16]
  timerClears: seq[uint16]
  cancelled, deleted: seq[uint8]
  stopHook, deleteHook: proc()
  beaconResetHook, cancelHook: proc()
  now: uint32
  channelStatus: uint8
  channelAdds, channelDeletes, kernelAllocations, failAt: int
  beaconAllocs, beaconFrees, initialized, deinitialized, rateInitialized: int
  beaconAllocationFails, channelMissing, initFails: bool
  hostContext: uint64
  expectedVif: uint8
  expectedFreq: uint16
  expectedSsid: array[4, uint8]
  expectedPhrase: string
  request: pointer
  requestFreed: bool
  lastBeacon: pointer
  poolBusy: bool
  beaconResets: int
  beaconStops: int
  firmwareStatus: uint16
  copiedBeacon: seq[uint8]
proc calloc(count, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc c_memset(dst: pointer; v: cint; n: csize_t): pointer =
  doAssert v == 0
  zeroMem(dst, n.int)
  dst
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc keMsgPayload(p: ptr Header): pointer = cast[pointer](cast[uint](p) + sizeof(Header).uint)
proc newMessage(id: uint16; dst, src: uint8; n: uint32): pointer =
  let h = cast[ptr Header](calloc(1, (sizeof(Header) + n.int).csize_t))
  doAssert h != nil
  h[] = Header(id: id, destId: dst, srcId: src, paramLen: n)
  result = keMsgPayload(h)
  allocated.add(result)
proc ke_msg_alloc(id: uint16; dst, src: uint8; n: uint32): pointer =
  inc kernelAllocations
  if kernelAllocations == failAt: return nil
  result = newMessage(id, dst, src, n)
  if id == MM_SET_BASIC_RATES_REQ:
    cast[ptr MmSetBasicRatesReqPayload](result).band = 0xFF
proc ke_msg_free(h: pointer) =
  let p = keMsgPayload(cast[ptr Header](h))
  let index = allocated.find(p)
  doAssert index >= 0, "double free or unowned message"
  allocated.delete(index)
  if p == request: requestFreed = true
  free(h)
proc co_list_push_back(q: ptr CoList; p: ptr Header)
proc ke_msg_send(p: pointer) =
  let h = keMsgHdrFromPayload(p)
  if h.destId >= TASK_API:
    if h.id == ME_CONFIG_CFM:
      configCfmSawCommand = keMsgQueueSent.first != nil
      configCfmSeenFields = (me.htSupp, me.psOn, me.nss, me.htCapByte, me.defKey)
      configCfmSeenRequester = me.requesterId
      configCfmSeenCapInfo = me.htCaps[0].uint16 or
        (me.htCaps[1].uint16 shl 8)
      if meControlCommand != nil:
        let original = keMsgHdrFromPayload(meControlCommand)
        configCfmSawOriginalRequest = original.id == ME_CONFIG_REQ and
          original.destId == TASK_ME and original.srcId == TASK_API and
          original.paramLen == MeConfigReqPayloadSize
      if configCfmHook != nil: configCfmHook()
    if h.id != APM_START_CFM:
      controlReplies.add((h.id, h.srcId, h.destId, h.paramLen))
      ke_msg_free(h)
      return
    doAssert h.id == APM_START_CFM
    if cast[ptr ApmStartCfmPayload](p).status == 0:
      doAssert state == ApmIdleState and apm.connectInfo == nil
    elif cast[ptr ApmStartCfmPayload](p).status == 1 and apmRollbackStatus == 1:
      let index = cast[ptr ApmStartCfmPayload](p).vifIdx
      doAssert (me.activeMask and (1'u32 shl index)) == 0
      doAssert (me.psDisableMask and (1'u32 shl index)) == 0
      doAssert vifs[index].state == 0 and vifs[index].beaconEnabled == 0
    cfms.add(cast[ptr ApmStartCfmPayload](p)[])
    ke_msg_free(h)
  else:
    co_list_push_back(addr keMsgQueueSent, h)
proc ke_msg_send_basic(id: uint16; dest, src: uint8) =
  let p = ke_msg_alloc(id, dest, src, 0)
  if p != nil: ke_msg_send(p)
proc co_list_push_back(q: ptr CoList; p: ptr Header) =
  p.next = nil
  if q.last == nil: q.first = p
  else: q.last.next = p
  q.last = p
proc co_list_pop_front(q: ptr CoList): ptr Header =
  result = q.first
  if result != nil:
    q.first = result.next
    if q.first == nil: q.last = nil
    result.next = nil
proc irqSave(): uint32 = 8
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc txlResetting(): bool = false
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool =
  selected = 0
  true
proc irqRestore(saved: uint32) = doAssert saved == 8
proc ke_reschedule_saved_messages(task: uint8): bool =
  var previous: ptr Header
  var node = keMsgQueueSaved.first
  while node != nil:
    let next = node.next
    if node.destId == task:
      if previous == nil: keMsgQueueSaved.first = next
      else: previous.next = next
      if keMsgQueueSaved.last == node: keMsgQueueSaved.last = previous
      co_list_push_back(addr keMsgQueueSent, node)
    else: previous = node
    node = next
  false
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc vifApConfig(v: ptr VifChannelView): ptr VifApConfigOverlay = cast[ptr VifApConfigOverlay](addr v.config[0])
proc vifSecurity(v: ptr VifChannelView): ptr typeof(v.security) = addr v.security
proc vifKeyPointers(v: ptr VifChannelView): ptr typeof(v.key) = addr v.key
proc apmEnvView(): ptr Apm = addr apm
proc meEnvView(): ptr typeof(me) = addr me
proc mmEnvView(): ptr typeof(mm) = addr mm
proc psEnvView(): ptr typeof(ps) = addr ps
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc staInfoForIdx(i: uint8): ptr Station = addr stations[i]
proc apSelfStaStart(s: ptr Station): ptr Station = s
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc getLogFunc(n: int): PlatformLogFunc = nil
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc KE_FIRST_MSG(task: uint16): uint16 = task shl 10
proc assert_err(file, expression: cstring; line: int) =
  doAssert false, $file & ":" & $line
proc mm_bcn_change(p: pointer) = lastBeacon = p
proc mmBeaconPoolIdle(): bool = not poolBusy
proc mm_bcn_init_vif(p: pointer) =
  inc beaconResets
  if beaconResetHook != nil: beaconResetHook()
proc mm_bcn_stop(p: pointer): bool =
  inc beaconStops
  cast[ptr VifChannelView](p).beaconEnabled = 0
  true
proc ke_state_set(task: uint8; value: uint16) =
  if task == TASK_APM: state = value
  elif task == TASK_MM: mmState = value
  else:
    doAssert task == TASK_ME
    meState = value
  discard ke_reschedule_saved_messages(task)
proc ke_state_get(task: uint8): uint16 =
  if task == TASK_APM: state elif task == TASK_MM: mmState else: meState
proc mm_active() = ke_state_set(TASK_MM, 1)
proc hal_machw_idle_req() = inc idleRequests
proc mmConfigCancelIdle() = discard
proc psAnswer(request: pointer)
proc psComplete() =
  ## psFinish of the live explicit transition: answer its request and
  ## release MM's saved requests.
  let request = psOwn.request
  psOwn = default(typeof(psOwn))
  if request != nil: psAnswer(request)
  discard ke_reschedule_saved_messages(TASK_MM)
proc psCancel() =
  ## ps_machine.nim's psCancel: free the request unanswered and release
  ## MM's saved requests.
  let request = psOwn.request
  psOwn = default(typeof(psOwn))
  if request != nil: ke_msg_free(keMsgHdrFromPayload(request))
  discard ke_reschedule_saved_messages(TASK_MM)
proc psHold(request: pointer) = psOwn.request = request
proc meTakeControlReply(request: pointer; id: uint16; length: uint32): pointer
proc smStaleRequest(request: pointer): bool = false
proc smAwaits(request: pointer): bool = false
proc smTakeReply(request: pointer; id: uint16): pointer = nil
proc smActivationConfirmed() = discard
proc smActivationCancel() = discard
proc ps_set_mode(mode, requester: uint8) =
  psOwn.kind = psExplicit
  ps.mode = requester
  psModes.add(mode)
  if not psDeferred: psComplete()
proc ps_polling_frame(p: pointer): uint8 = 0
proc phy_get_nss(): uint8 = phyNss
proc vifMgmtEnvView(): ptr typeof(vifMgmt) = addr vifMgmt
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc ke_timer_set(id: uint16; task: uint8; delay: uint32) =
  doAssert task == TASK_APM and delay == 5000000
  timers.add(id)
proc ke_timer_clear(id: uint16; task: uint8) =
  doAssert task == TASK_APM
  timerClears.add(id)
proc apmCancelPendingForVif(vif: uint8) =
  cancelled.add(vif)
  apmPendingCancelMask = apmPendingCancelMask or (1'u8 shl vif)
  if cancelHook != nil: cancelHook()
proc apm_sta_fw_delete(index: uint8; status, reason: uint16) =
  doAssert status == 4 and reason == 65535
  deleted.add(index)
  if deleteHook != nil:
    let hook = deleteHook
    deleteHook = nil
    hook()
proc chan_ctxt_add(p: pointer; index: ptr uint8): uint8 =
  doAssert cast[uint](index) > 65535, "channel output pointer was truncated"
  let d = cast[ptr ChanCtxtDefView](p)
  doAssert d.primFreq == expectedFreq and d.centerFreq1 == expectedFreq and d.centerFreq2 == 0
  doAssert d.txPower == 17
  inc channelAdds
  if channelStatus == 0: index[] = 2
  channelStatus
proc chan_ctxt_link(vif, index: uint8) =
  doAssert index == 2 and vif == expectedVif
  contexts[index].contextIndexOrMarker = index
  vifs[vif].chanCtxt = addr contexts[index]
proc chan_ctxt_del(index: uint8) =
  doAssert index == 2
  inc channelDeletes
proc chan_ctxt_unlink(vif: uint8) =
  doAssert vif == expectedVif
  vifs[vif].chanCtxt = nil
  inc channelDeletes
proc me_freq_to_chan_ptr(band: uint8; freq: uint16): pointer =
  doAssert band == 0 and freq == expectedFreq
  if channelMissing: nil else: addr channel
proc regRead(address: uint): uint32 =
  if address == MACHW_STATE_CNTRL_REG: 0 else: 0x1234
proc me_legacy_rate_bitfield_build(p: pointer; flag: uint8): uint32 =
  let r = cast[ptr array[13, uint8]](p)
  doAssert r[0] > 0 and r[0] <= 12
  15
proc me_init_bcmc_rate(p: pointer) = inc rateInitialized
proc tpc_update_vif_tx_power(v, p, r: pointer) =
  doAssert cast[ptr uint8](p)[] == 17
proc allocBeacon(n: uint32): pointer {.cdecl.} =
  doAssert n == 512
  inc beaconAllocs
  if beaconAllocationFails: nil else: calloc(1, n.csize_t)
proc freeBeacon(p: pointer) {.cdecl.} =
  inc beaconFrees
  free(p)
proc clockRead(): uint32 {.cdecl.} = now
proc blOpsFunc(n: int): pointer =
  case n
  of 184: cast[pointer](allocBeacon)
  of 188: cast[pointer](freeBeacon)
  of 200: cast[pointer](clockRead)
  else: nil
when defined(bl808WifiMbedTlsSha1Lease):
  var keySetupActive, keySetupFails: bool
  proc beginShaApKeySetup(): bool =
    if keySetupActive: return false
    keySetupActive = true
    true
  proc finishShaApKeySetup(): bool =
    doAssert keySetupActive
    keySetupActive = false
    not keySetupFails
proc initialize(p: pointer): pointer {.cdecl.} =
  let a = cast[ptr WpaBeaconRegisterParamView](p)
  doAssert sizeof(WpaBeaconRegisterParamView) == 112
  doAssert a.vifIdx == expectedVif and a.ssidLength == 4
  doAssert a.ssid[0 .. 3] == expectedSsid
  doAssert a.authMode == 3 and a.pairwiseCipher == 4
  for i, value in expectedPhrase: doAssert a.passphrase[i] == value.uint8
  doAssert a.passphrase[expectedPhrase.len] == 0
  inc initialized
  if initFails: nil else: addr hostContext
proc deinitialize(p: pointer): bool {.cdecl.} =
  doAssert p == (addr hostContext) and apm.hostapdCtx == nil
  inc deinitialized
  if stopHook != nil:
    let hook = stopHook
    stopHook = nil
    hook()
  true
proc me_build_beacon(buf: pointer; vif: uint8; tim: ptr uint16;
                     timLength: ptr uint8; hidden: uint8): uint32 =
  doAssert vif == expectedVif and hidden == 0
  let bytes = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0 ..< 200: bytes[i] = (i and 255).uint8
  tim[] = 80
  timLength[] = 6
  200
proc reset(vif: uint8; secure = true) =
  poolBusy = false
  beaconResets = 0
  beaconStops = 0
  # Successful startup intentionally retains only the six teardown buffers.
  var reserved: seq[pointer]
  for pool in [apmRollbackCommands, apmRollbackReplies]:
    for p in pool:
      if p != nil: reserved.add(p)
  doAssert allocated.len == reserved.len
  for p in allocated: doAssert p in reserved
  apmFreeStartBuffers()
  doAssert allocated.len == 0
  apm = default(Apm)
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  apmStartConfirmation = nil
  apmStartBeaconMessage = nil
  apmStartVifMessage = nil
  apmStartReplyPool = default(typeof(apmStartReplyPool))
  apmStartReplyIndex = 0
  apmStartRequest = nil
  apmStartReply = nil
  apmStartReplyPublished = false
  apmRollbackCommands = default(typeof(apmRollbackCommands))
  apmRollbackReplies = default(typeof(apmRollbackReplies))
  apmStartSideEffects = false
  apmRollbackActive = false
  apmRollbackHaltPending = false
  apmRollbackStatus = 0
  apmStopActive = false
  apmStopVifIdx = 255
  apmStopRequest = nil
  apmPendingCancelMask = 0
  apmStoppingVifs = 0
  state = ApmIdleState
  meState = 0
  mmState = 0
  meControlCommand = nil
  meControlReply = nil
  meControlReplyReady = false
  psOwn = default(typeof(psOwn))
  ps = default(typeof(ps))
  psDeferred = false
  psModes.setLen(0)
  idleRequests = 0
  phyNss = 1
  me = default(typeof(me))
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  cfms.setLen(0)
  controlReplies.setLen(0)
  configCfmSawCommand = false
  configCfmSawOriginalRequest = false
  configCfmSeenFields = default(typeof(configCfmSeenFields))
  configCfmSeenRequester = 0
  configCfmSeenCapInfo = 0
  configCfmHook = nil
  meConfigInProgress = false
  timers.setLen(0)
  timerClears.setLen(0)
  cancelled.setLen(0)
  deleted.setLen(0)
  stopHook = nil
  deleteHook = nil
  beaconResetHook = nil
  cancelHook = nil
  now = 80000
  channelStatus = 0
  channelAdds = 0
  channelDeletes = 0
  kernelAllocations = 0
  failAt = 0
  beaconAllocs = 0
  beaconFrees = 0
  initialized = 0
  deinitialized = 0
  rateInitialized = 0
  beaconAllocationFails = false
  channelMissing = false
  initFails = false
  copiedBeacon.setLen(0)
  expectedVif = vif
  expectedFreq = 2437
  expectedSsid = [97'u8, 0, 98, 99]
  expectedPhrase = "password"
  channel = default(ScanChannelEntry)
  vifs[vif].vifIdx = vif
  vifs[vif].vifType = VIF_TYPE_AP
  vifs[vif].macAddr = [2'u8, 3, 4, 5, 6, 7]
  callbacks = Callbacks(beaconRegister: cast[pointer](initialize), apStopped: cast[pointer](deinitialize))
  wpa_cbs = addr callbacks
  request = newMessage(0x1400, TASK_APM, TASK_API, sizeof(ApmStartReqView).uint32)
  requestFreed = false
  let r = apmStartReqView(request)
  r.vifIdx = vif
  r.channel.freq = 2437
  r.channel.txPower = 17
  r.centerFreq1 = 2437
  r.embedded = 1
  r.beaconInterval = 100
  r.controlPortEthertype = 0x8E88
  r.dtimPeriod = 1
  r.qosSupported = 1
  r.rates = [4'u8, 0x82, 0x84, 0x8B, 0x96, 0, 0, 0, 0, 0, 0, 0, 0]
  r.ssidLength = 4
  for i, value in expectedSsid: r.ssid[i] = value
  r.securityType = secure.uint8
  for i, value in expectedPhrase: r.passphrase[i] = value.uint8
  r.extraIeLength = 8
  r.extraIes[0 .. 7] = [7'u8, 6, 85, 83, 32, 1, 11, 20]
  me.htSupp = 1
  me.psOn = 1
'''

CHECKS = r'''
proc dispatchStart(): cint =
  result = apm_start_req_handler(request)
  if result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(request))
proc dispatchReply(p: pointer) =
  let id = keMsgHdrFromPayload(p).id
  if id == MM_BCN_CHANGE_CFM:
    doAssert mm_bcn_change_cfm_handler(p) == KeMsgConsumed
  elif id == ME_SET_ACTIVE_CFM:
    doAssert me_set_active_cfm_handler_apm(p) == KeMsgConsumed
  elif id == ME_SET_PS_DISABLE_CFM:
    doAssert me_set_ps_disable_cfm_handler_apm(p) == KeMsgConsumed
  elif id == MM_SET_VIF_STATE_CFM:
    doAssert mm_set_vif_state_cfm_handler_apm(p) == KeMsgConsumed
  else:
    doAssert mm_bss_param_setting_handler_apm(p) == KeMsgConsumed
proc ignoredReply(p: pointer) =
  let oldState = state
  let oldRequest = apmStartRequest
  let oldReply = apmStartReply
  let oldHead = keMsgQueueSent.first
  let oldPending = apm.pendingBssParams.first
  let oldCfms = cfms.len
  dispatchReply(p)
  doAssert state == oldState and apmStartRequest == oldRequest
  doAssert apmStartReply == oldReply and keMsgQueueSent.first == oldHead
  doAssert apm.pendingBssParams.first == oldPending and cfms.len == oldCfms
proc drainStartup(failBeacon = false; limit = high(int)) =
  var count = 0
  proc backend(h: ptr Header): bool =
    (h.destId == TASK_MM and h.srcId == TASK_ME and h.id in [MM_SET_IDLE_REQ, MM_SET_PS_MODE_REQ]) or
      (h.destId == TASK_ME and h.srcId == TASK_MM and h.id in [MM_SET_IDLE_CFM, MM_SET_PS_MODE_CFM])
  while keMsgQueueSent.first != nil and (count < limit or backend(keMsgQueueSent.first)):
    if not backend(keMsgQueueSent.first): inc count
    for id in [17'u16, 19, 21, MM_SET_VIF_STATE_CFM, ME_SET_ACTIVE_CFM, ME_SET_PS_DISABLE_CFM, MM_BCN_CHANGE_CFM]:
      let stale = newMessage(id, TASK_APM,
        (if id >= 0xC00: TASK_ME else: TASK_MM), 0)
      ignoredReply(stale)
      ke_msg_free(keMsgHdrFromPayload(stale))
    let header = co_list_pop_front(addr keMsgQueueSent)
    let p = keMsgPayload(header)
    let id = header.id
    if backend(header):
      doAssert meState == MeBusyState
      var status: cint
      if id == MM_SET_IDLE_REQ:
        status = mm_set_idle_req_handler(p)
      elif id == MM_SET_PS_MODE_REQ:
        status = mm_set_ps_mode_req_handler(p)
      elif id == MM_SET_IDLE_CFM:
        status = mm_set_idle_cfm_handler(p)
      else:
        status = mm_set_ps_mode_cfm_handler(p)
      if status == KeMsgConsumed:
        ke_msg_free(header)
      elif status == KeMsgSaved:
        co_list_push_back(addr keMsgQueueSaved, header)
        ke_state_set(TASK_MM, MM_IDLE)
      else:
        doAssert status == KeMsgNoFree
      continue
    if header.destId == TASK_APM:
      if p == apmStartReply:
        doAssert meState == MeIdleState
      let source = header.srcId
      header.srcId = TASK_API
      ignoredReply(p)
      header.srcId = source
      dispatchReply(p)
      ignoredReply(p)
      ke_msg_free(header)
      continue
    if id == 8 and header.destId == TASK_MM:
      # MM state changes can wake removal before APM teardown is complete.
      doAssert not apmPrepareVifRemoval(cast[ptr uint8](p)[])
      co_list_push_back(addr keMsgQueueSaved, header)
    elif id == MM_BCN_CHANGE_REQ:
      doAssert mm_bcn_change_req_handler(p) == KeMsgNoFree
      doAssert lastBeacon == p
      let b = cast[ptr MmBcnChangeReqPayload](p)
      doAssert b.beaconLength == 208 and b.timOffset == 80
      doAssert b.timLength == 6 and b.vifIdx == expectedVif
      copiedBeacon = newSeq[uint8](b.beaconLength.int)
      copyMem(addr copiedBeacon[0], addr b.beaconData[0], b.beaconLength.int)
      mmBeaconChangeConfirm(header, if failBeacon: 1 else: 0)
      ke_msg_free(keMsgHdrFromPayload(p))
    elif id == MM_SET_VIF_STATE_REQ:
      let s = cast[ptr MmSetVifStateReqPayload](p)
      doAssert s.vifIdx == expectedVif
      vifs[expectedVif].state = s.state
      if s.state == 0:
        ke_msg_send_basic_reply(p, MM_SET_VIF_STATE_CFM)
      ke_msg_free(keMsgHdrFromPayload(p))
    else:
      doAssert apmStopActive or (not requestFreed and cfms.len == 0)
      var status = KeMsgConsumed
      if id == ME_SET_ACTIVE_REQ:
        status = me_set_active_req_handler(p)
      elif id == ME_SET_PS_DISABLE_REQ:
        status = me_set_ps_disable_req_handler(p)
      else:
        if id == MM_SET_BASIC_RATES_REQ:
          doAssert cast[ptr MmSetBasicRatesReqPayload](p).band ==
            apmStartReqView(request).channel.band
        ke_msg_send_basic_reply(p, id + 1)
      if status == KeMsgConsumed: ke_msg_free(header)
      elif status == KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, header)
      else: doAssert status == KeMsgNoFree
for vif in 0'u8 .. 1'u8:
  for secure in [false, true]:
    reset(vif, secure)
    let edca = [0xA47'u32, 0xA43, 0x5E432, 0x2F322]
    vifs[vif].edcaRegs = edca
    let startResult = dispatchStart()
    doAssert startResult == KeMsgNoFree, $vif & ":" & $secure & ":" & $cfms & ":" &
      $channelAdds & ":" & $initialized & ":" & $kernelAllocations
    doAssert beaconResets == 1
    doAssert not requestFreed and cfms.len == 0 and apm.connectInfo == request
    doAssert state == ApmActiveState and apm.pendingBssParams.first != nil
    doAssert vifs[vif].edcaRegs == edca, "AP inherited the live EDCA bank"
    let allocationsBefore = kernelAllocations
    failAt = kernelAllocations + 1
    drainStartup()
    doAssert kernelAllocations == allocationsBefore
    doAssert requestFreed and allocated.len == 6 and cfms.len == 1
    doAssert cfms[0] == ApmStartCfmPayload(status: 0, vifIdx: vif,
                                          channelContextIndex: 2, staIdx: vif + 5)
    doAssert apm.connectInfo == nil and state == ApmIdleState and vifs[vif].state == 1
    doAssert copiedBeacon[86 .. 93] == @[7'u8, 6, 85, 83, 32, 1, 11, 20]
    doAssert copiedBeacon[94] == 86 and copiedBeacon[^1] == 199
    doAssert beaconAllocs == 1 and beaconFrees == 1
    doAssert initialized == secure.int and timers.len == 1
    doAssert mm_bcn_change_cfm_handler(nil) == KeMsgConsumed
    doAssert cfms.len == 1
    if apm.hostapdCtx != nil:
      apm.hostapdCtx = nil

for vif in 0'u8 .. 1:
  for secure in [false, true]:
    reset(vif, secure)
    doAssert dispatchStart() == KeMsgNoFree
    drainStartup(true)
    doAssert requestFreed and allocated.len == 0
    doAssert cfms.len == 1 and cfms[0].status != 0
    doAssert apm.connectInfo == nil and state == ApmIdleState
    doAssert vifs[vif].state == 0 and timers.len == 0
    doAssert channelDeletes == 1 and apm.hostapdCtx == nil

for failure in 1 .. 20:
  reset(0)
  failAt = failure
  doAssert dispatchStart() == KeMsgConsumed
  doAssert requestFreed and allocated.len == 0 and keMsgQueueSent.first == nil
  doAssert apm.connectInfo == nil and apm.hostapdCtx == nil and state == ApmIdleState
  doAssert apm.embeddedEnabled == 0 and apm.cryptoType == 0
  doAssert apm.securityIe == default(typeof(apm.securityIe))
  if failure == 1: doAssert cfms.len == 0
  else: doAssert cfms.len == 1 and cfms[0].status != 0
  doAssert beaconFrees <= beaconAllocs and deinitialized <= initialized

for vif in 0'u8 .. 1:
  reset(vif)
  vifs[vif xor 1].vifType = VIF_TYPE_AP
  vifs[vif xor 1].state = 1
  doAssert dispatchStart() == KeMsgConsumed
  doAssert requestFreed and allocated.len == 0
  doAssert cfms.len == 1 and cfms[0].status == 8
  doAssert channelAdds == 0 and beaconAllocs == 0
  doAssert vifs[vif xor 1].state == 1

reset(0)
poolBusy = true
doAssert dispatchStart() == KeMsgConsumed
doAssert cfms.len == 1 and cfms[0].status == 8
doAssert channelAdds == 0 and beaconResets == 0 and allocated.len == 0

for malformed in 0 ..< 17:
  reset(1)
  let r = apmStartReqView(request)
  case malformed
  of 0: keMsgHdrFromPayload(request).paramLen = 52
  of 1: r.vifIdx = 255
  of 2: r.ssidLength = 33
  of 3: r.rates[0] = 13
  of 4: r.extraIeLength = 65
  of 5: r.extraIes[1] = 20
  of 6: r.passphrase = default(typeof(r.passphrase))
  of 7: r.passphrase = [1'u8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
  of 8: channelStatus = 1
  of 9: channelMissing = true
  of 10: beaconAllocationFails = true
  of 11: initFails = true
  of 12: r.securityType = 3
  of 13:
    r.extraIeLength = 16
    r.extraIes[8 .. 15] = r.extraIes[0 .. 7]
  of 14: r.centerFreq1 = 2442
  of 15: r.centerFreq2 = 2452
  else: r.securityType = 255
  doAssert dispatchStart() == KeMsgConsumed
  doAssert requestFreed and allocated.len == 0 and keMsgQueueSent.first == nil
  doAssert apm.connectInfo == nil and apm.hostapdCtx == nil and state == ApmIdleState
  doAssert cfms.len == 1 and cfms[0].status != 0
  if malformed in [9, 14, 15]:
    doAssert channelAdds == 0 and beaconResets == 0 and beaconAllocs == 0,
      "an invalid channel reached AP setup before rejection"

for number in 1 .. 11:
  reset(0, false)
  expectedFreq = (2407 + 5 * number).uint16
  let r = apmStartReqView(request)
  r.channel.freq = expectedFreq
  r.centerFreq1 = expectedFreq.uint32
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup()
  doAssert cfms.len == 1 and cfms[0].status == 0 and channelAdds == 1
  doAssert vifs[0].state == 1 and vifs[0].channelFreqPair == expectedFreq.uint32

reset(1)
apmStartReqView(request).securityType = 2
doAssert dispatchStart() == KeMsgNoFree
drainStartup()
doAssert cfms.len == 1 and cfms[0].status == 0
doAssert initialized == 1 and vifs[1].state == 1
apm.hostapdCtx = nil

reset(1)
expectedPhrase.setLen(0)
for i in 0 ..< 64: expectedPhrase.add('x')
let r64 = apmStartReqView(request)
for i in 0 ..< 64: r64.passphrase[i] = 'x'.uint8
doAssert dispatchStart() == KeMsgNoFree
drainStartup()
doAssert cfms[0].status == 0 and allocated.len == 6
apm.hostapdCtx = nil

for busy in [1'u16, 2]:
  reset(0)
  state = busy
  doAssert dispatchStart() == KeMsgConsumed
  doAssert cfms.len == 1 and cfms[0].status == 8
  doAssert channelAdds == 0 and allocated.len == 0

# Cancel with either the request or its reply queued at every startup stage.
# The currently dispatched reply is never owned by the cancellation routine.
for stage in 0 ..< 6:
  for produced in [0, 1]:
    for saved in [false, true]:
      reset(0)
      doAssert dispatchStart() == KeMsgNoFree
      drainStartup(limit = stage * 2 + produced)
      doAssert apm.connectInfo == request and keMsgQueueSent.first != nil
      if saved:
        co_list_push_back(addr keMsgQueueSaved, co_list_pop_front(addr keMsgQueueSent))
      let unrelated = newMessage(0x777, TASK_MM, TASK_API, 0)
      ke_msg_send(unrelated)
      apm_start_cfm(cast[pointer](1'u))
      doAssert not requestFreed and apmRollbackActive and cfms.len == 0
      doAssert keMsgQueueSaved.first == nil
      doAssert keMsgPayload(co_list_pop_front(addr keMsgQueueSent)) == unrelated
      ke_msg_free(keMsgHdrFromPayload(unrelated))
      drainStartup()
      doAssert requestFreed and state == ApmIdleState and cfms.len == 1
      doAssert cfms[0].status == 1 and allocated.len == 0
      doAssert keMsgQueueSent.first == nil
      doAssert apmStartRequest == nil and apmStartReply == nil
      for reply in apmStartReplyPool: doAssert reply == nil

# A correlated reply in the wrong state is consumed before abort cleanup, so
# the dispatcher remains its sole owner and does not double free it.
for stage in 0 ..< 6:
  reset(1)
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup(limit = stage * 2 + 1)
  let header = co_list_pop_front(addr keMsgQueueSent)
  doAssert keMsgPayload(header) == apmStartReply
  state = 7
  dispatchReply(keMsgPayload(header))
  doAssert apmRollbackActive and cfms.len == 0 and not requestFreed
  ke_msg_free(header)
  drainStartup()
  doAssert state == ApmIdleState and cfms.len == 1 and cfms[0].status == 1
  doAssert requestFreed and allocated.len == 0
  doAssert apmStartReply == nil and apmStartRequest == nil
  doAssert keMsgQueueSent.first == nil
'''


def program_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    names = ["ApFrameExtras", "ApmStartInfoView", "ApmStartChannelView", "ApmStartReqView",
             "ApmStartCfmPayload", "ApmStopReqPayload", "MmBcnChangeReqPayload", "MmBcnChangeCfmPayload", "MmSetVifStateReqPayload",
             "MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "ScanChannelEntry",
             "ChanCtxtDefView", "RateSetView", "WpaBeaconRegisterParamView", "VifApConfigOverlay",
             "StatusCfmPayload", "MmSetIdleReqPayload", "MmSetPsModeReqPayload", "MeConfigReqPayload"]
    types = "type\n"
    for name in names:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    types += "const\n"
    for name in ["ApmStartCfmPayload", "MmSetVifStateReqPayload", "MeSetPsDisableReqPayload",
                 "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload", "MmSetBeaconIntReqPayload",
                 "MeSetActiveReqPayload", "StatusCfmPayload", "MmSetIdleReqPayload",
                 "MmSetPsModeReqPayload", "MeConfigReqPayload"]:
        types += f"  {name}Size = sizeof({name}).uint32\n"
    helpers = ""
    for name in ["apmStartReqView", "apmStopReqView", "apmStartInfoView", "rateSetAt", "mmSetIdleReqView",
                 "mmSetPsModeReqView", "meConfigReqView"]:
        match = re.search(r"(?ms)^template " + name + r"\b.*?(?=^template |^proc |\Z)", layout)
        assert match, name
        helpers += match.group(0)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    bodies = ""
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    bodies += "proc apm_start_cfm*(param: pointer) {.exportc, cdecl.}\n"
    bodies += "proc apm_send_next_bss_param*(param: pointer) {.exportc, cdecl.}\n"
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    bodies += procedure(kernel, "ke_queue_extract")
    for name in ["apmStartPendingForVif", "apmPrepareRollbackBuffers", "apmPrepareStartReplies", "apmSendStartRequest",
                 "apmTakeStartReply", "apmConsumeStartReply", "apmStartMessageMatches",
                 "apmCancelStartExchange"]:
        bodies += procedure(scan, name)
    for name in ["ke_msg_alloc_reply", "ke_msg_send_basic_reply", "mmBeaconChangeConfirm"]:
        bodies += procedure(kernel, name)
    bodies += "\nwhen not declared(ke_reschedule_saved_messages):\n  proc ke_reschedule_saved_messages(task: uint8): bool {.discardable.} = false\n"
    for name in ["meControlMessageMatches", "meCancelQueuedPayload",
                 "meControlReset", "meTakeControlReply", "meReserveControl", "meForwardControl",
                 "meBeginControl", "meCompleteControl"]:
        bodies += procedure(handlers, name)
    bodies += ("\nwhen not declared(ke_msg_forward_and_change_id):\n"
               + "\n".join("  " + line for line in
                            fw_procedure(kernel, "ke_msg_forward_and_change_id").splitlines()) + "\n")
    bodies += ps_machine_source("psAnswer", record=False)
    for name in ["apm_embedded_enabled", "me_rate_translate", "me_get_basic_rates", "me_add_chan_ctx",
                 "meBeaconFrameLength", "apmFreeStartBuffers", "apmFinishStop", "apmContinueStartRollback", "apmBeginStartRollback", "apmResumeHaltRollback",
                 "apmVifNeedsStop", "apmBeginStop", "apmPrepareVifRemoval", "apm_stop",
                 "apm_start_cfm", "apm_send_next_bss_param",
                 "apm_set_bss_param", "apm_bcn_set"]:
        bodies += procedure(scan, name)
    for name in ["readApFrameExtras", "appendApFrameExtras"]:
        bodies += procedure(scan, name)
    bodies += procedure(handlers, "apm_start_req_handler")
    for name in ["apm_stop_req_handler", "apmVifRunning", "apm_sta_connect_timeout_ind_handler"]:
        bodies += procedure(handlers, name)
    for name in ["me_config_req_handler", "mm_set_idle_req_handler", "mm_set_idle_cfm_handler", "mm_set_ps_mode_req_handler",
                 "mm_set_ps_mode_cfm_handler", "me_set_active_req_handler", "me_set_ps_disable_req_handler", "mm_bcn_change_req_handler",
                 "mm_bcn_change_cfm_handler", "mm_set_vif_state_cfm_handler_apm", "mm_bss_param_setting_handler_apm",
                 "me_set_active_cfm_handler_apm", "me_set_ps_disable_cfm_handler_apm"]:
        bodies += procedure(handlers, name)
    platform, reset = PLATFORM.split("proc reset(", 1)
    return types + helpers + platform + AP_EXTRAS_PLATFORM + bodies + "proc reset(" + reset


def run_program(tmp_path: Path, build: str, checks: str, *, lease: bool = False) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    program = tmp_path / "ap_start.nim"
    program.write_text(program_source() + checks)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if lease:
        command += ["-d:bl808WifiMbedTlsSha1Lease"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_start_transaction(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, CHECKS)


def test_ap_key_setup_failure_rolls_back_even_if_vendor_returns_context(tmp_path: Path) -> None:
    run_program(tmp_path, "checked", CHECKS + r'''
reset(1)
keySetupFails = true
doAssert dispatchStart() == KeMsgConsumed
doAssert initialized == 1 and deinitialized == 1 and apm.hostapdCtx == nil
doAssert not keySetupActive and beaconAllocs == 0 and channelDeletes == 1
doAssert state == ApmIdleState and requestFreed and allocated.len == 0
doAssert cfms.len == 1 and cfms[0].status == 1

reset(1)
keySetupFails = false
doAssert dispatchStart() == KeMsgNoFree and not keySetupActive
drainStartup()
doAssert cfms.len == 1 and cfms[0].status == 0 and requestFreed
''', lease=True)
