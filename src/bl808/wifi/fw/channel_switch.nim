# One channel switch at a time, as in chan.o. chan_switch_start begins it and
# chanSwitchFinish is its only end: chan_pre_switch_channel finishes it on
# arrival, and an abandonment (no context left to go to, lost request)
# finishes it too. A context is identified by its slot and
# chanCtxtEpochs[slot]. A switch to a context that leaves the pool is
# redirected here, at retirement, as chan.o chan_ctxt_unlink does, so the
# callbacks below need no other notion of identity.
#
# The switch's MM_FORCE_IDLE_REQ is a static kernel message that is never
# freed. While it is queued or saved, a new switch reuses it instead of
# sending it again, so it can never be linked into a kernel queue twice. When
# MM runs it, chanSwitchLanded serves whatever the switch needs at that point
# and always hands MM back out of HW_ACTIVE.
type
  ChanSwitchPhase = enum
    swNone        ## no switch in flight
    swQueued      ## waiting for MM to run the force-idle request
    swProtecting  ## PM=1 nulls / self-CTS on the source channel are outstanding
    swDeparting   ## protection done; the departure is waiting for MM
  ChanSwitchRequest = object
    header: KeMsgHdr
    callback: pointer   ## the 4-byte payload: the callback MM runs

var
  chanSw {.wifiCtrl.}: tuple[phase: ChanSwitchPhase; serial: uint32; building, pmSet: bool]
  chanSwitchRequest {.wifiCtrl.}: ChanSwitchRequest
  chanSwitchRequestQueued {.wifiCtrl.}: bool

proc chanSwitchSerial(): uint32 = chanSw.serial

proc chanSwitchSlot(target: pointer): int =
  ## The pool slot of a live context, or -1.
  for index in 0'u8 ..< 5:
    if target == cast[pointer](chanCtxtForIdx(index)):
      return (if chanCtxtForIdx(index).contextIndexOrMarker == index: index.int else: -1)
  -1

proc mmLeaveHwActive() =
  if ke_state_get(TASK_MM) == HW_ACTIVE.uint16: mm_back_to_host_idle()

proc chanSwitchLanded() {.cdecl.}

proc chanSwitchSend() =
  ## Ask MM to run the switch's force-idle request.
  chanEnvView().switchPending = 1
  if chanSwitchRequestQueued: return
  chanSwitchRequestQueued = true
  chanSwitchRequest.header = KeMsgHdr(id: MM_FORCE_IDLE_REQ_MSG, destId: TASK_MM,
    srcId: TASK_NONE, paramLen: 4)
  chanSwitchRequest.callback = cast[pointer](chanSwitchLanded)
  ke_msg_send(addr chanSwitchRequest.callback)

proc chanSwitchTake(request: pointer): cint =
  ## MM consumed a force-idle request. The switch's own is static: never free it.
  if request != addr chanSwitchRequest.callback: return KeMsgConsumed
  chanSwitchRequestQueued = false
  KeMsgNoFree

proc chanSwitchBegin() =
  ## chan_switch_start has published scheduledCtxt.
  inc chanSw.serial
  chanSw.phase = swQueued
  chanSwitchSend()

proc chanConnlessRequeue() =
  ## A scan (0x08) or ROC (0x04) dwell that was never entered goes back to
  ## its pending bit (0x02/0x01) and the connectionless gate is armed again,
  ## so TASK_SCAN, which waits in state 2 for the dwell, is not stranded.
  let env = chanEnvView()
  var flags = env.flags
  if (flags and 0x08) != 0 and env.currentCtxt != cast[pointer](chanCtxtForIdx(3)):
    flags = (flags and not 0x08'u8) or 0x02
  if (flags and 0x04) != 0 and env.currentCtxt != cast[pointer](chanCtxtForIdx(4)):
    flags = (flags and not 0x04'u8) or 0x01
  if flags == env.flags: return
  env.flags = flags and not 0x10'u8
  chan_conn_less_delay_prog()

proc chanSwitchFinish(arrived: bool) =
  ## The only end of a switch. On arrival chan_pre_switch_channel has already
  ## made the destination current. Otherwise the switch is abandoned: the
  ## destination goes back to waiting, an unentered scan/ROC dwell goes back
  ## to its gate, the departure-timeout flag (0x20) is cleared as arrival
  ## clears it, MM leaves HW_ACTIVE and the PM bit set for the protection
  ## frames is cleared again on the context that stays current.
  let saved = irqSave()
  defer: irqRestore(saved)
  let env = chanEnvView()
  let pmSet = chanSw.pmSet
  inc chanSw.serial
  chanSw.phase = swNone
  chanSw.building = false
  chanSw.pmSet = false
  env.scanDelayCount = 0
  env.connlessDelayCount = 0
  if arrived: return
  env.switchPending = 0
  env.flags = env.flags and not 0x20'u8   # its departure deadline, if it passed
  let destination = env.scheduledCtxt
  env.scheduledCtxt = nil
  if destination != nil:
    if chanCtxtAt(destination).status in {2'u8, 3}: chanCtxtAt(destination).status = 1
    mm_timer_clear(chanCtxtOpTimer())
  chanConnlessRequeue()
  # Inside a TX reset its caller still owns MM's state.
  if not txResetActive: mmLeaveHwActive()
  let current = env.currentCtxt
  if pmSet and current != nil and chanCtxtAt(current).contextIndexOrMarker <= 2 and
      psAwake():
    blmac_pwr_mgt_setf(0)

proc chanSwitchRedirect() =
  ## The destination leaves the pool. As in chan.o chan_ctxt_unlink, the
  ## switch goes on to another operating context: CDE picks it when several
  ## remain, the only one is taken when one remains. With none left, or none
  ## picked, the switch is abandoned.
  let env = chanEnvView()
  let gone = env.scheduledCtxt
  if env.ctxtCount > 1:
    var event = 1'u8
    chan_cde_evt(addr event)
  elif env.ctxtCount == 1:
    env.scheduledCtxt = cast[pointer](env.activeList.first)
  if env.scheduledCtxt in [gone, nil]: chanSwitchFinish(arrived = false)

proc chanSwitchRetire(target: pointer) =
  ## A context leaves the pool. A switch away from it carries on and a switch
  ## to it is redirected (vendor).
  let saved = irqSave()
  defer: irqRestore(saved)
  let env = chanEnvView()
  if env.currentCtxt == target: env.currentCtxt = nil
  if target != nil and env.scheduledCtxt == target: chanSwitchRedirect()

proc chanSwitchReset() =
  ## Kernel and channel (re)initialisation: drop the switch and its request.
  let saved = irqSave()
  defer: irqRestore(saved)
  proc matches(node: ptr CoListHdr; header: pointer): bool {.cdecl.} =
    cast[pointer](node) == header
  if chanSwitchRequestQueued:
    for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:
      discard ke_queue_extract(queue, matches, addr chanSwitchRequest.header)
    chanSwitchRequestQueued = false
  inc chanSw.serial
  chanSw.phase = swNone
  chanSw.building = false
  chanSw.pmSet = false
  let env = chanEnvView()
  env.scheduledCtxt = nil
  env.switchPending = 0
  env.scanDelayCount = 0
  env.connlessDelayCount = 0

proc chanSwitchForget(header: pointer): bool =
  ## ke_msg_free never frees the static request. Should the kernel ever drop
  ## it, the switch it carried cannot proceed and is abandoned.
  if header != addr chanSwitchRequest.header: return false
  chanSwitchRequestQueued = false
  if chanSw.phase in {swQueued, swDeparting}: chanSwitchFinish(arrived = false)
  true

proc chanSwitchDepart() =
  ## The protection frames are done: force idle and leave the source channel.
  ## The last confirmation can come from a TX reset's drain; the departure
  ## then runs from MM after the reset, never inside it. A failed forced idle
  ## (its recovery is already posted) is retried the same way.
  let serial = chanSw.serial
  if txResetActive or not chanForceIdle():
    if chanSw.serial == serial:
      chanSw.phase = swDeparting
      chanSwitchSend()
    return
  if chanSw.serial != serial:
    mmLeaveHwActive()   # the forced idle's drain ended the switch
    return
  chan_pre_switch_channel()

proc chanSwitchLanded() {.cdecl.} =
  ## MM ran the switch's request and is HW_ACTIVE.
  chanEnvView().switchPending = 0
  case chanSw.phase
  of swQueued: chan_goto_idle_cb()
  of swDeparting: chanSwitchDepart()
  of swNone, swProtecting: discard
  # Every path out of a switch callback hands MM back.
  mmLeaveHwActive()
