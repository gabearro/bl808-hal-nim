proc bl_send_scanu_req*(blHw: ptr BlHw; scanuPara: ptr ScanuPara): cint
    {.exportc, cdecl.} =
  let scanStartRequest = blMsgZalloc(SCANU_START_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuStartReq)
  if scanStartRequest == nil: return -Enomem
  let scanParams = cast[pointer](scanuPara)
  storeU8(scanStartRequest, ScanuVifIdxOff, 0)
  let fixedChannelCount = loadU16(scanParams, ScanParaChannelNumOff)
  let scanChannelCount = if fixedChannelCount == 0'u16: channelNumDefault.uint8 else: fixedChannelCount.uint8
  storeU8(scanStartRequest, ScanuChanCntOff, scanChannelCount)
  storeU8(scanStartRequest, ScanuSsidCntOff, 1)
  var scanChannelFlags = 0'u8
  let ssid = loadPtr(scanParams, ScanParaSsidOff)
  if ssid != nil and loadU8(ssid, MacSsidLengthOff) != 0'u8:
    let ssidLength = loadU8(ssid, MacSsidLengthOff)
    storeU8(scanStartRequest, ScanuSsidOff + MacSsidLengthOff, ssidLength)
    copyMem(ptrAt(scanStartRequest, ScanuSsidOff + MacSsidArrayOff), ptrAt(ssid, MacSsidArrayOff), ssidLength.uint)
  else:
    storeU8(scanStartRequest, ScanuSsidOff + MacSsidLengthOff, 0)
    if loadU8(scanParams, ScanParaModeOff) == SCAN_PASSIVE:
      scanChannelFlags = scanChannelFlags or SCAN_PASSIVE_BIT
  let bssid = loadPtr(scanParams, ScanParaBssidOff)
  if bssid != nil:
    copyMem(ptrAt(scanStartRequest, ScanuBssidOff), bssid, 6)
  let mac = loadPtr(scanParams, ScanParaMacOff)
  if mac != nil:
    copyMem(ptrAt(scanStartRequest, ScanuMacOff), mac, 6)
  storeU8(scanStartRequest, ScanuNoCckOff, 1)
  storeU16(scanStartRequest, ScanuAddIeLenOff, 0)
  storePtr(scanStartRequest, ScanuAddIesOff, nil)
  let channels = loadPtr(scanParams, ScanParaChannelsOff)
  for scanChannelSlot in 0 ..< scanChannelCount.int:
    let channelIndex =
      if fixedChannelCount == 0'u16:
        scanChannelSlot
      elif channels != nil:
        cast[ptr UncheckedArray[uint16]](channels)[scanChannelSlot].int - 1
      else:
        scanChannelSlot
    fillScanChan(
      scanStartRequest, ScanuChanOff + scanChannelSlot.uint * ScanChanSize, channelIndex, scanChannelFlags, 0)
  storeU32(scanStartRequest, ScanuDurationOff, loadU32(scanParams, ScanParaDurationOff))
  blSendMsg(blHw, scanStartRequest, 0, 0, nil)
