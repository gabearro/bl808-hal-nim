## DNS A-record lookups over lwIP UDP (the repo's Wi-Fi lwIP profile is
## built without lwIP's own resolver). Firmware only; the packet format
## lives in `dnsmsg.nim` (pure).
##
## Servers, in turn: the gateway DHCP gave us (home routers forward DNS),
## then two public resolvers. Each gets `TryTimeoutMs` to answer, and the
## list is gone through `Rounds` times before the lookup fails.
##
## A `Resolver` must stay where it is while a lookup is pending: lwIP holds
## its address. Keep it in a module variable or a heap object.

import bl808/kernel/lwipcore
import ./netio, ./netstate, ./dnsmsg, ./timebase

const
  TryTimeoutMs = 1_500'u64
  Rounds = 2
  PublicServers = [
    0x0101_0101'u32,                          # 1.1.1.1
    0x0808_0808'u32,                          # 8.8.8.8
  ]

type
  Resolver* = object
    addrs*: array[4, uint32]   ## answers, network byte order
    count*: int
    state: ResolveState
    pcb: ptr UdpPcb
    host: array[254, char]
    hostLen: int
    id: uint16
    servers: array[1 + PublicServers.len, uint32]
    serverCount: int
    tries: int                 ## queries sent
    sentMs: uint64
    hurry: bool                ## the server asked just now can't help: move on

var queryCount: uint32

proc currentServer(r: Resolver): uint32 =
  r.servers[(r.tries - 1) mod r.serverCount]

proc onReply(arg: pointer; pcb: ptr UdpPcb; p: ptr Pbuf; remote: ptr IpAddr;
             port: uint16) {.cdecl.} =
  let r = cast[ptr Resolver](arg)
  if p == nil: return
  # A reply fits one buffer; anything chained is not one of ours.
  if r.state == rsPending and port == DnsPort and remote != nil and
      pbufLen(p) == pbufTotLen(p):
    var known = false
    for i in 0 ..< r.serverCount:
      if r.servers[i] == remote.address: known = true
    if known:
      let data = cast[ptr UncheckedArray[byte]](pbufPayload(p))
      var addrs: array[MaxAddrs, uint32]
      var count = 0
      case parseReply(data.toOpenArray(0, pbufLen(p).int - 1), r.id, addrs, count)
      of drOk:
        r.addrs = addrs
        r.count = count
        r.state = rsOk
      of drNoAddress: r.state = rsNoAddress
      of drNameError: r.state = rsFailed
      of drServerError, drMalformed:
        if remote.address == currentServer(r[]): r.hurry = true
      of drNotOurs: discard
  discard pbufFree(p)

proc release(r: var Resolver) =
  if r.pcb != nil:
    udpRemove(r.pcb)
    r.pcb = nil

proc sendQuery(r: var Resolver) =
  let server = r.servers[r.tries mod r.serverCount]
  inc r.tries
  r.sentMs = nowMs()
  r.hurry = false
  let size = queryLen(r.host.toOpenArray(0, r.hostLen - 1))
  let p = pbufAlloc(pbufTransport, size.uint16, pbufRam)
  if p == nil: return               # out of memory: this try is spent
  let payload = cast[ptr UncheckedArray[byte]](pbufPayload(p))
  discard buildQuery(r.id, r.host.toOpenArray(0, r.hostLen - 1),
                     payload.toOpenArray(0, size - 1))
  var dst = IpAddr(address: server)
  discard udpSendto(r.pcb, p, addr dst, DnsPort)
  discard pbufFree(p)

proc cancel*(r: var Resolver) =
  r.release()
  r.state = rsFailed

proc start*(r: var Resolver; host: openArray[char]) =
  ## Begin a lookup (a dotted-quad `host` resolves at once).
  r.cancel()
  r.count = 0
  var literal: uint32
  if parseIpv4(host, literal):
    r.addrs[0] = literal
    r.count = 1
    r.state = rsOk
    return
  if host.len > r.host.len or queryLen(host) == 0: return
  for i in 0 ..< host.len: r.host[i] = host[i]
  r.hostLen = host.len

  r.serverCount = 0
  let gateway = net.gateway[0].uint32 or (net.gateway[1].uint32 shl 8) or
    (net.gateway[2].uint32 shl 16) or (net.gateway[3].uint32 shl 24)
  if gateway != 0:
    r.servers[0] = gateway
    r.serverCount = 1
  for server in PublicServers:
    if server != gateway:
      r.servers[r.serverCount] = server
      inc r.serverCount

  r.pcb = udpNew()
  if r.pcb == nil: return
  udpRecv(r.pcb, onReply, addr r)
  # Hard to guess, and different for every lookup.
  inc queryCount
  let t = nowUs()
  r.id = uint16((t xor (t shr 16)) and 0xFFFF) xor uint16((queryCount * 40503'u32) and 0xFFFF)
  r.tries = 0
  r.state = rsPending
  r.sendQuery()

proc poll*(r: var Resolver): ResolveState =
  ## `rsOk` with `addrs` / `count` filled, `rsNoAddress` for a name without
  ## an A record, `rsFailed` after the retries run out.
  if r.state == rsPending and r.pcb != nil and
      (r.hurry or elapsedMs(r.sentMs, nowMs()) >= TryTimeoutMs):
    if r.tries >= Rounds * r.serverCount: r.state = rsFailed
    else: r.sendQuery()
  if r.pcb == nil and r.state == rsPending:
    r.state = rsFailed              # never started
  if r.state != rsPending:
    r.release()
  r.state
