## Exported TCP/IP RX diagnostic counters used by hardware probes.

var nimFwDbgTcpipInputMpduConv* {.exportc: "nimfw_dbg_tcpip_input_mpdu_conv".}: uint32
var nimFwDbgTcpipInputMpduFail* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail".}: uint32
var nimFwDbgTcpipInputMpduFailCounts* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_counts".}: uint32
var nimFwDbgTcpipInputMpduFailDetailLo* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_lo".}: uint32
var nimFwDbgTcpipInputMpduFailDetailHi* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_hi".}: uint32
var nimFwDbgTcpipInputMpduLast0* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last0".}: uint32
var nimFwDbgTcpipInputMpduLast1* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last1".}: uint32
var nimFwDbgTcpipInputMpduLast2* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last2".}: uint32
var nimFwDbgTcpipInputEth* {.exportc: "nimfw_dbg_tcpip_input_eth".}: uint32
var nimFwDbgTcpipInputUdp* {.exportc: "nimfw_dbg_tcpip_input_udp".}: uint32
var nimFwDbgTcpipInputDhcpRx* {.exportc: "nimfw_dbg_tcpip_input_dhcp_rx".}: uint32
var nimFwDbgTcpipInputLastPorts* {.exportc: "nimfw_dbg_tcpip_input_last_ports".}: uint32
var nimFwDbgTcpipInputLastIp* {.exportc: "nimfw_dbg_tcpip_input_last_ip".}: uint32
var nimFwDbgTcpipInputDhcpMeta* {.exportc: "nimfw_dbg_tcpip_input_dhcp_meta".}: uint32
var nimFwDbgTcpipInputDhcpXid* {.exportc: "nimfw_dbg_tcpip_input_dhcp_xid".}: uint32
var nimFwDbgTcpipInputDhcpYiaddr* {.exportc: "nimfw_dbg_tcpip_input_dhcp_yiaddr".}: uint32
var nimFwDbgTcpipInputDhcpCh0* {.exportc: "nimfw_dbg_tcpip_input_dhcp_ch0".}: uint32
var nimFwDbgTcpipInputDhcpCh1* {.exportc: "nimfw_dbg_tcpip_input_dhcp_ch1".}: uint32
var nimFwDbgTcpipInputFrameLast0* {.exportc: "nimfw_dbg_tcpip_input_frame_last0".}: uint32
var nimFwDbgTcpipInputFrameLast1* {.exportc: "nimfw_dbg_tcpip_input_frame_last1".}: uint32
var nimFwDbgTcpipInputFrameSrc0* {.exportc: "nimfw_dbg_tcpip_input_frame_src0".}: uint32
var nimFwDbgTcpipInputFrameSrc1* {.exportc: "nimfw_dbg_tcpip_input_frame_src1".}: uint32
var nimFwDbgTcpipInputFrameSrc2* {.exportc: "nimfw_dbg_tcpip_input_frame_src2".}: uint32
var nimFwDbgTcpipInputFrameSrc3* {.exportc: "nimfw_dbg_tcpip_input_frame_src3".}: uint32
var nimFwDbgTcpipInputFramePbuf0* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf0".}: uint32
var nimFwDbgTcpipInputFramePbuf1* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf1".}: uint32
var nimFwDbgTcpipInputFramePbuf2* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf2".}: uint32
var nimFwDbgTcpipInputFramePbuf3* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf3".}: uint32
var nimFwDbgTcpipInputFrameEthType* {.exportc: "nimfw_dbg_tcpip_input_frame_ethertype".}: uint32
var nimFwDbgTcpipInputArp* {.exportc: "nimfw_dbg_tcpip_input_arp".}: uint32
var nimFwDbgTcpipInputTcp* {.exportc: "nimfw_dbg_tcpip_input_tcp".}: uint32
var nimFwDbgTcpipInputTcp80* {.exportc: "nimfw_dbg_tcpip_input_tcp80".}: uint32
var nimFwDbgTcpipInputTcpFlags* {.exportc: "nimfw_dbg_tcpip_input_tcp_flags".}: uint32
var nimFwDbgTcpipInputScanHit* {.exportc: "nimfw_dbg_tcpip_input_scan_hit".}: uint32
var nimFwDbgTcpipInputScanMeta* {.exportc: "nimfw_dbg_tcpip_input_scan_meta".}: uint32
var nimFwDbgTcpipInputScanPorts* {.exportc: "nimfw_dbg_tcpip_input_scan_ports".}: uint32
var nimFwDbgTcpipInputScanRaw* {.exportc: "nimfw_dbg_tcpip_input_scan_raw".}: array[96, uint8]
var nimFwDbgPbufAllocFail {.importc: "nimfw_dbg_pbuf_alloc_fail".}: uint32
var nimFwDbgPbufTakeFail {.importc: "nimfw_dbg_pbuf_take_fail".}: uint32

proc noteMpduFail(code: uint32) =
  nimFwDbgTcpipInputMpduFail = code
  if code >= 1 and code <= 4:
    nimFwDbgTcpipInputMpduFailDetailLo += 1'u32 shl ((code - 1) * 8)
  elif code >= 5 and code <= 8:
    nimFwDbgTcpipInputMpduFailDetailHi += 1'u32 shl ((code - 5) * 8)
  case code
  of 6:
    nimFwDbgTcpipInputMpduFailCounts += 1
  of 7:
    nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 8
  of 8:
    nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 16
  else:
    nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 24
