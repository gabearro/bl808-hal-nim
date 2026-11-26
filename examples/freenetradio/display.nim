## The radio's OLED screen (upstream `src/display.rs`, the drawing half):
##
##   Station name (address when stopped)    128 kbps 44.1 kHz / state  HH:MM
##   ---------------------------------------------------------------------
##   Station description (scrolls if long)
##   Now playing title (scrolls if long)
##   ============  left level
##   =========     right level
##
## `renderFrame` draws one frame into a framebuffer from a copy of the
## player status and the shared UI state, and says how the panel should be
## dimmed and when the next frame is due. Scrolling moves exactly 1 px per
## drawn frame (not by elapsed time): a delayed frame then means a brief
## slowdown rather than a visible 2 px jump.
##
## Pure Nim: no hardware, so every screen is rendered and checked on the
## host. `display_task.nim` owns the panel and the pacing.

import ./text, ./timebase, ./status, ./prefs, ./ui, ./netstate, ./menu, ./about,
       ./spectrum, ./diag, ./framebuf, ./fonts, ./gfx

{.localPassC: "-ffp-contract=off".}   # animation easing must round as upstream's

const
  FrameActiveMs* = 20
  FrameIdleMs* = 200
  ScrollGap = 80

  DimAfterMs = 10_000
    ## After this long stopped with no activity, the screen fades down to
    ## just the logo at minimum brightness (saves the panel, less glare in a
    ## dark room). Any activity brings it straight back.
  DimTimeMs = 1500
    ## How long dimming takes: the logo slides to the centre while the panel
    ## fades, both eased in and out.
  DimAmount = 0.6'f32
    ## How far to dim when idle, 0.0 (not at all) .. 1.0 (the dimmest the
    ## panel settings go). Upstream chose 0.6 by eye.
  UiFadePart = 0.4'f32
    ## The status bar and hint fade out over this fraction of DimTimeMs.
  BootFadeMs = 700
  BootHoldMs = 200
  BootSlideMs = 1000
    ## Boot animation: the logo fades in alone in the centre, holds, then
    ## slides down to its usual place while the rest of the screen fades in
    ## over the last UiFadePart of the slide (sleeping, in reverse).
  LogoAwakeTop = 24         # where the logo sits normally (below the hint text)
  LogoDimTop = 0            # ...and when dimmed
  LogoBottom = 63

  VisCyclePeriodMs = 5000   ## in cycle mode meters and spectrum alternate this often
  ClockW = 30               ## width of "HH:MM" in the 6x10 font
  PresetNameMax* = 32

  PhaseUpper: array[Phase, string] = [
    "STOPPED", "CONNECTING", "BUFFERING", "PLAYING", "ERROR", "OFFLINE"]

type
  Marquee = object
    ## A line of text that scrolls right to left in a loop when it is wider
    ## than its area.
    text: Text[128]
    px: int

  Display* = object
    ## What the screen remembers from frame to frame.
    bootStartMs: uint64
    title, station, name: Marquee
    stopped: bool             # a stopped spell is running...
    stoppedSince: uint64      # ...since then (or the last activity, if later)
    dimming: bool             # asleep...
    dimStartMs: uint64        # ...since then
    dimFrames: uint64         # frames drawn since then (screen recordings)
    meterL, meterR: uint8     # the meters fall back smoothly
    bars: array[Bands, uint8] # so do the spectrum bars

  FrameInputs* = object
    status*: Status
    net*: NetState
    hasClock*: bool           ## NTP has set the time
    clock*: (uint8, uint8)    ## local hour and minute
    presetName*: Text[PresetNameMax]
      ## Name of the preset whose URL is playing; empty if it is not one.
    nowMs*: uint64

  FrameResult* = object
    dim*: float32             ## panel dimming wanted, 0.0 .. 1.0 (ssd1322.dimCommands)
    animating*: bool          ## keep to the fixed 20 ms grid (no early frame on a wake)
    fast*: bool               ## next frame in FrameActiveMs, otherwise FrameIdleMs

proc initDisplay*(d: var Display; nowMs: uint64) =
  ## Call when the panel is ready: the boot animation starts now.
  d = Display(bootStartMs: nowMs)

# ---- Small helpers ----------------------------------------------------------------

func smoothstep(t: float32): float32 {.inline.} = t * t * (3.0'f32 - 2.0'f32 * t)

func lerp(a, b: int; e: float32): int {.inline.} =
  a + int(int32(float32(b - a) * e + 0.5'f32))

func level16(x: float32): int {.inline.} = int(x * 16.0'f32 + 0.5'f32)

proc add2(t: var Text; v: int) =
  ## Two digits, zero padded.
  if v < 10: t.add '0'
  t.addInt v

proc addIp(t: var Text; ip: array[4, uint8]) =
  for i in 0 .. 3:
    if i > 0: t.add '.'
    t.addInt ip[i].int

proc animMs(inp: FrameInputs): uint64 =
  ## Milliseconds for clock-driven animation (the menu pointer's bob).
  ## While a screen recording is being captured it runs on the frame count
  ## instead, so it plays at its true speed however slow the capture is.
  if ui.capture.on: ui.capture.frames.uint64 * FrameActiveMs
  else: inp.nowMs

proc spectrumShowing(nowMs: uint64): bool =
  ## Whether the spectrum (rather than the meters) is showing.
  case prefs.visualiser()
  of VisSpectrum: true
  of VisCycle: nowMs div VisCyclePeriodMs mod 2 == 1
  else: false

func splitStation(icyName: openArray[char]): tuple[n0, n1, d0, d1: int] =
  ## Split an icy-name like "Groove Salad: a nicely chilled plate of ambient
  ## beats [SomaFM]" into name `n0 ..< n1` and description `d0 ..< d1`.
  ## Without a ": " the whole thing is both (so the status bar's cut-off
  ## name can still be read in full).
  func trimmed(s: openArray[char]; a, b: int): (int, int) =
    var (a, b) = (a, b)
    while a < b and s[a] in {' ', '\t', '\n', '\r', '\v', '\f'}: inc a
    while b > a and s[b - 1] in {' ', '\t', '\n', '\r', '\v', '\f'}: dec b
    (a, b)
  for i in 0 ..< icyName.len - 1:
    if icyName[i] == ':' and icyName[i + 1] == ' ':
      if i == 0: break            # an empty name: not a split
      (result.n0, result.n1) = trimmed(icyName, 0, i)
      (result.d0, result.d1) = trimmed(icyName, i + 2, icyName.len)
      return
  (0, icyName.len, 0, icyName.len)

# ---- Marquee ----------------------------------------------------------------------

proc set(m: var Marquee; text: openArray[char]) =
  ## Change the text; scrolling restarts only if it actually changed.
  if not (m.text == text):
    m.text.set text
    m.px = 0

proc setPart(m: var Marquee; text: openArray[char]; a, b: int) =
  if b > a: m.set text.toOpenArray(a, b - 1)
  else: m.set ""

proc drawPart(fb: var FrameBuf; text: openArray[char]; a, b, x, y: int; s: TextStyle) =
  fb.drawText(text.toOpenArray(a, b - 1), x, y, s)

proc drawIn(m: var Marquee; fb: var FrameBuf; s: TextStyle; y, width: int;
            center: bool): bool =
  ## Draw at row `y` (top of the text) within the leftmost `width` pixels:
  ## text that fits is left-aligned or centred in them; longer text scrolls
  ## inside them, clipped at the edge. Returns true if it is scrolling.
  let charW = s.advance
  let len = m.text.len
  if len * charW <= width:
    if center: fb.drawText(m.text.chars, width div 2, y, s, alCenter)
    else: fb.drawText(m.text.chars, 0, y, s)
    return false
  # A narrow area (the status bar) gets a proportionally smaller gap.
  let period = len * charW + min(ScrollGap, width div 3)
  let offset = m.px mod period
  m.px = (offset + 1) mod period
  fb.setClip(0, y, width, s.font.charHeight)
  # The copy scrolling off, and the next one coming in behind it. Only the
  # characters in the area are drawn; the clip trims the ones half across
  # its edges.
  for copy in 0 .. 1:
    let x = copy * period - offset
    if x >= width or x + len * charW <= 0: continue
    let first = if x < 0: -x div charW else: 0
    let last = min((width - x + charW - 1) div charW, len)
    if last > first:
      fb.drawPart(m.text.chars, first, last, x + first * charW, y, s)
  fb.resetClip()
  true

proc draw(m: var Marquee; fb: var FrameBuf; s: TextStyle; y: int; center: bool): bool =
  m.drawIn(fb, s, y, Width, center)

# ---- Pieces of the screen ---------------------------------------------------------

proc drawBox(fb: var FrameBuf; x, y, w, h: int) =
  ## A filled black box with a 1 px grey border and cut corners.
  const Border = 10'u8
  fb.fillRect(x, y, w, h, 0)
  for xx in x + 2 ..< x + w - 2:
    fb.setPixel(xx, y, Border)
    fb.setPixel(xx, y + h - 1, Border)
  for yy in y + 2 ..< y + h - 2:
    fb.setPixel(x, yy, Border)
    fb.setPixel(x + w - 1, yy, Border)
  # The corners' diagonals.
  fb.setPixel(x + 1, y + 1, Border)
  fb.setPixel(x + w - 2, y + 1, Border)
  fb.setPixel(x + 1, y + h - 2, Border)
  fb.setPixel(x + w - 2, y + h - 2, Border)

proc drawPointer(fb: var FrameBuf; x, y: int; offset: float32) =
  ## The menu's pointer: a filled right-pointing triangle (4 px wide, 7
  ## tall, level with the row's capitals) with its left edge at x + `offset`
  ## px. The offset can be fractional: the edge pixels get partial
  ## brightness (coverage), so it moves smoothly on the 16-level panel.
  const Widths = [1, 2, 3, 4, 3, 2, 1]
  let whole = int(int32(offset))
  let frac = offset - whole.float32
  for i, w in Widths:
    let yy = y + 1 + i
    for k in 0 .. w:
      # Coverage of pixel k: the span runs from `frac` to `w + frac`.
      let cov = if k == 0: 1.0'f32 - frac elif k == w: frac else: 1.0'f32
      if cov > 0.0'f32:
        fb.setPixel(x + whole + k, yy, uint8(15.0'f32 * cov + 0.5'f32))

proc drawClock(fb: var FrameBuf; h, m: uint8; x, y: int; level: uint8) =
  ## "HH:MM" with its top left at (x, y) in the 6x10 font. The font's own
  ## colon sits a row low against its digits, so the colon is drawn here
  ## instead, as two 1x2 dots centred between the digit pairs.
  if level == 0: return
  let s = style(font6x10, level)
  var hh, mm: Text[4]
  hh.add2 h.int
  mm.add2 m.int
  fb.drawText(hh.chars, x, y, s)
  fb.drawText(mm.chars, x + 18, y, s)
  for dy in [2, 5]:
    fb.setPixel(x + 14, y + dy, level)
    fb.setPixel(x + 14, y + dy + 1, level)

proc drawLogo(fb: var FrameBuf; areaTop, areaBottom: int) =
  ## The FreeNetRadio logo: a broadcast symbol (a dot between radio-wave
  ## arcs that dim outwards) beside the word "NetRadio" (with "FREE" above
  ## it) in a top-to-bottom gradient, with a faint fading reflection
  ## underneath. Centred vertically between rows `areaTop` and `areaBottom`.
  const
    LogoText = "NetRadio"
    TextW = 8 * 10            # 10x20 font
    IconW = 34
    Gap = 10
    # In the 10x20 font's cell these letters occupy rows 3..15; the icon
    # reaches 4 px above and below them. "FREE" sits above the wordmark,
    # and the reflection starts ReflectGap px below the letters.
    LettersOffset = 3
    LettersH = 13
    FreeAbove = 7
    ReflectGap = 3
    ReflectRows = 10
    BlockH = FreeAbove + LettersH + ReflectGap + ReflectRows
  let blockTop = areaTop + (areaBottom - areaTop + 1 - BlockH) div 2
  let lettersTop = blockTop + FreeAbove
  let textTop = lettersTop - LettersOffset      # top of the text's cell
  let left = (Width - (IconW + Gap + TextW)) div 2
  let textX = left + IconW + Gap

  # Broadcast icon: centre dot plus three arcs each side, bright to dim.
  let (cx, cy) = (left + IconW div 2, lettersTop + LettersH div 2)
  fb.fillCircle(cx, cy, 7, 15)
  for i, level in [13'u8, 9, 5]:
    let diameter = 15 + i * 9
    fb.strokeArc(cx, cy, diameter, -40.0'f32, 80.0'f32, 2, level)
    fb.strokeArc(cx, cy, diameter, 140.0'f32, 80.0'f32, 2, level)

  # Wordmark, then recolour its pixels with a vertical gradient (15 -> 6).
  fb.drawText(LogoText, textX, textTop, style(font10x20, 15))
  for dy in 0 ..< 20:
    let level = uint8(15 - dy * 9 div 19)
    for x in textX ..< textX + TextW:
      if fb.pixel(x, textTop + dy) != 0:
        fb.setPixel(x, textTop + dy, level)

  # Reflection: the letters mirrored below them (bottom row first), a few
  # pixels down, fading out.
  let lettersBottom = lettersTop + LettersH - 1
  for r in 0 ..< ReflectRows:
    let srcY = lettersBottom - r
    let dstY = lettersBottom + 1 + ReflectGap + r
    if dstY >= Height: break
    let level = max(4 - r * 4 div ReflectRows, 1).uint8     # 4 -> 1
    for x in textX ..< textX + TextW:
      if fb.pixel(x, srcY) != 0:
        fb.setPixel(x, dstY, level)

  # FREE: the 5x7 capitals fill cell rows 1..6, so the cell starts 8 px
  # above the letters to leave a 1 px gap (the N's left stem is 1 px in).
  fb.drawText("FREE", textX + 1, lettersTop - 8, style(font5x7, 11, spacing = 1))

proc drawMuted(fb: var FrameBuf) =
  ## "MUTED" in dark bold text on a bright rounded box, centred at the
  ## bottom. The 6x13 bold glyphs otherwise touch: 3 px between letters.
  const (X, Y, W, H) = (Width div 2 - 50, 47, 100, 16)
  fb.fillRoundRect(X, Y, W, H, 4, 4, 15)
  fb.drawText("MUTED", X + (W - 1) div 2 + 1, Y + (H - 1) div 2 + 1,
              style(font6x13Bold, 0, spacing = 3), alCenter, blMiddle)

proc drawSpectrum(fb: var FrameBuf; bars: array[Bands, uint8]) =
  ## The spectrum analyser in the bottom 18 rows: one 5 px bar per band
  ## with a 1 px gap, brighter towards the top.
  const
    Top = 46
    Rows = Height - Top
    X0 = (Width - Bands * 6) div 2
  for i, v in bars:
    let h = (v.int * Rows + 254) div 255
    for k in 0 ..< h:
      let level = uint8(4 + k * 11 div (Rows - 1))
      for x in 0 ..< 5:
        fb.setPixel(X0 + i * 6 + x, Height - 1 - k, level)

proc drawBar(fb: var FrameBuf; y: int; level: uint8) =
  ## A solid white bar filled to `level` (0..255, one pixel per step). Its
  ## last Tip pixels fade out towards the end, so the bar's edge is soft
  ## and it grows and shrinks smoothly rather than in segments.
  const (BarH, Tip) = (8, 16)
  let width = (level.int * Width + 127) div 255     # 0..256
  if width == 0: return
  # Solid body, then the fading tip (brightest at the body, dimmest at the
  # very end). A short bar is all tip, scaled to its length.
  let tip = min(Tip, width)
  let body = width - tip
  if body > 0: fb.fillRect(0, y, body, BarH, 15)
  for k in 0 ..< tip:
    # k = 0 is next to the body, k = tip - 1 the last lit pixel.
    let gray = max((15 * (tip - k) + tip div 2) div (tip + 1), 2)   # stay above the track
    fb.fillRect(body + k, y, 1, BarH, gray.uint8)

proc drawMeter(fb: var FrameBuf; y: int; level: uint8; label: char) =
  ## An 8 px tall level bar at row `y` over a faint full-width track, with
  ## a little channel label at the left in the inverse of whatever is under
  ## it (black on the white bar, bright on the dim track).
  fb.fillRect(0, y, Width, 8, 1)
  fb.drawBar(y, level)
  # The 5x7 capitals are 6 rows tall: +1 centres them in the 8 px bar.
  fb.drawText([label], 2, y + 1, TextStyle(font: font5x7, invert: true))

proc drawScrollbar(fb: var FrameBuf; top, trackH, thumbY, thumbH: int) =
  ## A dim track with a brighter thumb, 2 px wide at the right edge.
  for yy in 0 ..< trackH:
    let level = if yy >= thumbY and yy < thumbY + thumbH: 9'u8 else: 2'u8
    fb.setPixel(Width - 2, top + yy, level)
    fb.setPixel(Width - 1, top + yy, level)

proc drawAbout(fb: var FrameBuf; first: int) =
  ## The About page: item 0 is the repository and licence, then one item
  ## per open source library (name and licence, with the author under it).
  ## Two items show at a time, starting at `first`.
  const (Top, Pitch) = (14, 12)
  let bright = style(font6x10, 15)
  let dim = style(font6x10, 7)
  let total = menu.aboutItems()
  for slot in 0 .. 1:
    let item = first + slot
    if item >= total: break
    let y = Top + slot * 2 * Pitch
    var line: Text[48]
    if item == 0:
      fb.drawText(about.Repo, 0, y, bright)
      line.add "License: "
      line.add about.License
      line.add " - libraries below"
      fb.drawText(line.chars, 0, y + Pitch, dim)
    else:
      let (name, author, license) = about.entry(item - 1)
      line.add "by "
      line.add author
      fb.drawText(name, 4, y, bright)
      fb.drawText(license, Width - 8, y, bright, alRight)
      fb.drawText(line.chars, 4, y + Pitch, dim)
  # Scrollbar down the right edge, as on the main list.
  let trackH = 4 * Pitch
  let span = max(total - 2, 1)
  let thumbH = max(trackH * 2 div max(total, 1), 4)
  fb.drawScrollbar(Top, trackH, (trackH - thumbH) * first div span, thumbH)

proc drawMenu(fb: var FrameBuf; inp: FrameInputs): bool =
  ## The settings menu, if it is open: a page filling everything below the
  ## status bar. The main list scrolls to keep the cursor in view, with a
  ## scrollbar down the right edge; the Equaliser page is a heading over
  ## the preset switcher and the three bands.
  const
    Visible = 5
    Top = 13
    Pitch = 10
    XCursor = 1
    XLabel = 10
    XValue = Width - 8
    BobMs = 600       # the pointer bobs 0..3 px right and back, eased
  var page: Page
  var selected: int
  if not menu.view(page, selected): return false
  if page == pgAbout:
    fb.drawAbout(selected)
    return true
  let phase = float32(animMs(inp) mod BobMs) / BobMs.float32
  let tri = if phase < 0.5'f32: phase * 2.0'f32 else: 2.0'f32 - phase * 2.0'f32
  let bob = 3.0'f32 * tri * tri * (3.0'f32 - 2.0'f32 * tri)

  var (rows, first, y0) = (Rows, min(max(selected - (Visible - 1), 0), Rows - Visible), Top)
  if page == pgEqualiser:
    fb.drawText("EQUALISER", XLabel, Top, style(font6x10, 6))
    (rows, first, y0) = (EqRows, 0, Top + Pitch)

  for row in first ..< first + min(rows, Visible):
    let y = y0 + (row - first) * Pitch
    let on = row == selected
    let text = style(font6x10, if on: 15 else: 9)
    var value: Text[24]
    var label = ""
    var adjustable, submenu = false   # changes with left/right; opens a submenu
    if page == pgMain:
      case row
      of RowVisual:
        value.add visualiserName(prefs.visualiser())
        (label, adjustable) = ("Visualiser", true)
      of RowEq:
        value.add eqPresetName()
        (label, submenu) = ("Equaliser", true)
      of RowZone:
        let mins = offsetQh() * 15
        value.add "UTC"
        value.add(if mins < 0: '-' else: '+')
        value.add2 abs(mins) div 60
        value.add ':'
        value.add2 abs(mins) mod 60
        (label, adjustable) = ("Time zone", true)
      of RowDst:
        value.add(if dstEnabled(): "On" else: "Off")
        (label, adjustable) = ("Daylight saving", true)
      of RowInfo:
        value.add statusInfoName(prefs.statusInfo())
        (label, adjustable) = ("Status bar", true)
      of RowSleepClock:
        value.add(if sleepClock(): "On" else: "Off")
        (label, adjustable) = ("Clock when sleeping", true)
      of RowAddress:
        if inp.net.hasIp: value.addIp inp.net.ip
        else: value.add "none"
        label = "Address"
      of RowAbout:
        value.add "Licenses"
        (label, submenu) = ("About", true)
      else: discard
    elif row == EqPreset:
      value.add eqPresetName()
      (label, adjustable) = ("Preset", true)
    else:
      let band = row - EqPreset - 1
      let db = eqGain(band)
      if db != 0:
        value.add(if db < 0: '-' else: '+')
      value.addInt abs(db)
      value.add " dB"
      (label, adjustable) = (["Bass", "Mid", "Treble"][band], true)
    if on: fb.drawPointer(XCursor, y, bob)
    fb.drawText(label, XLabel, y, text)
    # Adjustable values get arrows to show left/right changes them; a
    # submenu row shows an arrow towards the submenu.
    var v: Text[32]
    if on and adjustable: v.add "< "
    v.add value.chars
    if on and adjustable: v.add " >"
    elif on and submenu: v.add " >"
    fb.drawText(v.chars, XValue, y, text, alRight)

  if rows > Visible:
    let trackH = Visible * Pitch
    let thumbH = trackH * Visible div rows
    fb.drawScrollbar(Top, trackH, (trackH - thumbH) * first div (rows - Visible), thumbH)
  true

proc drawOsd(fb: var FrameBuf): bool =
  ## The message box over the middle of the screen, if one is showing.
  if not ui.osdActive(): return false
  const (X, Y, W, H) = (6, 13, Width - 12, 38)
  let (cx, cy) = (X + (W - 1) div 2, Y + (H - 1) div 2)
  fb.drawBox(X, Y, W, H)
  if ui.osd.big:
    fb.drawText(ui.osd.lines[0].chars, cx, cy, style(font10x20, 15), alCenter, blMiddle)
  else:
    let count = clamp(ui.osd.count, 0, ui.osd.lines.len)
    let top = cy - (count * 11) div 2 + 5
    for i in 0 ..< count:
      fb.drawText(ui.osd.lines[i].chars, Width div 2, top + i * 11,
                  style(font6x10, 15), alCenter, blMiddle)
  true

# ---- One frame --------------------------------------------------------------------

proc renderFrame*(d: var Display; fb: var FrameBuf; inp: FrameInputs): FrameResult =
  template s: untyped = inp.status
  let now = inp.nowMs
  let active = s.phase in {phBuffering, phPlaying}

  # Dim when stopped for DimAfterMs with no activity (decided before
  # drawing, so the normal logo can be left out while it slides).
  if s.phase == phStopped:
    d.stoppedSince = max(if d.stopped: d.stoppedSince else: now, ui.lastActivityMs)
    d.stopped = true
  else:
    d.stopped = false
  let overlayShowing = menu.isOpen() or ui.osdActive()
  let asleep = not overlayShowing and d.stopped and
               elapsedMs(d.stoppedSince, now) >= DimAfterMs
  let bootMs = elapsedMs(d.bootStartMs, now).float32
  let booting = bootMs < float32(BootFadeMs + BootHoldMs + BootSlideMs)

  # The big line: the title, or a status message when there isn't one.
  case s.phase
  of phError: d.title.set "Can't play"
  of phOffline: d.title.set "No network"
  of phStopped: d.title.set "Stopped"
  of phConnecting: d.title.set "Connecting..."
  of phBuffering, phPlaying:
    if not s.title.isEmpty: d.title.set s.title.chars
    elif s.station.isEmpty: d.title.set "Internet radio"
    else: d.title.set s.station.chars

  # Fall back gently (8/255 per frame) so the tip's fade is visible.
  d.meterL = max(s.levelL, d.meterL - min(d.meterL, 8))
  d.meterR = max(s.levelR, d.meterR - min(d.meterR, 8))
  if not active:
    d.meterL = 0
    d.meterR = 0

  # Spectrum bars: jump up to the latest data, fall 10/255 per frame.
  var fresh: array[Bands, uint8]
  if active: discard spectrum.read(fresh)     # stays zero without live data
  for i in 0 ..< Bands:
    d.bars[i] = max(fresh[i], d.bars[i] - min(d.bars[i], 10))

  fb.resetClip()
  fb.clear()
  let small = style(font6x10, 8)

  # The stream's icy-name is usually "Name: description".
  let parts = splitStation(s.station.chars)

  # Status bar, far right: the time, once NTP has set it. The other
  # right-hand text and the station name make room (5 chars + a gap).
  let info = prefs.statusInfo()
  let showClock = inp.hasClock and info in {InfoBoth, InfoClock}
  let showCodec = info in {InfoBoth, InfoCodec}
  let clockPx = if showClock: ClockW + 2 * 6 else: 0

  # Status bar, right: the format while playing, otherwise the state.
  var right: Text[24]
  if s.phase == phPlaying and s.sampleRate > 0:
    if showCodec:
      right.addInt s.bitrate
      right.add " kbps "
      right.addInt s.sampleRate div 1000
      right.add '.'
      right.addInt s.sampleRate mod 1000 div 100
      right.add " kHz"
  elif s.phase == phBuffering:
    right.add "BUFFERING "
    right.addInt s.bufferPct
    right.add '%'
  else:
    right.add PhaseUpper[s.phase]

  # Status bar, left: the address when nothing is playing (no station
  # chosen, stopped, or failed), otherwise the station name, scrolling if
  # it is too long to fit beside the right-hand text (2 characters' gap).
  let showAddress = s.url.isEmpty or s.phase in {phStopped, phError}
  var left: Text[48]
  var nameScrolling = false
  if not inp.net.linkUp:
    left.add "No network link"
  elif not inp.net.hasIp:
    left.add "Getting address..."
  elif showAddress:
    left.add "http://"
    left.addIp inp.net.ip
    left.add '/'
  else:
    let room = Width - (right.len + 2) * 6 - clockPx
    if not inp.presetName.isEmpty: d.name.set inp.presetName.chars
    else: d.name.setPart(s.station.chars, parts.n0, parts.n1)
    nameScrolling = d.name.drawIn(fb, style(font6x10, 13), 0, room, false)
  if not left.isEmpty:
    fb.drawText(left.chars, 0, 0, small)
  fb.drawText(right.chars, Width - 1 - clockPx, 0, small, alRight)
  if showClock:
    fb.drawClock(inp.clock[0], inp.clock[1], Width - ClockW, 0, 8)
  fb.hline(0, Width - 1, 11, 3)

  # The settings menu takes over everything below the status bar: nothing
  # else is drawn (or animated) while it is open.
  let menuOpen = menu.isOpen()
  var stationScrolling, titleScrolling = false
  if not menuOpen:
    # Station description (scrolling if long), or the error / hint text.
    if s.phase in {phError, phStopped, phOffline} and not s.message.isEmpty:
      d.station.set s.message.chars
    elif s.phase == phStopped:
      d.station.set "Select a station on the remote or web page"
    else:
      d.station.setPart(s.station.chars, parts.d0, parts.d1)
    stationScrolling = d.station.draw(fb, style(font6x10, 11), 14, false)

    # Title: centred if it fits, otherwise scrolling. When stopped the
    # status bar already says so: show the logo instead.
    if s.phase == phStopped:
      if not asleep and not booting:
        fb.drawLogo(LogoAwakeTop, LogoBottom)     # below the hint text
    else:
      titleScrolling = d.title.draw(fb, style(font10x20, 15), 25, true)
  let scrolling = stationScrolling or titleScrolling or nameScrolling

  # Level meters (only while a stream is active): left above right, filling
  # the bottom of the screen. When muted they are replaced by a flashing
  # (500 ms on/off) badge.
  if menuOpen:
    let t0 = nowUs()
    discard fb.drawMenu(inp)
    stats.overlayMaxUs = max(stats.overlayMaxUs, uint32(nowUs() - t0))
  elif active:
    if s.muted:
      if now div 500 mod 2 == 0: fb.drawMuted()
    elif spectrumShowing(now):
      fb.drawSpectrum(d.bars)
    else:
      fb.drawMeter(46, d.meterL, 'L')
      fb.drawMeter(56, d.meterR, 'R')

  let osd = not menuOpen and fb.drawOsd()

  # Dimming: the UI around the logo fades out, the logo slides to the
  # centre, and the whole panel dims.
  var fading = false
  if booting:
    fading = true     # 50 fps for the animation
    let fade = BootFadeMs.float32
    let hold = BootHoldMs.float32
    if bootMs < fade + hold:
      # Just the logo, centred, fading in from black.
      let e = smoothstep(min(bootMs / fade, 1.0'f32))
      fb.clear()
      fb.drawLogo(LogoDimTop, LogoBottom)
      fb.scaleLevels(level16(e))
    else:
      let t = min((bootMs - fade - hold) / BootSlideMs.float32, 1.0'f32)
      let e = smoothstep(t)
      # The UI fades in over the end of the slide...
      let uiPart = clamp((t - (1.0'f32 - UiFadePart)) / UiFadePart, 0.0'f32, 1.0'f32)
      if s.phase != phStopped and uiPart == 0.0'f32:
        # A restored station is already playing: the logo would land on
        # the meters, so it fades out where it is instead, then the UI
        # fades in.
        let fadeOut = 1.0'f32 - smoothstep(t / (1.0'f32 - UiFadePart))
        fb.clear()
        fb.drawLogo(LogoDimTop, LogoBottom)
        fb.scaleLevels(level16(fadeOut))
      else:
        fb.scaleLevels(level16(uiPart))
      # ...while the logo slides down to its usual place.
      if s.phase == phStopped:
        fb.drawLogo(lerp(LogoDimTop, LogoAwakeTop, e), LogoBottom)

  if asleep:
    # Progress 0..1 through the dim, eased (smoothstep).
    if not d.dimming:
      d.dimming = true
      d.dimStartMs = now
    var ms = elapsedMs(d.dimStartMs, now)
    if ui.capture.on:
      # Screen recordings run the dim on the frame count: the capture is
      # slower than the display.
      ms = d.dimFrames * FrameActiveMs
      inc d.dimFrames
    let t = min(ms.float32 / DimTimeMs.float32, 1.0'f32)
    let e = smoothstep(t)
    fading = t < 1.0'f32
    # The rest of the screen fades out over the first part.
    let uiPart = 1.0'f32 - min(t / UiFadePart, 1.0'f32)
    fb.scaleLevels(level16(uiPart))
    # The logo slides from its usual place to the centre.
    fb.drawLogo(lerp(LogoAwakeTop, LogoDimTop, e), LogoBottom)
    # The time, under the logo (the logo block ends at row 46 once it has
    # settled). It fades in over the last quarter of the slide: earlier,
    # the logo's reflection is still passing through the clock's rows.
    if prefs.sleepClock() and inp.hasClock:
      let c = smoothstep(clamp((t - 0.75'f32) / 0.25'f32, 0.0'f32, 1.0'f32))
      fb.drawClock(inp.clock[0], inp.clock[1], (Width - ClockW) div 2, 52,
                   uint8(7.0'f32 * c + 0.5'f32))
    result.dim = DimAmount * e
  else:
    d.dimming = false     # waking is instant (no slide back)
    d.dimFrames = 0
    result.dim = 0.0'f32

  # Muted counts as animating so the badge flashes on an even grid. The
  # menu's pointer bobs, so an open menu redraws on the fast grid.
  result.animating = menuOpen or active or scrolling
  result.fast = result.animating or osd or fading
