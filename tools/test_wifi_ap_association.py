"""Exercise AP association wire parsing, ME handoff, and WPA context ownership."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_ap_sta_init import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_AP = 2'u8
  TASK_ME = 3'u16
  TASK_APM = 5'u16
  TASK_API = 9'u16
  TASK_NONE = 255'u8
  ME_STA_ADD_REQ = 0xC05'u16
  ME_STA_ADD_CFM = 0xC06'u16
  APM_STA_ADD_IND = 0x1404'u16
  StaTxPolicyUpdateTxPower = 0x10'u8
type
  Header = object
    next: ptr Header
    id, destId, srcId: uint16
    paramLen: uint32
  CoList = object
    first, last: ptr Header
  Message = object
    header: Header
    body: array[128, uint8]
  Station = object
    macAddr: array[6, uint8]
    supportedRates: array[13, uint8]
    vhtCaps: array[32, uint8]
    capabilityFlags, assocInfoWord0, assocInfoWord1: uint32
    txPolicyUpdateFlags: array[4, uint8]
    controlPortState, psState, uapsdBitmap, instNbr, infoIdx, extFlag, paramFlag, valid: uint8
    rateWord, aid: uint16
    apmWpaContext: pointer
  Ssid = object
    ssidLen: uint8
    ssidData: array[32, uint8]
  Vif = object
    vifType, state: uint8
    basicRates: array[13, uint8]
    ssid: Ssid
    ap: tuple[maxAssocRate: uint16]
    apStartBeaconInterval: uint16
    key: tuple[flags: uint32]
    ht: VifHtCapabilitiesOverlay
  Slot = object
    macAddr: array[6, uint8]
    staHandle: pointer
    active, staIdx: uint8
  Tx = object
    callback, argument: pointer
    subtype: uint16
    status: uint
var
  input: array[1200, uint8]
  inputHeader: Header
  inputLen: int
  messages: array[16, Message]
  allocated, freed, joined, associated, removed, delivered, registrations, unregistered: int
  registrationStatus: uint8
  sent: seq[uint16]
  allocationsFail, joinFails, joinHasContext, reenterRemove: bool
  stations: array[7, Station]
  vifs: array[2, Vif]
  slots: array[5, Slot]
  apm: tuple[hostapdCtx: pointer, staCount, maxSta: uint8]
  me: tuple[htSupp: uint8]
  callbacks: WpaCallbacksView
  apmPendingAssociations: array[5, ApmPendingAssociation]
  apmPendingCancelMask: uint8
  apmStoppingVifs, startupMask: uint8
  rxVifEpochs: array[MAX_VIFS, uint32]
  wpa_cbs: pointer
  tx: Tx
  expectedIe: seq[uint8]
  nimFwDbgApmStaAddNoSlot, nimFwDbgApmStaAddNoSlotSta: uint32
  assigned: uint8
  context: pointer
  eapol: array[4, uint8]
  hostIndicationHook, joinHook, removeHook, allocateHook: proc()
  keMsgQueueSent, keMsgQueueSaved, keTimerQueue: CoList
  keSavedReschedTask = TASK_NONE
  keSavedReschedMask: uint16
  keSavedReschedRemaining: array[9, uint32]
  flushing: bool
  clearedEvents: uint32
proc aidListDelete(macAddr: pointer) {.exportc: "aid_list_delete", cdecl, noinline.}
proc irqSave(): uint32 = 8
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc irqRestore(saved: uint32) = doAssert saved == 8
proc apmStartPendingForVif(vif: uint8): bool = (startupMask and (1'u8 shl vif)) != 0
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc c_memset(dst: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(dst, n.int)
  dst
proc c_memcmp(a, b: pointer; n: csize_t): cint = cmpMem(a, b, n.int).cint
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  if p == addr input[0]: return addr inputHeader
  for msg in messages.mitems:
    if p == addr msg.body[0]: return addr msg.header
  doAssert false
proc ke_msg_alloc(id, dst, src: uint16; length: uint32): pointer =
  if allocationsFail:
    if allocateHook != nil:
      let callback = allocateHook
      allocateHook = nil
      callback()
    return nil
  doAssert allocated < messages.len and length <= 128
  let i = allocated
  inc allocated
  messages[i].header = Header(id: id, destId: dst, srcId: src, paramLen: length)
  for b in messages[i].body.mitems: b = 0xA9
  result = addr messages[i].body[0]
  if allocateHook != nil:
    let callback = allocateHook
    allocateHook = nil
    callback()
proc ke_msg_send(p: pointer) =
  let id = keMsgHdrFromPayload(p).id
  sent.add(id)
  if id == APM_STA_ADD_IND and hostIndicationHook != nil:
    let callback = hostIndicationHook
    hostIndicationHook = nil
    callback()
proc ke_msg_free(p: pointer) =
  if flushing:
    for pending in apmPendingAssociations:
      doAssert pending.request == nil and pending.confirmation == nil,
        "flush freed a message before cancelling its pending association"
  var found = false
  for msg in messages.mitems:
    if p == addr msg.header: found = true
  doAssert found
  inc freed
proc co_list_pop_front(queue: ptr CoList): ptr Header =
  result = queue.first
  if result != nil:
    queue.first = result.next
    if queue.first == nil: queue.last = nil
    result.next = nil
proc ke_evt_clear(mask: uint32) = clearedEvents = mask
proc mmConfigCancelIdle() = discard
proc mm_bcn_flush_updates(notify: bool) = doAssert not notify
proc psCancel() = discard
proc meControlReset() = discard
proc smCleanupCancel() = discard
proc smBssCancel() = discard
proc chanSwitchReset() = discard
proc scanRelease(failed = false) = discard
proc smActivationCancel() = discard
proc smRspTimerReset() = discard
template smSaQueryResetScope() = discard
proc keTimerCancelMutations(id = 0'u16; task = 0'u8; all = false) = discard
proc smDeferredCancel() = discard
proc smAbandon() = discard
proc staInfoForIdx(i: uint8): ptr Station = addr stations[i]
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifApProbeSsid(v: ptr Vif): ptr Ssid = addr v.ssid
proc vifApConfig(v: ptr Vif): ptr tuple[maxAssocRate: uint16] = addr v.ap
proc vifKeyPointers(v: ptr Vif): ptr tuple[flags: uint32] = addr v.key
proc vifHtCapabilities(v: ptr Vif): ptr VifHtCapabilitiesOverlay = addr v.ht
proc apmStaSlot(i: uint): ptr Slot = addr slots[i]
proc apmEnvView(): ptr typeof(apm) = addr apm
proc meEnvView(): ptr typeof(me) = addr me
proc wpaCallbacks(): ptr WpaCallbacksView = addr callbacks
proc me_set_sta_ht_vht_param(sta, caps: pointer) = discard
proc meTryInitRate(sta: pointer): bool = true
proc me_init_rate(sta: pointer) = discard meTryInitRate(sta)
proc staDeleteEpoch(index: uint8): uint32 = 0
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool = epoch == 0
proc blOpsFunc(offset: int): pointer = nil
proc mm_sta_add(p: pointer; index, hw: ptr uint8): uint8 =
  inc registrations
  if registrationStatus != 0: return registrationStatus
  let req = cast[ptr MmStaAddReqPayload](p)
  index[] = assigned
  hw[] = assigned + 8
  stations[assigned].macAddr = req.bssid
  stations[assigned].instNbr = req.vifIdx
  stations[assigned].valid = 1
  stations[assigned].infoIdx = assigned
  0
proc mm_sta_del(index: uint8) =
  inc unregistered
  stations[index].valid = 0
proc apm_send_mlme(vif: pointer; subtype: uint16; mac, cb, arg, extra: pointer) =
  doAssert vif == addr vifs[input[8]]
  doAssert cmpMem(mac, addr input[42], 6) == 0
  tx = Tx(callback: cb, argument: arg, subtype: subtype, status: cast[uint](extra))
proc join(outContext: ptr pointer; mac, ie: pointer; length: uint8): bool {.cdecl.} =
  inc joined
  doAssert cmpMem(mac, addr input[42], 6) == 0
  doAssert length.int == expectedIe.len
  doAssert cmpMem(ie, addr expectedIe[0], expectedIe.len) == 0
  if joinHasContext: outContext[] = context
  if joinHook != nil:
    let callback = joinHook
    joinHook = nil
    callback()
  not joinFails
proc notifyAssociated(ctx: pointer; index: uint8) {.cdecl.} =
  doAssert ctx == context and index == assigned
  doAssert stations[index].apmWpaContext == context
  inc associated
proc remove(ctx: pointer): bool {.cdecl.} =
  doAssert ctx == context
  inc removed
  if reenterRemove: aidListDelete(addr input[42])
  if removeHook != nil:
    let callback = removeHook
    removeHook = nil
    callback()
  true
proc receive(hapd, ctx, data: pointer; length: csize_t): bool {.cdecl.} =
  doAssert hapd == apm.hostapdCtx and ctx == context
  doAssert data == (addr eapol[0]) and length == 4
  inc delivered
  true
proc put16(offset: int; value: uint16) =
  input[offset] = (value and 255).uint8
  input[offset + 1] = (value shr 8).uint8
proc addIe(id: uint8; data: openArray[uint8]) =
  input[inputLen] = id
  input[inputLen + 1] = data.len.uint8
  for i, b in data: input[inputLen + 2 + i] = b
  inputLen += data.len + 2
proc reset(secure: bool; reassoc = false; vif = 0'u8) =
  input = default(typeof(input))
  messages = default(typeof(messages))
  stations = default(typeof(stations))
  slots = default(typeof(slots))
  apmPendingAssociations = default(typeof(apmPendingAssociations))
  apmPendingCancelMask = 0
  apmStoppingVifs = 0
  startupMask = 0
  vifs = default(typeof(vifs))
  allocated = 0
  freed = 0
  joined = 0
  associated = 0
  removed = 0
  delivered = 0
  registrations = 0
  unregistered = 0
  registrationStatus = 0
  hostIndicationHook = nil
  joinHook = nil
  removeHook = nil
  allocateHook = nil
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  keTimerQueue = default(CoList)
  flushing = false
  clearedEvents = 0
  sent.setLen(0)
  tx = default(Tx)
  assigned = 3
  context = cast[pointer](0x12345678)
  joinFails = false
  joinHasContext = true
  allocationsFail = false
  reenterRemove = false
  input[8] = vif
  input[42..47] = [2'u8, 3, 4, 5, 6, 7]
  put16(58, 10)
  inputLen = if reassoc: 66 else: 60
  vifs[vif].vifType = 2
  vifs[vif].state = 1
  vifs[vif].ap.maxAssocRate = 100
  vifs[vif].ssid.ssidLen = 3
  vifs[vif].ssid.ssidData[0..2] = [97'u8, 98, 99]
  vifs[vif].basicRates = [4'u8, 0x82, 0x84, 0x8B, 0x96, 0, 0, 0, 0, 0, 0, 0, 0]
  vifs[vif].key.flags = 1
  vifs[vif].apStartBeaconInterval = 0x8E88
  me.htSupp = 1
  apm.hostapdCtx = if secure: cast[pointer](0x87654321) else: nil
  apm.staCount = 0
  apm.maxSta = 5
  callbacks = default(WpaCallbacksView)
  callbacks.apJoin = cast[pointer](join)
  callbacks.staAdd = cast[pointer](notifyAssociated)
  callbacks.disconnect = cast[pointer](remove)
  callbacks.apEapolRx = cast[pointer](receive)
  wpa_cbs = addr callbacks
proc finish() =
  put16(0, (inputLen - 32).uint16)
  inputHeader = Header(paramLen: inputLen.uint32)
proc basicIes(secure: bool; ht = true) =
  addIe(0, [97'u8, 98, 99])
  addIe(1, [2'u8, 4])
  addIe(50, [11'u8, 22])
  if ht:
    var caps: array[26, uint8]
    for i in 0 ..< caps.len: caps[i] = (i + 1).uint8
    addIe(45, caps)
    addIe(221, [0'u8, 0x50, 0xF2, 2, 0, 1, 0x6F])
  if secure:
    expectedIe = @[48'u8, 4, 1, 0, 5, 6]
    addIe(48, expectedIe.toOpenArray(2, 5))
proc confirmTx(success: bool) =
  doAssert tx.callback != nil
  cast[proc(p: pointer; status: uint32) {.cdecl.}](tx.callback)(
    tx.argument, if success: 0x800000'u32 else: 0'u32)
'''

CHECKS = r'''
for secure in [false, true]:
  for reassoc in [false, true]:
    for vif in 0'u8 .. 1'u8:
      reset(secure, reassoc, vif)
      basicIes(secure)
      finish()
      apm_assoc_req_handler(addr input[0], reassoc.uint32)
      doAssert tx.status == 0 and apm.staCount == 1
      doAssert tx.subtype == (if reassoc: 0x30'u16 else: 0x10'u16)
      doAssert allocated == 1 and sent.len == 0
      doAssert messages[0].header == Header(id: ME_STA_ADD_REQ, destId: TASK_ME, srcId: TASK_APM, paramLen: 88)
      let req = cast[ptr ApmAssocStaAddIndPayload](tx.argument)
      doAssert req.aid == 1 and req.rateCount == 4
      doAssert req.rateBytes[0..3] == @[0x82'u8, 0x84, 0x8B, 0x96]
      doAssert req.flags == 3 and req.uapsdQueues == 15 and req.maxServicePeriod == 6
      doAssert req.htCapabilities[2] == 3 and req.htCapabilities[3] == 4
      doAssert req.htCapabilities[24..27] == @[22'u8, 23, 24, 25]
      doAssert slots[0].staHandle == (if secure: context else: nil)
      doAssert slots[0].staHandle != tx.argument
      confirmTx(true)
      doAssert sent == @[ME_STA_ADD_REQ]
      me_sta_add_req_handler(tx.argument)
      apm_sta_add_cfm_handler(addr messages[1].body[0])
      doAssert sent == @[ME_STA_ADD_REQ, ME_STA_ADD_CFM, APM_STA_ADD_IND]
      doAssert messages[2].header.paramLen == 28
      doAssert stations[assigned].aid == 1 and stations[assigned].instNbr == vif
      doAssert associated == secure.int and joined == secure.int
      apm_handle_eapol_input(assigned, addr eapol[0], 4)
      doAssert delivered == secure.int
      reenterRemove = true
      aidListDelete(addr input[42])
      doAssert removed == secure.int and apm.staCount == 0
      doAssert slots[0].active == 0 and stations[assigned].apmWpaContext == nil
      apm_handle_eapol_input(assigned, addr eapol[0], 4)
      apm_handle_eapol_input(255, addr eapol[0], 4)
      doAssert delivered == secure.int

for failure in 0 ..< 12:
  reset(true)
  basicIes(true)
  case failure
  of 0: input[62] = 100 # SSID mismatch
  of 1: put16(58, 101) # listen interval
  of 2: input[66] = 255 # IE length runs past frame
  of 3: inputLen -= 1 # truncated security IE
  of 4: joinFails = true
  of 5: joinHasContext = false
  of 6: callbacks.apJoin = nil
  of 7: apm.maxSta = 0
  of 8: vifs[0].basicRates[1] = 0xEC # missing basic rate
  of 9: input[61] = 0 # IE list becomes malformed
  of 10: callbacks.disconnect = nil
  else: wpa_cbs = nil
  finish()
  apm_assoc_req_handler(addr input[0])
  doAssert tx.status != 0 and apm.staCount == 0
  confirmTx(true)
  doAssert sent.len == 0 and freed == 1
  if failure == 4: doAssert removed == 1

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
confirmTx(false)
doAssert removed == 1 and apm.staCount == 0 and freed == 1 and sent.len == 0
reset(false)
basicIes(false)
finish()
allocationsFail = true
apm_assoc_req_handler(addr input[0])
doAssert allocated == 0 and tx.callback == nil
reset(false)
basicIes(false)
finish()
inputHeader.paramLen -= 1
apm_assoc_req_handler(addr input[0])
doAssert allocated == 0

# Large, valid extended-rate elements never write into the HT request block.
reset(false)
addIe(0, [97'u8, 98, 99])
addIe(1, [2'u8, 4, 11, 22])
var manyRates: array[255, uint8]
for rate in manyRates.mitems: rate = 2
addIe(50, manyRates)
finish()
apm_assoc_req_handler(addr input[0])
doAssert tx.status == 0
let large = cast[ptr ApmAssocStaAddIndPayload](tx.argument)
doAssert large.rateCount == 4 and large.htCapabilities == default(typeof(large.htCapabilities))
confirmTx(false)
doAssert apm.staCount == 0

reset(true)
basicIes(true)
finish()
let fullLength = inputLen
for cut in 60 ..< fullLength:
  reset(true)
  basicIes(true)
  inputLen = cut
  finish()
  apm_assoc_req_handler(addr input[0])
  doAssert joined == 0 and apm.staCount == 0
  if tx.callback != nil:
    doAssert tx.status != 0
    confirmTx(true)
reset(false)
basicIes(false)
finish()
for slot in slots.mitems:
  slot.active = 1
  slot.macAddr = [2'u8, 9, 9, 9, 9, 9]
apm_assoc_req_handler(addr input[0])
doAssert tx.status == 17 and joined == 0
confirmTx(true)
reset(false)
basicIes(false)
finish()
slots[0].active = 1
slots[0].macAddr = [2'u8, 3, 4, 5, 6, 7]
apm_assoc_req_handler(addr input[0])
doAssert allocated == 0
'''

PENDING_CHECKS = r'''
# An unacknowledged request owns its WPA context until cancellation/completion.
reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
let oldTx = tx
aidListDelete(addr input[42])
context = cast[pointer](0x23456789)
apm_assoc_req_handler(addr input[0])
let replacementTx = tx
cast[proc(p: pointer; status: uint32) {.cdecl.}](oldTx.callback)(oldTx.argument, 0)
doAssert removed == 1 and apm.staCount == 1 and slots[0].staHandle == context,
  "stale TX failure deleted replacement WPA slot"
tx = replacementTx
confirmTx(false)
doAssert removed == 2 and apm.staCount == 0

for noConfirmation in [false, true]:
  reset(true)
  basicIes(true)
  finish()
  apm_assoc_req_handler(addr input[0])
  confirmTx(true)
  if noConfirmation: allocationsFail = true
  else: registrationStatus = 1
  me_sta_add_req_handler(tx.argument)
  if not noConfirmation:
    apm_sta_add_cfm_handler(addr messages[1].body[0])
  doAssert removed == 1 and apm.staCount == 0,
    "failed ME registration leaked a pending WPA context"

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
let queuedRequest = tx.argument
confirmTx(true)
aidListDelete(addr input[42])
context = cast[pointer](0x23456789)
apm_assoc_req_handler(addr input[0])
me_sta_add_req_handler(queuedRequest)
doAssert registrations == 0 and associated == 0 and apm.staCount == 1,
  "cancelled queued request registered a stale station"
confirmTx(false)

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
confirmTx(true)
let cancelledDuringAllocation = tx.argument
allocateHook = proc() = apmCancelPendingForVif(0)
me_sta_add_req_handler(cancelledDuringAllocation)
doAssert registrations == 0 and apm.staCount == 0 and removed == 1
doAssert apmPendingAssociations[0].confirmation == nil
doAssert sent[^1] == ME_STA_ADD_CFM

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
confirmTx(true)
let replacedDuringFailedAllocation = tx.argument
allocationsFail = true
allocateHook = proc() =
  aidListDelete(addr input[42])
  allocationsFail = false
  context = cast[pointer](0x23456789)
  apm_assoc_req_handler(addr input[0])
me_sta_add_req_handler(replacedDuringFailedAllocation)
doAssert registrations == 0 and apm.staCount == 1 and removed == 1
doAssert slots[0].staHandle == context
doAssert apmPendingAssociations[0].request == tx.argument
confirmTx(false)

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
let registeredRequest = tx.argument
confirmTx(true)
me_sta_add_req_handler(registeredRequest)
let lateConfirmation = addr messages[1].body[0]
aidListDelete(addr input[42])
doAssert unregistered == 1 and stations[assigned].valid == 0
context = cast[pointer](0x23456789)
apm_assoc_req_handler(addr input[0])
apm_sta_add_cfm_handler(lateConfirmation)
doAssert associated == 0 and apm.staCount == 1 and slots[0].staHandle == context
confirmTx(false)

reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
confirmTx(true)
me_sta_add_req_handler(tx.argument)
allocationsFail = true
apm_sta_add_cfm_handler(addr messages[1].body[0])
doAssert associated == 0 and unregistered == 1 and removed == 1 and apm.staCount == 0

proc replaceFromHostNotification() =
  mm_sta_del(assigned)
  aidListDelete(addr input[42])
  context = cast[pointer](0x23456789)
  apm_assoc_req_handler(addr input[0])
reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
confirmTx(true)
me_sta_add_req_handler(tx.argument)
hostIndicationHook = replaceFromHostNotification
apm_sta_add_cfm_handler(addr messages[1].body[0])
doAssert associated == 0 and apm.staCount == 1 and slots[0].staHandle == context
confirmTx(false)

proc occupySelectedSlot() =
  slots[0].active = 1
  slots[0].macAddr = [2'u8, 9, 9, 9, 9, 9]
  apm.staCount = 1
reset(true)
basicIes(true)
finish()
joinHook = occupySelectedSlot
apm_assoc_req_handler(addr input[0])
doAssert tx.status == 17 and removed == 1 and apm.staCount == 1
doAssert slots[0].macAddr == [2'u8, 9, 9, 9, 9, 9]
confirmTx(true)

# The confirmation queue need not follow request order to identify its owner.
reset(false)
basicIes(false)
finish()
var requests: array[5, pointer]
for peer in 0 ..< 5:
  input[43] = peer.uint8
  apm_assoc_req_handler(addr input[0])
  requests[peer] = tx.argument
  confirmTx(true)
doAssert apm.staCount == 5
for peer in 0 ..< 5:
  assigned = peer.uint8
  me_sta_add_req_handler(requests[peer])
for peer in countdown(4, 0):
  apm_sta_add_cfm_handler(addr messages[5 + peer].body[0])
for peer in 0 ..< 5:
  doAssert slots[peer].staIdx == peer.uint8 and stations[peer].valid == 1
  doAssert apmPendingAssociations[peer].request == nil and apmPendingAssociations[peer].confirmation == nil

reset(true)
basicIes(true)
finish()
apmPendingAssociations[0].generation = 0xFFFFFFFE'u32
apm_assoc_req_handler(addr input[0])
let stoppedRequest = tx
apmCancelPendingForVif(0)
doAssert removed == 1 and apm.staCount == 0
let beforeStoppedAssociation = allocated
apm_assoc_req_handler(addr input[0])
doAssert allocated == beforeStoppedAssociation
cast[proc(p: pointer; status: uint32) {.cdecl.}](stoppedRequest.callback)(stoppedRequest.argument, 0x800000)
doAssert registrations == 0 and sent.len == 0

proc associateOtherVifFromRemove() =
  input[8] = 1
  input[43] = 9
  vifs[1] = vifs[0]
  context = cast[pointer](0x23456789)
  apm_assoc_req_handler(addr input[0])
reset(true)
basicIes(true)
finish()
apm_assoc_req_handler(addr input[0])
let cancelledVifRequest = tx
removeHook = associateOtherVifFromRemove
apmCancelPendingForVif(0)
doAssert apm.staCount == 1 and slots[0].staHandle == context
doAssert apmPendingAssociations[0].request == tx.argument,
  "cancellation erased a replacement association on another VIF"
confirmTx(false)
doAssert apm.staCount == 0 and removed == 2
cast[proc(p: pointer; status: uint32) {.cdecl.}](cancelledVifRequest.callback)(cancelledVifRequest.argument, 0)

proc stopApDuringJoin() = apmCancelPendingForVif(0)
reset(true)
basicIes(true)
finish()
joinHook = stopApDuringJoin
apm_assoc_req_handler(addr input[0])
doAssert apm.staCount == 0 and removed == 1 and freed == 1 and tx.callback == nil,
  "a join callback committed an association after stopping the AP"

reset(true)
basicIes(true)
finish()
joinHook = occupySelectedSlot
removeHook = stopApDuringJoin
apm_assoc_req_handler(addr input[0])
doAssert apm.staCount == 1 and removed == 1 and freed == 1 and tx.callback == nil,
  "rejected-context cleanup transmitted a response after stopping the AP"

# Flush both sent and saved messages only after every association is cancelled.
reset(false)
basicIes(false)
finish()
for peer in 0 ..< 2:
  vifs[peer] = vifs[0]
  input[8] = peer.uint8
  input[43] = peer.uint8
  assigned = peer.uint8
  apm_assoc_req_handler(addr input[0])
  confirmTx(true)
  me_sta_add_req_handler(tx.argument)
let firstCfm = addr messages[1].header
let secondCfm = addr messages[3].header
firstCfm.next = secondCfm
keMsgQueueSent = CoList(first: firstCfm, last: secondCfm)
input[43] = 2
apm_assoc_req_handler(addr input[0])
confirmTx(true)
let queuedHeader = keMsgHdrFromPayload(tx.argument)
keMsgQueueSaved = CoList(first: queuedHeader, last: queuedHeader)
input[43] = 3
apm_assoc_req_handler(addr input[0])
let awaitingTx = tx
flushing = true
ke_flush()
flushing = false
doAssert apm.staCount == 0 and unregistered == 2 and freed == 3
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
doAssert apmPendingCancelMask == 3 and clearedEvents == 0xFFFFFFFF'u32
cast[proc(p: pointer; status: uint32) {.cdecl.}](awaitingTx.callback)(awaitingTx.argument, 0x800000)
doAssert freed == 4 and registrations == 2
'''


SESSION_CHECKS = r'''
proc restartDuringJoin() =
  discard rxInvalidateVif(0)
  apmPendingCancelMask = 1
  discard rxInvalidateVif(0)
  apmPendingCancelMask = 0
  vifs[0].state = 1

reset(true)
basicIes(true)
finish()
joinHook = restartDuringJoin
apm_assoc_req_handler(addr input[0])
doAssert apm.staCount == 0 and removed == 1 and freed == 1 and tx.callback == nil,
  "a pre-restart join callback committed into a new AP session"

reset(false)
basicIes(false)
finish()
allocateHook = restartDuringJoin
apm_assoc_req_handler(addr input[0])
doAssert apm.staCount == 0 and freed == 1 and tx.callback == nil,
  "an allocation callback moved an old association into a new AP session"

for mode in 0 .. 3:
  reset(false)
  basicIes(false)
  finish()
  case mode
  of 0: vifs[0].state = 0
  of 1: apmPendingCancelMask = 1
  of 2: startupMask = 1
  else: apmStoppingVifs = 1
  apm_assoc_req_handler(addr input[0])
  doAssert allocated == 0 and apm.staCount == 0 and tx.callback == nil,
    "an inactive AP admitted an association"
'''


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_association_handoff(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    names = ["ApmRxMgmtPrefixView", "ApmAssocStaAddIndPayload", "MeStaAddReqPayload",
             "MeStaAddCfmPayload", "MmStaAddReqPayload", "ApmStaAddIndPayload",
             "ApmStaAddCfmParamView", "VifHtCapabilitiesOverlay", "MacIeView", "WpaCallbacksView",
             "ApmPendingAssociation"]
    for name in names:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    types += "const\n"
    for name in ["MeStaAddCfmPayload", "ApmStaAddIndPayload"]:
        types += f"  {name}Size = sizeof({name}).uint32\n"
    helpers = ""
    for name in ["apmRxMgmtPrefix", "meStaAddReqView", "meStaAddReqCapBlock", "meStaAddReqHtCaps",
                 "apmStaAddCfmParamView", "macIePayload"]:
        match = re.search(r"(?ms)^template " + name + r"\b.*?(?=^template |^proc |\Z)", layout)
        assert match, name
        helpers += match.group(0)
    # The fixture supplies its native pointer wrapper for APM confirmations.
    scan = (FW / "scan_station_ap_me.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    bodies = procedure(layout, "lmacGateHalfword")
    bodies += procedure(layout, "mmStaFillAggregation").split("\ntemplate ", 1)[0] + "\n"
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    bodies += procedure(scan, "me_rate_translate")
    bodies += procedure(handlers, "apmVifRunning")
    if "proc apmSessionCurrent(" in scan:
        bodies += procedure(scan, "apmSessionCurrent")
    for name in ["apmPendingClear", "apmPendingRequestSlot", "apmPendingConfirmationSlot",
                 "apmCancelPendingForVif", "aidListDelete", "apm_tx_cfm_handler", "apm_assoc_req_handler", "apm_sta_add",
                 "apm_handle_eapol_input"]:
        bodies += procedure(scan, name)
    bodies += procedure(handlers, "me_sta_add_req_handler")
    bodies += procedure(handlers, "apm_sta_add_cfm_handler")
    bodies += procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_flush")
    program = tmp_path / "ap_association.nim"
    program.write_text(types + PLATFORM + helpers + bodies + CHECKS + PENDING_CHECKS + SESSION_CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_association_response_pointer_abi(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["ApmAssocStaAddIndPayload", "AssocRspFixedBodyView", "MacIeView",
                 "WmmAcParamRecord", "WmmParameterIeView", "BssMaxIdlePeriodIeView",
                 "MmWmmParameterSourceView"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    platform = r'''
const MAX_VIFS = 2
type
  Vif = object
    wmmQosInfo: uint8
    edcaRegs: array[4, uint32]
    ap: tuple[privacyFlag: uint8]
  VifChannelView = Vif
var
  vifs: array[2, Vif]
  request: ApmAssocStaAddIndPayload
  memory: array[160, uint8]
  wmmSource: MmWmmParameterSourceView
  expectedVif: uint8
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifApConfig(v: ptr Vif): ptr tuple[privacyFlag: uint8] = addr v.ap
proc me_build_capability(p: pointer): uint16 =
  doAssert cast[uint](p) == expectedVif.uint
  0x101
proc appendIe(buf: pointer; id: uint8; data: openArray[uint8]): uint32 =
  let cursor = cast[ptr pointer](buf)
  let bytes = cast[ptr UncheckedArray[uint8]](cursor[])
  bytes[0] = id
  bytes[1] = data.len.uint8
  for i, value in data: bytes[i + 2] = value
  result = data.len.uint32 + 2
  cursor[] = cast[pointer](cast[uint](cursor[]) + result.uint)
proc me_add_ie_supp_rates(buf, rates: pointer): uint32 =
  doAssert rates == addr request.rateCount
  appendIe(buf, 1, request.rateBytes.toOpenArray(0, min(8, request.rateCount.int) - 1))
proc me_add_ie_ext_supp_rates(buf, rates: pointer): uint32 =
  doAssert rates == addr request.rateCount
  appendIe(buf, 50, request.rateBytes.toOpenArray(8, request.rateCount.int - 1))
proc me_add_ie_ht_capa(buf: pointer): uint32 = appendIe(buf, 45, [])
proc me_add_ie_ht_oper(buf, vif: pointer): uint32 =
  doAssert vif == addr vifs[expectedVif]
  appendIe(buf, 61, [])
proc mmWmmParameterSource(): ptr MmWmmParameterSourceView = addr wmmSource
proc wmmParameterIeAt(p: pointer): ptr WmmParameterIeView = cast[ptr WmmParameterIeView](p)
proc bssMaxIdlePeriodIeAt(p: pointer): ptr BssMaxIdlePeriodIeView = cast[ptr BssMaxIdlePeriodIeView](p)
'''
    checks = r'''
let buildResponse: proc(buf: pointer; vif: uint8; status: uint16; request: pointer): uint32 {.cdecl.} = me_build_associate_rsp_impl
for vif in 0'u8 .. 1'u8:
  for flags in 0'u32 .. 3'u32:
    for status in [0'u16, 17, 40, 0x1234]:
      for count in [1'u8, 8, 12]:
        expectedVif = vif
        request = default(ApmAssocStaAddIndPayload)
        request.aid = 257
        request.flags = flags
        request.rateCount = count
        for i in 0 ..< 12: request.rateBytes[i] = (i + 1).uint8
        for b in memory.mitems: b = 0xA5
        vifs[vif].ap.privacyFlag = 1
        vifs[vif].wmmQosInfo = 0x85
        vifs[vif].edcaRegs = [0x0A47'u32, 0x0A43, 0x005E432, 0x002F322]
        wmmSource.acBe = 0xDEADBEEF'u32
        wmmSource.idlePeriod = 0x1234
        var cursor = cast[pointer](addr memory[8])
        let length = buildResponse(cursor, vif, status, addr request)
        doAssert cast[uint](addr request) > 65535
        doAssert cursor == addr memory[8]
        doAssert memory[8..13] == @[0x11'u8, 1, (status and 255).uint8, (status shr 8).uint8, 1, 0xC1]
        doAssert memory[14] == 1 and memory[15] == min(count, 8'u8)
        for i in 0 ..< 8: doAssert memory[i] == 0xA5
        for i in 8 + length.int ..< memory.len: doAssert memory[i] == 0xA5
        let expectedLength = 6 + 2 + min(count.int, 8) +
          (if count > 8: count.int - 8 + 2 else: 0) +
          (if (flags and 2) != 0: 4 else: 0) +
          (if (flags and 1) != 0: 26 else: 0)
        if (flags and 1) != 0:
          let start = 8 + expectedLength - 26
          doAssert memory[start .. start + 25] ==
            [221'u8, 24, 0, 0x50, 0xF2, 2, 1, 1, 0x85, 0,
             3, 0xA4, 0, 0, 0x27, 0xA4, 0, 0, 0x42, 0x43, 0x5E, 0,
             0x62, 0x32, 0x2F, 0], "association WMM must encode this VIF's EDCA settings"
          doAssert memory[start + 26] == 0xA5,
            "association response appended an unexpected BSS Max Idle element"
        doAssert length.int == expectedLength
request.rateCount = 13
var cursor = cast[pointer](addr memory[8])
doAssert buildResponse(cursor, 0, 0, addr request) == 0
'''
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan, "writeWmmParameterIe")
    body += procedure(scan, "me_build_associate_rsp_impl")
    program = tmp_path / "association_response.nim"
    program.write_text(declarations + platform + procedure(layout, "setLe32") + body + checks)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
