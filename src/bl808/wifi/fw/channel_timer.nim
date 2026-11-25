# Arm, publish, capture, and invalidate run under the MM timer critical section.
type
  ChanTbttTimerOwner = object
    serial, vifEpoch, binding, allocation: uint32
    node, channel: pointer
    targetTime: uint32
    vif, index: uint8
    prepared, valid: bool
  ChanCtxtTimerOwner = object
    serial, allocation: uint32
    context, current, scheduled: pointer
    index, phase: uint8
    prepared, valid: bool
  ChanConnlessTimerOwner = object
    serial, generation: uint32
    prepared, valid: bool

var
  chanTbttTimerOwner {.wifiCtrl.}: ChanTbttTimerOwner
  chanCtxtTimerOwner {.wifiCtrl.}: ChanCtxtTimerOwner
  chanConnlessTimerOwner {.wifiCtrl.}: ChanConnlessTimerOwner

proc chanForceIdle(): bool =
  ## Drain TX for a channel switch. Queued radio deadlines and SM exchanges
  ## are not frames and stay owed; only a nested second reset fails the drain.
  let saved = irqSave()
  defer: irqRestore(saved)
  let previous = txResetEpoch
  mm_force_idle_req() and txResetEpoch == previous + 1'u32

proc chanTimerInvalidate(timer: pointer = nil) =
  if timer == nil or timer == chanTbttTimer():
    inc chanTbttTimerOwner.serial
    chanTbttTimerOwner.prepared = false
    chanTbttTimerOwner.valid = false
  if timer == nil or timer == chanCtxtOpTimer():
    inc chanCtxtTimerOwner.serial
    chanCtxtTimerOwner.prepared = false
    chanCtxtTimerOwner.valid = false
  if timer == nil or timer == chanConnLessDelayTimer():
    inc chanConnlessTimerOwner.serial
    chanConnlessTimerOwner.prepared = false
    chanConnlessTimerOwner.valid = false

proc chanCtxtTimerArming(timer: pointer) =
  chanTimerInvalidate(timer)
  if mmTimerAt(timer).callback != cast[pointer](chan_ctxt_op_evt): return
  let context = cast[pointer](mmTimerAt(timer).env)
  if context == nil: return
  for index in 0'u8 ..< chanCtxtEpochs.len.uint8:
    let ctxt = chanCtxtForIdx(index)
    if context != cast[pointer](ctxt): continue
    if ctxt.contextIndexOrMarker != index or ctxt.status notin {2'u8, 3, 4}: return
    chanCtxtTimerOwner.context = context
    chanCtxtTimerOwner.current = chanEnvView().currentCtxt
    chanCtxtTimerOwner.scheduled = chanEnvView().scheduledCtxt
    chanCtxtTimerOwner.index = index
    chanCtxtTimerOwner.phase = if ctxt.status == 4: 4'u8 else: 2'u8
    chanCtxtTimerOwner.allocation = chanCtxtEpochs[index]
    chanCtxtTimerOwner.prepared = true
    return

proc chanTimerArming(timer: pointer) =
  if timer == chanConnLessDelayTimer():
    chanTimerInvalidate(timer)
    if mmTimerAt(timer).callback != cast[pointer](chan_conn_less_delay_evt) or
        (chanEnvView().flags and 0x10) == 0:
      return
    # Later scan/ROC requests may join this gate before its deadline.
    chanConnlessTimerOwner.generation = chanConnlessGeneration
    chanConnlessTimerOwner.prepared = true
    return
  if timer == chanCtxtOpTimer():
    chanCtxtTimerArming(timer)
    return
  if timer != chanTbttTimer(): return
  chanTimerInvalidate(timer)
  if mmTimerAt(timer).callback != cast[pointer](chan_tbtt_switch_evt): return
  let nodePtr = chanTbttDeferredSlot()[]
  if nodePtr == nil: return
  let node = chanTbttNodeAt(nodePtr)
  if node.state != 1 or node.vifIdx >= MAX_VIFS.uint8: return
  let vif = vifChannelForIdx(node.vifIdx)
  let channel = vif.chanCtxt
  if channel == nil: return
  for index in 0'u8 ..< chanCtxtEpochs.len.uint8:
    let ctxt = chanCtxtForIdx(index)
    if cast[pointer](ctxt) != channel: continue
    if ctxt.contextIndexOrMarker != index or ctxt.status == 0: return
    chanTbttTimerOwner.node = nodePtr
    chanTbttTimerOwner.channel = channel
    chanTbttTimerOwner.targetTime = node.targetTime
    chanTbttTimerOwner.vif = node.vifIdx
    chanTbttTimerOwner.index = index
    chanTbttTimerOwner.vifEpoch = rxVifEpochs[node.vifIdx]
    chanTbttTimerOwner.binding = chanCtxtLinkEpochs[node.vifIdx]
    chanTbttTimerOwner.allocation = chanCtxtEpochs[index]
    chanTbttTimerOwner.prepared = true
    return

proc chanTimerPublished(timer: pointer) =
  if timer == chanConnLessDelayTimer():
    if chanConnlessTimerOwner.prepared:
      chanConnlessTimerOwner.prepared = false
      chanConnlessTimerOwner.valid = true
    return
  if timer == chanCtxtOpTimer():
    if chanCtxtTimerOwner.prepared:
      chanCtxtTimerOwner.prepared = false
      chanCtxtTimerOwner.valid = true
    return
  if timer != chanTbttTimer() or not chanTbttTimerOwner.prepared: return
  chanTbttTimerOwner.prepared = false
  chanTbttTimerOwner.valid = true

proc chanTimerCapture(timer: pointer): uint32 =
  if timer == chanTbttTimer(): chanTbttTimerOwner.serial
  elif timer == chanCtxtOpTimer(): chanCtxtTimerOwner.serial
  elif timer == chanConnLessDelayTimer(): chanConnlessTimerOwner.serial
  else: 0'u32

proc chanConnlessTimerPending(generation: uint32): bool =
  chanConnlessTimerOwner.valid and
    chanConnlessTimerOwner.generation == generation

proc chanConnlessTimerDispatch(callback: pointer; serial: uint32): bool =
  if callback != cast[pointer](chan_conn_less_delay_evt): return false
  result = true
  let saved = irqSave()
  defer: irqRestore(saved)
  if serial != chanConnlessTimerOwner.serial or
      not chanConnlessTimerPending(chanConnlessGeneration) or
      (chanEnvView().flags and 0x10) == 0:
    return
  chanConnlessTimerOwner.valid = false
  chanConnlessDelayEvent()

proc chanCtxtTimerCurrent(): bool =
  ## A context is its slot and allocation epoch; TPC and bandwidth updates
  ## edit its definition in place without ending its operation.
  let owner = addr chanCtxtTimerOwner
  if not owner.valid or chanCtxtEpochs[owner.index] != owner.allocation:
    return false
  let ctxt = chanCtxtForIdx(owner.index)
  let env = chanEnvView()
  let phase = owner.phase
  # A pending switch does not own the current scan dwell's end deadline.
  let operatingScan = owner.index == 3 and phase == 4 and
    ctxt.status == 4 and owner.current == owner.context
  ctxt.contextIndexOrMarker == owner.index and
    (ctxt.status == 3 or ctxt.status == phase) and env.currentCtxt == owner.current and
    (operatingScan or env.scheduledCtxt == owner.scheduled)

proc chanCtxtTimerDispatch(callback, argument: pointer; serial: uint32): bool =
  if callback != cast[pointer](chan_ctxt_op_evt): return false
  result = true
  let saved = irqSave()
  defer: irqRestore(saved)
  if chanCtxtTimerOwner.serial != serial or chanCtxtTimerOwner.context != argument or
      not chanCtxtTimerCurrent():
    return
  chanCtxtTimerOwner.valid = false
  chanCtxtOpEvent(argument, saved)

proc chanTimerDispatch(timer, callback, argument: pointer; serial: uint32): bool =
  if timer == chanConnLessDelayTimer():
    return chanConnlessTimerDispatch(callback, serial)
  if timer == chanCtxtOpTimer():
    return chanCtxtTimerDispatch(callback, argument, serial)
  if timer != chanTbttTimer() or callback != cast[pointer](chan_tbtt_switch_evt):
    return false
  result = true
  let saved = irqSave()
  defer: irqRestore(saved)
  if not chanTbttTimerOwner.valid or serial != chanTbttTimerOwner.serial or
      argument != chanTbttTimerOwner.node or
      rxVifEpochs[chanTbttTimerOwner.vif] != chanTbttTimerOwner.vifEpoch or
      chanCtxtLinkEpochs[chanTbttTimerOwner.vif] != chanTbttTimerOwner.binding or
      chanCtxtEpochs[chanTbttTimerOwner.index] != chanTbttTimerOwner.allocation:
    return
  let node = chanTbttNodeAt(argument)
  let ctxt = chanCtxtForIdx(chanTbttTimerOwner.index)
  if node.vifIdx != chanTbttTimerOwner.vif or node.state != 1 or
      node.targetTime != chanTbttTimerOwner.targetTime or
      chanTbttDeferredSlot()[] != argument or
      vifChannelForIdx(chanTbttTimerOwner.vif).chanCtxt != chanTbttTimerOwner.channel or
      cast[pointer](ctxt) != chanTbttTimerOwner.channel or
      ctxt.contextIndexOrMarker != chanTbttTimerOwner.index or ctxt.status == 0:
    return
  # Consume before callback work can arm another timer at the same address.
  chanTbttTimerOwner.valid = false
  chanTbttSwitchEvent(argument, saved)
