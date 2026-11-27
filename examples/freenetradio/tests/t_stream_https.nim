## Host end-to-end test: an https Icecast-style stream from a local
## `openssl s_server` played through the radio's own chain:
##
##   s_server -> socket -> tlsbind.nim (bl808/kernel/tls, Mbed TLS 3.6)
##            -> stream.nim (HTTP, ICY) -> pipe -> player.nim + mp3dec.nim
##            -> I2S ring -> a simulated DAC
##
## Only the two ends are stand-ins: POSIX sockets where the board has lwIP,
## and a DAC that follows the clock where the board has DMA. The sound that
## comes out is compared with a straight decode of the same MP3 bytes.
##
## Time is virtual (timebase's fake clock) and only passes when there is
## nothing left to do, so 17 seconds of radio play in well under a second
## and a slow machine cannot cause an underrun.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_stream_https.nim
##
## Needs `openssl` on the PATH; without it the test says so and is skipped.

import std/[os, osproc, posix, strutils]
import ../netio, ../stream, ../tlsbind, ../pipe, ../status, ../netstate,
       ../timebase, ../diag, ../prefs, ../spectrum, ../text
import ../player, ../i2s_ring, ../mp3dec

template st: untyped = status.player
  ## The shared status (the module `player` hides the bare name here).

const
  Clip = staticRead("data/mp3/m1_44k_js160.mp3")
    ## 44.1 kHz joint stereo at 160 kbit/s, about 0.7 s.
  Metaint = 8192
  StationName = "Host Test Radio: MP3 over TLS"
  FirstTitle = "The Fixtures - First Song"
  SecondTitle = "The Fixtures - Second Song"
  DecodeCostUs = 3000
    ## What a frame is taken to cost on the board; the virtual clock moves
    ## by this much per decoded frame.

# ---- The server ----------------------------------------------------------------

type Server = object
  dir: string
  port: int
  process: Process

proc sh(dir, command: string) =
  let (output, code) = execCmdEx(command, workingDir = dir)
  doAssert code == 0, command & "\n" & output

proc freePort(): int =
  ## A port nothing listens on (the server takes it a moment later).
  let s = socket(AF_INET, SOCK_STREAM, 0)
  var sa: Sockaddr_in
  sa.sin_family = typeof(sa.sin_family)(AF_INET)
  sa.sin_addr.s_addr = htonl(0x7F00_0001'u32)
  var size = sizeof(sa).SockLen
  doAssert bindSocket(s, cast[ptr SockAddr](addr sa), size) == 0
  doAssert getsockname(s, cast[ptr SockAddr](addr sa), addr size) == 0
  result = ntohs(sa.sin_port).int
  discard close(s)

proc icyReply(mp3: string; titles: openArray[(int, string)]): string =
  ## What an Icecast server sends for `Icy-MetaData: 1`: the headers, then
  ## the audio with a metadata block after every `Metaint` bytes. `titles`
  ## says which blocks (counted from 0) carry a new title; the rest are
  ## empty.
  result = "HTTP/1.0 200 OK\r\nServer: Icecast 2.4.4\r\nContent-Type: audio/mpeg\r\n" &
    "icy-br:160\r\nicy-name:" & StationName & "\r\nicy-pub:0\r\n" &
    "icy-metaint:" & $Metaint & "\r\n\r\n"
  var pos = 0
  var blockIndex = 0
  while mp3.len - pos >= Metaint:
    result.add mp3[pos ..< pos + Metaint]
    pos += Metaint
    var meta = ""
    for (at, title) in titles:
      if at == blockIndex: meta = "StreamTitle='" & title & "';StreamUrl='';"
    while meta.len mod 16 != 0: meta.add '\0'
    result.add char(meta.len div 16)
    result.add meta
    inc blockIndex
  result.add mp3[pos .. ^1]

proc startServer(reply: string; rsaCert: bool; tlsOptions: string;
                 connections = 1): Server =
  ## `openssl s_server -HTTP` answers `GET /stream` with the file `stream`,
  ## sent as it is (the file holds the whole response), then closes.
  result.dir = getTempDir() / ("fnr-https-" & $getCurrentProcessId())
  removeDir(result.dir)
  createDir(result.dir)
  writeFile(result.dir / "stream", reply)
  writeFile(result.dir / "server.log", "")
  let key =
    if rsaCert: "-newkey rsa:2048"
    else: "-newkey ec -pkeyopt ec_paramgen_curve:prime256v1"
  sh(result.dir, "openssl req -x509 " & key & " -nodes -keyout key.pem -out cert.pem " &
     "-subj /CN=localhost -days 2 2>&1")
  result.port = freePort()
  result.process = startProcess("/bin/sh", workingDir = result.dir, args = ["-c",
    "exec openssl s_server -accept 127.0.0.1:" & $result.port &
    # So many connections, then exit: leaving by itself is what gets its
    # log written out in full.
    " -cert cert.pem -key key.pem -HTTP -naccept " & $connections &
    # Naming a host makes the server report the name the client asked for
    # (it wants a second certificate for that host; the same one will do).
    " -servername localhost -cert2 cert.pem -key2 key.pem " & tlsOptions &
    " > server.log 2>&1"])
  for _ in 0 ..< 500:               # up to 5 s for "ACCEPT"
    if "ACCEPT" in readFile(result.dir / "server.log"): return
    doAssert result.process.running, "s_server exited:\n" & readFile(result.dir / "server.log")
    sleep(10)
  doAssert false, "s_server did not start:\n" & readFile(result.dir / "server.log")

proc stopServer(s: var Server): string =
  ## Waits for the server to finish (it has served its connections) and
  ## returns what it logged.
  discard s.process.waitForExit(5000)
  if s.process.running:
    s.process.terminate()
    discard s.process.waitForExit()
  s.process.close()
  result = readFile(s.dir / "server.log")
  removeDir(s.dir)

# ---- NetOps over a socket ---------------------------------------------------------

var
  fd: cint = -1
  connState: ConnState
  resolved: uint32
  resolveState: ResolveState
  lookups: seq[string]
  received: int           ## bytes, over all connections
  resetAt: int            ## cut the connection once this many came in (0: never)
  resetWith = netio.IoError  ## how: `IoError` is a reset, `IoClosed` a bare TCP FIN

proc netResolveStart(ctx: pointer; host: openArray[char]) {.nimcall.} =
  var name = newString(host.len)
  for i in 0 ..< host.len: name[i] = host[i]
  lookups.add name
  resolveState = if name == "localhost": rsOk else: rsFailed
  resolved = htonl(0x7F00_0001'u32)       # network byte order, as lwIP

proc netResolvePoll(ctx: pointer; ip: var uint32): ResolveState {.nimcall.} =
  ip = resolved
  resolveState

proc netClose(ctx: pointer) {.nimcall.} =
  if fd >= 0: discard close(SocketHandle(fd))
  fd = -1
  connState = csIdle

proc netConnectStart(ctx: pointer; ip: uint32; port: uint16) {.nimcall.} =
  netClose(ctx)
  let s = socket(AF_INET, SOCK_STREAM, 0)
  var sa: Sockaddr_in
  sa.sin_family = typeof(sa.sin_family)(AF_INET)
  sa.sin_port = htons(port)
  sa.sin_addr.s_addr = ip
  if connect(s, cast[ptr SockAddr](addr sa), sizeof(sa).SockLen) != 0:
    discard close(s)
    connState = csFailed
    return
  fd = s.cint
  discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
  connState = csConnected

proc netConnectPoll(ctx: pointer): ConnState {.nimcall.} = connState

proc netSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  if fd < 0: return IoError
  let n = send(SocketHandle(fd), data, len, 0)
  if n >= 0: n
  elif errno == EAGAIN or errno == EWOULDBLOCK: 0
  else: IoError

proc netRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  if fd < 0: return IoError
  if resetAt > 0 and received >= resetAt:
    resetAt = 0
    return resetWith
  let n = recv(SocketHandle(fd), data, len, 0)
  if n > 0:
    received += n
    n
  elif n == 0: IoClosed
  elif errno == EAGAIN or errno == EWOULDBLOCK: 0
  else: IoError

proc netQueued(ctx: pointer): int {.nimcall.} = 0

proc waitReadable(ms: cint) =
  ## Real time: let the server get its next bytes to us.
  if fd < 0: return
  var p = TPollfd(fd: fd, events: POLLIN)
  discard poll(addr p, 1, ms)

# ---- The simulated DAC (as in t_player.nim) ----------------------------------------

type
  Frame = array[2, int16]
  Dac = object
    cpu, mem: array[RingLen, int16]   ## what the CPU wrote / what the DMA sees
    pos: int
    rate: uint32
    fracUs: uint64
    played: seq[Frame]
    rateChanges: seq[uint32]

var dac: ptr Dac

proc advanceUs(us: uint64) =
  ## Virtual time passes: the DAC plays on.
  setFakeTimeUs(nowUs() + us)
  dac.fracUs += us * dac.rate
  let frames = dac.fracUs div 1_000_000
  dac.fracUs -= frames * 1_000_000
  for _ in 0 ..< frames.int:
    dac.played.add [dac.mem[dac.pos], dac.mem[dac.pos + 1]]
    dac.pos = (dac.pos + 2) mod RingLen

proc dacReadPos(): int {.nimcall.} = dac.pos

proc dacCommit(ring: var I2sRing) {.nimcall.} =
  var spans: array[8, Span]
  let n = ring.takeDirty(spans)
  for i in 0 ..< n:
    for k in spans[i].start ..< spans[i].start + spans[i].len:
      dac.mem[k] = dac.cpu[k]

proc dacSetRate(ring: var I2sRing; rate: uint32) {.nimcall.} =
  ring.restart()
  dacCommit(ring)
  dac.pos = 0
  dac.fracUs = 0
  dac.rate = rate
  dac.rateChanges.add rate

proc dacActualRate(rate: uint32): uint32 {.nimcall.} = rate

# ---- The real decoder -------------------------------------------------------------

proc decodeFrame(ctx: pointer; mp3: openArray[byte]; pcm: var openArray[int16];
                 info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] {.nimcall.} =
  result = cast[ptr Mp3Decoder](ctx)[].decode(mp3, pcm, info)
  advanceUs(DecodeCostUs)

proc spectrumOf(ctx: pointer; energy: var array[SpectrumBands, float32]): uint32 {.nimcall.} =
  cast[ptr Mp3Decoder](ctx)[].takeSpectrum(energy)

proc decodeAll(mp3: string): seq[Frame] =
  ## The reference: the whole stream through a fresh decoder, no player.
  let d = createShared(Mp3Decoder)
  initDecoder(d[])
  var pcm: array[MaxSamplesPerFrame, int16]
  var pos = 0
  while pos < mp3.len:
    var info: FrameInfo
    let (used, status) = d[].decode(
      cast[ptr UncheckedArray[byte]](unsafeAddr mp3[pos]).toOpenArray(0, mp3.len - pos - 1),
      pcm, info)
    if used == 0: break
    pos += used
    if status == dsDecoded:
      doAssert info.channels == 2
      for f in 0 ..< info.samplesProduced:
        result.add [pcm[2 * f], pcm[2 * f + 1]]
  freeShared(d)

# ---- One radio ------------------------------------------------------------------

type
  Radio = object
    client: StreamClient
    tls: TlsLink
    player: Player
    decoder: Mp3Decoder
    window: array[Window, byte]
    pcm: array[MaxSamplesPerFrame, int16]

  Heard = object
    phases: seq[Phase]        ## in the order they were first entered
    titles: seq[string]
    messages: seq[string]
    tlsVersion, tlsSuite: string
    sampleRate, bitrate: uint32
    channels: uint8
    played: seq[Frame]
    virtualMs: uint64

proc listen(url: string; limitMs: uint64): Heard =
  ## Power up a radio, play `url` and run it until the stream has ended and
  ## the sound has died away (or `limitMs` of virtual time has passed).
  setFakeTimeUs(1_000_000)
  diagInit(); statusInit(); pipeInit(); prefsInit(); spectrumInit()
  net = NetState(linkUp: true, hasIp: true)
  netClose(nil)
  lookups.setLen 0
  received = 0
  if dac == nil: dac = createShared(Dac)
  dac[] = Dac(rate: InitialSampleRate)
  let radio = createShared(Radio)       # as on the board: too big for the stack
  initDecoder(radio.decoder)
  initPlayer(radio.player, cast[ptr UncheckedArray[int16]](addr dac.cpu[0]),
             cast[ptr UncheckedArray[byte]](addr radio.window[0]),
             cast[ptr UncheckedArray[int16]](addr radio.pcm[0]),
             DecoderOps(ctx: addr radio.decoder, decode: decodeFrame, takeSpectrum: spectrumOf),
             OutputOps(readPos: dacReadPos, commit: dacCommit,
                       setSampleRate: dacSetRate, actualRate: dacActualRate))
  streamInit(radio.client, NetOps(resolveStart: netResolveStart,
      resolvePoll: netResolvePoll, connectStart: netConnectStart,
      connectPoll: netConnectPoll, send: netSend, recv: netRecv, close: netClose,
      rxQueued: netQueued, txQueued: netQueued),
    secureOps(addr radio.tls))
  setVolume(100)                        # unity gain: the DAC gets the decoder's samples
  play(url)

  # The two tasks, at the pace stream_task.nim and audio_task.nim give them.
  let startMs = nowMs()
  var streamDueUs, audioDueUs = nowUs()
  var hint = shYield
  var quietSinceMs = 0'u64
  result.phases.add st.phase
  result.titles.add ""
  result.messages.add ""
  while nowMs() - startMs < limitMs:
    if nowUs() >= streamDueUs:
      hint = radio.client.step()
      streamDueUs = nowUs() + (case hint
        of shYield: 0'u64
        of shWait: 1000'u64
        of shIdle: 5000'u64)
    if nowUs() >= audioDueUs:
      audioDueUs = nowUs() + (case radio.player.step()
        of srYield: 0'u64
        of srWait: 10_000'u64
        of srIdle: 20_000'u64
        of srDecodePending: raise newException(AssertionDefect, "unexpected remote decode"))
    if st.phase != result.phases[^1]: result.phases.add st.phase
    if $st.title != result.titles[^1]: result.titles.add $st.title
    if $st.message != result.messages[^1]: result.messages.add $st.message
    if st.phase == phPlaying:
      if result.tlsVersion.len == 0:
        result.tlsVersion = $radio.tls.version
        result.tlsSuite = $radio.tls.cipherSuite
      result.sampleRate = st.sampleRate
      result.bitrate = st.bitrate
      result.channels = st.channels
    if st.phase in {phStopped, phError}:
      # Over: half a second more for the fade-out to play.
      if quietSinceMs == 0: quietSinceMs = nowMs()
      elif nowMs() - quietSinceMs >= 500: break
    let nextUs = min(streamDueUs, audioDueUs)
    if nextUs > nowUs():
      # Both tasks are asleep. If the client sleeps because the server's
      # next bytes are not here yet, give them (real) time to arrive
      # before virtual time moves on.
      if hint == shWait and pipe.stream.free >= 2048: waitReadable(50)
      advanceUs(nextUs - nowUs())
  result.played = dac.played
  result.virtualMs = nowMs() - startMs
  netClose(nil)
  freeShared(radio)

proc tuneIn(reply: string; rsaCert: bool; tlsOptions: string;
            connections = 1): tuple[heard: Heard, log: string] =
  ## Serve `reply` at https://localhost:<port>/stream and play it; returns
  ## what was heard and what the server logged.
  var server = startServer(reply, rsaCert, tlsOptions, connections)
  try:
    result.heard = listen("https://localhost:" & $server.port & "/stream", 60_000)
  finally:
    result.log = stopServer(server)

proc find(hay, needle: openArray[Frame]): int =
  ## First index of `needle` in `hay`, or -1.
  for i in 0 .. hay.len - needle.len:
    var same = true
    for k in 0 ..< needle.len:
      if hay[i + k] != needle[k]:
        same = false
        break
    if same: return i
  -1

proc checkSound(heard: Heard; reference: seq[Frame]; mp3Len: int) =
  ## What the DAC played is the reference decode, sample for sample, from
  ## the end of the fade-in to where the end of the stream cut it off.
  const
    Probe = 4096      # clear of the fade-in and the encoder's silent start
    ProbeLen = 256
  doAssert reference.len > Probe + ProbeLen
  let at = find(heard.played, reference.toOpenArray(Probe, Probe + ProbeLen - 1))
  doAssert at >= Probe, "the stream's sound is not in the DAC output"
  let origin = at - Probe                 # DAC index of reference frame 0
  var matched = FadeFrames
  while matched < reference.len and origin + matched < heard.played.len and
      heard.played[origin + matched] == reference[matched]:
    inc matched
  # The end of the stream stops playback at once (as upstream): what was
  # still in the pipe, the decoder's window and the ring is not heard.
  let bytesPerFrame = mp3Len / reference.len
  let lostAtMost = int((PipeLen + Window).float / bytesPerFrame) + RingFrames + FadeFrames
  doAssert matched >= reference.len - lostAtMost,
    "sound matches the reference for only " & $matched & " of " & $reference.len & " frames"
  # ... and it was heard for about as long as it lasts.
  let seconds = (matched - FadeFrames) / 44100
  doAssert heard.virtualMs.float / 1000 >= seconds
  when defined(verbose):
    echo "  matched ", matched, " of ", reference.len, " frames (", seconds, " s) in ",
      heard.virtualMs, " virtual ms; handshake ", stats.tlsHandshakeMs, " ms, ",
      heard.tlsVersion, " ", heard.tlsSuite

proc main() =
  if findExe("openssl").len == 0:
    echo "t_stream_https: skipped (no openssl on the PATH)"
    return

  # ---- TLS 1.3, upstream's one combination: AES-128-GCM-SHA256 and P-256 -----
  block:
    let mp3 = Clip.repeat(24)             # about 17 s
    let reference = decodeAll(mp3)
    doAssert reference.len > 16 * 44100
    let blocks = mp3.len div Metaint
    let (heard, log) = tuneIn(
      icyReply(mp3, [(0, FirstTitle), (blocks div 2, SecondTitle)]),
      rsaCert = false,
      "-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256 -groups P-256")

    doAssert heard.phases == @[phStopped, phConnecting, phBuffering, phPlaying, phStopped],
      $heard.phases & " '" & $st.message & "' tls error " & $stats.tlsLastError
    doAssert $st.message == StreamEnded
    doAssert lookups == @["localhost"]
    doAssert "Hostname in TLS extension: \"localhost\"" in log, log      # SNI
    doAssert heard.tlsVersion == "TLSv1.3", heard.tlsVersion
    doAssert heard.tlsSuite == "TLS1-3-AES-128-GCM-SHA256", heard.tlsSuite
    doAssert stats.connectStage == 6 and stats.reconnects == 0 and stats.outages == 0
    doAssert $st.station == StationName
    doAssert heard.titles == @["", FirstTitle, SecondTitle], $heard.titles
    doAssert heard.sampleRate == 44100 and heard.channels == 2 and heard.bitrate == 160
    doAssert st.underruns == 0
    doAssert dac.rateChanges.len == 0     # the DAC already ran at 44.1 kHz
    checkSound(heard, reference, mp3.len)

  # ---- An older server: TLS 1.2 with an RSA certificate -----------------------
  block:
    let mp3 = Clip.repeat(6)
    let reference = decodeAll(mp3)
    let (heard, _) = tuneIn(icyReply(mp3, [(0, FirstTitle)]), rsaCert = true, "-tls1_2")

    doAssert heard.phases == @[phStopped, phConnecting, phBuffering, phPlaying, phStopped],
      $heard.phases & " '" & $st.message & "' tls error " & $stats.tlsLastError
    doAssert $st.message == StreamEnded
    doAssert heard.tlsVersion == "TLSv1.2", heard.tlsVersion
    doAssert heard.tlsSuite == "TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256", heard.tlsSuite
    doAssert heard.titles == @["", FirstTitle]
    doAssert st.underruns == 0
    checkSound(heard, reference, mp3.len)

  # ---- The connection is reset mid-stream: reconnect and carry on ---------------
  block:
    let mp3 = Clip.repeat(8)
    resetAt = mp3.len div 2
    let (heard, _) = tuneIn(icyReply(mp3, [(0, FirstTitle)]), rsaCert = false,
                            "-tls1_3", connections = 2)

    doAssert stats.reconnects == 1 and resetAt == 0
    doAssert Reconnecting in heard.messages, $heard.messages
    doAssert heard.phases[^1] == phStopped and $st.message == StreamEnded,
      $heard.phases & " '" & $st.message & "'"
    doAssert received > mp3.len + mp3.len div 2     # the second connection ran to its end
    doAssert lookups == @["localhost", "localhost"]

  # ---- The TCP connection just ends (FIN) with no TLS close_notify --------------
  # Upstream's TLS reports that as an I/O error, so the stream is lost, not
  # finished: only the server's close_notify is "The stream ended".
  block:
    let mp3 = Clip.repeat(8)
    resetAt = mp3.len div 2
    resetWith = IoClosed
    let (heard, _) = tuneIn(icyReply(mp3, [(0, FirstTitle)]), rsaCert = false,
                            "-tls1_3", connections = 2)
    resetWith = netio.IoError

    doAssert stats.reconnects == 1 and resetAt == 0, $stats.reconnects & " '" & $st.message & "'"
    doAssert Reconnecting in heard.messages, $heard.messages
    doAssert heard.phases[^1] == phStopped and $st.message == StreamEnded,
      $heard.phases & " '" & $st.message & "'"
    doAssert lookups == @["localhost", "localhost"]

  # ---- Nothing listens on the port: upstream's message, no retry --------------
  block:
    let port = freePort()
    let heard = listen("https://localhost:" & $port & "/stream", 60_000)
    doAssert heard.phases == @[phStopped, phConnecting, phError], $heard.phases
    doAssert $st.message == "Couldn't connect to the server", $st.message

  echo "t_stream_https: ok"

main()
