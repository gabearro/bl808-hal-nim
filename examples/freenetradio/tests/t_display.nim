## Host tests for the screen renderer (display.nim).
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_display.nim
##
## Options:
##   -d:dumpDir=/some/dir   also write every checked frame there as a PGM
##                          (256x64, maxval 15) to compare by eye with
##                          upstream's docs/oled-*.png and .gif
##   -d:printGolden         print the frame hashes instead of checking them
##
## A frame's hash is FNV-1a over the 8192 framebuffer bytes. The hashes in
## `Upstream` are those of frames in upstream's own screenshots (docs/
## oled-stopped.png and frames of the oled-*.gif recordings, 4 bits per
## pixel recovered from the images), so those checks compare this renderer
## with the original firmware pixel for pixel: fonts, logo arcs, gradient,
## reflection, meters with their soft tips, spectrum bars, marquee steps,
## menu, pointer anti-aliasing and scrollbar. The other hashes pin this
## renderer's own output.

import std/[math, strutils]
import ../text, ../timebase, ../status, ../prefs, ../ui, ../netstate, ../menu,
       ../about, ../spectrum, ../diag, ../framebuf, ../fonts, ../gfx, ../display

const
  dumpDir {.strdefine.} = ""
  PrintGolden = defined(printGolden)

  SomaStation = "Underground 80s: UK Synthpop and a bit of New Wave. [SomaFM]"
  Hint = "Select a station on the remote or web page"

var
  store, expectStore: array[BufLen, byte]
  fb = initFrameBuf(addr store)
  ex = initFrameBuf(addr expectStore)     # scratch for drawing what is expected
  d: Display
  inp: FrameInputs

# ---- Helpers ------------------------------------------------------------------

proc frameHash(): uint32 =
  result = 0x811C_9DC5'u32
  for b in store: result = (result xor b.uint32) * 0x0100_0193'u32

proc dump(name: string) =
  if dumpDir.len == 0: return
  var pgm = "P5\n256 64\n15\n"
  for y in 0 ..< Height:
    for x in 0 ..< Width: pgm.add char(fb.pixel(x, y))
  writeFile(dumpDir & "/" & name & ".pgm", pgm)

proc check(name: string; golden: uint32) =
  dump name
  if PrintGolden:
    echo "  ", name, " = 0x", toHex(frameHash())
  else:
    doAssert frameHash() == golden, name & ": frame hash 0x" & toHex(frameHash())

proc world() =
  ## Everything back to power-on, with the boot animation over, a network
  ## address, and nothing playing.
  setFakeTimeUs(0)
  statusInit(); prefsInit(); menuInit(); diagInit(); spectrumInit()
  ui.osd = Osd()
  ui.lastActivityMs = 0
  ui.wakeRequested = false
  ui.capture = Capture()
  inp = FrameInputs(net: NetState(linkUp: true, hasIp: true, ip: [192'u8, 168, 0, 42]))
  d.initDisplay(nowMs())
  advanceFakeTimeMs(60_000)
  ui.lastActivityMs = nowMs()

proc frame(): FrameResult =
  inp.nowMs = nowMs()
  d.renderFrame(fb, inp)

proc frames(n: int) =
  for i in 0 ..< n: discard frame()

proc tune(title = ""; station = SomaStation) =
  inp.status.phase = phPlaying
  inp.status.url.set "http://ice1.somafm.com/u80s-128-mp3"
  inp.status.station.set station
  inp.status.title.set title
  inp.status.bitrate = 128
  inp.status.sampleRate = 44_100

proc clock(h, m: int) =
  inp.hasClock = true
  inp.clock = (h.uint8, m.uint8)

proc lit(y0 = 0; y1 = Height - 1; x0 = 0; x1 = Width - 1): int =
  for y in y0 .. y1:
    for x in x0 .. x1:
      if fb.pixel(x, y) != 0: inc result

proc sameAsExpected(x, y, w, h: int): bool =
  for yy in y ..< y + h:
    for xx in x ..< x + w:
      if fb.pixel(xx, yy) != ex.pixel(xx, yy): return false
  true

proc textAt(text: string; x, y: int; s: TextStyle; align = alLeft;
            baseline = blTop): bool =
  ## Whether exactly this text (and nothing else in its box) is drawn there.
  ex.clear()
  ex.drawText(text, x, y, s, align, baseline)
  let w = max(s.textWidth(text), 1)
  let left = case align
    of alLeft: x
    of alCenter: x - (w - 1) div 2
    of alRight: x - (w - 1)
  let top = if baseline == blMiddle: y - (s.font.charHeight - 1) div 2 else: y
  sameAsExpected(left, top, w, s.font.charHeight)

let
  small = style(font6x10, 8)
  nameStyle = style(font6x10, 13)
  lineStyle = style(font6x10, 11)
  bigStyle = style(font10x20, 15)

proc statusBar(left, right: string; name = ""): bool =
  ## Left of the clock the top bar holds exactly these texts: the dim
  ## `left` or the brighter station `name`, and `right`.
  ex.clear()
  let clockPx = if inp.hasClock and prefs.statusInfo() in {InfoBoth, InfoClock}: 42 else: 0
  ex.drawText(left, 0, 0, small)
  ex.drawText(name, 0, 0, nameStyle)
  ex.drawText(right, 255 - clockPx, 0, small, alRight)
  ex.hline(0, 255, 11, 3)
  sameAsExpected(0, 0, 256 - clockPx, 12)

proc barWidth(y: int): int =
  ## Lit width of the level bar whose top row is `y` (the track is level 1).
  for x in 0 ..< Width:
    if fb.pixel(x, y) > 1: inc result

func barHeight(v: uint8): int = (v.int * 18 + 254) div 255

proc publishHeights(heights: array[Bands, int]): array[Bands, uint8] =
  ## Feed the spectrum module energies that come out as bars of these
  ## heights (0..18 rows), and return the bar values it then reports. Found
  ## by search: upstream's log2 is a rough fit, so not every value occurs.
  var energy: array[Bands, float32]
  for i, h in heights:
    if h == 0: continue
    var db = SpectrumFloorDb.float + SpectrumRangeDb.float + 1.0
    while true:
      let p = pow(2.0, db / 3.0103).float32
      let bar = clamp((3.0103'f32 * log2Approx(p) - SpectrumFloorDb) * 255.0'f32 /
                      SpectrumRangeDb, 0.0'f32, 255.0'f32).uint8
      if barHeight(bar) == h:
        energy[i] = p
        break
      db -= 0.002
      doAssert db > SpectrumFloorDb.float - 1.0
  spectrum.publish(energy, 1)
  doAssert spectrum.read(result)
  for i, h in heights: doAssert barHeight(result[i]) == h

# Frames from upstream's own screenshots (see the top of the file).
const Upstream = (
  stopped: 0xFB7CFB71'u32,             # docs/oled-stopped.png
  meters: [0x814E5637'u32, 0xA44007ED'u32, 0x6B31ECD5'u32, 0xAD684D87'u32,
           0xB0B3841B'u32, 0x96A5A8E1'u32, 0x58B78880'u32, 0x22BA98E6'u32,
           0x062E6151'u32, 0xD7F6F1EB'u32, 0x25F89DB3'u32, 0x090E6EB9'u32],
                                        # docs/oled-playing-meters.gif, frames 0..11
  spectrum: 0xBBF82DE0'u32,            # docs/oled-playing-spectrum.gif, frame 0
  menu: 0x669FDE6A'u32,                # docs/oled-menu.gif, frame 0
  equaliser: 0xA0A93130'u32,           # docs/oled-eq.gif, frame 0
  menuEnd: 0xA68336C1'u32)             # docs/oled-about.gif, frame 0

# ---- Frames compared with upstream's screenshots --------------------------------

block: # stoppedScreen
  world()
  clock(21, 47)
  let r = frame()
  doAssert frameHash() == Upstream.stopped
  dump "stopped"
  doAssert r.dim == 0 and not r.animating and not r.fast
  doAssert statusBar("http://192.168.0.42/", "STOPPED")
  doAssert textAt(Hint, 0, 14, lineStyle)
  # The logo block: FREE over NetRadio, beside the broadcast symbol.
  doAssert textAt("FREE", 111, 26, style(font5x7, 11, spacing = 1))
  doAssert fb.pixel(83, 40) == 15                 # the symbol's centre dot
  doAssert lit(12, 13) == 0 and lit(24, 25) == 0

block: # playingWithMeters
  # The recording starts 67 frames into the description's scroll. Levels
  # per frame as the player published them; 0 lets the meter fall back.
  const Levels = [(211, 211), (0, 0), (0, 0), (227, 227), (0, 225), (219, 0),
                  (215, 0), (0, 0), (0, 0), (0, 0), (239, 237), (0, 0)]
  world()
  clock(21, 35)
  tune "ABC - Vanity Kills"
  frames 67
  for i, (l, r) in Levels:
    inp.status.levelL = l.uint8
    inp.status.levelR = r.uint8
    let res = frame()
    doAssert frameHash() == Upstream.meters[i], "meters frame " & $i
    doAssert res.animating and res.fast and res.dim == 0
    if i == 0: dump "playing-meters"
  doAssert statusBar("", "128 kbps 44.1 kHz", "Underground 80s")
  doAssert textAt("ABC - Vanity Kills", 128, 25, bigStyle, alCenter)

block: # playingWithSpectrum
  # In the recording the description is 290 frames into its scroll and the
  # title, which changed later, 82 frames into its own.
  const Heights = [12, 15, 14, 18, 17, 14, 13, 14, 11, 12, 9, 9, 10, 11, 9, 10, 7, 10,
                   12, 10, 10, 12, 10, 11, 10, 10, 9, 8, 8, 9, 11, 14, 12, 12, 11, 13,
                   12, 12, 11, 0]
  world()
  clock(21, 41)
  setVisualiser(VisSpectrum)
  tune "Tears For Fears"
  frames 208
  inp.status.title.set "Tears For Fears - The Working Hour"
  frames 82
  discard publishHeights(Heights)
  let r = frame()
  doAssert frameHash() == Upstream.spectrum
  dump "playing-spectrum"
  doAssert r.animating and r.fast
  # 5 px bars, 1 px apart, 18 rows at most, centred; brighter towards the top.
  for i, h in Heights:
    for k in 0 ..< 18:
      let want = if k < h: uint8(4 + k * 11 div 17) else: 0'u8
      for x in 0 ..< 6:
        doAssert fb.pixel(8 + i * 6 + x, 63 - k) == (if x < 5: want else: 0'u8)
  doAssert lit(46, 63, 0, 7) == 0 and lit(46, 63, 248, 255) == 0

block: # settingsMenu
  # The recordings were taken with the screen-capture clock: the pointer's
  # bob runs on the captured frame count.
  proc recorded() =
    world()
    tune "ABC - Vanity Kills"
    setVisualiser(VisSpectrum)
    setDstEnabled(true)
    ui.capture.on = true
    menu.toggle()

  recorded()
  clock(21, 36)
  var r = frame()
  doAssert frameHash() == Upstream.menu
  dump "menu"
  doAssert r.animating and r.fast               # the pointer bobs
  doAssert textAt("Visualiser", 10, 13, style(font6x10, 15))
  doAssert textAt("< Spectrum >", 248, 13, style(font6x10, 15), alRight)
  doAssert textAt("Flat", 248, 23, style(font6x10, 9), alRight)
  doAssert textAt("UTC+00:00", 248, 33, style(font6x10, 9), alRight)
  doAssert textAt("Daylight saving", 10, 43, style(font6x10, 9))
  doAssert lit(13, 63, 0, 9) == 16               # only the pointer left of the labels

  recorded()
  clock(21, 36)
  menu.key(keyDown)
  menu.key(keyOk)
  ui.capture.frames = 2
  r = frame()
  doAssert frameHash() == Upstream.equaliser
  dump "equaliser"
  doAssert textAt("EQUALISER", 10, 13, style(font6x10, 6))
  doAssert textAt("< Flat >", 248, 23, style(font6x10, 15), alRight)
  doAssert textAt("0 dB", 248, 53, style(font6x10, 9), alRight)

  recorded()
  clock(21, 37)
  for i in 1 .. 7: menu.key(keyDown)
  ui.capture.frames = 12
  r = frame()
  doAssert frameHash() == Upstream.menuEnd
  dump "menu-end"
  doAssert textAt("192.168.0.42", 248, 43, style(font6x10, 9), alRight)
  doAssert textAt("Licenses >", 248, 53, style(font6x10, 15), alRight)

# ---- Status bar -----------------------------------------------------------------

block: # statusBarTexts
  world()
  discard frame()
  doAssert statusBar("http://192.168.0.42/", "STOPPED")
  inp.net.hasIp = false
  discard frame()
  doAssert statusBar("Getting address...", "STOPPED")
  inp.net.linkUp = false
  inp.net.hasIp = true                    # no link wins
  discard frame()
  doAssert statusBar("No network link", "STOPPED")
  inp.net.linkUp = true

  # No station chosen yet: the address, whatever the phase.
  inp.status.phase = phConnecting
  discard frame()
  doAssert statusBar("http://192.168.0.42/", "CONNECTING")
  inp.status.url.set "http://x/"
  inp.status.station.set "Radio X: all day"
  discard frame()
  doAssert statusBar("", "CONNECTING", "Radio X")
  inp.status.phase = phError
  discard frame()
  doAssert statusBar("http://192.168.0.42/", "ERROR")
  inp.status.phase = phOffline
  discard frame()
  doAssert statusBar("", "OFFLINE", "Radio X")
  inp.status.phase = phBuffering
  inp.status.bufferPct = 42
  discard frame()
  doAssert statusBar("", "BUFFERING 42%", "Radio X")
  inp.status.phase = phPlaying            # format not known yet
  inp.status.sampleRate = 0
  discard frame()
  doAssert statusBar("", "PLAYING", "Radio X")
  inp.status.sampleRate = 22_050
  inp.status.bitrate = 64
  discard frame()
  doAssert statusBar("", "64 kbps 22.0 kHz", "Radio X")
  inp.status.sampleRate = 48_000
  inp.status.bitrate = 320
  discard frame()
  doAssert statusBar("", "320 kbps 48.0 kHz", "Radio X")

block: # statusBarClockAndInfoSetting
  world()
  tune "T", "Radio X: all day"
  clock(7, 5)
  discard frame()
  doAssert statusBar("", "128 kbps 44.1 kHz", "Radio X")
  # "HH:MM" at the far right: digits from the font, the colon as two 1x2 dots.
  doAssert textAt("07", 226, 0, small) and textAt("05", 244, 0, small)
  for y in 0 .. 9:
    doAssert fb.pixel(240, y) == (if y in {2, 3, 5, 6}: 8'u8 else: 0'u8)
    doAssert fb.pixel(239, y) == 0 and fb.pixel(241, y) == 0
  setStatusInfo(InfoClock)
  discard frame()
  doAssert statusBar("", "", "Radio X") and textAt("07", 226, 0, small)
  setStatusInfo(InfoCodec)
  discard frame()
  doAssert statusBar("", "128 kbps 44.1 kHz", "Radio X") and lit(0, 10, 220, 255) > 0
  doAssert textAt("z", 255, 0, small, alRight)   # the codec text now ends at the edge
  setStatusInfo(InfoOff)
  discard frame()
  doAssert statusBar("", "", "Radio X") and lit(0, 10, 100, 255) == 0
  inp.status.phase = phBuffering          # status text is always shown
  inp.status.bufferPct = 7
  discard frame()
  doAssert statusBar("", "BUFFERING 7%", "Radio X")
  setStatusInfo(InfoBoth)
  inp.hasClock = false                    # NTP has not answered yet
  discard frame()
  doAssert statusBar("", "BUFFERING 7%", "Radio X") and textAt("%", 255, 0, small, alRight)

block: # stationNameAndDescription
  world()
  tune "T", "Groove Salad: a nicely chilled plate"
  discard frame()
  doAssert textAt("Groove Salad", 0, 0, nameStyle)
  doAssert textAt("a nicely chilled plate", 0, 14, lineStyle)
  inp.status.station.set "  Groove Salad :   spaced out  "    # both halves are trimmed
  discard frame()
  doAssert textAt("Groove Salad", 0, 0, nameStyle) and textAt("spaced out", 0, 14, lineStyle)
  inp.status.station.set "Just a name"     # no ": ": both lines show it all
  discard frame()
  doAssert textAt("Just a name", 0, 0, nameStyle) and textAt("Just a name", 0, 14, lineStyle)
  inp.status.station.set ": odd"           # an empty name is not a split
  discard frame()
  doAssert textAt(": odd", 0, 0, nameStyle) and textAt(": odd", 0, 14, lineStyle)
  inp.status.station.set "A: B: C"         # the first ": " splits
  discard frame()
  doAssert textAt("A", 0, 0, nameStyle) and textAt("B: C", 0, 14, lineStyle)
  inp.status.station.set "No space:here"
  discard frame()
  doAssert textAt("No space:here", 0, 0, nameStyle)
  # A saved preset's name replaces the stream's.
  inp.status.station.set "Groove Salad: a nicely chilled plate"
  inp.presetName.set "My favourite"
  discard frame()
  doAssert textAt("My favourite", 0, 0, nameStyle)
  doAssert textAt("a nicely chilled plate", 0, 14, lineStyle)
  # Nothing known about the station yet.
  inp.presetName.clear()
  inp.status.station.clear()
  inp.status.title.clear()
  discard frame()
  doAssert lit(0, 10, 0, 100) == 0 and lit(14, 23) == 0
  doAssert textAt("Internet radio", 128, 25, bigStyle, alCenter)

block: # bigLine
  world()
  tune "Artist - Song", "Radio X: all day"
  discard frame()
  doAssert textAt("Artist - Song", 128, 25, bigStyle, alCenter)
  inp.status.title.clear()
  discard frame()
  doAssert textAt("Radio X: all day", 128, 25, bigStyle, alCenter)
  inp.status.phase = phBuffering
  discard frame()
  doAssert textAt("Radio X: all day", 128, 25, bigStyle, alCenter)
  inp.status.phase = phConnecting
  discard frame()
  doAssert textAt("Connecting...", 128, 25, bigStyle, alCenter)
  doAssert textAt("all day", 0, 14, lineStyle)
  inp.status.phase = phError
  inp.status.message.set "Not an MP3 stream (AAC)"
  var r = frame()
  doAssert textAt("Can't play", 128, 25, bigStyle, alCenter)
  doAssert textAt("Not an MP3 stream (AAC)", 0, 14, lineStyle)
  doAssert not r.animating and not r.fast and lit(46, 63) == 0
  check "error", 0xB128F160'u32
  inp.status.phase = phOffline
  inp.status.message.set "The Wi-Fi link is down. Check that the access point is in range."
  r = frame()
  doAssert textAt("No network", 128, 25, bigStyle, alCenter)
  doAssert r.animating and r.fast          # the long message scrolls
  inp.status.message.clear()
  discard frame()
  doAssert textAt("all day", 0, 14, lineStyle)
  # Stopped with an explanation: it replaces the hint, above the logo.
  inp.status.phase = phStopped
  inp.status.message.set "The stream ended"
  discard frame()
  doAssert textAt("The stream ended", 0, 14, lineStyle)
  doAssert fb.pixel(83, 40) == 15 and lit(25, 25) == 0

# ---- Marquees -------------------------------------------------------------------

block: # marquee
  proc rowCopy(y0, y1: int): seq[seq[uint8]] =
    for y in y0 .. y1:
      var line: seq[uint8]
      for x in 0 ..< Width: line.add fb.pixel(x, y)
      result.add line

  # 42 characters of 6 px fit the 256 px line; 43 do not.
  world()
  tune "T", "N: " & 'a'.repeat(42)
  var r = frame()
  let fits = rowCopy(14, 23)
  frames 3
  doAssert rowCopy(14, 23) == fits and textAt('a'.repeat(42), 0, 14, lineStyle)

  world()
  let long = "0123456789 The quick brown fox jumps over 1"   # 43 characters
  doAssert long.len == 43
  tune "T", "N: " & long
  r = frame()
  doAssert r.animating
  let first = rowCopy(14, 23)
  # 1 px left per frame, the second copy 80 px behind the first's end.
  const Period = 43 * 6 + 80
  for k in 1 ..< Period:
    discard frame()
    if k <= 60 or k mod 37 == 0 or k > Period - 5:
      let now = rowCopy(14, 23)
      for y in 0 ..< now.len:
        for x in 0 ..< Width:
          let src = x + k                       # column of the unscrolled line
          let want =
            if src < Width: first[y][src]
            elif src < 43 * 6: 255'u8           # text that started off-screen
            elif src < Period: 0'u8             # the gap
            else: first[y][src - Period]        # the next copy coming in
          if want != 255: doAssert now[y][x] == want
  discard frame()
  doAssert rowCopy(14, 23) == first              # one full loop
  # The line restarts only when the text changes.
  frames 9
  inp.status.station.set "N: " & long
  discard frame()
  doAssert rowCopy(14, 23) != first
  inp.status.station.set "N: " & long & "!"
  discard frame()
  doAssert rowCopy(14, 23) == first              # the added character is off-screen

  # The title: centred while it fits (25 characters of 10 px), then scrolling.
  world()
  tune 'M'.repeat(25)
  r = frame()
  doAssert textAt('M'.repeat(25), 128, 25, bigStyle, alCenter)
  inp.status.title.set 'M'.repeat(26)
  r = frame()
  doAssert r.animating and fb.pixel(1, 28) == 15 and fb.pixel(0, 28) == 0
  discard frame()
  doAssert fb.pixel(0, 28) == 15                # moved 1 px

  # The status bar's name scrolls inside the room left of the format text
  # (2 characters' gap), with a gap of a third of that room, and never
  # draws over the text to its right.
  world()
  clock(12, 0)
  let name = "The Longest Station Name On Air"
  tune "T", name & ": d"
  r = frame()
  let room = 256 - (17 + 2) * 6 - 42             # "128 kbps 44.1 kHz" and the clock
  doAssert room == 100 and name.len * 6 > room and r.animating
  doAssert statusBar("", "128 kbps 44.1 kHz") == false   # the name is there too
  doAssert lit(0, 10, room, 255 - 42 - 17 * 6) == 0
  let top0 = rowCopy(0, 9)
  const NamePeriod = 31 * 6 + 100 div 3
  for k in 1 ..< NamePeriod:
    discard frame()
    doAssert lit(0, 10, room, 255 - 42 - 17 * 6) == 0
    if k == 1:
      let now = rowCopy(0, 9)
      for y in 0 ..< now.len:
        for x in 0 ..< room - 1: doAssert now[y][x] == top0[y][x + 1]
  discard frame()
  doAssert rowCopy(0, 9) == top0

# ---- Meters, spectrum, muted ------------------------------------------------------

block: # meters
  world()
  tune "T", "N: d"
  inp.status.levelL = 255
  inp.status.levelR = 0
  discard frame()
  doAssert barWidth(46) == 256 and barWidth(56) == 0
  # Full: 240 px solid, then a 16 px tip fading to the track's edge.
  for x in 0 ..< 240:
    if x notin 2 .. 6: doAssert fb.pixel(x, 50) == 15
  for k in 0 ..< 16:
    doAssert fb.pixel(240 + k, 46).int == max((15 * (16 - k) + 8) div 17, 2)
  doAssert fb.pixel(240, 46) == 14 and fb.pixel(255, 46) == 2
  # The track behind an empty bar is level 1, 8 rows, with a 2 row gap.
  for x in 7 ..< 256: doAssert fb.pixel(x, 60) == 1
  doAssert lit(54, 55) == 0 and lit(45, 45) == 0
  # Channel letters: the inverse of what is under them.
  ex.clear()
  ex.fillRect(0, 46, 256, 8, 15)
  ex.fillRect(0, 56, 256, 8, 1)
  ex.drawText("L", 2, 47, TextStyle(font: font5x7, invert: true))
  ex.drawText("R", 2, 57, TextStyle(font: font5x7, invert: true))
  doAssert sameAsExpected(0, 46, 8, 18) or sameAsExpected(0, 46, 8, 8)
  doAssert fb.pixel(2, 47) == 0 and fb.pixel(2, 57) == 14 and fb.pixel(1, 57) == 1

  # One pixel per level step, rounded: width = (level * 256 + 127) div 255.
  for level in [1, 2, 7, 15, 16, 17, 100, 128, 200, 254]:
    world()
    tune "T", "N: d"
    inp.status.levelL = level.uint8
    discard frame()
    let width = (level * 256 + 127) div 255
    doAssert barWidth(46) == width
    # A short bar is all tip, scaled to its length.
    let tip = min(16, width)
    for k in 0 ..< tip:
      doAssert fb.pixel(width - tip + k, 46).int == max((15 * (tip - k) + tip div 2) div (tip + 1), 2)

  # Fall back 8/255 per frame; jump up at once.
  world()
  tune "T", "N: d"
  inp.status.levelL = 200
  inp.status.levelR = 100
  discard frame()
  inp.status.levelL = 0
  inp.status.levelR = 96
  for step in 1 .. 30:
    discard frame()
    doAssert barWidth(46) == (max(200 - 8 * step, 0) * 256 + 127) div 255
    doAssert barWidth(56) == (max(100 - 8 * step, 96) * 256 + 127) div 255
  inp.status.levelL = 180
  discard frame()
  doAssert barWidth(46) == (180 * 256 + 127) div 255
  # Not playing: the meters reset and nothing is drawn below the title.
  inp.status.phase = phConnecting
  discard frame()
  doAssert lit(46, 63) == 0
  inp.status.phase = phBuffering
  inp.status.levelL = 0
  discard frame()
  doAssert barWidth(46) == 0 and fb.pixel(100, 46) == 1    # no fall-back from before

block: # spectrumBars
  world()
  setVisualiser(VisSpectrum)
  tune "T", "N: d"
  var heights: array[Bands, int]
  heights[0] = 18; heights[1] = 1; heights[2] = 2; heights[39] = 10
  let bars = publishHeights(heights)
  discard frame()
  proc height(band: int): int =
    for k in 0 ..< 18:
      if fb.pixel(8 + band * 6, 63 - k) != 0: inc result
  # Height = ceil(value * 18 / 255) rows.
  doAssert barHeight(0) == 0 and barHeight(1) == 1 and barHeight(14) == 1 and
           barHeight(15) == 2 and barHeight(241) == 18 and barHeight(255) == 18
  for band in 0 ..< Bands: doAssert height(band) == heights[band]
  doAssert fb.pixel(8, 46) == 15 and fb.pixel(8, 63) == 4 and fb.pixel(12, 63) == 4 and
           fb.pixel(13, 63) == 0
  doAssert lit(46, 63, 0, 7) == 0 and fb.pixel(8 + 39 * 6 + 4, 63) == 4
  # Data older than 120 ms is stale: the bars fall 10/255 per frame.
  advanceFakeTimeMs(119)
  discard frame()
  doAssert height(0) == 18
  advanceFakeTimeMs(1)
  for step in 1 .. 26:
    discard frame()
    doAssert height(0) == barHeight(uint8(max(bars[0].int - 10 * step, 0)))
    doAssert height(39) == barHeight(uint8(max(bars[39].int - 10 * step, 0)))
  doAssert lit(46, 63) == 0
  # Fresh data jumps straight up, and holds while it stays fresh.
  discard publishHeights(heights)
  frames 3
  doAssert height(0) == 18 and height(39) == 10
  # Meters instead when the setting says so; each in turn in cycle mode.
  setVisualiser(VisMeters)
  discard frame()
  doAssert fb.pixel(100, 46) == 1
  setVisualiser(VisCycle)
  setFakeTimeUs(100_000 * 1000)           # 100 s: an even 5 s period -> meters
  discard publishHeights(heights)
  discard frame()
  doAssert fb.pixel(100, 46) == 1
  advanceFakeTimeMs(4_999)
  discard publishHeights(heights)
  discard frame()
  doAssert fb.pixel(100, 46) == 1
  advanceFakeTimeMs(1)                    # 105 s: odd -> spectrum
  discard publishHeights(heights)
  discard frame()
  doAssert fb.pixel(100, 46) == 0 and height(0) == 18
  advanceFakeTimeMs(5_000)
  discard frame()
  doAssert fb.pixel(100, 46) == 1

block: # mutedBadge
  world()
  tune "T", "N: d"
  inp.status.muted = true
  inp.status.levelL = 200
  setFakeTimeUs(100_000 * 1000)
  var r = frame()
  check "muted", 0x7D97C188'u32
  doAssert r.animating and r.fast
  # A bright rounded box with dark bold letters, 3 px apart, centred.
  ex.clear()
  ex.fillRoundRect(78, 47, 100, 16, 4, 4, 15)
  ex.drawText("MUTED", 128, 55, style(font6x13Bold, 0, spacing = 3), alCenter, blMiddle)
  doAssert sameAsExpected(0, 45, 256, 19)
  doAssert fb.pixel(78, 47) == 0 and fb.pixel(80, 47) == 15 and fb.pixel(78, 49) == 15
  doAssert lit(46, 63, 0, 77) == 0 and lit(46, 63, 178, 255) == 0   # no meters behind it
  # 500 ms on, 500 ms off.
  advanceFakeTimeMs(499)
  discard frame()
  doAssert fb.pixel(100, 55) == 15
  advanceFakeTimeMs(1)
  discard frame()
  doAssert lit(46, 63) == 0
  advanceFakeTimeMs(500)
  discard frame()
  doAssert fb.pixel(100, 55) == 15
  # Muted with the spectrum selected: still the badge.
  setVisualiser(VisSpectrum)
  discard frame()
  doAssert fb.pixel(100, 55) == 15

# ---- Message box ------------------------------------------------------------------

block: # osd
  world()
  tune "Artist - Song", "N: d"
  inp.status.levelL = 128
  ui.showOsd("Volume 42")
  var r = frame()
  check "osd-big", 0x711C0C1A'u32
  doAssert r.fast and r.animating
  # A black box with a grey outline and cut corners, over the middle.
  doAssert fb.pixel(8, 13) == 10 and fb.pixel(247, 13) == 10 and fb.pixel(6, 15) == 10 and
           fb.pixel(249, 47) == 10 and fb.pixel(128, 50) == 10
  doAssert fb.pixel(6, 13) != 10 and fb.pixel(7, 13) != 10 and fb.pixel(7, 14) == 10 and
           fb.pixel(248, 14) == 10 and fb.pixel(7, 49) == 10 and fb.pixel(248, 49) == 10
  ex.clear()
  ex.drawText("Volume 42", 127, 31, bigStyle, alCenter, blMiddle)
  doAssert sameAsExpected(7, 15, 242, 34)        # only the text inside the box
  doAssert statusBar("", "128 kbps 44.1 kHz", "N") and fb.pixel(100, 56) != 0   # the rest stays
  # Gone after 1.5 s.
  advanceFakeTimeMs(1499)
  discard frame()
  doAssert fb.pixel(8, 13) == 10
  advanceFakeTimeMs(1)
  discard frame()
  doAssert fb.pixel(8, 13) == 0 and textAt("Artist - Song", 128, 25, bigStyle, alCenter)

  # More than 22 characters: the small font.
  ui.showOsd("IR code 0x1234 (unknown)")
  discard frame()
  ex.clear()
  ex.drawText("IR code 0x1234 (unknown)", 128, 31, style(font6x10, 15), alCenter, blMiddle)
  doAssert sameAsExpected(7, 15, 242, 34)
  doAssert not ui.osd.big
  ui.showOsd('W'.repeat(22))
  doAssert ui.osd.big

  # Several lines are spaced 11 px, centred on the box.
  ui.osd.lines[0].set "First line"
  ui.osd.lines[1].set "Second"
  ui.osd.lines[2].set "Third line here"
  ui.osd.count = 3
  ui.osd.big = false
  ui.osd.untilMs = nowMs() + 1000
  discard frame()
  check "osd-lines", 0x5D7A3BA7'u32
  ex.clear()
  for i, line in ["First line", "Second", "Third line here"]:
    ex.drawText(line, 128, 31 - 16 + 5 + i * 11, style(font6x10, 15), alCenter, blMiddle)
  doAssert sameAsExpected(7, 15, 242, 34)

  # On an idle screen a message means fast frames, but no fixed grid.
  world()
  ui.showOsd("Preset 7")
  r = frame()
  doAssert r.fast and not r.animating
  doAssert fb.pixel(83, 40) == 0                 # it covers the logo's symbol
  advanceFakeTimeMs(1500)
  r = frame()
  doAssert not r.fast and fb.pixel(83, 40) == 15

# ---- Menu pages -------------------------------------------------------------------

block: # menuPages
  let on = style(font6x10, 15)
  let off = style(font6x10, 9)
  world()
  tune "T", "N: d"
  inp.status.levelL = 200
  menu.toggle()
  var r = frame()
  # The menu takes over everything below the bar: no title, no meters.
  doAssert lit(46, 63, 100, 180) == 0 and r.animating
  const Labels = ["Visualiser", "Equaliser", "Time zone", "Daylight saving", "Status bar",
                  "Clock when sleeping", "Address", "About"]
  for row in 0 .. 4:
    doAssert textAt(Labels[row], 10, 13 + row * 10, if row == 0: on else: off)
  doAssert textAt("< Meters >", 248, 13, on, alRight)
  doAssert textAt("Off", 248, 43, off, alRight) and textAt("Both", 248, 53, off, alRight)
  # Scrollbar: a 50 row track, thumb 31 rows, at the top.
  for yy in 0 ..< 50:
    doAssert fb.pixel(254, 13 + yy) == (if yy < 31: 9'u8 else: 2'u8)
    doAssert fb.pixel(255, 13 + yy) == fb.pixel(254, 13 + yy) and fb.pixel(253, 13 + yy) == 0
  doAssert fb.pixel(254, 63) == 0 and fb.pixel(254, 12) == 0

  # The list scrolls to keep the cursor in view; the thumb follows.
  for (downs, first) in [(4, 0), (5, 1), (6, 2), (7, 3)]:
    menuInit()
    menu.toggle()
    for i in 1 .. downs: menu.key(keyDown)
    discard frame()
    for slot in 0 .. 4:
      let row = first + slot
      doAssert textAt(Labels[row], 10, 13 + slot * 10, if row == downs: on else: off)
    let thumb = (50 - 31) * first div 3
    for yy in 0 ..< 50:
      doAssert fb.pixel(255, 13 + yy) == (if yy >= thumb and yy < thumb + 31: 9'u8 else: 2'u8)
  doAssert textAt("192.168.0.42", 248, 43, off, alRight)
  doAssert textAt("Licenses >", 248, 53, on, alRight)
  doAssert textAt("On", 248, 33, off, alRight)       # clock when sleeping
  inp.net.hasIp = false
  discard frame()
  doAssert textAt("none", 248, 43, off, alRight)
  inp.net.hasIp = true

  # Values as the settings change. Rows that left/right changes show
  # "< value >" when selected; submenus "value >"; the address nothing.
  menuInit()
  menu.toggle()
  setVisualiser(VisCycle)
  setOffsetQh(-14)                         # UTC-03:30
  setDstEnabled(true)
  setStatusInfo(InfoCodec)
  stepEqPreset(1)
  discard frame()
  doAssert textAt("< Cycle >", 248, 13, on, alRight)
  doAssert textAt("Bass Boost", 248, 23, off, alRight)
  doAssert textAt("UTC-03:30", 248, 33, off, alRight)
  doAssert textAt("On", 248, 43, off, alRight) and textAt("Codec", 248, 53, off, alRight)
  menu.key(keyDown)
  discard frame()
  doAssert textAt("Bass Boost >", 248, 23, on, alRight)
  menu.key(keyDown)
  setOffsetQh(56)
  discard frame()
  doAssert textAt("< UTC+14:00 >", 248, 33, on, alRight)
  setOffsetQh(23)
  discard frame()
  doAssert textAt("< UTC+05:45 >", 248, 33, on, alRight)
  for i in 1 .. 4: menu.key(keyDown)       # the address row, now the last one showing
  discard frame()
  doAssert textAt("Address", 10, 53, on) and textAt("192.168.0.42", 248, 53, on, alRight)

  # The pointer: 4 px wide, 7 tall, bobbing 0..3 px with partial-coverage edges.
  proc pointerRows(y: int): seq[string] =
    for yy in y + 1 .. y + 7:
      var line = ""
      for xx in 1 .. 8: line.add "0123456789ABCDEF"[fb.pixel(xx, yy)]
      result.add line
  menuInit()
  setFakeTimeUs(600_000 * 1000)            # phase 0 of the 600 ms bob
  menu.toggle()
  discard frame()
  doAssert pointerRows(13) == @["F0000000", "FF000000", "FFF00000", "FFFF0000", "FFF00000",
                                "FF000000", "F0000000"]
  advanceFakeTimeMs(300)                   # furthest right: 3 px
  discard frame()
  doAssert pointerRows(13) == @["000F0000", "000FF000", "000FFF00", "000FFFF0", "000FFF00",
                                "000FF000", "000F0000"]
  advanceFakeTimeMs(150)                   # half way back: 1.5 px, half-lit edges
  discard frame()
  doAssert pointerRows(13) == @["08800000", "08F80000", "08FF8000", "08FFF800", "08FF8000",
                                "08F80000", "08800000"]
  advanceFakeTimeMs(150)
  discard frame()
  doAssert pointerRows(13)[3] == "FFFF0000"
  menu.key(keyDown)                        # it follows the cursor
  discard frame()
  doAssert lit(14, 20, 1, 8) == 0 and pointerRows(23)[3] == "FFFF0000"

  # Equaliser page.
  menuInit()
  prefsInit()
  menu.toggle()
  menu.key(keyDown)
  menu.key(keyOk)
  discard frame()
  doAssert textAt("EQUALISER", 10, 13, style(font6x10, 6))
  doAssert textAt("Preset", 10, 23, on) and textAt("< Flat >", 248, 23, on, alRight)
  for i, label in ["Bass", "Mid", "Treble"]:
    doAssert textAt(label, 10, 33 + i * 10, off) and textAt("0 dB", 248, 33 + i * 10, off, alRight)
  doAssert fb.pixel(254, 30) == 0                  # four rows: no scrollbar
  menu.key(keyRight); menu.key(keyRight); menu.key(keyRight)      # Vocal: -2, +3, +2
  discard frame()
  doAssert textAt("< Vocal >", 248, 23, on, alRight)
  doAssert textAt("-2 dB", 248, 33, off, alRight) and textAt("+3 dB", 248, 43, off, alRight) and
           textAt("+2 dB", 248, 53, off, alRight)
  menu.key(keyDown)
  for i in 1 .. 12: menu.key(keyRight)             # bass up to the +10 limit
  discard frame()
  doAssert textAt("< +10 dB >", 248, 33, on, alRight) and textAt("Custom", 248, 23, off, alRight)
  check "equaliser-custom", 0x049C9C5D'u32

  # The menu closes itself after 15 s without a button.
  advanceFakeTimeMs(14_999)
  r = frame()
  doAssert r.animating and textAt("EQUALISER", 10, 13, style(font6x10, 6))
  advanceFakeTimeMs(1)
  r = frame()
  doAssert textAt("T", 128, 25, bigStyle, alCenter) and fb.pixel(100, 56) != 0

block: # aboutPage
  let bright = style(font6x10, 15)
  let dim = style(font6x10, 7)
  world()
  menu.toggle()
  for i in 1 .. 7: menu.key(keyDown)
  menu.key(keyOk)
  var r = frame()
  dump "about"
  doAssert r.animating
  # Item 0: the repository and licence; then the first library.
  doAssert textAt(about.Repo, 0, 14, bright)
  doAssert textAt("License: MIT - libraries below", 0, 26, dim)
  let total = menu.aboutItems()
  doAssert total == about.count() + 1 and total >= 3
  proc library(item, y: int): bool =
    let (name, author, license) = about.entry(item - 1)
    ex.clear()
    ex.drawText(name, 4, y, bright)
    ex.drawText(license, 248, y, bright, alRight)
    ex.drawText("by " & author, 4, y + 12, dim)
    sameAsExpected(0, y, 254, 22)
  doAssert library(1, 38)
  doAssert lit(13, 13) == 0 and lit(62, 63, 0, 253) == 0
  # Scrollbar: 48 rows from row 14; the thumb shows 2 of `total` items.
  proc thumbOk(first: int): bool =
    let thumbH = max(48 * 2 div total, 4)
    let thumbY = (48 - thumbH) * first div max(total - 2, 1)
    for yy in 0 ..< 48:
      let want = if yy >= thumbY and yy < thumbY + thumbH: 9'u8 else: 2'u8
      if fb.pixel(254, 14 + yy) != want or fb.pixel(255, 14 + yy) != want: return false
    fb.pixel(254, 13) == 0 and fb.pixel(254, 62) == 0
  doAssert thumbOk(0)
  # Down one library at a time, right a screenful, to the end and no further.
  menu.key(keyDown)
  discard frame()
  doAssert library(1, 14) and library(2, 38) and thumbOk(1)
  for i in 1 .. total: menu.key(keyRight)
  discard frame()
  doAssert library(total - 2, 14) and library(total - 1, 38) and thumbOk(total - 2)
  menu.key(keyOk)                         # back to the list, on About
  discard frame()
  doAssert textAt("Licenses >", 248, 53, bright, alRight)

# ---- Boot animation ---------------------------------------------------------------

block: # bootAnimation
  proc boot(playing: bool) =
    world()
    setFakeTimeUs(5_000 * 1000)
    if playing: tune "Artist - Song", "N: d"
    ui.lastActivityMs = nowMs()
    d.initDisplay(nowMs())

  # What "the logo alone, centred" looks like: the settled sleep screen
  # without its clock, one row higher. (Sliding up, upstream rounds the
  # logo's offset with "+ 0.5, truncate", which for a negative offset stops
  # one row short: asleep, the logo sits a row lower than at boot.)
  world()
  setSleepClock(false)
  discard frame()
  advanceFakeTimeMs(10_000)
  discard frame()
  advanceFakeTimeMs(1_500)
  discard frame()
  check "logo-asleep", 0xF5FA97C7'u32
  # FREE from row 15, the symbol's dot centred on row 29, the reflection
  # down to row 48.
  doAssert fb.pixel(83, 29) == 15 and lit(0, 14) == 0 and lit(15, 15) > 0 and
           lit(48, 48) > 0 and lit(49, 63) == 0
  var centred: array[BufLen, byte]
  for i in 0 ..< BufLen - 128: centred[i] = store[i + 128]

  proc scaled(buf: array[BufLen, byte]; num: int): array[BufLen, byte] =
    for i, b in buf:
      result[i] = uint8((b shr 4).int * num div 16) shl 4 or uint8((b and 15).int * num div 16)

  # 0..700 ms: the logo fades in from black (eased); 700..900 ms: it holds.
  boot(false)
  var r = frame()
  doAssert lit() == 0 and r.fast and not r.animating and r.dim == 0
  for (ms, level) in [(100, 1), (175, 3), (350, 8), (525, 14), (600, 15), (699, 16), (700, 16),
                      (899, 16)]:
    boot(false)
    advanceFakeTimeMs(ms.uint64)
    r = frame()
    doAssert store == scaled(centred, level), "boot fade at " & $ms
    doAssert r.fast
    if ms == 350: check "boot-fade", 0xDE3BC799'u32

  # 900..1900 ms: the logo slides down to its usual place; the rest of the
  # screen fades in over the last 40 % of the slide.
  world()
  discard frame()
  let settled = store
  proc dotTop(): int =
    ## Top row of the symbol's centre dot (7 rows tall): where the logo is.
    for y in 0 ..< Height - 3:
      if fb.pixel(83, y) == 15 and fb.pixel(80, y + 3) == 15: return y
    -1
  func dotTopFor(e: float): int =
    ## ...for the logo's area starting at row lerp(0, 24, e).
    let areaTop = int(24.0 * e + 0.5)
    areaTop + (64 - areaTop - 33) div 2 + 10
  doAssert dotTopFor(0.0) == 25 and dotTopFor(1.0) == 37
  boot(false)
  advanceFakeTimeMs(900)
  discard frame()
  doAssert store == centred and dotTop() == 25
  var last = 25
  for ms in countup(900, 1899, 20):
    boot(false)
    advanceFakeTimeMs(ms.uint64)
    r = frame()
    doAssert r.fast and not r.animating
    let t = (ms - 900) / 1000
    let e = t * t * (3 - 2 * t)
    let top = dotTop()
    doAssert top >= last                          # moves down only
    doAssert top in [dotTopFor(e - 1e-5), dotTopFor(e + 1e-5)]
    last = top
    # The rest: black until 60 % of the slide, then fading in.
    let ui = clamp((t - 0.6) / 0.4, 0.0, 1.0)
    let line = fb.pixel(0, 11).int                # the bar's rule, level 3
    doAssert line in [3 * int(ui * 16 + 0.5 - 1e-4) div 16, 3 * int(ui * 16 + 0.5 + 1e-4) div 16]
    if ms < 1500: doAssert lit(0, 13) == 0
    if ms == 1400: check "boot-slide", 0xA6AC63C7'u32
    if ms == 1700: check "boot-ui-fade", 0xBEDF4E55'u32
  boot(false)
  advanceFakeTimeMs(1899)
  r = frame()
  doAssert r.fast and dotTop() == 37
  advanceFakeTimeMs(1)
  r = frame()
  doAssert store == settled and not r.fast

  # A restored station is already playing: the logo fades out where it is
  # (it would land on the meters), then the screen fades in.
  boot(true)
  advanceFakeTimeMs(800)
  r = frame()
  doAssert store == centred and r.animating
  for (ms, level) in [(900, 16), (1200, 8), (1300, 4), (1499, 0)]:
    boot(true)
    advanceFakeTimeMs(ms.uint64)
    discard frame()
    doAssert store == scaled(centred, level), "boot with station at " & $ms
  boot(true)
  advanceFakeTimeMs(2_000)
  inp.status.levelL = 99
  discard frame()
  let playing = store
  for (ms, level) in [(1600, 4), (1700, 8), (1800, 12), (1899, 16)]:
    boot(true)
    advanceFakeTimeMs(ms.uint64)
    inp.status.levelL = 99
    discard frame()
    doAssert store == scaled(playing, level), "boot with station at " & $ms
    doAssert fb.pixel(83, 28) == 0                     # no logo any more
    if ms == 1700: check "boot-station", 0x4C9C0C08'u32

# ---- Idle dim -----------------------------------------------------------------------

block: # idleDim
  world()
  clock(3, 7)
  var r = frame()
  let awake = store
  # Stopped for 10 s without activity: asleep.
  advanceFakeTimeMs(9_999)
  r = frame()
  doAssert store == awake and r.dim == 0 and not r.fast
  advanceFakeTimeMs(1)
  r = frame()
  doAssert r.dim == 0 and r.fast and not r.animating      # the fade has just begun
  doAssert store == awake                                  # ...from the same picture
  # 1.5 s: the UI fades out over the first 40 %, the logo slides up, the
  # panel dims to 0.6, all eased.
  var lastTop = 37
  for ms in countup(20, 1480, 20):
    advanceFakeTimeMs(20)
    var before = d
    r = frame()
    let t = ms / 1500
    let e = t * t * (3 - 2 * t)
    doAssert abs(r.dim - 0.6 * e) < 1e-4 and r.fast and not r.animating
    # The bar's rule (level 3) shows the UI's fade: gone after 40 %.
    let ui = 1.0 - min(t / 0.4, 1.0)
    doAssert fb.pixel(0, 11).int in [3 * int(ui * 16 + 0.5 - 1e-4) div 16,
                                     3 * int(ui * 16 + 0.5 + 1e-4) div 16]
    if t >= 0.4: doAssert lit(0, 11) == 0
    var top = -1
    for y in 0 ..< Height - 3:
      if fb.pixel(83, y) == 15 and fb.pixel(80, y + 3) == 15: (top = y; break)
    doAssert top <= lastTop and top >= 26         # slides up only
    lastTop = top
    # The clock under the logo fades in (to level 7) over the last quarter.
    let withClock = store
    let colon = fb.pixel(127, 54).int
    setSleepClock(false)
    discard before.renderFrame(fb, inp)
    setSleepClock(true)
    let c = clamp((t - 0.75) / 0.25, 0.0, 1.0)
    let level = [int(7 * c * c * (3 - 2 * c) + 0.5 - 1e-3), int(7 * c * c * (3 - 2 * c) + 0.5 + 1e-3)]
    if level[1] == 0: doAssert store == withClock
    if level[0] > 0: doAssert store != withClock and colon in level and fb.pixel(127, 54) == 0
    store = withClock
    if ms == 760: check "sleep-slide", 0x5D34BFC7'u32
  doAssert lastTop == 26
  advanceFakeTimeMs(20)
  r = frame()
  doAssert abs(r.dim - 0.6) < 1e-6 and not r.fast and not r.animating
  check "asleep", 0xCBDC8633'u32
  # Settled: the logo block centred (rows 15..48), the time at level 7.
  doAssert lit(0, 14) == 0 and lit(49, 51) == 0 and lit(62, 63) == 0
  doAssert textAt("03", 113, 52, style(font6x10, 7)) and textAt("07", 131, 52, style(font6x10, 7))
  doAssert fb.pixel(127, 54) == 7 and fb.pixel(127, 55) == 7 and fb.pixel(127, 57) == 7 and
           fb.pixel(127, 58) == 7 and fb.pixel(127, 56) == 0
  let asleep = store
  advanceFakeTimeMs(60_000)
  r = frame()
  doAssert store == asleep and r.dim == 0.6'f32 * 1.0'f32

  # No clock on the dimmed screen if the setting is off or NTP never answered.
  setSleepClock(false)
  discard frame()
  doAssert lit(49, 63) == 0
  setSleepClock(true)
  inp.hasClock = false
  discard frame()
  doAssert lit(49, 63) == 0
  inp.hasClock = true
  # ...and it shows even when the status bar's clock is switched off.
  setStatusInfo(InfoOff)
  discard frame()
  doAssert store == asleep
  setStatusInfo(InfoBoth)

  # Any activity wakes it at once (no slide back) and restarts the 10 s.
  ui.wake()
  r = frame()
  doAssert store == awake and r.dim == 0 and not r.fast
  advanceFakeTimeMs(9_999)
  r = frame()
  doAssert r.dim == 0 and store == awake
  advanceFakeTimeMs(1)
  r = frame()
  doAssert r.dim == 0 and r.fast            # the slide starts on this frame
  advanceFakeTimeMs(750)
  r = frame()
  doAssert abs(r.dim - 0.3) < 1e-4
  # A message wakes it too, and holds it awake while it shows.
  ui.showOsd("Volume 10")
  r = frame()
  doAssert r.dim == 0 and fb.pixel(8, 13) == 10
  advanceFakeTimeMs(1_500)
  r = frame()
  doAssert r.dim == 0 and store == awake
  # The open menu keeps the screen awake.
  advanceFakeTimeMs(9_000)
  menu.toggle()
  advanceFakeTimeMs(14_000)
  r = frame()
  doAssert r.dim == 0 and r.animating
  advanceFakeTimeMs(1_000)                 # the menu closes itself; 15 s idle already
  r = frame()
  doAssert r.fast and not r.animating and r.dim == 0
  advanceFakeTimeMs(1_500)
  r = frame()
  doAssert store == asleep

  # Only a stopped radio sleeps, counted from when it stopped.
  world()
  inp.status.phase = phError
  inp.status.message.set "No such host"
  advanceFakeTimeMs(100_000)
  r = frame()
  doAssert r.dim == 0 and not r.fast
  inp.status.phase = phStopped
  r = frame()
  doAssert r.dim == 0 and not r.fast
  advanceFakeTimeMs(9_999)
  r = frame()
  doAssert r.dim == 0 and not r.fast
  advanceFakeTimeMs(1)
  r = frame()
  doAssert r.fast
  inp.status.phase = phConnecting          # playing again: awake at once
  r = frame()
  doAssert r.dim == 0 and textAt("Connecting...", 128, 25, bigStyle, alCenter)

  # While a screen recording is captured, the dim runs on the frame count
  # (20 ms per captured frame), not the clock.
  world()
  discard frame()
  advanceFakeTimeMs(10_000)
  ui.capture.on = true
  for k in 0 .. 80:
    r = frame()
    let t = min(k * 20 / 1500, 1.0)
    doAssert abs(r.dim - 0.6 * (t * t * (3 - 2 * t))) < 1e-4
    doAssert r.fast == (k < 75)
    advanceFakeTimeMs(43)                  # the capture is slower than the display

echo "t_display: ok"
