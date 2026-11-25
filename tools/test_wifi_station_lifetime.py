"""Exercise station retirement across synchronous TX/PS/key callbacks."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_API = 9'u8
  MM_STA_DEL_REQ = 12'u16
  ME_STA_DEL_REQ = 0xC07'u16
  MeStaDelReqPayloadSize = 1'u32
  MM_PS_CHANGE_IND = 0x37'u16
  MmPsChangeIndPayloadSize = 2
  MACHW_TIMLO_REG = 0x24B00120'u
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  StaQueueIdentity = object
    entry: pointer
    stationEpoch, vifEpoch: uint32
    station, vif: uint8
    stationTracked, vifTracked: bool
  MmStaDeletion = object
    owner: StaQueueIdentity
    requestEpoch: uint32
    keys: array[4, uint8]
    keyPending: array[4, bool]
    active, running, staMode, apEffectsDone, addressDeleted, requestOwned: bool
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    confirmations, pending, postponed: CoList
  KeMsgHdr = object
    link: CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  MeStaDelReqPayload = object
    staIdx: uint8
  QueuedDelete = object
    header: KeMsgHdr
    body: MeStaDelReqPayload
  Sta = object
    link: CoListHdr
    instNbr, valid, psMode: uint8
    postponedList: CoList
    marker: uint32
    controlPortState: uint8
    txPolicy, keyMat: pointer
  Frame = object
    link: CoListHdr
    callback, callbackArg, bufDesc: pointer
    pendingMacTime: uint32
    usedFlag, postponeFlag, retryFlag: uint8
  LinkDesc = object
    macHeader: array[24, uint8]
  Security = object
    connected, cipher: uint8
    staKeySlots: array[4, uint8]
  Keys = object
    defaultKeyPtr, groupKeyPtr, flags: uint32
  Vif = object
    vifType, vifIdx, staIdx, psBaCounter: uint8
    security: Security
    stations: CoList
    keys: Keys
  MmPsChangeIndPayload = object
    staIdx, psState: uint8
var
  txActiveFlush: ptr TxFlushBatch
  stations: array[7, Sta]
  vifs: array[2, Vif]
  frames: array[3, Frame]
  frameReleases: array[3, int]
  frameEnv: tuple[postponedCount: uint32]
  sta_info_env: CoList
  keMsgQueueSent, keMsgQueueSaved: CoList
  staDeleteEpochs: array[5, uint32]
  mmStaDeletions: array[STA_MGMT_FREE_STAS, MmStaDeletion]
  mmStaDelRetryMask: uint8
  mmStaDelRetryEpochs: array[STA_MGMT_FREE_STAS, uint32]
  mmStaDelRetryReset: uint32
  mmStaDelRetryTimer: uint32
  rxVifEpochs: array[2, uint32]
  message: MmPsChangeIndPayload
  events: seq[string]
  keys: seq[uint8]
  hook: proc()
  hookSite: string
  expectedVif: uint8
  allocationFails: bool
  keyFailure: uint8
  addressOk: bool
  haltCalls: int
  irq: bool
  messagesFreed: int
  extraFrame: Frame
  extraFrameReleases: int
  bcmcPolicies: array[2, uint32]
  drainUnlockEpoch: uint32
proc invokeHook(site: string)
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) =
  irq = (saved and 8) != 0
  if irq and hookSite == "reset-return" and "zero" in events:
    invokeHook("reset-return")
  if irq and hookSite == "drain-unlock" and staDeleteEpochs[2] == drainUnlockEpoch:
    invokeHook("drain-unlock")
proc txlFlushScopeExit(previous: ptr TxFlushBatch) =
  var batch = txActiveFlush
  while batch != previous and batch != nil:
    doAssert batch.confirmations.first == nil and batch.pending.first == nil and
      batch.postponed.first == nil
    batch = batch.previous
  txActiveFlush = previous
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc mmStaDelQueueRetryLocked(index: uint8; saved: uint32) =
  mmStaDelRetryEpochs[index] = staDeleteEpochs[index]
  mmStaDelRetryMask = mmStaDelRetryMask or (1'u8 shl index)
proc mmTimerActiveDelivery(timer: pointer): ptr tuple[cancelled: bool] = nil
proc ke_reschedule_saved_messages(task: uint8): bool =
  doAssert task == TASK_MM
  true
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifPostponedStaList(vif: ptr Vif): ptr CoList = addr vif.stations
proc vifSecurity(vif: ptr Vif): ptr Security = addr vif.security
proc vifKeyPointers(vif: ptr Vif): ptr Keys = addr vif.keys
proc txBufferControlBcmcDescAt(index: int): pointer = addr bcmcPolicies[index]
proc getLogFunc(offset: int): pointer = nil
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc hostTxDescAt(p: pointer): ptr Frame = cast[ptr Frame](p)
proc hostTxLinkDescAt(p: pointer): ptr LinkDesc = cast[ptr LinkDesc](p)
proc txFrameEnv(): ptr typeof(frameEnv) = addr frameEnv
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc wifiRamPointer(p: pointer): bool = p != nil
proc regRead(p: uint): uint32 = 999999
proc co_list_find(list: ptr CoList; node: ptr CoListHdr): bool =
  var current = list.first
  var count = 0
  while current != nil:
    if current == node: return true
    inc count
    doAssert count < 10, "list cycle"
    current = current.next
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  doAssert not co_list_find(list, node), "station/frame returned twice"
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_remove(list: ptr CoList; previous, node: ptr CoListHdr) =
  if previous == nil:
    doAssert list.first == node
    list.first = node.next
  else:
    doAssert previous.next == node
    previous.next = node.next
  if list.last == node: list.last = previous
  node.next = nil
proc co_list_extract(list: ptr CoList; node: ptr CoListHdr) =
  var previous: ptr CoListHdr
  var current = list.first
  while current != nil:
    if current == node:
      co_list_remove(list, previous, current)
      return
    previous = current
    current = current.next
proc invokeHook(site: string) =
  events.add(site)
  if hook != nil and hookSite == site:
    let callback = hook
    hook = nil
    callback()
proc txl_frame_release(p: pointer; notify: bool) =
  doAssert notify
  if p == addr extraFrame:
    inc extraFrameReleases
    doAssert extraFrameReleases == 1
    invokeHook("tx")
    return
  var index = -1
  for i in 0 ..< frames.len:
    if p == addr frames[i]: index = i
  doAssert index >= 0
  inc frameReleases[index]
  doAssert frameReleases[index] == 1, "postponed frame released twice"
  invokeHook("tx")
proc txlHaltStationQueues(index: uint8; selected: var uint8): bool =
  inc haltCalls
  if hookSite == "halt": invokeHook("halt")
  true
proc txl_retire_station(index: uint8; selected: uint8) =
  doAssert index == 2
  doAssert stations[index].valid == 0
  doAssert not co_list_find(addr vifs[expectedVif].stations, addr stations[index].link)
  doAssert not co_list_find(addr sta_info_env, addr stations[index].link)
  invokeHook("drain")
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0 and n == 368
  doAssert staInfoAt(p).postponedList.first == nil
  events.add("zero")
  zeroMem(p, sizeof(Sta))
  p
proc ke_msg_alloc(id: uint16; dst, src: uint8; n: int): pointer =
  doAssert id == MM_PS_CHANGE_IND and dst == TASK_API and src == TASK_MM and n == 2
  invokeHook("alloc")
  if allocationFails: nil else: addr message
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) =
  doAssert p == addr message
  inc messagesFreed
  events.add("free")
proc ke_msg_send(p: pointer) = invokeHook("host")
proc apm_tx_int_ps_clear(vif: pointer; index: uint8) =
  doAssert index == expectedVif + 5 and stations[index].psMode == 0
  invokeHook("ps")
proc mmDeleteSecurityKey(index: uint8): bool =
  keys.add(index)
  invokeHook("key")
  index != keyFailure
proc mmDeleteSecurityAddress(index: uint8): bool =
  doAssert index == 2
  invokeHook("address")
  addressOk
proc setup(vif: uint8; ap: bool) =
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  frames = default(typeof(frames))
  frameReleases = default(typeof(frameReleases))
  sta_info_env = default(CoList)
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  expectedVif = vif
  for i in 0 ..< stations.len:
    stations[i].instNbr = 255
  for i in 0 .. 1:
    vifs[i].vifIdx = i.uint8
    vifs[i].staIdx = 2
    vifs[i].psBaCounter = 1
    vifs[i].security = Security(connected: 1, cipher: 2,
      staKeySlots: [8'u8, 9, 10, 11])
  vifs[vif].vifType = if ap: 2 else: 0
  stations[2] = Sta(instNbr: vif, valid: 1, psMode: ap.uint8, marker: 1234)
  stations[3] = Sta(instNbr: vif xor 1, valid: 1, marker: 5678)
  stations[vif + 5].psMode = 1
  co_list_push_back(addr vifs[vif].stations, addr stations[2].link)
  co_list_push_back(addr vifs[vif xor 1].stations, addr stations[3].link)
  for frame in frames.mitems:
    co_list_push_back(addr stations[2].postponedList, addr frame.link)
  frameEnv.postponedCount = frames.len.uint32
  events.setLen(0)
  keys.setLen(0)
  hook = nil
  hookSite = ""
  allocationFails = false
  keyFailure = 0xFF
  addressOk = true
  haltCalls = 0
  mmStaDeletions = default(typeof(mmStaDeletions))
  mmStaDelRetryMask = 0
  irq = true
  messagesFreed = 0
  rxVifEpochs = [11'u32, 12]
  extraFrame = default(Frame)
  extraFrameReleases = 0
  drainUnlockEpoch = 0
'''

CHECKS = r'''
proc reenter() =
  # All callback boundaries must observe retirement before touching storage.
  doAssert stations[2].valid == 0, "retiring station still admitted"
  doAssert not co_list_find(addr vifs[expectedVif].stations, addr stations[2].link)
  doAssert not co_list_find(addr sta_info_env, addr stations[2].link)
  mm_sta_del(2)
  sta_mgmt_unregister(2)
setup(0, false)
hookSite = "halt"
hook = proc() = mm_sta_del(2)
mm_sta_del(2)
doAssert haltCalls == 1 and sta_info_env.first == addr stations[2].link
for vif in 0'u8 .. 1:
  for ap in [false, true]:
    for site in ["drain", "tx", "host", "ps", "key", "address"]:
      for direct in [false, true]:
        setup(vif, ap)
        hookSite = site
        hook = reenter
        if direct: sta_mgmt_unregister(2)
        else: mm_sta_del(2)
        doAssert frameReleases == [1, 1, 1]
        doAssert frameEnv.postponedCount == 0
        doAssert sta_info_env.first == addr stations[2].link
        doAssert sta_info_env.last == addr stations[2].link
        doAssert stations[2].link.next == nil and stations[2].instNbr == 255
        doAssert stations[2].valid == 0 and stations[2].marker == 0
        doAssert vifs[vif].stations.first == nil
        doAssert stations[3].valid == 1 and stations[3].marker == 5678
        doAssert vifs[vif xor 1].stations.first == addr stations[3].link
        doAssert events.count("zero") == 1
        doAssert events.count("drain") == 1
        doAssert events[0] == "drain"
        doAssert events.count("address") == (not direct).int
        doAssert keys == (if direct or ap: newSeq[uint8]() else: @[8'u8, 9, 10])
        doAssert events.count("ps") == (ap and not direct).int
        doAssert vifs[vif].psBaCounter == (if ap and not direct: 0'u8 else: 1'u8)
        let before = events
        mm_sta_del(2)
        sta_mgmt_unregister(2)
        for invalid in [5'u8, 6, 7, 255]:
          mm_sta_del(invalid)
          sta_mgmt_unregister(invalid)
        doAssert events == before

# The same table slot becomes reusable only after its first drain has finished.
setup(1, false)
mm_sta_del(2)
co_list_extract(addr sta_info_env, addr stations[2].link)
stations[2].valid = 1
stations[2].instNbr = 1
stations[2].marker = 9012
co_list_push_back(addr vifs[1].stations, addr stations[2].link)
hook = reenter
hookSite = "address"
mm_sta_del(2)
doAssert events.count("address") == 2 and events.count("zero") == 2
doAssert sta_info_env.first == addr stations[2].link
doAssert sta_info_env.last == addr stations[2].link
doAssert frameReleases == [1, 1, 1] and frameEnv.postponedCount == 0

# Invalid VIF identities or already detached entries cannot corrupt a free list.
setup(0, true)
stations[2].instNbr = 255
mm_sta_del(2)
sta_mgmt_unregister(2)
doAssert events.len == 0 and sta_info_env.first == nil
stations[2].instNbr = 0
co_list_extract(addr vifs[0].stations, addr stations[2].link)
mm_sta_del(2)
sta_mgmt_unregister(2)
doAssert events.len == 0 and sta_info_env.first == nil

# Retirement cancels old requests in both queues without changing ownership.
setup(0, false)
var pending: array[7, QueuedDelete]
for i in 0 ..< pending.len:
  pending[i].header = KeMsgHdr(id: MM_STA_DEL_REQ, destId: TASK_MM, paramLen: 1)
  pending[i].body.staIdx = 2
pending[1].header.id = ME_STA_DEL_REQ
pending[1].header.destId = TASK_ME
pending[2].body.staIdx = 3
pending[4].header.id = ME_STA_DEL_REQ
pending[4].header.destId = TASK_ME
pending[5].header.paramLen = 0
pending[6].header.destId = TASK_API
for i in 0 ..< pending.len:
  co_list_push_back((if i < 3: addr keMsgQueueSent else: addr keMsgQueueSaved),
    addr pending[i].header.link)
let oldEpoch = staDeleteEpoch(2)
mm_sta_del(2)
for i in [0, 1, 3, 4]: doAssert pending[i].body.staIdx == 255
doAssert pending[2].body.staIdx == 3
doAssert pending[5].body.staIdx == 2 and pending[6].body.staIdx == 2
doAssert keMsgQueueSent.first == addr pending[0].header.link
doAssert keMsgQueueSent.last == addr pending[2].header.link
doAssert keMsgQueueSaved.first == addr pending[3].header.link
doAssert keMsgQueueSaved.last == addr pending[6].header.link
co_list_extract(addr sta_info_env, addr stations[2].link)
stations[2] = Sta(valid: 1, instNbr: 1, marker: 777)
co_list_push_back(addr vifs[1].stations, addr stations[2].link)
let beforeStale = events
for i in [0, 1, 3, 4]: mm_sta_del(pending[i].body.staIdx)
doAssert events == beforeStale and stations[2].marker == 777 and stations[2].valid == 1
doAssert not staDeleteIsCurrent(2, oldEpoch)
doAssert staDeleteIsCurrent(2, staDeleteEpoch(2))
mm_sta_del(2)
doAssert stations[2].valid == 0 and stations[3].valid == 1
staDeleteEpochs[2] = high(uint32)
staDeleteInvalidate(2)
doAssert staDeleteEpoch(2) == 0

# A failed hardware cleanup keeps the retired entry out of the free pool.
for failed in [8'u8, 9, 10]:
  setup(0, false)
  let beforeEpoch = staDeleteEpoch(2)
  keyFailure = failed
  mm_sta_del(2)
  doAssert stations[2].valid == 0 and stations[2].marker == 1234
  doAssert not co_list_find(addr sta_info_env, addr stations[2].link)
  doAssert mmStaDelOwned(2, 0, beforeEpoch)
  doAssert vifs[0].security.staKeySlots[(failed - 8).int] == failed
  doAssert "address" notin events and "zero" notin events
  let after = events
  mm_sta_del(2)
  doAssert events == after & @["key"]
  keyFailure = 0xFF
  mmStaDelRetryCb(nil)
  doAssert events.count("address") == 1 and events.count("zero") == 1
  doAssert not mmStaDelOwned(2, 0, beforeEpoch)
  doAssert sta_info_env.first == addr stations[2].link
setup(0, false)
addressOk = false
mm_sta_del(2)
doAssert stations[2].valid == 0 and stations[2].marker == 1234
doAssert not co_list_find(addr sta_info_env, addr stations[2].link)
doAssert "address" in events and "zero" notin events
vifs[0].staIdx = 4
addressOk = true
mmStaDelRetryCb(nil)
doAssert events.count("address") == 2 and events.count("zero") == 1
doAssert vifs[0].staIdx == 4
doAssert sta_info_env.first == addr stations[2].link

# AP sleeper and broadcast power-save effects run only once across retries.
setup(0, true)
addressOk = false
mm_sta_del(2)
doAssert events.count("ps") == 1 and vifs[0].psBaCounter == 0
addressOk = true
mmStaDelRetryCb(nil)
doAssert events.count("ps") == 1 and events.count("address") == 2
doAssert sta_info_env.first == addr stations[2].link

# An unpublished add with an uncertain address write uses the same retry
# owner, but must not touch VIF association, keys, or AP sleeper accounting.
for ap in [false, true]:
  setup(0, ap)
  var unpublished: StaQueueIdentity
  doAssert staMgmtBeginRemoval(2, unpublished) != nil
  addressOk = false
  mmStaDelTrackUnpublished(unpublished)
  doAssert sta_info_env.first == nil and mmStaDeletions[2].active
  doAssert not mmStaDelOwned(2, 0, unpublished.stationEpoch - 1'u32)
  doAssert vifs[0].staIdx == 2 and vifs[0].psBaCounter == 1
  doAssert keys.len == 0 and events.count("ps") == 0
  addressOk = true
  mmStaDelRetryCb(nil)
  doAssert sta_info_env.first == addr stations[2].link
  doAssert vifs[0].staIdx == 2 and vifs[0].psBaCounter == 1
  doAssert keys.len == 0 and events.count("address") == 2

# Replacing the VIF during a callout must stop the old teardown before it
# touches the replacement. Old detached TX frames may still retire.
for vif in 0'u8 .. 1:
  for ap in [false, true]:
    let sites = if ap: @["drain", "alloc", "host", "ps", "address", "tx"]
      else: @["drain", "key", "address", "tx"]
    for site in sites:
      for incomingIrq in [false, true]:
        setup(vif, ap)
        irq = incomingIrq
        hookSite = site
        var fired = false
        var replacement: Vif
        hook = proc() =
          fired = true
          if site in ["alloc", "host", "tx"]:
            doAssert irq == incomingIrq, "callback IRQ contract"
          elif site == "ps":
            doAssert not irq, "power-save handoff was not atomic"
          inc rxVifEpochs[vif]
          vifs[vif].staIdx = 4
          vifs[vif].psBaCounter = 9
          vifs[vif].security.staKeySlots = [41'u8, 42, 43, 44]
          replacement = vifs[vif]
        mm_sta_del(2)
        doAssert fired and irq == incomingIrq
        doAssert vifs[vif] == replacement, "old teardown modified replacement VIF at " & site
        doAssert stations[2].valid == 0 and stations[2].marker == 1234
        doAssert not co_list_find(addr sta_info_env, addr stations[2].link)
        doAssert "zero" notin events
        doAssert messagesFreed == (site == "alloc").int

# Beginning removal must not hand a stale token back to another caller.
setup(0, false)
hookSite = "drain"
hook = proc() = inc rxVifEpochs[0]
var staleOwner: StaQueueIdentity
doAssert staMgmtBeginRemoval(2, staleOwner) == nil

# A reset must leave freshly queued work reachable rather than zeroing it.
for incomingIrq in [false, true]:
  setup(0, false)
  irq = incomingIrq
  hookSite = "tx"
  hook = proc() =
    doAssert irq == incomingIrq
    co_list_push_back(addr stations[2].postponedList, addr extraFrame.link)
    inc frameEnv.postponedCount
  mm_sta_del(2)
  doAssert irq == incomingIrq and frameReleases == [1, 1, 1]
  doAssert frameEnv.postponedCount == 1
  doAssert stations[2].postponedList.first == addr extraFrame.link
  doAssert stations[2].marker == 1234 and "zero" notin events
  doAssert sta_info_env.first == nil

# A failed final TX drain keeps the saved delete request pending through a
# second station epoch, then releases it only with the free-list publication.
setup(0, false)
let drainEpoch = staDeleteEpoch(2)
hookSite = "tx"
hook = proc() =
  co_list_push_back(addr stations[2].postponedList, addr extraFrame.link)
  inc frameEnv.postponedCount
mm_sta_del(2)
doAssert mmStaDelOwned(2, 0, drainEpoch)
doAssert sta_info_env.first == nil and mmStaDeletions[2].addressDeleted
var awaiting = QueuedDelete(header: KeMsgHdr(id: MM_STA_DEL_REQ, destId: TASK_MM, paramLen: 1),
                            body: MeStaDelReqPayload(staIdx: 2))
co_list_push_back(addr keMsgQueueSaved, addr awaiting.header.link)
hookSite = "tx"
hook = proc() = doAssert awaiting.body.staIdx == 2
mmStaDelRetryCb(nil)
doAssert extraFrameReleases == 1 and sta_info_env.first == addr stations[2].link
doAssert awaiting.body.staIdx == 0xFF and not mmStaDelOwned(2, 0, drainEpoch)
doAssert events.count("address") == 1


# An IRQ at the first callback boundary cannot make reset drain a replacement
# queue. The original batch must already be detached before interrupts return.
setup(0, false)
drainUnlockEpoch = staDeleteEpochs[2] + 2'u32
hookSite = "drain-unlock"
var interruptedDrain = false
hook = proc() =
  interruptedDrain = true
  inc rxVifEpochs[0]
  co_list_push_back(addr stations[2].postponedList, addr extraFrame.link)
  inc frameEnv.postponedCount
mm_sta_del(2)
doAssert interruptedDrain and irq
doAssert frameReleases == [1, 1, 1] and frameEnv.postponedCount == 1
doAssert stations[2].postponedList.first == addr extraFrame.link
doAssert sta_info_env.first == nil and stations[2].marker == 1234

# An interrupt after reset but before free-pool publication can claim/reset
# the same storage. Each ownership check must reject that continuation.
for change in 0 .. 3:
  setup(0, false)
  hookSite = "reset-return"
  var fired = false
  hook = proc() =
    fired = true
    case change
    of 0: inc staDeleteEpochs[2]
    of 1: stations[2].valid = 1
    of 2: stations[2].instNbr = 0
    else: co_list_push_back(addr sta_info_env, addr stations[2].link)
  mm_sta_del(2)
  doAssert fired and irq
  if change == 3:
    doAssert sta_info_env.first == addr stations[2].link
    doAssert sta_info_env.last == addr stations[2].link
  else: doAssert sta_info_env.first == nil

# A direct finish request cannot reset a live entry with a matching token.
setup(0, false)
let liveOwner = staPostponedOwner(addr stations[2])
staMgmtFinishRemoval(liveOwner)
doAssert stations[2].valid == 1 and stations[2].marker == 1234 and events.len == 0
for index in [5'u8, 6]:
  setup(0, false)
  stations[index].marker = 456
  staMgmtFinishRemoval(staPostponedOwner(addr stations[index]))
  doAssert stations[index].marker == 456 and sta_info_env.first == nil
setup(0, false)
var local = Sta(instNbr: 255, marker: 555)
staMgmtFinishRemoval(staPostponedOwner(addr local))
doAssert local.marker == 555 and sta_info_env.first == nil

setup(0, false)
staDeleteEpochs[2] = high(uint32) - 1
mm_sta_del(2)
doAssert staDeleteEpochs[2] == 0
doAssert sta_info_env.first == addr stations[2].link
sta_mgmt_entry_init(nil)

# Cold initialization still produces five free entries and two BCMC entries.
stations = default(typeof(stations))
vifs = default(typeof(vifs))
keMsgQueueSent = default(CoList)
keMsgQueueSaved = default(CoList)
events.setLen(0)
hook = nil
sta_mgmt_init()
var freeNode = sta_info_env.first
for index in 0 ..< 5:
  doAssert freeNode == addr stations[index].link
  doAssert stations[index].instNbr == 255
  freeNode = freeNode.next
doAssert freeNode == nil and sta_info_env.last == addr stations[4].link
for index in 0 .. 1:
  doAssert stations[index + 5].instNbr == index.uint8
  doAssert stations[index + 5].keyMat == cast[pointer](addr vifs[index].keys)
  doAssert stations[index + 5].txPolicy == addr bcmcPolicies[index]

# Failure while resetting the first entry cannot publish that entry as free
# or continue reinitializing unrelated slots.
stations = default(typeof(stations))
vifs = default(typeof(vifs))
frames = default(typeof(frames))
frameReleases = default(typeof(frameReleases))
events.setLen(0)
stations[0].instNbr = 0
stations[0].marker = 303
stations[1].marker = 777
co_list_push_back(addr stations[0].postponedList, addr frames[0].link)
frameEnv.postponedCount = 1
hookSite = "tx"
hook = proc() = inc rxVifEpochs[0]
sta_mgmt_init()
doAssert sta_info_env.first == nil and stations[0].marker == 303
doAssert stations[1].marker == 777 and "zero" notin events


'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "key_failure", "address_failure", "begin_owner", "init_failure",
    "mm_owner", "reset_owner", "reset_pending", "reset_retired", "drain_capture", "drain_irq", "finish_epoch",
    "finish_valid", "finish_vif", "finish_pool", "finish_scope", "ps_handoff", "callback_irq"])
def test_station_retirement_is_callback_safe(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    sta = (FW / "sta_management.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    names = ["staDeleteEpoch", "staDeleteIsCurrent", "staDeleteCancelQueued", "staDeleteInvalidate",
                 "staPostponedOwner", "staPostponedOwnerCurrent", "staPostponedListValid",
                 "staReleasePostponed", "sta_mgmt_postponed_desc_release", "staMgmtResetEntry", "sta_mgmt_entry_init",
                 "sta_mgmt_init", "staRemovalCurrent",
                 "staMgmtBeginRemoval", "staMgmtFinishRemoval", "sta_mgmt_unregister"]
    parts = {name: procedure(sta, name) for name in names}
    before = dict(parts)
    deletion = procedure(kernel, "mmStaDelTry")
    original_deletion = deletion
    if mutation == "key_failure":
        deletion = deletion.replace("if keysRemoved and", "if true and")
    elif mutation == "address_failure":
        deletion = deletion.replace("if deleted: deletion.addressDeleted = true",
                                    "if true: deletion.addressDeleted = true")
    elif mutation == "begin_owner":
        parts["staMgmtBeginRemoval"] = parts["staMgmtBeginRemoval"].replace(
            "if not staRemovalCurrent(owner):", "if false:")
    elif mutation == "init_failure":
        parts["sta_mgmt_init"] = parts["sta_mgmt_init"].replace(
            "if not staMgmtResetEntry(staPostponedOwner(cast[pointer](sta)), false):\n      return",
            "discard staMgmtResetEntry(staPostponedOwner(cast[pointer](sta)), false)")
    elif mutation == "mm_owner":
        deletion = deletion.replace("template current(): bool = sameDeletion() and staRemovalCurrent(owner)",
                                    "template current(): bool = true")
    elif mutation == "reset_owner":
        parts["staMgmtResetEntry"] = parts["staMgmtResetEntry"].replace(
            "not staPostponedOwnerCurrent(resetOwner)", "false")
    elif mutation == "reset_pending":
        parts["staMgmtResetEntry"] = parts["staMgmtResetEntry"].replace(
            "or sta.postponedList.first != nil", "")
    elif mutation == "reset_retired":
        parts["staMgmtResetEntry"] = parts["staMgmtResetEntry"].replace(
            "requireRetired and sta.valid != 0", "false")
    elif mutation == "drain_capture":
        parts["staMgmtResetEntry"] = parts["staMgmtResetEntry"].replace(
            "  discard staReleasePostponed(resetOwner, 1'u32, saved)",
            "  irqRestore(saved)\n  discard sta_mgmt_postponed_desc_release(staEntry, 1'u32)\n  discard irqSave()")
    elif mutation == "drain_irq":
        parts["staReleasePostponed"] = parts["staReleasePostponed"].replace(
            "irqRestore(callbackIrqState)", "irqRestore(saved)")
    elif mutation == "finish_epoch":
        parts["staMgmtFinishRemoval"] = parts["staMgmtFinishRemoval"].replace(
            "staDeleteEpoch(owner.station) != owner.stationEpoch + 1'u32", "false")
    elif mutation == "finish_valid":
        parts["staMgmtFinishRemoval"] = parts["staMgmtFinishRemoval"].replace("sta.valid != 0", "false")
    elif mutation == "finish_vif":
        parts["staMgmtFinishRemoval"] = parts["staMgmtFinishRemoval"].replace("sta.instNbr != 0xFF", "false")
    elif mutation == "finish_pool":
        parts["staMgmtFinishRemoval"] = parts["staMgmtFinishRemoval"].replace(
            "co_list_find(addr sta_info_env, cast[ptr CoListHdr](owner.entry))", "false")
    elif mutation == "finish_scope":
        parts["staMgmtFinishRemoval"] = parts["staMgmtFinishRemoval"].replace(
            "not owner.stationTracked or owner.station >= STA_MGMT_FREE_STAS.uint8", "false")
    elif mutation == "callback_irq":
        deletion = deletion.replace("      irqRestore(saved)\n      try:", "      discard\n      try:")
    elif mutation == "ps_handoff":
        deletion = deletion.replace("        apm_tx_int_ps_clear(cast[pointer](vif), bcmcStaIdx)",
                                    "        outsideLock(apm_tx_int_ps_clear(cast[pointer](vif), bcmcStaIdx))")
    if mutation is not None:
        assert parts != before or deletion != original_deletion, mutation
    bodies = "".join(parts.values())
    # The deletion a request started is still held by MM for that station.
    bodies += """
proc mmStaDelOwned(staIdx, vifIdx: uint8; stationEpoch: uint32): bool =
  let deletion = mmStaDeletions[staIdx]
  deletion.active and deletion.requestOwned and deletion.owner.vif == vifIdx and
    deletion.requestEpoch == stationEpoch
""" + deletion
    bodies += procedure(kernel[kernel.index("proc mmStaDelTry("):], "mmStaDelTrackUnpublished")
    bodies += procedure(kernel, "mm_sta_del")
    bodies += procedure(kernel[kernel.index("proc mm_sta_del*"):], "mmStaDelRetryCb")
    debug = "var\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    source = tmp_path / "lifetime.nim"
    source.write_text("import std/sequtils\n" + PLATFORM + debug + bodies + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV", "SIGBUS"]), result.stdout
