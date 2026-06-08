var staIface: WifiInterface
var
  wifiScanFuture: CpsFuture[uint32]
  wifiScanTimer: TimerId
  wifiConnectFuture: CpsFuture[WifiError]
  wifiConnectTimer: TimerId
  wifiStaIdleFuture: CpsFuture[WifiError]
  wifiStaIdleTimer: TimerId
  wifiDisconnectFuture: CpsFuture[WifiError]
  wifiDisconnectTimer: TimerId
  wifiDisconnectIssuePending: bool
  wifiDisconnectIssueTimeoutMs: uint32
