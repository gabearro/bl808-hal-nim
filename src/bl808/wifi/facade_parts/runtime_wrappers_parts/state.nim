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

when defined(bl808WifiDiagLinkDrop):
  type WifiScanObservationKind* = enum
    wifiScanPending, wifiScanUnavailable, wifiScanSubmitRejected,
    wifiScanTimedOut, wifiScanConfirmed
  var wifiScanObservation: tuple[kind: WifiScanObservationKind, code: uint32]

  proc wifiLastScanObservation*(): tuple[kind: WifiScanObservationKind, code: uint32] =
    wifiScanObservation

  template noteWifiScan(kind, code: untyped) =
    wifiScanObservation = (kind, code)
else:
  template noteWifiScan(kind, code: untyped) = discard
