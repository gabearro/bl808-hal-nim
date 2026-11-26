## Wi-Fi station, DHCP and reconnect; keeps `netstate.net` current and polls
## lwIP. Firmware only.
##
## `netStart` calls `lwipInit()` and `wifiInit()` synchronously. `wifiInit`
## runs Nim's PreMain (every module's top-level initialisers), which the
## bare-metal startup otherwise never runs, so main calls `netStart` before
## any other module sets up its state.
##
## The supervision is modelled on examples/m0_allcore_wasm_cps_live_test.nim:
## join, wait for the WPA handshake, DHCP; then watch the association and
## the lease. A link that stays down for `LinkLostConfirmMs` (a blip
## shorter than that is ignored) is torn down and joined again, with a
## growing pause between failed attempts. Nothing here reboots.

import bl808/wifi
import bl808/kernel/cps
import bl808/kernel/lwipcore
import bl808/kernel/log
import ./netstate, ./timebase, ./diag

const
  WifiSsid* {.strdefine.} = ""
  WifiPassword* {.strdefine.} = ""

  WpaCompletedState = 10'u32
  JoinTimeoutMs = 30_000'u32
  WpaTimeoutMs = 15_000'u64
  DhcpTimeoutMs = 30_000'u64        ## associated but no lease: join again
  DisconnectTimeoutMs = 10_000'u32
  LinkLostConfirmMs = 3_000'u64     ## sustained-down before reconnecting
  BackoffStepMs = 5_000'u64         ## pause after a failed attempt ...
  BackoffMaxMs = 20_000'u64         ## ... doubling up to this
  PollMs = 10

type
  NetStage = enum
    nsJoin        ## start associating
    nsJoining     ## waiting for the join to finish
    nsWpa         ## waiting for the 4-way handshake, then start DHCP
    nsUp          ## associated: watch the link and the lease
    nsLeaving     ## waiting for the disconnect to finish
    nsBackoff

  NetCtl = object
    stage: NetStage
    pending: CpsFuture[WifiError]
    netif: ptr Netif
    sinceMs: uint64         ## when the current stage (or wait) began
    downSinceMs: uint64     ## first time the link was seen down (0 = up)
    noLeaseSinceMs: uint64  ## first time there was no lease (0 = have one)
    backoffMs: uint64

var ctl: NetCtl

proc bl808WpaCurrentState(): uint32 {.importc: "bl808_wpa_current_state", cdecl.}

proc associated(): bool {.inline.} =
  bl808_wifi_backend_connected() != 0 and bl808WpaCurrentState() == WpaCompletedState

proc octets(address: uint32): array[4, uint8] =
  for i in 0 ..< 4: result[i] = uint8((address shr (8 * i)) and 0xFF)

proc finished(ok: var bool): bool =
  ## Whether the pending Wi-Fi operation is done, and how it went.
  if not ctl.pending.finished: return false
  ok = not ctl.pending.hasError and ctl.pending.read() == wifiOk
  ctl.pending = nil
  true

proc leave() =
  ## Give the association up (or the attempt at one) and start over.
  if net.linkUp:
    inc stats.wifiReconnects
    logWarn "wifi: link lost, reconnecting"
  net.linkUp = false
  net.hasIp = false
  if ctl.netif != nil:
    dhcpStop(ctl.netif)
    ctl.netif = nil
  ctl.pending = wifiDisconnectAsync(DisconnectTimeoutMs)
  ctl.stage = nsLeaving

proc updateLease(now: uint64) =
  let address = netifIp4Addr(ctl.netif).address
  if dhcpSuppliedAddress(ctl.netif) != 0 and address != 0:
    let ip = octets(address)
    let fresh = not net.hasIp or ip != net.ip
    net.ip = ip
    net.gateway = octets(netifIp4Gw(ctl.netif).address)
    net.hasIp = true
    ctl.noLeaseSinceMs = 0
    ctl.backoffMs = 0
    if fresh:
      discard etharpGratuitous(ctl.netif)
      logInfo "wifi: address ":
        lU32(ip[0]); lChar('.'); lU32(ip[1]); lChar('.')
        lU32(ip[2]); lChar('.'); lU32(ip[3])
  else:
    # A NAK or expiry can clear the address while lwIP rediscovers in place.
    net.hasIp = false
    if ctl.noLeaseSinceMs == 0: ctl.noLeaseSinceMs = now

proc netStep() =
  ## One pass of the supervisor; never waits.
  let now = nowMs()
  var ok = false
  case ctl.stage
  of nsJoin:
    ctl.pending = wifiConnectAsync(WifiSsid, WifiPassword, 0'u8, JoinTimeoutMs)
    ctl.stage = nsJoining
  of nsJoining:
    if finished(ok):
      if ok:
        ctl.sinceMs = now
        ctl.stage = nsWpa
      else:
        leave()
  of nsWpa:
    if associated():
      let netif = cast[ptr Netif](wifiGetNetif())
      if netif != nil and dhcpStart(netif) == ErrOk:
        ctl.netif = netif
        ctl.downSinceMs = 0
        ctl.noLeaseSinceMs = now
        net.linkUp = true
        ctl.stage = nsUp
        logInfo "wifi: joined"
        return
    if bl808_wifi_backend_connected() == 0 or elapsedMs(ctl.sinceMs, now) >= WpaTimeoutMs:
      leave()
  of nsUp:
    if associated():
      ctl.downSinceMs = 0
    elif ctl.downSinceMs == 0:
      ctl.downSinceMs = now
    elif elapsedMs(ctl.downSinceMs, now) >= LinkLostConfirmMs:
      leave()
      return
    updateLease(now)
    if ctl.noLeaseSinceMs != 0 and elapsedMs(ctl.noLeaseSinceMs, now) >= DhcpTimeoutMs:
      leave()
  of nsLeaving:
    if finished(ok):
      ctl.sinceMs = now
      ctl.stage = nsBackoff
  of nsBackoff:
    if elapsedMs(ctl.sinceMs, now) >= ctl.backoffMs:
      # The first attempt after a loss is immediate; failed ones back off.
      ctl.backoffMs =
        if ctl.backoffMs == 0: BackoffStepMs else: min(ctl.backoffMs * 2, BackoffMaxMs)
      ctl.stage = nsJoin

proc netTask(): CpsVoidFuture {.cps.} =
  while true:
    timed(slNet):
      netStep()
      sysCheckTimeouts()
    await sleepMs(PollMs)

proc netStart*() =
  lwipInit()
  if wifiInit() != wifiOk:
    logError "wifi init failed"
    return
  ctl = NetCtl(stage: nsJoin)
  net = NetState()
  wifiInstallServiceHook(periodUs = 1000'u32, iterations = 16'u32)
  if WifiSsid.len == 0:
    logError "no Wi-Fi network: build with -d:WifiSsid=... -d:WifiPassword=..."
    return
  discard netTask()
