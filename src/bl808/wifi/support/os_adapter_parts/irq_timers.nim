## IRQ, workqueue, and timer adapter callbacks.

proc osIrqAttach(n: int32; f, arg: pointer) {.cdecl.} =
  discard arg
  if f != nil and n >= 0:
    bl808_register_trap_handler(n.uint32, cast[IrqHandler](f))
proc osIrqEnable(n: int32) {.cdecl.} =
  if n >= 0: bl808_enable_peripheral_irq(n.uint32, 1)
proc osIrqDisable(n: int32) {.cdecl.} =
  if n >= 0: bl808_disable_peripheral_irq(n.uint32)
proc osWorkqueueCreate(): pointer {.cdecl.} = osTaskGetCurrent()
proc osWorkqueueSubmit(work, worker, argv: pointer; tick: clong): cint {.cdecl.} =
  discard worker
  discard argv
  discard tick
  if work == nil or work != osTaskGetCurrent():
    return 1
  osTaskNotify(work)
  0

proc osTimerLink(timer: pointer): ptr ptr SimpleTimer =
  var link = addr osTimerHead
  while link[] != nil and cast[pointer](link[]) != timer:
    link = addr link[].next
  if link[] != nil: link else: nil

proc osTimerIntervalUs(tSec, tNsec: clong): uint64 =
  if tSec < 0 or tNsec < 0 or tNsec >= 1_000_000_000 or
      tSec.uint64 > high(int64).uint64 div 1_000_000'u64:
    return 0
  let milliseconds = tSec.uint64 * 1000'u64 + tNsec.uint64 div 1_000_000'u64
  if milliseconds == 0:
    if tSec == 0 and tNsec == 0: return 0
    return 1000'u64
  milliseconds * 1000'u64

proc osTimerCreate(fn, argv: pointer): pointer {.cdecl.} =
  if fn == nil:
    return nil
  result = c_calloc(1, sizeof(SimpleTimer).csize_t)
  if result == nil:
    return
  let timer = cast[ptr SimpleTimer](result)
  timer.callback = fn
  timer.arg = argv
  let saved = osEnterCritical()
  timer.next = osTimerHead
  osTimerHead = timer
  osExitCritical(saved)

proc osTimerDelete(timer: pointer; tick: uint32): cint {.cdecl.} =
  discard tick
  let saved = osEnterCritical()
  let link = osTimerLink(timer)
  if link == nil:
    osExitCritical(saved)
    return 0
  let state = link[]
  link[] = state.next
  state.next = nil
  state.header.deleted = true
  state.active = false
  let dispose = state.header.users == 0
  osExitCritical(saved)
  if dispose:
    c_free(timer)
  1

proc osTimerStart(timer: pointer; tSec, tNsec: clong;
                  periodic: bool): cint =
  if timer == nil:
    return 1
  let interval = osTimerIntervalUs(tSec, tNsec)
  if interval == 0:
    return 1
  var now: uint64
  if not sampleMtimeUs(now):
    return 1
  let saved = osEnterCritical()
  let link = osTimerLink(timer)
  if link == nil:
    osExitCritical(saved)
    return 1
  let state = link[]
  state.periodUs = interval
  state.deadlineUs = now + interval
  state.periodic = periodic
  state.active = true
  osExitCritical(saved)
  vendorNotifyWork()
  0

proc osTimerNextDelayUs(nowUs: uint64): uint64 =
  ## Timer objects are not stored in deadline order. Inspect them under the
  ## same lock as osTimerStart and osTimerPoll, then return a relative delay.
  result = high(uint64)
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  var timer = osTimerHead
  while timer != nil:
    if timer.active and not timer.running:
      let remaining = cast[int64](timer.deadlineUs - nowUs)
      if remaining <= 0:
        return 0
      result = min(result, remaining.uint64)
    timer = timer.next

proc osTimerStartOnce(timer: pointer; tSec, tNsec: clong): cint {.cdecl.} =
  osTimerStart(timer, tSec, tNsec, false)

proc osTimerStartPeriodic(timer: pointer; tSec, tNsec: clong): cint {.cdecl.} =
  osTimerStart(timer, tSec, tNsec, true)

proc osTimerPoll() =
  let irqState = osEnterCritical()
  osExitCritical(irqState)
  if (irqState and 8'u32) == 0:
    return
  var now: uint64
  if not sampleMtimeUs(now):
    return
  var budget = 16
  while budget != 0:
    dec budget
    let saved = osEnterCritical()
    var link = addr osTimerHead
    while link[] != nil:
      if link[].active and not link[].running and
          cast[int64](now - link[].deadlineUs) >= 0:
        break
      link = addr link[].next
    if link[] == nil:
      osExitCritical(saved)
      return
    let timer = link[]
    if timer.header.users == high(uint32):
      osExitCritical(saved)
      return
    inc timer.header.users
    timer.running = true
    let callback = timer.callback
    let arg = timer.arg
    if timer.periodic:
      timer.deadlineUs = now + timer.periodUs
    else:
      timer.active = false
    if timer.next != nil:
      link[] = timer.next
      timer.next = nil
      var tail = addr osTimerHead
      while tail[] != nil:
        tail = addr tail[].next
      tail[] = timer
    osExitCritical(saved)
    try:
      cast[proc(arg: pointer) {.cdecl.}](callback)(arg)
    finally:
      let callbackSaved = osEnterCritical()
      timer.running = false
      osExitCritical(callbackSaved)
      osObjectRelease(cast[pointer](timer))
