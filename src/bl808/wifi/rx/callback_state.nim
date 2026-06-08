var wifi_hw {.importc, header: "bl_defs.h".}: BlHw

var cbSmConnect: ConnectCb
var cbSmConnectEnv: pointer
var cbSmDisconnect: DisconnectCb
var cbSmDisconnectEnv: pointer
var cbBeacon: BeaconCb
var cbBeaconEnv: pointer
var cbProbeResp: ProbeRespCb
var cbProbeRespEnv: pointer
var cbPkt: PktCb
var cbPktAdv: PktAdvCb
var cbPktEnv: pointer
var cbRssi: RssiCb
var cbRssiEnv: pointer
var cbEvent: EventCb
var cbEventEnv: pointer
var nimFwDbgRxSmStaAdd* {.exportc: "nimfw_dbg_rx_sm_sta_add".}: uint32
var nimFwDbgRxSmStaAddMeta* {.exportc: "nimfw_dbg_rx_sm_sta_add_meta".}: uint32
var nimFwDbgRxSmStaAddVif* {.exportc: "nimfw_dbg_rx_sm_sta_add_vif".}: uint32
var nimFwDbgRxSmStaAddSta* {.exportc: "nimfw_dbg_rx_sm_sta_add_sta".}: uint32
var nimFwDbgRxSmStaAddError* {.exportc: "nimfw_dbg_rx_sm_sta_add_error".}: uint32
var nimFwDbgRxSmDisc* {.exportc: "nimfw_dbg_rx_sm_disc".}: uint32
var nimFwDbgRxSmSeq* {.exportc: "nimfw_dbg_rx_sm_seq".}: uint32
var nimFwDbgRxSmStaAddSeq* {.exportc: "nimfw_dbg_rx_sm_sta_add_seq".}: uint32
var nimFwDbgRxSmDiscSeq* {.exportc: "nimfw_dbg_rx_sm_disc_seq".}: uint32
var nimFwDbgRxSmDiscMeta* {.exportc: "nimfw_dbg_rx_sm_disc_meta".}: uint32
var nimFwDbgRxSmDiscVif* {.exportc: "nimfw_dbg_rx_sm_disc_vif".}: uint32
var nimFwDbgRxSmDiscSta* {.exportc: "nimfw_dbg_rx_sm_disc_sta".}: uint32
