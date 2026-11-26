## lwIP raw-API TCP as polled, non-blocking byte streams: the stream
## client's connection and the web server's listener and connections.
## Firmware only.
##
## Everything runs in task context (lwIP is NO_SYS and is polled from the
## scheduler), so no locking. Received data is copied into the connection's
## own buffer at once, and the TCP receive window is that buffer's free
## space, which is what back-pressures a sender when the reader stops.
##
## The buffer is as long as lwIP's window (`TCP_WND`), and `tcpRecved` hands
## back what the reader takes out, so the two stay in step. Throughput is at
## most window / round-trip time, and upstream gives the stream its whole
## 10 KB buffer as the window for that reason (radio.rs, `NET_LEN`: 4 KB
## carried 128 kbit/s at only about 10 KB/s). The repo's Wi-Fi lwIP profile
## defaults to two segments; `freenetradio.nims` builds the radio with
## `TCP_WND` = 10240.

import bl808/kernel/lwipcore
import ./netio

type
  TcpConn* = ref object
    pcb: ptr TcpPcb
    state: ConnState
    rx: seq[byte]             ## ring
    rxHead, rxCount: int
    peerClosed: bool          ## FIN received
    failed: bool              ## reset, aborted or timed out
    held: bool                ## lwIP's callbacks hold a reference
    listener: TcpListener     ## for accepted connections, until closed

  TcpListener* = ref object
    pcb: ptr TcpPcb
    maxConns: int
    active: int               ## accepted (waiting or handed out) and not yet closed
    waiting: seq[TcpConn]

proc hold(c: TcpConn) =
  ## Keep `c` alive while lwIP has its address as the callback argument.
  if not c.held:
    c.held = true
    GC_ref(c)

proc release(c: TcpConn) =
  if c.held:
    c.held = false
    GC_unref(c)

proc onRecv(arg: pointer; pcb: ptr TcpPcb; p: ptr Pbuf; err: ErrT): ErrT {.cdecl.} =
  let c = cast[TcpConn](arg)
  if p == nil:
    c.peerClosed = true
    return ErrOk
  let n = pbufTotLen(p).int
  let cap = c.rx.len
  if n > cap - c.rxCount:
    # No room (the window should have prevented it): lwIP keeps the segment
    # and offers it again later.
    return ErrMem
  let tail = (c.rxHead + c.rxCount) mod cap
  let first = min(n, cap - tail)
  discard pbufCopyPartial(p, addr c.rx[tail], first.uint16, 0)
  if n > first:
    discard pbufCopyPartial(p, addr c.rx[0], (n - first).uint16, first.uint16)
  c.rxCount += n
  discard pbufFree(p)
  ErrOk

proc onErr(arg: pointer; err: ErrT) {.cdecl.} =
  # lwIP has already freed the pcb.
  let c = cast[TcpConn](arg)
  c.pcb = nil
  c.failed = true
  c.state = csFailed
  c.release()

proc onConnected(arg: pointer; pcb: ptr TcpPcb; err: ErrT): ErrT {.cdecl.} =
  let c = cast[TcpConn](arg)
  c.state = csConnected
  ErrOk

proc attach(c: TcpConn; pcb: ptr TcpPcb) =
  c.pcb = pcb
  c.hold()
  tcpArg(pcb, cast[pointer](c))
  tcpRecv(pcb, onRecv)
  tcpErr(pcb, onErr)

proc detach(c: TcpConn): ptr TcpPcb =
  ## Take the pcb back from the connection, with no callbacks left on it.
  result = c.pcb
  c.pcb = nil
  if result != nil:
    tcpArg(result, nil)
    tcpRecv(result, nil)
    tcpErr(result, nil)
  c.release()

proc finished(c: TcpConn) =
  ## Common end of `close` and `abort`.
  c.state = csIdle
  c.rxHead = 0
  c.rxCount = 0
  if c.listener != nil:
    dec c.listener.active
    c.listener = nil

proc newTcpConn*(): TcpConn =
  ## An unconnected connection. Its receive buffer is lwIP's window, so what
  ## lwIP accepts always fits.
  TcpConn(rx: newSeq[byte](TcpWnd.int))

proc abort*(c: TcpConn) =
  ## Drop the connection at once (RST).
  let pcb = c.detach()
  if pcb != nil: tcpAbort(pcb)
  c.finished()

proc close*(c: TcpConn) =
  ## Send what is queued, then FIN; the connection is finished with.
  let unread = c.rxCount
  let pcb = c.detach()
  if pcb != nil:
    # lwIP takes a window short of `TCP_WND` to mean unread data and answers
    # the close with a reset, which could also cut off what was just sent:
    # hand back what was never read first.
    if unread > 0: tcpRecved(pcb, unread.uint16)
    if tcpClose(pcb) != ErrOk: tcpAbort(pcb)
  c.finished()

proc connect*(c: TcpConn; ip: uint32; port: uint16) =
  ## Start connecting (`ip` in network byte order); watch `state`.
  c.abort()
  c.peerClosed = false
  c.failed = false
  let pcb = tcpNew()
  if pcb == nil:
    c.state = csFailed
    return
  c.attach(pcb)
  var address = IpAddr(address: ip)
  if tcpConnect(pcb, addr address, port, onConnected) == ErrOk:
    c.state = csPending
  else:
    c.abort()
    c.state = csFailed

proc state*(c: TcpConn): ConnState = c.state

proc send*(c: TcpConn; data: ptr UncheckedArray[byte]; len: int): int =
  ## Queue up to `len` bytes: the count taken, 0 if the send buffer is
  ## full, or `IoClosed` / `IoError`.
  if c.pcb == nil or c.state != csConnected: return IoError
  let n = min(min(len, tcpSndbuf(c.pcb).int), 0xFFFF)
  if n <= 0: return 0
  let err = tcpWrite(c.pcb, data, n.uint16, TcpWriteFlagCopy)
  if err == ErrMem: return 0      # segment queue full: later
  if err != ErrOk: return IoError
  discard tcpOutput(c.pcb)
  n

proc recv*(c: TcpConn; buf: ptr UncheckedArray[byte]; cap: int): int =
  ## Read up to `cap` bytes: the count, 0 if nothing has arrived, `IoClosed`
  ## once the peer has closed and everything was read, or `IoError`.
  if c.rxCount > 0:
    let n = min(cap, c.rxCount)
    let first = min(n, c.rx.len - c.rxHead)
    if first > 0: copyMem(buf, addr c.rx[c.rxHead], first)
    if n > first: copyMem(addr buf[first], addr c.rx[0], n - first)
    c.rxHead = (c.rxHead + n) mod c.rx.len
    c.rxCount -= n
    if c.pcb != nil: tcpRecved(c.pcb, n.uint16)   # reopen the window by that much
    return n
  if c.failed: IoError
  elif c.peerClosed: IoClosed
  elif c.state != csConnected: IoError
  else: 0

proc rxQueued*(c: TcpConn): int = c.rxCount
  ## Received, not yet read.

proc txQueued*(c: TcpConn): int =
  ## Sent, not yet acknowledged.
  if c.pcb == nil: 0 else: TcpSndBuf.int - tcpSndbuf(c.pcb).int

proc ioSend*(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  ## `send` as a `netio.IoFn`; `ctx` is the `TcpConn`.
  cast[TcpConn](ctx).send(data, len)

proc ioRecv*(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  cast[TcpConn](ctx).recv(data, len)

proc onAccept(arg: pointer; newPcb: ptr TcpPcb; err: ErrT): ErrT {.cdecl.} =
  let l = cast[TcpListener](arg)
  if err != ErrOk or newPcb == nil: return ErrOk
  if l.active >= l.maxConns:
    tcpAbort(newPcb)              # refuse (RST) rather than queue
    return ErrAbrt
  let c = newTcpConn()
  c.state = csConnected
  c.listener = l
  c.attach(newPcb)
  inc l.active
  l.waiting.add c
  ErrOk

proc listen*(port: uint16; maxConns: int): TcpListener =
  ## Listen on `port`. While `maxConns` accepted connections are open,
  ## further ones are refused (RST) rather than queued. nil on failure.
  let pcb = tcpNew()
  if pcb == nil: return nil
  var any = ipAddrAny()
  if tcpBind(pcb, addr any, port) != ErrOk:
    tcpAbort(pcb)
    return nil
  let listening = tcpListen(pcb)  # frees `pcb` and returns a smaller one
  if listening == nil:
    tcpAbort(pcb)
    return nil
  result = TcpListener(pcb: listening, maxConns: maxConns)
  GC_ref(result)                  # the listener lives as long as lwIP has it
  tcpArg(listening, cast[pointer](result))
  tcpAccept(listening, onAccept)

proc accept*(l: TcpListener): TcpConn =
  ## The next connection that has arrived, or nil.
  if l.waiting.len == 0: return nil
  result = l.waiting[0]
  l.waiting.delete(0)
