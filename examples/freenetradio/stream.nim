## The stream client (the stream half of upstream `src/radio.rs`:
## `stream_task`, `wait_for_network`, `fetch`, `Conn`, `Icy` and the HTTP
## helpers).
##
## Upstream is three nested async functions raced against the command
## signal and the link. Here it is one explicit state machine, `step`, that
## never blocks: the firmware task calls it in a loop and sleeps or yields
## as the returned hint says, and host tests drive it with scripted
## `NetOps` / `SecureOps` and the fake clock. No HAL imports.
##
## Data flow: connection -> `buf` -> ICY splitter -> `pipe.stream`. When
## the pipe is full the client stops reading, which back-pressures the TCP
## connection.

import ./text, ./timebase, ./status, ./pipe, ./netstate, ./netio, ./diag

const
  UserAgent* = "BL808-FreeNetRadio/0.1"
  MaxHops* = 6                      ## redirects and playlists followed
  HeadCap* = 2048                   ## response headers, a playlist, or audio in transit
  MetaCap = 512                     ## one ICY metadata block
  MaxRetries* = 3'u32
    ## Reconnect attempts before giving up on a stream that won't start.
    ## A stream that was playing gets a fresh set each time it drops.
  MaxRetriesAfterOutage* = 10'u32
    ## Attempts after the network comes back (2 s apart), for any failure.
  ResponseTimeoutMs* = 5_000'u64
    ## How long to wait for the response headers. Some https servers
    ## occasionally accept the request and then send nothing at all.
  StallTimeoutMs* = 5_000'u64
    ## Reconnect if a stream that was flowing goes quiet this long.
  SocketTimeoutMs* = 15_000'u64
    ## Upstream's socket timeout: connecting, the TLS handshake, sending
    ## the request and reading a playlist give up after this long.
  RetryPauseMs = 1_000'u64
  RetryPauseAfterOutageMs = 2_000'u64

  LinkDown* = "The Wi-Fi link is down. Check that the access point is in range."
  GettingAddress* = "Getting a network address..."
  NetworkBack* = "Network back, reconnecting..."
  Reconnecting* = "Reconnecting..."
  StreamEnded* = "The stream ended"
  RecordTooBig* = "The server's TLS records are too big for this radio's memory; try http://"
  NoTls* = "This firmware was built without TLS; try http://"

type
  Msg* = Text[96]

  Url* = object
    tls*: bool
    host*: Text[256]
    port*: uint16
    path*: Text[256]

  StepHint* = enum
    shIdle    ## nothing to do until a command or the network: sleep a few ms
    shWait    ## waiting for the connection or for room in the pipe: sleep 1 ms
    shYield   ## made progress and there may be more: just let other tasks run

  Stage = enum
    sgIdle          ## waiting for a command
    sgStart         ## top of upstream's retry loop
    sgWaitLink      ## offline: no link
    sgWaitConfig    ## offline: no address yet
    sgPause         ## between reconnect attempts
    # --- upstream's `fetch` (the link is watched in these) ---
    sgHop           ## parse the URL, start the lookup
    sgResolve
    sgConnect
    sgHandshake
    sgRequest
    sgHead
    sgPlaylist
    sgFirstAudio    ## audio that arrived with the headers
    sgStreaming

  Outcome = enum
    ocNone, ocEnded, ocFailed

  IcyState = enum
    isAudio, isMetaLength, isMeta

  Icy = object
    ## Splits an ICY stream into audio (to the pipe) and metadata (titles).
    metaint: int
    untilMeta: int
    state: IcyState
    left: int
    meta: array[MetaCap, char]
    metaLen: int

  ReadResult = enum
    rrData, rrNone, rrClosed, rrError

  StreamClient* = object
    ## Allocate on the heap (about 4 KB) and fill in `net` and `secure`.
    net*: NetOps
    secure*: SecureOps
    stage: Stage
    playUrl: Text[256]        ## what the play command asked for
    url: Text[256]            ## the current hop
    target: Url
    hop: int
    retries: uint32           ## failed starts in a row
    afterOutage: bool         ## just back from a network outage
    netBusy: bool             ## a lookup, connect or connection is in progress
    tlsOpen: bool
    deadlineMs: uint64
    handshakeStartMs: uint64
    stallStartMs: uint64
    outcome: Outcome
    failMsg: Msg
    failRetry: bool
    req: Text[512]
    reqSent: int
    buf: array[HeadCap, char]
    len: int                  ## bytes of `buf` filled (headers, playlist)
    dataPos, dataEnd: int     ## audio in `buf` not yet through the ICY splitter
    icy: Icy

# -----------------------------------------------------------------------------
# Text helpers (the slices of Rust become index ranges into the buffer)
# -----------------------------------------------------------------------------

func isAsciiSpace(c: char): bool {.inline.} =
  c in {' ', '\t', '\n', '\x0C', '\r'}

func trimAscii*(s: openArray[char]): Slice[int] =
  ## The range of `s` without leading and trailing ASCII whitespace
  ## (empty: `b < a`).
  var a = 0
  var b = s.high
  while a <= b and isAsciiSpace(s[a]): inc a
  while b >= a and isAsciiSpace(s[b]): dec b
  a .. b

func lower(c: char): char {.inline.} =
  if c in {'A' .. 'Z'}: char(c.ord + 32) else: c

func eqIgnoreCase(a: openArray[char]; b: string): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if lower(a[i]) != lower(b[i]): return false
  true

func startsWith(s: openArray[char]; prefix: string): bool =
  if s.len < prefix.len: return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]: return false
  true

func find(s: openArray[char]; needle: string; start = 0): int =
  ## Index of the first `needle` at or after `start`, or -1.
  var i = start
  while i + needle.len <= s.len:
    var same = true
    for j in 0 ..< needle.len:
      if s[i + j] != needle[j]:
        same = false
        break
    if same: return i
    inc i
  -1

func containsIgnoreCase*(s: openArray[char]; needle: string): bool =
  var i = 0
  while i + needle.len <= s.len:
    if eqIgnoreCase(s.toOpenArray(i, i + needle.len - 1), needle): return true
    inc i
  false

func parseNumber(s: openArray[char]; max: uint64; value: var uint64): bool =
  ## Rust's `str::parse` for an unsigned integer: an optional '+', then
  ## decimal digits only, within range.
  var i = 0
  if s.len > 0 and s[0] == '+': i = 1
  if i >= s.len: return false
  var v = 0'u64
  while i < s.len:
    if s[i] notin {'0' .. '9'}: return false
    v = v * 10 + uint64(s[i].ord - '0'.ord)
    if v > max: return false
    inc i
  value = v
  true

func validUtf8*(s: openArray[char]): bool =
  ## Strict UTF-8, as Rust's `core::str::from_utf8` accepts it.
  var i = 0
  while i < s.len:
    let b = s[i].ord
    var extra = 0
    var minimum = 0
    var cp = 0
    if b < 0x80:
      inc i
      continue
    elif b in 0xC2 .. 0xDF: (extra, minimum, cp) = (1, 0x80, b and 0x1F)
    elif b in 0xE0 .. 0xEF: (extra, minimum, cp) = (2, 0x800, b and 0x0F)
    elif b in 0xF0 .. 0xF4: (extra, minimum, cp) = (3, 0x10000, b and 0x07)
    else: return false
    if i + extra >= s.len: return false
    for k in 1 .. extra:
      let cb = s[i + k].ord
      if (cb and 0xC0) != 0x80: return false
      cp = (cp shl 6) or (cb and 0x3F)
    if cp < minimum or cp > 0x10FFFF or cp in 0xD800 .. 0xDFFF: return false
    i += extra + 1
  true

# -----------------------------------------------------------------------------
# URL and HTTP helpers
# -----------------------------------------------------------------------------

proc parseUrl*(url: openArray[char]; u: var Url): string =
  ## Fills `u`; returns "" or what is wrong with the URL.
  if url.len == 0:
    return "Enter a stream URL"
  var start: int
  if startsWith(url, "http://"):
    u.tls = false
    start = 7
  elif startsWith(url, "https://"):
    u.tls = true
    start = 8
  else:
    return "The URL must start with http:// or https://"
  var slash = start
  while slash < url.len and url[slash] != '/': inc slash
  # `start ..< slash` is the authority; the path is the rest, or "/".
  var colon = slash - 1
  while colon >= start and url[colon] != ':': dec colon
  var hostEnd = slash
  if colon >= start:
    var port: uint64
    if not parseNumber(url.toOpenArray(colon + 1, slash - 1), 65535, port):
      return "Bad port number in the URL"
    u.port = port.uint16
    hostEnd = colon
  else:
    u.port = if u.tls: 443 else: 80
  if hostEnd == start:
    return "The URL has no host name"
  u.host.set url.toOpenArray(start, hostEnd - 1)
  if slash < url.len: u.path.set url.toOpenArray(slash, url.high)
  else: u.path.set "/"
  ""

func statusCode*(head: openArray[char]): int =
  ## HTTP status code from the status line ("HTTP/1.x 200 OK" or
  ## "ICY 200 OK"), or -1.
  var lineEnd = 0
  while lineEnd < head.len and head[lineEnd] != '\r': inc lineEnd
  var first = 0
  while first < lineEnd and head[first] != ' ': inc first
  if first >= lineEnd: return -1
  var last = first + 1
  while last < lineEnd and head[last] != ' ': inc last
  var code: uint64
  if parseNumber(head.toOpenArray(first + 1, last - 1), 65535, code): code.int
  else: -1

func header*(head: openArray[char]; name: string; value: var Slice[int]): bool =
  ## The value of the first header called `name` (case-insensitive),
  ## trimmed, as a range of `head`.
  var lineStart = 0
  var statusLine = true
  while lineStart <= head.len:
    var lineEnd = lineStart
    while lineEnd < head.len and head[lineEnd] != '\n': inc lineEnd
    if not statusLine:
      var last = lineEnd
      if last > lineStart and head[last - 1] == '\r': dec last
      var colon = lineStart
      while colon < last and head[colon] != ':': inc colon
      if colon < last and eqIgnoreCase(head.toOpenArray(lineStart, colon - 1), name):
        let t = trimAscii(head.toOpenArray(colon + 1, last - 1))
        value = (colon + 1 + t.a) .. (colon + 1 + t.b)
        return true
    statusLine = false
    lineStart = lineEnd + 1
  false

proc absoluteUrl*(current: Url; location: openArray[char]): Text[256] =
  ## Resolve a Location header against the current URL.
  let empty = not validUtf8(location)
  template loc: untyped =
    location.toOpenArray(0, (if empty: -1 else: location.high))
  if not empty and (startsWith(location, "http://") or startsWith(location, "https://")):
    result.add loc
  else:
    result.add(if current.tls: "https" else: "http")
    result.add "://"
    result.add current.host.chars
    result.add ':'
    result.addInt current.port
    if empty or location.len == 0 or location[0] != '/':
      result.add '/'
    result.add loc

proc firstUrlInPlaylist*(body: openArray[char]; url: var Text[256]): bool =
  ## First stream URL in an .m3u or .pls playlist.
  var lineStart = 0
  while lineStart <= body.len:
    var lineEnd = lineStart
    while lineEnd < body.len and body[lineEnd] != '\n': inc lineEnd
    if not validUtf8(body.toOpenArray(lineStart, lineEnd - 1)):
      return false
    var a = lineStart
    var b = lineEnd - 1
    while a <= b and body[a] in {' ', '\t' .. '\r'}: inc a
    while b >= a and body[b] in {' ', '\t' .. '\r'}: dec b
    # .pls lines look like "File1=http://..."
    var eq = a
    while eq <= b and body[eq] != '=': inc eq
    if eq <= b and startsWith(body.toOpenArray(a, eq - 1), "File"):
      a = eq + 1
    if startsWith(body.toOpenArray(a, b), "http://") or
        startsWith(body.toOpenArray(a, b), "https://"):
      url.set body.toOpenArray(a, b)
      return true
    lineStart = lineEnd + 1
  false

func streamTitle*(meta: openArray[char]; title: var Slice[int]): bool =
  ## `StreamTitle='...';` from an ICY metadata block, as a range of `meta`.
  const Key = "StreamTitle='"
  let at = find(meta, Key)
  if at < 0: return false
  let start = at + Key.len
  var stop = find(meta, "';", start)
  if stop < 0:
    stop = meta.len
    for i in countdown(meta.high, start):
      if meta[i] == '\'':
        stop = i
        break
  let t = trimAscii(meta.toOpenArray(start, stop - 1))
  title = (start + t.a) .. (start + t.b)
  true

func tlsMessage*(e: SecureError): string =
  ## Explain a failed TLS handshake.
  case e
  of seRefused: "The server refused the secure connection (it may not offer TLS 1.3)"
  of seRecordTooBig: RecordTooBig
  of seIo: "Connection lost while setting up TLS"
  of seHandshake: "The server's TLS settings aren't supported (needs AES-128-GCM and P-256)"
  of seNone, seOther: "The secure (TLS) connection failed"

# -----------------------------------------------------------------------------
# The connection: plain TCP, or TLS over it
# -----------------------------------------------------------------------------

template bytesAt(c: StreamClient; i: int): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](addr c.buf[i])

proc reqAt(s: openArray[char]; i: int): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](unsafeAddr s[i])

proc dropConn(c: var StreamClient) =
  if c.tlsOpen:
    c.secure.close(c.secure.ctx)
    c.tlsOpen = false
  if c.netBusy:
    c.net.close(c.net.ctx)
    c.netBusy = false

proc connRead(c: var StreamClient; at, cap: int; got: var int): ReadResult =
  ## Read some bytes into `buf[at ..< at + cap]`.
  got = 0
  if not c.tlsOpen:
    let n = c.net.recv(c.net.ctx, c.bytesAt(at), cap)
    if n > 0:
      got = n
      return rrData
    return (if n == 0: rrNone elif n == IoClosed: rrClosed else: rrError)
  let t0 = nowUs()
  let st = c.secure.read(c.secure.ctx, c.bytesAt(at), cap, got)
  let took = nowUs() - t0
  if took > stats.tlsReadMaxUs.uint64:
    stats.tlsReadMaxUs = uint32(min(took, high(uint32).uint64))
  case st
  of ssOk: (if got > 0: rrData else: rrNone)
  of ssWantRead, ssWantWrite: rrNone
  of ssClosed, ssError:
    stats.tlsLastError = c.secure.lastError(c.secure.ctx)
    var decoded, pending = 0
    c.secure.buffered(c.secure.ctx, decoded, pending)
    stats.failInfo = [c.net.rxQueued(c.net.ctx).uint32,
                      c.net.txQueued(c.net.ctx).uint32, decoded.uint32, pending.uint32]
    if st == ssClosed: rrClosed else: rrError

proc connWrite(c: var StreamClient; data: ptr UncheckedArray[byte]; len: int): int =
  ## Bytes taken, 0 for "not now", negative when the connection is lost.
  if not c.tlsOpen:
    return c.net.send(c.net.ctx, data, len)
  var put = 0
  case c.secure.write(c.secure.ctx, data, len, put)
  of ssOk: put
  of ssWantRead, ssWantWrite: 0
  of ssClosed, ssError: IoError

# -----------------------------------------------------------------------------
# ICY
# -----------------------------------------------------------------------------

proc feed(c: var StreamClient): bool =
  ## Push `buf[dataPos ..< dataEnd]` through the ICY splitter. False when
  ## the pipe is full: call again later with the rest.
  while c.dataPos < c.dataEnd:
    case c.icy.state
    of isAudio:
      var n = c.dataEnd - c.dataPos
      if c.icy.metaint != 0: n = min(n, c.icy.untilMeta)
      let wrote = pipe.stream.write(c.bytesAt(c.dataPos).toOpenArray(0, n - 1))
      c.dataPos += wrote
      if c.icy.metaint != 0:
        c.icy.untilMeta -= wrote
        if c.icy.untilMeta == 0: c.icy.state = isMetaLength
      if wrote < n: return false
    of isMetaLength:
      let length = c.buf[c.dataPos].ord * 16
      inc c.dataPos
      c.icy.metaLen = 0
      if length == 0:
        c.icy.state = isAudio
        c.icy.untilMeta = c.icy.metaint
      else:
        c.icy.state = isMeta
        c.icy.left = length
    of isMeta:
      let n = min(c.icy.left, c.dataEnd - c.dataPos)
      let keep = min(n, MetaCap - c.icy.metaLen)
      for i in 0 ..< keep:
        c.icy.meta[c.icy.metaLen + i] = c.buf[c.dataPos + i]
      c.icy.metaLen += keep
      c.dataPos += n
      c.icy.left -= n
      if c.icy.left == 0:
        var title: Slice[int]
        if streamTitle(c.icy.meta.toOpenArray(0, c.icy.metaLen - 1), title):
          player.title.clear()
          player.title.addSanitized c.icy.meta.toOpenArray(title.a, title.b)
        c.icy.state = isAudio
        c.icy.untilMeta = c.icy.metaint
  true

# -----------------------------------------------------------------------------
# fetch: connect, follow redirects and playlists, then stream
# -----------------------------------------------------------------------------

proc fail(c: var StreamClient; message: string; retry = false) =
  c.outcome = ocFailed
  c.failMsg.set message
  c.failRetry = retry

proc nextHop(c: var StreamClient) =
  c.dropConn()
  inc c.hop
  c.stage = sgHop

proc startHop(c: var StreamClient) =
  if c.hop >= MaxHops:
    c.fail "Too many redirects"
    return
  let problem = parseUrl(c.url.chars, c.target)
  if problem.len > 0:
    c.fail problem
    return
  stats.connectStage = 1
  c.netBusy = true
  c.net.resolveStart(c.net.ctx, c.target.host.chars)
  c.stage = sgResolve

proc startRequest(c: var StreamClient) =
  c.req.clear()
  c.req.add "GET "
  c.req.add c.target.path.chars
  c.req.add " HTTP/1.0\r\nHost: "
  c.req.add c.target.host.chars
  c.req.add "\r\nUser-Agent: " & UserAgent &
    "\r\nAccept: */*\r\nIcy-MetaData: 1\r\nConnection: close\r\n\r\n"
  c.reqSent = 0
  c.deadlineMs = nowMs() + SocketTimeoutMs
  c.stage = sgRequest

proc processHead(c: var StreamClient; headLen: int) =
  stats.connectStage = 5
  template head: untyped = c.buf.toOpenArray(0, headLen - 1)
  let status = statusCode(head)
  if status < 0:
    c.fail "The server didn't send a valid HTTP response"
    return
  var ct = 0 .. -1
  discard header(head, "content-type", ct)
  template has(needle: string): bool =
    containsIgnoreCase(c.buf.toOpenArray(ct.a, ct.b), needle)

  if status in 300 .. 399:
    var location: Slice[int]
    if not header(head, "location", location):
      c.fail "Redirect without a Location header"
      return
    c.url = absoluteUrl(c.target, c.buf.toOpenArray(location.a, location.b))
    c.nextHop()
    return
  if status != 200:
    var m: Msg
    m.add "The server replied with HTTP status "
    m.addInt status
    c.fail $m
    return

  # A playlist (.m3u / .pls): play the first stream URL in it.
  if has("mpegurl") or has("scpls") or has("x-pls"):
    let body = c.len - headLen
    if body > 0:
      moveMem(addr c.buf[0], addr c.buf[headLen], body)
    c.len = body
    c.deadlineMs = nowMs() + SocketTimeoutMs
    c.stage = sgPlaylist
    return
  if has("aac") or has("mp4"):
    c.fail "AAC streams aren't supported, only MP3"
    return
  if has("ogg") or has("opus") or has("flac"):
    c.fail "Ogg/Opus/FLAC streams aren't supported, only MP3"
    return
  if has("text/html"):
    c.fail "That URL is a web page, not an audio stream"
    return

  var metaint = 0'u64
  var value: Slice[int]
  if header(head, "icy-metaint", value):
    if not validUtf8(c.buf.toOpenArray(value.a, value.b)) or
        not parseNumber(c.buf.toOpenArray(value.a, value.b), high(int32).uint64, metaint):
      metaint = 0
  if header(head, "icy-name", value):
    player.station.clear()
    player.station.addSanitized c.buf.toOpenArray(value.a, value.b)
  # After a reconnect the audio may still be playing from the buffer:
  # leave it be.
  if player.phase != phPlaying:
    player.phase = phBuffering
  player.message.clear()

  # Audio that arrived along with the headers.
  c.icy.metaint = metaint.int
  c.icy.untilMeta = metaint.int
  c.icy.state = isAudio
  c.icy.metaLen = 0
  c.dataPos = headLen
  c.dataEnd = c.len
  c.stage = sgFirstAudio

proc finishPlaylist(c: var StreamClient) =
  if firstUrlInPlaylist(c.buf.toOpenArray(0, c.len - 1), c.url):
    c.nextHop()
  else:
    c.fail "The playlist has no stream URL in it"

proc fetchStep(c: var StreamClient): StepHint =
  ## One non-blocking step of upstream's `fetch`. Sets `outcome` when the
  ## stream ended or failed.
  result = shWait
  let now = nowMs()
  var got = 0
  case c.stage
  of sgHop:
    c.startHop()
    result = shYield

  of sgResolve:
    var ip: uint32
    case c.net.resolvePoll(c.net.ctx, ip)
    of rsPending: discard
    of rsFailed: c.fail "Couldn't look up the server's address"
    of rsNoAddress: c.fail "The server's name has no address"
    of rsOk:
      stats.connectStage = 2
      c.net.connectStart(c.net.ctx, ip, c.target.port)
      c.deadlineMs = now + SocketTimeoutMs
      c.stage = sgConnect

  of sgConnect:
    case c.net.connectPoll(c.net.ctx)
    of csPending:
      if now >= c.deadlineMs: c.fail "Couldn't connect to the server"
    of csIdle, csFailed: c.fail "Couldn't connect to the server"
    of csConnected:
      if not c.target.tls:
        c.startRequest()
      else:
        # The certificate isn't verified: a radio stream isn't secret, and
        # this still gets through to https-only servers and is private on
        # the wire.
        stats.connectStage = 3
        if not c.secure.available:
          c.fail NoTls
        elif not c.secure.open(c.secure.ctx, c.net.ctx, c.net.send, c.net.recv,
                               c.target.host.chars):
          c.fail tlsMessage(seOther)
        else:
          c.tlsOpen = true
          c.handshakeStartMs = now
          c.deadlineMs = now + SocketTimeoutMs
          c.stage = sgHandshake
      result = shYield

  of sgHandshake:
    case c.secure.handshakeStep(c.secure.ctx)
    of ssOk:
      stats.tlsHandshakeMs = uint32(elapsedMs(c.handshakeStartMs, nowMs()))
      c.startRequest()
      result = shYield
    of ssWantRead, ssWantWrite:
      if now >= c.deadlineMs: c.fail tlsMessage(seIo)
    of ssClosed: c.fail tlsMessage(seIo)
    of ssError: c.fail tlsMessage(c.secure.errorClass(c.secure.ctx))

  of sgRequest:
    if c.reqSent == c.req.len:
      stats.connectStage = 4
      c.len = 0
      c.deadlineMs = now + ResponseTimeoutMs
      c.stage = sgHead
      return shYield
    let n = c.connWrite(reqAt(c.req.chars, c.reqSent), c.req.len - c.reqSent)
    if n > 0:
      c.reqSent += n
      c.deadlineMs = now + SocketTimeoutMs
      result = shYield
    elif n < 0 or now >= c.deadlineMs:
      c.fail "Connection lost while sending the request"

  of sgHead:
    if c.len == HeadCap:
      c.fail "The server's response headers are too long"
      return
    case c.connRead(c.len, HeadCap - c.len, got)
    of rrError: c.fail("Connection lost while reading the response", retry = true)
    of rrClosed: c.fail("The server closed the connection without replying", retry = true)
    of rrNone:
      if now >= c.deadlineMs: c.fail("The server didn't answer", retry = true)
    of rrData:
      # The terminator can only end inside what is new.
      let from0 = max(c.len - 3, 0)
      c.len += got
      let at = find(c.buf.toOpenArray(0, c.len - 1), "\r\n\r\n", from0)
      if at >= 0: c.processHead(at + 4)
      result = shYield

  of sgPlaylist:
    var done = c.len == HeadCap
    if not done:
      case c.connRead(c.len, HeadCap - c.len, got)
      of rrData:
        c.len += got
        c.deadlineMs = now + SocketTimeoutMs
        result = shYield
      of rrNone: done = now >= c.deadlineMs
      of rrClosed, rrError: done = true
    if done:
      c.finishPlaylist()
      result = shYield

  of sgFirstAudio:
    if c.feed():
      stats.connectStage = 6
      c.stallStartMs = now
      c.stage = sgStreaming
      result = shYield

  of sgStreaming:
    if c.dataPos < c.dataEnd:
      # The pipe was full: the rest of the last read goes first.
      if c.feed():
        c.stallStartMs = now
        result = shYield
      return
    case c.connRead(0, HeadCap, got)
    of rrData:
      stats.streamBytes += got.uint32
      c.dataPos = 0
      c.dataEnd = got
      if c.feed():
        c.stallStartMs = nowMs()
      # Decrypting a record takes a while: always let the other tasks run
      # after a read, even when more is queued.
      result = shYield
    of rrNone:
      if elapsedMs(c.stallStartMs, now) >= StallTimeoutMs:
        c.fail("The stream stalled", retry = true)
    of rrClosed: c.outcome = ocEnded
    of rrError: c.fail("Lost the connection to the stream", retry = true)

  of sgIdle, sgStart, sgWaitLink, sgWaitConfig, sgPause:
    discard

# -----------------------------------------------------------------------------
# stream_task: commands, the network coming and going, retries
# -----------------------------------------------------------------------------

proc startFetch(c: var StreamClient) =
  c.url = c.playUrl
  c.hop = 0
  c.outcome = ocNone
  c.stage = sgHop

proc onCommand(c: var StreamClient; command: Command) =
  c.dropConn()
  # Whatever happens next, the old stream's data is no longer wanted.
  pipe.stream.clear()
  beginGeneration()
  case command
  of cmdStop:
    setPhase(phStopped, "")
    c.stage = sgIdle
  of cmdPlay:
    setPhase(phConnecting, "")
    c.playUrl = player.url
    c.retries = 0
    c.afterOutage = false
    c.stage = sgStart
  of cmdNone: discard

proc finishFetch(c: var StreamClient) =
  ## The fetch ended or failed: reconnect, or say why not.
  let outcome = c.outcome
  c.outcome = ocNone
  c.dropConn()
  if outcome == ocEnded:
    setPhase(phStopped, StreamEnded)
  elif not net.linkUp:
    # The fetch failed because the link had gone: wait for it.
    inc stats.outages
    c.stage = sgStart
    return
  elif (c.failRetry or c.afterOutage) and
      c.retries < (if c.afterOutage: MaxRetriesAfterOutage else: MaxRetries):
    if stats.connectStage == 6:
      c.retries = 0
      c.afterOutage = false
    inc c.retries
    inc stats.reconnects
    # Keep playing what's buffered (the phase stays Playing) while
    # reconnecting.
    if player.phase notin {phPlaying, phBuffering}:
      player.phase = phConnecting
    player.message.set Reconnecting
    c.deadlineMs = nowMs() +
      (if c.afterOutage: RetryPauseAfterOutageMs else: RetryPauseMs)
    c.stage = sgPause
    return
  else:
    setPhase(phError, $c.failMsg)
  pipe.stream.clear()
  c.stage = sgIdle

proc step*(c: var StreamClient): StepHint =
  ## Advance the client as far as it can go without waiting.
  if commandPending():
    c.onCommand(takeCommand())
    return shYield
  case c.stage
  of sgIdle:
    result = shIdle
  of sgStart:
    if not net.linkUp or not net.hasIp:
      # No link, or no address yet: say so and wait.
      pipe.stream.clear()
      if not net.linkUp:
        setPhase(phOffline, LinkDown)
        c.stage = sgWaitLink
      else:
        setPhase(phOffline, GettingAddress)
        c.stage = sgWaitConfig
    else:
      c.startFetch()
    result = shYield
  of sgWaitLink:
    if not net.linkUp: return shIdle
    # Link up but no address yet (also the normal case at boot, for a
    # moment, before DHCP has answered).
    setPhase(phOffline, GettingAddress)
    c.stage = sgWaitConfig
    result = shYield
  of sgWaitConfig:
    if not net.hasIp: return shIdle
    setPhase(phConnecting, NetworkBack)
    # The access point, router or DHCP may need a moment, so also retry
    # the failures that are normally final (DNS, connect), and more times.
    c.retries = 0
    c.afterOutage = true
    c.startFetch()
    result = shYield
  of sgPause:
    if nowMs() < c.deadlineMs: return shIdle
    c.stage = sgStart
    result = shYield
  else:
    if not net.linkUp:
      # The link went down: drop the connection, then wait for it above.
      inc stats.outages
      c.outcome = ocNone
      c.dropConn()
      c.stage = sgStart
      return shYield
    result = c.fetchStep()
    if c.outcome != ocNone:
      c.finishFetch()
      result = shYield

proc streamInit*(c: var StreamClient; net: NetOps; secure: SecureOps) =
  ## `c` must be zeroed memory (it is never copied: it is too big for the
  ## stack).
  c.net = net
  c.secure = secure
  c.stage = sgIdle
