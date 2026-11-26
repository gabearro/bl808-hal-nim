## The stream client task: binds `stream.nim`'s state machine to the lwIP
## adapter (`resolver`, `tcpconn`) and, through `tlsbind.nim`, the repo's TLS
## module, and steps it. Firmware only. Build with -d:radioNoTls to leave
## TLS out (https URLs then fail with a message).

import bl808/kernel/cps
import ./netio, ./resolver, ./tcpconn, ./stream, ./diag

const HaveTls = not defined(radioNoTls)

when HaveTls:
  import ./tlsbind

type
  Link = object
    ## What the client's `NetOps` / `SecureOps` contexts point at.
    resolver: Resolver
    conn: TcpConn
    when HaveTls:
      tls: TlsLink

var
  link: ptr Link
  client: ptr StreamClient

template at(ctx: pointer): ptr Link = cast[ptr Link](ctx)

# ---- NetOps: name lookup and one TCP connection ------------------------------

proc opResolveStart(ctx: pointer; host: openArray[char]) {.nimcall.} =
  at(ctx).resolver.start(host)

proc opResolvePoll(ctx: pointer; ip: var uint32): ResolveState {.nimcall.} =
  result = at(ctx).resolver.poll()
  if result == rsOk: ip = at(ctx).resolver.addrs[0]

proc opConnectStart(ctx: pointer; ip: uint32; port: uint16) {.nimcall.} =
  at(ctx).conn.connect(ip, port)

proc opConnectPoll(ctx: pointer): ConnState {.nimcall.} =
  at(ctx).conn.state

proc opSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  at(ctx).conn.send(data, len)

proc opRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  at(ctx).conn.recv(data, len)

proc opClose(ctx: pointer) {.nimcall.} =
  at(ctx).resolver.cancel()
  at(ctx).conn.abort()

proc opRxQueued(ctx: pointer): int {.nimcall.} = at(ctx).conn.rxQueued
proc opTxQueued(ctx: pointer): int {.nimcall.} = at(ctx).conn.txQueued

# ---- SecureOps: the repo's TLS session over that connection ------------------

proc secureOps(): SecureOps =
  when HaveTls:
    tlsbind.secureOps(addr link.tls)
  else:
    # `available: false`: the client never calls the rest.
    SecureOps(available: false)

# ---- The task -----------------------------------------------------------------

proc streamTask(): CpsVoidFuture {.cps.} =
  while true:
    var hint: StepHint
    timed(slStream): hint = client[].step()
    if hint == shYield:
      await yieldNow()
    elif hint == shWait:
      await sleepMs(1)
    else:
      await sleepMs(5)

proc streamStart*() =
  link = createShared(Link)
  link.conn = newTcpConn()
  client = createShared(StreamClient)
  streamInit(client[], NetOps(ctx: link, resolveStart: opResolveStart,
      resolvePoll: opResolvePoll, connectStart: opConnectStart,
      connectPoll: opConnectPoll, send: opSend, recv: opRecv, close: opClose,
      rxQueued: opRxQueued, txQueued: opTxQueued),
    secureOps())
  discard streamTask()
