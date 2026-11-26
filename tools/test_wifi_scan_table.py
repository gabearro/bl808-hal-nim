"""Drive TASK_SCAN and TASK_SCANU through every state and input.

The harness is the real scan_machine.nim (scanGo, scanuGo, the dwell notices,
scanRelease and scanuComplete over op.nim's Op) with the real handlers of
both tasks from task_handlers.nim and SCANU's request builder from
scan_station_ap_me.nim (scanu_start, scanu_scan_next and its IE writer),
scan_init and scanu_init. Messages are dispatched as ke_task_schedule does,
through the per-state tables parsed from dispatch_tables.nim: SCANU's state
table first, then its default table; TASK_SCAN has only its default table.
test_wifi_message_tables.py checks those tables against the vendor archive
(scan_task.o, scanu_task.o), with the port's SCANU_RAW_SEND_REQ refusal.

The channel scheduler is a model of slot 3, the guarantee scan_machine.nim
relies on: chan_scan_req(start) asks for the slot, the radio arrives
(scanDwellPost(START)) and later retires it (scanDwellPost(END));
chan_scan_req(abort) retires it at once when it is on its channel and does
nothing before (chan_ctxt_op_evt below status 4).

Each row starts a host or SM scan or join, runs it to one stop point (each of
its first 40 steps, which covers every state of both tasks with each notice
queued or held), applies one input there and runs to quiescence. After every
step:

  - TASK_SCAN is not idle exactly while it holds a request, and holds
    notices only for a live dwell; TASK_SCANU likewise holds its request
    exactly while it is not idle;
  - whatever a busy task waits for is coming: a live START or END is queued
    or the slot that posts it is requested, SCANU's lower request is queued
    to TASK_SCAN, held by it or answered back, a replay's SCAN_DONE_IND is
    queued;
  - no request is answered twice.

At quiescence both tasks are idle, every upper request has exactly one
answer, nothing else is allocated, and every stamp handed out is stale.
"""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

ROOT = FW.parents[3]
WIFI = FW.parent

TASKS = (FW / "task_handlers.nim").read_text()
SCAN = (FW / "scan_station_ap_me.nim").read_text()
KERNEL = (FW / "kernel_mac_channel.nim").read_text()
TABLES = (FW / "dispatch_tables.nim").read_text()

TABLE_NAMES = ["scan_default_state", "scanu_default_state", "scanu_idle",
               "scanu_scanning", "scanu_joining"]

TASK_HANDLERS = [
    "mm_scan_channel_start_ind_handler", "advanceScanChannelIndex",
    "mm_scan_channel_end_ind_handler", "mm_scan_channel_end_early_handler",
    "cacheScanStartContext", "sendScanStartConfirmation", "scan_start_req_handler",
    "scan_start_cfm_handler", "scan_done_ind_handler", "scan_cancel_req_handler",
    "smAbortOwnsLowerScan", "scan_abort_req_handler", "scan_probe_req_handler",
    "scanu_start_req_handler", "scanu_join_req_handler", "smQueueOwnedScanAbort",
]

BUILDER = [
    "scanChannelValid", "reserveProbeIeBytes", "cursor", "appendByte", "appendIeHeader",
    "skip", "appendDsParamPlaceholder", "appendBytes", "probeIesValid",
    "appendHtCapabilities", "macId2RatePtr", "appendSupportedRates", "finishScanStartReq",
    "sendScanStartReq", "initScanStartReq", "appendScanBandChannel", "copyScanBandChannels",
    "firstScanBandChannel", "clampedProbeReqIeLen", "supportedRateStart",
    "appendScanSupportedRates", "appendScanHtCapabilities", "allocScanStartReq",
    "allocInitializedScanStartReq", "copyScanSsidFilterIfPresent",
    "resetUndirectedScanuStart", "finishAdvancedScanuScanBand", "scanu_start",
    "scanu_scan_next", "scan_init", "scanu_init",
]

PLATFORM = r'''
import "@WIFI@/fw_messages"
import "@WIFI@/fw_constants"
{.pragma: wifiCtrl.}
{.pragma: wifiCtrlExport.}
const
  SCAN_STATUS_OK = 0'u8
  SCAN_STATUS_FAIL = 1'u8
  SCAN_STATUS_BAD_PARAM = 4'u8
  SCAN_STATUS_BUSY = 8'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  MAX_VIFS = 2
  MAX_SCAN_RESULTS = 4
  IE_ID_DS_PARAM = 3'u8
  IE_LEN_DS_PARAM = 1'u8
  IE_ID_HT_CAP = 45'u8
  IE_LEN_HT_CAP = 26'u8
  IE_ID_SUPPORTED_RATES = 1'u8
  PROBE_REQ_SUPPORTED_RATE_COUNT = 8'u8
type
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  KeMsgHandler = object
    msgId: uint32
    handler: pointer
  StatusCfmPayload = object
    status: uint8
  ScanSlot = object
    slot: uint8
  ScanEnvObj = object
    paramPtr, chanInfoPtr: pointer
    requester, channelIndex, abortFlag, padding: uint8
    passiveDuration, activeDuration, joinActiveDuration: uint32
  ScanuEnvObj = object
    paramPtr, pendingJoinRxuMgtInd, probeIeCopyDst, extraIePtr: pointer
    requester, bssidFilterEnabled, scanBand, resultState, directedFound,
      joinRetryCount: uint8
    resultCount, extraIeLen: uint16
    filterBssid: array[6, uint8]
  IeBuffer = object
    magic, probeIeStateWord, writeOffset: uint32
    ieDataPtr: pointer
    ieData: array[200, uint8]
  MeEnvView = object
    htSupp: uint8
    caps: array[26, uint8]
  VifApConfig = object
    securityFlags: uint32
  CachedEntry = object
    cachedRxuMgtInd: pointer
  ScanuAddIe = object
    ieData: array[200, uint8]
const
  HostTask = 10'u8   # an external requester; TASK_API also gets a join's extra CFM
  ScanSsidSlotViewSize = sizeof(ScanSsidSlotView)
  ScanStartReqPayloadSize = sizeof(ScanStartReqPayload).uint32
  ScanuStartReqPayloadSize = sizeof(ScanuStartReqPayload).uint32
  StatusCfmPayloadSize = 1'u32
var
  heap: seq[pointer]           # every allocated header
  queue, saved: seq[pointer]   # kernel sent and saved queues (payloads)
  delivered: seq[pointer]      # messages sent to SM or the host
  allocations: int
  failId: uint16               # allocations of this id fail
  failCount: int               # this many of them
  states: array[3, uint16]
  scanSlot = ScanSlot(slot: 0xFF)
  slotOn: bool
  scan_env: ScanEnvObj
  scanu_env: ScanuEnvObj
  scan_probe_req_ie, hostIes: IeBuffer
  scanuAdd: ScanuAddIe
  mac_id2rate: array[12, uint8]
  me = MeEnvView(htSupp: 1)
  vifConfigs: array[MAX_VIFS, VifApConfig]
  cache: CachedEntry
  cacheHit: bool
  scanuJoinHandler: pointer
  scanuResultCount: uint32
  scanuResults: array[MAX_SCAN_RESULTS, pointer]
  probes, cacheClears, replayedFrames, rawSends, terminations, arrivals: int
  events, logs: seq[string]     # handler call order, platform log lines
  probeStatus: uint8            # scan_probe_req_tx's result
  scanDuration = 200_000'u32
  logging: bool
  timer: tuple[armed: bool, stamp: uint32]
  cancelConfirmations: seq[uint8]
  smRequest: pointer
  nimFwDbgScanStartRxCtrl, nimFwDbgScanStartIrqRaw, nimFwDbgScanStartGenRaw: uint32
  nimFwDbgScanEndRxCtrl, nimFwDbgScanEndIrqRaw, nimFwDbgScanEndGenRaw: uint32
  nimFwDbgScanStartPhyRaw, nimFwDbgScanEndPhyRaw: array[4, uint32]

proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgPayload(h: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](h) + sizeof(KeMsgHdr).uint)
template scanStartReqView(p: pointer): ptr ScanStartReqPayload = cast[ptr ScanStartReqPayload](p)
template scanuStartReqView(p: pointer): ptr ScanuStartReqPayload = cast[ptr ScanuStartReqPayload](p)
template activeScanuReq(): ptr ScanuStartReqPayload = scanuStartReqView(scanu_env.paramPtr)
template statusCfmView(p: pointer): ptr StatusCfmPayload = cast[ptr StatusCfmPayload](p)
template scanSsidSlot(req: typed, index: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](cast[uint](addr req.ssidFilter[0]) + index.uint * ScanSsidSlotViewSize.uint)
proc chanScanPoolOverlay(): ptr ScanSlot = addr scanSlot
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  zeroMem(p, n.int)
  p
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc co_pack8p(dst, src: pointer; n: uint32) = copyMem(dst, src, n.int)
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc nimFwTrace(s: cstring) = discard
proc regRead(address: uint): uint32 = 0
const MACHW_RX_CNTRL_REG = 0'u
const MACHW_INTC_STATUS_RAW = 0'u
const MACHW_INTC_GEN_RAW = 0'u
proc snapshotPhyChannel(raw: var array[4, uint32]) = discard
proc rfPhyTraceCheckpoint(point: uint32) = discard
proc applyScanChannelRxFilter(flags: uint8) = events.add("filter")
proc clearScanEdcaRxFilter() = events.add("unfilter")
proc printer(format: cstring) {.cdecl, varargs.} = logs.add($format)
proc blOpsFunc(index: int): pointer =
  doAssert index == 4
  if logging: cast[pointer](printer) else: nil
proc getLogFunc(index: int): pointer = nil
proc scan_get_scan_duration(): uint32 =
  events.add("duration")
  scanDuration
proc scan_probe_req_tx(): uint8 =
  inc probes
  events.add("tx")
  probeStatus
proc scanStartRequestValid(n: uint32; req: ptr ScanStartReqPayload): bool =
  n >= ScanStartReqPayloadSize and req.channelCount in 1'u8 .. 42'u8
proc cacheScanStartDurations(req: ptr ScanStartReqPayload) = discard
proc scanProbeReqIeDataPtr(ie: var IeBuffer): pointer = addr ie.ieData[0]
proc scanuAddIeDataAddr(): uint = cast[uint](addr scanuAdd.ieData[0])
proc scanuAddIeView(): ptr ScanuAddIe = addr scanuAdd
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = 2 + ie.len.uint
proc meEnvView(): ptr MeEnvView = addr me
proc meHtCapsPtr(p: ptr MeEnvView): pointer = addr p.caps[0]
proc cacheScanuFilterSsid(req: ptr ScanuStartReqPayload) = discard
proc scanu_cached_scanresult_clear() = inc cacheClears
proc scanu_frame_handler(frame: pointer; length: uint32) = discard
proc vifChannelForIdx(index: uint8): ptr VifApConfig = addr vifConfigs[index]
proc vifApConfig(vif: ptr VifApConfig): ptr VifApConfig = vif
proc scanu_search_by_bssid(bssid: pointer): pointer =
  if cacheHit: addr cache else: nil
proc scanuResultAt(p: pointer): ptr CachedEntry = cast[ptr CachedEntry](p)
proc scanuCachedSsidFor(entry: ptr CachedEntry): pointer = addr cacheHit
proc smScanRefused(request: pointer): bool = false
proc smAwaits(request: pointer): bool = request != nil and request == smRequest
proc scan_send_cancel_cfm(status, dest: uint8) = cancelConfirmations.add(status)

proc ke_msg_try_alloc(id: uint16; dest, source: uint8; length: uint32): pointer =
  if id == failId and failCount > 0:
    dec failCount
    return nil
  inc allocations
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + max(length.int, 8)))
  header.id = id
  header.destId = dest
  header.srcId = source
  header.paramLen = length
  heap.add(header)
  keMsgPayload(header)
proc ke_msg_free(header: pointer) =
  let index = heap.find(header)
  doAssert index >= 0, "freed a message that is not allocated"
  heap.del(index)
  dealloc(header)
proc ke_msg_send(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  doAssert p notin queue and p notin delivered, "message sent twice"
  if header.destId in [TASK_SCAN, TASK_SCANU]: queue.add(p)
  else: delivered.add(p)
proc ke_state_get(task: uint8): uint16 = states[task]
proc ke_state_set(task: uint8; state: uint16) =
  if states[task] == state: return
  states[task] = state
  # ke_reschedule_saved_messages: the task's saved messages run again.
  var kept: seq[pointer]
  for p in saved:
    if keMsgHdrFromPayload(p).destId == task: queue.add(p) else: kept.add(p)
  saved = kept
proc ke_timer_try_set(id: uint16; task: uint8; delay: uint32; stamp = 0'u32): bool =
  doAssert id == SCAN_PROBE_TIMER and task == TASK_SCAN and stamp != 0
  doAssert delay == scanDuration shr 1
  events.add("timer")
  timer = (true, stamp)
  true
proc ke_timer_clear(id: uint16; task: uint8) =
  doAssert id == SCAN_PROBE_TIMER and task == TASK_SCAN
  events.add("clear")
  timer.armed = false
proc ke_msg_save(p: pointer): cint {.cdecl.} = KeMsgSaved
proc ke_msg_discard(p: pointer): cint {.cdecl.} = KeMsgConsumed
proc rxu_mgt_ind_handler_scanu(p: pointer): cint {.cdecl.} =
  inc replayedFrames
  KeMsgConsumed
proc scanu_raw_send_req_handler(p: pointer): cint {.cdecl.} =
  inc rawSends
  KeMsgConsumed
proc scanu_raw_send_busy_handler(p: pointer): cint {.cdecl.} = KeMsgConsumed

proc scanu_scan_next*() {.exportc, cdecl.}

# The channel scheduler's slot 3.
proc scanDwellPost(id: uint16)
proc scan_set_channel_request() =
  events.add("next")
  doAssert scanSlot.slot == 0xFF and states[TASK_SCAN] == ScanChannelPendingState
  scanSlot.slot = 3
  slotOn = false
proc scan_ie_download(param: pointer) = scan_set_channel_request()
proc arrive() =
  doAssert scanSlot.slot == 3 and not slotOn
  slotOn = true
  inc arrivals
  scanDwellPost(MM_SCAN_CHANNEL_START_IND)
proc retire() =
  doAssert scanSlot.slot == 3 and slotOn
  scanSlot.slot = 0xFF
  slotOn = false
  scanDwellPost(MM_SCAN_CHANNEL_END_IND)
proc scan_terminate_channel_request() =
  events.add("terminate")
  inc terminations
  if scanSlot.slot == 3 and slotOn: retire()
'''

DRIVER = r'''
proc dispatchTo(p: pointer; table: openArray[KeMsgHandler]): (bool, cint) =
  let id = keMsgHdrFromPayload(p).id
  for entry in table:
    if entry.msgId == id.uint32:
      return (true, cast[proc(p: pointer): cint {.cdecl.}](entry.handler)(p))
  (false, KeMsgConsumed)

proc dispatch(p: pointer) =
  ## ke_task_schedule: the state table, then the default table, else free.
  let header = keMsgHdrFromPayload(p)
  var found = false
  var result = KeMsgConsumed
  if header.destId == TASK_SCAN:
    (found, result) = dispatchTo(p, scan_default_state)
  else:
    doAssert header.destId == TASK_SCANU
    let state = states[TASK_SCANU]
    let table = if state == ScanuIdleState: @scanu_idle
                elif state == ScanuScanningState: @scanu_scanning
                else: @scanu_joining
    (found, result) = dispatchTo(p, table)
    if not found: (found, result) = dispatchTo(p, scanu_default_state)
  if not found or result == KeMsgConsumed: ke_msg_free(header)
  elif result == KeMsgSaved: saved.add(p)

var answers: seq[(pointer, uint16)]   # (request, answer id) for upper requests
var requests: seq[pointer]            # upper requests sent

proc liveStart(): bool =
  for p in queue:
    let h = keMsgHdrFromPayload(p)
    if h.id == MM_SCAN_CHANNEL_START_IND and h.paramLen == 4 and
        opCurrent(scanOwn.op, cast[ptr uint32](p)[]): return true
proc liveEnd(): bool =
  for p in queue:
    let h = keMsgHdrFromPayload(p)
    if h.id == MM_SCAN_CHANNEL_END_IND and h.paramLen == 4 and
        opCurrent(scanOwn.op, cast[ptr uint32](p)[]): return true

proc check(where: string) =
  let scanState = states[TASK_SCAN]
  doAssert scanState in [ScanIdleState, ScanChannelPendingState, ScanChannelRunningState], where
  doAssert (scanState != ScanIdleState) == (scan_env.paramPtr != nil),
    where & ": TASK_SCAN state " & $scanState & " and its request disagree"
  if scanState == ScanIdleState:
    doAssert scanOwn.start == nil and scanOwn.finish == nil, where & ": idle with notices"
    doAssert not opCurrent(scanOwn.op, scanOwn.op.serial), where & ": idle with a live stamp"
  if scanState == ScanChannelPendingState:
    doAssert liveStart() or (scanOwn.start != nil and scanSlot.slot == 3),
      where & ": state 2 with no START coming"
  if scanState == ScanChannelRunningState:
    doAssert scanOwn.start == nil, where & ": START held on the channel"
    doAssert liveEnd() or (scanOwn.finish != nil and scanSlot.slot == 3 and slotOn),
      where & ": state 3 with no END coming"
  if scan_env.paramPtr != nil and keMsgHdrFromPayload(scan_env.paramPtr).srcId == TASK_SCANU:
    doAssert scan_env.paramPtr == scanuOwn.lower,
      where & ": TASK_SCAN runs a lower request SCANU no longer waits on"
  let scanuState = states[TASK_SCANU]
  doAssert scanuState in [ScanuIdleState, ScanuScanningState, ScanuJoiningState], where
  doAssert (scanuState != ScanuIdleState) == (scanu_env.paramPtr != nil),
    where & ": TASK_SCANU state " & $scanuState & " and its request disagree"
  if scanuOwn.lower != nil:
    doAssert scanuState != ScanuIdleState, where & ": idle SCANU waits on a lower request"
    doAssert scanuOwn.lower in queue or scan_env.paramPtr == scanuOwn.lower,
      where & ": SCANU waits on a lower request nobody holds"
  if scanuState != ScanuIdleState:
    let replay = scanu_env.pendingJoinRxuMgtInd
    doAssert (scanuOwn.lower != nil) != (replay != nil),
      where & ": SCANU busy with " & $(scanuOwn.lower != nil) & " lower and " &
        $(replay != nil) & " replay"
    if replay != nil: doAssert replay in queue, where & ": replay DONE not queued"
  for request in requests:
    var count = 0
    for answer in answers:
      if answer[0] == request: inc count
    doAssert count <= 1, where & ": request answered twice"

var kept: seq[pointer]   # answers delivered in this row, freed at rest

proc collect(active: pointer) =
  ## Answers to SM and the host: record them. An answer in place is the
  ## request itself; an allocated one answers the request SCANU ran in this
  ## step. TASK_API's extra SCANU_JOIN_CFM is not counted. They stay
  ## allocated until the row ends, so no address is reused meanwhile.
  for p in delivered:
    let h = keMsgHdrFromPayload(p)
    if h.id in [SCANU_START_CFM, SCANU_JOIN_CFM] and h.destId != TASK_API:
      let request = if p in requests: p else: active
      doAssert request != nil, "an answer for no request"
      answers.add((request, h.id))
    kept.add(p)
  delivered.setLen(0)

var stamps: seq[uint32]
proc step(): bool =
  ## One kernel step: dispatch a message, else the radio moves. False at rest.
  let active = if queue.len > 0 and queue[0] in requests: queue[0]
               else: scanu_env.paramPtr
  if queue.len > 0:
    let p = queue[0]
    queue.delete(0)
    dispatch(p)
  elif scanSlot.slot == 3 and not slotOn: arrive()
  elif scanSlot.slot == 3: retire()
  else: return false
  if scanOwn.op.serial notin stamps: stamps.add(scanOwn.op.serial)
  collect(active)
  true

proc settle(where: string) =
  var guard = 0
  while step():
    check(where)
    inc guard
    doAssert guard < 500, where & ": no quiescence"

proc newUpper(id: uint16; source: uint8; channels: int): pointer =
  result = ke_msg_try_alloc(id, TASK_SCANU, source, ScanuStartReqPayloadSize)
  let req = scanuStartReqView(result)
  req.channelCount = channels.uint8
  for i in 0 ..< channels:
    req.channelList[i] = ScanChannelEntry(prim20Freq: (2412 + 5 * i).uint16, band: 0)
  req.vifIdx = 0
  req.bssid = [2'u8, 1, 1, 1, 1, 1]
  requests.add(result)
  if source == TASK_SM: smRequest = result
  ke_msg_send(result)

proc stale(id: uint16; stamp: uint32): pointer =
  ## A notice or expiry carrying `stamp`, delivered to TASK_SCAN.
  result = ke_msg_try_alloc(id, TASK_SCAN, TASK_NONE, 4)
  cast[ptr uint32](result)[] = stamp
  ke_msg_send(result)

proc mmReset() =
  ## MM_RESET_REQ: me_init (scanu_init, then sm_init), then mm_init
  ## (scan_init, then chan_init, which frees slot 3).
  scanu_init()
  smRequest = nil
  scan_init()
  scanSlot.slot = 0xFF
  slotOn = false

proc finish(where: string) =
  settle(where)
  doAssert states[TASK_SCAN] == ScanIdleState and states[TASK_SCANU] == ScanuIdleState, where
  doAssert queue.len == 0 and saved.len == 0, where & ": messages left queued"
  for request in requests:
    var count = 0
    for answer in answers:
      if answer[0] == request: inc count
    doAssert count == 1 or (count == 0 and keMsgHdrFromPayload(request) notin heap),
      where & ": request answered " & $count & " times"
  for p in kept: ke_msg_free(keMsgHdrFromPayload(p))
  kept.setLen(0)
  doAssert heap.len == 0, where & ": " & $heap.len & " messages leaked"
  for stamp in stamps:
    doAssert not opCurrent(scanOwn.op, stamp), where & ": stamp still live at rest"
'''


def tables() -> str:
    declarations = dict((name, body) for body, name in re.findall(
        r"(var (\w+)\*[^\n]*: array\[\d+, KeMsgHandler\] = \[.*?\n\])", TABLES, re.S))
    helper = re.search(r"(?ms)^template keMsgHandlerAddress\(.*?(?=\n\S|\Z)", TABLES).group(0)
    return helper + "\n" + "\n".join(declarations[name] for name in TABLE_NAMES) + "\n"


def layout_types() -> str:
    layout = (FW / "layout_types.nim").read_text()
    code = "type\n"
    for name in ["ScanChannelEntry", "ScanSsidSlotView", "ScanStartReqPayload",
                 "ScanuStartReqPayload", "MacIeView"]:
        code += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    return code


def harness() -> str:
    machine = (FW / "scan_machine.nim").read_text()
    writer = "type ProbeIeWriter = object" + SCAN.split("type ProbeIeWriter = object", 1)[1].split("\nproc ", 1)[0] + "\n"
    code = layout_types() + PLATFORM.replace("@WIFI@", str(WIFI))
    code += (FW / "op.nim").read_text() + procedure(KERNEL, "ke_msg_forward_and_change_id")
    code += machine
    code += writer + "".join(procedure(SCAN, name).split("\ntype ProbeIeWriter", 1)[0]
                             for name in BUILDER)
    code += "".join(procedure(TASKS, name) for name in TASK_HANDLERS)
    return code + tables() + DRIVER + flush_driver()


def flush_driver() -> str:
    """ke_flush's scan lines, extracted from the real procedure, then its
    flush of the kernel queues and timers (every answer queued is freed)."""
    flush = procedure(KERNEL, "ke_flush")
    start = flush.index("  # The lower scan's answer is flushed")
    end = flush.index("  scanuAbandon()\n", start) + len("  scanuAbandon()\n")
    return ("proc keFlushScan() =\n" + flush[start:end] + r'''
  for p in queue & saved: ke_msg_free(keMsgHdrFromPayload(p))
  queue.setLen(0)
  saved.setLen(0)
  timer.armed = false
  smRequest = nil       # smAbandon: SM forgets the request it sent
''')


# --------------------------------------------------------------------------
# TASK_SCAN
# --------------------------------------------------------------------------

# One input applied to a run stopped at some step. `source` is the scan's
# requester (SM or the host).
INPUTS = {
    "none": "",
    "abort_sm": "smQueueOwnedScanAbort()\n",
    "abort_host": r'''
ke_msg_send(ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, HostTask, 0))
''',
    "cancel_host": r'''
ke_msg_send(ke_msg_try_alloc(SCAN_CANCEL_REQ, TASK_SCAN, HostTask, 0))
''',
    "early_end": "scanEarlyEndRequest()\n",
    "stop_after_dwell": "scanStopAfterDwell()\n",
    "probe_expiry": r'''
if timer.armed:
  timer.armed = false
  discard stale(SCAN_PROBE_TIMER, timer.stamp)
''',
    # Deliveries of an earlier dwell, or of none: stamps other than the live one.
    "stale_notices": r'''
for id in [MM_SCAN_CHANNEL_START_IND, MM_SCAN_CHANNEL_END_IND, MM_SCAN_CHANNEL_END_EARLY,
           SCAN_PROBE_TIMER]:
  discard stale(id, scanOwn.op.serial - 1)
  discard stale(id, 0)
''',
    # The next dwell cannot allocate its notices.
    "next_dwell_alloc_fails": r'''
failId = MM_SCAN_CHANNEL_END_IND
failCount = 1
''',
    "lower_alloc_fails": r'''
failId = SCAN_START_REQ
failCount = 1
''',
    "lower_cfm_alloc_fails": r'''
failId = SCAN_START_CFM
failCount = 1
''',
    "slot_taken": r'''
if scanSlot.slot == 0xFF: scanSlot.slot = 4   # another user of the singleton slot
''',
    "mm_reset": "mmReset()\n",
    # ke_flush: every queued message, a lower answer included, is freed.
    "ke_flush": "keFlushScan()\n",
    "host_scan": "discard newUpper(SCANU_START_REQ, HostTask, 1)\n",
    "host_join": "discard newUpper(SCANU_JOIN_REQ, HostTask, 1)\n",
}

STARTS = {
    "sm_scan": "discard newUpper(SCANU_START_REQ, TASK_SM, 3)\n",
    "host_scan": "discard newUpper(SCANU_START_REQ, HostTask, 2)\n",
    "sm_join": "discard newUpper(SCANU_JOIN_REQ, TASK_SM, 2)\n",
}

# Checks of particular inputs, after quiescence.
INPUT_CHECKS = {
    # A delivery that is not the live dwell's never ends a dwell.
    "stale_notices": "doAssert terminations == 0, where & \": a stale delivery ended a dwell\"",
    "none": "doAssert terminations == 0",
}

ROW = r'''
for stop in 0 .. 40:
  doAssert heap.len == 0 and kept.len == 0
  answers.setLen(0)
  requests.setLen(0)
  stamps.setLen(0)
  scanSlot.slot = 0xFF
  slotOn = false
  failCount = 0
  terminations = 0
  timer.armed = false
  scan_init()
  scanu_init()
  let where = "@START@/@INPUT@ at step " & $stop
@STARTCODE@
  var ran = 0
  while ran < stop and step():
    check(where)
    inc ran
  if ran < stop:            # the run ended before this stop point
    finish(where)
    break
@INPUTCODE@
  check(where & " (input)")
  finish(where)
  if scanSlot.slot == 4: scanSlot.slot = 0xFF   # the other slot user leaves
  @EXTRA@
'''


def row(start: str, inp: str) -> str:
    indent = lambda code: "".join("  " + line + "\n" for line in code.strip("\n").splitlines())
    return ROW.replace("@START@", start).replace("@INPUT@", inp).replace(
        "@STARTCODE@", indent(STARTS[start])).replace(
        "@INPUTCODE@", indent(INPUTS[inp]) if INPUTS[inp].strip() else "  discard").replace(
        "@EXTRA@", INPUT_CHECKS.get(inp, "discard"))


@pytest.mark.parametrize("inp", INPUTS)
@pytest.mark.parametrize("start", STARTS)
def test_scan_table(tmp_path: Path, start: str, inp: str) -> None:
    run_program(tmp_path, "checked", harness() + row(start, inp))


def test_scan_table_runs_asan(tmp_path: Path) -> None:
    body = "".join(row(start, inp) for start in STARTS for inp in
                   ["none", "abort_sm", "early_end", "mm_reset", "next_dwell_alloc_fails"])
    run_program(tmp_path, "asan", harness() + body)


# --------------------------------------------------------------------------
# Properties of particular rows
# --------------------------------------------------------------------------

def test_scan_answers_and_probes(tmp_path: Path) -> None:
    """A scan of three channels runs three dwells, probes once at each START
    and once at each repeat expiry, and ends with one SCAN_DONE_IND answered
    in place: the lower request itself, which SCANU takes."""
    run_program(tmp_path, "checked", harness() + r'''
scan_init()
scanu_init()
let upper = newUpper(SCANU_START_REQ, HostTask, 3)
var dwells = 0
var lower: pointer
while true:
  if states[TASK_SCAN] == ScanChannelRunningState and timer.armed and queue.len == 0 and
      scanSlot.slot == 3 and slotOn:
    inc dwells
    let before = probes
    discard stale(SCAN_PROBE_TIMER, timer.stamp)
    doAssert step() and probes == before + 1, "the repeat probe of a live dwell was dropped"
  if states[TASK_SCAN] != ScanIdleState: lower = scan_env.paramPtr
  if not step(): break
  check("scan")
finish("scan")
doAssert dwells == 3 and probes == 6
doAssert answers.len == 1 and answers[0] == (upper, SCANU_START_CFM)
''')


def test_abort_while_pending_leaves_the_channel_at_once(tmp_path: Path) -> None:
    """SCAN_ABORT_REQ in state 2 sets the stop flag; the dwell then leaves its
    channel as soon as it starts, without probing, and the request ends.
    In state 3 the abort leaves the channel at once (pinned scan_task.o)."""
    run_program(tmp_path, "checked", harness() + r'''
for running in [false, true]:
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  let upper = newUpper(SCANU_START_REQ, TASK_SM, 4)
  while states[TASK_SCAN] != ScanChannelPendingState or queue.len != 0:
    doAssert step()
  if running:
    arrive()
    doAssert step() and states[TASK_SCAN] == ScanChannelRunningState and probes == 1
  let before = probes
  smQueueOwnedScanAbort()
  doAssert step()                   # the abort
  doAssert terminations == (if running: 1 else: 0) and scan_env.abortFlag == 1
  if not running:
    doAssert states[TASK_SCAN] == ScanChannelPendingState
    arrive()
    doAssert step() and terminations == 1 and probes == before,
      "a dwell started after the abort probed or stayed on its channel"
  doAssert not slotOn and scanSlot.slot == 0xFF
  finish("abort")
  doAssert arrivals == 1, "the aborted scan went on to the next channel"
  doAssert answers == @[(upper, SCANU_START_CFM)]
  terminations = 0
  probes = 0
  arrivals = 0
''')


def test_sm_abort_spares_another_requesters_scan(tmp_path: Path) -> None:
    """SM's abort acts only on the lower scan of SM's live scan request, when
    TASK_SCAN runs it: queued for SM's scan, it leaves a host scan alone."""
    run_program(tmp_path, "checked", harness() + r'''
scan_init()
scanu_init()
let smUpper = newUpper(SCANU_START_REQ, TASK_SM, 2)
while states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
smQueueOwnedScanAbort()
let abort = queue[^1]
queue.setLen(queue.len - 1)
smRequest = nil                     # SM moved on (sm_init) before the abort ran
ke_msg_send(abort)
doAssert step() and scan_env.abortFlag == 0, "SM's late abort stopped the scan"
finish("late abort")
''')


def test_join_replay_completes_once(tmp_path: Path) -> None:
    """A join whose target is cached replays the frame and ends with the
    SCAN_DONE_IND SCANU sent itself, without a lower scan; state 2 is set
    once. A stray SCAN_DONE_IND changes nothing."""
    run_program(tmp_path, "checked", harness() + r'''
var transitions: seq[uint16]
scan_init()
scanu_init()
cacheHit = true
cache.cachedRxuMgtInd = ke_msg_try_alloc(0x1C00, TASK_SCANU, TASK_SCANU, 32)
let upper = newUpper(SCANU_JOIN_REQ, TASK_SM, 1)
doAssert step()
doAssert states[TASK_SCANU] == ScanuJoiningState and scanu_env.pendingJoinRxuMgtInd != nil
doAssert scanuOwn.lower == nil and queue.len == 2
let stray = ke_msg_try_alloc(SCAN_DONE_IND, TASK_SCANU, TASK_SCAN, 0)
ke_msg_send(stray)
finish("replay")
doAssert replayedFrames == 1 and cacheClears == 1
doAssert answers == @[(upper, SCANU_JOIN_CFM)]
''')


def test_saved_requests_run_after_the_answer(tmp_path: Path) -> None:
    """SCANU's tables save a second request while it is busy; it runs after
    the first one's answer is queued. The busy branch of the old handlers
    is gone: the handlers run only in state 0."""
    run_program(tmp_path, "checked", harness() + r'''
scan_init()
scanu_init()
let first = newUpper(SCANU_START_REQ, HostTask, 1)
doAssert step() and states[TASK_SCANU] == ScanuScanningState
let second = newUpper(SCANU_JOIN_REQ, TASK_SM, 1)
let third = newUpper(SCANU_START_REQ, HostTask, 1)
while second in queue or third in queue: doAssert step()
doAssert saved == @[second, third] and states[TASK_SCANU] == ScanuScanningState
var order: seq[pointer]
while step():
  check("saved")
  for answer in answers:
    if answer[0] notin order: order.add(answer[0])
finish("saved")
doAssert order == @[first, second, third], "saved requests ran before the answer"
''')
    for handler in ["scanu_start_req_handler", "scanu_join_req_handler"]:
        body = procedure(TASKS, handler)
        assert "ke_state_get(TASK_SCANU)" not in body and "SCAN_STATUS_BUSY" not in body, handler
        assert "KeMsgSaved" not in body, handler


def test_tables_route_as_the_machines_assume() -> None:
    """The per-state tables the harness dispatches through: TASK_SCAN has one
    default table with all seven messages; SCANU admits requests only in
    idle, takes lower answers and frames only while busy, and saves new
    requests while busy. The scanning and joining tables are the same."""
    entries = {name: re.findall(r"KeMsgHandler\(msgId: (\w+), handler: keMsgHandlerAddress\((\w+)\)\)",
                                body) for body, name in re.findall(
        r"(var (\w+)\*[^\n]*: array\[\d+, KeMsgHandler\] = \[.*?\n\])", TABLES, re.S)}
    assert dict(entries["scan_default_state"]) == {
        "SCAN_START_REQ": "scan_start_req_handler",
        "MM_SCAN_CHANNEL_START_IND": "mm_scan_channel_start_ind_handler",
        "MM_SCAN_CHANNEL_END_EARLY": "mm_scan_channel_end_early_handler",
        "MM_SCAN_CHANNEL_END_IND": "mm_scan_channel_end_ind_handler",
        "SCAN_ABORT_REQ": "scan_abort_req_handler",
        "SCAN_CANCEL_REQ": "scan_cancel_req_handler",
        "SCAN_PROBE_TIMER": "scan_probe_req_handler",
    }
    assert "scan_state_handler" not in TABLES
    assert dict(entries["scanu_idle"]) == {
        "SCANU_START_REQ": "scanu_start_req_handler",
        "SCANU_JOIN_REQ": "scanu_join_req_handler",
        "SCANU_RAW_SEND_REQ": "scanu_raw_send_req_handler",
    }
    assert entries["scanu_scanning"] == entries["scanu_joining"]
    assert dict(entries["scanu_scanning"]) == {
        "SCAN_START_CFM": "scan_start_cfm_handler",
        "SCAN_DONE_IND": "scan_done_ind_handler",
        "RXU_MGT_IND": "rxu_mgt_ind_handler_scanu",
    }
    assert dict(entries["scanu_default_state"]) == {
        "SCANU_START_REQ": "ke_msg_save",
        "SCANU_JOIN_REQ": "ke_msg_save",
        "RXU_MGT_IND": "ke_msg_discard",
        "SCANU_RAW_SEND_REQ": "scanu_raw_send_busy_handler",
    }
    state_table = TABLES.split("var scanu_state_handler*", 1)[1].split("\n]", 1)[0]
    assert re.findall(r"addr (\w+)\)", state_table) == ["scanu_idle", "scanu_scanning", "scanu_joining"]


MUTATIONS = {
    # The START handler stops checking the stamp: a stale START runs.
    "start_stamp": ("task", "  if not scanCurrent(param, ScanChannelPendingState): return KeMsgConsumed\n",
                    "  if ke_state_get(TASK_SCAN) != ScanChannelPendingState: return KeMsgConsumed\n"),
    # The END handler stops checking the stamp.
    "end_stamp": ("task", "  if not scanCurrent(param, ScanChannelRunningState): return KeMsgConsumed\n  # The vendor",
                  "  if ke_state_get(TASK_SCAN) != ScanChannelRunningState: return KeMsgConsumed\n  # The vendor"),
    # The END_EARLY handler ends any running dwell (pinned scan_task.o).
    "early_stamp": ("task", "  if scanCurrent(param, ScanChannelRunningState) and scanOnChannel():\n    scan_terminate_channel_request()",
                    "  if ke_state_get(TASK_SCAN) != ScanIdleState:\n    scan_terminate_channel_request()"),
    # A dwell started after an abort probes and stays (pinned scan_task.o).
    "abort_at_start": ("task", "  let stopped = scan_env.abortFlag != 0\n",
                       "  let stopped = false\n"),
    # The next dwell's notices are not freed when it cannot start.
    "notice_leak": ("machine", "    for notice in [start, finish]:\n      if notice != nil: ke_msg_free(keMsgHdrFromPayload(notice))\n    return false",
                    "    return false"),
    # A refused lower request is not answered (dropped).
    "refusal_dropped": ("task", "  scanAnswer(param, SCAN_START_CFM, requester, status)\n  return KeMsgNoFree",
                        "  return KeMsgConsumed"),
    # scanRelease leaves the state.
    "release_state": ("machine", "  else: scanAnswer(request, SCAN_DONE_IND, scan_env.requester, 0)\n  scanGo(ScanIdleState)",
                      "  else: scanAnswer(request, SCAN_DONE_IND, scan_env.requester, 0)"),
    # SCANU takes any SCAN_DONE_IND as its band's end.
    "lower_identity": ("machine", "  if not scanuAwaits(answer): return false\n",
                       "  if answer == nil: return false\n"),
    # A dwell whose END is already queued is asked to leave its channel again.
    "leave_once": ("machine", "  scanOwn.finish != nil\n", "  true\n"),
    # ke_flush frees the lower answer but leaves SCANU waiting for it.
    "flush_scanu": ("flush", "  scanRelease()\n  scanuAbandon()\n", "  scanRelease()\n"),
    # SM's abort no longer checks that the scan is SM's.
    "abort_owner": ("task", "  if param != nil and keMsgHdrFromPayload(param).srcId == TASK_SM and\n      not smAbortOwnsLowerScan():",
                    "  if false:"),
}


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_table_detects_mutations(tmp_path: Path, mutation: str) -> None:
    """Each rule the machines rely on is checked by some row."""
    where, old, new = MUTATIONS[mutation]
    code = harness()
    assert old in code, mutation
    code = code.replace(old, new, 1)
    rows = "".join(row(start, inp) for start in STARTS for inp in INPUTS)
    extra = r'''
block properties:
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  doAssert heap.len == 0
  discard newUpper(SCANU_START_REQ, TASK_SM, 4)
  while states[TASK_SCAN] != ScanChannelPendingState or queue.len != 0: doAssert step()
  smQueueOwnedScanAbort()
  doAssert step()
  let before = probes
  arrive()
  doAssert step() and probes == before, "abort before START: the dwell probed"
  finish("abort property")
  # SM's abort queued for its scan and run after SM moved on.
  discard newUpper(SCANU_START_REQ, TASK_SM, 2)
  while states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
  smQueueOwnedScanAbort()
  smRequest = nil
  while queue.len > 0 and keMsgHdrFromPayload(queue[0]).id != SCAN_ABORT_REQ: doAssert step()
  doAssert step() and scan_env.abortFlag == 0, "SM's late abort stopped the scan"
  finish("late abort property")
  # Two early-end requests for one dwell: it leaves its channel once.
  discard newUpper(SCANU_START_REQ, HostTask, 2)
  while states[TASK_SCAN] != ScanChannelPendingState or queue.len != 0: doAssert step()
  arrive()
  doAssert step() and states[TASK_SCAN] == ScanChannelRunningState
  terminations = 0
  scanEarlyEndRequest()
  scanEarlyEndRequest()
  doAssert step() and step() and terminations == 1, "a dwell left its channel twice"
  finish("early end property")
'''
    import subprocess, shutil
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "mutant.nim"
    path.write_text(code + rows + extra)
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
                             "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}",
                             f"-o:{tmp_path / 'test'}", str(path)],
                            cwd=ROOT, text=True, capture_output=True, timeout=300)
    assert result.returncode != 0 and ("AssertionDefect" in result.stdout + result.stderr), \
        f"mutation {mutation} survived:\n" + result.stdout[-3000:] + result.stderr[-3000:]
