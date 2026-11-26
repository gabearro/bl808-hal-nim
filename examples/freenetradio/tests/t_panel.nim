## The display driver's byte stream, played into a model of the SSD1322
## (`panel_model.nim`): the init sequence, the dim commands, the frame window
## and a frame must be commands the controller knows with the right number of
## arguments, and the picture must land where a 256x64 module shows it.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_panel.nim

import ../framebuf, ../ssd1322
import ./panel_model

proc send(p: var Panel; cmds: Cmds) =
  ## As `Oled.send` does on the wire: the command byte with D/C low, its
  ## arguments with D/C high.
  for cmd, first, count in cmds.commands:
    p.feed(false, cmd)
    for i in 0 ..< count: p.feed(true, cmds.arg(first + i))

proc sendFrame(p: var Panel; buf: array[BufLen, byte]) =
  p.send windowCommands()
  p.feed(false, CmdWriteRam)
  for b in buf: p.feed(true, b)

var screen: array[BufLen, byte]
var fb = initFrameBuf(addr screen)
# A picture with no symmetry: every pixel depends on x and y differently.
for y in 0 ..< Height:
  for x in 0 ..< Width:
    fb.setPixel(x, y, uint8((x * 7 + y * 3 + (x shr 4)) and 15))

var p = initPanel()
p.send initCommands()
p.sendFrame screen
p.feed(false, CmdDisplayOn)
doAssert p.errors.len == 0, $p.errors
doAssert p.on and p.upright
doAssert p.ramBytes == BufLen
doAssert p.colStart == VisibleFirstCol and p.colEnd - p.colStart + 1 == VisibleCols
doAssert p.rowStart == 0 and p.rowEnd == VisibleRows - 1
for y in 0 ..< Height:
  for x in 0 ..< Width:
    doAssert p.pixel(x, y) == fb.pixel(x, y), "pixel " & $x & "," & $y

# A second frame starts again at the top left, and dimming in between is
# made of known commands.
for amount in [0.0'f32, 0.5, 1.0]:
  p.send dimCommands(amount)
fb.setPixel(0, 0, 15)
fb.setPixel(255, 63, 9)
p.sendFrame screen
doAssert p.errors.len == 0, $p.errors
doAssert p.pixel(0, 0) == 15 and p.pixel(255, 63) == 9

# Every gamma setting gives a table the controller accepts.
for gamma in 5'u8 .. 30:
  var t = DefaultTuning
  t.gammaX10 = gamma
  var q = initPanel()
  q.send initCommands(t)
  doAssert q.errors.len == 0, $gamma & ": " & $q.errors

# The model does notice mistakes.
block:
  var q = initPanel()
  q.feed(false, 0x15)
  q.feed(true, 0x1C)
  q.feed(false, 0x75)             # cut short
  doAssert q.errors.len == 1
  q = initPanel()
  q.feed(true, 0x00)              # stray data
  doAssert q.errors.len == 1

echo "t_panel: ok"
