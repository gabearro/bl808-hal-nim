## Opt-in connected scan bench for the standalone Wi-Fi HTTP/UDP server.

const
  WifiScanAbWarmupMs {.intdefine.} = 8_000'u32
  WifiScanAbWindowMs {.intdefine.} = 40_000'u32
  WifiScanAbWindows {.intdefine.} = 4'u32
  WifiScanAbWpaComplete = 10'u32

static:
  doAssert WifiScanAbWindows > 0 and WifiScanAbWindows mod 4 == 0
  doAssert WifiScanAbWindowMs > 0 and WifiScanAbWindowMs < 0x8000_0000'u32

type ScanAbBench = object
  readyAt, windowAt, window: uint32
  firstHomeMs: uint32
  httpBefore, udpBefore: uint32
  homeBefore: array[7, uint32]
  active, stopped, submitted, confirmed, homeSeen: bool

proc scanAbTreatment(window: uint32): bool {.inline.} =
  (window and 3).uint8 in {1'u8, 2'u8}

proc scanAbLinkUp(): bool {.inline.} =
  bl808_wifi_backend_connected() != 0 and wifiScanAbWpaState() == WifiScanAbWpaComplete

proc scanAbIp(): uint32 {.inline.} =
  let netif = cast[ptr Netif](wifiGetNetif())
  if netif == nil: 0'u32 else: netifIp4(netif)

proc scanAbEnd(bench: var ScanAbBench; now, ip: uint32; outcome: string) =
  var home: array[7, uint32]
  for i in 0 ..< home.len: home[i] = wifiScanAbHome[i]
  let homeRequests = home[0] - bench.homeBefore[0]
  phaseMark(Phase.scan, Kind.info):
    kvWrite("bench", "scan_ab")
    kvWrite("event", "window_end")
    kvWrite("outcome", outcome)
    kvWrite("window", bench.window)
    kvWrite("scan", scanAbTreatment(bench.window).uint32)
    kvWrite("submitted", bench.submitted.uint32)
    kvWrite("confirmed", bench.confirmed.uint32)
    kvWrite("ms", now)
    kvWrite("ip", ip)
    kvWrite("wpa", wifiScanAbWpaState())
    kvWrite("status", bl808_wifi_backend_last_status())
    kvWrite("reason", bl808_wifi_backend_last_reason())
    kvWrite("http", httpRequests - bench.httpBefore)
    kvWrite("udp_rx", udpRxPackets - bench.udpBefore)
    kvWrite("home", homeRequests)
    if homeRequests != 0: kvWrite("home_mac_us", home[1])
    if bench.homeSeen: kvWrite("first_home_ms", bench.firstHomeMs)
    kvWrite("home_queued", home[2] - bench.homeBefore[2])
    kvWrite("home_ack", home[3] - bench.homeBefore[3])
    kvWrite("home_no_ack", home[4] - bench.homeBefore[4])
    kvWrite("home_retired", home[5] - bench.homeBefore[5])
    if home[3] != bench.homeBefore[3] or home[4] != bench.homeBefore[4] or
        home[5] != bench.homeBefore[5]: kvWrite("last_tx", home[6])
  inc bench.window
  bench.active = false
  if outcome != "complete" or bench.window == WifiScanAbWindows:
    bench.stopped = true
    phaseMark(Phase.scan, Kind.info):
      kvWrite("bench", "scan_ab")
      kvWrite("event", "finished")
      kvWrite("outcome", outcome)
      kvWrite("windows", bench.window)

proc scanAbTick(bench: var ScanAbBench) =
  if bench.stopped: return
  var now = nowMs()
  if not bench.active and now - bench.readyAt < WifiScanAbWarmupMs: return
  var ip = scanAbIp()
  var connected = scanAbLinkUp()
  if not bench.active:
    bench.windowAt = now
    bench.httpBefore = httpRequests
    bench.udpBefore = udpRxPackets
    for i in 0 ..< bench.homeBefore.len: bench.homeBefore[i] = wifiScanAbHome[i]
    bench.active = true
    bench.submitted = false
    bench.confirmed = false
    bench.homeSeen = false
    phaseMark(Phase.scan, Kind.info):
      kvWrite("bench", "scan_ab")
      kvWrite("event", "window_start")
      kvWrite("window", bench.window)
      kvWrite("scan", scanAbTreatment(bench.window).uint32)
      kvWrite("ms", now)
    if connected and ip == httpLastIp and scanAbTreatment(bench.window):
      # Same manager entry as wifiScanAsync; this example drives the backend
      # in its existing polling loop and does not start a CPS scheduler.
      let status = wifi_mgmr_scan(nil, nil)
      # The command waits for firmware and can dispatch a link event inline.
      now = nowMs()
      ip = scanAbIp()
      connected = scanAbLinkUp()
      if status != 0:
        phaseMark(Phase.scan, Kind.info):
          kvWrite("bench", "scan_ab")
          kvWrite("event", "submit_rejected")
          kvWrite("window", bench.window)
          kvWrite("rc", status)
        if connected and ip == httpLastIp:
          scanAbEnd(bench, now, ip, "submit_rejected")
          return
      else:
        bench.submitted = true

  if not bench.homeSeen and wifiScanAbHome[0] != bench.homeBefore[0]:
    bench.homeSeen = true
    bench.firstHomeMs = nowMs()
  if not connected or ip != httpLastIp:
    scanAbEnd(bench, now, ip, if not connected: "link_lost" else: "lease_changed")
    return
  if bench.submitted and not bench.confirmed and bl808_wifi_backend_scan_done_count() != 0:
    bench.confirmed = true
    let status = wifiScanAbConfirmStatus()
    phaseMark(Phase.scan, Kind.info):
      kvWrite("bench", "scan_ab")
      kvWrite("event", "scan_confirm")
      kvWrite("window", bench.window)
      kvWrite("ms", now)
      kvWrite("status", status)
      kvWrite("results", bl808_wifi_backend_scan_count())
    if status != 0:
      scanAbEnd(bench, now, ip, "scan_failed")
      return
  if now - bench.windowAt >= WifiScanAbWindowMs:
    scanAbEnd(bench, now, ip,
      if bench.submitted and not bench.confirmed: "scan_timeout" else: "complete")
