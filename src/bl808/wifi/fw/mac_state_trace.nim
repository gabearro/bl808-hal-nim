const MacStateTraceEntries = 8

# Use the WiFi module's BSS rather than the cached control/stack bank.
var macStateTraceCount {.exportc: "nimfw_dbg_mac_state_count".}: uint32
var macStateTraceLog {.exportc: "nimfw_dbg_mac_state_log".}:
  array[MacStateTraceEntries, array[2, uint32]]

proc regWrite(address: uint; value: uint32) {.inline.} =
  ## Observe firmware requests after the runtime helper definitions only.
  if address != MACHW_STATE_CNTRL_REG:
    mmio.regWrite(address, value)
    return
  let saved = irqSave()
  let count = macStateTraceCount
  let slot = (count mod MacStateTraceEntries.uint32).int
  let timestamp = macTimeNow()
  mmio.regWrite(address, value)
  volatileStore(addr macStateTraceLog[slot][0], timestamp)
  volatileStore(addr macStateTraceLog[slot][1], value)
  volatileStore(addr macStateTraceCount, count + 1)
  irqRestore(saved)
