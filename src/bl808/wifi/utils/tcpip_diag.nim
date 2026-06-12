var nimFwDbgTcpipInputCalls* {.exportc: "nimfw_dbg_tcpip_input_calls".}: uint32
var nimFwDbgTcpipInputNoForward* {.exportc: "nimfw_dbg_tcpip_input_no_forward".}: uint32
var nimFwDbgTcpipInputMpdu* {.exportc: "nimfw_dbg_tcpip_input_mpdu".}: uint32
var nimFwDbgTcpipInputNoVif* {.exportc: "nimfw_dbg_tcpip_input_no_vif".}: uint32
var nimFwDbgTcpipInputNoNetif* {.exportc: "nimfw_dbg_tcpip_input_no_netif".}: uint32
var nimFwDbgTcpipInputNoPbuf* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf".}: uint32
var nimFwDbgTcpipInputOk* {.exportc: "nimfw_dbg_tcpip_input_ok".}: uint32
var nimFwDbgTcpipInputFail* {.exportc: "nimfw_dbg_tcpip_input_fail".}: uint32
var nimFwDbgTcpipInputNoPbufStatus* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_status".}: uint32
var nimFwDbgTcpipInputNoPbufFlags* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_flags".}: uint32
var nimFwDbgTcpipInputNoPbufMeta* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_meta".}: uint32
var nimFwDbgTcpipInputNoPbufPkt* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_pkt".}: uint32
var nimFwDbgTcpipInputNoPbufStage* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_stage".}: uint32
var nimFwDbgTcpipInputNoPbufRaw* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_raw".}: array[64, uint8]

proc noteTcpipNoPbuf(stage, status, flags, msduOffset: uint32;
                     usedMpduInput: bool; pkt: pointer) =
  inc nimFwDbgTcpipInputNoPbuf
  nimFwDbgTcpipInputNoPbufStage = stage
  nimFwDbgTcpipInputNoPbufStatus = status
  nimFwDbgTcpipInputNoPbufFlags = flags
  nimFwDbgTcpipInputNoPbufMeta =
    (msduOffset and 0xFFFF'u32) or
    ((if usedMpduInput: 1'u32 else: 0'u32) shl 16) or
    (if pkt == nil: 0'u32 else: loadU16(pkt, WifiPktLenOff).uint32 shl 17)
  nimFwDbgTcpipInputNoPbufPkt = cast[uint](pkt).uint32
  for noPbufRawByteIndex in 0 ..< nimFwDbgTcpipInputNoPbufRaw.len:
    nimFwDbgTcpipInputNoPbufRaw[noPbufRawByteIndex] = 0
  if pkt != nil and loadU16(pkt, WifiPktLenOff) != 0'u16:
    let uploadFrameData = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)
    let noPbufRawCopyLimit =
      if loadU16(pkt, WifiPktLenOff).int < nimFwDbgTcpipInputNoPbufRaw.len:
        loadU16(pkt, WifiPktLenOff).int
      else:
        nimFwDbgTcpipInputNoPbufRaw.len
    for noPbufRawByteIndex in 0 ..< noPbufRawCopyLimit:
      nimFwDbgTcpipInputNoPbufRaw[noPbufRawByteIndex] =
        loadU8(uploadFrameData, noPbufRawByteIndex.uint)

proc wifi_nimfw_tcpip_input_calls*(): uint32 {.exportc, cdecl.} =
  nimFwDbgTcpipInputCalls
proc wifi_nimfw_tcpip_input_ok*(): uint32 {.exportc, cdecl.} =
  nimFwDbgTcpipInputOk
proc wifi_nimfw_tcpip_input_fail*(): uint32 {.exportc, cdecl.} =
  nimFwDbgTcpipInputFail
proc wifi_nimfw_tcpip_input_drop_flags*(): uint32 {.exportc, cdecl.} =
  (nimFwDbgTcpipInputNoForward and 0xff'u32) or
    ((nimFwDbgTcpipInputMpdu and 0xff'u32) shl 8) or
    ((nimFwDbgTcpipInputNoVif and 0xff'u32) shl 16) or
    ((nimFwDbgTcpipInputNoNetif and 0xff'u32) shl 24)
proc wifi_nimfw_tcpip_input_no_pbuf*(): uint32 {.exportc, cdecl.} =
  nimFwDbgTcpipInputNoPbuf
