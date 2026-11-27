## The web server: two concurrent connections on port 80 over `tcpconn`,
## answered by `httpd.nim` (upstream `main.rs` `http_task`).
## Firmware only.
##
## Each connection carries one request. The whole request must arrive and
## be answered within 5 s (60 s in diag builds, for screen recordings), so a
## stalled or trickling client cannot hold a slot (there are only two)
## indefinitely. Then the connection is closed (lwIP goes on delivering what
## was queued), given up to 10 s for anything `tcpconn` still reports as
## unsent, and dropped: upstream's close, flush, abort. A third simultaneous
## connection is refused rather than queued.

import bl808/kernel/cps
import bl808/kernel/log
import ./httpd, ./tcpconn, ./netstate, ./timebase, ./diag
when defined(bl808m0) and defined(radioProfiler):
  import bl808/kernel/profiler

const
  HttpPort = 80'u16
  HttpConns = 2
  RequestMs = (if DiagEnabled: 60_000 else: 5_000)
  FlushMs = 10_000
  BusyPollMs = 2
  IdlePollMs = 20

type
  Slot = object
    conn: TcpConn            # nil while the slot is free
    exchange: ptr Exchange   # allocated once, at start
    closing: bool            # closed; waiting for the queued bytes to go out
    deadlineMs: uint64

var
  listener: TcpListener
  slots: array[HttpConns, Slot]

proc service(s: var Slot) =
  let now = nowMs()
  if not s.closing:
    let over = pump(s.exchange[], cast[pointer](s.conn), ioSend, ioRecv)
    if over or now >= s.deadlineMs:
      finish(s.exchange[])
      s.conn.close()
      s.closing = true
      s.deadlineMs = now + FlushMs
  elif s.conn.txQueued() == 0 or now >= s.deadlineMs:
    s.conn.abort()
    s.conn = nil

proc httpPoll(): uint64 =
  ## Serve what can be served now; returns when to come back, in ms.
  when defined(bl808m0) and defined(radioProfiler):
    expireProfile()
  if listener == nil:
    # Like upstream, the server starts once the network is configured.
    if not configUp(): return IdlePollMs
    listener = listen(HttpPort, HttpConns)
    if listener == nil: return IdlePollMs
    logInfo "Serving on http://":
      lU32(net.ip[0]); lChar('.'); lU32(net.ip[1]); lChar('.')
      lU32(net.ip[2]); lChar('.'); lU32(net.ip[3]); lChar('/')
  result = IdlePollMs
  for s in slots.mitems:
    if s.conn == nil:
      s.conn = listener.accept()
      if s.conn != nil:
        reset(s.exchange[])
        s.closing = false
        s.deadlineMs = nowMs() + RequestMs
    if s.conn != nil:
      service(s)
      result = BusyPollMs

proc httpTask(): CpsVoidFuture {.cps.} =
  while true:
    var waitMs: uint64
    timed(slHttp): waitMs = httpPoll()
    await sleepMs(waitMs)

proc httpStart*() =
  for s in slots.mitems:
    s.exchange = createShared(Exchange)
  discard httpTask()
