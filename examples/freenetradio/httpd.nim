## The web interface's HTTP logic (the HTTP half of upstream `src/main.rs`:
## `serve`, `respond`, `send_status`, `status_json`, `preset_reply` and
## their helpers). Pure Nim: `http_task.nim` moves the bytes.
##
##   GET  /                 the web page (gzip)
##   GET  /radio            player status as JSON
##   POST /radio/play       start a stream: raw URL body, or form field `url=`
##   POST /radio/stop       stop playback
##   POST /radio/volume     body `0`..`100`, or form field `volume=`
##   GET  /presets          the 99 presets as JSON
##   POST /presets/<1..99>  save: form fields `name=` and `url=` (empty url clears)
##   POST /presets/<n>/play play a preset
##   POST /presets/reset    back to the built-in presets
##   POST /remote/<key>     virtual remote button; `?repeat` for a held button
##   GET  /licenses         the open source list, `name|author|license` lines
##   GET  /screen           raw framebuffer (256x64, 4 bpp)
##   diag builds: GET /stats, POST /stats/reset, GET /screen/stream?n=<frames>
##
## POSTs reply with the status JSON, or redirect to / for plain HTML form
## submits (requests whose Accept header includes text/html).
##
## Use: keep one `Exchange` per connection; `reset` it when a connection is
## accepted, `pump` it with the connection's non-blocking send and receive
## until it returns true, then `finish` it (also when the connection is
## given up early) and close.
##
## Underneath: `scan` the bytes received so far until the request is
## complete, `begin` a `Reply` from it (this performs the action), then call
## `next` until it says `stDone`, sending each chunk it hands out. `next`
## answers `stWait` while a reply is deferred: the status JSON is built
## 20 ms after the action so the stream task has taken a play/stop, and a
## preset reply waits for the flash job.

import std/macros
import ./text, ./timebase, ./status, ./presets, ./remote, ./ir_nec, ./ui,
       ./diag, ./about, ./webpage, ./netio

const
  RequestMax* = 1024
    ## Room for browser headers plus a full preset (URL-encoded). Larger
    ## requests are rejected.
  StatusDelayMs = 20
  SnapTimeoutMs = 2000
  DefaultStreamFrames = 100'u32

  PresetsHead = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
    "Cache-Control: no-store\r\nConnection: close\r\n\r\n["
  StreamHead = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" &
    "Connection: close\r\n\r\n"

type
  Scan* = enum
    scMore       ## read more (up to `scanWant` bytes)
    scReady      ## head and body are complete
    scTooLarge   ## reply with `beginTooLarge`

  Chunk* = object
    ## Bytes to send. They stay valid until the next call on the `Reply`.
    data*: ptr UncheckedArray[byte]
    len*: int

  Step* = enum
    stSend       ## send the chunk, then call `next` again
    stWait       ## nothing yet: call `next` again in a moment
    stDone       ## the reply is complete: close the connection

  Stage = enum
    sgDone, sgPieces, sgStatusWait, sgPresetWait, sgPresetList, sgRecording

  Reply* = object
    ## One request's reply in progress. About 2.7 KB: keep it on the heap,
    ## and do not copy or move it once `begin` has run (chunks point into it).
    stage: Stage
    after: Stage             # what follows once the queued pieces are sent
    queue: array[3, Chunk]
    queued, sent: int
    head: Text[256]
    body: Text[1024]         # status JSON
    piece: Text[320]         # one preset of GET /presets
    stats: Text[960]
    html: bool               # the request's Accept header asks for HTML
    readyAtMs: uint64        # when the status reply may be built
    slot: int                # next preset of GET /presets
    job: presets.Ticket      # the preset save or reset this reply waits for
    framesLeft: uint32       # GET /screen/stream
    frameOut: bool           # a frame was handed out; release the display next
    recording: bool          # this reply holds `ui.capture`
    waitSinceMs: uint64

  StackUsageProc* = proc(unused, total: var int) {.nimcall.}

  DiagExtraProc* = proc(isPost: bool; path: openArray[char]; text: var Text[960];
                        blob: var Chunk): bool {.nimcall.}

var stackUsage*: StackUsageProc
  ## Stack bytes never used and the stack's size, for the "stack:" line of
  ## `/stats`. Installed by `main`; unset reads as 0 of 0.

var diagExtra*: DiagExtraProc
  ## Further diag routes under `/selftest/` (the firmware's pin self-test).
  ## Returns false for a path it does not know. The reply is `blob` as
  ## binary when it sets one, else `text`.

# ---- Byte helpers ------------------------------------------------------------

func lower(c: char): char {.inline.} =
  if c in {'A' .. 'Z'}: char(c.ord + 32) else: c

func eqIgnoreCase(a, b: openArray[char]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if lower(a[i]) != lower(b[i]): return false
  true

func containsIgnoreCase(hay, needle: openArray[char]): bool =
  for start in 0 .. hay.len - needle.len:
    var same = true
    for i in 0 ..< needle.len:
      if lower(hay[start + i]) != lower(needle[i]):
        same = false
        break
    if same: return true
  false

func startsWith(s: openArray[char]; prefix: string): bool =
  if s.len < prefix.len: return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]: return false
  true

func endsWith(s: openArray[char]; suffix: string): bool =
  if s.len < suffix.len: return false
  for i in 0 ..< suffix.len:
    if s[s.len - suffix.len + i] != suffix[i]: return false
  true

func equals(s: openArray[char]; other: string): bool {.inline.} =
  s.len == other.len and s.startsWith(other)

func indexOf(s: openArray[char]; c: char; first = 0): int =
  for i in first ..< s.len:
    if s[i] == c: return i
  -1

iterator spans(s: openArray[char]; sep: char): Slice[int] =
  ## The pieces of `s` between separators (always at least one, possibly
  ## empty: `a .. a - 1`), like Rust's `split`.
  var first = 0
  for i in 0 .. s.len:
    if i == s.len or s[i] == sep:
      yield first .. i - 1
      first = i + 1

template sub(s: openArray[char]; span: Slice[int]): untyped =
  toOpenArray(s, span.a, span.b)

func validUtf8*(s: openArray[char]): bool =
  ## Strict UTF-8, as Rust's `core::str::from_utf8` accepts it.
  var i = 0
  while i < s.len:
    let b = s[i].ord
    var more: int
    var lo = 0x80
    var hi = 0xBF
    if b < 0x80: more = 0
    elif b in 0xC2 .. 0xDF: more = 1
    elif b in 0xE0 .. 0xEF:
      more = 2
      if b == 0xE0: lo = 0xA0
      elif b == 0xED: hi = 0x9F
    elif b in 0xF0 .. 0xF4:
      more = 3
      if b == 0xF0: lo = 0x90
      elif b == 0xF4: hi = 0x8F
    else: return false
    if i + more >= s.len and more > 0: return false
    for k in 1 .. more:
      let c = s[i + k].ord
      if k == 1:
        if c < lo or c > hi: return false
      elif c < 0x80 or c > 0xBF: return false
    i += more + 1
  true

func parseUint*(s: openArray[char]; value: var uint32): bool =
  ## Rust's `str::parse::<u32>`: decimal digits with an optional leading
  ## `+`, nothing else, no overflow.
  var i = 0
  if s.len > 0 and s[0] == '+': i = 1
  if i >= s.len: return false
  var v = 0'u64
  while i < s.len:
    if s[i] notin {'0' .. '9'}: return false
    v = v * 10 + uint64(s[i].ord - '0'.ord)
    if v > high(uint32).uint64: return false
    inc i
  value = v.uint32
  true

# ---- Request parsing -----------------------------------------------------------

func header*(head: openArray[char]; name: string; value: var Slice[int]): bool =
  ## The value of the first header called `name` (case-insensitive), as a
  ## span of `head` without the trailing CR.
  var requestLine = true
  for line in spans(head, '\n'):
    if requestLine:
      requestLine = false
      continue
    var last = line.b
    if last >= line.a and head[last] == '\r': dec last
    var colon = -1
    for i in line.a .. last:
      if head[i] == ':':
        colon = i
        break
    if colon < 0: continue
    if eqIgnoreCase(head.toOpenArray(line.a, colon - 1), name):
      value = colon + 1 .. last
      return true
  false

func acceptsHtml*(head: openArray[char]): bool =
  ## True if the request's `Accept` header asks for HTML, i.e. it is a
  ## browser navigation (form submit) rather than `fetch()` or curl.
  var requestLine = true
  for line in spans(head, '\n'):
    if requestLine:
      requestLine = false
      continue
    if line.len > 7 and
        eqIgnoreCase(head.toOpenArray(line.a, line.a + 6), "accept:") and
        containsIgnoreCase(head.toOpenArray(line.a + 7, line.b), "text/html"):
      return true
  false

func formField*(body: openArray[char]; name: string; value: var Slice[int]): bool =
  ## The raw (still URL-encoded) value of `name` in an
  ## application/x-www-form-urlencoded body, as a span of `body`.
  for pair in spans(body, '&'):
    var eq = -1
    for i in pair.a .. pair.b:
      if body[i] == '=':
        eq = i
        break
    if eq < 0: continue
    if body.toOpenArray(pair.a, eq - 1).equals(name):
      value = eq + 1 .. pair.b
      return true
  false

func hexValue(c: char): int =
  case c
  of '0' .. '9': c.ord - '0'.ord
  of 'a' .. 'f': c.ord - 'a'.ord + 10
  of 'A' .. 'F': c.ord - 'A'.ord + 10
  else: -1

func urlDecode*[N](input: openArray[char]; o: var Text[N]) =
  ## URL-decode a form value (`+` and `%XX`) and append it to `o`. At most
  ## 256 bytes are decoded; a value that is not UTF-8 decodes to nothing.
  var bytes: array[256, char]
  var n = 0
  var i = 0
  while i < input.len and n < bytes.len:
    var b = input[i]
    inc i
    if b == '+':
      b = ' '
    elif b == '%' and i + 2 <= input.len:
      let h = hexValue(input[i])
      let l = hexValue(input[i + 1])
      if h >= 0 and l >= 0:
        b = char(h shl 4 or l)
        i += 2
    bytes[n] = b
    inc n
  if validUtf8(bytes.toOpenArray(0, n - 1)):
    o.add bytes.toOpenArray(0, n - 1)

func scan*(req: openArray[char]; headLen, bodyLen: var int): Scan =
  ## Where the request stands given the bytes received so far. The head
  ## ends at the first blank line; the body is `Content-Length` bytes.
  var headEnd = -1
  for i in 0 .. req.len - 4:
    if req[i] == '\r' and req[i + 1] == '\n' and req[i + 2] == '\r' and
        req[i + 3] == '\n':
      headEnd = i + 4
      break
  headLen = 0
  bodyLen = 0
  if headEnd < 0:
    return if req.len >= RequestMax: scTooLarge else: scMore
  headLen = headEnd
  var value: Slice[int]
  if header(req.toOpenArray(0, headLen - 1), "content-length", value):
    template digits: untyped = req.toOpenArray(value.a, value.b)
    var n = 0'u32
    if validUtf8(digits) and parseUint(digits.sub(trimmed(digits)), n):
      bodyLen = n.int
  if headLen + bodyLen > RequestMax: scTooLarge
  elif req.len < headLen + bodyLen: scMore
  else: scReady

func scanWant*(have, headLen, bodyLen: int): int =
  ## How many more bytes to read after `scan` said `scMore` (`headLen` is 0
  ## while the head is incomplete).
  if headLen == 0: RequestMax - have else: headLen + bodyLen - have

# ---- Text building ---------------------------------------------------------------

func emit[N](o: var Text[N]; s: string) {.inline.} = o.add s
func emit[N](o: var Text[N]; c: char) {.inline.} = o.add c
func emit[N; T: SomeInteger](o: var Text[N]; v: T) {.inline.} = o.addInt v
func emit[N](o: var Text[N]; b: bool) {.inline.} =
  o.add(if b: "true" else: "false")

macro put(o: untyped; parts: varargs[untyped]): untyped =
  ## `o.put a, b, c`: append each part (text, character, integer or bool).
  result = newStmtList()
  for part in parts:
    result.add newCall(bindSym"emit", o, part)

func jsonStr*[N](o: var Text[N]; s: openArray[char]) =
  ## Append `s` as a JSON string (it is already printable ASCII).
  o.add '"'
  for c in s:
    case c
    of '"': o.add "\\\""
    of '\\': o.add "\\\\"
    else: o.add c
  o.add '"'

proc statusJson*(j: var Text[1024]) =
  ## The player status as JSON for the web page.
  j.put "{\"state\":\"", $player.phase, "\",\"message\":"
  jsonStr(j, player.message.chars)
  j.add ",\"url\":"
  jsonStr(j, player.url.chars)
  j.add ",\"station\":"
  jsonStr(j, player.station.chars)
  j.add ",\"title\":"
  jsonStr(j, player.title.chars)
  j.put ",\"sample_rate\":", player.sampleRate, ",\"bitrate\":", player.bitrate,
    ",\"channels\":", player.channels, ",\"buffer\":", player.bufferPct,
    ",\"underruns\":", player.underruns, ",\"volume\":", player.volume,
    ",\"muted\":", player.muted, "}"

func addHex2[N](o: var Text[N]; v: uint32) =
  ## Upper-case hex, at least two digits (Rust's `{:02X}`).
  const Digits = "0123456789ABCDEF"
  var shift = 28
  while shift > 4 and (v shr shift) == 0: shift -= 4
  while shift >= 0:
    o.add Digits[int((v shr shift) and 0xF)]
    shift -= 4

proc statsText*(o: var Text[960]) =
  ## The `/stats` text. Reading it restarts the "since last read" marks
  ## (frame gaps, decode max, DAC queue low-water, loop gap, TLS read max).
  var unused, total = 0
  if stackUsage != nil: stackUsage(unused, total)
  let gapMin = if stats.frameGapMinMs == high(uint32): 0'u32 else: stats.frameGapMinMs
  let gapMax = stats.frameGapMaxMs
  stats.frameGapMinMs = high(uint32)
  stats.frameGapMaxMs = 0
  let decodeMax = player.decodeMaxUs
  player.decodeMaxUs = 0
  let minQueued = stats.minQueued
  stats.minQueued = high(uint32)
  let loopGap = stats.maxLoopGapUs
  stats.maxLoopGapUs = 0
  let tlsReadMax = stats.tlsReadMaxUs
  stats.tlsReadMaxUs = 0

  o.put "stack: ", unused, " of ", total, " bytes never used\n",
    "uptime: ", nowMs() div 1000, " s\n",
    "frame gap: ", gapMin, '-', gapMax, " ms\n",
    "decode per frame: avg ", player.decodeAvgUs, " us, max ", decodeMax, " us\n",
    "underruns: ", player.underruns, '\n',
    "rx ring overflows: ", 0, '\n',
    "stream bytes in: ", stats.streamBytes, '\n',
    "audio loops: ", stats.audioLoops, '\n',
    "display frames: ", stats.displayFrames, " (stage ", stats.displayStage,
    "), flush timeouts: ", stats.flushTimeouts,
    ", overlay draw max: ", stats.overlayMaxUs, " us\n",
    "DAC queue low-water: ", minQueued, " frames, audio loop max gap: ",
    loopGap, " us\n",
    "ir: last code "
  if stats.irLastCode == high(uint32):
    o.add "none"
  else:
    o.add "addr 0x"
    o.addHex2 stats.irLastCode shr 8
    o.add " cmd 0x"
    o.addHex2 stats.irLastCode and 0xFF
  o.put ", frames ", stats.irFrames, ", errors ", stats.irErrors, '\n',
    "tls handshake: ", stats.tlsHandshakeMs, " ms, longest read ", tlsReadMax,
    " us, last error ", stats.tlsLastError, ", stage ", stats.connectStage,
    ", at error: tcp rx ", stats.failInfo[0], " tx ", stats.failInfo[1],
    ", tls decoded ", stats.failInfo[2], " pending ", stats.failInfo[3], '\n',
    "reconnects: ", stats.reconnects, ", network outages: ", stats.outages, '\n',
    "settings saves: ", stats.settingsSaves, ", failed ",
    stats.settingsFailures, " (", stats.settingsLastError, ")\n",
    "last underrun (ms, kind, buffered, queued): ", stats.underrunInfo[0], ' ',
    stats.underrunInfo[1], ' ', stats.underrunInfo[2], ' ',
    stats.underrunInfo[3], '\n',
    "spectrum dB (bands 0 10 20 30 39): ", stats.spectrumDb[0], ' ',
    stats.spectrumDb[1], ' ', stats.spectrumDb[2], ' ', stats.spectrumDb[3],
    ' ', stats.spectrumDb[4], '\n',
    "i2s underruns: ", stats.i2sUnderruns, ", dma errors: ", stats.dmaErrors, '\n',
    "decode errors (noframe, reservoir, corrupt, other): ",
    stats.decodeErrors[0], ' ', stats.decodeErrors[1], ' ',
    stats.decodeErrors[2], ' ', stats.decodeErrors[3], '\n',
    "wifi reconnects: ", stats.wifiReconnects, '\n'

# ---- Replies ---------------------------------------------------------------------

func chunkOf(s: openArray[char]): Chunk =
  if s.len > 0:
    result = Chunk(data: cast[ptr UncheckedArray[byte]](unsafeAddr s[0]), len: s.len)

proc pieces(r: var Reply; a: Chunk; b = Chunk(); c = Chunk()) =
  r.queue = [a, b, c]
  r.queued = 3
  r.sent = 0
  r.stage = sgPieces
  r.after = sgDone

proc respond(r: var Reply; status, contentType: string; body: Chunk;
             tail = Chunk(); location = "") =
  ## Upstream's `respond`: the usual head, then the body in up to two parts.
  r.head.clear()
  r.head.put "HTTP/1.1 ", status, "\r\nContent-Type: ", contentType,
    "\r\nContent-Length: ", body.len + tail.len,
    "\r\nCache-Control: no-store\r\nConnection: close\r\n"
  if location.len > 0:
    r.head.put "Location: ", location, "\r\n"
  r.head.add "\r\n"
  r.pieces(chunkOf(r.head.chars), body, tail)

proc plain(r: var Reply; status, body: string) =
  r.respond(status, "text/plain", chunkOf(body))

proc seeOther(r: var Reply) =
  r.respond("303 See Other", "text/plain", chunkOf("ok\n"), location = "/")

proc sendStatus(r: var Reply) =
  r.body.clear()
  statusJson(r.body)
  r.respond("200 OK", "application/json", chunkOf(r.body.chars))

proc statusLater(r: var Reply) =
  ## Let the stream task pick up a play/stop before reporting status.
  r.stage = sgStatusWait
  r.readyAtMs = nowMs() + StatusDelayMs

proc presetReply(r: var Reply; error: string) =
  ## Reply to a preset change: redirect browsers, otherwise ok / error text.
  if error.len > 0:
    r.piece.set error      # a copy: the message need not be a literal
    r.respond("500 Internal Server Error", "text/plain", chunkOf(r.piece.chars),
              chunkOf("\n"))
  elif r.html:
    r.seeOther()
  else:
    r.plain("200 OK", "ok\n")

proc presetJob(r: var Reply; error: string) =
  ## A save or reset was asked for: wait for it (it runs after any that
  ## came before it), or say why it was not accepted.
  if error.len > 0:
    r.presetReply(error)
  else:
    r.job = presets.ticket()
    r.stage = sgPresetWait

proc screenChunk(): Chunk {.inline.} =
  Chunk(data: cast[ptr UncheckedArray[byte]](ui.screen), len: ScreenBytes)

proc stopRecording(r: var Reply) =
  if r.recording:
    r.recording = false
    capture.on = false
    capture.snapDone = true      # release a display that is waiting on us

proc presetNumber(digits: openArray[char]; index: var int): bool =
  ## A preset number 1..99 as a 0-based index.
  var n = 0'u32
  if parseUint(digits, n) and n >= 1 and n <= Slots.uint32:
    index = n.int - 1
    return true
  false

proc posted(body: openArray[char]; form: bool; field: string): Text[256] =
  ## A value posted either as a form field or as the raw body (also used
  ## when a form-encoded body has no such field, e.g. `curl --data <url>`).
  var value: Slice[int]
  if form and formField(body, field, value):
    urlDecode(body.sub(value), result)
  elif validUtf8(body):
    result.add body

proc begin*(r: var Reply; req: openArray[char]; headLen, bodyLen: int;
            diagRoutes = DiagEnabled) =
  ## Route a complete request (`scan` said `scReady`), act on it and set up
  ## the reply. `diagRoutes` adds `/stats`, `/stats/reset` and
  ## `/screen/stream`.
  # Firmware without -d:radioDiag carries none of that (the constant folds
  # the routes and the /stats text away); host tests exercise both ways.
  const DiagCompiled = DiagEnabled or not defined(bl808m0)
  let diagRoutes = DiagCompiled and diagRoutes
  template head: untyped = req.toOpenArray(0, headLen - 1)
  template body: untyped = req.toOpenArray(headLen, headLen + bodyLen - 1)
  var lineEnd = indexOf(req, '\r')
  if lineEnd < 0: lineEnd = req.len
  template line: untyped = req.toOpenArray(0, lineEnd - 1)
  var methodSpan, pathSpan = 0 .. -1
  var word = 0
  for span in spans(line, ' '):
    if word == 0: methodSpan = span
    elif word == 1: pathSpan = span
    else: break
    inc word
  template path: untyped = req.toOpenArray(pathSpan.a, pathSpan.b)
  let isGet = req.toOpenArray(methodSpan.a, methodSpan.b).equals("GET")
  let isPost = req.toOpenArray(methodSpan.a, methodSpan.b).equals("POST")
  var contentType: Slice[int]
  let form = header(head, "content-type", contentType) and containsIgnoreCase(
    head.sub(contentType), "application/x-www-form-urlencoded")

  r.stage = sgDone
  r.html = acceptsHtml(head)

  if isGet and path.equals("/"):
    # Every browser accepts gzip; there is no plain copy.
    r.head.clear()
    r.head.put "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n",
      "Content-Encoding: gzip\r\nContent-Length: ", PageGz.len,
      "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    r.pieces(chunkOf(r.head.chars), chunkOf(PageGz))
  elif isGet and path.equals("/presets"):
    # Streamed as it is built: no Content-Length, the connection closes at
    # the end.
    r.pieces(chunkOf(PresetsHead))
    r.after = sgPresetList
    r.slot = 0
  elif isPost and path.equals("/presets/reset"):
    r.presetJob(startReset())
  elif isPost and path.startsWith("/presets/") and path.endsWith("/play"):
    # POST /presets/<n>/play: play it (the web page's Play buttons).
    var index = 0
    let last = path.len - "/play".len - 1
    if last >= "/presets/".len and
        presetNumber(path.toOpenArray("/presets/".len, last), index):
      playPreset(index)
      r.presetReply("")
    else:
      r.presetReply("No such preset")
  elif isPost and path.startsWith("/presets/"):
    # POST /presets/<1..99> with form fields name= and url=.
    var index = 0
    if presetNumber(path.toOpenArray("/presets/".len, path.len - 1), index):
      var name: Text[NameMax]
      var url: Text[UrlMax]
      var value: Slice[int]
      if formField(body, "name", value): urlDecode(body.sub(value), name)
      if formField(body, "url", value): urlDecode(body.sub(value), url)
      r.presetJob(startSave(index, name.chars.sub(trimmed(name.chars)),
                            url.chars.sub(trimmed(url.chars))))
    else:
      r.presetReply("No such preset")
  elif isPost and path.startsWith("/remote/"):
    # The web page's virtual remote: same codes and actions as IR.
    var nameEnd = indexOf(path, '?', "/remote/".len)
    var repeat = false
    if nameEnd >= 0:
      repeat = path.toOpenArray(nameEnd + 1, path.len - 1).equals("repeat")
    else:
      nameEnd = path.len
    let command = commandFor(path.toOpenArray("/remote/".len, nameEnd - 1))
    if command >= 0:
      onPress(Press(address: 0, command: command.uint8, repeat: repeat))
      r.statusLater()
    else:
      r.plain("404 Not Found", "no such button\n")
  elif isGet and path.equals("/radio"):
    r.sendStatus()
  elif isGet and path.equals("/licenses"):
    r.respond("200 OK", "text/plain; charset=utf-8", chunkOf(LicensesText))
  elif isPost and path.equals("/radio/play"):
    let url = posted(body, form, "url")
    status.play($url)
    r.statusLater()
  elif isPost and path.equals("/radio/stop"):
    status.stop()
    r.statusLater()
  elif isPost and path.equals("/radio/volume"):
    let text = posted(body, form, "volume")
    var v = 0'u32
    if parseUint(text.chars.sub(trimmed(text.chars)), v):
      setVolume(min(v, 100).uint8)
    r.statusLater()
  elif diagRoutes and isGet and path.startsWith("/screen/stream"):
    # Screen recording: `n` consecutive frames, each captured whole (the
    # display waits for every copy), 8192 bytes apiece.
    var n = DefaultStreamFrames
    var part = 0
    for span in spans(path, '='):
      if part == 1:
        if not parseUint(path.sub(span), n): n = DefaultStreamFrames
        break
      inc part
    if ui.screen == nil or capture.on:
      r.plain("503 Service Unavailable", "not ready\n")
    else:
      r.pieces(chunkOf(StreamHead))
      r.after = sgRecording
      r.framesLeft = n
      r.frameOut = false
      r.recording = true
      r.waitSinceMs = nowMs()
      capture.snapReady = false
      capture.snapDone = false
      capture.on = true
  elif isGet and path.equals("/screen"):
    # Debug aid: the display's raw framebuffer (256x64, 4 bits per pixel,
    # left pixel in the high nibble), read in place. It may catch a frame
    # mid-draw; that is fine for a screenshot.
    if ui.screen == nil:
      r.plain("503 Service Unavailable", "not ready\n")
    else:
      r.head.clear()
      r.head.put "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n",
        "Content-Length: ", ScreenBytes,
        "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
      r.pieces(chunkOf(r.head.chars), screenChunk())
  elif diagRoutes and isPost and path.equals("/stats/reset"):
    # Restart the high/low-water marks, to measure one activity.
    resetWaterMarks()
    r.plain("200 OK", "ok\n")
  elif diagRoutes and isGet and path.equals("/stats"):
    r.stats.clear()
    statsText(r.stats)
    r.respond("200 OK", "text/plain", chunkOf(r.stats.chars))
  elif diagRoutes and diagExtra != nil and path.startsWith("/selftest/"):
    r.stats.clear()
    var blob: Chunk
    if not diagExtra(isPost, path, r.stats, blob):
      r.plain("404 Not Found", "not found\n")
    elif blob.len > 0:
      r.head.clear()
      r.head.put "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n",
        "Content-Length: ", blob.len,
        "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
      r.pieces(chunkOf(r.head.chars), blob)
    else:
      r.respond("200 OK", "text/plain", chunkOf(r.stats.chars))
  elif path.equals("/") or path.equals("/radio") or path.equals("/radio/play") or
      path.equals("/radio/stop") or path.equals("/radio/volume") or
      (diagRoutes and path.equals("/stats")):
    r.plain("405 Method Not Allowed", "method not allowed\n")
  else:
    r.plain("404 Not Found", "not found\n")

proc beginTooLarge*(r: var Reply) =
  ## The reply to a request that does not fit in `RequestMax` bytes.
  r.html = false
  r.plain("413 Payload Too Large", "request too large\n")

proc next*(r: var Reply; chunk: var Chunk): Step =
  ## The next thing to do for this reply. The previous chunk must have been
  ## sent in full before this is called again.
  while true:
    case r.stage
    of sgDone:
      return stDone
    of sgPieces:
      while r.sent < r.queued:
        chunk = r.queue[r.sent]
        inc r.sent
        if chunk.len > 0: return stSend
      r.stage = r.after
      r.after = sgDone
    of sgStatusWait:
      if nowMs() < r.readyAtMs: return stWait
      if r.html: r.seeOther()
      else: r.sendStatus()
    of sgPresetWait:
      var error: string
      if not presets.finished(r.job, error): return stWait
      r.presetReply(error)
    of sgPresetList:
      if r.slot >= Slots:
        r.pieces(chunkOf("]"))
      else:
        let p = presets.get(r.slot)
        r.piece.clear()
        if r.slot > 0: r.piece.add ','
        r.piece.add "{\"name\":"
        jsonStr(r.piece, p.name.chars)
        r.piece.add ",\"url\":"
        jsonStr(r.piece, p.url.chars)
        r.piece.add '}'
        inc r.slot
        r.pieces(chunkOf(r.piece.chars))
        r.after = sgPresetList
    of sgRecording:
      if r.frameOut:
        # The frame has gone out: let the display draw the next one.
        r.frameOut = false
        dec r.framesLeft
        capture.snapDone = true
        r.waitSinceMs = nowMs()
      if r.framesLeft == 0 or ui.screen == nil:
        r.stopRecording()
        r.stage = sgDone
      elif capture.snapReady:
        capture.snapReady = false
        r.frameOut = true
        chunk = screenChunk()
        return stSend
      elif elapsedMs(r.waitSinceMs, nowMs()) >= SnapTimeoutMs:
        r.stopRecording()
        r.stage = sgDone
      else:
        return stWait

proc finish*(r: var Reply) =
  ## The connection is over (reply complete, client gone or out of time):
  ## give back anything the reply was holding.
  r.stopRecording()
  r.stage = sgDone

# ---- One connection's exchange ---------------------------------------------------

type
  Exchange* = object
    ## A request being read and its reply being sent, over a non-blocking
    ## connection. About 3.8 KB: allocate it on the heap, once.
    replying: bool
    req: array[RequestMax, char]
    len, headLen, bodyLen: int
    reply: Reply
    chunk: Chunk
    sent: int                # bytes of `chunk` already taken by the connection

proc reset*(x: var Exchange) =
  ## Ready for a new connection.
  x.replying = false
  x.len = 0
  x.headLen = 0
  x.bodyLen = 0
  x.chunk = Chunk()
  x.sent = 0
  x.reply.stage = sgDone

proc pump*(x: var Exchange; ctx: pointer; send, recv: IoFn;
           diagRoutes = DiagEnabled): bool =
  ## Move the exchange as far as the connection allows right now: read the
  ## request, act on it, send the reply (stopping whenever the connection
  ## will not take more). True once it is over: the reply is complete or
  ## the client went away.
  while not x.replying:
    let n = recv(ctx, cast[ptr UncheckedArray[byte]](addr x.req[x.len]),
                 scanWant(x.len, x.headLen, x.bodyLen))
    if n < 0: return true
    if n == 0: return false
    x.len += n
    case scan(x.req.toOpenArray(0, x.len - 1), x.headLen, x.bodyLen)
    of scMore: discard
    of scTooLarge:
      beginTooLarge(x.reply)
      x.replying = true
    of scReady:
      begin(x.reply, x.req.toOpenArray(0, x.len - 1), x.headLen, x.bodyLen,
            diagRoutes)
      x.replying = true
  while true:
    if x.sent < x.chunk.len:
      let n = send(ctx, cast[ptr UncheckedArray[byte]](addr x.chunk.data[x.sent]),
                   x.chunk.len - x.sent)
      if n < 0: return true
      if n == 0: return false
      x.sent += n
    else:
      x.chunk = Chunk()
      x.sent = 0
      case next(x.reply, x.chunk)
      of stSend: discard
      of stWait: return false
      of stDone: return true

proc finish*(x: var Exchange) =
  finish(x.reply)
