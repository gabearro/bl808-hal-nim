proc c_memset(s: pointer; c: cint; n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}

proc bl_send_reset(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_version_req(blHw: ptr BlHw; cfm: ptr MmVersionCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_me_config_req(blHw: ptr BlHw): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_me_chan_config_req(blHw: ptr BlHw): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_me_rate_config_req(blHw: ptr BlHw; staIdx: uint8; fixedRateCfg: uint16): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_start(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_add_if(blHw: ptr BlHw; mac: ptr uint8; iftype: cint; p2p: bool;
                    cfm: ptr MmAddIfCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_remove_if(blHw: ptr BlHw; instNbr: uint8): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_scanu_req(blHw: ptr BlHw; scanuPara: ptr ScanuPara): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_scanu_raw_send(blHw: ptr BlHw; pkt: ptr uint8; len: cint): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_sm_connect_req(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams;
                            cfm: ptr SmConnectCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_sm_connect_abort_req(blHw: ptr BlHw; cfm: ptr SmAbortCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_sm_disconnect_req(blHw: ptr BlHw): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_mm_powersaving_req(blHw: ptr BlHw; mode: cint): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_mm_denoise_req(blHw: ptr BlHw; mode: cint): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_channel_set_req(blHw: ptr BlHw; channel: cint): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_monitor_enable(blHw: ptr BlHw; cfm: ptr MmMonitorCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_monitor_disable(blHw: ptr BlHw; cfm: ptr MmMonitorCfm): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_monitor_channel_set(blHw: ptr BlHw; cfm: ptr MmMonitorChannelCfm;
                                 channel, use40Mhz: cint): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_beacon_interval_set(blHw: ptr BlHw; cfm: ptr MmBeaconCfm;
                                 beaconInt: uint16): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_apm_start_req(blHw: ptr BlHw; cfm: ptr ApmStartCfm; ssid, password: cstring;
                           channel: cint; vifIndex, hiddenSsid: uint8;
                           bcnInt: uint16): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_apm_stop_req(blHw: ptr BlHw; vifIdx: uint8): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_apm_sta_del_req(blHw: ptr BlHw; cfm: ptr ApmStaDelCfm;
                             staIdx, vifIdx: uint8): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_apm_conf_max_sta_req(blHw: ptr BlHw; maxStaSupported: uint8): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_send_cfg_task_req(blHw: ptr BlHw; ops, task, element, typ: uint32;
                          arg1, arg2: pointer): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_msg_update_channel_cfg(code: cstring) {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_msg_get_channel_nums(): cint {.importc, cdecl, header: "bl_msg_tx.h".}
proc bl_get_fixed_channels_is_valid(channels: ptr uint16; channelNum: uint16): cint
  {.importc, cdecl, header: "bl_msg_tx.h".}

proc bl_platform_on(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_platform.h".}
proc bl_handle_dynparams(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_mod_params.h".}
proc bl_irqs_init(blHw: ptr BlHw): cint {.importc, cdecl, header: "bl_irqs.h".}
proc bl_irq_bottomhalf(blHw: ptr BlHw) {.importc, cdecl, header: "bl_irqs.h".}
proc bl_tx_try_flush(param: cint; txFcField: ptr KeTxFc) {.importc, cdecl, header: "bl_tx.h".}
proc ipc_host_enable_irq(env: pointer; value: uint32)
  {.importc, cdecl, header: "ipc_host.h".}
proc ipc_host_txdesc_left(env: pointer; queueIdx, userPos: cint): cint
  {.importc, cdecl, header: "ipc_host.h".}
proc bl_wifi_enable_irq(): cint {.importc, cdecl.}
proc bl_os_msleep(ms: uint32) {.importc, cdecl, header: "bl_os_private.h".}
