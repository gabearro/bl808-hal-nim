## Host tests for the NEC decoder (`ir_nec.nim`): synthetic edge trains.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_ir_nec.nim

import ../ir_nec, ../timebase

type
  Period = tuple[us: uint32, low: bool]
  Got = object
    presses: seq[Press]
    errors: int

proc run(d: var NecDecoder; train: openArray[Period]; got: var Got) =
  ## Feed periods as they would arrive: each one ends `us` later.
  for p in train:
    setFakeTimeUs(nowUs() + p.us)
    var press: Press
    case d.feed(p.us, p.low, press)
    of nePress: got.presses.add press
    of neError: inc got.errors
    of neNone: discard

proc frameBits(bits: uint32; scale = 1.0; count = 32): seq[Period] =
  ## Leader, `count` bits LSB first, trailing burst.
  proc t(us: int): uint32 = uint32(us.float * scale)
  result.add (t(9000), true)
  result.add (t(4500), false)
  for i in 0 ..< count:
    result.add (t(560), true)
    result.add ((if ((bits shr i) and 1) != 0: t(1690) else: t(560)), false)
  result.add (t(560), true)

proc frame(address, command: uint8; scale = 1.0): seq[Period] =
  frameBits(address.uint32 or ((not address).uint32 shl 8) or
            (command.uint32 shl 16) or ((not command).uint32 shl 24), scale)

proc repeatCode(gapUs = 40_000'u32): seq[Period] =
  @[(gapUs, false), (9000'u32, true), (2250'u32, false), (560'u32, true)]

block: # a standard frame
  var d: NecDecoder
  var got: Got
  d.run(@[(123_456'u32, false)] & frame(0x00, 0x45), got)   # first period after boot is junk
  doAssert got.errors == 0 and got.presses.len == 1
  doAssert got.presses[0] == Press(address: 0, command: 0x45, repeat: false)

block: # every command value, another address
  var d: NecDecoder
  var got: Got
  for c in 0 .. 255:
    d.run(@[(40_000'u32, false)] & frame(0x5A, c.uint8), got)
  doAssert got.errors == 0 and got.presses.len == 256
  for c in 0 .. 255:
    doAssert got.presses[c] == Press(address: 0x5A, command: c.uint8, repeat: false)

block: # extended NEC: a 16-bit address when the second byte isn't the inverse
  var d: NecDecoder
  var got: Got
  d.run(frameBits(0x34'u32 or (0x12'u32 shl 8) or (0x1C'u32 shl 16) or (0xE3'u32 shl 24)), got)
  doAssert got.presses == @[Press(address: 0x1234, command: 0x1C, repeat: false)]

block: # a bad command check byte is an error, not a press
  var d: NecDecoder
  var got: Got
  d.run(frameBits(0x00'u32 or (0xFF'u32 shl 8) or (0x45'u32 shl 16) or (0xBB'u32 shl 24)), got)
  doAssert got.presses.len == 0 and got.errors == 1
  d.run(@[(40_000'u32, false)] & frame(0, 0x46), got)     # and the next frame decodes
  doAssert got.presses.len == 1 and got.errors == 1

block: # repeat codes while held, each within 250 ms of the last
  var d: NecDecoder
  var got: Got
  d.run(frame(0, 0x18), got)
  d.run(repeatCode(), got)
  for _ in 0 ..< 20:
    d.run(repeatCode(96_000), got)      # every ~108 ms
  doAssert got.errors == 0 and got.presses.len == 22
  doAssert not got.presses[0].repeat
  for i in 1 .. 21:
    doAssert got.presses[i] == Press(address: 0, command: 0x18, repeat: true)

block: # a repeat code too long after the press is ignored (and is no error)
  var d: NecDecoder
  var got: Got
  d.run(frame(0, 0x18), got)
  d.run(repeatCode(240_000), got)       # ends 251.8 ms after the frame
  doAssert got.presses.len == 1 and got.errors == 0
  d.run(repeatCode(96_000), got)        # still nothing: the window is not reopened
  doAssert got.presses.len == 1
  # Just inside the window.
  var d2: NecDecoder
  var got2: Got
  d2.run(frame(0, 0x18), got2)
  d2.run(repeatCode(237_000), got2)     # 248.8 ms
  doAssert got2.presses.len == 2 and got2.presses[1].repeat

block: # a repeat code with no press before it
  var d: NecDecoder
  var got: Got
  d.run(repeatCode(), got)
  doAssert got.presses.len == 0 and got.errors == 0

block: # timing tolerances
  proc decodes(train: seq[Period]): bool =
    var d: NecDecoder
    var got: Got
    d.run(train, got)
    got.presses.len == 1
  doAssert decodes(frame(0, 0x45, 0.88)) and decodes(frame(0, 0x45, 1.13))
  var f = frame(0, 0x45)
  f[0].us = 7500
  doAssert decodes(f)
  f[0].us = 10_500
  doAssert decodes(f)
  f[0].us = 10_501
  doAssert not decodes(f)
  f[0].us = 7499
  doAssert not decodes(f)
  f = frame(0, 0x45)
  f[1].us = 3800
  doAssert decodes(f)
  f[1].us = 5200
  doAssert decodes(f)
  f[1].us = 5201
  doAssert not decodes(f)
  f = frame(0, 0x45)
  f[2].us = 260
  f[4].us = 860
  doAssert decodes(f)
  f[2].us = 259
  doAssert not decodes(f)
  f = frame(0, 0x45)
  f[3].us = 2090          # bit 0 of 0x00 read as a 1: address 0x01, ~address 0xFF -> extended
  var d: NecDecoder
  var got: Got
  d.run(f, got)
  doAssert got.presses == @[Press(address: 0xFF01, command: 0x45, repeat: false)]
  f[3].us = 1000          # neither a 0 gap (<= 860) nor a 1 gap (>= 1290)
  doAssert not decodes(f)
  # The repeat gap: 2250 +/- 500.
  proc repeats(gap: uint32): bool =
    var d: NecDecoder
    var got: Got
    d.run(frame(0, 0x45), got)
    d.run(@[(40_000'u32, false), (9000'u32, true), (gap, false), (560'u32, true)], got)
    got.presses.len == 2
  doAssert repeats(1750) and repeats(2750) and not repeats(1749) and not repeats(2751)

block: # noise
  var d: NecDecoder
  var got: Got
  # Stray pulses while idle are ignored without counting errors.
  d.run(@[(300'u32, true), (5000'u32, false), (120'u32, true), (70_000'u32, false),
          (2000'u32, true), (800'u32, false)], got)
  doAssert got.errors == 0 and got.presses.len == 0
  # A glitch in the middle of a frame drops it with one error...
  var f = frame(0, 0x45)
  f.insert((100'u32, true), 20)
  d.run(f, got)
  doAssert got.presses.len == 0 and got.errors == 1
  # ...and the next clean frame decodes.
  d.run(@[(40_000'u32, false)] & frame(0, 0x45), got)
  doAssert got.presses.len == 1 and got.errors == 1
  # A frame cut short and a new one straight after: the new leader is what
  # reveals the error, so (as upstream) that frame is lost too; the one
  # after it decodes.
  var cut = frame(0, 0x46)
  cut.setLen(30)
  d.run(cut & frame(0, 0x47), got)
  doAssert got.errors == 2 and got.presses.len == 1
  d.run(@[(40_000'u32, false)] & frame(0, 0x47), got)
  doAssert got.errors == 2 and got.presses.len == 2 and got.presses[1].command == 0x47
  # A leader followed by a wrong gap.
  d.run(@[(40_000'u32, false), (9000'u32, true), (3200'u32, false)], got)
  doAssert got.errors == 3
  # A leader directly after a repeat's gap restarts (no error).
  d.run(@[(9000'u32, true), (2250'u32, false)] & frame(0, 0x09), got)
  doAssert got.errors == 3 and got.presses[^1].command == 0x09

block: # the check byte failure counts once
  var d: NecDecoder
  var got: Got
  d.run(frameBits(0), got)      # command 0x00, check 0x00
  doAssert got.errors == 1 and got.presses.len == 0

echo "t_ir_nec: ok"
