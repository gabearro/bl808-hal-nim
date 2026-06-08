proc bl_send_me_config_req*(blHw: ptr BlHw): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(ME_CONFIG_REQ, TASK_ME, DRV_TASK_ID, SizeMeConfigReq)
  if req == nil: return -Enomem
  let hw = cast[pointer](blHw)
  let htCap = ptrAt(hw, BlHwHtCapOff)
  let modp = loadPtr(hw, BlHwModParamsOff)
  let htSupp =
    when defined(bl808WifiForceLegacyRates):
      0'u8
    else:
      1'u8
  bl_os_printf("[ME] HT supp %d, VHT supp %d\r\n", htSupp.cint, 0)
  storeU8(req, MeConfigHtSuppOff, htSupp)
  storeU8(req, MeConfigVhtSuppOff, 0)
  storeU16(req, MeConfigHtCapOff + MacHtCapInfoOff, loadU16(htCap, HtCapCapOff))
  storeU8(req, MeConfigHtCapOff + MacHtAmpduOff, 3)
  copyMem(ptrAt(req, MeConfigHtCapOff + MacHtMcsRateOff), ptrAt(htCap, HtCapMcsOff), 16)
  storeU16(req, MeConfigHtCapOff + MacHtExtCapOff, 0)
  storeU32(req, MeConfigHtCapOff + MacHtBeamformOff, 0)
  storeU8(req, MeConfigHtCapOff + MacHtAselOff, 0)
  if modp != nil:
    storeU8(req, MeConfigPsOnOff, loadU8(modp, BlModParamsPsOnOff))
    storeU16(req, MeConfigTxLftOff, loadI32(modp, BlModParamsTxLftOff).uint16)
  blSendMsg(blHw, req, 1, ME_CONFIG_CFM, nil)

proc bl_send_me_rate_config_req*(blHw: ptr BlHw; staIdx: uint8;
                                 fixedRateCfg: uint16): cint {.exportc, cdecl.} =
  let req = blMsgZalloc(ME_RC_SET_RATE_REQ, TASK_ME, DRV_TASK_ID, SizeMeRcSetRateReq)
  if req == nil: return -Enomem
  storeU8(req, MeRcStaIdxOff, staIdx)
  storeU16(req, MeRcFixedRateOff, fixedRateCfg)
  storeU16(req, MeRcPowerTableReqOff, 1)
  blSendMsg(blHw, req, 0, 0, nil)
