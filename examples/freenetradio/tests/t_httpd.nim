## Host tests for the web interface (`httpd.nim`) over raw request bytes:
## every route, method errors, oversize requests, form and raw bodies, URL
## decoding, JSON escaping, deferred replies, the stats format, screen
## recording, and a dribbling / back-pressured connection.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_httpd.nim

import std/[strutils, osproc, os, streams]
import ../httpd, ../text, ../timebase, ../status, ../presets, ../remote,
       ../flashdev, ../board, ../ui, ../diag, ../menu, ../about, ../webpage,
       ../netio

# ---- A RAM flash for the presets ---------------------------------------------

const StoreBytes = StoreSectors * FlashSector

var
  flashMem = newSeq[byte](StoreBytes)
  flashFail = false          # make the next program fail

proc ramRead(ctx: pointer; offset: uint32; buf: var openArray[byte]) {.nimcall.} =
  for i in 0 ..< buf.len: buf[i] = flashMem[offset.int + i]

proc ramErase(ctx: pointer; offset: uint32): bool {.nimcall.} =
  for i in 0 ..< FlashSector: flashMem[offset.int + i] = 0xFF
  true

proc ramProgram(ctx: pointer; offset: uint32; data: openArray[byte]): FlashStatus {.nimcall.} =
  if flashFail:
    flashFail = false
    return fsWriteFailed
  for i in 0 ..< data.len:
    flashMem[offset.int + i] = flashMem[offset.int + i] and data[i]
  fsOk

proc freshRadio() =
  ## Everything back to power-on state with blank flash, at t = 1000 s.
  for b in flashMem.mitems: b = 0xFF
  flashFail = false
  setFakeTimeUs(1_000_000_000)
  diagInit()
  statusInit()
  menuInit()
  remoteInit()
  presetsInit(FlashDev(read: ramRead, eraseSector: ramErase, program: ramProgram))
  ui.screen = nil
  ui.capture = Capture()
  ui.osd = Osd()
  stackUsage = nil

# ---- Driving a request -----------------------------------------------------------

type Exchanged = object
  raw: string          ## everything the server sent
  waitedMs: int        ## fake time that passed while the reply was deferred
  complete: bool       ## the request was complete (or too large) and answered

var whileWaiting: proc() = nil
  ## Stands in for the other tasks while a reply is deferred.

proc exchange(request: string; diagRoutes = false; limitMs = 10_000): Exchanged =
  var r = create(Reply)
  defer: dealloc(r)
  var headLen, bodyLen = 0
  case scan(request, headLen, bodyLen)
  of scMore: return
  of scTooLarge: beginTooLarge(r[])
  of scReady: begin(r[], request, headLen, bodyLen, diagRoutes)
  result.complete = true
  var chunk: Chunk
  while true:
    case next(r[], chunk)
    of stSend:
      doAssert chunk.len > 0
      let at = result.raw.len
      result.raw.setLen at + chunk.len
      copyMem(addr result.raw[at], chunk.data, chunk.len)
    of stWait:
      doAssert result.waitedMs < limitMs, "the reply never came"
      if whileWaiting != nil: whileWaiting()
      advanceFakeTimeMs(1)
      inc result.waitedMs
    of stDone:
      break
  finish(r[])

proc statusLine(x: Exchanged): string = x.raw[0 ..< x.raw.find("\r\n")]
proc head(x: Exchanged): string = x.raw[0 ..< x.raw.find("\r\n\r\n") + 4]
proc body(x: Exchanged): string = x.raw[x.raw.find("\r\n\r\n") + 4 .. ^1]

proc get(path: string; diagRoutes = false): Exchanged =
  exchange("GET " & path & " HTTP/1.1\r\nHost: radio\r\n\r\n", diagRoutes)

proc post(path: string; body = ""; contentType = ""; accept = "";
          diagRoutes = false): Exchanged =
  var req = "POST " & path & " HTTP/1.1\r\nHost: radio\r\n"
  if contentType.len > 0: req.add "Content-Type: " & contentType & "\r\n"
  if accept.len > 0: req.add "Accept: " & accept & "\r\n"
  req.add "Content-Length: " & $body.len & "\r\n\r\n" & body
  exchange(req, diagRoutes)

const
  Form = "application/x-www-form-urlencoded"
  BrowserAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

proc plainHead(status: string; length: int; contentType = "text/plain"): string =
  ## Upstream's `respond` head.
  "HTTP/1.1 " & status & "\r\nContent-Type: " & contentType &
    "\r\nContent-Length: " & $length &
    "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"

const SeeOther = "HTTP/1.1 303 See Other\r\nContent-Type: text/plain\r\n" &
  "Content-Length: 3\r\nCache-Control: no-store\r\nConnection: close\r\n" &
  "Location: /\r\n\r\nok\n"

proc checkPlain(x: Exchanged; status, text: string) =
  doAssert x.raw == plainHead(status, text.len) & text, x.raw

const StoppedJson = "{\"state\":\"stopped\",\"message\":\"\",\"url\":\"\"," &
  "\"station\":\"\",\"title\":\"\",\"sample_rate\":0,\"bitrate\":0," &
  "\"channels\":0,\"buffer\":0,\"underruns\":0,\"volume\":10,\"muted\":false}"

proc pumpPresets() = presets.poll()

# ---- Helpers ---------------------------------------------------------------------

block: # parsing helpers
  var v: Slice[int]
  let h = "GET / HTTP/1.1\r\nHost: x\r\ncontent-LENGTH: 12 \r\nAccept: a\r\nX: 1\n\r\n"
  doAssert header(h, "content-length", v) and h[v] == " 12 "
  doAssert header(h, "x", v) and h[v] == " 1"          # bare LF line
  doAssert not header(h, "missing", v)
  doAssert not header("Host: x\r\n\r\n", "host", v)     # the first line is the request line
  doAssert header("G\r\nA:1\r\nA:2\r\n", "a", v) and "G\r\nA:1\r\nA:2\r\n"[v] == "1"
  doAssert header("G\r\nno colon\r\nb:\r\n", "B", v) and v.len == 0

  doAssert acceptsHtml("GET / HTTP/1.1\r\nACCEPT: x, Text/HTML;q=1\r\n\r\n")
  doAssert not acceptsHtml("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n")
  doAssert not acceptsHtml("GET /text/html HTTP/1.1\r\nX-Accept: text/html\r\n\r\n")
  doAssert not acceptsHtml("Accept: text/html\r\n\r\n")  # request line is skipped
  doAssert not acceptsHtml("G\r\nAccept:\r\n")

  let b = "a=1&name=Soma+FM&url=http%3A%2F%2Fx&empty=&novalue"
  doAssert formField(b, "name", v) and b[v] == "Soma+FM"
  doAssert formField(b, "url", v) and b[v] == "http%3A%2F%2Fx"
  doAssert formField(b, "empty", v) and v.len == 0
  doAssert not formField(b, "novalue", v) and not formField(b, "nam", v)
  doAssert formField("x=1&x=2", "x", v) and "x=1&x=2"[v] == "1"

  proc decoded(s: string): string =
    var t: Text[256]
    urlDecode(s, t)
    $t
  doAssert decoded("a+b%20c%2fd%2Fe") == "a b c/d/e"
  doAssert decoded("100%") == "100%" and decoded("%4") == "%4" and decoded("%zz1") == "%zz1"
  doAssert decoded("%C3%A9") == "\xC3\xA9"
  doAssert decoded("%FF") == ""                       # not UTF-8: nothing
  doAssert decoded("%41%") == "A%"
  doAssert decoded(repeat('a', 300)).len == 256         # 256 bytes at most
  var small: Text[4]
  urlDecode("a%C3%A9%C3%A9", small)                     # cut at a character boundary
  doAssert $small == "a\xC3\xA9"

  doAssert validUtf8("") and validUtf8("abc\xE2\x82\xAC\xF0\x9F\x8E\xB5")
  for bad in ["\x80", "\xC0\xAF", "\xC3", "\xE0\x80\x80", "\xED\xA0\x80",
              "\xF4\x90\x80\x80", "\xF8\x88\x80\x80\x80", "a\xE2\x82"]:
    doAssert not validUtf8(bad), bad.toHex

  var n = 0'u32
  doAssert parseUint("0", n) and n == 0
  doAssert parseUint("+42", n) and n == 42
  doAssert parseUint("007", n) and n == 7
  doAssert parseUint("4294967295", n) and n == high(uint32)
  for bad in ["", "+", "-1", "4294967296", "12a", " 1", "1 ", "0x10", "99999999999999999999"]:
    doAssert not parseUint(bad, n), bad

  proc trim(s: string): string = s[trimmed(s)]
  doAssert trim("  a b \t\r\n") == "a b" and trim("") == "" and trim(" \n ") == ""
  doAssert trim("\xC2\xA0x\xE2\x80\x83\xE3\x80\x80") == "x"   # NBSP, EM SPACE, IDEOGRAPHIC SPACE
  doAssert trim("\xC3\xA9 ") == "\xC3\xA9"

  var j: Text[64]
  jsonStr(j, "a\"b\\c/d")
  doAssert $j == "\"a\\\"b\\\\c/d\""

block: # scan
  var headLen, bodyLen = 0
  doAssert scan("", headLen, bodyLen) == scMore
  doAssert scan("GET / HTTP/1.1\r\nHost: x\r\n", headLen, bodyLen) == scMore
  doAssert headLen == 0 and scanWant(26, headLen, bodyLen) == RequestMax - 26
  let g = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
  doAssert scan(g, headLen, bodyLen) == scReady and headLen == g.len and bodyLen == 0
  let p = "POST /radio/volume HTTP/1.1\r\nContent-Length:  5 \r\n\r\n"
  doAssert scan(p & "12", headLen, bodyLen) == scMore
  doAssert headLen == p.len and bodyLen == 5 and scanWant(p.len + 2, headLen, bodyLen) == 3
  doAssert scan(p & "12345", headLen, bodyLen) == scReady
  doAssert scan(p & "12345extra", headLen, bodyLen) == scReady and bodyLen == 5
  # An unparsable length counts as no body.
  doAssert scan("POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n", headLen, bodyLen) == scReady
  doAssert bodyLen == 0
  doAssert scan("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", headLen, bodyLen) == scReady
  # Exactly the limit fits; one more byte of body does not.
  let lead = "POST /radio/play HTTP/1.1\r\nContent-Length: "
  let room = RequestMax - (lead.len + 3 + 4)
  let fits = lead & $room & "\r\n\r\n" & repeat('u', room)
  doAssert fits.len == RequestMax and scan(fits, headLen, bodyLen) == scReady
  doAssert scan(lead & $(room + 1) & "\r\n\r\n", headLen, bodyLen) == scTooLarge
  doAssert scan(lead & "4294967295\r\n\r\n", headLen, bodyLen) == scTooLarge
  # A head that does not end within the buffer.
  doAssert scan("GET / HTTP/1.1\r\nX: " & repeat('x', RequestMax - 20), headLen, bodyLen) == scMore
  doAssert scan("GET / HTTP/1.1\r\nX: " & repeat('x', RequestMax - 19), headLen, bodyLen) == scTooLarge

# ---- Routes ----------------------------------------------------------------------

block: # GET /
  freshRadio()
  let x = get("/")
  doAssert x.head == "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" &
    "Content-Encoding: gzip\r\nContent-Length: " & $PageGz.len &
    "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
  doAssert x.body == PageGz and x.waitedMs == 0
  # The page is upstream's, byte for byte, once unpacked.
  let gz = getTempDir() / "t_httpd_page.gz"
  writeFile(gz, x.body)
  let p = startProcess("gzip", args = ["-dc", gz], options = {poUsePath})
  let page = p.outputStream.readAll()
  doAssert p.waitForExit() == 0
  p.close()
  removeFile(gz)
  doAssert page == readFile(currentSourcePath().parentDir.parentDir / "index.html")
  doAssert "<title>" in page

block: # GET /radio and JSON escaping
  freshRadio()
  let x = get("/radio")
  doAssert x.raw == plainHead("200 OK", StoppedJson.len, "application/json") & StoppedJson
  doAssert x.waitedMs == 0

  player.phase = phPlaying
  player.message.set "say \"hi\" \\ bye"
  player.url.set "http://example.com/a?b=\"c\""
  player.station.set "Groove Salad: a nicely chilled plate"
  player.title.set "Artist - Song \\o/"
  player.sampleRate = 44100
  player.bitrate = 128
  player.channels = 2
  player.bufferPct = 97
  player.underruns = 3
  player.volume = 0
  player.muted = true
  doAssert get("/radio").body ==
    "{\"state\":\"playing\",\"message\":\"say \\\"hi\\\" \\\\ bye\"," &
    "\"url\":\"http://example.com/a?b=\\\"c\\\"\"," &
    "\"station\":\"Groove Salad: a nicely chilled plate\"," &
    "\"title\":\"Artist - Song \\\\o/\",\"sample_rate\":44100,\"bitrate\":128," &
    "\"channels\":2,\"buffer\":97,\"underruns\":3,\"volume\":0,\"muted\":true}"
  for (phase, name) in [(phStopped, "stopped"), (phConnecting, "connecting"),
                        (phBuffering, "buffering"), (phError, "error"),
                        (phOffline, "offline")]:
    player.phase = phase
    doAssert get("/radio").body.startsWith("{\"state\":\"" & name & "\",")

  # The JSON buffer is 1024 bytes: a status full of quotes is cut there.
  player.url.set repeat('"', 256)
  player.station.set repeat('"', 128)
  player.title.set repeat('\\', 128)
  let cut = get("/radio")
  doAssert cut.body.len == 1024
  doAssert "Content-Length: 1024\r\n" in cut.head

block: # POST /radio/play
  freshRadio()
  # Raw body, as `curl --data-binary` with text/plain.
  var x = post("/radio/play", "  http://ice1.somafm.com/groovesalad-128-mp3\r\n", "text/plain")
  doAssert x.waitedMs == 20, $x.waitedMs
  doAssert $player.url == "http://ice1.somafm.com/groovesalad-128-mp3"
  doAssert takeCommand() == cmdPlay
  doAssert x.statusLine == "HTTP/1.1 200 OK" and "Content-Type: application/json\r\n" in x.head
  doAssert "\"url\":\"http://ice1.somafm.com/groovesalad-128-mp3\"" in x.body

  # The status is built after the 20 ms, so it shows what the stream task did.
  whileWaiting = proc() =
    if takeCommand() == cmdPlay: setPhase(phConnecting, "")
  x = post("/radio/play", "url=http%3A%2F%2Fexample.com%2Flive+one.mp3&x=1", Form)
  whileWaiting = nil
  doAssert $player.url == "http://example.com/live one.mp3"
  doAssert x.body.startsWith("{\"state\":\"connecting\",")

  # A form body without the field is taken whole (`curl --data <url>`).
  discard post("/radio/play", "http://example.com/raw", Form)
  doAssert $player.url == "http://example.com/raw"
  # A field named url in a body that is not declared a form is not decoded.
  discard post("/radio/play", "url=http%3A%2F%2Fa", "text/plain")
  doAssert $player.url == "url=http%3A%2F%2Fa"
  # The content type is matched anywhere in the header, in any case.
  discard post("/radio/play", "url=http%3A%2F%2Fb", "Application/X-WWW-Form-Urlencoded; charset=UTF-8")
  doAssert $player.url == "http://b"
  # No body, and a body that is not UTF-8, play an empty URL.
  discard post("/radio/play")
  doAssert player.url.isEmpty and takeCommand() == cmdPlay
  discard post("/radio/play", "http://x/\xFF")
  doAssert player.url.isEmpty
  # At most 256 bytes are kept.
  discard post("/radio/play", "http://x/" & repeat('a', 400))
  doAssert player.url.len == 256

  # A browser form submit is redirected to the page.
  discard takeCommand()
  x = post("/radio/play", "url=http%3A%2F%2Fc", Form, BrowserAccept)
  doAssert x.raw == SeeOther and x.waitedMs == 20
  doAssert $player.url == "http://c" and takeCommand() == cmdPlay

block: # POST /radio/stop
  freshRadio()
  var x = post("/radio/stop")
  doAssert takeCommand() == cmdStop and x.waitedMs == 20
  doAssert x.raw == plainHead("200 OK", StoppedJson.len, "application/json") & StoppedJson
  x = post("/radio/stop", accept = BrowserAccept)
  doAssert x.raw == SeeOther and takeCommand() == cmdStop
  # A POST without Content-Length.
  x = exchange("POST /radio/stop HTTP/1.0\r\n\r\n")
  doAssert x.statusLine == "HTTP/1.1 200 OK" and takeCommand() == cmdStop

block: # POST /radio/volume
  freshRadio()
  var x = post("/radio/volume", "35")
  doAssert player.volume == 35 and not player.muted and x.waitedMs == 20
  doAssert "\"volume\":35,\"muted\":false}" in x.body
  discard post("/radio/volume", "volume=+7+", Form)        # "+" decodes to a space
  doAssert player.volume == 7
  discard post("/radio/volume", " 250\n")
  doAssert player.volume == 100
  discard post("/radio/volume", "0")
  doAssert player.volume == 0 and player.muted
  discard post("/radio/volume", "+12")
  doAssert player.volume == 12 and not player.muted
  for ignored in ["", "loud", "-5", "1.5", "4294967296", "volume=9"]:
    x = post("/radio/volume", ignored)
    doAssert player.volume == 12, ignored
    doAssert x.statusLine == "HTTP/1.1 200 OK"               # still answers with the status
  x = post("/radio/volume", "volume=40", Form, BrowserAccept)
  doAssert x.raw == SeeOther and player.volume == 40

block: # GET /presets
  freshRadio()
  let x = get("/presets")
  doAssert x.head == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
    "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
  doAssert "Content-Length" notin x.head
  var expected = "["
  for i in 0 ..< Slots:
    if i > 0: expected.add ','
    let p = presets.get(i)
    expected.add "{\"name\":\"" & $p.name & "\",\"url\":\"" & $p.url & "\"}"
  expected.add ']'
  doAssert x.body == expected
  doAssert x.body.startsWith("[{\"name\":\"Groove Salad\",\"url\":\"http://ice1.somafm.com/groovesalad-128-mp3\"},")
  doAssert x.body.endsWith(",{\"name\":\"\",\"url\":\"\"}]")
  doAssert x.body.count("{\"name\":") == 99

block: # POST /presets/<n>
  freshRadio()
  whileWaiting = pumpPresets
  # The first save rewrites the ten defaults, 50 ms apart: the reply waits.
  var x = post("/presets/12", "name=+My+%22Radio%22+&url=http%3A%2F%2Fexample.com%2Fa%5Cb+", Form)
  x.checkPlain("200 OK", "ok\n")
  doAssert x.waitedMs >= 450, $x.waitedMs
  doAssert not presets.busy()
  doAssert $presets.get(11).name == "My \"Radio\"" and $presets.get(11).url == "http://example.com/a\\b"
  doAssert $presets.get(0).name == "Groove Salad"
  let listed = get("/presets").body
  doAssert ",{\"name\":\"My \\\"Radio\\\"\",\"url\":\"http://example.com/a\\\\b\"}," in listed

  # Later saves are one page; a browser is redirected.
  x = post("/presets/1", "url=http%3A%2F%2Fone&name=One", Form, BrowserAccept)
  doAssert x.raw == SeeOther and x.waitedMs < 50
  doAssert $presets.get(0).name == "One" and $presets.get(0).url == "http://one"
  # The fields are read from the body whatever the content type says.
  x = post("/presets/99", "name=Last&url=http://last")
  x.checkPlain("200 OK", "ok\n")
  doAssert $presets.get(98).url == "http://last"
  # An empty URL clears the slot; so does a missing one.
  x = post("/presets/99", "name=Gone&url=", Form)
  x.checkPlain("200 OK", "ok\n")
  doAssert presets.get(98).isEmpty
  discard post("/presets/1", "", Form)
  doAssert presets.get(0).isEmpty
  # Names and URLs are cut to what a slot holds.
  discard post("/presets/2", "name=" & repeat('n', 40) & "&url=http://x/" & repeat('u', 240), Form)
  doAssert presets.get(1).name.len == NameMax and presets.get(1).url.len == UrlMax

  for bad in ["/presets/0", "/presets/100", "/presets/", "/presets/abc", "/presets/-1",
              "/presets/1/", "/presets/1x", "/presets/4294967297"]:
    x = post(bad, "name=a&url=http://a", Form)
    x.checkPlain("500 Internal Server Error", "No such preset\n")
  doAssert not presets.busy()
  x = post("/presets/+5", "name=Five&url=http://five", Form)     # Rust's parse takes a leading +
  x.checkPlain("200 OK", "ok\n")
  doAssert $presets.get(4).name == "Five"

  # A failed flash write is reported, also to a browser.
  flashFail = true
  x = post("/presets/3", "name=a&url=http://a", Form, BrowserAccept)
  x.checkPlain("500 Internal Server Error", "Flash write failed\n")

  # While another save is running (upstream: two web tasks at once): the
  # request waits its turn, then both have taken effect.
  doAssert presets.startSave(5, "first", "http://first") == ""
  x = post("/presets/7", "name=second&url=http://second", Form)
  x.checkPlain("200 OK", "ok\n")
  doAssert not presets.busy()
  doAssert $presets.get(5).url == "http://first" and $presets.get(6).url == "http://second"
  # Each reply reports its own save, not whichever finished last.
  flashFail = true                        # the next flash write, i.e. the one below
  doAssert presets.startSave(7, "fails", "http://fails") == ""
  x = post("/presets/9", "name=works&url=http://works", Form)
  x.checkPlain("200 OK", "ok\n")
  doAssert presets.get(7).isEmpty and $presets.get(8).url == "http://works"
  # Straight after "reset to defaults": saved on top of the built-in list.
  doAssert presets.startReset() == ""
  x = post("/presets/2", "name=Mine&url=http://mine", Form)
  x.checkPlain("200 OK", "ok\n")
  doAssert $presets.get(1).name == "Mine" and $presets.get(0).name == "Groove Salad"
  doAssert presets.get(11).isEmpty and $presets.get(5).name == "Indie Pop Rocks"
  whileWaiting = nil

block: # POST /presets/reset
  freshRadio()
  whileWaiting = pumpPresets
  discard post("/presets/20", "name=Twenty&url=http://twenty", Form)
  discard post("/presets/1", "name=One&url=http://one", Form)
  doAssert $presets.get(19).name == "Twenty" and $presets.get(0).name == "One"
  var x = post("/presets/reset")
  x.checkPlain("200 OK", "ok\n")
  doAssert not presets.busy()
  doAssert $presets.get(0).name == "Groove Salad" and presets.get(19).isEmpty
  x = post("/presets/reset", accept = BrowserAccept)
  doAssert x.raw == SeeOther
  doAssert get("/presets/reset").statusLine == "HTTP/1.1 404 Not Found"
  whileWaiting = nil

block: # POST /presets/<n>/play
  freshRadio()
  var x = post("/presets/2/play")
  x.checkPlain("200 OK", "ok\n")
  doAssert x.waitedMs == 0
  doAssert $player.url == "http://ice1.somafm.com/dronezone-128-mp3" and takeCommand() == cmdPlay
  doAssert $ui.osd.lines[0] == "2 Drone Zone"
  x = post("/presets/10/play", accept = BrowserAccept)
  doAssert x.raw == SeeOther and $player.url == "http://ice1.somafm.com/u80s-128-mp3"
  discard takeCommand()
  # An empty slot is still "ok": the display says it is empty.
  x = post("/presets/50/play")
  x.checkPlain("200 OK", "ok\n")
  doAssert takeCommand() == cmdNone and $ui.osd.lines[0] == "Preset 50 is empty"
  for bad in ["/presets/0/play", "/presets/100/play", "/presets//play", "/presets/x/play",
              "/presets/play", "/presets/1/2/play"]:
    x = post(bad)
    x.checkPlain("500 Internal Server Error", "No such preset\n")
  doAssert takeCommand() == cmdNone
  doAssert get("/presets/2/play").statusLine == "HTTP/1.1 404 Not Found"

block: # POST /remote/<key>
  freshRadio()
  var x = post("/remote/up")
  doAssert player.volume == 11 and x.waitedMs == 20
  doAssert x.statusLine == "HTTP/1.1 200 OK" and "\"volume\":11," in x.body
  x = post("/remote/down", accept = BrowserAccept)
  doAssert x.raw == SeeOther and player.volume == 10
  # A held button: repeats count once it has been held for 0.4 s.
  discard post("/remote/up")
  discard post("/remote/up?repeat")
  doAssert player.volume == 11
  advanceFakeTimeMs(400)
  discard post("/remote/up?repeat")
  doAssert player.volume == 12
  # Only exactly "?repeat" is a repeat; anything else is a fresh press.
  discard post("/remote/up?repeat=1")
  doAssert player.volume == 13
  discard post("/remote/star")
  doAssert player.muted
  discard post("/remote/star")
  doAssert not player.muted
  # Every button of the virtual remote exists.
  for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "star", "hash",
              "up", "down", "left", "right", "ok"]:
    freshRadio()
    doAssert post("/remote/" & key).statusLine == "HTTP/1.1 200 OK", key
  freshRadio()
  discard post("/remote/hash")
  doAssert menu.isOpen()
  discard post("/remote/hash")
  doAssert not menu.isOpen()
  discard post("/remote/ok")                 # nothing selected: plays preset 1
  doAssert takeCommand() == cmdPlay and $player.url == "http://ice1.somafm.com/groovesalad-128-mp3"
  discard post("/remote/4")
  discard post("/remote/2")                  # two digits: preset 42 (empty)
  doAssert $ui.osd.lines[0] == "Preset 42 is empty"
  for bad in ["/remote/", "/remote/OK", "/remote/volume", "/remote/?repeat", "/remote/up/"]:
    x = post(bad)
    x.checkPlain("404 Not Found", "no such button\n")
    doAssert x.waitedMs == 0
  doAssert get("/remote/ok").statusLine == "HTTP/1.1 404 Not Found"

block: # GET /licenses
  freshRadio()
  let x = get("/licenses")
  doAssert x.raw == plainHead("200 OK", LicensesText.len, "text/plain; charset=utf-8") & LicensesText
  var lines = 0
  for line in x.body.splitLines:
    if line.len == 0: continue
    doAssert line.count('|') == 2, line       # name|author|license
    inc lines
  doAssert lines == about.count() and x.body.endsWith("\n")

block: # GET /screen
  freshRadio()
  get("/screen").checkPlain("503 Service Unavailable", "not ready\n")
  var fb = create(array[ScreenBytes, byte])
  for i in 0 ..< ScreenBytes: fb[i] = byte(i * 7)
  ui.screen = fb
  let x = get("/screen")
  doAssert x.head == "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" &
    "Content-Length: 8192\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
  doAssert x.body.len == 8192
  for i in 0 ..< ScreenBytes: doAssert x.body[i].byte == fb[i]
  ui.screen = nil
  dealloc(fb)

block: # method and path errors
  freshRadio()
  for path in ["/", "/radio"]:
    for verb in ["POST", "PUT", "DELETE", "HEAD", "get"]:
      exchange(verb & " " & path & " HTTP/1.1\r\n\r\n")
        .checkPlain("405 Method Not Allowed", "method not allowed\n")
  for path in ["/radio/play", "/radio/stop", "/radio/volume"]:
    for verb in ["GET", "PUT", "post"]:
      exchange(verb & " " & path & " HTTP/1.1\r\n\r\n")
        .checkPlain("405 Method Not Allowed", "method not allowed\n")
  doAssert takeCommand() == cmdNone
  for (verb, path) in [("GET", "/nope"), ("GET", "/index.html"), ("GET", "/?x=1"),
                       ("GET", "/radio/"), ("GET", "/radio?x"), ("POST", "/presets"),
                       ("PUT", "/presets"), ("PUT", "/presets/1"), ("POST", "/licenses"),
                       ("POST", "/screen"), ("DELETE", "/remote/ok"), ("GET", ""),
                       ("GET", "/stats"), ("POST", "/stats"), ("POST", "/stats/reset"),
                       ("GET", "/screen/stream"), ("GET", "/screen/stream?n=3")]:
    exchange(verb & " " & path & " HTTP/1.1\r\n\r\n").checkPlain("404 Not Found", "not found\n")
  # Odd request lines do not upset it.
  exchange("\r\n\r\n").checkPlain("404 Not Found", "not found\n")
  exchange("GET\r\n\r\n").checkPlain("404 Not Found", "not found\n")
  exchange("GET  / HTTP/1.1\r\n\r\n").checkPlain("404 Not Found", "not found\n")   # empty path word
  doAssert exchange("GET /\r\n\r\n").statusLine == "HTTP/1.1 200 OK"   # no version: still GET /

block: # oversize requests
  freshRadio()
  var x = exchange("GET / HTTP/1.1\r\nCookie: " & repeat('c', RequestMax) & "\r\n\r\n")
  x.checkPlain("413 Payload Too Large", "request too large\n")
  x = exchange("POST /radio/play HTTP/1.1\r\nContent-Length: 2000\r\n\r\nhttp://x")
  x.checkPlain("413 Payload Too Large", "request too large\n")
  doAssert takeCommand() == cmdNone
  x = exchange("POST /presets/1 HTTP/1.1\r\nAccept: text/html\r\nContent-Length: 1024\r\n\r\n")
  x.checkPlain("413 Payload Too Large", "request too large\n")       # never a redirect
  doAssert not exchange("GET / HTTP/1.1\r\nHost: x\r\n").complete     # still waiting for the head
  doAssert not exchange("POST /radio/play HTTP/1.1\r\nContent-Length: 9\r\n\r\nhttp").complete

# ---- Diagnostics -----------------------------------------------------------------

proc fakeStack(unused, total: var int) {.nimcall.} =
  unused = 5120
  total = 8192

block: # /stats
  freshRadio()
  # Without the diag routes it does not exist (checked above too).
  get("/stats").checkPlain("404 Not Found", "not found\n")

  var x = get("/stats", diagRoutes = true)
  doAssert x.statusLine == "HTTP/1.1 200 OK" and "Content-Type: text/plain\r\n" in x.head
  doAssert "Content-Length: " & $x.body.len & "\r\n" in x.head
  doAssert x.body ==
    "stack: 0 of 0 bytes never used\n" &
    "uptime: 1000 s\n" &
    "frame gap: 0-0 ms\n" &
    "decode per frame: avg 0 us, max 0 us\n" &
    "underruns: 0\n" &
    "rx ring overflows: 0\n" &
    "stream bytes in: 0\n" &
    "audio loops: 0\n" &
    "display frames: 0 (stage 0), flush timeouts: 0, overlay draw max: 0 us\n" &
    "DAC queue low-water: 4294967295 frames, audio loop max gap: 0 us\n" &
    "ir: last code none, frames 0, errors 0\n" &
    "tls handshake: 0 ms, longest read 0 us, last error 0, stage 0, at error: tcp rx 0 tx 0, tls decoded 0 pending 0\n" &
    "reconnects: 0, network outages: 0\n" &
    "settings saves: 0, failed 0 ()\n" &
    "last underrun (ms, kind, buffered, queued): 0 0 0 0\n" &
    "spectrum dB (bands 0 10 20 30 39): 0 0 0 0 0\n" &
    "i2s underruns: 0, dma errors: 0\n" &
    "decode errors (noframe, reservoir, corrupt, other): 0 0 0 0\n" &
    "wifi reconnects: 0\n", x.body

  stackUsage = fakeStack
  advanceFakeTimeMs(234_999)
  player.decodeAvgUs = 4100
  player.decodeMaxUs = 9000
  player.underruns = 2
  stats = Diag(
    connectStage: 6, streamBytes: 123456, reconnects: 3, outages: 1,
    tlsHandshakeMs: 850, tlsReadMaxUs: 4200, tlsLastError: -0x7780,
    failInfo: [11'u32, 22, 33, 44], audioLoops: 777, minQueued: 1500,
    maxLoopGapUs: 31000, decodeErrors: [1'u32, 2, 3, 4],
    underrunInfo: [5000'u32, 2, 37, 400], i2sUnderruns: 9, dmaErrors: 8,
    spectrumDb: [-12'i16, -30, -45, -60, -71], displayFrames: 4321,
    displayStage: 3, flushTimeouts: 1, overlayMaxUs: 650, frameGapMinMs: 19,
    frameGapMaxMs: 23, irLastCode: 0x0045, irFrames: 12, irErrors: 2,
    settingsSaves: 5, settingsFailures: 1, settingsLastError: "Flash write failed",
    wifiReconnects: 4)
  let full =
    "stack: 5120 of 8192 bytes never used\n" &
    "uptime: 1234 s\n" &
    "frame gap: 19-23 ms\n" &
    "decode per frame: avg 4100 us, max 9000 us\n" &
    "underruns: 2\n" &
    "rx ring overflows: 0\n" &
    "stream bytes in: 123456\n" &
    "audio loops: 777\n" &
    "display frames: 4321 (stage 3), flush timeouts: 1, overlay draw max: 650 us\n" &
    "DAC queue low-water: 1500 frames, audio loop max gap: 31000 us\n" &
    "ir: last code addr 0x00 cmd 0x45, frames 12, errors 2\n" &
    "tls handshake: 850 ms, longest read 4200 us, last error -30592, stage 6, at error: tcp rx 11 tx 22, tls decoded 33 pending 44\n" &
    "reconnects: 3, network outages: 1\n" &
    "settings saves: 5, failed 1 (Flash write failed)\n" &
    "last underrun (ms, kind, buffered, queued): 5000 2 37 400\n" &
    "spectrum dB (bands 0 10 20 30 39): -12 -30 -45 -60 -71\n" &
    "i2s underruns: 9, dma errors: 8\n" &
    "decode errors (noframe, reservoir, corrupt, other): 1 2 3 4\n" &
    "wifi reconnects: 4\n"
  x = get("/stats", diagRoutes = true)
  doAssert x.body == full, x.body
  # Reading restarted the "since last read" marks, and only those.
  doAssert stats.frameGapMinMs == high(uint32) and stats.frameGapMaxMs == 0
  doAssert stats.minQueued == high(uint32) and stats.maxLoopGapUs == 0
  doAssert stats.tlsReadMaxUs == 0 and player.decodeMaxUs == 0
  doAssert stats.overlayMaxUs == 650 and stats.streamBytes == 123456
  x = get("/stats", diagRoutes = true)
  doAssert "frame gap: 0-0 ms\n" in x.body and ", max 0 us\n" in x.body
  doAssert "low-water: 4294967295 frames, audio loop max gap: 0 us\n" in x.body
  doAssert "longest read 0 us" in x.body

  # An extended NEC address prints in full.
  stats.irLastCode = 0xBF00'u32 shl 8 or 0x0D
  doAssert "ir: last code addr 0xBF00 cmd 0x0D," in get("/stats", diagRoutes = true).body
  stats.irLastCode = 0x1A'u32 shl 8 or 0xFF
  doAssert "ir: last code addr 0x1A cmd 0xFF," in get("/stats", diagRoutes = true).body

  # The buffer is upstream's 960 bytes: every counter at its maximum is cut
  # there (from the end), never overrun.
  stats = Diag(
    connectStage: high(uint32), streamBytes: high(uint32), reconnects: high(uint32),
    outages: high(uint32), tlsHandshakeMs: high(uint32), tlsReadMaxUs: high(uint32),
    tlsLastError: low(int32), failInfo: [high(uint32), high(uint32), high(uint32), high(uint32)],
    audioLoops: high(uint32), minQueued: high(uint32), maxLoopGapUs: high(uint32),
    decodeErrors: [high(uint32), high(uint32), high(uint32), high(uint32)],
    underrunInfo: [high(uint32), high(uint32), high(uint32), high(uint32)],
    i2sUnderruns: high(uint32), dmaErrors: high(uint32),
    spectrumDb: [low(int16), low(int16), low(int16), low(int16), low(int16)],
    displayFrames: high(uint32), displayStage: high(uint32), flushTimeouts: high(uint32),
    overlayMaxUs: high(uint32), frameGapMinMs: high(uint32) - 1, frameGapMaxMs: high(uint32),
    irLastCode: 0xFFFF_FF'u32, irFrames: high(uint32), irErrors: high(uint32),
    settingsSaves: high(uint32), settingsFailures: high(uint32),
    settingsLastError: "Flash verify failed", wifiReconnects: high(uint32))
  player.decodeAvgUs = high(uint32)
  player.decodeMaxUs = high(uint32)
  player.underruns = high(uint32)
  x = get("/stats", diagRoutes = true)
  doAssert x.body.len == 960 and "Content-Length: 960\r\n" in x.head, $x.body.len
  doAssert "spectrum dB (bands 0 10 20 30 39): -32768 -32768 -32768 -32768 -32768\n" in x.body

  # POST /stats/reset restarts the water marks.
  stats.minQueued = 12
  stats.maxLoopGapUs = 34
  stats.overlayMaxUs = 56
  post("/stats/reset", diagRoutes = true).checkPlain("200 OK", "ok\n")
  doAssert stats.minQueued == high(uint32) and stats.maxLoopGapUs == 0 and stats.overlayMaxUs == 0
  post("/stats", diagRoutes = true).checkPlain("405 Method Not Allowed", "method not allowed\n")
  get("/stats/reset", diagRoutes = true).checkPlain("404 Not Found", "not found\n")

block: # GET /screen/stream
  freshRadio()
  get("/screen/stream", diagRoutes = true).checkPlain("503 Service Unavailable", "not ready\n")
  doAssert not capture.on

  var fb = create(array[ScreenBytes, byte])
  ui.screen = fb
  # A display that finishes a frame every 20 ms and waits for it to be copied.
  var frame = 0
  var sinceFrame = 0
  var waitingForCopy = false
  whileWaiting = proc() =
    if not capture.on: return
    if waitingForCopy:
      if not capture.snapDone: return
      capture.snapDone = false
      waitingForCopy = false
      sinceFrame = 0
    inc sinceFrame
    if sinceFrame >= 20:
      inc frame
      for i in 0 ..< ScreenBytes: fb[i] = byte(frame)
      capture.snapReady = true
      waitingForCopy = true

  const Head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" &
    "Connection: close\r\n\r\n"
  var x = get("/screen/stream?n=3", diagRoutes = true)
  doAssert x.head == Head and x.body.len == 3 * ScreenBytes
  for k in 0 ..< 3:
    # Each frame whole: the display did not draw while it went out.
    for i in 0 ..< ScreenBytes:
      doAssert x.body[k * ScreenBytes + i].byte == byte(k + 1)
  doAssert not capture.on and capture.snapDone       # the display is released
  doAssert x.waitedMs >= 60 and x.waitedMs < 100

  # Without n (or with a bad one) it records 100 frames.
  frame = 0
  capture = Capture()
  waitingForCopy = false
  x = get("/screen/stream", diagRoutes = true)
  doAssert x.body.len == 100 * ScreenBytes
  frame = 0
  capture = Capture()
  waitingForCopy = false
  x = get("/screen/stream?n=lots", diagRoutes = true)
  doAssert x.body.len == 100 * ScreenBytes
  capture = Capture()
  waitingForCopy = false
  x = get("/screen/stream?n=0", diagRoutes = true)
  doAssert x.raw == Head and not capture.on

  # A display that stops drawing ends the recording after 2 s.
  whileWaiting = nil
  capture = Capture()
  x = get("/screen/stream?n=5", diagRoutes = true)
  doAssert x.raw == Head and x.waitedMs == 2000 and not capture.on

  # One recording at a time; an abandoned one lets go of the display.
  var first = create(Reply)
  var headLen, bodyLen = 0
  let req = "GET /screen/stream?n=9 HTTP/1.1\r\n\r\n"
  doAssert scan(req, headLen, bodyLen) == scReady
  begin(first[], req, headLen, bodyLen, diagRoutes = true)
  doAssert capture.on
  get("/screen/stream", diagRoutes = true).checkPlain("503 Service Unavailable", "not ready\n")
  doAssert capture.on                                   # still the first one's
  finish(first[])
  doAssert not capture.on and capture.snapDone
  dealloc(first)
  ui.screen = nil
  dealloc(fb)

# ---- A whole connection ------------------------------------------------------------

type Wire = object
  ## A connection that delivers the request a few bytes at a time and takes
  ## the reply a few bytes at a time.
  incoming: string
  delivered: int
  rxStep, txStep: int
  outgoing: string
  peerClosed: bool         # the client closes once everything is delivered
  txFails: bool
  txBlocked: bool

proc wireRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let w = cast[ptr Wire](ctx)
  doAssert len > 0
  let n = min(min(len, w.rxStep), w.incoming.len - w.delivered)
  if n == 0: return (if w.peerClosed: IoClosed else: 0)
  copyMem(data, addr w.incoming[w.delivered], n)
  w.delivered += n
  n

proc wireSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let w = cast[ptr Wire](ctx)
  doAssert len > 0
  if w.txFails: return IoError
  if w.txBlocked: return 0
  let n = min(len, w.txStep)
  let at = w.outgoing.len
  w.outgoing.setLen at + n
  copyMem(addr w.outgoing[at], data, n)
  w.txBlocked = true       # one write per poll, like a full send buffer
  n

proc converse(w: var Wire; x: ptr Exchange; diagRoutes = false; limit = 100_000;
              resume = false): int =
  ## Pump until the exchange is over; returns the number of polls.
  if not resume: reset(x[])
  while true:
    inc result
    doAssert result < limit, "the exchange never finished"
    w.txBlocked = false
    if pump(x[], addr w, wireSend, wireRecv, diagRoutes): break
    if whileWaiting != nil: whileWaiting()
    advanceFakeTimeMs(1)
  finish(x[])

block: # pump
  freshRadio()
  whileWaiting = nil
  var x = create(Exchange)

  # The same replies whatever the pace of the connection.
  let page = get("/").raw
  let presetList = get("/presets").raw
  for (rxStep, txStep) in [(1, 1), (7, 13), (64, 536), (2000, 1460), (4096, 100_000)]:
    var w = Wire(incoming: "GET / HTTP/1.1\r\nHost: radio\r\nAccept: text/html\r\n\r\n",
                 rxStep: rxStep, txStep: txStep)
    discard converse(w, x)
    doAssert w.outgoing == page, $rxStep
    w = Wire(incoming: "GET /presets HTTP/1.1\r\n\r\n", rxStep: rxStep, txStep: txStep)
    discard converse(w, x)
    doAssert w.outgoing == presetList
    w = Wire(incoming: "POST /radio/volume HTTP/1.1\r\nContent-Type: " & Form &
               "\r\nContent-Length: 9\r\n\r\nvolume=64", rxStep: rxStep, txStep: txStep)
    player.volume = 1
    discard converse(w, x)
    doAssert player.volume == 64 and w.outgoing.endsWith("\"volume\":64,\"muted\":false}")
    doAssert w.delivered == w.incoming.len

  # The body is waited for, and only Content-Length bytes of it are read
  # once the head is in.
  var w = Wire(incoming: "POST /radio/play HTTP/1.1\r\nContent-Length: 8\r\n\r\n", rxStep: 4096, txStep: 4096)
  reset(x[])
  for i in 0 ..< 50:
    doAssert not pump(x[], addr w, wireSend, wireRecv, false)
  doAssert w.outgoing.len == 0 and takeCommand() == cmdNone
  w.incoming.add "http://ytrailing"
  discard converse(w, x, resume = true)
  doAssert $player.url == "http://y" and takeCommand() == cmdPlay
  doAssert w.delivered == w.incoming.len - "trailing".len

  # Too large, found while reading: answered without reading further.
  w = Wire(incoming: "GET / HTTP/1.1\r\nX: " & repeat('x', 3000) & "\r\n\r\n", rxStep: 300, txStep: 4096)
  discard converse(w, x)
  doAssert w.outgoing == plainHead("413 Payload Too Large", 18) & "request too large\n"
  doAssert w.delivered == RequestMax
  w = Wire(incoming: "POST /radio/play HTTP/1.1\r\nContent-Length: 5000\r\n\r\n" & repeat('u', 5000),
           rxStep: 4096, txStep: 4096)
  discard converse(w, x)
  doAssert w.outgoing.startsWith("HTTP/1.1 413 ") and takeCommand() == cmdNone

  # The client goes away: mid-request, and mid-reply.
  w = Wire(incoming: "GET / HTTP/1.1\r\nHost", rxStep: 4096, txStep: 4096, peerClosed: true)
  discard converse(w, x)
  doAssert w.outgoing.len == 0
  w = Wire(incoming: "", rxStep: 4096, txStep: 4096, peerClosed: true)
  doAssert converse(w, x) == 1
  w = Wire(incoming: "GET / HTTP/1.1\r\n\r\n", rxStep: 4096, txStep: 100, txFails: true)
  doAssert converse(w, x) == 1 and w.outgoing.len == 0

  # A send buffer that stays full holds the reply where it is.
  w = Wire(incoming: "GET /radio HTTP/1.1\r\n\r\n", rxStep: 4096, txStep: 10)
  reset(x[])
  w.txBlocked = false
  doAssert not pump(x[], addr w, wireSend, wireRecv, false)
  doAssert w.outgoing.len == 10
  for i in 0 ..< 20:
    doAssert not pump(x[], addr w, wireSend, wireRecv, false)     # still blocked
  doAssert w.outgoing.len == 10
  w.txStep = 100_000
  discard converse(w, x, resume = true)
  doAssert w.outgoing == get("/radio").raw

  # A recording abandoned with the connection releases the display.
  var fb = create(array[ScreenBytes, byte])
  ui.screen = fb
  capture = Capture()
  w = Wire(incoming: "GET /screen/stream?n=4 HTTP/1.1\r\n\r\n", rxStep: 4096, txStep: 4096)
  reset(x[])
  doAssert not pump(x[], addr w, wireSend, wireRecv, true)
  doAssert capture.on
  finish(x[])
  doAssert not capture.on and capture.snapDone
  ui.screen = nil
  dealloc(fb)
  dealloc(x)

echo "t_httpd: ok"
