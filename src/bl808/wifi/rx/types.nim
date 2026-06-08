type
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  BlSta {.importc: "struct bl_sta", header: "bl_defs.h".} = object
  Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
  BlRxInfo {.importc: "bl_rx_info_t", header: "bl_main.h".} = object
  WifiEventSmConnect {.importc: "struct wifi_event_sm_connect_ind", header: "bl_main.h".} = object
  WifiEventSmDisconnect {.importc: "struct wifi_event_sm_disconnect_ind", header: "bl_main.h".} = object
  WifiEventBeacon {.importc: "struct wifi_event_beacon_ind", header: "bl_main.h".} = object
  WifiEvent {.importc: "struct wifi_event", header: "bl_main.h".} = object
  MsgCbProc = proc(blHw, cmd, msg: pointer): cint {.cdecl.}
  CmdMsgindProc = proc(cmdMgr, msg: pointer; cb: MsgCbProc): cint {.cdecl.}
  ConnectCb = proc(env: pointer; ind: ptr WifiEventSmConnect) {.cdecl.}
  DisconnectCb = proc(env: pointer; ind: ptr WifiEventSmDisconnect) {.cdecl.}
  BeaconCb = proc(env: pointer; ind: ptr WifiEventBeacon) {.cdecl.}
  ProbeRespCb = proc(env: pointer; timestamp: int64) {.cdecl.}
  PktCb = proc(env: pointer; pkt: ptr uint8; len: cint; info: ptr BlRxInfo) {.cdecl.}
  PktAdvCb = proc(env, pktWrap: pointer; info: ptr BlRxInfo) {.cdecl.}
  RssiCb = proc(env: pointer; rssi: int8) {.cdecl.}
  EventCb = proc(env: pointer; event: ptr WifiEvent) {.cdecl.}
  WifiWpaIe {.bycopy.} = object
    proto: cint
    pairwiseCipher: cint
    groupCipher: cint
    keyMgmt: cint
    capabilities: cint
    numPmkid: csize_t
    pmkid: pointer
    mgmtGroupCipher: cint
