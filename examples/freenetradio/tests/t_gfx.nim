## Host tests for the framebuffer, fonts, drawing primitives and the pure
## half of the SSD1322 driver.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_gfx.nim
##
## The shape patterns marked "e-g" are copied from embedded-graphics 0.8.2's
## own unit tests (primitives/circle/points.rs, arc/styled.rs,
## rounded_rectangle/styled.rs); its `test_baseline` rule checks the fonts.
## Whole frames, including the logo's arcs, are compared against upstream's
## screenshots in t_display.nim.

import std/strutils
import ../framebuf, ../fonts, ../gfx, ../ssd1322

var store: array[BufLen, byte]
var fb = initFrameBuf(addr store)

proc rows(x, y, w, h: int): seq[string] =
  ## A region as text: ' ' for 0, '#' for 15, a hex digit otherwise.
  for yy in y ..< y + h:
    var line = ""
    for xx in x ..< x + w:
      let v = fb.pixel(xx, yy)
      line.add(if v == 0: ' ' elif v == 15: '#' else: "0123456789ABCDEF"[v])
    result.add line

proc lit(): int =
  for b in store:
    if (b shr 4) != 0: inc result
    if (b and 0x0F) != 0: inc result

block: # framebufferPacking
  fb.clear()
  fb.setPixel(0, 0, 0xA)
  fb.setPixel(1, 0, 0x5)
  doAssert store[0] == 0xA5              # left pixel in the high nibble
  fb.setPixel(255, 63, 0xF)
  doAssert store[BufLen - 1] == 0x0F
  fb.setPixel(254, 63, 0x3)
  doAssert store[BufLen - 1] == 0x3F
  doAssert fb.pixel(0, 0) == 0xA and fb.pixel(1, 0) == 0x5 and fb.pixel(255, 63) == 0xF
  doAssert store[128] == 0               # row 1 starts 128 bytes in
  fb.setPixel(0, 1, 7)
  doAssert store[128] == 0x70
  # Off-screen writes and reads are harmless.
  let before = store
  for (x, y) in [(-1, 0), (256, 0), (0, -1), (0, 64), (1000, 1000)]:
    fb.setPixel(x, y, 15)
    doAssert fb.pixel(x, y) == 0
  doAssert store == before
  fb.invertPixel(0, 0)
  doAssert fb.pixel(0, 0) == 5
  fb.clear(3)
  doAssert store[0] == 0x33 and store[BufLen - 1] == 0x33
  fb.clear()
  doAssert lit() == 0

block: # scaleLevels
  fb.clear()
  for v in 0 .. 15: fb.setPixel(v, 0, v.uint8)
  fb.scaleLevels(16)
  for v in 0 .. 15: doAssert fb.pixel(v, 0) == v.uint8
  fb.scaleLevels(8)
  for v in 0 .. 15: doAssert fb.pixel(v, 0) == uint8(v div 2)
  fb.clear(15)
  fb.scaleLevels(1)
  doAssert fb.pixel(9, 9) == 0           # 15/16 rounds down to nothing
  fb.clear(15)
  fb.scaleLevels(99)                     # clamped to 16
  doAssert fb.pixel(9, 9) == 15
  fb.scaleLevels(-3)                     # clamped to 0
  doAssert lit() == 0

block: # clip
  fb.clear()
  fb.setClip(10, 5, 4, 3)
  fb.fillRect(0, 0, 256, 64, 15)
  doAssert lit() == 12
  doAssert fb.pixel(10, 5) == 15 and fb.pixel(13, 7) == 15
  doAssert fb.pixel(9, 5) == 0 and fb.pixel(14, 5) == 0 and fb.pixel(10, 8) == 0
  fb.setClip(250, 60, 100, 100)          # cut at the screen edge
  fb.fillRect(0, 0, 300, 100, 15)
  doAssert lit() == 12 + 6 * 4
  fb.setClip(20, 20, -5, 0)              # empty
  fb.fillRect(0, 0, 256, 64, 15)
  doAssert lit() == 12 + 6 * 4
  fb.resetClip()
  fb.fillRect(0, 0, 256, 64, 15)
  doAssert lit() == 256 * 64

block: # fontMetricsAndGlyphs
  doAssert font5x7.charWidth == 5 and font5x7.charHeight == 7
  doAssert font6x10.charWidth == 6 and font6x10.charHeight == 10
  doAssert font6x13Bold.charWidth == 6 and font6x13Bold.charHeight == 13
  doAssert font10x20.charWidth == 10 and font10x20.charHeight == 20
  # e-g `test_baseline`: the lowest lit row of "A" is the font's baseline.
  for (font, baseline) in [(font5x7, 5), (font6x10, 7), (font6x13Bold, 10), (font10x20, 15)]:
    var lowest = -1
    for row in 0 ..< font.charHeight:
      if font.glyphRow('A', row) != 0: lowest = row
    doAssert lowest == baseline
    for row in 0 ..< font.charHeight:
      doAssert font.glyphRow(' ', row) == 0
      # No glyph spills past its cell.
      for c in ' ' .. '~':
        doAssert (font.glyphRow(c, row) and (0xFFFF'u16 shr font.charWidth)) == 0
      # Outside ASCII: the '?' glyph.
      doAssert font.glyphRow('\xE9', row) == font.glyphRow('?', row)
      doAssert font.glyphRow('\x07', row) == font.glyphRow('?', row)

  fb.clear()
  fb.drawText("h1", 0, 0, style(font6x10, 15))
  doAssert rows(0, 0, 12, 10) == @[
    "            ",
    "#       #   ",
    "#      ##   ",
    "# ##  # #   ",
    "##  #   #   ",
    "#   #   #   ",
    "#   #   #   ",
    "#   # ##### ",
    "            ",
    "            "]
  fb.clear()
  fb.drawText("F", 0, 0, style(font5x7, 15))
  doAssert rows(0, 0, 5, 7) == @[
    "#### ",
    "#    ",
    "###  ",
    "#    ",
    "#    ",
    "#    ",
    "     "]
  fb.clear()
  fb.drawText("N", 0, 0, style(font10x20, 15))
  doAssert rows(0, 3, 10, 13) == @[       # the capitals fill rows 3..15
    " ##    ## ",
    " ###   ## ",
    " ###   ## ",
    " ####  ## ",
    " ####  ## ",
    " ## ## ## ",
    " ## ## ## ",
    " ##  #### ",
    " ##  #### ",
    " ##   ### ",
    " ##   ### ",
    " ##    ## ",
    " ##    ## "]
  doAssert rows(0, 0, 10, 3) == @["          ", "          ", "          "]
  doAssert rows(0, 16, 10, 4) == @["          ", "          ", "          ", "          "]
  fb.clear()
  fb.drawText("M", 0, 0, style(font6x13Bold, 15))
  doAssert rows(0, 2, 6, 9) == @[
    "##  ##",
    "##  ##",
    "######",
    "######",
    "######",
    "##  ##",
    "##  ##",
    "##  ##",
    "##  ##"]

block: # textPlacement
  let s = style(font6x10, 9)
  doAssert s.advance == 6 and s.textWidth("abc") == 18 and s.textWidth("") == 0
  let wide = style(font6x13Bold, 0, spacing = 3)
  doAssert wide.advance == 9 and wide.textWidth("MUTED") == 5 * 9 - 3

  proc extent(): tuple[x0, y0, x1, y1: int] =
    result = (999, 999, -1, -1)
    for y in 0 ..< Height:
      for x in 0 ..< Width:
        if fb.pixel(x, y) != 0:
          result = (min(result.x0, x), min(result.y0, y), max(result.x1, x), max(result.y1, y))

  # "HH" in 6x10 lights columns 0..4 and 6..10, rows 1..7 of its cells.
  fb.clear()
  fb.drawText("HH", 100, 20, s)
  doAssert extent() == (100, 21, 110, 27)
  doAssert fb.pixel(100, 21) == 9
  # Right aligned: x is the rightmost column of the last cell.
  fb.clear()
  fb.drawText("HH", 100, 20, s, alRight)
  doAssert extent() == (100 - 11, 21, 100 - 11 + 10, 27)
  # Centred: starts (width - 1) div 2 left of x.
  fb.clear()
  fb.drawText("HH", 100, 20, s, alCenter)
  doAssert extent() == (100 - 5, 21, 100 - 5 + 10, 27)
  fb.clear()
  fb.drawText("HHH", 100, 20, s, alCenter)
  doAssert extent() == (100 - 8, 21, 100 - 8 + 16, 27)
  # Middle baseline: the cell starts (height - 1) div 2 above y.
  fb.clear()
  fb.drawText("HH", 100, 20, s, alLeft, blMiddle)
  doAssert extent() == (100, 20 - 4 + 1, 110, 20 - 4 + 7)
  fb.clear()
  fb.drawText("H", 100, 30, style(font10x20, 15), alCenter, blMiddle)
  doAssert extent().y0 == 30 - 9 + 3 and extent().x0 == 100 - 4 + 1
  # Character spacing moves the following letters only.
  fb.clear()
  fb.drawText("HH", 100, 20, style(font6x10, 9, spacing = 4))
  doAssert extent() == (100, 21, 114, 27)
  fb.clear()
  fb.drawText("HH", 100, 20, style(font6x10, 9, spacing = 4), alRight)
  doAssert extent() == (100 - 15, 21, 100 - 15 + 14, 27)
  # Empty text draws nothing, whatever the alignment.
  fb.clear()
  fb.drawText("", 100, 20, s, alRight)
  fb.drawText("", 100, 20, s, alCenter)
  doAssert lit() == 0
  # One '?' per non-ASCII character, as embedded-graphics draws a `str`.
  fb.clear()
  fb.drawText("a\xC3\xA9b", 0, 0, s)
  let utf = rows(0, 0, 24, 10)
  fb.clear()
  fb.drawText("a?b", 0, 0, s)
  doAssert rows(0, 0, 24, 10) == utf
  doAssert s.textWidth("a\xC3\xA9b") == 18

  # Text touches only its glyphs' pixels (no background).
  fb.clear(4)
  fb.drawText("H", 0, 0, s)
  doAssert fb.pixel(1, 1) == 4 and fb.pixel(0, 1) == 9 and fb.pixel(0, 0) == 4
  # Inverting text: 15 minus whatever is underneath, the level is ignored.
  fb.clear()
  fb.fillRect(0, 0, 3, 10, 15)
  fb.fillRect(3, 0, 3, 10, 1)
  fb.drawText("H", 0, 0, TextStyle(font: font6x10, level: 9, invert: true))
  doAssert fb.pixel(0, 1) == 0 and fb.pixel(4, 1) == 14 and fb.pixel(1, 1) == 15
  doAssert fb.pixel(1, 4) == 0 and fb.pixel(3, 4) == 14
  # Clipped text is cut mid-glyph.
  fb.clear()
  fb.setClip(102, 0, 6, 64)
  fb.drawText("HH", 100, 20, s)
  fb.resetClip()
  # Left: the first H's crossbar and right stem; right: the second H's
  # left stem and the start of its crossbar.
  doAssert extent() == (102, 21, 107, 27)
  doAssert fb.pixel(104, 21) == 9 and fb.pixel(106, 21) == 9 and fb.pixel(102, 21) == 0
  doAssert fb.pixel(102, 24) == 9 and fb.pixel(107, 24) == 9 and fb.pixel(105, 24) == 0
  # Partly off-screen text is safe.
  fb.clear()
  fb.drawText("HHHH", -9, -4, s)
  fb.drawText("HHHH", 250, 60, s)
  doAssert fb.pixel(0, 0) == 9

block: # linesAndRectangles
  fb.clear()
  fb.hline(0, 255, 11, 3)
  doAssert lit() == 256 and fb.pixel(0, 11) == 3 and fb.pixel(255, 11) == 3
  fb.clear()
  fb.fillRect(250, 60, 10, 10, 7)        # clipped at the corner
  doAssert lit() == 6 * 4
  fb.fillRect(5, 5, 0, 3, 7)
  fb.fillRect(5, 5, 3, -1, 7)
  doAssert lit() == 6 * 4

block: # circles (e-g primitives/circle/points.rs)
  const Circles = [
    @["#"],
    @["##", "##"],
    @[" # ", "###", " # "],
    @[" ## ", "####", "####", " ## "],
    @[" ### ", "#####", "#####", "#####", " ### "],
    @[" #### ", "######", "######", "######", "######", " #### "],
    @["  ###  ", " ##### ", "#######", "#######", "#######", " ##### ", "  ###  "],
    @["  ####  ", " ###### ", "########", "########", "########", "########",
      " ###### ", "  ####  "],
    @["  #####  ", " ####### ", "#########", "#########", "#########", "#########",
      "#########", " ####### ", "  #####  "],
  ]
  for i, pattern in Circles:
    let d = i + 1
    # `Circle::new((10, 10), d)` has its centre at 10 + (d - 1) div 2.
    let c = 10 + (d - 1) div 2
    fb.clear()
    fb.fillCircle(c, c, d, 15)
    doAssert rows(10, 10, d, d) == pattern
    var count = 0
    for line in pattern:
      for ch in line:
        if ch == '#': inc count
    doAssert lit() == count              # nothing outside the box
  fb.clear()
  fb.fillCircle(0, 0, 9, 15)             # off the corner: clipped, no crash
  fb.fillCircle(255, 63, 0, 15)
  doAssert fb.pixel(0, 0) == 15 and lit() == 5 + 5 + 5 + 4 + 3

block: # arcs (e-g primitives/arc/styled.rs)
  # tiny_arc: Arc::new((0, 0), 7, 210 deg, 120 deg), stroke 1.
  fb.clear()
  fb.strokeArc(13, 13, 7, 210.0, 120.0, 1, 15)
  doAssert rows(10, 10, 7, 7) == @[
    "  ###  ",
    " #   # ",
    "       ",
    "       ",
    "       ",
    "       ",
    "       "]

  # quadrant_arcs: a quarter-turn arc is the stroked circle clipped to that
  # quadrant (stroke 2, diameters 11 and 12, both directions).
  var whole, quarter: array[BufLen, byte]
  for d in [11, 12]:
    let c = 1 + (d - 1) div 2
    let box = d + 2                      # the stroke reaches 1 px outside
    let half = (box + 1) div 2
    fb.clear()
    fb.strokeArc(c, c, d, 0.0, 360.0, 2, 15)
    whole = store
    doAssert lit() > 0
    # (start, sweep, the quadrant is the right half, the bottom half)
    for (start, sweep, right, bottom) in [
        (0.0'f32, 90.0'f32, true, true), (90.0'f32, 90.0'f32, false, true),
        (180.0'f32, 90.0'f32, false, false), (270.0'f32, 90.0'f32, true, false),
        (0.0'f32, -90.0'f32, true, false), (90.0'f32, -90.0'f32, true, true),
        (180.0'f32, -90.0'f32, false, true), (270.0'f32, -90.0'f32, false, false)]:
      fb.clear()
      fb.strokeArc(c, c, d, start, sweep, 2, 15)
      quarter = store
      store = whole
      for y in 0 ..< Height:
        for x in 0 ..< Width:
          let inX = if right: x >= box - half else: x < half
          let inY = if bottom: y >= box - half else: y < half
          if not (inX and inY): fb.setPixel(x, y, 0)
      doAssert store == quarter

  # Sweeps of half a turn or more are the union of the two half planes.
  fb.clear()
  fb.strokeArc(30, 30, 21, 0.0, 180.0, 2, 15)
  doAssert fb.pixel(30, 40) == 15 and fb.pixel(30, 20) == 0
  fb.clear()
  fb.strokeArc(30, 30, 21, 0.0, 270.0, 2, 15)
  doAssert fb.pixel(30, 40) == 15 and fb.pixel(20, 30) == 15 and fb.pixel(30, 20) == 15
  doAssert fb.pixel(37, 23) == 0
  # The logo's arcs: 80 degrees either side of the centre, mirror images.
  fb.clear()
  fb.strokeArc(40, 30, 33, -40.0, 80.0, 2, 5)
  fb.strokeArc(40, 30, 33, 140.0, 80.0, 2, 5)
  for y in 0 ..< Height:
    for x in 0 .. 40:
      doAssert fb.pixel(40 - x, y) == fb.pixel(40 + x, y)
      doAssert fb.pixel(40 + x, 30 - min(y, 30)) == fb.pixel(40 + x, 30 + min(y, 30))
  doAssert fb.pixel(56, 30) == 5 and fb.pixel(57, 30) == 5 and fb.pixel(55, 30) == 0 and
           fb.pixel(58, 30) == 0
  doAssert fb.pixel(40, 14) == 0 and fb.pixel(40, 46) == 0
  fb.clear()
  fb.strokeArc(40, 30, 33, -40.0, 80.0, 0, 5)
  doAssert lit() == 0

block: # roundedRectangles (e-g primitives/rounded_rectangle/styled.rs)
  # full_height_corners: the top of a 40 px wide box with 20x20 corners.
  const Top = [
    "                ########                ",
    "            ################            ",
    "          ####################          ",
    "         ######################         ",
    "       ##########################       ",
    "      ############################      ",
    "     ##############################     ",
    "    ################################    ",
    "    ################################    ",
    "   ##################################   ",
    "  ####################################  ",
    "  ####################################  ",
    " ###################################### ",
    " ###################################### ",
    " ###################################### ",
    " ###################################### ",
    "########################################",
    "########################################",
    "########################################",
    "########################################"]
  fb.clear()
  fb.fillRoundRect(3, 2, 40, 40, 20, 20, 15)
  let got = rows(3, 2, 40, 40)
  for i in 0 ..< 20:
    doAssert got[i] == Top[i]
    doAssert got[39 - i] == Top[i]       # the bottom mirrors the top
  # Radii that do not fit are scaled down: 40x40 with huge corners is the same.
  fb.clear()
  fb.fillRoundRect(3, 2, 40, 40, 80, 80, 15)
  doAssert rows(3, 2, 40, 40) == got
  # The MUTED badge: 100x16 with 4 px corners.
  fb.clear()
  fb.fillRoundRect(78, 47, 100, 16, 4, 4, 15)
  let badge = rows(78, 47, 100, 16)
  for i, inset in [2, 1, 0, 0]:
    doAssert badge[i][0 ..< 6] == ' '.repeat(inset) & '#'.repeat(6 - inset)
    doAssert badge[i][^6 .. ^1] == '#'.repeat(6 - inset) & ' '.repeat(inset)
    doAssert badge[15 - i] == badge[i]
  for i in 2 .. 13: doAssert badge[i] == '#'.repeat(100)
  # No corners: a plain rectangle.
  fb.clear()
  fb.fillRoundRect(10, 10, 7, 5, 0, 0, 15)
  doAssert lit() == 35
  fb.fillRoundRect(10, 10, 0, 5, 2, 2, 15)
  doAssert lit() == 35

block: # ssd1322Commands
  doAssert ColStart == 0x1C and ColEnd == 0x5B
  doAssert initCommands().flat == @[
    0xFD'u8, 0x12,        # unlock
    0xAE,                 # display off
    0xCA, 0x3F,           # 64 rows
    0xA2, 0x00, 0xA1, 0x00,
    0xA0, 0x14, 0x11,     # re-map, dual COM
    0xB5, 0x00, 0xAB, 0x01,
    0xD1, 0xA2, 0x20,
    0xB3, 0x91,           # oscillator 9, divider 1
    0xB4, 0xA0, 0xFD,     # external VSL, enhanced low gray scale
    0xC1, 0x9F, 0xC7, 0x0F,
    0xB1, 0xE2,           # phase 2 = 14, phase 1 = 2
    0xBB, 0x1F, 0xB6, 0x08, 0xBE, 0x07,
    0xB9,                 # linear gray-scale table
    0xA6, 0xA9]
  doAssert windowCommands().flat == @[0x15'u8, 0x1C, 0x5B, 0x75, 0, 63]
  doAssert CmdWriteRam == 0x5C and CmdDisplayOn == 0xAF

  # Commands keep their argument boundaries (D/C goes high for arguments).
  var shape: seq[(byte, int)]
  let w = windowCommands()
  for cmd, first, count in w.commands:
    shape.add (cmd, count)
    doAssert w.arg(first) in [0x1C'u8, 0]
  doAssert shape == @[(0x15'u8, 2), (0x75'u8, 2)]

  # Tuning: clamping and the two B4 / gamma variants.
  var t = DefaultTuning
  doAssert t.clamped == t
  t.masterContrast = 99; t.phase1 = 0; t.phase2 = 1; t.prechargeVoltage = 200
  t.secondPrecharge = 77; t.vcomh = 9; t.clockDiv = 12; t.oscFreq = 16; t.gammaX10 = 2
  let c = t.clamped
  doAssert c.masterContrast == 15 and c.phase1 == 2 and c.phase2 == 3 and
           c.prechargeVoltage == 31 and c.secondPrecharge == 15 and c.vcomh == 7 and
           c.clockDiv == 10 and c.oscFreq == 15 and c.gammaX10 == 5
  t = DefaultTuning
  t.gammaX10 = 99
  doAssert t.clamped.gammaX10 == 30
  t = DefaultTuning
  t.externalVsl = false
  t.enhancedLowGs = false
  t.gammaX10 = 22
  var cmds: Cmds
  cmds.addTuning t
  let f = cmds.flat
  doAssert f[2 .. 4] == @[0xB4'u8, 0xA2, 0xB5]
  doAssert f.len == 17 + 16 + 1 and f[17] == 0xB8 and f[^1] == 0x00
  doAssert f[18 .. ^2] == @(gammaTable(22))

block: # gammaTable
  # Linear: 180 n / 15.
  doAssert gammaTable(10) == [12'u8, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 168, 180]
  for g in 5'u8 .. 30:
    let table = gammaTable(g)
    doAssert table[14] == 180
    for i in 1 ..< 15: doAssert table[i] > table[i - 1]
    doAssert table[0] >= 1
  # Values from the formula 180 (n/15)^gamma, rounded (gamma 2.2 and 0.5).
  doAssert gammaTable(22) == [1'u8, 2, 5, 10, 16, 24, 34, 45, 59, 74, 91, 110, 131, 155, 180]
  doAssert gammaTable(5) == [46'u8, 66, 80, 93, 104, 114, 123, 131, 139, 147, 154, 161, 168, 174, 180]
  # Steep curves start with the forced minimum steps.
  doAssert gammaTable(30)[0 .. 2] == [1'u8, 2, 3]

block: # dimCommands
  doAssert dimCommands(0.0).flat == @[0xC7'u8, 0x0F, 0xC1, 0x9F, 0xBB, 0x1F, 0xB6, 0x08]
  doAssert dimCommands(1.0).flat == @[0xC7'u8, 0, 0xC1, 40, 0xBB, 0, 0xB6, 1]
  doAssert dimCommands(7.5) == dimCommands(1.0) and dimCommands(-1.0) == dimCommands(0.0)
  # The idle dim (0.6): 15 -> 6, 159 -> 88 (87.6), 31 -> 12 (12.4), 8 -> 4 (3.8).
  doAssert dimCommands(0.6).flat == @[0xC7'u8, 6, 0xC1, 88, 0xBB, 12, 0xB6, 4]
  doAssert dimCommands(0.5).flat == @[0xC7'u8, 8, 0xC1, 100, 0xBB, 16, 0xB6, 5]

block: # spiPrescaler
  doAssert spiPrescaler(40_000_000, 9_000_000) == 2     # 6.67 MHz
  doAssert spiPrescaler(40_000_000, 10_000_000) == 1    # 10 MHz exactly
  doAssert spiPrescaler(160_000_000, 9_000_000) == 8    # 8.89 MHz
  doAssert spiPrescaler(40_000_000, 100_000_000) == 0
  doAssert spiPrescaler(40_000_000, 1_000) == 255
  for hz in [1_000_000, 4_000_000, 9_000_000, 10_000_000]:
    doAssert 40_000_000 div (2 * (spiPrescaler(40_000_000, hz) + 1)) <= hz

echo "t_gfx: ok"
