proc txCntrlPurgeCheck(sta: pointer; onlyCheck: uint8) =
  let staO = staView(sta)
  if not listEmpty(cast[pointer](addr staO.pendingList)) or not listEmpty(cast[pointer](addr staO.waitingList)):
    if onlyCheck != 0:
      bl_os_printf("[TX] Have remaining packets when checking!\n\r")
    else:
      bl_os_enter_critical()
      txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staO.staIdx)
      bl_irq_handler()
      bl_os_exit_critical()
