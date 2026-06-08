proc bl_send_scanu_req*(blHw: ptr BlHw; scanuPara: ptr ScanuPara): cint
    {.exportc, cdecl.} =
  let req = blMsgZalloc(SCANU_START_REQ, TASK_SCANU, DRV_TASK_ID, SizeScanuStartReq)
  if req == nil: return -Enomem
  let sp = cast[pointer](scanuPara)
  storeU8(req, ScanuVifIdxOff, 0)
  let fixedCount = loadU16(sp, ScanParaChannelNumOff)
  let chanCnt = if fixedCount == 0'u16: channelNumDefault.uint8 else: fixedCount.uint8
  storeU8(req, ScanuChanCntOff, chanCnt)
  storeU8(req, ScanuSsidCntOff, 1)
  var chanFlags = 0'u8
  let ssid = loadPtr(sp, ScanParaSsidOff)
  if ssid != nil and loadU8(ssid, MacSsidLengthOff) != 0'u8:
    let ssidLen = loadU8(ssid, MacSsidLengthOff)
    storeU8(req, ScanuSsidOff + MacSsidLengthOff, ssidLen)
    copyMem(ptrAt(req, ScanuSsidOff + MacSsidArrayOff), ptrAt(ssid, MacSsidArrayOff), ssidLen.uint)
  else:
    storeU8(req, ScanuSsidOff + MacSsidLengthOff, 0)
    if loadU8(sp, ScanParaModeOff) == SCAN_PASSIVE:
      chanFlags = chanFlags or SCAN_PASSIVE_BIT
  let bssid = loadPtr(sp, ScanParaBssidOff)
  if bssid != nil:
    copyMem(ptrAt(req, ScanuBssidOff), bssid, 6)
  let mac = loadPtr(sp, ScanParaMacOff)
  if mac != nil:
    copyMem(ptrAt(req, ScanuMacOff), mac, 6)
  storeU8(req, ScanuNoCckOff, 1)
  storeU16(req, ScanuAddIeLenOff, 0)
  storePtr(req, ScanuAddIesOff, nil)
  let channels = loadPtr(sp, ScanParaChannelsOff)
  for i in 0 ..< chanCnt.int:
    let index =
      if fixedCount == 0'u16:
        i
      elif channels != nil:
        cast[ptr UncheckedArray[uint16]](channels)[i].int - 1
      else:
        i
    fillScanChan(req, ScanuChanOff + i.uint * ScanChanSize, index, chanFlags, 0)
  storeU32(req, ScanuDurationOff, loadU32(sp, ScanParaDurationOff))
  blSendMsg(blHw, req, 0, 0, nil)
