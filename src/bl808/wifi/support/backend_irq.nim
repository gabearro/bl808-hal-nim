proc bl808WifiBackendPollEmbEvents() =
  if (regRead32(IpcEmb2AppStatus) and IpcA2eMsgBit) != 0:
    ke_evt_set(KeEvtIpcEmbMsg)

proc bl808WifiBackendClearEmbIpc() =
  regWrite32(IpcApp2EmbAck, 0xffff_ffff'u32)

proc bl808WifiBackendClearHostIpc() =
  regWrite32(IpcEmb2AppAck, 0xffff_ffff'u32)

proc bl808WifiBackendHostIpcStatus(): uint32 =
  regRead32(IpcEmb2AppRawStatus)

proc bl808WifiBackendDriveRfStatus() =
  var rfCtrl = regRead32(RfStatusCtrl)
  if (regRead32(MacRfStatus) and MacRfActiveBit) != 0:
    rfCtrl = rfCtrl or 0x01'u32
  else:
    rfCtrl = rfCtrl and not 0x01'u32
  regWrite32(RfStatusCtrl, rfCtrl)

template macServiceIrqSave(): uint32 =
  block:
    var prev {.gensym.}: uint32
    # Keep shared-memory accesses inside the interrupt-protected region.
    {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", prev, ") :: \"memory\");"].}
    prev

template macServiceIrqRestore(prev: uint32) =
  if (prev and 8) != 0:
    {.emit: ["asm volatile(\"csrsi mstatus, 8\" ::: \"memory\");"].}

proc bl808WifiBackendPollMacIrq() =
  ## Thread-context MAC servicing. mac_irq()/hal_machw_gen_handler() mutate
  ## MAC descriptor lists with plain multi-word stores, and the SAME handlers
  ## also run from the real CLIC trap (bl808WifiBackendMacIrqTrampoline).
  ## Mask interrupts around the thread-side servicing so trap-context and
  ## thread-context invocations can never interleave inside the handlers
  ## (unsynchronized overlap tears co_list/descriptor state).
  var guard = 32
  while guard > 0:
    dec guard
    let saved = macServiceIrqSave()
    let platformPending = regRead32(MacIrqStatus0) or regRead32(MacIrqStatus1)
    let machwPending = regRead32(MachwIrqRaw) and regRead32(MachwIrqUnmask)
    if platformPending == 0 and machwPending == 0:
      macServiceIrqRestore(saved)
      break
    inc macIrqCount
    inc macPollIrqCount
    if platformPending != 0:
      mac_irq()
    else:
      hal_machw_gen_handler()
    macServiceIrqRestore(saved)

proc bl808WifiBackendMacIrqTrampoline() {.cdecl.} =
  inc macIrqCount
  inc macTrapIrqCount
  mac_irq()

proc bl808WifiBackendIpcIrqTrampoline() {.cdecl.} =
  inc ipcTrapIrqCount
  bl_irq_handler()
