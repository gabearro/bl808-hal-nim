## Host tests for the stream client (`stream.nim`) with scripted fakes of
## `netio.NetOps` and `netio.SecureOps`.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_stream.nim

import std/strutils
import ../text, ../timebase, ../status, ../pipe, ../netstate, ../netio, ../diag
import ../stream

# -----------------------------------------------------------------------------
# Fake network: one scripted connection per connectStart
# -----------------------------------------------------------------------------

type
  ConnScript = object
    refuse: bool            ## connect fails
    hang: bool              ## connect never completes
    chunks: seq[string]     ## what the server sends, one recv per chunk
    finish: int             ## after the chunks: 0 silence, IoClosed, IoError
    sendBlocked: bool       ## send returns 0
    sendFails: bool
    sendMax: int            ## bytes taken per send (0 = all)

  FakeNet = object
    scripts: seq[ConnScript]
    next: int
    cur: ConnScript
    chunkIdx, chunkPos: int
    connected: bool
    resolveResult: ResolveState
    resolveFor: seq[(string, ResolveState)]   ## per-host overrides
    pendingResolve: ResolveState
    hosts: seq[string]
    ports: seq[uint16]
    ips: seq[uint32]
    sent: seq[string]       ## per connection
    closes, recvCalls: int

  FakeTls = object
    ## Mirrors the `bl808/kernel/tls` contract over the `IoFn` pair it is
    ## opened with. "Encryption" is XOR 0x5A, so the tests can tell that
    ## the bytes really went through it.
    available, openFails: bool
    ioCtx: pointer
    send, recv: IoFn
    hostname: string
    wants: int              ## handshake steps that return want-read first
    handshakeResult: SecureStatus
    errClass: SecureError
    lastErr: int32
    opens, closes, reads: int
    isOpen: bool
    writeWants: int

var
  fnet: FakeNet
  ftls: FakeTls
  current: string         ## the running test, for failure messages

template test(name: string; body: untyped) =
  block:
    current = name
    body

proc enc(s: string): string =
  result = s
  for ch in result.mitems: ch = char(ch.ord xor 0x5A)

proc nResolveStart(ctx: pointer; host: openArray[char]) {.nimcall.} =
  var h = newString(host.len)
  for i in 0 ..< host.len: h[i] = host[i]
  fnet.hosts.add h
  fnet.pendingResolve = fnet.resolveResult
  for (name, res) in fnet.resolveFor:
    if name == h: fnet.pendingResolve = res

proc nResolvePoll(ctx: pointer; ip: var uint32): ResolveState {.nimcall.} =
  if fnet.pendingResolve == rsOk: ip = 0x0403_0201'u32
  fnet.pendingResolve

proc nConnectStart(ctx: pointer; ip: uint32; port: uint16) {.nimcall.} =
  doAssert fnet.next < fnet.scripts.len, "unexpected connection in: " & current
  fnet.cur = fnet.scripts[fnet.next]
  inc fnet.next
  fnet.chunkIdx = 0
  fnet.chunkPos = 0
  fnet.connected = true
  fnet.ips.add ip
  fnet.ports.add port
  fnet.sent.add ""

proc nConnectPoll(ctx: pointer): ConnState {.nimcall.} =
  if not fnet.connected: csIdle
  elif fnet.cur.refuse: csFailed
  elif fnet.cur.hang: csPending
  else: csConnected

proc nSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  if fnet.cur.sendFails: return IoError
  if fnet.cur.sendBlocked: return 0
  let n = if fnet.cur.sendMax > 0: min(len, fnet.cur.sendMax) else: len
  for i in 0 ..< n: fnet.sent[^1].add char(data[i])
  n

proc nRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  inc fnet.recvCalls
  if fnet.chunkIdx >= fnet.cur.chunks.len: return fnet.cur.finish
  let chunk = fnet.cur.chunks[fnet.chunkIdx]
  let n = min(len, chunk.len - fnet.chunkPos)
  for i in 0 ..< n: data[i] = byte(chunk[fnet.chunkPos + i])
  fnet.chunkPos += n
  if fnet.chunkPos == chunk.len:
    inc fnet.chunkIdx
    fnet.chunkPos = 0
  n

proc nClose(ctx: pointer) {.nimcall.} =
  inc fnet.closes
  fnet.connected = false

proc nRxQueued(ctx: pointer): int {.nimcall.} = 11
proc nTxQueued(ctx: pointer): int {.nimcall.} = 22

proc sOpen(ctx: pointer; ioCtx: pointer; send, recv: IoFn;
           hostname: openArray[char]): bool {.nimcall.} =
  inc ftls.opens
  if ftls.openFails: return false
  ftls.ioCtx = ioCtx
  ftls.send = send
  ftls.recv = recv
  ftls.hostname = newString(hostname.len)
  for i in 0 ..< hostname.len: ftls.hostname[i] = hostname[i]
  ftls.isOpen = true
  true

proc sHandshake(ctx: pointer): SecureStatus {.nimcall.} =
  if ftls.wants > 0:
    dec ftls.wants
    return ssWantRead
  ftls.handshakeResult

proc sRead(ctx: pointer; buf: ptr UncheckedArray[byte]; cap: int;
           got: var int): SecureStatus {.nimcall.} =
  inc ftls.reads
  advanceFakeTimeMs(2)            # a decrypt takes time
  got = 0
  let n = ftls.recv(ftls.ioCtx, buf, cap)
  if n > 0:
    for i in 0 ..< n: buf[i] = buf[i] xor 0x5A
    got = n
    ssOk
  elif n == 0: ssWantRead
  elif n == IoClosed:
    ftls.lastErr = -0x7280
    ssClosed
  else:
    ftls.lastErr = -0x0050
    ftls.errClass = seIo
    ssError

proc sWrite(ctx: pointer; buf: ptr UncheckedArray[byte]; len: int;
            put: var int): SecureStatus {.nimcall.} =
  put = 0
  if ftls.writeWants > 0:
    dec ftls.writeWants
    return ssWantWrite
  var tmp = newSeq[byte](len)
  for i in 0 ..< len: tmp[i] = buf[i] xor 0x5A
  let n = ftls.send(ftls.ioCtx, cast[ptr UncheckedArray[byte]](addr tmp[0]), len)
  if n > 0:
    put = n
    ssOk
  elif n == 0: ssWantWrite
  else: ssClosed

proc sClose(ctx: pointer) {.nimcall.} =
  inc ftls.closes
  ftls.isOpen = false

proc sBuffered(ctx: pointer; decoded, pending: var int) {.nimcall.} =
  decoded = 33
  pending = 44

proc sLastError(ctx: pointer): int32 {.nimcall.} = ftls.lastErr
proc sErrorClass(ctx: pointer): SecureError {.nimcall.} = ftls.errClass

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------

var
  client: ptr StreamClient
  audio: string           ## what the "decoder" took out of the pipe
  draining: bool

proc drain() =
  var tmp: array[512, byte]
  while true:
    let n = pipe.stream.read(tmp)
    if n == 0: break
    for i in 0 ..< n: audio.add char(tmp[i])

proc fresh(scripts: varargs[ConnScript]) =
  ## A new radio: network up, nothing playing.
  if client != nil: deallocShared(client)
  client = createShared(StreamClient)
  fnet = FakeNet(resolveResult: rsOk)
  for s in scripts: fnet.scripts.add s
  ftls = FakeTls(available: true, handshakeResult: ssOk)
  diagInit()
  statusInit()
  pipeInit()
  net = NetState(linkUp: true, hasIp: true)
  audio = ""
  draining = true
  streamInit(client[], NetOps(ctx: nil, resolveStart: nResolveStart,
      resolvePoll: nResolvePoll, connectStart: nConnectStart,
      connectPoll: nConnectPoll, send: nSend, recv: nRecv, close: nClose,
      rxQueued: nRxQueued, txQueued: nTxQueued),
    SecureOps(ctx: nil, available: true, open: sOpen, handshakeStep: sHandshake,
      read: sRead, write: sWrite, close: sClose, lastError: sLastError,
      buffered: sBuffered, errorClass: sErrorClass))

proc tick(): StepHint =
  ## One step of the task loop: yields cost no time, waits cost 1 ms.
  result = client[].step()
  if draining: drain()
  if result != shYield: advanceFakeTimeMs(1)

proc pump(ms: int) =
  let until = nowMs() + ms.uint64
  var spins = 0
  while nowMs() < until:
    if tick() == shYield:
      inc spins
      doAssert spins < 100_000, "the client never waits"
    else:
      spins = 0

template pumpUntil(cond: untyped; limitMs = 120_000) =
  block:
    let until = nowMs() + limitMs.uint64
    var spins = 0
    while not (cond):
      doAssert nowMs() < until, "timed out waiting for: " & astToStr(cond) & " in: " & current
      if tick() == shYield:
        inc spins
        doAssert spins < 100_000, "the client never waits"
      else:
        spins = 0

proc msg(): string = $player.message

proc playNow(url: string) =
  ## Send the play command and let the client take it.
  play(url)
  doAssert tick() == shYield

const
  Ok200 = "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n"
  Request = "GET /live HTTP/1.0\r\nHost: radio.example\r\n" &
    "User-Agent: BL808-FreeNetRadio/0.1\r\nAccept: */*\r\nIcy-MetaData: 1\r\n" &
    "Connection: close\r\n\r\n"

proc server(chunks: varargs[string]): ConnScript =
  result.finish = IoClosed
  for ch in chunks: result.chunks.add ch

proc quiet(chunks: varargs[string]): ConnScript =
  ## A server that goes silent after what it sent.
  for ch in chunks: result.chunks.add ch

proc expectError(url, body, message: string) =
  fresh(server(body))
  playNow(url)
  pumpUntil player.phase in {phError, phStopped}
  doAssert player.phase == phError and msg() == message,
    "got '" & msg() & "' for " & url

# -----------------------------------------------------------------------------
# The pure helpers
# -----------------------------------------------------------------------------

test "parseUrl":
  var u: Url
  doAssert parseUrl("http://example.com/a/b?c=d", u) == ""
  doAssert not u.tls and u.host == "example.com" and u.port == 80 and u.path == "/a/b?c=d"
  doAssert parseUrl("https://example.com", u) == ""
  doAssert u.tls and u.host == "example.com" and u.port == 443 and u.path == "/"
  doAssert parseUrl("http://h:8000/stream", u) == ""
  doAssert u.host == "h" and u.port == 8000 and u.path == "/stream"
  doAssert parseUrl("https://h:+8443", u) == "" and u.port == 8443   # Rust's parse takes '+'
  doAssert parseUrl("http://h/a:b", u) == "" and u.port == 80 and u.path == "/a:b"
  doAssert parseUrl("http://a:b:81/", u) == "" and u.host == "a:b" and u.port == 81
  doAssert parseUrl("", u) == "Enter a stream URL"
  doAssert parseUrl("ftp://x/", u) == "The URL must start with http:// or https://"
  doAssert parseUrl("HTTP://x/", u) == "The URL must start with http:// or https://"
  doAssert parseUrl("http://h:/", u) == "Bad port number in the URL"
  doAssert parseUrl("http://h:99999/", u) == "Bad port number in the URL"
  doAssert parseUrl("http://h:8x/", u) == "Bad port number in the URL"
  doAssert parseUrl("http://h:-1/", u) == "Bad port number in the URL"
  doAssert parseUrl("http:///path", u) == "The URL has no host name"
  doAssert parseUrl("http://:80/", u) == "The URL has no host name"
  doAssert parseUrl("http://", u) == "The URL has no host name"

test "statusCode":
  doAssert statusCode("HTTP/1.1 200 OK\r\nA: b\r\n\r\n") == 200
  doAssert statusCode("ICY 200 OK\r\n\r\n") == 200
  doAssert statusCode("HTTP/1.0 404\r\n\r\n") == 404
  doAssert statusCode("HTTP/1.0 302 Found") == 302
  doAssert statusCode("HTTP/1.1  200 OK\r\n") == -1      # empty second field
  doAssert statusCode("HTTP/1.1\r\n 200 OK\r\n") == -1
  doAssert statusCode("garbage\r\n\r\n") == -1
  doAssert statusCode("HTTP/1.1 2x0 OK\r\n") == -1
  doAssert statusCode("HTTP/1.1 70000 OK\r\n") == -1
  doAssert statusCode("") == -1

test "header":
  const Head = "HTTP/1.0 200 OK\r\nContent-Type:  audio/mpeg \r\nicy-name:Radio One\r\n" &
    "X-Empty:\r\nNoColon\r\nICY-MetaInt: 16000\nContent-Type: second\r\n\r\n"
  var v: Slice[int]
  doAssert header(Head, "content-type", v) and Head[v] == "audio/mpeg"
  doAssert header(Head, "ICY-NAME", v) and Head[v] == "Radio One"
  doAssert header(Head, "icy-metaint", v) and Head[v] == "16000"   # bare LF line
  doAssert header(Head, "x-empty", v) and v.len == 0
  doAssert not header(Head, "location", v)
  doAssert not header(Head, "nocolon", v)
  doAssert not header("Location: x\r\n\r\n", "location", v)   # the status line is skipped
  doAssert containsIgnoreCase("Audio/X-MPEGURL; charset=x", "mpegurl")
  doAssert not containsIgnoreCase("audio/mpeg", "mpegurl")
  doAssert not containsIgnoreCase("", "aac")

test "absoluteUrl":
  var u: Url
  doAssert parseUrl("https://host.example:8443/dir/file", u) == ""
  doAssert $absoluteUrl(u, "http://other/x") == "http://other/x"
  doAssert $absoluteUrl(u, "https://other/x") == "https://other/x"
  doAssert $absoluteUrl(u, "/new/path") == "https://host.example:8443/new/path"
  doAssert $absoluteUrl(u, "relative") == "https://host.example:8443/relative"
  doAssert $absoluteUrl(u, "") == "https://host.example:8443/"
  doAssert $absoluteUrl(u, "/bad\xFFutf8") == "https://host.example:8443/"
  doAssert parseUrl("http://plain/", u) == ""
  doAssert $absoluteUrl(u, "/x") == "http://plain:80/x"
  doAssert absoluteUrl(u, "http://h/" & repeat('a', 400)).len == 256

test "firstUrlInPlaylist":
  var t: Text[256]
  doAssert firstUrlInPlaylist("#EXTM3U\r\n#EXTINF:-1,Name\r\n  http://a/b  \r\nhttp://c/\r\n", t)
  doAssert t == "http://a/b"
  doAssert firstUrlInPlaylist("[playlist]\nNumberOfEntries=2\nFile1=https://x/1\nFile2=http://x/2\n", t)
  doAssert t == "https://x/1"
  doAssert firstUrlInPlaylist("Title1=http://not/this\nFile1= http://spaced/\nfile2=http://z/\nhttp://plain/?a=b", t)
  doAssert t == "http://plain/?a=b"      # "File1= http" has a space; "file2" is lower case
  doAssert firstUrlInPlaylist("File9=http://x/?a=b", t) and t == "http://x/?a=b"
  doAssert not firstUrlInPlaylist("", t)
  doAssert not firstUrlInPlaylist("#EXTM3U\nftp://x/\n", t)
  doAssert not firstUrlInPlaylist("bad \xFF line\nhttp://after/\n", t)   # not UTF-8: give up
  doAssert firstUrlInPlaylist("caf\xC3\xA9\nhttp://after/\n", t) and t == "http://after/"

test "streamTitle":
  var s: Slice[int]
  const A = "StreamTitle='Artist - Song';StreamUrl='http://x';\0\0\0"
  doAssert streamTitle(A, s) and A[s] == "Artist - Song"
  const B = "StreamTitle='It's here';"
  doAssert streamTitle(B, s) and B[s] == "It's here"
  const C = "StreamTitle='cut off'\0\0"          # no "';": up to the last quote
  doAssert streamTitle(C, s) and C[s] == "cut off"
  const D = "StreamTitle='no end at all"
  doAssert streamTitle(D, s) and D[s] == "no end at all"
  const E = "StreamTitle='  padded  ';"
  doAssert streamTitle(E, s) and E[s] == "padded"
  const F = "StreamTitle='';"
  doAssert streamTitle(F, s) and s.len == 0
  doAssert not streamTitle("StreamUrl='x';", s)
  doAssert not streamTitle("", s)

test "validUtf8 and trimAscii":
  doAssert validUtf8("") and validUtf8("plain") and validUtf8("\xC3\xA9\xE2\x82\xAC\xF0\x9F\x8E\xB5")
  doAssert not validUtf8("\xFF") and not validUtf8("\xC3") and not validUtf8("\x80")
  doAssert not validUtf8("\xC0\x80") and not validUtf8("\xED\xA0\x80") and not validUtf8("\xF4\x90\x80\x80")
  doAssert trimAscii(" \t a b \r\n") == 3 .. 5
  doAssert trimAscii("   ").len == 0 and trimAscii("").len == 0

test "tlsMessage":
  doAssert tlsMessage(seRefused) == "The server refused the secure connection (it may not offer TLS 1.3)"
  doAssert tlsMessage(seRecordTooBig) == "The server's TLS records are too big for this radio's memory; try http://"
  doAssert tlsMessage(seIo) == "Connection lost while setting up TLS"
  doAssert tlsMessage(seHandshake) == "The server's TLS settings aren't supported (needs AES-128-GCM and P-256)"
  doAssert tlsMessage(seOther) == "The secure (TLS) connection failed"
  doAssert tlsMessage(seNone) == "The secure (TLS) connection failed"

# -----------------------------------------------------------------------------
# Playing a stream
# -----------------------------------------------------------------------------

test "idle until told to play":
  fresh()
  doAssert client[].step() == shIdle and client[].step() == shIdle
  doAssert player.phase == phStopped and player.generation == 0 and fnet.hosts.len == 0

test "a plain http stream, start to end":
  fresh(server("HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nicy-name: Caf\xC3\xA9 Radio\t1 \r\n\r\nMP3",
               "DATA", "more"))
  player.station.set "old"
  player.title.set "old"
  player.sampleRate = 44100
  playNow("http://radio.example/live")
  doAssert player.phase == phConnecting and msg() == "" and player.generation == 1
  doAssert player.station.len == 0 and player.title.len == 0 and player.sampleRate == 0
  pumpUntil stats.connectStage == 6
  doAssert player.phase == phBuffering and msg() == ""
  doAssert player.station == "Caf? Radio 1"
  doAssert fnet.hosts == @["radio.example"] and fnet.ports == @[80'u16]
  doAssert fnet.ips == @[0x0403_0201'u32]
  doAssert fnet.sent[0] == Request
  pumpUntil player.phase == phStopped
  doAssert msg() == "The stream ended"
  doAssert audio == "MP3DATAmore"
  doAssert stats.streamBytes == 8            # what came with the headers isn't counted
  doAssert pipe.stream.len == 0 and fnet.closes == 1
  doAssert client[].step() == shIdle

test "the headers may arrive in pieces, and an ICY status line is fine":
  fresh(server("ICY 200 OK\r\nicy-na", "me:X\r\n\r", "\naudio"))
  playNow("http://radio.example:8000")
  pumpUntil player.phase == phStopped
  doAssert audio == "audio" and player.station == "X" and fnet.ports == @[8000'u16]
  doAssert fnet.sent[0].startsWith("GET / HTTP/1.0\r\nHost: radio.example\r\n")

test "the stage counter walks 1..6":
  fresh(quiet(Ok200))
  fnet.resolveResult = rsPending
  playNow("http://radio.example/live")
  pump(5)
  doAssert stats.connectStage == 1
  fnet.pendingResolve = rsOk
  fnet.scripts[0].hang = true
  pump(5)
  doAssert stats.connectStage == 2

test "a playing stream stays 'playing' through the header handling":
  fresh(server(Ok200 & "x"))
  playNow("http://radio.example/live")
  player.phase = phPlaying
  player.message.set "Reconnecting..."
  pumpUntil stats.connectStage == 6
  doAssert player.phase == phPlaying and msg() == ""

# -----------------------------------------------------------------------------
# ICY metadata
# -----------------------------------------------------------------------------

proc metaBlock(text: string): string =
  let blocks = (text.len + 15) div 16
  result = $char(blocks) & text & repeat('\0', blocks * 16 - text.len)

test "titles are cut out of the audio, whatever the read boundaries":
  let body = "AAAAAAAA" & metaBlock("StreamTitle='Na\xC3\xAFve - Song\x01';") &
             "BBBBBBBB" & metaBlock("") & "CCCCCCCC" &
             metaBlock("StreamUrl='x';") & "DDDDDDDD" &
             metaBlock("StreamTitle='Second';") & "EEEE"
  for size in [1, 2, 3, 7, 16, 64, 4096]:
    var chunks = @["HTTP/1.0 200 OK\r\nicy-metaint: 8\r\n\r\n"]
    var i = 0
    while i < body.len:
      chunks.add body[i ..< min(i + size, body.len)]
      i += size
    fresh(server(chunks))
    playNow("http://radio.example/live")
    pumpUntil audio.len >= 16
    if size <= 16: doAssert player.title == "Na?ve - Song "
    pumpUntil player.phase == phStopped
    doAssert audio == "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDDEEEE", "chunk size " & $size
    doAssert player.title == "Second"

test "metadata that arrives with the headers; a block longer than the buffer":
  let long = "StreamTitle='" & repeat('t', 600) & "';"
  fresh(server("HTTP/1.0 200 OK\r\nicy-metaint:4\r\n\r\nabcd" & metaBlock("StreamTitle='First';") & "ef",
               "gh" & metaBlock(long) & "ijkl" & metaBlock("StreamTitle='Last';")))
  playNow("http://radio.example/live")
  pumpUntil audio.len >= 6
  doAssert player.title == "First"
  pumpUntil player.phase == phStopped
  doAssert audio == "abcdefghijkl"
  doAssert player.title == "Last"

test "an over-long block is cut at 512 bytes and the title at 128":
  let long = "StreamTitle='" & repeat('t', 600) & "';"
  fresh(quiet("HTTP/1.0 200 OK\r\nicy-metaint:4\r\n\r\nabcd" & metaBlock(long) & "efgh"))
  playNow("http://radio.example/live")
  pumpUntil audio.len == 8
  doAssert player.title.len == 128 and player.title[127] == 't'

test "a bad icy-metaint means no metadata":
  for bad in ["abc", "-5", "", "99999999999", "2147483648", "8 bytes"]:
    fresh(server("HTTP/1.0 200 OK\r\nicy-metaint: " & bad & "\r\n\r\n\x01raw"))
    playNow("http://radio.example/live")
    pumpUntil player.phase == phStopped
    doAssert audio == "\x01raw"

# -----------------------------------------------------------------------------
# Back-pressure
# -----------------------------------------------------------------------------

test "a full pipe stops the reading, and that is not a stall":
  var chunks = @[Ok200]
  for i in 0 ..< 12: chunks.add repeat(char('a'.ord + i), 2048)
  fresh(quiet(chunks))
  draining = false
  playNow("http://radio.example/live")
  pumpUntil pipe.stream.free == 0
  pump(50)
  let calls = fnet.recvCalls
  pump(20_000)                                # far longer than the stall timeout
  doAssert fnet.recvCalls == calls, "kept reading with the pipe full"
  doAssert player.phase == phBuffering and stats.reconnects == 0
  draining = true
  pumpUntil audio.len == 12 * 2048
  for i in 0 ..< 12:
    doAssert audio[i * 2048] == char('a'.ord + i) and audio[i * 2048 + 2047] == char('a'.ord + i)
  # ... and the stall clock starts once the pipe took everything.
  let t0 = nowMs()
  pumpUntil stats.reconnects == 1
  doAssert nowMs() - t0 in 4_990'u64 .. 5_010'u64

test "audio that came with the headers waits for the pipe too":
  fresh(server(Ok200 & repeat('h', 1500)))
  draining = false
  var fill: array[PipeLen - 1000, byte]
  playNow("http://radio.example/live")
  doAssert pipe.stream.write(fill) == fill.len
  pump(300)
  doAssert stats.connectStage == 5 and pipe.stream.free == 0   # not "streaming" yet
  draining = true
  pumpUntil stats.connectStage == 6
  pumpUntil player.phase == phStopped
  doAssert audio.endsWith(repeat('h', 1500))

# -----------------------------------------------------------------------------
# Redirects and playlists
# -----------------------------------------------------------------------------

test "absolute and relative redirects":
  fresh(server("HTTP/1.1 302 Found\r\nLocation: http://second.example:8080/a\r\n\r\n"),
        server("HTTP/1.1 301 Moved\r\nlocation: /b?x=1\r\nContent-Type: text/html\r\n\r\n<html>"),
        server("HTTP/1.1 307 Temp\r\nLOCATION: c\r\n\r\n"),
        server(Ok200 & "ok"))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert audio == "ok" and msg() == "The stream ended"
  doAssert fnet.hosts == @["radio.example", "second.example", "second.example", "second.example"]
  doAssert fnet.ports == @[80'u16, 8080, 8080, 8080]
  doAssert fnet.sent[1].startsWith("GET /a HTTP/1.0\r\nHost: second.example\r\n")
  doAssert fnet.sent[2].startsWith("GET /b?x=1 HTTP/1.0\r\n")
  doAssert fnet.sent[3].startsWith("GET /c HTTP/1.0\r\n")
  doAssert fnet.closes == 4

test "a redirect from https keeps https":
  fresh(server(enc("HTTP/1.1 302 Found\r\nLocation: /x\r\n\r\n")), server(enc(Ok200 & "tls")))
  playNow("https://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert audio == "tls" and fnet.ports == @[443'u16, 443] and ftls.opens == 2 and ftls.closes == 2

test "six hops at most":
  var hops: seq[ConnScript]
  for i in 0 ..< 6: hops.add server("HTTP/1.1 302 Found\r\nLocation: /again\r\n\r\n")
  fresh(hops)
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Too many redirects" and fnet.next == 6

test "five redirects and then the stream is fine":
  var hops: seq[ConnScript]
  for i in 0 ..< 5: hops.add server("HTTP/1.1 302 Found\r\nLocation: /again\r\n\r\n")
  hops.add server(Ok200 & "sixth")
  fresh(hops)
  playNow("http://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert audio == "sixth"

test "redirect errors":
  expectError("http://radio.example/live", "HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n",
              "Redirect without a Location header")
  fresh(server("HTTP/1.1 302 Found\r\nLocation: ftp://x/\r\n\r\n"),
        server("HTTP/1.1 404 Not Found\r\n\r\n"))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert fnet.hosts == @["radio.example", "radio.example"]   # taken as a relative path
  doAssert fnet.sent[1].startsWith("GET /ftp://x/ HTTP/1.0\r\n")

test "an .m3u playlist, body partly with the headers":
  fresh(server("HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\n\r\n#EXTM3U\r\nhttp://stream.exam",
               "ple:8000/mp3\r\nhttp://other/\r\n"),
        server(Ok200 & "m3u"))
  playNow("http://radio.example/listen.m3u")
  pumpUntil player.phase == phStopped
  doAssert audio == "m3u" and fnet.hosts[1] == "stream.example" and fnet.ports[1] == 8000
  doAssert fnet.sent[1].startsWith("GET /mp3 HTTP/1.0\r\n")

test "a .pls playlist to an https stream, and each playlist content type":
  for ct in ["audio/x-scpls", "application/pls+xml; x-pls", "application/vnd.apple.mpegURL"]:
    fresh(server("HTTP/1.1 200 OK\r\nContent-Type: " & ct & "\r\n\r\n",
                 "[playlist]\nFile1=https://tls.example/s\nTitle1=x\n"),
          server(enc(Ok200 & "pls")))
    playNow("http://radio.example/listen.pls")
    pumpUntil player.phase == phStopped
    doAssert audio == "pls" and ftls.hostname == "tls.example", ct

test "a playlist whose server never closes is read until the socket timeout":
  fresh(quiet("HTTP/1.1 200 OK\r\nContent-Type: audio/x-scpls\r\n\r\nFile1=http://s.example/\n"),
        server(Ok200 & "late"))
  playNow("http://radio.example/listen.pls")
  let t0 = nowMs()
  pumpUntil player.phase == phStopped
  doAssert audio == "late" and nowMs() - t0 >= 15_000

test "a playlist bigger than the buffer: the first 2048 bytes are enough":
  fresh(quiet("HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\n\r\n",
              "http://first.example/\n" & repeat("#" & repeat('x', 62) & "\n", 40)),
        server(Ok200 & "big"))
  playNow("http://radio.example/big.m3u")
  pumpUntil player.phase == phStopped, 5_000
  doAssert audio == "big" and fnet.hosts[1] == "first.example"

test "playlist errors":
  expectError("http://radio.example/x.m3u",
              "HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\n\r\n#EXTM3U\r\n",
              "The playlist has no stream URL in it")
  fresh(server("HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\n\r\nhttp://half"))
  fnet.scripts[0].finish = IoError            # a lost connection ends the playlist too
  fnet.scripts.add server(Ok200 & "z")
  playNow("http://radio.example/x.m3u")
  pumpUntil player.phase == phStopped
  doAssert fnet.hosts[1] == "half"

# -----------------------------------------------------------------------------
# Errors that are final
# -----------------------------------------------------------------------------

test "refusals by content type, status and response shape":
  const U = "http://radio.example/live"
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\n\r\n", "AAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: audio/AACP\r\n\r\n", "AAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: video/mp4\r\n\r\n", "AAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: application/ogg\r\n\r\n", "Ogg/Opus/FLAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: audio/opus\r\n\r\n", "Ogg/Opus/FLAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: audio/flac\r\n\r\n", "Ogg/Opus/FLAC streams aren't supported, only MP3")
  expectError(U, "HTTP/1.0 200 OK\r\nContent-Type: Text/HTML; charset=utf-8\r\n\r\n<html>", "That URL is a web page, not an audio stream")
  expectError(U, "HTTP/1.0 404 Not Found\r\n\r\n", "The server replied with HTTP status 404")
  expectError(U, "HTTP/1.0 503 Busy\r\nContent-Type: audio/mpeg\r\n\r\n", "The server replied with HTTP status 503")
  expectError(U, "HTTP/1.0 204 No Content\r\n\r\n", "The server replied with HTTP status 204")
  expectError(U, "HTTP/1.0 100 Continue\r\n\r\n", "The server replied with HTTP status 100")
  expectError(U, "SSH-2.0-OpenSSH\r\n\r\n", "The server didn't send a valid HTTP response")
  expectError(U, "\r\n\r\n", "The server didn't send a valid HTTP response")
  doAssert stats.connectStage == 5 and stats.reconnects == 0 and pipe.stream.len == 0

test "headers that never end":
  fresh(quiet("HTTP/1.0 200 OK\r\n", "X: " & repeat('a', 3000)))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError, 1_000
  doAssert msg() == "The server's response headers are too long"

test "exactly 2048 bytes of headers still fit":
  let pad = 2048 - "HTTP/1.0 200 OK\r\nX: \r\n\r\n".len
  fresh(server("HTTP/1.0 200 OK\r\nX: " & repeat('a', pad) & "\r\n\r\n", "fits"))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert audio == "fits"

test "bad URLs":
  for (url, why) in [("", "Enter a stream URL"),
                     ("radio.example/live", "The URL must start with http:// or https://"),
                     ("http://radio.example:port/", "Bad port number in the URL"),
                     ("http:///live", "The URL has no host name")]:
    fresh()
    playNow(url)
    pumpUntil player.phase == phError
    doAssert msg() == why and fnet.hosts.len == 0 and stats.reconnects == 0

test "name lookup and connect failures are final (when not after an outage)":
  fresh()
  fnet.resolveResult = rsFailed
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Couldn't look up the server's address" and stats.connectStage == 1

  fresh()
  fnet.resolveResult = rsNoAddress
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "The server's name has no address" and fnet.closes == 1

  fresh(ConnScript(refuse: true))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Couldn't connect to the server" and stats.connectStage == 2

  fresh(ConnScript(hang: true))
  playNow("http://radio.example/live")
  let t0 = nowMs()
  pumpUntil player.phase == phError
  doAssert msg() == "Couldn't connect to the server"
  doAssert nowMs() - t0 in 15_000'u64 .. 15_010'u64 and fnet.closes == 1

test "the request can't be sent":
  fresh(ConnScript(sendFails: true))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while sending the request" and stats.connectStage == 2

  fresh(ConnScript(sendBlocked: true))
  playNow("http://radio.example/live")
  let t0 = nowMs()
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while sending the request" and nowMs() - t0 >= 15_000

test "a request taken a few bytes at a time arrives whole":
  var s = server(Ok200 & "slow")
  s.sendMax = 7
  fresh(s)
  playNow("http://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert fnet.sent[0] == Request and audio == "slow"

test "the longest URL (256 characters) still fits the request buffer":
  let path = "/" & repeat('p', 256 - "http://radio.example/".len)
  fresh(server(Ok200))
  playNow("http://radio.example" & path & "overflow")     # cut at 256 by the status
  pumpUntil player.phase == phStopped
  doAssert fnet.sent[0].startsWith("GET " & path & " HTTP/1.0\r\nHost: radio.example\r\n")
  doAssert fnet.sent[0].endsWith("Connection: close\r\n\r\n")

# -----------------------------------------------------------------------------
# Reconnecting
# -----------------------------------------------------------------------------

test "a server that accepts and says nothing: three more tries, 1 s apart":
  fresh(quiet(), quiet(), quiet(), quiet())
  playNow("http://radio.example/live")
  let t0 = nowMs()
  pump(100)
  doAssert stats.connectStage == 4 and fnet.sent[0] == Request
  pumpUntil stats.reconnects == 1
  doAssert nowMs() - t0 in 5_000'u64 .. 5_020'u64
  doAssert player.phase == phConnecting and msg() == "Reconnecting..."
  doAssert fnet.closes == 1 and fnet.next == 1
  pump(990)
  doAssert fnet.next == 1                     # still pausing
  pump(20)
  doAssert fnet.next == 2
  pumpUntil player.phase == phError
  doAssert msg() == "The server didn't answer"
  doAssert stats.reconnects == 3 and fnet.next == 4
  doAssert nowMs() - t0 in 23_000'u64 .. 23_100'u64     # 4 x 5 s + 3 x 1 s

test "the other retried failures while starting":
  fresh(server(), server(), server(), server())
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "The server closed the connection without replying" and stats.reconnects == 3

  var lost = quiet("HTTP/1.0 200")
  lost.finish = IoError
  fresh(lost, lost, lost, lost)
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while reading the response" and stats.reconnects == 3

test "a retry that works clears the message":
  fresh(server(), server(Ok200 & "second time"))
  playNow("http://radio.example/live")
  pumpUntil stats.reconnects == 1
  doAssert msg() == "Reconnecting..."
  pumpUntil stats.connectStage == 6
  doAssert player.phase == phBuffering and msg() == ""

test "a stream that stalls reconnects, with a fresh set of tries each time":
  var scripts: seq[ConnScript]
  for i in 0 ..< 6: scripts.add quiet(Ok200 & "audio" & $i)
  for i in 0 ..< 3: scripts.add quiet()
  fresh(scripts)
  playNow("http://radio.example/live")
  for i in 1 .. 6:
    pumpUntil stats.connectStage == 6 and audio.endsWith("audio" & $(i - 1))
    player.phase = phPlaying                  # the decoder got going
    let t0 = nowMs()
    pumpUntil stats.reconnects == i.uint32
    doAssert nowMs() - t0 in 4_990'u64 .. 5_010'u64
    # What is buffered keeps playing while reconnecting.
    doAssert player.phase == phPlaying and msg() == "Reconnecting..."
  # Now it doesn't come back. The reconnect after the stall was the first
  # of the fresh set of three, so two more follow it.
  pumpUntil player.phase == phError
  doAssert msg() == "The server didn't answer" and stats.reconnects == 8
  doAssert fnet.next == 9

test "buffered audio survives a reconnect, and is dropped on a final error":
  fresh(quiet(Ok200 & "keep me"), quiet(), quiet(), quiet())
  draining = false
  playNow("http://radio.example/live")
  pumpUntil stats.reconnects == 1
  doAssert pipe.stream.len == 7 and player.phase == phBuffering
  pumpUntil player.phase == phError
  doAssert pipe.stream.len == 0

test "a reset connection mid-stream":
  var lost = quiet(Ok200 & "abc")
  lost.finish = IoError
  fresh(lost, server(Ok200 & "def"))
  playNow("http://radio.example/live")
  pumpUntil stats.reconnects == 1
  doAssert msg() == "Reconnecting..."
  pumpUntil player.phase == phStopped
  doAssert audio == "abcdef"

test "a new command ends the pause between tries":
  fresh(server(), quiet(Ok200 & "other"))
  playNow("http://radio.example/live")
  pumpUntil stats.reconnects == 1
  playNow("http://other.example/x")
  pump(3)
  doAssert fnet.hosts == @["radio.example", "other.example"] and player.generation == 2
  doAssert msg() == ""

# -----------------------------------------------------------------------------
# The network going away and coming back
# -----------------------------------------------------------------------------

test "play with no link: wait for the link, then for an address":
  fresh(server(Ok200 & "back"))
  net = NetState()
  playNow("http://radio.example/live")
  pump(100)
  doAssert player.phase == phOffline
  doAssert msg() == "The Wi-Fi link is down. Check that the access point is in range."
  doAssert fnet.hosts.len == 0 and stats.outages == 0
  net.linkUp = true
  pump(100)
  doAssert player.phase == phOffline and msg() == "Getting a network address..."
  net.hasIp = true
  doAssert tick() == shYield
  doAssert player.phase == phConnecting and msg() == "Network back, reconnecting..."
  pumpUntil player.phase == phStopped
  doAssert audio == "back" and stats.outages == 0     # waiting at the start isn't an outage

test "link up but no address (the normal case for a moment at boot)":
  fresh(server(Ok200))
  net = NetState(linkUp: true)
  playNow("http://radio.example/live")
  pump(50)
  doAssert player.phase == phOffline and msg() == "Getting a network address..."
  net.hasIp = true
  pumpUntil player.phase == phStopped

test "the link drops under a stream":
  fresh(quiet(Ok200 & "one"), server(Ok200 & "two"))
  draining = false
  playNow("http://radio.example/live")
  pumpUntil stats.connectStage == 6
  player.phase = phPlaying
  player.levelL = 200
  net.linkUp = false
  net.hasIp = false
  pump(10)
  doAssert stats.outages == 1 and fnet.closes == 1
  doAssert player.phase == phOffline and msg().startsWith("The Wi-Fi link is down")
  doAssert pipe.stream.len == 0 and player.levelL == 0
  pump(30_000)                                # however long it takes
  doAssert player.phase == phOffline and stats.reconnects == 0
  net.linkUp = true
  net.hasIp = true
  draining = true
  pumpUntil player.phase == phStopped
  doAssert audio == "two" and player.generation == 1    # same play command throughout

test "after an outage every failure is retried, ten times, 2 s apart":
  fresh()
  net = NetState()
  fnet.resolveResult = rsFailed
  playNow("http://radio.example/live")
  pump(10)
  net = NetState(linkUp: true, hasIp: true)
  let t0 = nowMs()
  pumpUntil stats.reconnects == 1
  doAssert player.phase == phConnecting and msg() == "Reconnecting..."
  pumpUntil player.phase == phError
  doAssert msg() == "Couldn't look up the server's address"
  doAssert stats.reconnects == 10 and fnet.hosts.len == 11
  doAssert nowMs() - t0 in 20_000'u64 .. 20_100'u64

test "... until audio flows again; then the normal rules are back":
  fresh(quiet(Ok200 & "x"), ConnScript(refuse: true))
  net = NetState()
  playNow("http://radio.example/live")
  pump(10)
  net = NetState(linkUp: true, hasIp: true)
  pumpUntil stats.reconnects == 1            # the stall: retried, counters reset
  pumpUntil player.phase == phError
  doAssert msg() == "Couldn't connect to the server" and stats.reconnects == 1

test "a fetch that fails because the link went is an outage, not an error":
  var lost = quiet(Ok200 & "abc")
  lost.finish = IoError
  fresh(lost, server(Ok200 & "def"))
  playNow("http://radio.example/live")
  pumpUntil stats.reconnects == 1            # link up: an ordinary reconnect
  doAssert stats.outages == 0
  # Same again, but with the link gone by the time the read fails.
  fresh(quiet(Ok200 & "abc"), server(Ok200 & "def"))
  playNow("http://radio.example/live")
  pumpUntil stats.connectStage == 6 and audio == "abc"
  fnet.cur.finish = IoError
  net.linkUp = false
  discard tick()
  doAssert stats.outages == 1 and stats.reconnects == 0 and player.phase != phError

test "commands while offline":
  fresh(server(Ok200 & "x"))
  net = NetState()
  playNow("http://radio.example/live")
  pump(10)
  doAssert player.phase == phOffline
  stop()
  pump(10)
  doAssert player.phase == phStopped and msg() == "" and player.generation == 2
  net = NetState(linkUp: true, hasIp: true)
  pump(100)
  doAssert fnet.hosts.len == 0                # stopped means stopped

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

test "stop while streaming":
  fresh(quiet(Ok200 & "abc"))
  draining = false
  playNow("http://radio.example/live")
  pumpUntil stats.connectStage == 6
  player.title.set "Song"
  player.bitrate = 128
  stop()
  doAssert tick() == shYield
  doAssert player.phase == phStopped and msg() == "" and player.generation == 2
  doAssert pipe.stream.len == 0 and fnet.closes == 1
  doAssert player.title.len == 0 and player.station.len == 0 and player.bitrate == 0
  pump(10_000)
  doAssert player.phase == phStopped and stats.reconnects == 0

test "play replaces what is playing; only the newest command counts":
  fresh(quiet(Ok200 & "first"), server(Ok200 & "second"))
  playNow("http://radio.example/live")
  pumpUntil stats.connectStage == 6
  play("http://ignored.example/")
  playNow("  http://new.example/next  ")
  pumpUntil player.phase == phStopped
  doAssert fnet.hosts == @["radio.example", "new.example"] and audio == "firstsecond"
  doAssert player.generation == 2 and fnet.closes == 2

test "a command during the lookup or the connect drops it":
  fresh(ConnScript(hang: true), server(Ok200))
  playNow("http://radio.example/live")
  pump(100)
  stop()
  pump(5)
  doAssert fnet.closes == 1 and player.phase == phStopped
  fnet.resolveResult = rsPending
  playNow("http://radio.example/live")
  pump(100)
  stop()
  pump(5)
  doAssert fnet.closes == 2

test "play again after an error or the end":
  fresh(server("HTTP/1.0 404 Nope\r\n\r\n"), server(Ok200 & "ok"))
  playNow("http://radio.example/live")
  pumpUntil player.phase == phError
  playNow("http://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert audio == "ok" and player.generation == 2

# -----------------------------------------------------------------------------
# TLS
# -----------------------------------------------------------------------------

test "an https stream end to end":
  fresh(server(enc(Ok200 & "sec"), enc("ret"), enc(metaBlock("ignored"))))
  ftls.wants = 40
  playNow("https://radio.example/live")
  pumpUntil stats.connectStage == 3
  doAssert ftls.hostname == "radio.example" and fnet.ports == @[443'u16]
  pumpUntil stats.connectStage == 6
  doAssert stats.tlsHandshakeMs == 40
  doAssert enc(fnet.sent[0]) == Request       # the request went through the session
  pumpUntil player.phase == phStopped
  doAssert msg() == "The stream ended"
  doAssert audio.startsWith("secret") and ftls.closes == 1 and fnet.closes == 1
  doAssert stats.tlsReadMaxUs == 2000
  doAssert stats.tlsLastError == -0x7280      # the close is recorded, as upstream
  doAssert stats.failInfo == [11'u32, 22, 33, 44]

test "every decrypted read is followed by a yield":
  fresh(quiet(enc(Ok200), enc("a"), enc("b"), enc("c")))
  playNow("https://radio.example/live")
  pumpUntil stats.connectStage == 6
  let reads = ftls.reads
  doAssert client[].step() == shYield and ftls.reads == reads + 1
  doAssert client[].step() == shYield and ftls.reads == reads + 2
  doAssert client[].step() == shYield and ftls.reads == reads + 3
  doAssert client[].step() == shWait          # nothing more: wait

test "handshake failures, by class":
  for (class, why) in [
      (seRefused, "The server refused the secure connection (it may not offer TLS 1.3)"),
      (seHandshake, "The server's TLS settings aren't supported (needs AES-128-GCM and P-256)"),
      (seRecordTooBig, "The server's TLS records are too big for this radio's memory; try http://"),
      (seIo, "Connection lost while setting up TLS"),
      (seOther, "The secure (TLS) connection failed"),
      (seNone, "The secure (TLS) connection failed")]:
    fresh(quiet())
    ftls.handshakeResult = ssError
    ftls.errClass = class
    ftls.wants = 3
    playNow("https://radio.example/live")
    pumpUntil player.phase == phError
    doAssert msg() == why and stats.reconnects == 0 and stats.connectStage == 3
    doAssert ftls.closes == 1 and fnet.closes == 1

test "the connection closes, or goes quiet, during the handshake":
  fresh(quiet())
  ftls.handshakeResult = ssClosed
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while setting up TLS"

  fresh(quiet())
  ftls.wants = high(int)
  playNow("https://radio.example/live")
  let t0 = nowMs()
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while setting up TLS"
  doAssert nowMs() - t0 in 15_000'u64 .. 15_010'u64

test "no TLS in the build, or no memory for a session":
  fresh(quiet())
  client.secure.available = false
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "This firmware was built without TLS; try http://"
  doAssert ftls.opens == 0 and fnet.closes == 1

  fresh(quiet())
  ftls.openFails = true
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "The secure (TLS) connection failed" and ftls.closes == 0

test "the transport fails under an open session":
  var lost = quiet(enc(Ok200 & "abc"))
  lost.finish = IoError
  fresh(lost, server(enc(Ok200 & "def")))
  playNow("https://radio.example/live")
  pumpUntil stats.reconnects == 1
  doAssert msg() == "Reconnecting..." and stats.tlsLastError == -0x0050
  pumpUntil player.phase == phStopped
  doAssert audio == "abcdef" and ftls.opens == 2

  var early = quiet(enc("HTTP/1.0 200"))
  early.finish = IoError
  fresh(early, early, early, early)
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while reading the response"

test "a session that can't take the request yet, or at all":
  fresh(server(enc(Ok200 & "w")))
  ftls.writeWants = 25
  playNow("https://radio.example/live")
  pumpUntil player.phase == phStopped
  doAssert enc(fnet.sent[0]) == Request and audio == "w"

  fresh(ConnScript(sendFails: true))
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "Connection lost while sending the request"

test "an https server that says nothing, and one that stalls":
  fresh(quiet(), quiet(), quiet(), quiet())
  playNow("https://radio.example/live")
  pumpUntil player.phase == phError
  doAssert msg() == "The server didn't answer" and ftls.opens == 4 and ftls.closes == 4

  fresh(quiet(enc(Ok200 & "x")), server(enc(Ok200 & "y")))
  playNow("https://radio.example/live")
  pumpUntil stats.reconnects == 1
  pumpUntil player.phase == phStopped
  doAssert audio == "xy"

echo "t_stream: ok"
