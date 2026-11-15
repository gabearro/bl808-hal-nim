"""Retain interrupted TX flush batches until reset can finish their cleanup."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_retirement_preflight import source as preflight_source
from test_wifi_tx_reset_batch import source as reset_source


def source() -> str:
    code = preflight_source()
    if "proc txlFlushScopeExit(" in code:
        code = code.replace(procedure(code, "txlFlushScopeExit"), "", 1)
    support = r'''
var recoveryState: tuple[resetInProgress: uint8]
var txRecoveryPostponed: CoList
var events: uint32
var invalidations, disabled, visits, failVisit: int
proc txControlEnv(): ptr typeof(recoveryState) = addr recoveryState
proc txlInvalidateDmaAll() = inc invalidations
proc hal_machw_disable_int() =
  doAssert not irq
  inc disabled
proc ke_evt_set(mask: uint32) =
  doAssert not irq
  events = events or mask
'''
    code = code.replace("proc irqSave()", support + "proc irqSave()", 1)
    code = code.replace(procedure(code, "txlResetting"),
                        "proc txlResetting(): bool = recoveryState.resetInProgress != 0\n", 1)
    code = code.replace(procedure(code, "txl_cfm_flush"), r'''
proc txl_cfm_flush(ac: uint8; queue: ptr CoList; status: uint32) =
  doAssert not irq and status == 0x40000000'u32
  inc visits
  if visits == failVisit:
    if onFlush != nil: onFlush()
    raise newException(ValueError, "flush callback stopped")
  while queue.first != nil:
    inc completed
    queue.first = queue.first.next
  queue.last = nil
''', 1)
    tx = (FW / "tx_layer.nim").read_text()
    if "proc txlFlushScopeExit(" in tx:
        lists = (FW / "kernel_mac_channel.nim").read_text()
        helper = procedure(lists, "co_list_concat") + procedure(tx, "txlFlushScopeExit")
        code = code.replace("proc txlDetachAc(", helper + "proc txlDetachAc(", 1)
    return code + r'''
proc resetRecovery() =
  recoveryState.resetInProgress = 0
  txRecoveryPostponed = default(CoList)
  events = 0
  invalidations = 0
  disabled = 0
  visits = 0
  failVisit = 0
proc queueCount(queue: CoList): int =
  var node = queue.first
  var last: ptr CoListHdr
  while node != nil:
    inc result
    doAssert result <= 20
    last = node
    node = node.next
  doAssert queue.last == last
proc reachable(): int =
  for ac in 0 ..< NUM_TX_QUEUES:
    result += queueCount(controls[ac].pending) + queueCount(confirmations[ac])
  result += queueCount(txRecoveryPostponed)
proc flush(kind: int) =
  if kind != 3:
    retire(kind)
  else:
    let saved = irqSave()
    defer: irqRestore(saved)
    doAssert txl_cntrl_halt_ac(3)
    txl_cntrl_flush_ac(3, 0x40000000'u32)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_interrupted_scope_keeps_all_unprocessed_frames_reachable(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 3:
  for incoming in [false, true]:
    for failure in 1 .. (if kind == 3: 2 else: 10):
      setup((if kind == 3: 8'u32 else: 31'u32), incoming)
      resetRecovery()
      failVisit = failure
      var raised = false
      try: flush(kind)
      except ValueError: raised = true
      doAssert raised and visits == failure and irq == incoming
      doAssert completed + reachable() == 10, "interrupted flush lost detached frames"
      doAssert txActiveFlush == nil and txSecurityUpdating == 0
      doAssert recoveryState.resetInProgress == 1
      doAssert events == 0x80000000'u32 and invalidations == 1 and disabled == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_unwind_preserves_ancestor_and_new_live_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 2:
  for incoming in [false, true]:
    setup(31, incoming)
    resetRecovery()
    var ancestor: TxFlushBatch
    var outerFrame, fresh: HostTxDescView
    ancestor.pending = CoList(first: addr outerFrame.link, last: addr outerFrame.link)
    txActiveFlush = addr ancestor
    failVisit = 1
    onFlush = proc() =
      co_list_push_back(addr controls[4].pending, addr fresh.link)
      controls[4].current = addr fresh
      buffers.backupQueues[4] = controls[4].pending
    var raised = false
    try: flush(kind)
    except ValueError: raised = true
    doAssert raised and txActiveFlush == (addr ancestor)
    doAssert ancestor.pending.first == (addr outerFrame.link)
    doAssert ancestor.pending.last == (addr outerFrame.link)
    doAssert reachable() == 11
    doAssert controls[4].pending.first == (addr fresh.link)
    doAssert controls[4].pending.last == (addr frames[8].link)
    doAssert fresh.link.next == (addr frames[8].link)
    doAssert controls[4].current == (addr fresh)
    doAssert buffers.backupQueues[4].first == (addr fresh.link)
    doAssert recoveryState.resetInProgress == 1 and irq == incoming
    txActiveFlush = nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_key_update_honors_recovery_without_live_ac_entries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0, true)
resetRecovery()
controls = default(typeof(controls))
confirmations = default(typeof(confirmations))
var postponed: HostTxDescView
co_list_push_back(addr txRecoveryPostponed, addr postponed.link)
recoveryState.resetInProgress = 1
doAssert not txSecurityBeginUpdate(addr targetKey)
doAssert txSecurityUpdating == 0 and halted == 0 and detached == 0
doAssert txRecoveryPostponed.first == (addr postponed.link)
doAssert irq
recoveryState.resetInProgress = 0
txRecoveryPostponed = default(CoList)
doAssert txSecurityBeginUpdate(addr targetKey)
txSecurityEndUpdate(addr targetKey)
doAssert txSecurityUpdating == 0 and irq
''')


def integrated_source() -> str:
    code = reset_source()
    if "txRecoveryPostponed: CoList" not in code:
        code = code.replace("var\n", "var\n  txRecoveryPostponed: CoList\n", 1)
    if "proc txlFlushScopeExit(" in code:
        code = code.replace(procedure(code, "txlFlushScopeExit"), "", 1)
    code = code.replace(procedure(code, "hal_machw_disable_int"),
                        "proc hal_machw_disable_int() = discard\n", 1)
    tx = (FW / "tx_layer.nim").read_text()
    lists = (FW / "kernel_mac_channel.nim").read_text()
    helper = procedure(lists, "co_list_concat") + procedure(tx, "txlFlushScopeExit")
    code = code.replace("proc txl_cntrl_flush_ac*", helper + "proc txl_cntrl_flush_ac*", 1)
    return code + r'''
var
  frames: array[6, HostTxDescView]
  hardware: array[6, HwDesc]
  heads: array[6, HeadThd]
  outputs: array[6, uint32]
  completions: array[6, int]
  failIndex: int
  callbackIrq: bool
proc completed(arg: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  let index = cast[uint](arg).int - 1
  doAssert interruptsEnabled == callbackIrq
  inc completions[index]
  if index == failIndex:
    failIndex = -1
    raise newException(ValueError, "completion interrupted cleanup")
proc setup(incoming: bool) =
  callbackIrq = false
  interruptsEnabled = incoming
  frames = default(typeof(frames))
  hardware = default(typeof(hardware))
  heads = default(typeof(heads))
  outputs = default(typeof(outputs))
  completions = default(typeof(completions))
  frameEnv = default(TxFrameEnvView)
  txEnv = default(TxControlEnvView)
  confirmLists = default(typeof(confirmLists))
  buffers = default(BufferEnv)
  txRecoveryPostponed = default(CoList)
  txActiveFlush = nil
  txResetActive = false
  hardwareResets = 0
  failIndex = -1
  ke_env = default(typeof(ke_env))
  hostCompletions.setLen(0)
  indications.setLen(0)
  hostHook = nil
  active = 31
  for i in 0 ..< frames.len:
    frames[i].hwDesc = addr hardware[i]
    frames[i].cfmDst = addr outputs[i]
    frames[i].callback = cast[pointer](completed)
    frames[i].callbackArg = cast[pointer](i + 1)
    hardware[i].head = addr heads[i]
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_real_clear_error_retains_pending_work_for_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, integrated_source() + r'''
for incoming in [false, true]:
  setup(incoming)
  for i in [1, 3]:
    frames[i].queueFirst = cast[pointer](1)
    frames[i].usedFlag = 1
  for i in 0 .. 1: co_list_push_back(addr confirmLists[2], addr frames[i].link)
  for i in 2 .. 3: co_list_push_back(addr txEnv.ac[2].pending, addr frames[i].link)
  txEnv.packetCounter = 4
  failIndex = 0
  var raised = false
  try: discard txl_cntrl_clear_ac(2)
  except ValueError: raised = true
  doAssert raised and completions == [1, 0, 0, 0, 0, 0]
  doAssert txActiveFlush == nil and interruptsEnabled == incoming
  doAssert txEnv.ac[2].pending.first == (addr frames[2].link)
  doAssert txEnv.ac[2].pending.last == (addr frames[3].link)
  doAssert txEnv.packetCounter == 2 and txEnv.resetInProgress == 1
  doAssert (ke_env[0] and 0x80000000'u32) != 0
  doAssert hostCompletions == @[cast[pointer](addr frames[1])]
  doAssert indications == @[4'u32]
  doAssert txl_reset()
  doAssert hardwareResets == 1 and txEnv.resetInProgress == 0
  doAssert txEnv.packetCounter == 0 and txActiveFlush == nil
  doAssert completions == [1, 0, 1, 0, 0, 0]
  doAssert hostCompletions == @[cast[pointer](addr frames[1]), cast[pointer](addr frames[3])]
  doAssert indications == @[4'u32, 4]
  doAssert listCount(frameEnv.freeList) == 2 and interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_postponed_recovery_survives_another_interrupted_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, integrated_source() + r'''
for incoming in [false, true]:
  setup(incoming)
  var ancestor, inner: TxFlushBatch
  for i in 0 .. 2:
    frames[i].postponeFlag = 1
    co_list_push_back(addr ancestor.postponed, addr frames[i].link)
  frames[3].postponeFlag = 1
  co_list_push_back(addr inner.postponed, addr frames[3].link)
  frameEnv.postponedCount = 4
  inner.previous = addr ancestor
  txActiveFlush = addr inner
  txlFlushScopeExit(addr ancestor)
  doAssert txActiveFlush == (addr ancestor)
  doAssert inner.postponed.first == nil and ancestor.postponed.first != nil
  doAssert listCount(txRecoveryPostponed) == 1 and frameEnv.postponedCount == 4
  txlFlushScopeExit(nil)
  doAssert txActiveFlush == nil and ancestor.postponed.first == nil
  doAssert listCount(txRecoveryPostponed) == 4 and frameEnv.postponedCount == 4
  failIndex = 3
  var raised = false
  try: discard txl_reset()
  except ValueError: raised = true
  doAssert raised and completions == [0, 0, 0, 1, 0, 0]
  doAssert frameEnv.postponedCount == 3 and listCount(txRecoveryPostponed) == 3
  doAssert txEnv.resetInProgress == 1 and not txResetActive
  doAssert (ke_env[0] and 0x80000000'u32) != 0
  doAssert interruptsEnabled == incoming
  doAssert txl_reset()
  doAssert hardwareResets == 1 and txEnv.resetInProgress == 0
  doAssert completions == [1, 1, 1, 1, 0, 0]
  doAssert frameEnv.postponedCount == 0 and txRecoveryPostponed.first == nil
  doAssert listCount(frameEnv.freeList) == 4 and txEnv.packetCounter == 0
  doAssert interruptsEnabled == incoming
''')


def postponed_source() -> str:
    code = integrated_source().replace(
        "    usedFlag, postponeFlag, retryFlag, vifIdx, staIdx, staInfoIdx: uint8\n",
        "    usedFlag, postponeFlag, retryFlag, vifIdx, staIdx, staInfoIdx: uint8\n"
        "    pendingMacTime: uint32\n",
    )
    support = r'''
const MACHW_TIMLO_REG = 0x24B00120'u
type
  StaQueueIdentity = object
    entry: pointer
  Sta = object
    postponedList: CoList
var macTime: uint32
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc staPostponedOwnerCurrent(identity: StaQueueIdentity): bool = true
proc staPostponedListValid(queue: ptr CoList): bool = true
proc regRead(address: uint): uint32
'''
    old = procedure(code, "regRead")
    code = code.replace(old, old.replace(
        "  case address\n", "  if address == MACHW_TIMLO_REG: return macTime\n  case address\n", 1
    ), 1)
    code = code.replace("proc regRead(", support + "proc regRead(", 1)
    body = procedure((FW / "sta_management.nim").read_text(), "staReleasePostponed")
    body = procedure((FW / "kernel_mac_channel.nim").read_text(), "co_list_remove") + body
    existing = set(re.findall(r"\bnimFwDbg\w+", code))
    code += "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)) - existing)
    )
    return code + body


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_station_error_preserves_retained_and_unvisited_postponed_frames(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, postponed_source() + r'''
for incoming in [false, true]:
  setup(incoming)
  callbackIrq = incoming
  var station: Sta
  macTime = 200000
  for i in [1, 0, 2]:
    frames[i].postponeFlag = 1
    frames[i].pendingMacTime = (if i == 1: macTime else: 0'u32)
    co_list_push_back(addr station.postponedList, addr frames[i].link)
  frameEnv.postponedCount = 3
  failIndex = 0
  var raised = false
  try: discard staReleasePostponed(StaQueueIdentity(entry: addr station), 0, incoming.uint32 * 8)
  except ValueError: raised = true
  doAssert raised and completions == [1, 0, 0, 0, 0, 0]
  doAssert station.postponedList.first == nil and txActiveFlush == nil
  doAssert frameEnv.postponedCount == 2 and listCount(txRecoveryPostponed) == 2
  doAssert txRecoveryPostponed.first == (addr frames[1].link)
  doAssert txRecoveryPostponed.last == (addr frames[2].link)
  doAssert txEnv.resetInProgress == 1 and interruptsEnabled == incoming
  callbackIrq = false
  doAssert txl_reset()
  doAssert completions == [1, 1, 1, 0, 0, 0]
  doAssert frameEnv.postponedCount == 0 and txRecoveryPostponed.first == nil
  doAssert listCount(frameEnv.freeList) == 3 and txEnv.packetCounter == 0
  doAssert interruptsEnabled == incoming
''')
