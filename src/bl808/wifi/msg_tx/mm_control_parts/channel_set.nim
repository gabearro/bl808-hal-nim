proc bl_send_channel_set_req*(blHw: ptr BlHw; channel: cint): cint {.exportc, cdecl.} =
  var cfm: array[1, uint8]
  let req = blMsgZalloc(MM_SET_CHANNEL_REQ, TASK_MM, DRV_TASK_ID, SizeMmSetChannelReq)
  if req == nil: return -Enomem
  let freq = phy_channel_to_freq(PHY_BAND_2G4, channel)
  storeU8(req, MmSetChannelBandOff, PHY_BAND_2G4)
  storeU8(req, MmSetChannelTypeOff, PHY_CHNL_BW_20)
  storeU16(req, MmSetChannelPrim20Off, freq)
  storeU16(req, MmSetChannelCenter1Off, freq)
  storeU16(req, MmSetChannelCenter2Off, freq)
  storeU8(req, MmSetChannelIndexOff, 0)
  storeU8(req, MmSetChannelTxPowerOff, 15)
  blSendMsg(blHw, req, 1, MM_SET_CHANNEL_CFM, addr cfm[0])
