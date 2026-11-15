proc tcpip_stack_input*(swdesc: pointer; status: uint32; hwhdr: pointer;
                        msduOffset: uint32; pkt: pointer;
                        extraStatus: uint32): cint {.exportc, cdecl.} =
  inc nimFwDbgTcpipInputCalls
  if (status and RxStatusForward) == 0'u32 or hwhdr == nil:
    inc nimFwDbgTcpipInputNoForward
    return -1
  var lease: firmware.RxHostLease
  let flags = block:
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if (saved and 8) != 0: enableInterrupts()
    if not firmware.captureRxHostLease(swdesc, lease):
      return -1
    loadU32(hwhdr, RxFlagsOff)
  if (flags and RxFlagIs80211Mpdu) != 0'u32:
    return inputMonitorFrame(hwhdr, pkt, msduOffset, addr lease)
  when defined(bl808WifiRxPbufInput):
    var delivery: RxNetifDelivery
    let inputPbuf = block:
      let saved = csrReadMstatus()
      disableInterrupts()
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      defer:
        {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
        if (saved and 8) != 0: enableInterrupts()
      if not firmware.rxHostLeaseCurrent(lease):
        return -1
      let staIdx = (flags shr RxFlagStaIdxShift) and RxFlagStaIdxMask
      let vif = rxVif(cast[pointer](addr wifi_hw), staIdx)
      if vif == nil:
        inc nimFwDbgTcpipInputNoVif
        return -1
      let netif = cast[ptr Netif](loadPtr(vif, BlVifDevOff))
      if netif == nil or netif.input == nil:
        inc nimFwDbgTcpipInputNoNetif
        return -1
      delivery = RxNetifDelivery(lease: lease, station: staIdx,
        vif: vif, netif: netif, input: netif.input)
      nimFwDbgTcpipInputFrameLast0 = msduOffset or (msduOffset shl 16)
      let packet = allocFramePbuf(msduOffset, pkt)
      if packet == nil:
        noteTcpipNoPbuf(1'u32, status, flags, msduOffset, false, pkt)
        return -1
      packet
    if (extraStatus and BlRxStatusAmsdu) != 0'u32:
      return inputAmsdu(inputPbuf, delivery)

    discard noteEthernetInput(inputPbuf)
    return if deliverRxPacket(inputPbuf, delivery) == rxDelivered: 0 else: -1
  else:
    discard status
    discard hwhdr
    discard msduOffset
    discard pkt
    discard extraStatus
  -1
