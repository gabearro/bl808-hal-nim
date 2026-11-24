"""Check scan-task message, timer, and probe ordering against the vendor."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_abort_logs_function_name(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    handler = procedure(source, "scan_abort_req_handler")
    run_program(tmp_path, mode, r'''
type ScanEnv = object
  paramPtr: pointer
  abortFlag: uint8
const
  TASK_SCAN = 1'u8
  ScanIdleState = 0'u8
  ScanChannelRunningState = 3'u8
  KeMsgConsumed = 0.cint
var
  scan_env: ScanEnv
  state: uint8
  terminations: int
  logs: seq[string]
  loggingEnabled = true
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  state
proc scan_terminate_channel_request() = inc terminations
proc printer(format, name: cstring) {.cdecl, varargs.} =
  doAssert $format == "%s: scan_abort_req_handler done\r\n"
  logs.add($name)
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  if loggingEnabled: cast[pointer](printer) else: nil
''' + handler + r'''
for requestedState in [ScanIdleState, 2'u8, ScanChannelRunningState]:
  scan_env.abortFlag = 0
  state = requestedState
  scan_env.paramPtr = if requestedState == ScanIdleState: nil else: addr scan_env
  doAssert scan_abort_req_handler(nil) == KeMsgConsumed
  doAssert scan_env.abortFlag == uint8(requestedState != ScanIdleState)
  doAssert terminations == int(requestedState == ScanChannelRunningState)
doAssert logs == @["scan_abort_req_handler", "scan_abort_req_handler",
                   "scan_abort_req_handler"]
state = ScanChannelRunningState
scan_env.paramPtr = nil
scan_env.abortFlag = 0
doAssert scan_abort_req_handler(nil) == KeMsgConsumed
doAssert scan_env.abortFlag == 0 and terminations == 1 and logs.len == 4
state = ScanIdleState
scan_env.paramPtr = addr scan_env
scan_env.abortFlag = 0
doAssert scan_abort_req_handler(nil) == KeMsgConsumed
doAssert scan_env.abortFlag == 1 and terminations == 1 and logs.len == 5
loggingEnabled = false
doAssert scan_abort_req_handler(nil) == KeMsgConsumed
doAssert logs.len == 5
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_probe_timer_reports_tx_failure(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    helper = procedure(source, "sendPeriodicScanProbeRequest")
    handler = procedure(source, "scan_probe_req_handler")
    run_program(tmp_path, mode, r'''
const KeMsgConsumed = 0.cint
var
  running: bool
  txStatus: uint8
  txCalls, hookReads: int
  logs: seq[string]
  hookEnabled = true
proc scanTaskInChannelRunningState(): bool = running
proc scan_probe_req_tx(): uint8 =
  inc txCalls
  txStatus
proc printer(format: cstring) {.cdecl, varargs.} = logs.add($format)
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 4
  inc hookReads
  if hookEnabled: cast[pointer](printer) else: nil
''' + helper + handler + r'''
doAssert scan_probe_req_handler(nil) == KeMsgConsumed
doAssert txCalls == 0 and hookReads == 0 and logs.len == 0
running = true
doAssert scan_probe_req_handler(nil) == KeMsgConsumed
doAssert txCalls == 1 and hookReads == 0 and logs.len == 0
txStatus = 1
doAssert scan_probe_req_handler(nil) == KeMsgConsumed
doAssert txCalls == 2 and hookReads == 1
doAssert logs == @["scan_probe_req_tx failed!\r\n"]
hookEnabled = false
doAssert scan_probe_req_handler(nil) == KeMsgConsumed
doAssert txCalls == 3 and hookReads == 2 and logs.len == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_start_reports_failure_before_arming_timer(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    guard = procedure(source, "scanProbeTimerCurrent")
    helper = procedure(source, "scheduleActiveScanProbeTimer")
    run_program(tmp_path, mode, r'''
const
  TASK_SCAN = 1'u8
  SCAN_PROBE_TIMER = 1031'u16
  ScanChannelPendingState = 2'u8
  KE_TIMER_MAX_DELAY = 0x11E1A2FF'u32
type ScanProbeTimerContext = tuple[param: pointer, epoch: uint32, channel: uint8]
var
  txStatus: uint8
  events: seq[string]
  request, replacement: uint8
  scan_env: tuple[paramPtr: pointer, channelIndex: uint8]
  scanRequestEpoch: uint32
  state = ScanChannelPendingState
  timerFails: bool
  scanDuration = 22000'u32
  onTx, onLog, onDuration, onTimer: proc()
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  state
proc scan_probe_req_tx(): uint8 =
  events.add("tx")
  if onTx != nil: onTx()
  txStatus
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert $format == "scan_probe_req_tx f\r\n"
  events.add("log")
  if onLog != nil: onLog()
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 4
  events.add("hook")
  cast[pointer](printer)
proc scan_get_scan_duration(): uint32 =
  events.add("duration")
  if onDuration != nil: onDuration()
  scanDuration
proc ke_timer_try_set(id: uint16; task: uint8; duration: uint32;
                      guard: proc(context: pointer): bool {.nimcall.};
                      context: pointer): bool =
  doAssert id == SCAN_PROBE_TIMER and task == TASK_SCAN and duration == 11000
  doAssert guard(context)
  events.add("timer")
  if onTimer != nil: onTimer()
  if timerFails: false else: guard(context)
''' + guard + helper + r'''
scan_env.paramPtr = addr request
doAssert scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "duration", "timer"]
events.setLen(0)
txStatus = 1
doAssert scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "hook", "log", "duration", "timer"]
events.setLen(0)
txStatus = 0
onTx = proc() =
  scan_env.paramPtr = addr replacement
  inc scanRequestEpoch
doAssert not scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx"]
scan_env.paramPtr = addr request
scanRequestEpoch = 0
onTx = nil
events.setLen(0)
txStatus = 1
onLog = proc() = inc scanRequestEpoch
doAssert not scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "hook", "log"]
scanRequestEpoch = 0
onLog = nil
events.setLen(0)
txStatus = 0
onDuration = proc() = inc scanRequestEpoch
doAssert not scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "duration"]
scanRequestEpoch = 0
onDuration = nil
events.setLen(0)
onTimer = proc() = inc scanRequestEpoch
doAssert not scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "duration", "timer"]
scanRequestEpoch = 0
onTimer = nil
events.setLen(0)
timerFails = true
doAssert scheduleActiveScanProbeTimer(addr request, 0, 0)
doAssert events == @["tx", "duration", "timer"]
for tinyOrOversized in [1'u32, (KE_TIMER_MAX_DELAY + 1) * 2]:
  scanDuration = tinyOrOversized
  events.setLen(0)
  doAssert scheduleActiveScanProbeTimer(addr request, 0, 0)
  doAssert events == @["tx", "duration"]
''')


def _scan_end_source() -> str:
    from test_wifi_auth_frames import layouts
    from test_wifi_message_allocation import PLATFORM
    from test_wifi_scan_start_confirmation import exchange_source

    source = (FW / "task_handlers.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    messages = "".join(procedure(kernel, name) for name in (
        "ke_msg_try_alloc", "ke_msg_alloc", "ke_msg_send_basic", "ke_msg_forward_and_change_id"))
    handler = (procedure(source, "forwardFailedScanDwell") + procedure(source, "releaseCompletedScanRequest")
               + procedure(source, "mm_scan_channel_end_ind_handler"))
    heap = PLATFORM.replace(procedure(PLATFORM, "assert_err"), "")
    heap = heap.replace(procedure(heap, "scanDwellForget"), "")
    heap = heap.replace("  allocated: seq[pointer]", "  failAtCall: int\n  allocHook: proc()\n  allocated: seq[pointer]")
    heap = heap.replace("  if failAllocation:", """  if allocHook != nil:
    let hook = allocHook
    allocHook = nil
    hook()
  if allocationCalls == failAtCall or failAllocation:""")
    notices = kernel[kernel.index("type\n  ScanDwellPair ="):kernel.index("var mmEdcaRefresh:")]
    notices += kernel[kernel.index("proc scanDwellBeginReset("):kernel.index("proc ke_init*(")]
    notices += "proc resetDwell() = scanDwellReset()\n"
    return heap + layouts("ScanChannelEntry", "ScanStartReqPayload") + r'''
type
  ScanEnv = object
    paramPtr: pointer
    channelIndex, abortFlag, requester: uint8
    activeDuration, passiveDuration, joinActiveDuration: uint32
  ScanReq = ScanStartReqPayload
  ChanCtxtView = object
    contextIndexOrMarker, invalidMarker: uint8
const
  TASK_SCAN = 1'u8
  TASK_SCANU = 2'u8
  TASK_NONE = 255'u8
  MM_SCAN_CHANNEL_START_IND = 75'u16
  SCAN_START_CFM = 1025'u16
  SCAN_STATUS_FAIL = 1'u8
  StatusCfmPayloadSize = 1'u32
  ScanIdleState = 0'u8
  ScanChannelRunningState = 3'u8
  MM_SCAN_CHANNEL_END_IND = 77'u16
  SCAN_DONE_IND = 0x402'u16
  SCAN_PROBE_TIMER = 1031'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  MACHW_RX_CNTRL_REG = 0'u32
  MACHW_INTC_STATUS_RAW = 1'u32
  MACHW_INTC_GEN_RAW = 2'u32
var
  scan_env: ScanEnv
  scanu_env: tuple[paramPtr: pointer]
  scanuRequestEpoch: uint32
  req: ScanReq
  replacementReq: ScanReq
  scanRequestEpoch: uint32
  chanCtxtEpochs: array[5, uint32]
  chan_ctxt_pool: array[5, ChanCtxtView]
  events: seq[string]
  traceHook: proc()
  clearHook: proc()
  state = ScanChannelRunningState
  irqEnabled = true
  queued: seq[pointer]
  sendHook, freeHook: proc()
  nimFwDbgScanEndRxCtrl, nimFwDbgScanEndIrqRaw: uint32
  nimFwDbgScanEndGenRaw, nimFwDbgScanEndPhyRaw: uint32
template chanScanPoolOverlay(): untyped =
  cast[ptr tuple[slot: uint8]](addr chan_ctxt_pool[3].contextIndexOrMarker)
chanScanPoolOverlay().slot = 0xFF
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  state
proc assert_err(a, b: cstring; line: cint) =
  doAssert line == 234
  inc assertions
proc irqSave(): uint32 =
  result = irqEnabled.uint32 * 8
  irqEnabled = false
proc irqRestore(saved: uint32) = irqEnabled = (saved and 8) != 0
proc ke_state_set(task, next: uint8) =
  doAssert task == TASK_SCAN
  state = next
proc ke_msg_send(p: pointer) =
  queued.add(p)
  if sendHook != nil:
    let hook = sendHook
    sendHook = nil
    hook()
{.pragma: wifiCtrl.}
proc statusCfmView(p: pointer): ptr tuple[status: uint8] = cast[ptr tuple[status: uint8]](p)
proc scanDwellForget(header: pointer)
proc ke_msg_free(h: ptr KeMsgHdr) =
  scanDwellForget(h)
  let index = allocated.find(cast[pointer](h))
  doAssert index >= 0
  allocated.delete(index)
  free(h)
  if freeHook != nil:
    let hook = freeHook
    freeHook = nil
    hook()
proc ke_timer_clear(id: uint16; task: uint8) =
  doAssert id == SCAN_PROBE_TIMER and task == TASK_SCAN
  events.add("clear")
  if clearHook != nil:
    let hook = clearHook
    clearHook = nil
    hook()
proc clearScanEdcaRxFilter() = events.add("filter")
proc regRead(address: uint32): uint32 = 0
proc snapshotPhyChannel(raw: var uint32) = discard
proc rfPhyTraceCheckpoint(tag: uint32) =
  if traceHook != nil:
    let hook = traceHook
    traceHook = nil
    hook()
proc advanceScanChannelIndex(): uint8 =
  inc scan_env.channelIndex
  scan_env.channelIndex
proc scanStartReqView(p: pointer): ptr ScanReq = cast[ptr ScanReq](p)
proc scanChannelSequenceDone(index, total, abortFlag: uint8): bool =
  index >= total or abortFlag != 0
proc scan_set_channel_request() =
  events.add("next")
type CoListHdr = KeMsgHdr
var savedQueue: seq[pointer]
template keMsgQueueSent: untyped = queued
template keMsgQueueSaved: untyped = savedQueue
proc ke_queue_extract(q: ptr seq[pointer];
    matches: proc(node: ptr CoListHdr; header: pointer): bool {.cdecl.};
    header: pointer): ptr CoListHdr =
  for i,p in q[]:
    let node = keMsgHdrFromPayload(p)
    if matches(node, header):
      q[].delete(i)
      return node
''' + messages + notices + exchange_source() + handler


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_end_clears_probe_timer_before_next_channel(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, _scan_end_source() + r'''
req.channelCount = 2
scan_env.paramPtr = addr req
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert scan_env.channelIndex == 1
doAssert events == @["clear", "filter", "next"]
events.setLen(0)
scan_env.paramPtr = nil
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert events.len == 0 and scan_env.channelIndex == 1
scan_env.paramPtr = addr req
scan_env.channelIndex = 2
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert events.len == 0 and scan_env.channelIndex == 2
state = 0
scan_env.channelIndex = 0
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert assertions == 1 and events.len == 0
doAssert scan_env.channelIndex == 0
state = ScanChannelRunningState
scan_env.paramPtr = addr req
req.channelCount = 2
events.setLen(0)
traceHook = proc() =
  scan_env.paramPtr = addr replacementReq
  inc scanRequestEpoch
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert scan_env.paramPtr == (addr replacementReq) and scan_env.channelIndex == 0
doAssert events == @["clear", "filter"]
scan_env.paramPtr = addr req
events.setLen(0)
traceHook = proc() = inc scanRequestEpoch
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert scan_env.channelIndex == 0 and events == @["clear", "filter"]
scan_env.paramPtr = addr req
events.setLen(0)
clearHook = proc() =
  scan_env.paramPtr = addr replacementReq
  inc scanRequestEpoch
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert scan_env.paramPtr == addr replacementReq
doAssert scan_env.channelIndex == 0 and events == @["clear"]
scan_env.paramPtr = addr req
events.setLen(0)
clearHook = proc() = inc scanRequestEpoch
doAssert mm_scan_channel_end_ind_handler(nil) == KeMsgConsumed
doAssert scan_env.channelIndex == 0 and events == @["clear"]
resetDwell()
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_end_message_ownership(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, _scan_end_source() + r'''
proc beginDwell(aborting: bool; requester = TASK_SCANU): pointer =
  doAssert allocated.len == 0 and queued.len == 0
  reset()
  let lower = ke_msg_alloc(0x400, TASK_SCAN, requester, sizeof(ScanReq).uint32)
  scanStartReqView(lower).channelCount = 2
  inc scanRequestEpoch
  scan_env = ScanEnv(paramPtr: lower, requester: requester, abortFlag: aborting.uint8,
                     channelIndex: (not aborting).uint8)
  state = ScanChannelRunningState
  ke_msg_alloc(MM_SCAN_CHANNEL_END_IND, TASK_SCAN, 255, 0)

proc checkDone(p: pointer; requester: uint8) =
  let h = keMsgHdrFromPayload(p)
  doAssert (h.id, h.destId, h.srcId, h.paramLen) == (SCAN_DONE_IND, requester, TASK_SCAN, 0'u32)

proc replaceScan() =
  doAssert scan_env.paramPtr == nil
  inc scanRequestEpoch
  scan_env = ScanEnv(paramPtr: addr replacementReq, requester: 7, abortFlag: 1)
  state = 2

for irq in [false, true]:
  for aborting in [false, true]:
    for boundary in 0 .. 2:
      irqEnabled = irq
      let requester = if aborting: 4'u8 else: TASK_SCANU # saved source, not END.srcId
      let incoming = beginDwell(aborting, requester)
      let lower = scan_env.paramPtr
      let epoch = scanRequestEpoch
      let initialAllocs = allocationCalls
      failAllocation = true
      if boundary == 1:
        sendHook = proc() =
          doAssert keMsgHdrFromPayload(lower) in allocated and state == ScanChannelRunningState
          doAssert queued == @[incoming]
          checkDone(incoming, requester)
          ke_msg_free(keMsgHdrFromPayload(queued.pop())) # recipient consumed it inline
          replaceScan()
      elif boundary == 2:
        freeHook = proc() =
          doAssert queued == @[incoming] and state == ScanIdleState and irqEnabled == irq
          checkDone(incoming, requester)
          replaceScan()
      doAssert mm_scan_channel_end_ind_handler(incoming) == KeMsgNoFree
      doAssert allocationCalls == initialAllocs and assertions == 0 and irqEnabled == irq
      if boundary == 0:
        doAssert state == ScanIdleState and scan_env.paramPtr == nil and scan_env.abortFlag == 0
        doAssert scanRequestEpoch == epoch + 1
      else:
        doAssert state == 2 and scan_env.paramPtr == (addr replacementReq) and scan_env.abortFlag == 1
        doAssert scanRequestEpoch == epoch + 2
      if boundary != 1:
        doAssert queued == @[incoming] and allocated.len == 1
        checkDone(incoming, requester)
        ke_msg_free(keMsgHdrFromPayload(queued.pop()))
      doAssert queued.len == 0 and allocated.len == 0

# Nonterminal and stale callbacks leave the incoming envelope to the dispatcher.
for stale in [false, true]:
  let incoming = beginDwell(false)
  if stale: clearHook = proc() = inc scanRequestEpoch
  else: scan_env.channelIndex = 0
  let lower = scan_env.paramPtr
  let initialAllocs = allocationCalls
  failAllocation = stale
  doAssert mm_scan_channel_end_ind_handler(incoming) == KeMsgConsumed
  doAssert keMsgHdrFromPayload(incoming).id == MM_SCAN_CHANNEL_END_IND
  let reserved = if stale: 0 else: 2
  doAssert queued.len == 0 and allocated.len == 2 + reserved and allocationCalls == initialAllocs + reserved
  doAssert scan_env.paramPtr == lower
  resetDwell()
  ke_msg_free(keMsgHdrFromPayload(incoming)) # dispatcher
  ke_msg_free(keMsgHdrFromPayload(lower))

# If the end envelope is unusable, the retained lower request carries DONE.
for direct in [false, true]:
  var incoming = beginDwell(false)
  let lower = scan_env.paramPtr
  ke_msg_free(keMsgHdrFromPayload(incoming))
  incoming = if direct: nil else: ke_msg_alloc(MM_SCAN_CHANNEL_END_IND, TASK_SCAN, 255, 1)
  let initialAllocs = allocationCalls
  failAllocation = true
  doAssert mm_scan_channel_end_ind_handler(incoming) == KeMsgConsumed
  doAssert queued == @[lower] and allocationCalls == initialAllocs
  checkDone(queued[0], TASK_SCANU)
  ke_msg_free(keMsgHdrFromPayload(queued.pop()))
  if not direct: ke_msg_free(keMsgHdrFromPayload(incoming))
  doAssert allocated.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_start_ignores_retired_or_invalid_channel(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    handler = procedure(source, "mm_scan_channel_start_ind_handler")
    run_program(tmp_path, mode, r'''
type
  Channel = object
    flags: uint8
  ScanReq = object
    channelCount: uint8
    channelList: array[2, Channel]
  ScanEnv = object
    paramPtr: pointer
    channelIndex: uint8
const
  TASK_SCAN = 1'u8
  ScanChannelPendingState = 2'u8
  KeMsgConsumed = 0.cint
  MACHW_RX_CNTRL_REG = 0'u32
  MACHW_INTC_STATUS_RAW = 1'u32
  MACHW_INTC_GEN_RAW = 2'u32
var
  scan_env: ScanEnv
  req = ScanReq(channelCount: 2)
  replacementReq: ScanReq
  scanRequestEpoch: uint32
  filterCalls, timerCalls, stateCalls: int
  state = ScanChannelPendingState
  assertions: int
  filterHook, traceHook, timerHook: proc()
  nimFwDbgScanStartRxCtrl, nimFwDbgScanStartIrqRaw: uint32
  nimFwDbgScanStartGenRaw, nimFwDbgScanStartPhyRaw: uint32
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  state
proc assert_err(a, b: cstring; line: int) =
  doAssert line == 159
  inc assertions
proc scanStartReqView(p: pointer): ptr ScanReq = cast[ptr ScanReq](p)
proc applyScanChannelRxFilter(flag: uint8) =
  inc filterCalls
  if filterHook != nil:
    let hook = filterHook
    filterHook = nil
    hook()
proc regRead(address: uint32): uint32 = 0
proc snapshotPhyChannel(raw: var uint32) = discard
proc rfPhyTraceCheckpoint(tag: uint32) =
  if traceHook != nil:
    let hook = traceHook
    traceHook = nil
    hook()
proc scheduleActiveScanProbeTimer(p: pointer; epoch: uint32; index: uint8): bool =
  doAssert p == (addr req) and epoch == scanRequestEpoch and index == scan_env.channelIndex
  inc timerCalls
  if timerHook != nil:
    let hook = timerHook
    timerHook = nil
    hook()
  true
proc scanDwellClaim(p: pointer): bool = true
proc enterScanChannelRunningState() = inc stateCalls
''' + handler + r'''
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 0 and timerCalls == 0 and stateCalls == 0
scan_env.paramPtr = addr req
scan_env.channelIndex = 2
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 0 and timerCalls == 0 and stateCalls == 0
req.channelCount = 3
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 0 and timerCalls == 0 and stateCalls == 0
req.channelCount = 2
scan_env.channelIndex = 0
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 1 and timerCalls == 1 and stateCalls == 1
state = 0
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert assertions == 1
doAssert filterCalls == 1 and timerCalls == 1 and stateCalls == 1
state = ScanChannelPendingState
filterHook = proc() =
  scan_env.paramPtr = addr replacementReq
  inc scanRequestEpoch
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 2 and timerCalls == 1 and stateCalls == 1
scan_env.paramPtr = addr req
traceHook = proc() = inc scanRequestEpoch
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 3 and timerCalls == 1 and stateCalls == 1
timerHook = proc() =
  scan_env.paramPtr = addr replacementReq
  inc scanRequestEpoch
doAssert mm_scan_channel_start_ind_handler(nil) == KeMsgConsumed
doAssert filterCalls == 4 and timerCalls == 2 and stateCalls == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_early_end_stops_after_state_assertion(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    handler = procedure(source, "mm_scan_channel_end_early_handler")
    run_program(tmp_path, mode, r'''
type ScanEnv = object
  paramPtr: pointer
const
  TASK_SCAN = 1'u8
  ScanIdleState = 0'u8
  KeMsgConsumed = 0.cint
var
  scan_env: ScanEnv
  state: uint8
  assertions, terminations: int
  request: uint8
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  state
proc assert_err(a, b: cstring; line: int) =
  doAssert line == 186
  inc assertions
proc scan_terminate_channel_request() = inc terminations
''' + handler + r'''
doAssert mm_scan_channel_end_early_handler(nil) == KeMsgConsumed
doAssert assertions == 1 and terminations == 0
state = 2
doAssert mm_scan_channel_end_early_handler(nil) == KeMsgConsumed
doAssert assertions == 1 and terminations == 0
scan_env.paramPtr = addr request
doAssert mm_scan_channel_end_early_handler(nil) == KeMsgConsumed
doAssert assertions == 1 and terminations == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_start_confirms_after_channel_request(tmp_path: Path, mode: str) -> None:
    from test_wifi_scan_start_confirmation import exchange_source

    source = (FW / "task_handlers.nim").read_text()
    scan_source = (FW / "scan_station_ap_me.nim").read_text()
    helpers = procedure(scan_source, "scanChannelValid")
    helpers += procedure(scan_source, "probeIesValid") + "".join(procedure(source, name) for name in [
        "scanStartRequestValid", "sendScanStartConfirmation",
        "finishAcceptedScanStartReq",
    ])
    helpers += procedure((FW / "kernel_mac_channel.nim").read_text(),
                         "ke_msg_forward_and_change_id")
    handler = procedure(source, "scan_start_req_handler")
    run_program(tmp_path, mode, r'''
type
  MsgHdr = object
    id: uint16
    srcId, destId: uint8
    paramLen: uint32
  Channel = object
    prim20Freq: uint16
    band: uint8
  ScanReq = object
    channelCount: uint8
    channelList: array[42, Channel]
    vifIdx, scanType: uint8
    ssidFilter: array[34, uint8]
    ieBodyLen: uint16
    addIeLen: uint32
  ScanStartReqPayload = ScanReq
  StatusCfm = object
    status: uint8
  ProbeIes = object
    ieData: array[200, uint8]
  ScanEnv = object
    paramPtr: pointer
  MacIeView {.packed.} = object
    id, len: uint8
const
  TASK_SCAN = 1'u8
  TASK_SCANU = 2'u8
  ScanIdleState = 0'u8
  SCAN_START_REQ = 1024'u16
  SCAN_START_CFM = 1025'u16
  ScanStartReqPayloadSize = 316'u32
  MAX_VIFS = 2
  StatusCfmPayloadSize = 1'u32
  SCAN_STATUS_OK = 0'u8
  SCAN_STATUS_FAIL = 1'u8
  SCAN_STATUS_BAD_PARAM = 4'u8
  SCAN_STATUS_BUSY = 8'u8
  IE_ID_DS_PARAM = 3'u8
  IE_LEN_DS_PARAM = 1'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
var
  request: ScanReq
  nextRequest: ScanReq
  requestHeader = MsgHdr(id: SCAN_START_REQ, srcId: 7, destId: TASK_SCAN,
    paramLen: ScanStartReqPayloadSize)
  nextHeader = MsgHdr(srcId: 9, paramLen: ScanStartReqPayloadSize)
  confirmationHeader: MsgHdr
  confirmation: StatusCfm
  scan_probe_req_ie: ProbeIes
  scan_env: ScanEnv
  scanState: uint8
  scanu_env: tuple[paramPtr: pointer]
  scanuRequestEpoch: uint32
  failAlloc, replaceUpper: bool
  events: seq[string]
  sentStatuses: seq[uint8]
  nestedCall: proc(): cint
type ScanDwellPair = object
var scanRequestEpoch, scanDwellSerial, scanDwellResetEpoch: uint32
var chanCtxtEpochs: array[5, uint32]
var scanSlot = (slot: 0xFF'u8,)
template chanScanPoolOverlay(): untyped = addr scanSlot
var reserveFails: bool
proc irqSave(): uint32 = 8
proc irqRestore(saved: uint32) = discard
proc scanDwellDispose(pair: var ScanDwellPair) = discard
proc scanDwellReserve(pair: var ScanDwellPair): bool = not reserveFails
proc scanDwellInstall(pair: var ScanDwellPair; slot: uint32; admitting = false) = discard
proc keMsgHdrFromPayload(p: pointer): ptr MsgHdr =
  if p == addr request: addr requestHeader
  elif p == addr nextRequest: addr nextHeader
  elif p == addr confirmation: addr confirmationHeader
  else: nil
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == SCAN_START_CFM and dest in [TASK_SCANU, 7'u8, 9'u8]
  doAssert src == TASK_SCAN and size == StatusCfmPayloadSize
  events.add("alloc")
  if replaceUpper: inc scanuRequestEpoch
  if failAlloc: nil else: addr confirmation
proc ke_msg_free(p: pointer) =
  doAssert p == addr confirmationHeader
  events.add("free")
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  scanState
proc scanStartReqView(p: pointer): ptr ScanReq = cast[ptr ScanReq](p)
proc macIeAt(pos: uint): ptr MacIeView = cast[ptr MacIeView](pos)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc cacheScanStartContext(param: pointer; requester: uint8) =
  doAssert param == (addr request) and requester == 7
  scan_env.paramPtr = param
  events.add("cache")
proc cacheScanStartDurations(req: ptr ScanReq) =
  doAssert req == addr request
  events.add("durations")
proc scan_ie_download(param: pointer) =
  doAssert param == addr request
  events.add("download")
  if nestedCall != nil: discard nestedCall()
proc statusCfmView(p: pointer): ptr StatusCfm = cast[ptr StatusCfm](p)
proc ke_msg_send(p: pointer) =
  if p != addr confirmation:
    doAssert p == (addr request) and requestHeader.id == SCAN_START_CFM
    doAssert requestHeader.paramLen == StatusCfmPayloadSize
    doAssert requestHeader.destId == TASK_SCANU and requestHeader.srcId == TASK_SCAN
  sentStatuses.add(statusCfmView(p).status)
  events.add("send")
''' + exchange_source() + helpers + handler + r'''
for channel in request.channelList.mitems:
  channel = Channel(prim20Freq: 2412, band: 0)
request.channelCount = 2
reserveFails = true
doAssert scan_start_req_handler(addr request) == KeMsgConsumed
doAssert scan_env.paramPtr == nil and sentStatuses == @[SCAN_STATUS_FAIL]
doAssert events == @["alloc", "send"]
reserveFails = false
events.setLen(0)
sentStatuses.setLen(0)
doAssert scan_start_req_handler(nil) == KeMsgConsumed
doAssert events.len == 0 and sentStatuses.len == 0 and scan_env.paramPtr == nil
doAssert scan_start_req_handler(addr request) == KeMsgNoFree
doAssert confirmation.status == SCAN_STATUS_OK
doAssert events == @["alloc", "cache", "durations", "download", "send"]
scan_env.paramPtr = nil
events.setLen(0)
nestedCall = proc(): cint =
  nestedCall = nil
  result = scan_start_req_handler(addr nextRequest)
  doAssert result == KeMsgConsumed
  doAssert confirmation.status == SCAN_STATUS_BUSY
doAssert scan_start_req_handler(addr request) == KeMsgNoFree
doAssert sentStatuses[^2 .. ^1] == @[SCAN_STATUS_BUSY, SCAN_STATUS_OK]
doAssert events == @["alloc", "cache", "durations", "download", "alloc", "send", "send"]
scan_env.paramPtr = nil
events.setLen(0)
scanState = 1
doAssert scan_start_req_handler(addr request) == KeMsgConsumed
doAssert confirmation.status == SCAN_STATUS_BUSY
doAssert events == @["alloc", "send"]
scanState = ScanIdleState
proc checkBadRequest() =
  events.setLen(0)
  doAssert scan_start_req_handler(addr request) == KeMsgConsumed
  doAssert confirmation.status == SCAN_STATUS_BAD_PARAM
  doAssert events == @["alloc", "send"]
requestHeader.paramLen = ScanStartReqPayloadSize - 1
checkBadRequest()
requestHeader.paramLen = ScanStartReqPayloadSize
request.channelCount = 0
checkBadRequest()
request.channelCount = 43
checkBadRequest()
request.channelCount = 2
request.vifIdx = 2
checkBadRequest()
request.vifIdx = 0
request.scanType = 2
checkBadRequest()
request.scanType = 1
request.ssidFilter[0] = 33
checkBadRequest()
request.ssidFilter[0] = 32
request.ieBodyLen = 201
checkBadRequest()
request.ieBodyLen = 1
checkBadRequest()
request.ieBodyLen = 3
scan_probe_req_ie.ieData[0] = 3
scan_probe_req_ie.ieData[1] = 2
scan_probe_req_ie.ieData[2] = 11
checkBadRequest()
request.ieBodyLen = 2
scan_probe_req_ie.ieData[1] = 0
checkBadRequest()
request.ieBodyLen = 4
scan_probe_req_ie.ieData[1] = 2
scan_probe_req_ie.ieData[3] = 11
checkBadRequest()
request.ieBodyLen = 0
request.channelList[1].prim20Freq = 2413
checkBadRequest()
request.channelList[1] = Channel(prim20Freq: 2483, band: 0)
checkBadRequest()
request.channelList[1] = Channel(prim20Freq: 5826, band: 1)
checkBadRequest()
request.channelList[1] = Channel(prim20Freq: 5180, band: 2)
checkBadRequest()
request.channelList[1] = Channel(prim20Freq: 5825, band: 1)
for invalidDuration in [0x04000000'u32, high(uint32)]:
  request.addIeLen = invalidDuration
  checkBadRequest()
request.addIeLen = 1000
doAssert scanStartRequestValid(ScanStartReqPayloadSize, addr request)
request.addIeLen = 0x03FFFFFF'u32
scan_probe_req_ie = default(ProbeIes)
request.ieBodyLen = 200
request.channelCount = 42
request.vifIdx = 1
events.setLen(0)
doAssert scan_start_req_handler(addr request) == KeMsgNoFree
doAssert confirmation.status == SCAN_STATUS_OK
doAssert events == @["alloc", "cache", "durations", "download", "send"]

scan_env.paramPtr = nil
requestHeader.srcId = TASK_SCANU
scanu_env.paramPtr = addr nextRequest
scanuLower = ScanuLowerExchange(request: addr request, epoch: scanuRequestEpoch)
inc scanuRequestEpoch
events.setLen(0)
doAssert scan_start_req_handler(addr request) == KeMsgConsumed
doAssert events.len == 0 and scan_env.paramPtr == nil
for fails in [true, false]:
  scanuLower = ScanuLowerExchange(request: addr request, epoch: scanuRequestEpoch)
  failAlloc = fails
  replaceUpper = true
  events.setLen(0)
  doAssert scan_start_req_handler(addr request) == KeMsgConsumed
  doAssert events == (if fails: @["alloc"] else: @["alloc", "free"])
  doAssert scan_env.paramPtr == nil and requestHeader.id == SCAN_START_REQ
replaceUpper = false
failAlloc = true
scanuLower = ScanuLowerExchange(request: addr request, epoch: scanuRequestEpoch)
requestHeader.paramLen = 0
events.setLen(0)
doAssert scan_start_req_handler(addr request) == KeMsgConsumed
doAssert events == @["alloc"] and requestHeader.id == SCAN_START_REQ
requestHeader.paramLen = ScanStartReqPayloadSize
events.setLen(0)
doAssert scan_start_req_handler(addr request) == KeMsgNoFree
doAssert events == @["alloc", "send"] and sentStatuses[^1] == SCAN_STATUS_FAIL
doAssert scanuClaimLowerReply(addr request, done = false)
doAssert scan_env.paramPtr == nil and scanState == ScanIdleState
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scan_dwell_slot_conversion(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    run_program(tmp_path, mode, layouts("ChanScanReqPayload") +
                procedure(kernel, "chanScanDurationTicks") + r'''
for (duration, slots) in [(0'u32, 0'u16), (1'u32, 1'u16), (1000'u32, 1'u16),
    (1024'u32, 1'u16), (2047'u32, 1'u16), (2048'u32, 2'u16),
    (220000'u32, 214'u16), (0x03ffffff'u32, 0xffff'u16),
    (0x04000000'u32, 0xffff'u16), (high(uint32), 0xffff'u16)]:
  var request = ChanScanReqPayload(duration: duration)
  doAssert chanScanDurationTicks(addr request) == slots
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_idle_scan_cancel_confirms_to_requester(tmp_path: Path, mode: str) -> None:
    scan_source = (FW / "scan_station_ap_me.nim").read_text()
    handler_source = (FW / "task_handlers.nim").read_text()
    confirmation = procedure(scan_source, "scan_send_cancel_cfm")
    handler = procedure(handler_source, "scan_cancel_req_handler")
    run_program(tmp_path, mode, r'''
type
  ScanEnv = object
    paramPtr: pointer
    abortFlag: uint8
  MsgHdr = object
    srcId: uint8
  StatusCfmPayload = object
    status: uint8
const
  TASK_SCAN = 1'u8
  ScanIdleState = 0'u8
  SCAN_CANCEL_CFM = 1028'u16
  StatusCfmPayloadSize = 1'u32
  KeMsgConsumed = 0.cint
var
  scan_env: ScanEnv
  requestBody: uint8
  requestHeader = MsgHdr(srcId: 7)
  confirmationBody: StatusCfmPayload
  scanState: uint8
  allocations, sends: int
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  scanState
proc keMsgHdrFromPayload(p: pointer): ptr MsgHdr =
  doAssert p == (addr requestBody)
  addr requestHeader
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == SCAN_CANCEL_CFM and dest == requestHeader.srcId
  doAssert src == TASK_SCAN and size == StatusCfmPayloadSize
  inc allocations
  addr confirmationBody
proc ke_msg_send(p: pointer) =
  doAssert p == (addr confirmationBody) and confirmationBody.status == 1
  inc sends
''' + confirmation + handler + r'''
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 1 and sends == 1 and scan_env.abortFlag == 0
requestHeader.srcId = 9
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 2 and sends == 2
scan_env.paramPtr = addr requestBody
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 2 and sends == 2 and scan_env.abortFlag == 1
scan_env.paramPtr = nil
scanState = 3
scan_env.abortFlag = 0
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 3 and sends == 3 and scan_env.abortFlag == 0
doAssert scan_cancel_req_handler(nil) == KeMsgConsumed
doAssert allocations == 3 and sends == 3 and scan_env.abortFlag == 0
scan_env.paramPtr = addr requestBody
doAssert scan_cancel_req_handler(nil) == KeMsgConsumed
doAssert scan_env.abortFlag == 0
''')
