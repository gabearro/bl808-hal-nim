## Drawing into the framebuffer: the pieces of embedded-graphics 0.8.2 that
## upstream's display code calls, rasterised pixel for pixel the same way
## (mono-font text, filled rectangle, filled rounded rectangle, filled
## circle, stroked arc). Pure Nim.
##
## Coordinates follow embedded-graphics: a shape "with centre" c and size n
## starts at c - (n - 1) div 2, and a rectangle's centre is its top left
## plus (size - 1) div 2.

import ./framebuf, ./fonts
export framebuf.fillRect

{.localPassC: "-ffp-contract=off".}   # the arc's trigonometry must round as upstream's

type
  Baseline* = enum
    blTop, blMiddle
  Align* = enum
    alLeft, alCenter, alRight

  TextStyle* = object
    font*: FontId
    level*: uint8       ## gray level 0..15
    spacing*: int       ## extra pixels between characters
    invert*: bool       ## invert what is underneath instead of using `level`

func style*(font: FontId; level: uint8; spacing = 0): TextStyle {.inline.} =
  TextStyle(font: font, level: level, spacing: spacing)

func advance*(s: TextStyle): int {.inline.} =
  ## Pixels from one character's left edge to the next.
  s.font.charWidth + s.spacing

func isContinuation(c: char): bool {.inline.} = (c.ord and 0xC0) == 0x80

func charCount(text: openArray[char]): int =
  ## Characters as embedded-graphics counts them (UTF-8 code points).
  for c in text:
    if not c.isContinuation: inc result

func textWidth*(s: TextStyle; text: openArray[char]): int =
  ## Width of the text's bounding box (no spacing after the last character).
  let n = charCount(text)
  if n == 0: 0 else: n * s.advance - s.spacing

proc drawText*(fb: var FrameBuf; text: openArray[char]; x, y: int;
               s: TextStyle; align = alLeft; baseline = blTop) =
  ## Draw one line of text: only the glyphs' set pixels are touched. `x` is
  ## the left edge, the centre or the rightmost pixel according to `align`;
  ## `y` is the top or the middle row of the character cell.
  let w = s.font.charWidth
  let h = s.font.charHeight
  let span = textWidth(s, text) - 1       # may be -1 for empty text
  var px = case align
    of alLeft: x
    of alCenter: x - span div 2
    of alRight: x - span
  let top = if baseline == blMiddle: y - (h - 1) div 2 else: y
  for c in text:
    if c.isContinuation: continue         # one glyph ('?') per non-ASCII character
    fb.drawMask(px, top, w, s.font.glyphRows(c), s.level, s.invert)
    px += w + s.spacing

proc hline*(fb: var FrameBuf; x0, x1, y: int; level: uint8) =
  ## A 1 px horizontal line from `x0` to `x1` inclusive.
  fb.fillRect(x0, y, x1 - x0 + 1, 1, level)

# ---- Circles and arcs -------------------------------------------------------
# embedded-graphics tests doubled coordinates against a squared diameter, so
# circles of even diameter are centred between pixels.

func circleThreshold(diameter: int): int {.inline.} =
  if diameter <= 4: diameter * diameter - diameter div 2 else: diameter * diameter

proc fillCircle*(fb: var FrameBuf; cx, cy, diameter: int; level: uint8) =
  ## `Circle::with_center(c, d)` filled.
  if diameter <= 0: return
  let left = cx - (diameter - 1) div 2
  let top = cy - (diameter - 1) div 2
  let c2x = left * 2 + diameter - 1
  let c2y = top * 2 + diameter - 1
  let threshold = circleThreshold(diameter)
  for y in top ..< top + diameter:
    let dy = 2 * y - c2y
    for x in left ..< left + diameter:
      let dx = 2 * x - c2x
      if dx * dx + dy * dy < threshold:
        # The row is symmetric: it runs from here to the mirrored column.
        fb.fillRect(x, y, diameter - 2 * (x - left), 1, level)
        break

# micromath 2.x `F32Ext::cos` / `sin`, which embedded-graphics uses without
# std: a parabola fit, good to about 0.1 %. Kept so the arcs' ends fall on
# the same pixels.
func mmFloor(x: float32): float32 =
  result = float32(int32(x))
  if x < result: result -= 1.0'f32

func mmCos(a: float32): float32 =
  var x = a * (0.318_309_886_183_790_671_54'f32 / 2.0'f32)
  x -= 0.25'f32 + mmFloor(x + 0.25'f32)
  x *= 16.0'f32 * (abs(x) - 0.5'f32)
  x += 0.225'f32 * x * (abs(x) - 1.0'f32)
  x

func mmSin(a: float32): float32 =
  mmCos(a - 3.141_592_653_589_793_238_46'f32 / 2.0'f32)

const
  Pi32 = 3.141_592_653_589_793_238_46'f32
  NormalScale = 1024'f32

func radians(degrees: float32): float32 {.inline.} = degrees * Pi32 / 180.0'f32

func halfPlane(angle: float32): (int, int) =
  ## Normal vector of the line through the origin at `angle`
  ## (`OriginLinearEquation::with_angle`).
  if angle == radians(180.0'f32):
    (0, -1024)
  else:
    let vx = int(int32(mmCos(angle) * NormalScale))
    let vy = int(int32(mmSin(angle) * NormalScale))
    (-vy, vx)

proc strokeArc*(fb: var FrameBuf; cx, cy, diameter: int;
                startDeg, sweepDeg: float32; width: int; level: uint8) =
  ## `Arc::with_center(c, d, start, sweep)` with a centred stroke `width`
  ## pixels wide. Angles in degrees, 0 = +x, increasing clockwise on screen.
  if width <= 0 or diameter <= 0: return
  let outside = width div 2
  let inside = (width + 1) div 2
  # The arc's circle, then the stroke's outer and inner edges around its
  # centre (`Circle::offset`).
  let left = cx - (diameter - 1) div 2
  let top = cy - (diameter - 1) div 2
  let ccx = left + (diameter - 1) div 2
  let ccy = top + (diameter - 1) div 2
  let outerD = diameter + 2 * outside
  let innerD = max(diameter - 2 * inside, 0)
  let oLeft = ccx - (outerD - 1) div 2
  let oTop = ccy - (outerD - 1) div 2
  let c2x = oLeft * 2 + outerD - 1
  let c2y = oTop * 2 + outerD - 1
  let outerT = circleThreshold(outerD)
  let innerT = circleThreshold(innerD)

  # The sector between the two radii (`PlaneSector`).
  var a0 = radians(startDeg)
  let sweep = radians(sweepDeg)
  var a1 = a0 + sweep
  let sweepAbs = abs(sweep)
  let whole = sweepAbs >= 2.0'f32 * Pi32
  let union = sweepAbs >= Pi32
  if sweep < 0: swap(a0, a1)
  let (rx, ry) = halfPlane(a0)      # points at or right of the start line
  let (lx, ly) = halfPlane(a1)      # points at or left of the end line

  for y in oTop ..< oTop + outerD:
    let dy = 2 * y - c2y
    for x in oLeft ..< oLeft + outerD:
      let dx = 2 * x - c2x
      let dist = dx * dx + dy * dy
      if dist < outerT and dist >= innerT:
        let onLeft = dx * lx + dy * ly <= 0
        let onRight = dx * rx + dy * ry >= 0
        if whole or (if union: onLeft or onRight else: onLeft and onRight):
          fb.setPixel(x, y, level)

# ---- Rounded rectangle ------------------------------------------------------

func inEllipse(px, py, ex, ey, rx, ry, threshold: int): bool {.inline.} =
  ## Whether a pixel is inside the (2rx x 2ry) ellipse whose bounding box
  ## starts at (ex, ey).
  let dx = 2 * px - (2 * ex + 2 * rx - 1)
  let dy = 2 * py - (2 * ey + 2 * ry - 1)
  if rx == ry: dx * dx + dy * dy < threshold
  else: 4 * ry * ry * dx * dx + 4 * rx * rx * dy * dy < threshold

proc fillRoundRect*(fb: var FrameBuf; x, y, w, h, rx, ry: int; level: uint8) =
  ## `RoundedRectangle::with_equal_corners(Rectangle(x, y, w, h), (rx, ry))`
  ## filled.
  if w <= 0 or h <= 0: return
  # Radii that don't fit are scaled down together (`CornerRadii::confine`).
  var (rx, ry) = (max(rx, 0), max(ry, 0))
  var (overlap, size, corner) = (0, 0, 0)
  if 2 * rx - w > overlap: (size, corner, overlap) = (w, 2 * rx, 2 * rx - w)
  if 2 * ry - h > overlap: (size, corner, overlap) = (h, 2 * ry, 2 * ry - h)
  if overlap > 0 and corner > 0:
    rx = rx * size div corner
    ry = ry * size div corner
  # Each corner is a quarter of a (2rx x 2ry) ellipse, tested in doubled
  # coordinates about its centre (`EllipseQuadrant`, `EllipseContains`).
  let threshold = if rx == ry: circleThreshold(2 * rx) else: 16 * rx * rx * ry * ry
  for yy in y ..< y + h:
    var xs = x
    var xe = x + w
    if yy < y + ry or yy >= y + h - ry:
      let ey = if yy < y + ry: y else: y + h - 2 * ry
      while xs < x + w and not inEllipse(xs, yy, x, ey, rx, ry, threshold): inc xs
      if xs == x + w: xs = x                    # no pixel found: the full row
      while xe > x and not inEllipse(xe - 1, yy, x + w - 2 * rx, ey, rx, ry, threshold): dec xe
      if xe == x: xe = x + w
    fb.fillRect(xs, yy, xe - xs, 1, level)
