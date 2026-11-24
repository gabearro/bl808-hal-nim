# Arm, publish, capture, and invalidate run under the MM timer critical section.
type
  ChanTbttTimerOwner = object
    serial, resetEpoch, vifEpoch, binding, allocation: uint32
    node, channel: pointer
    targetTime: uint32
    definition: ChanCtxtDefView
    vif, index: uint8
    prepared, valid: bool
  ChanCtxtTimerOwner = object
    serial, resetEpoch, allocation: uint32
    context, current, scheduled: pointer
    definition: ChanCtxtDefView
    index, phase: uint8
    prepared, valid: bool
  ChanConnlessTimerOwner = object
    serial, resetEpoch, generation: uint32
    prepared, valid: bool

var
  chanTbttTimerOwner {.wifiCtrl.}: ChanTbttTimerOwner
  chanCtxtTimerOwner {.wifiCtrl.}: ChanCtxtTimerOwner
  chanConnlessTimerOwner {.wifiCtrl.}: ChanConnlessTimerOwner

proc chanForceIdle(): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  let previous = txResetEpoch
  if not mm_force_idle_req() or txResetEpoch != previous + 1'u32: return false
  # A channel switch drains TX but does not cancel these already queued deadlines.
  if chanTbttTimerOwner.valid and chanTbttTimerOwner.resetEpoch == previous:
    chanTbttTimerOwner.resetEpoch = txResetEpoch
  if chanConnlessTimerOwner.valid and chanConnlessTimerOwner.resetEpoch == previous:
    chanConnlessTimerOwner.resetEpoch = txResetEpoch
  smScanPreserveAcrossChannelReset(previous)
  smRegistrationPreserveAcrossChannelReset(previous)
  true

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
    chanCtxtTimerOwner.definition = ctxt.channel
    chanCtxtTimerOwner.index = index
    chanCtxtTimerOwner.phase = if ctxt.status == 4: 4'u8 else: 2'u8
    chanCtxtTimerOwner.resetEpoch = txResetEpoch
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
    chanConnlessTimerOwner.resetEpoch = txResetEpoch
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
    chanTbttTimerOwner.definition = ctxt.channel
    chanTbttTimerOwner.vif = node.vifIdx
    chanTbttTimerOwner.index = index
    chanTbttTimerOwner.resetEpoch = txResetEpoch
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
    chanConnlessTimerOwner.generation == generation and
    chanConnlessTimerOwner.resetEpoch == txResetEpoch

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

proc chanCtxtTimerCurrent(resetEpoch: uint32): bool =
  let owner = addr chanCtxtTimerOwner
  if not owner.valid or owner.resetEpoch != resetEpoch or
      chanCtxtEpochs[owner.index] != owner.allocation:
    return false
  let ctxt = chanCtxtForIdx(owner.index)
  let env = chanEnvView()
  let phase = owner.phase
  # A pending switch does not own the current scan dwell's end deadline.
  let operatingScan = owner.index == 3 and phase == 4 and
    ctxt.status == 4 and owner.current == owner.context
  ctxt.contextIndexOrMarker == owner.index and
    (ctxt.status == 3 or ctxt.status == phase) and env.currentCtxt == owner.current and
    (operatingScan or env.scheduledCtxt == owner.scheduled) and
    ctxt.channel.band == owner.definition.band and
    ctxt.channel.chanType == owner.definition.chanType and
    ctxt.channel.primFreq == owner.definition.primFreq and
    ctxt.channel.centerFreq1 == owner.definition.centerFreq1 and
    ctxt.channel.centerFreq2 == owner.definition.centerFreq2

proc chanForceIdleForDeparture(target: pointer): bool =
  let saved = irqSave()
  defer: irqRestore(saved)
  if target == nil or chanEnvView().scheduledCtxt != target: return false
  let owner = addr chanCtxtTimerOwner
  let previous = txResetEpoch
  let serial = owner.serial
  let carryDeadline = owner.phase == 2 and owner.context == target and
    owner.scheduled == target and chanCtxtTimerCurrent(previous)
  if not chanForceIdle(): return false
  # The switch's own TX drain precedes its protection-frame wait. Keep the
  # original deadline only if the drain did not retire or replace its owner.
  if carryDeadline and owner.serial == serial and chanCtxtTimerCurrent(previous):
    owner.resetEpoch = txResetEpoch
  true

proc chanCtxtTimerDispatch(callback, argument: pointer; serial: uint32): bool =
  if callback != cast[pointer](chan_ctxt_op_evt): return false
  result = true
  let saved = irqSave()
  defer: irqRestore(saved)
  if chanCtxtTimerOwner.serial != serial or chanCtxtTimerOwner.context != argument or
      not chanCtxtTimerCurrent(txResetEpoch):
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
      txResetEpoch != chanTbttTimerOwner.resetEpoch or
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
      ctxt.contextIndexOrMarker != chanTbttTimerOwner.index or ctxt.status == 0 or
      ctxt.channel.band != chanTbttTimerOwner.definition.band or
      ctxt.channel.chanType != chanTbttTimerOwner.definition.chanType or
      ctxt.channel.primFreq != chanTbttTimerOwner.definition.primFreq or
      ctxt.channel.centerFreq1 != chanTbttTimerOwner.definition.centerFreq1 or
      ctxt.channel.centerFreq2 != chanTbttTimerOwner.definition.centerFreq2:
    return
  # Consume before callback work can arm another timer at the same address.
  chanTbttTimerOwner.valid = false
  chanTbttSwitchEvent(argument, saved)
