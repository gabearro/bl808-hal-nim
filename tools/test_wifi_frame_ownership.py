"""Check freelist corruption, live leases, and postponed-expiry ownership."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const
  TxlFrameDescCount = 4'u32
  TxlFrameDescSize = 220'u
  TxlFrameLinkCount = 4'u32
  TxlFrameLinkSize = 860'u
  InvalidFrameDescIndex = 0xFFFFFFFF'u32
  STA_INFO_TAB_ENTRIES = 7
  MACHW_TIMLO_REG = 0x24B00120'u
type
  CoListHdr {.packed.} = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    confirmations, pending, postponed: CoList
  HostTxDescView {.packed.} = object
    link: CoListHdr
    callback, callbackArg, bufDesc: pointer
    pendingMacTime: uint32
    usedFlag, postponeFlag, retryFlag: uint8
    vifIdx, staInfoIdx: uint8
  TxFrameEnvView = object
    freeList, usedList: CoList
    postponedCount: uint32
  Sta = object
    postponedList: CoList
    valid, instNbr: uint8
  LinkDesc = object
    next, txDesc: pointer
    macHeader: array[24, uint8]
  CallbackState = object
    calls: int
    advanceTime: uint32
    reallocate: bool
    repost: bool
    lease: pointer
var
  txActiveFlush: ptr TxFlushBatch
  txl_frame_desc_storage: array[880, uint8]
  txl_frame_pool: array[3440, uint8]
  frameEnv: TxFrameEnvView
  stas: array[7, Sta]
  acs: array[5, tuple[current: pointer, pending: CoList]]
  backups: array[5, pointer]
  macTime: uint32
  interruptsEnabled = true

proc txFrameEnv(): ptr TxFrameEnvView = addr frameEnv
proc txlFrameDescAt(index: uint32): ptr HostTxDescView =
  cast[ptr HostTxDescView](addr txl_frame_desc_storage[index * 220])
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txSecurityCurrent(d: ptr HostTxDescView): bool = true
proc txSecurityForget(d: pointer) = discard
proc txSecurityReset() = discard
proc txlFrameEndLease(d: ptr HostTxDescView) = discard
proc hostTxLinkDescAt(p: pointer): ptr LinkDesc = cast[ptr LinkDesc](p)
proc hostTxBufferedLinkAt(p: pointer): ptr LinkDesc = cast[ptr LinkDesc](p)
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc txControlAc(ac: uint32): ptr tuple[current: pointer, pending: CoList] = addr acs[ac]
proc txBackupQueueHeadPtr(ac: uint32): ptr pointer = addr backups[ac]
proc txl_tx_desc_pointer_plausible(p: pointer): bool = p != nil
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc wifiRamPointer(p: pointer): bool = cast[uint](p) > 4096
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macTime
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(previous: uint32) = interruptsEnabled = (previous and 8) != 0
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  var present = list.first
  var count = 0
  while present != nil:
    doAssert present != node, "duplicate list ownership"
    inc count
    doAssert count <= 4, "list cycle"
    present = present.next
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): ptr CoListHdr =
  result = list.first
  if result == nil: return
  list.first = result.next
  if list.first == nil: list.last = nil
  result.next = nil
proc co_list_remove(list: ptr CoList; previous, node: ptr CoListHdr) =
  if previous == nil:
    doAssert list.first == node
    list.first = node.next
  else:
    doAssert previous.next == node
    previous.next = node.next
  if list.last == node: list.last = previous
proc reset() =
  txl_frame_desc_storage = default(typeof(txl_frame_desc_storage))
  frameEnv = default(TxFrameEnvView)
  stas = default(typeof(stas))
  acs = default(typeof(acs))
  backups = default(typeof(backups))
  macTime = 0
  for i in 0'u32 ..< 4:
    co_list_push_back(addr frameEnv.freeList, addr txlFrameDescAt(i).link)
"""

CALLBACK_STUBS = r"""
proc txlCaptureFrameCallback(d: ptr HostTxDescView): int = 0
proc txlInvokeFrameCallback(callback, argument: pointer; status: uint32; context: int) =
  cast[proc(arg: pointer; status: uint32) {.cdecl.}](callback)(argument, status)
"""
DMA_INVALIDATION_STUBS = r"""
proc txlInvalidateDmaFrame(p: pointer) = discard
proc txlInvalidateDmaAc(ac: uint8) = discard
proc txlInvalidateDmaVif(vif: uint8) = discard
proc txlInvalidateDmaStation(station: uint8) = discard
proc txlInvalidateDmaAll() = discard
proc txlInvalidateDmaPool() = discard
"""
STA_QUEUE_STUBS = r"""
type StaQueueIdentity = object
  entry: pointer
proc staPostponedOwner(p: pointer): StaQueueIdentity = StaQueueIdentity(entry: p)
proc staPostponedOwnerCurrent(identity: StaQueueIdentity): bool = true
"""
PLATFORM += CALLBACK_STUBS + DMA_INVALIDATION_STUBS + STA_QUEUE_STUBS

CHECKS = r"""
proc callback(arg: pointer; status: uint32) {.cdecl.} =
  doAssert status == 0 and interruptsEnabled
  let state = cast[ptr CallbackState](arg)
  inc state.calls
  macTime += state.advanceTime
  if state.reallocate:
    state.lease = cast[pointer](txl_frame_free_list_pop(addr frameEnv.freeList))
    if state.repost:
      doAssert state.lease != nil
      co_list_push_back(addr stas[1].postponedList, cast[ptr CoListHdr](state.lease))
      inc frameEnv.postponedCount

# A caller already owns one slot. Damaging the remaining free list must not
# invent free ownership for that slot, even though it is not on a TX queue.
reset()
let callerLease = txl_frame_free_list_pop(addr frameEnv.freeList)
doAssert callerLease == addr txlFrameDescAt(0).link
frameEnv.freeList.first = cast[ptr CoListHdr](1)
frameEnv.freeList.last = cast[ptr CoListHdr](1)
doAssert txl_frame_free_list_pop(addr frameEnv.freeList) == nil
doAssert frameEnv.freeList.first == nil and frameEnv.freeList.last == nil

# AC 4 is a real owner too; damaged free links cannot authorize its reclamation.
reset()
let queued = txl_frame_free_list_pop(addr frameEnv.freeList)
co_list_push_back(addr acs[4].pending, queued)
frameEnv.freeList.first = cast[ptr CoListHdr](1)
frameEnv.freeList.last = cast[ptr CoListHdr](1)
doAssert txl_frame_free_list_pop(addr frameEnv.freeList) == nil
doAssert acs[4].pending.first == queued and acs[4].pending.last == queued

# A loop, bad successor, bad tail, and orphan tail are all inconsistent lists.
for corruption in 0 .. 3:
  reset()
  case corruption
  of 0: frameEnv.freeList.first.next = frameEnv.freeList.first
  of 1: frameEnv.freeList.first.next = cast[ptr CoListHdr](3)
  of 2: frameEnv.freeList.last = frameEnv.freeList.first
  else: frameEnv.freeList.first = nil
  doAssert txl_frame_free_list_pop(addr frameEnv.freeList) == nil
  doAssert frameEnv.freeList.first == nil and frameEnv.freeList.last == nil

# Exhausting valid free slots must never reissue a live lease.
reset()
for index in 0'u32 ..< 4:
  let lease = txl_frame_free_list_pop(addr frameEnv.freeList)
  doAssert lease == addr txlFrameDescAt(index).link
doAssert txl_frame_free_list_pop(addr frameEnv.freeList) == nil

# Exact age boundary, unsigned clock wrap, mixed keep/remove ordering, and
# forced release all preserve the remaining list and global count.
for now in [0'u32, 0x00020000, 0xFFFFFFF0'u32]:
  for force in [false, true]:
    reset()
    var contexts: array[4, CallbackState]
    let ages = [0'u32, 120000, 120001, 200000]
    for index in 0'u32 ..< 4:
      let desc = hostTxDescAt(txl_frame_free_list_pop(addr frameEnv.freeList))
      desc.callback = cast[pointer](callback)
      desc.callbackArg = addr contexts[index]
      desc.pendingMacTime = now - ages[index]
      desc.postponeFlag = 1
      co_list_push_back(addr stas[0].postponedList, addr desc.link)
    macTime = now
    frameEnv.postponedCount = 4
    let released = sta_mgmt_postponed_desc_release(addr stas[0], force.uint32)
    doAssert released == (if force: 4'u32 else: 2'u32)
    doAssert frameEnv.postponedCount == 4 - released
    for index in 0 ..< 4:
      doAssert contexts[index].calls == (if force or ages[index] > 120000: 1 else: 0)
    if force:
      doAssert stas[0].postponedList.first == nil
    else:
      doAssert stas[0].postponedList.first == addr txlFrameDescAt(0).link
      doAssert stas[0].postponedList.last == addr txlFrameDescAt(1).link

# An expired frame is returned before its callback and may be allocated by it.
reset()
var context = CallbackState(reallocate: true)
for index in 0'u32 ..< 4: discard txl_frame_free_list_pop(addr frameEnv.freeList)
let desc = txlFrameDescAt(0)
desc.callback = cast[pointer](callback)
desc.callbackArg = addr context
co_list_push_back(addr stas[0].postponedList, addr desc.link)
frameEnv.postponedCount = 1
doAssert sta_mgmt_postponed_desc_release(addr stas[0], 1) == 1
doAssert context.calls == 1 and context.lease == cast[pointer](desc)
doAssert frameEnv.freeList.first == nil

# A callback may allocate and postpone new work on another station. Only the
# completed frame is removed from the global count.
reset()
var repostContext = CallbackState(reallocate: true, repost: true)
for index in 0'u32 ..< 4: discard txl_frame_free_list_pop(addr frameEnv.freeList)
let repostDesc = txlFrameDescAt(0)
repostDesc.callback = cast[pointer](callback)
repostDesc.callbackArg = addr repostContext
co_list_push_back(addr stas[0].postponedList, addr repostDesc.link)
frameEnv.postponedCount = 1
doAssert sta_mgmt_postponed_desc_release(addr stas[0], 1) == 1
doAssert frameEnv.postponedCount == 1
doAssert stas[1].postponedList.first == cast[ptr CoListHdr](repostContext.lease)
doAssert frameEnv.freeList.first == nil and stas[0].postponedList.first == nil

# A callback can advance time enough for the next queued frame to expire.
reset()
var contexts: array[2, CallbackState]
contexts[0].advanceTime = 10
for index in 0'u32 ..< 4: discard txl_frame_free_list_pop(addr frameEnv.freeList)
for index in 0'u32 ..< 2:
  let desc = txlFrameDescAt(index)
  desc.callback = cast[pointer](callback)
  desc.callbackArg = addr contexts[index]
  desc.pendingMacTime = if index == 0: 0'u32 else: 10'u32
  co_list_push_back(addr stas[0].postponedList, addr desc.link)
macTime = 120001
frameEnv.postponedCount = 2
doAssert sta_mgmt_postponed_desc_release(addr stas[0], 0) == 2
doAssert contexts[0].calls == 1 and contexts[1].calls == 1

# A bad station list must not reset another station's postponed count.
reset()
frameEnv.postponedCount = 3
stas[0].postponedList.first = cast[ptr CoListHdr](1)
stas[0].postponedList.last = cast[ptr CoListHdr](1)
doAssert sta_mgmt_postponed_desc_release(addr stas[0], 1) == 0
doAssert frameEnv.postponedCount == 3
"""


def test_pool_leases_and_postponed_release(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    base = ROOT / "src/bl808/wifi/fw"
    tx = (base / "tx_layer.nim").read_text()
    sta = (base / "sta_management.nim").read_text()

    def procedure(source: str, name: str) -> str:
        match = re.search(r"(?ms)^proc " + re.escape(name) + r"(?=[*(]).*?(?=^proc |\Z)", source)
        return match.group(0) if match else ""

    # Legacy recovery helpers are included when present so this test also
    # demonstrates the old allocator's live-lease reclamation bug.
    names = ["txl_frame_desc_index", "txl_frame_desc_valid", "txl_frame_link_valid",
             "txl_frame_list_contains", "txl_frame_link_list_contains_desc",
             "txl_frame_desc_active", "txl_frame_rebuild_free_list",
             "txl_frame_free_list_pop", "txl_frame_release"]
    procedures = "\n".join(procedure(tx, name) for name in names)
    procedures += procedure(sta, "staPostponedListValid")
    procedures += procedure(sta, "staReleasePostponed")
    procedures += procedure(sta, "sta_mgmt_postponed_desc_release")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", procedures)))
    )
    source = tmp_path / "frame_ownership.nim"
    source.write_text(PLATFORM + debug + procedures + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
