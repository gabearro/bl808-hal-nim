## The seam between the stream client's logic and the platform.
##
## `stream.nim` (pure, host-tested) drives a connection through these two
## tables of non-blocking operations; `stream_task.nim` fills them with the
## lwIP adapter and the repo's TLS module, and host tests fill them with
## scripted fakes. Every operation returns at once.

type
  IoFn* = proc(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.}
    ## Send or receive up to `len` bytes: the count moved, 0 for "would
    ## block", or a negative `IoClosed` / `IoError`. The same shape as the
    ## callbacks in `bl808/kernel/tls`'s `TlsIo`, so a TLS session can sit
    ## directly on a `NetOps` connection.

const
  IoClosed* = -1    ## the peer closed the connection cleanly
  IoError* = -2     ## reset, aborted or timed out

type
  ResolveState* = enum
    rsPending, rsOk, rsFailed, rsNoAddress

  ConnState* = enum
    csIdle, csPending, csConnected, csFailed

  NetOps* = object
    ## One TCP connection at a time, plus name lookup.
    ctx*: pointer
    resolveStart*: proc(ctx: pointer; host: openArray[char]) {.nimcall.}
    resolvePoll*: proc(ctx: pointer; ip: var uint32): ResolveState {.nimcall.}
      ## `ip` is in network byte order (lwIP's `ip4_addr_t.addr`).
    connectStart*: proc(ctx: pointer; ip: uint32; port: uint16) {.nimcall.}
    connectPoll*: proc(ctx: pointer): ConnState {.nimcall.}
    send*: IoFn
    recv*: IoFn
    close*: proc(ctx: pointer) {.nimcall.}
      ## Drop whatever is in progress (lookup, connect or connection).
    rxQueued*: proc(ctx: pointer): int {.nimcall.}   ## diagnostics
    txQueued*: proc(ctx: pointer): int {.nimcall.}   ## diagnostics

  SecureStatus* = enum
    ## Mirrors `TlsStatus`.
    ssOk, ssWantRead, ssWantWrite, ssClosed, ssError

  SecureError* = enum
    ## Mirrors `TlsErrorClass`; picks the user-visible TLS message.
    seNone
    seRefused        ## alert / handshake refused (e.g. no common version)
    seHandshake      ## unsupported parameters or another handshake failure
    seRecordTooBig
    seIo             ## the connection underneath was lost
    seOther

  SecureOps* = object
    ## One TLS client session over a `NetOps` connection.
    ctx*: pointer
    available*: bool
      ## False when the firmware was built without TLS (`-d:radioNoTls`).
    open*: proc(ctx: pointer; ioCtx: pointer; send, recv: IoFn;
                hostname: openArray[char]): bool {.nimcall.}
    handshakeStep*: proc(ctx: pointer): SecureStatus {.nimcall.}
    read*: proc(ctx: pointer; buf: ptr UncheckedArray[byte]; cap: int;
                got: var int): SecureStatus {.nimcall.}
    write*: proc(ctx: pointer; buf: ptr UncheckedArray[byte]; len: int;
                 put: var int): SecureStatus {.nimcall.}
    close*: proc(ctx: pointer) {.nimcall.}
    lastError*: proc(ctx: pointer): int32 {.nimcall.}
    buffered*: proc(ctx: pointer; decoded, pending: var int) {.nimcall.}
      ## Diagnostics after a failed read: plaintext not yet read, and bytes
      ## of the record being received.
    errorClass*: proc(ctx: pointer): SecureError {.nimcall.}
