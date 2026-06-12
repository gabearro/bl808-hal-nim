proc cfg80211_init(blHw: ptr BlHw): cint =
  if blHw == nil:
    return -1
  let blHwStorage = cast[pointer](blHw)
  initListHead(blHwStorage, BlHwVifsOff)
  storePtr(blHwStorage, BlHwModParamsOff, cast[pointer](addr bl_mod_params))

  result = bl_platform_on(blHw)
  if result != 0:
    return result
  ipc_host_enable_irq(loadPtr(blHwStorage, BlHwIpcEnvOff), IpcIrqE2aAll)
  discard bl_wifi_enable_irq()

  result = bl_send_reset(blHw)
  if result != 0:
    return result
  bl_os_msleep(5'u32)

  var versionCfm: array[SizeMmVersionCfm, uint8]
  zero(addr versionCfm[0], versionCfm.len)
  result = bl_send_version_req(blHw, cast[ptr MmVersionCfm](addr versionCfm[0]))
  if result != 0:
    return result
  result = bl_handle_dynparams(blHw)
  if result != 0:
    return result
  discard bl_send_me_config_req(blHw)
  discard bl_send_me_chan_config_req(blHw)
