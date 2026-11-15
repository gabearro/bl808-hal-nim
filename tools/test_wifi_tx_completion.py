"""Run production TX confirmation, flush, callback, and release lifecycles."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_frame_ownership import CALLBACK_STUBS, DMA_INVALIDATION_STUBS


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    confirmations, pending, postponed: CoList
  HeadThd = object
    flags: uint32
    confirmType: uint16
  HwDesc = object
    txConfirmDescPtr, status, confirmStatus: uint32
    head: ptr HeadThd
  LinkDesc = object
    macHeader: array[26, uint8]
  HostTxDescView = object
    link: CoListHdr
    hwDesc, bufDesc, dmaLink, queueFirst, cfmDst: pointer
    callback, callbackArg: pointer
    usedFlag, postponeFlag, retryFlag, vifIdx, staIdx, staInfoIdx: uint8
    active: uint32
  TxFrameEnvView = object
    freeList, usedList: CoList
    postponedCount: uint32
  CallbackState = object
    count: int
    statuses: seq[uint32]
    desc: ptr HostTxDescView
    retry: bool
var
  frameEnv: TxFrameEnvView
  txActiveFlush: ptr TxFlushBatch
  confirmLists: array[5, CoList]
  txEnv: tuple[packetCounter: uint32]
  ke_env: array[4, uint32]
  txl_cfm_evt_bit = [0x4000'u32, 0x8000'u32, 0x10000'u32, 0x20000'u32, 0x40000'u32]
  interruptsEnabled = true
  indications: seq[uint32]
  hostCompletions, rateCompletions: seq[pointer]

proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txlFrameSessionCurrent(d: ptr HostTxDescView): bool = true
proc txlFrameLeaseToken(d: ptr HostTxDescView): uint32 = 0
proc txlFrameLeaseMatches(d: ptr HostTxDescView; token: uint32): bool = true
proc txlFrameEndLease(d: ptr HostTxDescView) = discard
proc hostTxHwDescAt(p: pointer): ptr HwDesc = cast[ptr HwDesc](p)
proc hostTxLinkDescAt(p: pointer): ptr LinkDesc = cast[ptr LinkDesc](p)
proc hostTxHeadThd(p: ptr HwDesc): ptr HeadThd = p.head
proc hostTxThdConfirmAt(p: ptr HeadThd): ptr HeadThd = p
proc hostTxConfirmLinkWord(d: ptr HostTxDescView): ptr uint32 = addr d.active
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc txControlEnv(): ptr tuple[packetCounter: uint32] = addr txEnv
proc txFrameEnv(): ptr TxFrameEnvView = addr frameEnv
proc txCfmList(ac: uint32): ptr CoList = addr confirmLists[ac]
proc nimFwMgmtFcTrace(fc: uint8): bool = false
proc nimFwTrace2U32(s: string; a, b: uint32) = discard
proc nimFwConnectTrace2U32(s: string; a, b: uint32) = discard
proc noteMgmtTxConfirm(d: ptr HostTxDescView; status, phase: uint32) = discard
proc assert_err(cond, file: cstring; line: int) = doAssert false, "unexpected firmware assertion"
proc ke_evt_set(bits: uint32) = ke_env[0] = ke_env[0] or bits
proc ke_evt_clear(bits: uint32) = ke_env[0] = ke_env[0] and not bits
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  var present = list.first
  while present != nil:
    doAssert present != node, "descriptor inserted twice"
    present = present.next
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): pointer =
  let node = list.first
  if node == nil: return nil
  list.first = node.next
  if list.first == nil: list.last = nil
  node.next = nil
  cast[pointer](node)
proc listCount(list: CoList): int =
  var node = list.first
  while node != nil:
    inc result
    doAssert result < 20, "list cycle"
    node = node.next
proc me_tx_cfm_singleton(p: pointer) =
  doAssert not interruptsEnabled
  rateCompletions.add(p)
proc ipc_emb_txcfm(p: pointer) =
  doAssert not interruptsEnabled
  hostCompletions.add(p)
proc ipc_emb_txcfm_ind(mask: uint32) = indications.add(mask)

proc callback(arg: pointer; status: uint32) {.cdecl.} =
  doAssert interruptsEnabled
  let state = cast[ptr CallbackState](arg)
  inc state.count
  state.statuses.add(status)
  if state.retry and state.count == 1:
    doAssert listCount(frameEnv.freeList) == 0
    state.desc.retryFlag = 1
    hostTxHwDescAt(state.desc.hwDesc).confirmStatus = 0x99887766'u32
    inc txEnv.packetCounter
    co_list_push_back(addr frameEnv.usedList, addr state.desc.link)
"""

PLATFORM += CALLBACK_STUBS + DMA_INVALIDATION_STUBS

CHECKS = r"""
proc reset() =
  frameEnv = default(TxFrameEnvView)
  confirmLists = default(typeof(confirmLists))
  txEnv.packetCounter = 0
  ke_env = default(typeof(ke_env))
  indications.setLen(0)
  hostCompletions.setLen(0)
  rateCompletions.setLen(0)
  interruptsEnabled = true

proc initDesc(desc: var HostTxDescView; hw: var HwDesc; head: var HeadThd;
              output: var uint32; host: bool) =
  desc = HostTxDescView(hwDesc: addr hw, cfmDst: addr output, active: 1)
  hw = HwDesc(head: addr head, confirmStatus: 0x11223344)
  head = HeadThd(flags: 0x81000001'u32)
  output = 0xDEADBEEF'u32
  if host:
    desc.queueFirst = cast[pointer](1)
    desc.bufDesc = cast[pointer](2)
    desc.usedFlag = 1

# Every AC must drain only its own queue and preserve unrelated event bits.
for ac in 0'u8 .. 4'u8:
  reset()
  var desc: array[2, HostTxDescView]
  var hw: array[2, HwDesc]
  var head: array[2, HeadThd]
  var output: array[2, uint32]
  txEnv.packetCounter = 2
  ke_env[0] = 0x1000
  for i in 0 ..< 2:
    initDesc(desc[i], hw[i], head[i], output[i], true)
    desc[i].bufDesc = nil
    txl_cfm_push(addr desc[i], 0x81001230'u32 + i.uint32 * 2, ac.uint32)
  doAssert listCount(confirmLists[ac]) == 2
  txl_cfm_evt(ac)
  doAssert confirmLists[ac].first == nil
  doAssert txEnv.packetCounter == 0 and ke_env[0] == 0x1000
  doAssert indications == @[(1'u32 shl ac), (1'u32 shl ac)]
  doAssert hostCompletions == @[cast[pointer](addr desc[0]), cast[pointer](addr desc[1])]
  doAssert rateCompletions == hostCompletions
  for i in 0 ..< 2:
    doAssert output[i] == (0x81001231'u32 + i.uint32 * 2)
    doAssert head[i].confirmType == 0x0101 and desc[i].active == 0

# The host path of single-descriptor flush must also drain internal work.
for ac in 0'u8 .. 4'u8:
  for dmaOwned in [false, true]:
    for initialStatus in [0'u32, 0x00800000'u32, 0x81000000'u32]:
      for host in [false, true]:
        reset()
        var desc: array[2, HostTxDescView]
        var hw: array[2, HwDesc]
        var head: array[2, HeadThd]
        var output: array[2, uint32]
        var contexts: array[2, CallbackState]
        for i in 0 ..< 2:
          initDesc(desc[i], hw[i], head[i], output[i], i == 0 and host)
          contexts[i].desc = addr desc[i]
          if i != 0 or not host:
            desc[i].callback = cast[pointer](callback)
            desc[i].callbackArg = addr contexts[i]
        head[0].flags = initialStatus
        if dmaOwned: desc[0].dmaLink = cast[pointer](1)
        txEnv.packetCounter = 2
        txl_frame_cfm(addr desc[1])
        txl_cfm_flush_desc(ac, addr desc[0], 0x40000000'u32)
        doAssert txEnv.packetCounter == 0
        doAssert frameEnv.usedList.first == nil
        doAssert contexts[1].statuses == @[0x11223344'u32]
        let expectedFlags = if dmaOwned: 0x7C000000'u32
          elif (initialStatus and 0x80000000'u32) != 0: initialStatus
          else: 0x40000000'u32
        if host:
          doAssert contexts[0].count == 0
          doAssert indications == @[(1'u32 shl ac)]
          doAssert output[0] == (expectedFlags or 1)
          doAssert desc[0].bufDesc == nil
          doAssert listCount(frameEnv.freeList) == 1
        else:
          doAssert contexts[0].statuses == @[0x11223344'u32]
          doAssert indications.len == 0 and hostCompletions.len == 0
          doAssert head[0].flags == expectedFlags
          doAssert listCount(frameEnv.freeList) == 2

# Batch flush delivers host notifications together, after internal callbacks.
for ac in 0'u8 .. 4'u8:
  reset()
  var desc: array[3, HostTxDescView]
  var hw: array[3, HwDesc]
  var head: array[3, HeadThd]
  var output: array[3, uint32]
  var context: CallbackState
  var list: CoList
  for i in 0 ..< 3:
    initDesc(desc[i], hw[i], head[i], output[i], i != 1)
    desc[i].dmaLink = cast[pointer](1)
    co_list_push_back(addr list, addr desc[i].link)
  context.desc = addr desc[1]
  desc[1].callback = cast[pointer](callback)
  desc[1].callbackArg = addr context
  txEnv.packetCounter = 3
  txl_cfm_flush(ac, addr list, 0x40000000'u32)
  doAssert list.first == nil and frameEnv.usedList.first == nil
  doAssert context.statuses == @[0x11223344'u32]
  doAssert listCount(frameEnv.freeList) == 1
  doAssert hostCompletions == @[cast[pointer](addr desc[0]), cast[pointer](addr desc[2])]
  doAssert indications == @[(1'u32 shl ac)]
  doAssert txEnv.packetCounter == 0
  doAssert output[0] == 0x7C000001'u32 and output[2] == 0x7C000001'u32

# Direct release is controlled explicitly, without relying on register a1.
for external in [false, true]:
  for notify in [false, true]:
    for hasCallback in [false, true]:
      reset()
      var desc: HostTxDescView
      var context = CallbackState(desc: addr desc)
      if external: desc.usedFlag = 1
      if hasCallback:
        desc.callback = cast[pointer](callback)
        desc.callbackArg = addr context
      txl_frame_release(addr desc, notify)
      doAssert context.count == (if notify and hasCallback: 1 else: 0)
      if context.count != 0: doAssert context.statuses == @[0'u32]
      doAssert listCount(frameEnv.freeList) == (if external: 0 else: 1)

# A callback that resubmits the same frame must not return it to the pool
# before the retried transmission finishes.
reset()
var retried: HostTxDescView
var retryHw: HwDesc
var retryHead: HeadThd
var retryOutput: uint32
initDesc(retried, retryHw, retryHead, retryOutput, false)
var retryContext = CallbackState(desc: addr retried, retry: true)
retried.callback = cast[pointer](callback)
retried.callbackArg = addr retryContext
txEnv.packetCounter = 1
txl_frame_cfm(addr retried)
txl_frame_evt()
doAssert retryContext.statuses == @[0x11223344'u32, 0x99887766'u32]
doAssert listCount(frameEnv.freeList) == 1
doAssert frameEnv.usedList.first == nil and retried.retryFlag == 0
doAssert txEnv.packetCounter == 0 and interruptsEnabled
"""


@pytest.mark.parametrize("trace", [False, True])
def test_tx_completion_lifecycle(tmp_path: Path, trace: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    base = ROOT / "src/bl808/wifi/fw"
    tx = (base / "tx_layer.nim").read_text()
    upper = (base / "tx_upper.nim").read_text()

    def procedure(source: str, name: str, next_name: str) -> str:
        return "proc " + name + source.split("proc " + name, 1)[1].split(
            "\nproc " + next_name, 1
        )[0]

    procedures = "\n".join([
        procedure(upper, "txu_cntrl_cfm*", "txu_cntrl_tkip_mic_append*"),
        procedure(tx, "txl_frame_release*", "txlFrameConfirmPending"),
        procedure(tx, "txlFrameConfirmPending", "txl_frame_evt*"),
        procedure(tx, "txl_frame_evt*", "txl_frame_send_null_frame*"),
        procedure(tx, "txl_frame_cfm*", "txl_frame_release*"),
        procedure(tx, "txl_cfm_push*", "txlCfmPending"),
        procedure(tx, "txlCfmPending", "txl_cfm_evt*"),
        procedure(tx, "txl_cfm_evt*", "txl_cfm_flush*"),
        procedure(tx, "txl_cfm_flush*", "txl_cfm_flush_desc*"),
        procedure(tx, "txl_cfm_flush_desc*", "txl_cfm_dump*"),
    ])
    debug_vars = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", procedures)))
    )
    source = tmp_path / "tx_completion_test.nim"
    source.write_text(PLATFORM + debug_vars + procedures + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}"]
    if trace:
        command.append("-d:bl808WifiConnectTrace")
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
