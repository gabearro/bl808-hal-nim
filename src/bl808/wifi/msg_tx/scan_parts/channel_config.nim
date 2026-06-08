proc bl_send_me_chan_config_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(ME_CHAN_CONFIG_REQ, TASK_ME, DRV_TASK_ID, SizeMeChanConfigReq)
  if req == nil: return -Enomem
  var count = channelNumDefault
  if count > SCAN_CHANNEL_2G4: count = SCAN_CHANNEL_2G4
  for i in 0 ..< count:
    fillScanChan(req, MeChanChan2G4Off + i.uint * ScanChanSize, i, 0, 20)
    storeU8(req, MeChanCountOff, (i + 1).uint8)
  blSendMsg(blHw, req, 1, ME_CHAN_CONFIG_CFM, nil)
