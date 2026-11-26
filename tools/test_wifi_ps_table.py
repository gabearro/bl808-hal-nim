"""Drive the power-save transition machine through every phase and input.

The harness is the real ps_machine.nim (psStart, psSend, psCount, psFinish,
psCancel, psApplyPm and the dwell's PM hold over op.nim's Op) with the real
power_save.nim procedures that start and end transitions (ps_set_mode,
ps_dpsm_update, ps_traffic_status_update, ps_enable_cfm, ps_disable_cfm,
ps_check_tx_status.part.0, ps_tx_null_timer_handle, both handles, ps_init)
and the real mm_set_ps_mode_req_handler, mm_force_idle_req and
chanForceIdle. The platform models only the edges: the TX layer (each null
frame is refused at once or gets exactly one confirmation, from a delivery,
an AC3 flush or a TX reset's drain), the MM timers, the kernel's saved queue
and the MAC's PM register.

Each row starts a transition (an explicit request from ME or the host for PS
off, static or dynamic, a DPSM sleep or wake) with one or two STA VIFs, stops
it at one of its first steps, applies one input there (a confirmation with
each status, a stale confirmation, the TX-null timer, an AC3 flush, a TX reset,
an ME reset, another request, a traffic sample, a dwell on the AP's channel
with a request or traffic in it, a send that completes or is refused inline)
and runs it to quiescence. After every step:

  - a transition is live exactly while psOwn.kind is not idle, and ps.flags
    bits 1 and 2 say which DPSM transition it is;
  - a live transition counts exactly its frames not yet confirmed (plus one
    while it is still sending), and a live sleep has its timer armed;
  - an idle machine holds no request, no count and no timer, and no parked
    mode (bit 4) ever appears;
  - outside a dwell the PM register is PS's choice;
  - every null frame PS sends says PS's PM choice, and none is sent while a
    scan or ROC dwell holds the bit (the MAC would mark it PM=0).

At quiescence PS is idle, every request was answered exactly once (or freed
once by a cancel), nothing is leaked and every stamp handed out is stale.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

POWER = (FW / "power_save.nim").read_text()
TASKS = (FW / "task_handlers.nim").read_text()
KERNEL = (FW / "kernel_mac_channel.nim").read_text()
CHANNEL = (FW / "channel_timer.nim").read_text()
MACHINE = (FW / "ps_machine.nim").read_text()

PS_PROCS = ["ps_init", "ps_set_mode", "ps_check_tx_status_part0_nim", "ps_disable_cfm",
            "ps_traffic_status_update", "ps_tx_null_timer_handle", "ps_disable_cfm_handle",
            "ps_enable_cfm", "ps_enable_cfm_handle", "ps_dpsm_update"]

PS_PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  TASK_API = 11'u8
  MM_SET_PS_MODE_REQ = 0x1F'u16
  MM_SET_PS_MODE_CFM = 0x20'u16
  HW_ACTIVE = 3
  MM_ACTIVE_STATE = 1'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  TxAck = 0x80800000'u32      # Done and acknowledged.
  TxNoAck = 0x80000000'u32    # Done, retry limit reached without an ACK.
  TxFlushed = 0x40000000'u32  # txl_cfm_flush: never completed on air.
const MmSetPsModeReqPayloadSize = sizeof(MmSetPsModeReqPayload).uint32
type
  Vif = object
    next: pointer
    flags, keyPsState, psLastTime: uint32
    vifIdx, vifType, state, staIdx, psNullRetry, uapsdBitmap, psFlags: uint8
    chanCtxt: pointer
  KePs = object
    flags, staPending: uint8
  MmEnv = object
    previousState: uint16
    hardwareMode: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
  TxFrameCallbackScope = object
    vif: uint8
  Frame = object
    sta: uint8
    callback: pointer
    arg: uint32
    pm, done: bool
  Answer = tuple[id: uint16, dest: uint8, message: pointer]
var
  ps: PsEnvView
  params: BlPsParamsView
  vifs: array[MAX_VIFS, Vif]
  vifEnv: VifEnv
  ke: KePs
  mm: MmEnv
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  onChannel: array[MAX_VIFS, bool]
  txResetEpoch: uint32
  meControlCommand, meReservedReply: pointer
  txActiveFrameCallback: ptr TxFrameCallbackScope
  mmState: uint16
  pmRegister, macNow, pmResult: uint32
  frames: seq[Frame]
  nullSendStatus: uint8
  onAlloc, onSend: proc()
  nullTimerArmed, uapsdTimerArmed, clearResult: bool
  answers: seq[Answer]
  savedRequests: seq[pointer]
  reschedules, liveMessages, uapsdArms: int
  losses: seq[uint16]
  tdCfm: seq[tuple[vif: uint8, flag: uint32]]
  lastAnswerTarget: pointer
  tdEntries: array[MAX_VIFS, TdEntryView]
  tdCfmArmed: array[MAX_VIFS, bool]
  tdArms: seq[tuple[vif: uint8, expiry: uint32]]
  channelEnv: tuple[currentCtxt: pointer]
  interrupts = true

proc irqSave(): uint32 =
  result = interrupts.uint32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = saved != 0
proc psEnvView(): ptr PsEnvView = addr ps
proc blPsParamsView(): ptr BlPsParamsView = addr params
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  if index < MAX_VIFS.uint8: addr vifs[index] else: nil
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_INFO_TAB_ENTRIES.uint8: stationEpochs[index] else: 0'u32
proc keEnvPsFlags(): ptr KePs = addr ke
const MACHW_TIMLO_REG = 0x24B00120'u
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macNow
proc chanEnvView(): ptr typeof(channelEnv) = addr channelEnv
proc tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc clearTrafficCounters(td: ptr TdEntryView) =
  td.rxCount = 0
  td.txCount = 0
  td.psRxCount = 0
  td.psTxCount = 0
proc tdEntryForVif(index: uint8): ptr TdEntryView = addr tdEntries[index]
proc mmEnvView(): ptr MmEnv = addr mm
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc macTimeNow(): uint32 = macNow
var logFunc: pointer  # the platform logger (g_bl_ops_funcs[204]), if any
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  logFunc
proc blOpsFunc(slot: int): pointer = nil
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, size.int)
  p
proc chan_is_on_channel(p: pointer): bool {.cdecl.} = onChannel[vifChannelAt(p).vifIdx]
template psUapsdTimer(): pointer = cast[pointer](addr psEnvView().nullRetryLimit)
template psTxNullTimer(): pointer = cast[pointer](addr psEnvView().txNullTimerWord)
proc mm_timer_set(timer: pointer; expiry: uint32) =
  if timer == psTxNullTimer(): nullTimerArmed = true
  elif timer in [cast[pointer](addr tdEntries[0]), cast[pointer](addr tdEntries[1])]:
    tdArms.add((tdEntryAt(timer).vifIdx, expiry))
  else:
    doAssert timer == psUapsdTimer()
    uapsdTimerArmed = true
    inc uapsdArms
proc mm_timer_clear(timer: pointer) =
  if timer == psTxNullTimer(): nullTimerArmed = false
  else:
    doAssert timer == psUapsdTimer()
    uapsdTimerArmed = false
proc wifi_hosal_pm_post_event(event, code: uint32; p: pointer) =
  if p != nil: cast[ptr uint32](p)[] = pmResult
when not defined(realTd):
  proc td_cfm_set_timer(index: uint8; value: uint32) = tdCfm.add((index, value))
proc ke_evt_set(bits: uint32) = discard
proc mm_send_connection_loss_ind(vif: pointer; reason: uint16) = losses.add(reason)
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc newMessage(id: uint16; dest, src: uint8; length: uint32): pointer =
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + 4))
  header.id = id
  header.destId = dest
  header.srcId = src
  header.paramLen = length
  inc liveMessages
  keMsgPayload(header)
proc ke_msg_free(header: ptr KeMsgHdr) =
  dec liveMessages
  dealloc(header)
proc ke_msg_send(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  answers.add((header.id, header.destId, p))
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dest, src: uint8) =
  let header = keMsgHdrFromPayload(p)
  header.id = id
  header.destId = dest
  header.srcId = src
  ke_msg_send(p)
proc ke_msg_alloc_reply(request: pointer; id: uint16; length: uint32): pointer =
  ## ME's reserved reply (meTakeControlReply); no other request has one here.
  if request != meControlCommand or meReservedReply == nil: return nil
  result = meReservedReply
  meReservedReply = nil
  meControlCommand = nil
  let header = keMsgHdrFromPayload(result)
  header.id = id
  header.destId = TASK_ME
  header.srcId = TASK_MM
proc ke_reschedule_saved_messages(task: uint8): bool {.discardable.} =
  doAssert task == TASK_MM
  inc reschedules
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_MM
  mmState
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_MM
  mmState = state
proc mmSetPsModeReqView(p: pointer): ptr MmSetPsModeReqPayload =
  cast[ptr MmSetPsModeReqPayload](p)
proc ps_polling_frame(p: pointer): uint8 {.discardable.} = 0
proc blmac_pwr_mgt_setf(value: uint32) =
  doAssert value <= 1
  pmRegister = (pmRegister and not 4'u32) or (value shl 2)
proc hal_machw_reset(): bool = true
proc rxl_reset(): bool = true
proc mmConfigCancelIdle() = discard
proc ps_uapsd_timer_handle() {.cdecl.} = discard

proc ps_disable_cfm*(env: pointer, statusFlags: uint32) {.exportc, cdecl.}
proc ps_enable_cfm*(env: pointer, status: uint32) {.exportc, cdecl.}
proc ps_check_tx_status_part0_nim*(vifEntry: pointer, completionFn: pointer): uint32
  {.exportc: "ps_check_tx_status_part0_nim", cdecl.}
proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.}
proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.}
proc ps_tx_null_timer_handle*(env: pointer) {.exportc, cdecl.}
proc ps_dpsm_update*(enable: uint32): uint32 {.exportc, cdecl, discardable.}
proc checkNullFrame()

# TX layer. A null frame is refused (1, no confirmation) or accepted (0) and
# then confirmed exactly once: by deliver, by an AC3 flush or a TX reset.
proc vifOfStation(sta: uint8): uint8 =
  for index in 0 ..< MAX_VIFS:
    if vifs[index].staIdx == sta: return index.uint8
  doAssert false, "no VIF for station"
proc txl_frame_send_null_frame(staIdx: uint8; cfmCallback: pointer;
                               cfmArg: uint32): uint8 {.discardable.} =
  # onAlloc: txl_frame_get's pool recovery, before the frame exists (it can
  # flush AC3 and run a TX reset). onSend: after the push, which can complete
  # the frame inline.
  if onAlloc != nil:
    let hook = onAlloc
    onAlloc = nil
    hook()
  checkNullFrame()
  frames.add(Frame(sta: staIdx, callback: cfmCallback, arg: cfmArg,
                   pm: (pmRegister and 4) != 0, done: nullSendStatus != 0))
  if onSend != nil:
    let hook = onSend
    onSend = nil
    hook()
  nullSendStatus
proc deliver(index: int; status: uint32) =
  ## txl_frame_evt or a drain: the frame's one confirmation.
  doAssert not frames[index].done
  frames[index].done = true
  let callback = frames[index].callback
  if callback == nil: return
  var scope = TxFrameCallbackScope(vif: vifOfStation(frames[index].sta))
  let previous = txActiveFrameCallback
  txActiveFrameCallback = addr scope
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(
    cast[pointer](frames[index].arg.uint), status)
  txActiveFrameCallback = previous
proc flushPending() =
  var index = 0
  while index < frames.len:
    if not frames[index].done: deliver(index, TxFlushed)
    inc index
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3
  flushPending()
  clearResult
proc txl_reset(): bool =
  # tx_layer.nim advances the epoch, then drains the queued confirmations.
  inc txResetEpoch
  flushPending()
  true
'''

PS_HELPERS = r'''
proc checkNullFrame() =
  ## Every null frame here is PS's. The MAC marks it with the register's PM
  ## bit: it must be PS's choice, so none may go out while a dwell holds the
  ## bit at 0 (the scanning STA's VIF is on channel during its dwell).
  doAssert (ps.statusFlags and 2) == 0, "a PS null frame was sent during a dwell"
  doAssert ((pmRegister and 4) != 0) == psOwn.pm, "a PS null frame says the wrong PM"
proc request(mode: uint8; fromMe = true): pointer =
  ## An MM_SET_PS_MODE_REQ: ME's forward (with the reply ME reserved for it)
  ## or the host's. lastAnswerTarget is the message its answer will be.
  result = newMessage(MM_SET_PS_MODE_REQ, TASK_MM,
                      if fromMe: TASK_ME else: TASK_API, MmSetPsModeReqPayloadSize)
  mmSetPsModeReqView(result).mode = mode
  lastAnswerTarget = result
  if fromMe:
    doAssert meControlCommand == nil
    meControlCommand = result
    meReservedReply = newMessage(MM_SET_PS_MODE_REQ + 1, TASK_ME, TASK_MM, 0)
    lastAnswerTarget = meReservedReply
proc dispatch(p: pointer): cint =
  ## ke_task_schedule: run the request, keep it saved or free it.
  result = mm_set_ps_mode_req_handler(p)
  if result == KeMsgSaved: savedRequests.add(p)
  elif result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(p))
proc releaseSaved() =
  ## A reschedule moved the saved requests back to the sent queue.
  let waiting = savedRequests
  savedRequests.setLen(0)
  for p in waiting: discard dispatch(p)
proc fireNullTimer(): bool =
  ## mm_timer_schedule: the timer's env word is its argument.
  if not nullTimerArmed: return false
  nullTimerArmed = false
  ps_tx_null_timer_handle(ps.txNullTimerEnv)
  true
proc pending(): int =
  for frame in frames:
    if not frame.done and frame.callback != nil: inc result
proc firstPending(): int =
  for index, frame in frames:
    if not frame.done and frame.callback != nil: return index
  -1
proc answersFor(message: pointer): int =
  for answer in answers:
    if answer.message == message: inc result
proc freeAnswers() =
  for answer in answers: ke_msg_free(keMsgHdrFromPayload(answer.message))
  answers.setLen(0)
proc stations(count: int) =
  vifs[0] = Vif(vifIdx: 0, vifType: VIF_TYPE_STA, state: 1, staIdx: 2)
  vifs[1] = Vif(vifIdx: 1, vifType: 4, staIdx: 0xFF)
  vifs[0].next = nil
  if count == 2:
    vifs[1] = Vif(vifIdx: 1, vifType: VIF_TYPE_STA, state: 1, staIdx: 3)
    vifs[0].next = addr vifs[1]
  vifEnv.activeList.first = addr vifs[0]
proc setup(count = 1) =
  ## An associated STA with PS off: ps_init, then the station(s).
  doAssert liveMessages == 0, "messages leaked: " & $liveMessages
  ps_init()
  params = BlPsParamsView(trafficPeriod: 100, timPeriod: 100, trafficThreshold: 1,
                          nullRetryLimit: 8, txNullTimeout: 50)
  ps.uapsdPeriod = 100
  stations(count)
  onChannel = [true, true]
  ke = default(KePs)
  mm = default(MmEnv)
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  txResetEpoch = 0
  meControlCommand = nil
  meReservedReply = nil
  txActiveFrameCallback = nil
  mmState = MM_ACTIVE_STATE
  pmRegister = 0
  macNow = 1000
  pmResult = 0
  frames.setLen(0)
  nullSendStatus = 0
  onAlloc = nil
  onSend = nil
  uapsdTimerArmed = false
  clearResult = true
  answers.setLen(0)
  savedRequests.setLen(0)
  reschedules = 0
  uapsdArms = 0
  losses.setLen(0)
  tdCfm.setLen(0)
  tdCfmArmed = default(typeof(tdCfmArmed))
  tdArms.setLen(0)
  logFunc = nil
  for index in 0 ..< MAX_VIFS:
    tdEntries[index] = TdEntryView(vifIdx: index.uint8, active: 1)
  channelEnv.currentCtxt = nil
  interrupts = true
proc ackAll() =
  ## Confirm every frame still out, then let the timer fire.
  for round in 0 .. 8:
    let index = firstPending()
    if index < 0: break
    deliver(index, TxAck)
  discard fireNullTimer()
proc enter(mode: uint8; count = 1) =
  ## PS in `mode`, reached through a host request that completed.
  setup(count)
  let p = request(mode, fromMe = false)
  discard dispatch(p)
  ackAll()
  doAssert psOwn.kind == psIdle and answersFor(p) == 1
  freeAnswers()
  frames.setLen(0)
  reschedules = 0
proc staleFrame(index: int) =
  ## A confirmation from an ended transition changes nothing.
  if index >= 0 and not frames[index].done:
    let before = (psOwn, ps.pendingCount, ps.flags, answers.len)
    deliver(index, TxAck)
    doAssert (psOwn, ps.pendingCount, ps.flags, answers.len) == before
proc checkPs(sending = false) =
  ## The machine's invariants (module docstring).
  let live = psOwn.kind != psIdle
  doAssert live == psOwn.op.live
  doAssert ((ps.flags and 2) != 0) == (psOwn.kind == psWake)
  doAssert ((ps.flags and 4) != 0) == (psOwn.kind == psSleep)
  doAssert (ps.flags and 0x10) == 0, "a mode was parked"
  if not live:
    doAssert ps.pendingCount == 0 and not nullTimerArmed and psOwn.request == nil
  elif not sending:
    var counted = 0
    for frame in frames:
      if not frame.done and frame.callback != nil and
          opCurrent(psOwn.op, frame.arg): inc counted
    doAssert ps.pendingCount.int == counted,
      "count " & $ps.pendingCount & " frames " & $counted
    if psOwn.kind == psSleep: doAssert nullTimerArmed
  if (ps.statusFlags and 2) == 0:
    doAssert ((pmRegister and 4) != 0) == psOwn.pm
'''


def ps_source(*, td: bool = False) -> str:
    """The harness. With `td`, the real traffic detector (td_cfm_set_timer and
    td_timer_end) replaces the recording stub."""
    code = "{.define: realTd.}\n" if td else ""
    code += layouts("PsEnvView", "BlPsParamsView", "MmVifIdentity", "KeMsgHdr",
                    "MmSetPsModeReqPayload", "TdEntryView")
    code += PS_PLATFORM + (FW / "op.nim").read_text()
    if td:
        code += procedure((FW / "traffic_detection.nim").read_text(), "td_cfm_set_timer")
    code += procedure(KERNEL, "mmCaptureVif") + procedure(KERNEL, "mmVifCurrent")
    # The whole machine: its record and every proc, in file order.
    code += MACHINE[MACHINE.index("type\n  PsKind"):]
    for name in PS_PROCS:
        code += procedure(POWER, name)
    if td:
        code += procedure(POWER, "td_timer_end")
    code += procedure(TASKS, "mm_set_ps_mode_req_handler")
    code += ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n"
             + procedure(KERNEL, "mm_force_idle_req"))
    code += procedure(CHANNEL, "chanForceIdle")
    return code + PS_HELPERS


# --------------------------------------------------------------------------
# The table
# --------------------------------------------------------------------------

STARTS = {
    # name: (Nim that starts the transition, expected kind)
    "explicit_off_me": ("enter(1, count)\nlet held = request(0)\ndoAssert dispatch(held) == KeMsgNoFree", "psExplicit"),
    "explicit_static_host": ("setup(count)\nlet held = request(1, fromMe = false)\ndoAssert dispatch(held) == KeMsgNoFree", "psExplicit"),
    # Dynamic PS asked again while it is on: traffic meanwhile starts nothing.
    "explicit_dynamic_me": ("enter(2, count)\nlet held = request(2)\ndoAssert dispatch(held) == KeMsgNoFree", "psExplicit"),
    # The first frame finishes while the walk is still sending.
    "explicit_inline": ("setup(count)\nonSend = proc() = deliver(frames.len - 1, TxAck)\n"
                        "let held = request(1)\ndoAssert dispatch(held) == KeMsgNoFree", "psExplicit"),
    # Every frame is refused: the transition ends where it starts.
    "explicit_refused": ("enter(2, count)\nnullSendStatus = 1\nlet held = request(0, fromMe = false)\n"
                         "doAssert dispatch(held) == KeMsgNoFree\ndoAssert psOwn.kind == psIdle\n"
                         "nullSendStatus = 0", "psExplicit"),
    "sleep_inline": ("enter(2, count)\ndiscard ps_traffic_status_update(0, 4)\nackAll()\nframes.setLen(0)\n"
                     "onSend = proc() = deliver(frames.len - 1, TxFlushed)\n"
                     "let held: pointer = nil\ndiscard ps_traffic_status_update(0, 0)", "psSleep"),
    "dpsm_sleep": ("enter(2, count)\ndiscard ps_traffic_status_update(0, 4)\nackAll()\nframes.setLen(0)\n"
                   "doAssert (ps.flags and 0x0F) == 9 and not psOwn.pm\n"
                   "let held: pointer = nil\ndiscard ps_traffic_status_update(0, 0)", "psSleep"),
    "dpsm_wake": ("enter(2, count)\nlet held: pointer = nil\ndiscard ps_traffic_status_update(0, 4)", "psWake"),
}

INPUTS = {
    "ack": "let i = firstPending()\nif i >= 0: deliver(i, TxAck)",
    "no_ack": "let i = firstPending()\nif i >= 0: deliver(i, TxNoAck)",
    "flushed": "let i = firstPending()\nif i >= 0: deliver(i, TxFlushed)",
    "stale": "staleFrame(oldFrame)",
    "timer": "discard fireNullTimer()",
    # A drain confirms frames; none is sent again from inside it.
    "clear_ac3": "let sent = frames.len\ndiscard txl_cntrl_clear_ac(3)\ndoAssert frames.len == sent",
    "tx_reset": "let sent = frames.len\ndoAssert chanForceIdle()\nmmState = MM_ACTIVE_STATE\n"
                "doAssert frames.len == sent",
    "cancel": "heldCancelled = held != nil and psOwn.request == held\npsCancel()\n"
              "if heldCancelled and meReservedReply != nil:\n"
              "  # meControlReset frees ME's reply with its exchange.\n"
              "  ke_msg_free(keMsgHdrFromPayload(meReservedReply))\n  meReservedReply = nil\n"
              "  meControlCommand = nil",
    "request": "let other = request(0, fromMe = false)\nlate.add(other)\n"
               "savedAt = reschedules\n"
               "let idle = psOwn.kind == psIdle\n"
               "doAssert dispatch(other) == (if idle: KeMsgNoFree else: KeMsgSaved)",
    "traffic": "let before = psOwn.op.serial\nlet started = psOwn.kind == psIdle\n"
               "discard ps_traffic_status_update(1, 4)\ndiscard ps_traffic_status_update(1, 0)\n"
               "if not started: doAssert psOwn.op.serial == before",
    "retry_refused": "nullSendStatus = 1\nlet i = firstPending()\nif i >= 0: deliver(i, TxNoAck)\n"
                     "nullSendStatus = 0",
    "retry_inline": "onSend = proc() = deliver(frames.len - 1, TxAck)\nlet i = firstPending()\n"
                    "if i >= 0: deliver(i, TxNoAck)\nonSend = nil",
    # A dwell on the AP's channel: the VIF stays on channel, so only the
    # dwell's hold keeps PS's null frames (which would say PM=0) off the air.
    # A transition that starts during it only records its PM choice and ends
    # at once; the departure and the way home tell the AP.
    "dwell_request": "psDwellBegin()\nlet other = request(1, fromMe = false)\nlate.add(other)\n"
                     "savedAt = reschedules\nlet idle = psOwn.kind == psIdle\n"
                     "discard dispatch(other)\n"
                     "if idle: doAssert psOwn.kind == psIdle and answersFor(other) == 1\nackAll()\n"
                     "doAssert (pmRegister and 4) == 0, \"PM written during a dwell\"\npsDwellEnd()\n"
                     "doAssert ((pmRegister and 4) != 0) == psOwn.pm",
    "dwell_traffic": "psDwellBegin()\nlet idle = psOwn.kind == psIdle\n"
                     "discard ps_traffic_status_update(0, 4)\ndiscard ps_traffic_status_update(0, 0)\n"
                     "if idle: doAssert psOwn.kind == psIdle and not nullTimerArmed\n"
                     "doAssert (pmRegister and 4) == 0, \"PM written during a dwell\"\npsDwellEnd()\n"
                     "doAssert ((pmRegister and 4) != 0) == psOwn.pm",
    "dwell": "psDwellBegin()\ndoAssert (pmRegister and 4) == 0\nlet i = firstPending()\n"
             "if i >= 0: deliver(i, TxAck)\npsDwellEnd()",
}

ROW = r'''
for count in [1, 2]:
  for stop in 0 .. 3:
    var late: seq[pointer]
    var oldFrame = -1
    var heldCancelled = false
    var savedAt = 0
    @START@
    let target = if held == nil: nil else: lastAnswerTarget
    doAssert psOwn.kind in [@KIND@, psIdle]
    # An earlier transition's frame still out (sent unconfirmed).
    frames.add(Frame(sta: vifs[0].staIdx, callback: cast[pointer](ps_enable_cfm),
                     arg: psOwn.op.serial - 1, pm: true))
    oldFrame = frames.len - 1
    checkPs()
    for step in 0 ..< stop:
      let i = firstPending()
      if i >= 0 and i != oldFrame: deliver(i, TxAck)
      checkPs()
    block input:
      @INPUT@
    checkPs()
    # Quiescence: confirm everything, let timers fire, run saved requests.
    for round in 0 .. 6:
      ackAll()
      if savedRequests.len > 0 and psOwn.kind == psIdle:
        doAssert reschedules > savedAt, "the end of a transition did not release MM"
        releaseSaved()
      checkPs()
    doAssert psOwn.kind == psIdle and savedRequests.len == 0
    doAssert not psOwn.op.live
    for frame in frames:
      doAssert not opCurrent(psOwn.op, frame.arg), "a stamp is still live"
    if target != nil:
      doAssert answersFor(target) == (if heldCancelled: 0 else: 1),
        "the held request was answered " & $answersFor(target) & " times"
    for other in late: doAssert answersFor(other) == 1, "a saved request was not answered"
    freeAnswers()
    if meReservedReply != nil:
      ke_msg_free(keMsgHdrFromPayload(meReservedReply))
      meReservedReply = nil
    meControlCommand = nil
    doAssert liveMessages == 0, "messages leaked: " & $liveMessages
'''


def row(start: str, inp: str) -> str:
    code, kind = STARTS[start]
    indent = lambda text, n: "\n".join(" " * n + line for line in text.splitlines())
    body = ROW.replace("@START@", indent(code, 4).lstrip()).replace("@KIND@", kind)
    body = body.replace("@INPUT@", indent(INPUTS[inp], 6).lstrip())
    return body


@pytest.mark.parametrize("start", sorted(STARTS))
def test_ps_transition_table(tmp_path: Path, start: str) -> None:
    code = ps_source()
    for inp in INPUTS:
        code += f"\n# --- {start} x {inp}\n" + "block:\n" + "\n".join(
            "  " + line for line in row(start, inp).splitlines())
    run_program(tmp_path, "checked", code)


# Each rule the table relies on, broken in the real source: the table fails.
MUTATIONS = {
    "finish_keeps_timer": (MACHINE, "  mm_timer_clear(psTxNullTimer())\n  ps.pendingCount = 0\n"
                           "  ps.flags = ps.flags and not 0x06'u8\n  opFinish(psOwn.op)\n  # The commits",
                           "  ps.pendingCount = 0\n  ps.flags = ps.flags and not 0x06'u8\n"
                           "  opFinish(psOwn.op)\n  # The commits"),
    "no_stamp_check": (MACHINE, "  if not opCurrent(psOwn.op, opEnvStamp(env)): return\n  let vifEntry",
                       "  if not psOwn.op.live: return\n  let vifEntry"),
    "finish_keeps_mm_saved": (MACHINE, "  if request != nil: psAnswer(request)\n"
                              "  discard ke_reschedule_saved_messages(TASK_MM)",
                              "  if request != nil: psAnswer(request)"),
    "no_reserved_count": (MACHINE, "  ps.pendingCount = 1\n  case kind", "  ps.pendingCount = 0\n  case kind"),
    "handler_overlaps": (TASKS, "  if psOwn.kind != psIdle:\n    return KeMsgSaved\n", ""),
    "dpsm_overlaps": (POWER, "  if psOwn.kind != psIdle: return 0\n  let ps = psEnvView()\n  let waking",
                      "  let ps = psEnvView()\n  let waking"),
    "sleep_without_timer": (POWER, "    mm_timer_set(psTxNullTimer(), macTimeNow() + blPsParamsView().txNullTimeout)\n",
                            ""),
    "flushed_retries": (MACHINE, "  if (status and (TxDone or TxAcked)) == TxDone and",
                        "  if (status and TxAcked) == 0 and"),
    "dwell_writes_pm": (MACHINE, "  if not psDwell(): blmac_pwr_mgt_setf(pm.uint32)",
                        "  blmac_pwr_mgt_setf(pm.uint32)"),
    "dwell_sends_explicit": (POWER, "        if not psDwell(): psSend(node, callback, stamp)",
                             "        psSend(node, callback, stamp)"),
    "dwell_sends_dpsm": (POWER, "      if vif.state != 0 and chan_is_on_channel(node) and not psDwell():",
                         "      if vif.state != 0 and chan_is_on_channel(node):"),
}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_ps_transition_table_catches(tmp_path: Path, mutation: str, monkeypatch) -> None:
    source, old, new = MUTATIONS[mutation]
    assert source.count(old) == 1, mutation
    names = {id(MACHINE): "MACHINE", id(TASKS): "TASKS", id(POWER): "POWER"}
    monkeypatch.setitem(globals(), names[id(source)], source.replace(old, new))
    failed = 0
    for start in sorted(STARTS):
        code = ps_source()
        for inp in INPUTS:
            code += f"\n# --- {start} x {inp}\n" + "block:\n" + "\n".join(
                "  " + line for line in row(start, inp).splitlines())
        (tmp_path / start).mkdir()
        try:
            run_program(tmp_path / start, "checked", code)
        except AssertionError:
            failed += 1
    assert failed, f"{mutation} was not caught"
