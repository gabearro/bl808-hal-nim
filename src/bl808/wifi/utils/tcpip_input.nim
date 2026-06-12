proc tcpip_stack_input*(swdesc: pointer; status: uint32; hwhdr: pointer;
                        msduOffset: uint32; pkt: pointer;
                        extraStatus: uint32): cint {.exportc, cdecl.} =
  discard swdesc
  inc nimFwDbgTcpipInputCalls
  when defined(bl808WifiRxPbufInput):
    if (status and RxStatusForward) == 0'u32 or hwhdr == nil:
      inc nimFwDbgTcpipInputNoForward
      return -1

    let flags = loadU32(hwhdr, RxFlagsOff)
    noteUploadScan(pkt, msduOffset, flags)
    let staIdx = (flags shr RxFlagStaIdxShift) and RxFlagStaIdxMask
    let vif = rxVif(cast[pointer](addr wifi_hw), staIdx)
    if vif == nil:
      inc nimFwDbgTcpipInputNoVif
      return -1

    let netif = cast[ptr Netif](loadPtr(vif, BlVifDevOff))
    if netif == nil:
      inc nimFwDbgTcpipInputNoNetif
      return -1

    let usedMpduInput = (flags and RxFlagIs80211Mpdu) != 0'u32 and msduOffset == 0'u32
    var inputPbuf =
      if usedMpduInput:
        allocMpduEthernetPbuf(msduOffset, pkt)
      else:
        let ethOffset =
          if msduOffset >= 14'u32: msduOffset - 14'u32
          else: msduOffset
        let resolvedOffset = ethernetOffsetForUpload(pkt, ethOffset)
        nimFwDbgTcpipInputFrameLast0 = resolvedOffset or (msduOffset shl 16)
        allocFramePbuf(resolvedOffset, pkt)
    if inputPbuf == nil:
      noteTcpipNoPbuf(1'u32, status, flags, msduOffset, usedMpduInput, pkt)
      return -1
    if (extraStatus and BlRxStatusAmsdu) != 0'u32:
      inputPbuf.flags = inputPbuf.flags or PbufFlagAmsdu

    if not noteEthernetInput(inputPbuf) and
        not usedMpduInput and pkt != nil:
      discard pbuf_free(inputPbuf)
      let mpduOffset =
        if msduOffset >= 4'u32: msduOffset - 4'u32
        else: 0'u32
      inputPbuf = allocMpduEthernetPbuf(mpduOffset, pkt)
      if inputPbuf == nil and mpduOffset != 0'u32:
        inputPbuf = allocMpduEthernetPbuf(0'u32, pkt)
      if inputPbuf == nil:
        noteTcpipNoPbuf(2'u32, status, flags, mpduOffset, true, pkt)
        return -1
      discard noteEthernetInput(inputPbuf)
    if bl808_nim_netif_input_call(inputPbuf, netif) != 0'i8:
      inc nimFwDbgTcpipInputFail
      discard pbuf_free(inputPbuf)
      return -1
    else:
      inc nimFwDbgTcpipInputOk
      return 0
  else:
    discard status
    discard hwhdr
    discard msduOffset
    discard pkt
    discard extraStatus
  -1
