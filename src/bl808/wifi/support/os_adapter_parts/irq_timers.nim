## IRQ, workqueue, and timer adapter callbacks.

proc osIrqAttach(n: int32; f, arg: pointer) {.cdecl.} =
  discard arg
  if f != nil and n >= 0:
    bl808_register_trap_handler(n.uint32, cast[IrqHandler](f))
proc osIrqEnable(n: int32) {.cdecl.} =
  if n >= 0: bl808_enable_peripheral_irq(n.uint32, 1)
proc osIrqDisable(n: int32) {.cdecl.} =
  if n >= 0: bl808_disable_peripheral_irq(n.uint32)
proc osWorkqueueCreate(): pointer {.cdecl.} = nil
proc osWorkqueueSubmit(work, worker, argv: pointer; tick: clong): cint {.cdecl.} =
  discard work; discard worker; discard argv; discard tick; 0
proc osTimerCreate(fn, argv: pointer): pointer {.cdecl.} =
  discard fn; discard argv; c_calloc(1, 4)
proc osTimerDelete(timer: pointer; tick: uint32): cint {.cdecl.} =
  discard tick; c_free(timer); 0
proc osTimerStart(timer: pointer; tSec, tNsec: clong): cint {.cdecl.} =
  discard timer; discard tSec; discard tNsec; 0
