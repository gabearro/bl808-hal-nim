proc bl808_wifi_copy_completed_tx_policy*(wrapper, statusAddress: pointer;
    words: ptr array[8, uint32]; power: ptr array[4, uint32];
    airTag: ptr uint32 = nil): bool {.exportc, cdecl.} =
  let desc = addr ipcHostTxWrapperAt(wrapper).txDesc
  if cast[pointer](desc.cfmDst) != statusAddress or
      desc.hwDesc != cast[pointer](addr desc.aggDescPtr):
    return false
  let thd = hostTxHwDescAt(desc.hwDesc)
  let link = hostTxInlineBufferedLink(desc)
  let rate = hostTxRateTemplate(link)
  if thd.magic != 0xCAFEBABE'u32 or
      cast[pointer](hostTxHeadThd(thd)) != cast[pointer](addr desc.aggDescStorage[0]) or
      thd.chainedThd != cast[pointer](rate) or rate.magic != 0xBADCAB1E'u32:
    return false
  words[] = [rate.rateWord, rate.retryRateControl0, rate.retryRateControl1,
             rate.retryRateControl2, rate.policyWord, thd.retryLimitControl,
             thd.ackPolicyControl, thd.confirmStatus]
  if power != nil:
    power[] = [cast[uint32](rate.txPower), rate.retryTxPowerControl0,
               rate.retryTxPowerControl1, rate.retryTxPowerControl2]
  if airTag != nil:
    airTag[] = 0
    # Read the completed inline MAC header, not TXU's initial sequence field.
    let frame = cast[ptr UncheckedArray[uint8]](addr link.macHeader[0])
    let start = link.headerThd.payloadStart
    let last = link.headerThd.payloadEnd
    let raw = thd.confirmStatus
    if statusAddress != nil and (raw and 0xC000_0000'u32) == 0x8000_0000'u32 and
        (raw or 1'u32) == cast[ptr uint32](statusAddress)[] and
        thd.status == pointerAddrU32(addr link.headerThd) and
        link.headerLen >= 26 and link.headerThd.magic == 0xCAFEFADE'u32 and
        start == pointerAddrU32(frame) and last >= start and last - start >= 25:
      let fc = frame[0].uint32 or (frame[1].uint32 shl 8)
      let seqCtrl = frame[22].uint32 or (frame[23].uint32 shl 8)
      let qos = frame[24]
      if (fc and 0x87ff) == 0x0188 and (seqCtrl and 15) == 0 and (qos and 0x8f) < 8:
        airTag[] = 0x8000_0000'u32 or ((qos.uint32 and 7) shl 16) or seqCtrl
  true
