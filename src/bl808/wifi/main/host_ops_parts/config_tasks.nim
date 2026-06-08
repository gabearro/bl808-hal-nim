proc bl_main_rate_config*(staIdx: uint8; fixedRateCfg: uint16): cint {.exportc, cdecl.} =
  bl_send_me_rate_config_req(hwPtr(), staIdx, fixedRateCfg)

proc bl_main_set_country_code*(countryCode: cstring): cint {.exportc, cdecl.} =
  bl_msg_update_channel_cfg(countryCode)
  discard bl_send_me_chan_config_req(hwPtr())
  0

proc bl_main_get_channel_nums*(): cint {.exportc, cdecl.} =
  bl_msg_get_channel_nums()

proc bl_main_cfg_task_req*(ops, task, element, typ: uint32; arg1, arg2: pointer): cint
    {.exportc, cdecl.} =
  bl_send_cfg_task_req(hwPtr(), ops, task, element, typ, arg1, arg2)
