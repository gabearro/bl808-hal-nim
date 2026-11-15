type CallbackBinding[T] = object
  handler: T
  context: pointer
  generation: uint32

# Unregistration cancels pending snapshots, not calls already admitted below.
# Callers keep their context alive until any in-flight callback returns.

template callbackIrqSave(): uint =
  block:
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "asm volatile(\"\" ::: \"memory\");".}
    saved

template callbackIrqRestore(saved: uint) =
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  if (saved and 8) != 0:
    enableInterrupts()

proc setCallback[T](slot: var CallbackBinding[T]; callback: T; context: pointer) =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  slot.handler = callback
  slot.context = context
  inc slot.generation

proc clearCallback[T](slot: var CallbackBinding[T]) =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  slot.handler = nil
  slot.context = nil
  inc slot.generation

proc snapshotCallback[T](slot: var CallbackBinding[T]): CallbackBinding[T] =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  let handler = slot.handler
  let context = slot.context
  let generation = slot.generation
  CallbackBinding[T](handler: handler, context: context, generation: generation)

proc claimCallback[T](slot: var CallbackBinding[T]; pending: CallbackBinding[T]): bool =
  let saved = callbackIrqSave()
  defer: callbackIrqRestore(saved)
  # A successful check admits this call; user code runs after IRQ restoration.
  pending.handler != nil and slot.generation == pending.generation and
    slot.handler == pending.handler and slot.context == pending.context
