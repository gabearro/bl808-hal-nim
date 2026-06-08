var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
var internel_cal_size_tx_hdr* {.exportc.}: cint = TxHdrSize.cint
var txCntrlStaTrigger: uint32
var txCntrlStaTriggerPending: uint32
var nimFwDbgDhcpTx* {.exportc: "nimfw_dbg_dhcp_tx".}: uint32
var nimFwDbgDhcpTxEth* {.exportc: "nimfw_dbg_dhcp_tx_eth".}: uint32
var nimFwDbgDhcpTxPorts* {.exportc: "nimfw_dbg_dhcp_tx_ports".}: uint32
var nimFwDbgDhcpTxLen* {.exportc: "nimfw_dbg_dhcp_tx_len".}: uint32
var nimFwDbgDhcpTxSrcLo* {.exportc: "nimfw_dbg_dhcp_tx_src_lo".}: uint32
var nimFwDbgDhcpTxSrcHi* {.exportc: "nimfw_dbg_dhcp_tx_src_hi".}: uint32
var nimFwDbgDhcpTxMsg* {.exportc: "nimfw_dbg_dhcp_tx_msg".}: uint32
var nimFwDbgDhcpTxRawLen* {.exportc: "nimfw_dbg_dhcp_tx_raw_len".}: uint32
var nimFwDbgDhcpTxRaw* {.exportc: "nimfw_dbg_dhcp_tx_raw".}: array[384, uint8]
var nimFwDbgDhcpTxBreakHits* {.exportc: "nimfw_dbg_dhcp_tx_break_hits".}: uint32
var nimFwDbgDhcpRequestTxBreakHits* {.exportc: "nimfw_dbg_dhcp_request_tx_break_hits".}: uint32
var nimFwDbgDhcpTxMsgHist* {.exportc: "nimfw_dbg_dhcp_tx_msg_hist".}: array[8, uint32]
var nimFwDbgDhcpUdpChecksumRepair* {.exportc: "nimfw_dbg_dhcp_udp_csum_repair".}: uint32
var nimFwDbgDhcpUdpChecksumBefore* {.exportc: "nimfw_dbg_dhcp_udp_csum_before".}: uint32
var nimFwDbgDhcpUdpChecksumCalc* {.exportc: "nimfw_dbg_dhcp_udp_csum_calc".}: uint32
var nimFwDbgDhcpUdpChecksumAfter* {.exportc: "nimfw_dbg_dhcp_udp_csum_after".}: uint32
var nimFwDbgDhcpUdpChecksumVerifyBefore* {.exportc: "nimfw_dbg_dhcp_udp_csum_vbefore".}: uint32
var nimFwDbgDhcpUdpChecksumVerifyAfter* {.exportc: "nimfw_dbg_dhcp_udp_csum_vafter".}: uint32
var nimFwDbgDhcpReqUdpChecksumBefore* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_before".}: uint32
var nimFwDbgDhcpReqUdpChecksumCalc* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_calc".}: uint32
var nimFwDbgDhcpReqUdpChecksumAfter* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_after".}: uint32
var nimFwDbgDhcpReqUdpChecksumVerifyBefore* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_vbefore".}: uint32
var nimFwDbgDhcpReqUdpChecksumVerifyAfter* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_vafter".}: uint32
var nimFwDbgDhcpReqUdpChecksumAtCopy* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_at_copy".}: uint32
var nimFwDbgDhcpCfm* {.exportc: "nimfw_dbg_dhcp_cfm".}: uint32
var nimFwDbgDhcpCfmOk* {.exportc: "nimfw_dbg_dhcp_cfm_ok".}: uint32
var nimFwDbgDhcpCfmFail* {.exportc: "nimfw_dbg_dhcp_cfm_fail".}: uint32
var nimFwDbgDhcpCfmAckOk* {.exportc: "nimfw_dbg_dhcp_cfm_ack_ok".}: uint32
var nimFwDbgDhcpCfmAckFail* {.exportc: "nimfw_dbg_dhcp_cfm_ack_fail".}: uint32
var nimFwDbgDhcpCfmStatus* {.exportc: "nimfw_dbg_dhcp_cfm_status".}: uint32
var nimFwDbgDhcpCfmRingIdx* {.exportc: "nimfw_dbg_dhcp_cfm_ring_idx".}: uint32
var nimFwDbgDhcpCfmStatusLog* {.exportc: "nimfw_dbg_dhcp_cfm_status_log".}: array[8, uint32]
var nimFwDbgDhcpCfmMetaLog* {.exportc: "nimfw_dbg_dhcp_cfm_meta_log".}: array[8, uint32]
var nimFwDbgEapolCfmRingIdx {.importc: "nimfw_dbg_eapol_cfm_ring_idx".}: uint32
var nimFwDbgEapolCfmStatusLog {.importc: "nimfw_dbg_eapol_cfm_status_log".}: array[4, uint32]
var nimFwDbgEapolCfmMetaLog {.importc: "nimfw_dbg_eapol_cfm_meta_log".}: array[4, uint32]
var nimFwDbgEapolCfmKeyLog {.importc: "nimfw_dbg_eapol_cfm_key_log".}: array[4, uint32]
var nimFwDbgEapolCfmReplayLog {.importc: "nimfw_dbg_eapol_cfm_replay_log".}: array[4, uint32]
var nimFwDbgEapolCfmCbLog {.importc: "nimfw_dbg_eapol_cfm_cb_log".}: array[4, uint32]
var nimFwDbgTxStaLookup* {.exportc: "nimfw_dbg_tx_sta_lookup".}: uint32
var nimFwDbgTxStaLookupFail* {.exportc: "nimfw_dbg_tx_sta_lookup_fail".}: uint32
var nimFwDbgTxStaLookupMode* {.exportc: "nimfw_dbg_tx_sta_lookup_mode".}: uint32
var nimFwDbgTxStaLookupVif* {.exportc: "nimfw_dbg_tx_sta_lookup_vif".}: uint32
var nimFwDbgTxStaLookupSta* {.exportc: "nimfw_dbg_tx_sta_lookup_sta".}: uint32
var nimFwDbgTxStaLookupResult* {.exportc: "nimfw_dbg_tx_sta_lookup_result".}: uint32
var nimFwDbgTxStaLookupEth* {.exportc: "nimfw_dbg_tx_sta_lookup_eth".}: uint32
var nimFwDbgTxStaLookupDst0* {.exportc: "nimfw_dbg_tx_sta_lookup_dst0".}: uint32
var nimFwDbgTxStaLookupDst1* {.exportc: "nimfw_dbg_tx_sta_lookup_dst1".}: uint32
var nimFwDbgTxArp* {.exportc: "nimfw_dbg_tx_arp".}: uint32
var nimFwDbgTxUdp* {.exportc: "nimfw_dbg_tx_udp".}: uint32
var nimFwDbgTxUdpProbe* {.exportc: "nimfw_dbg_tx_udp_probe".}: uint32
var nimFwDbgTxUdpPorts* {.exportc: "nimfw_dbg_tx_udp_ports".}: uint32
var nimFwDbgTxUdpIp* {.exportc: "nimfw_dbg_tx_udp_ip".}: uint32
var nimFwDbgTxTcp* {.exportc: "nimfw_dbg_tx_tcp".}: uint32
var nimFwDbgTxTcp80* {.exportc: "nimfw_dbg_tx_tcp80".}: uint32
var nimFwDbgTxTcpFlags* {.exportc: "nimfw_dbg_tx_tcp_flags".}: uint32
