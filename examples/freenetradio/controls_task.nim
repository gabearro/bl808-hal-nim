## The controls: IR capture and decoding, the remote's digit timer, the
## preset job pump, the settings save tick, and the NTP task (the network
## half of upstream `src/clock.rs`). Firmware only.
##
## `controlsStart` brings up the flash store and restores the saved
## settings before returning, so the stream task (started next) can pick up
## where the radio left off.

import bl808/kernel/cps
import bl808/kernel/lwipcore
import bl808/kernel/log
import ./timebase, ./netstate, ./netio, ./wallclock, ./resolver
import ./flashdev, ./presets, ./settings, ./remote, ./ir_rx

const
  ControlsPeriodMs = 5
  SettingsTickMs = 1000

# ---- NTP -------------------------------------------------------------------
# Nothing is shown until the first successful sync. After that the time
# keeps running from the local timer and is re-synced every hour (a failed
# re-sync just keeps the old time).

type
  NtpPhase = enum
    npWaitNetwork     ## until the network has an address
    npResolving       ## looking up pool.ntp.org
    npQuery           ## asked `servers[index]`, waiting for its answer

  Ntp = object
    phase: NtpPhase
    resolver: Resolver
    pcb: ptr UdpPcb
    servers: array[4, uint32]     # network byte order
    serverCount: int
    index: int
    deadlineMs: uint64
    # The socket's one-datagram receive buffer.
    rxHave: bool
    rxLen: int
    rxFrom: uint32
    rxAtMs: uint64
    rx: array[NtpPacketLen, byte]

const
  NtpPollMs = 10'u64
  NtpWaitNetworkMs = 100'u64

var ntp: Ntp

proc ntpReceive(arg: pointer; pcb: ptr UdpPcb; p: ptr Pbuf; remoteAddr: ptr IpAddr;
                port: uint16) {.cdecl.} =
  if p == nil: return
  if not ntp.rxHave:      # a second datagram before the first is read is dropped
    ntp.rxHave = true
    ntp.rxAtMs = nowMs()
    ntp.rxFrom = if remoteAddr != nil: remoteAddr.address else: 0
    ntp.rxLen = min(pbufTotLen(p).int, NtpPacketLen)
    discard pbufCopyPartial(p, addr ntp.rx, ntp.rxLen.uint16, 0)
  discard pbufFree(p)

proc ntpClose() =
  if ntp.pcb != nil:
    udpRemove(ntp.pcb)
    ntp.pcb = nil

proc ntpSend(server: uint32): bool =
  ## Ask one server.
  let p = pbufAlloc(pbufTransport, NtpPacketLen, pbufRam)
  if p == nil: return false
  var request = ntpRequest()
  var dst = IpAddr(address: server)
  result = pbufTake(p, addr request, NtpPacketLen) == 0 and
           udpSendto(ntp.pcb, p, addr dst, NtpPort) == 0
  discard pbufFree(p)

proc ntpFinish(ok: bool): uint64 =
  ## The sync attempt is over: how long to sleep before the next.
  ntpClose()
  ntp.phase = npWaitNetwork
  if ok: ResyncMs.uint64 else: RetryMs.uint64

proc ntpAsk(): uint64 =
  ## Ask `servers[index]`, or the next one that a request can be sent to.
  ## The pool returns several addresses; each is tried in turn.
  while ntp.index < ntp.serverCount:
    if ntpSend(ntp.servers[ntp.index]):
      ntp.phase = npQuery
      ntp.deadlineMs = nowMs() + QueryTimeoutMs.uint64
      return NtpPollMs
    inc ntp.index
  ntpFinish(ok = false)

proc ntpStep(): uint64 =
  ## One step of the NTP client; returns the milliseconds to sleep before
  ## the next.
  case ntp.phase
  of npWaitNetwork:
    if not configUp(): return NtpWaitNetworkMs
    ntp.resolver.start(NtpServer)
    ntp.phase = npResolving
    NtpPollMs
  of npResolving:
    case ntp.resolver.poll()
    of rsPending: NtpPollMs
    of rsFailed, rsNoAddress: ntpFinish(ok = false)
    of rsOk:
      ntp.serverCount = min(ntp.resolver.count, ntp.servers.len)
      for i in 0 ..< ntp.serverCount: ntp.servers[i] = ntp.resolver.addrs[i]
      ntp.index = 0
      ntp.rxHave = false
      ntp.pcb = udpNew()
      if ntp.pcb == nil: return ntpFinish(ok = false)
      var anyAddr = ipAddrAny()
      if udpBind(ntp.pcb, addr anyAddr, 0) != 0: return ntpFinish(ok = false)
      udpRecv(ntp.pcb, ntpReceive, nil)
      ntpAsk()
  of npQuery:
    if ntp.rxHave:
      # The first datagram in ends the wait. It counts if it is a server
      # answer of stratum 1..15 (0 = kiss-o'-death / unsynchronised) from
      # the server that was asked.
      ntp.rxHave = false
      var unix: uint64
      if ntp.rxFrom == ntp.servers[ntp.index] and
          ntpParse(ntp.rx.toOpenArray(0, ntp.rxLen - 1), unix):
        setSynced(unix, ntp.rxAtMs)
        logInfo "ntp: synced"
        return ntpFinish(ok = true)
    elif nowMs() < ntp.deadlineMs:
      return NtpPollMs
    inc ntp.index
    ntpAsk()

proc ntpTask(): CpsVoidFuture {.cps.} =
  while true:
    let waitMs = ntpStep()
    await sleepMs(waitMs)

# ---- IR, digits, preset jobs, settings -------------------------------------

var lastSettingsTickMs: uint64

proc controlsStep() =
  irPoll(remote.onPress)
  remote.poll()
  presets.poll()
  if elapsedMs(lastSettingsTickMs, nowMs()) >= SettingsTickMs:
    lastSettingsTickMs = nowMs()
    settingsTick()

proc controlsTask(): CpsVoidFuture {.cps.} =
  while true:
    controlsStep()
    await sleepMs(ControlsPeriodMs)

proc controlsStart*() =
  let dev = hardwareFlash()
  presetsInit(dev)
  settingsInit(dev)
  settingsRestore()
  remoteInit()
  irInit()
  lastSettingsTickMs = nowMs()
  ntp = Ntp()
  discard controlsTask()
  discard ntpTask()
