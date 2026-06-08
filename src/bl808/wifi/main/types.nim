type
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  BlModParams {.importc: "struct bl_mod_params", header: "bl_mod_params.h".} = object
  Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
  MacAddr {.importc: "struct mac_addr", header: "lmac_msg.h".} = object
  MacSsid {.importc: "struct mac_ssid", header: "lmac_msg.h".} = object
  KeTxFc {.importc: "struct ke_tx_fc", header: "lmac_msg.h".} = object
  Cfg80211ConnectParams {.importc: "struct cfg80211_connect_params",
                          header: "cfg80211.h".} = object
  MmAddIfCfm {.importc: "struct mm_add_if_cfm", header: "lmac_msg.h".} = object
  MmVersionCfm {.importc: "struct mm_version_cfm", header: "lmac_msg.h".} = object
  MmMonitorCfm {.importc: "struct mm_monitor_cfm", header: "lmac_msg.h".} = object
  MmMonitorChannelCfm {.importc: "struct mm_monitor_channel_cfm",
                        header: "lmac_msg.h".} = object
  MmBeaconCfm {.importc: "struct mm_set_beacon_int_cfm",
                header: "lmac_msg.h".} = object
  SmConnectCfm {.importc: "struct sm_connect_cfm", header: "lmac_msg.h".} = object
  SmAbortCfm {.importc: "struct sm_connect_abort_cfm", header: "lmac_msg.h".} = object
  ApmStartCfm {.importc: "struct apm_start_cfm", header: "lmac_msg.h".} = object
  ApmStaDelCfm {.importc: "struct apm_sta_del_cfm", header: "lmac_msg.h".} = object
  ScanuPara {.importc: "struct bl_send_scanu_para", header: "bl_msg_tx.h".} = object
