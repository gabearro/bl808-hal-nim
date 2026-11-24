## Link-only check for the read-only XIP metadata verifier on each ISA/ABI.
import cps/wasm/jit/xip_slot

var slot: array[XipSlotHeaderBytes + 8, byte]
var identity: XipSlotIdentity

proc xipSlotTargetCheck*(): int32 {.exportc.} =
  let info = probeXipSlot(slot, identity)
  info.status.ord.int32
