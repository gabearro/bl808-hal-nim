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

proc bl808WifiBackendPollMacIrq() =
  var guard = 32
  while guard > 0:
    dec guard
    let platformPending = regRead32(MacIrqStatus0) or regRead32(MacIrqStatus1)
    let machwPending = regRead32(MachwIrqRaw) and regRead32(MachwIrqUnmask)
    if platformPending == 0 and machwPending == 0:
      break
    inc macIrqCount
    inc macPollIrqCount
    if platformPending != 0:
      mac_irq()
    else:
      hal_machw_gen_handler()

proc bl808WifiBackendMacIrqTrampoline() {.cdecl.} =
  inc macIrqCount
  inc macTrapIrqCount
  mac_irq()

proc bl808WifiBackendIpcIrqTrampoline() {.cdecl.} =
  inc ipcTrapIrqCount
  bl_irq_handler()
