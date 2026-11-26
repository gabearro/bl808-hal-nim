## Host exerciser for src/bl808/kernel/tls.nim: one HTTPS GET over a
## non-blocking TCP socket wrapped in a `TlsIo`. Driven by
## tools/test_tls_handshake.py against a local `openssl s_server`.
##
##   tls_host_client <port> <server-name> <path> <output-file> [options]
##     --verify=<ca.der>   verify the server against this anchor
##     --clock=<seconds>   the date for certificate validity, as Unix time
##                         (0: unknown); default: this machine's clock
##     --trickle=<n>       the transport moves at most n bytes per call and
##                         reports "would block" on every other call
##     --pad=<n>           add n bytes of request headers (several records)
##     --upload            stop after sending the request (the server logs it)
##     --repeat=<n>        fetch n times in one process (allocation balance)
##
## Prints one line: `ok version=... suite=... bytes=... blocked=... heap=...
## open=... idle=... stack=...`, or `fail stage=... error=... class=...`.
## `heap` is the peak of live Mbed TLS allocations (through `tlsSetAllocator`),
## `open` what an established session holds, `idle` what stays allocated
## between sessions (the shared random generator and trust anchors), `stack`
## the deepest stack use of a session; all host figures, indicative for the
## target.

import std/[nativesockets, net, parseopt, posix, strutils, volatile]
import bl808/kernel/tls

type Transport = object
  fd: SocketHandle
  trickle: int
  stall: bool        # the next call reports "would block"
  blocked: int       # simulated and real "would block" results
  realBlock: bool    # the kernel had nothing: wait for the socket

# ---- memory accounting -------------------------------------------------------
var heapLive, heapPeak: int

proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(memory: pointer) {.importc: "free", header: "<stdlib.h>".}

proc countingCalloc(count, size: csize_t): pointer {.cdecl.} =
  ## A size header in front of each block keeps the books.
  let bytes = count * size
  let base = cast[ptr csize_t](c_malloc(bytes + 16))
  if base == nil: return nil
  base[] = bytes
  heapLive += bytes.int
  heapPeak = max(heapPeak, heapLive)
  result = cast[pointer](cast[uint](base) + 16)
  zeroMem(result, bytes)

proc countingFree(memory: pointer) {.cdecl.} =
  if memory == nil: return
  let base = cast[ptr csize_t](cast[uint](memory) - 16)
  heapLive -= base[].int
  c_free(base)

const StackWindow = 256 * 1024

proc paintStack(top: uint) =
  ## Mark the unused stack below `top` (the address of a caller's local).
  for depth in 512 ..< StackWindow:
    volatileStore(cast[ptr byte](top - depth.uint), 0xA5'u8)

proc stackDepth(top: uint): int =
  ## How far below `top` the marks were overwritten since `paintStack`.
  result = StackWindow - 1
  while result >= 512 and volatileLoad(cast[ptr byte](top - result.uint)) == 0xA5'u8:
    dec result

proc throttled(t: var Transport; len: var int): bool =
  if t.trickle <= 0: return false
  t.stall = not t.stall
  if t.stall:
    inc t.blocked
    return true
  len = min(len, t.trickle)

proc ioSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let t = cast[ptr Transport](ctx)
  var count = len
  if t[].throttled(count): return 0
  let moved = send(t.fd, data, count.cint, 0)
  if moved >= 0: return moved
  if errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR:
    inc t.blocked
    t.realBlock = true
    return 0
  -1

proc ioRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let t = cast[ptr Transport](ctx)
  var count = len
  if t[].throttled(count): return 0
  let moved = recv(t.fd, data, count.cint, 0)
  if moved > 0: return moved
  if moved == 0: return -1
  if errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR:
    inc t.blocked
    t.realBlock = true
    return 0
  -1

proc wait(t: var Transport; status: TlsStatus) =
  ## Only a real "would block" needs the kernel; a simulated one is retried.
  if not t.realBlock: return
  t.realBlock = false
  var fds = [TPollfd(fd: t.fd.cint, events: if status == tlsWantWrite: POLLOUT else: POLLIN)]
  if poll(addr fds[0], 1, 10_000) <= 0:
    quit("fail stage=timeout error=0 class=tlsErrIo", 2)

proc fail(stage: string; s: TlsSession) {.noreturn.} =
  echo "fail stage=", stage, " error=-0x", toHex(-tlsLastError(s), 4),
    " class=", tlsErrorClass(s)
  quit(1)

proc fetch(port: int; name, path, output: string; verify: bool; trickle, pad: int;
           uploadOnly: bool): string =
  ## Connect, shake hands, GET `path` into `output`, close. Returns the report.
  var transport = Transport(trickle: trickle)
  let socket = newSocket()
  socket.connect("127.0.0.1", Port(port))
  socket.getFd.setBlocking(false)
  transport.fd = socket.getFd

  var session: TlsSession
  let stackTop = cast[uint](addr session)
  paintStack(stackTop)
  if not tlsOpen(session, TlsIo(ctx: addr transport, send: ioSend, recv: ioRecv), name,
                 verifyPeer = verify):
    fail("open", session)
  while true:
    let status = tlsHandshakeStep(session)
    case status
    of tlsOk: break
    of tlsWantRead, tlsWantWrite: transport.wait(status)
    of tlsClosed, tlsError: fail("handshake", session)
  let established = heapLive

  var request = "GET " & path & " HTTP/1.0\r\nHost: " & name & "\r\n"
  var padding = pad
  var line = 0
  while padding > 0:
    # Text that differs from line to line, so a repeated or skipped record shows.
    let chunk = min(padding, 1000)
    request.add "X-Pad: "
    for column in 0 ..< chunk: request.add char(ord('a') + (line * 31 + column * 7) mod 26)
    request.add "\r\n"
    padding -= chunk
    inc line
  request.add "\r\n"
  var sent = 0
  while sent < request.len:
    var put: int
    let status = tlsWrite(session, cast[ptr UncheckedArray[byte]](addr request[sent]),
                          request.len - sent, put)
    sent += put
    case status
    of tlsOk: discard
    of tlsWantRead, tlsWantWrite: transport.wait(status)
    of tlsClosed, tlsError: fail("write", session)

  var body = newStringOfCap(1 shl 20)
  var buffer: array[4096, byte]
  while not uploadOnly:
    var got: int
    let status = tlsRead(session, cast[ptr UncheckedArray[byte]](addr buffer[0]),
                         buffer.len, got)
    case status
    of tlsOk:
      let start = body.len
      body.setLen(start + got)
      copyMem(addr body[start], addr buffer[0], got)
    of tlsWantRead, tlsWantWrite: transport.wait(status)
    of tlsClosed: break
    of tlsError: fail("read", session)

  let stackUsed = stackDepth(stackTop)
  writeFile(output, body)
  result = "ok version=" & $tlsVersion(session) & " suite=" & $tlsCipherSuite(session) &
    " bytes=" & $body.len & " blocked=" & $transport.blocked & " heap=" & $heapPeak
  tlsClose(session)
  socket.close()
  result.add " open=" & $established & " idle=" & $heapLive & " stack=" & $stackUsed

var fixedClock: BiggestInt = -1     # --clock; -1: this machine's clock

proc main() =
  var positional: seq[string]
  var caFile = ""
  var trickle, pad = 0
  var repeat = 1
  var uploadOnly = false
  for kind, key, value in getopt():
    case kind
    of cmdArgument: positional.add key
    of cmdLongOption:
      case key
      of "verify": caFile = value
      of "clock": fixedClock = parseBiggestInt(value)
      of "trickle": trickle = parseInt(value)
      of "pad": pad = parseInt(value)
      of "repeat": repeat = parseInt(value)
      of "upload": uploadOnly = true
      else: quit("unknown option " & key, 2)
    else: quit("unknown option " & key, 2)
  if positional.len != 4: quit("usage: tls_host_client <port> <name> <path> <out>", 2)

  doAssert tlsSetAllocator(countingCalloc, countingFree)
  if fixedClock >= 0:
    tlsSetClock(proc(): int64 {.nimcall.} = int64(fixedClock))
  if caFile.len > 0:
    let anchor = readFile(caFile)
    doAssert tlsAddTrustAnchor(cast[seq[byte]](anchor))
  var report = ""
  var idle = -1
  for round in 1 .. repeat:
    report = fetch(parseInt(positional[0]), positional[1], positional[2], positional[3],
                   caFile.len > 0, trickle, pad, uploadOnly)
    # Only the first session may add to what stays allocated.
    doAssert idle < 0 or heapLive == idle, "a TLS session leaked " & $(heapLive - idle) & " bytes"
    idle = heapLive
  echo report

main()
