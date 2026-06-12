proc bl_send_me_chan_config_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  let channelConfigRequest = blMsgZalloc(ME_CHAN_CONFIG_REQ, TASK_ME, DRV_TASK_ID, SizeMeChanConfigReq)
  if channelConfigRequest == nil: return -Enomem
  var configuredChannelCount = channelNumDefault
  if configuredChannelCount > SCAN_CHANNEL_2G4:
    configuredChannelCount = SCAN_CHANNEL_2G4
  for scanChannelSlot in 0 ..< configuredChannelCount:
    fillScanChan(channelConfigRequest, MeChanChan2G4Off + scanChannelSlot.uint * ScanChanSize,
                 scanChannelSlot, 0, 20)
    storeU8(channelConfigRequest, MeChanCountOff, (scanChannelSlot + 1).uint8)
  blSendMsg(blHw, channelConfigRequest, 1, ME_CHAN_CONFIG_CFM, nil)
