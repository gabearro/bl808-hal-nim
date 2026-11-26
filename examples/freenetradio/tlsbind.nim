## `netio.SecureOps` over the repo's TLS module (`bl808/kernel/tls`,
## Mbed TLS 3.6): the only file of the radio that imports it.
## `stream_task.nim` uses this on the board, over the lwIP connection;
## `tests/t_stream_https.nim` uses the same code on the host, over a socket
## to a real server. No HAL imports here.
##
## The session sits directly on the `IoFn` pair the stream client hands to
## `open` (the `NetOps` connection). TLS reports the server's close_notify
## and a transport that stopped underneath it both as "closed";
## `tlsPeerClosed` tells them apart. As upstream, only close_notify is the
## end of the radio stream: a connection that is reset, or that ends (TCP
## FIN) without close_notify, is a lost connection to retry.

# By path, not `bl808/kernel/tls`: host tests build without the repo's
# config, so `src` is not on their module path.
import ../../src/bl808/kernel/tls
import ./netio

type
  TlsLink* = object
    ## One TLS client session. The stream client is given this object's
    ## address, so it must stay put (keep it in a heap object or a module
    ## variable).
    session: TlsSession

template at(ctx: pointer): ptr TlsLink = cast[ptr TlsLink](ctx)

func secureStatus(s: TlsStatus): SecureStatus =
  case s
  of tlsOk: ssOk
  of tlsWantRead: ssWantRead
  of tlsWantWrite: ssWantWrite
  of tlsClosed: ssClosed
  of tlsError: ssError

proc opOpen(ctx: pointer; ioCtx: pointer; send, recv: IoFn;
            hostname: openArray[char]): bool {.nimcall.} =
  var name = newString(hostname.len)
  for i in 0 ..< hostname.len: name[i] = hostname[i]
  # No certificate check, as upstream: there are no root certificates on
  # board and a radio stream isn't secret.
  tlsOpen(at(ctx).session, TlsIo(ctx: ioCtx, send: send, recv: recv), name)

proc opHandshake(ctx: pointer): SecureStatus {.nimcall.} =
  secureStatus(tlsHandshakeStep(at(ctx).session))

proc opRead(ctx: pointer; buf: ptr UncheckedArray[byte]; cap: int;
            got: var int): SecureStatus {.nimcall.} =
  result = secureStatus(tlsRead(at(ctx).session, buf, cap, got))
  if result == ssClosed and not tlsPeerClosed(at(ctx).session):
    result = ssError      # no close_notify came: lost, not finished

proc opWrite(ctx: pointer; buf: ptr UncheckedArray[byte]; len: int;
             put: var int): SecureStatus {.nimcall.} =
  secureStatus(tlsWrite(at(ctx).session, buf, len, put))

proc opClose(ctx: pointer) {.nimcall.} =
  tlsClose(at(ctx).session)

proc opLastError(ctx: pointer): int32 {.nimcall.} =
  tlsLastError(at(ctx).session)

proc opBuffered(ctx: pointer; decoded, pending: var int) {.nimcall.} =
  (decoded, pending) = tlsBuffered(at(ctx).session)

proc opErrorClass(ctx: pointer): SecureError {.nimcall.} =
  case tlsErrorClass(at(ctx).session)
  of tlsErrNone: seNone
  of tlsErrRefused: seRefused
  of tlsErrHandshake: seHandshake
  of tlsErrRecordTooBig: seRecordTooBig
  of tlsErrIo: seIo
  of tlsErrOther: seOther

proc secureOps*(link: ptr TlsLink): SecureOps =
  ## The stream client's TLS operations, running on `link`.
  SecureOps(ctx: link, available: true, open: opOpen,
    handshakeStep: opHandshake, read: opRead, write: opWrite,
    close: opClose, lastError: opLastError, buffered: opBuffered,
    errorClass: opErrorClass)

proc version*(link: TlsLink): cstring =
  ## "TLSv1.3" or "TLSv1.2" while a session is open, otherwise "".
  tlsVersion(link.session)

proc cipherSuite*(link: TlsLink): cstring =
  ## The negotiated suite's IANA name while a session is open, otherwise "".
  tlsCipherSuite(link.session)
