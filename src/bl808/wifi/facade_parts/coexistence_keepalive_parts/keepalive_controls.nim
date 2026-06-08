proc wifiSendStaKeepaliveFrame*(): WifiError =
  ## Transmit one STA null-data keepalive frame when the Nim WiFi firmware is
  ## associated. This is a WiFi MAC TX primitive for coexistence validation,
  ## not a replacement for the lwIP data path.
  wifiNimFirmwareSendStaKeepaliveFrame()

proc wifiSetStaKeepaliveQosNull*(enabled: bool) =
  ## Select QoS-null framing for the STA keepalive TX primitive. Normal WiFi
  ## keepalive validation uses legacy null-data by default; coexistence tests
  ## enable QoS-null because it follows the SDK U-APSD/control path.
  wifiNimFirmwareSetKeepaliveQosNull(enabled)

proc wifiStaKeepaliveAckOkCount*(): uint32 =
  wifiNimFirmwareKeepaliveAckOkCount()

proc wifiStaKeepaliveConfirmCount*(): uint32 =
  wifiNimFirmwareKeepaliveConfirmCount()

proc wifiStaKeepaliveFailCount*(): uint32 =
  wifiNimFirmwareKeepaliveFailCount()
