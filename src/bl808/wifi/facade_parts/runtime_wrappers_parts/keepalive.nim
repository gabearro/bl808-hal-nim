proc wifiNimFirmwareSendStaKeepaliveFrame(): WifiError {.inline.} =
  case wifi_nimfw_send_sta_null_frame()
  of 0'u8: wifiOk
  of 2'u8: wifiBusy
  else: wifiFail

proc wifiNimFirmwareSetKeepaliveQosNull(enabled: bool) {.inline.} =
  wifi_nimfw_set_keepalive_qosnull_enabled(
    if enabled: 1'u32 else: 0'u32)

proc wifiNimFirmwareKeepaliveAckOkCount(): uint32 {.inline.} =
  wifi_nimfw_null_frame_ack_ok_count()

proc wifiNimFirmwareKeepaliveConfirmCount(): uint32 {.inline.} =
  wifi_nimfw_null_frame_cfm_count()

proc wifiNimFirmwareKeepaliveFailCount(): uint32 {.inline.} =
  wifi_nimfw_null_frame_fail_count()
