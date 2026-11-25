"""Drive scan admission, both channel notifications, and the lower task together."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_probe_timer import _scan_end_source


def source() -> str:
    tasks = (FW / "task_handlers.nim").read_text()
    code = _scan_end_source().replace('  events.add("next")', '''  events.add("next")
  doAssert chanScanPoolOverlay().slot == 0xFF
  chanScanPoolOverlay().slot = 3
  inc chanCtxtEpochs[3]
  state = 2''', 1)
    code += r'''
const
  ScanChannelPendingState = 2'u8
  SCAN_STATUS_OK = 0'u8
  SCAN_STATUS_BUSY = 8'u8
  SCAN_STATUS_BAD_PARAM = 4'u8
var
  upperRequest: uint8
  downloadHook: proc()
  nimFwDbgScanStartRxCtrl, nimFwDbgScanStartIrqRaw, nimFwDbgScanStartGenRaw, nimFwDbgScanStartPhyRaw: uint32
proc scanStartRequestValid(n: uint32; req: ptr ScanReq): bool = n == sizeof(ScanReq).uint32
proc cacheScanStartDurations(req: ptr ScanReq) = discard
proc scan_ie_download(p: pointer) =
  if downloadHook != nil:
    let hook = downloadHook
    downloadHook = nil
    hook()
  else: scan_set_channel_request()
proc applyScanChannelRxFilter(flags: uint8) = events.add("enter")
proc scheduleActiveScanProbeTimer(p: pointer; epoch: uint32; channel: uint8): bool = true
proc enterScanChannelRunningState() = state = ScanChannelRunningState
'''
    for name in ("cacheScanStartContext", "sendScanStartConfirmation", "finishAcceptedScanStartReq",
                 "scan_start_req_handler", "mm_scan_channel_start_ind_handler"):
        code += procedure(tasks, name)
    return code + r'''
proc take(): pointer =
  result = queued[0]
  queued.delete(0)
proc consume(p: pointer) = ke_msg_free(keMsgHdrFromPayload(p))
proc newRequest(count: uint8): pointer =
  result = ke_msg_alloc(0x400, TASK_SCAN, TASK_SCANU, sizeof(ScanReq).uint32)
  scanStartReqView(result).channelCount = count
  scanu_env.paramPtr = addr upperRequest
  inc scanuRequestEpoch
  scanuLower = ScanuLowerExchange(request: result, epoch: scanuRequestEpoch)
proc checkStatus(p: pointer; status: uint8) =
  let h = keMsgHdrFromPayload(p)
  doAssert (h.id,h.srcId,h.destId,h.paramLen) == (SCAN_START_CFM,TASK_SCAN,TASK_SCANU,1'u32)
  doAssert statusCfmView(p).status == status
proc fresh() =
  doAssert allocated.len == 0 and queued.len == 0 and scanDwellPostedHead == nil
  reset()
  failAtCall = 0
  state = ScanIdleState
  chanScanPoolOverlay().slot = 0xFF
  scan_env = default(ScanEnv)
  resetDwell()
  events.setLen(0)
proc admitted(count: uint8): pointer =
  fresh()
  result = newRequest(count)
  doAssert scan_start_req_handler(result) == KeMsgNoFree and state == ScanChannelPendingState
  let cfm = take()
  checkStatus(cfm, SCAN_STATUS_OK)
  doAssert scanuClaimLowerReply(cfm, done = false)
  consume(cfm)
proc publishDwell(endFirst = false) =
  let slot = chanCtxtEpochs[3]
  let allocs = allocationCalls
  failAllocation = true
  scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot - 1)
  if endFirst: scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
  scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot)
  scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot)
  scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
  chanScanPoolOverlay().slot = 0xFF
  inc chanCtxtEpochs[3] # Slot is retired before the task drains its FIFO.
  doAssert allocationCalls == allocs and queued.len == 2
  for i,id in [MM_SCAN_CHANNEL_START_IND, MM_SCAN_CHANNEL_END_IND]:
    let h = keMsgHdrFromPayload(queued[i])
    doAssert (h.id,h.srcId,h.destId,h.paramLen) == (id,TASK_NONE,TASK_SCAN,0'u32)
  let start = take()
  doAssert mm_scan_channel_start_ind_handler(start) == KeMsgConsumed and state == ScanChannelRunningState
  consume(start)
  failAllocation = false
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_dwell_notices(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
fresh()
let inlineFailure = newRequest(1)
downloadHook = proc() =
  state = ScanChannelRunningState
  doAssert releaseCompletedScanRequest(inlineFailure, failed = true)
doAssert scan_start_req_handler(inlineFailure) == KeMsgNoFree
doAssert queued == @[inlineFailure] and state == ScanIdleState
checkStatus(inlineFailure, SCAN_STATUS_FAIL)
doAssert scanuClaimLowerReply(take(), done = false)
consume(inlineFailure)

for failed in [1, 2]:
  fresh()
  let lower = newRequest(2)
  failAtCall = allocationCalls + 1 + failed # after START_CFM
  doAssert scan_start_req_handler(lower) == KeMsgConsumed and state == ScanIdleState
  let cfm = take()
  checkStatus(cfm, SCAN_STATUS_FAIL)
  doAssert scan_env.paramPtr == nil and allocated.len == 2
  consume(cfm)
  consume(lower)

for failed in [0, 1, 2]:
  let lower = admitted(2)
  publishDwell()
  let firstEnd = take()
  if failed != 0: failAtCall = allocationCalls + failed
  doAssert mm_scan_channel_end_ind_handler(firstEnd) == KeMsgConsumed
  consume(firstEnd)
  if failed != 0:
    let cfm = take()
    doAssert cfm == lower and state == ScanIdleState and scan_env.paramPtr == nil
    checkStatus(cfm, SCAN_STATUS_FAIL)
    doAssert scanuClaimLowerReply(cfm, done = false)
    consume(cfm)
  else:
    doAssert queued.len == 0 and scan_env.channelIndex == 1 and state == ScanChannelPendingState
    publishDwell(endFirst = true)
    let lastEnd = take()
    failAllocation = true
    doAssert mm_scan_channel_end_ind_handler(lastEnd) == KeMsgNoFree
    doAssert queued == @[lastEnd] and keMsgHdrFromPayload(lastEnd).id == SCAN_DONE_IND
    let done = take()
    doAssert scanuClaimLowerReply(done, done = true)
    doAssert not scanuClaimLowerReply(done, done = true)
    consume(done)
  doAssert allocated.len == 0 and assertions == 0

# Abort while the second pair is being reserved: do not submit another dwell.
discard admitted(2)
publishDwell()
let earlyEnd = take()
allocHook = proc() = scan_env.abortFlag = 1
doAssert mm_scan_channel_end_ind_handler(earlyEnd) == KeMsgNoFree
doAssert queued == @[earlyEnd] and state == ScanIdleState
consume(take())
doAssert allocated.len == 0

# A synchronously dispatched END must not submit a next channel into an
# occupied singleton slot, even when it successfully reserved both messages.
let busyLower = admitted(2)
publishDwell()
chanScanPoolOverlay().slot = 3
let busyEnd = take()
doAssert mm_scan_channel_end_ind_handler(busyEnd) == KeMsgConsumed
consume(busyEnd)
doAssert queued == @[busyLower] and state == ScanIdleState
checkStatus(queued[0], SCAN_STATUS_FAIL)
consume(take())
doAssert allocated.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_partial_dwell_reset(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = source().replace("  doAssert offset == 0xB8", "  if offset == 188: return nil\n  doAssert offset == 0xB8")
    code += r'''
var scan_probe_req_ie: tuple[magic, probeIeStateWord, writeOffset: uint32,
                             ieDataPtr: pointer, ieData: array[200, uint8]]
proc nimFwTrace(s: cstring) = discard
var keTimerQueue: seq[pointer]
var keSavedReschedTask: uint8
var keSavedReschedMask, keSavedReschedRemaining: uint32
proc co_list_init(q: ptr seq[pointer]) = q[].setLen(0)
proc first(q: seq[pointer]): ptr KeMsgHdr =
  if q.len != 0: return keMsgHdrFromPayload(q[0])
proc co_list_pop_front(q: ptr seq[pointer]): ptr KeMsgHdr =
  result = q[].first
  q[].delete(0)
const MAX_VIFS = 2
proc ke_evt_clear(bits: uint32) = discard
proc mmConfigCancelIdle() = discard
proc keTimerCancelMutations(all: bool) = discard
proc smRspTimerReset() = discard
template smSaQueryResetScope() = discard
proc chanSwitchReset() = discard
proc smActivationCancel() = discard
proc smBssCancel() = discard
proc smCleanupCancel() = discard
proc smDeferredCancel() = discard
proc mmPsModeCancel() = discard
proc meControlReset() = discard
proc apmCancelPendingForVif(vif: uint8) = discard
proc mm_bcn_flush_updates(all: bool) = discard
type ChanEnvView = object
  freeList, tbttSwitchCallback, cdeCallback, cdeArg, ctxtOpCallback, connLessDelayCallback: pointer
var env: ChanEnvView
var chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
var chanCtxtCount, chanCtxtFlags, chanConflictCount, chanSlotConfigCycles, cde_evt_tmr_msg: uint8
var chanCurrentCtxt, chanPendingCtxt: pointer
var chanConflictDetected, chanScanPending: bool
proc chanEnvView(): ptr ChanEnvView = addr env
proc chanCtxtAt(p: uint): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtHdr(ctxt: ptr ChanCtxtView): pointer = ctxt
proc co_list_push_back(q: ptr pointer; node: pointer) = discard
proc chan_tbtt_switch_evt() = discard
proc chan_cde_evt() = discard
proc chan_ctxt_op_evt() = discard
proc chan_conn_less_delay_evt() = discard
proc chanBcnRequestReset() = discard
''' + procedure((FW / "layout_types.nim").read_text(), "markInvalid").split("\ntype\n")[0] + "\n"
    code += procedure(scan, "scan_init") + "".join(procedure(kernel, n) for n in ("ke_init", "ke_flush", "chan_init"))
    run_program(tmp_path, mode, code + r'''
# Reset before admission, between the two reservation allocations: the
# dispatcher still owns this lower request and must consume it exactly once.
fresh()
let offered = newRequest(1)
allocHook = proc() =
  allocHook = proc() =
    allocHook = proc() = scan_init()
doAssert scan_start_req_handler(offered) == KeMsgConsumed
checkStatus(queued[0], SCAN_STATUS_BUSY)
consume(take())
doAssert allocated == @[cast[pointer](keMsgHdrFromPayload(offered))]
consume(offered)

# Reset inside download, after admission but before handler return.
fresh()
let committed = newRequest(1)
downloadHook = proc() = scan_init()
doAssert scan_start_req_handler(committed) == KeMsgNoFree
doAssert scan_env.paramPtr == nil and state == ScanIdleState
checkStatus(queued[0], SCAN_STATUS_FAIL)
consume(take())
doAssert allocated.len == 0

for resetModule in [scan_init, ke_init, ke_flush, chan_init]:
  for published in 0..2:
    for popped in 0..published:
      discard admitted(1)
      let slot = chanCtxtEpochs[3]
      if published >= 1: scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot)
      if published == 2:
        scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
        chanScanPoolOverlay().slot = 0xFF
        inc chanCtxtEpochs[3] # Channel operation retired its own slot.
      var inflight: seq[pointer]
      for i in 0..<popped: inflight.add(take())
      if queued.len != 0: savedQueue.add(take())
      let reusable = published == 2 or resetModule == chan_init
      # The free hook can offer a new request. Logical reset alone cannot
      # promise slot 3 while the previous radio operation still occupies it.
      var replacement: pointer
      freeHook = proc() =
        doAssert state == ScanIdleState and scan_env.paramPtr == nil
        replacement = newRequest(1)
        let res = scan_start_req_handler(replacement)
        if reusable: doAssert res == KeMsgNoFree
        else:
          doAssert res == KeMsgConsumed
          consume(replacement)
      resetModule()
      doAssert savedQueue.len == 0 and queued.len == 1
      checkStatus(queued[0], if reusable: SCAN_STATUS_OK else: SCAN_STATUS_BUSY)
      consume(take())
      if not reusable:
        chanScanPoolOverlay().slot = 0xFF
        inc chanCtxtEpochs[3]
        replacement = newRequest(1)
        doAssert scan_start_req_handler(replacement) == KeMsgNoFree
        checkStatus(queued[0], SCAN_STATUS_OK)
        consume(take())
      for i,p in inflight:
        if i == 0: doAssert mm_scan_channel_start_ind_handler(p) == KeMsgConsumed
        else: doAssert mm_scan_channel_end_ind_handler(p) == KeMsgConsumed
        consume(p)
      doAssert state == ScanChannelPendingState and scan_env.paramPtr == replacement
      scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
      doAssert assertions == 0 and queued.len == 0 and allocated.len == 3
      resetModule()
      doAssert scan_env.paramPtr == nil and scanDwellPostedHead == nil and allocated.len == 0

# An unrelated direct caller's request is not a retained KE allocation.
fresh()
scan_env.paramPtr = addr req
scan_init()
doAssert scan_env.paramPtr == nil and allocated.len == 0

# Even an admitted pointer is not reset-owned once its epoch no longer agrees.
let borrowed = admitted(1)
inc scanRequestEpoch
scan_init()
doAssert allocated == @[cast[pointer](keMsgHdrFromPayload(borrowed))]
consume(borrowed)
''')
