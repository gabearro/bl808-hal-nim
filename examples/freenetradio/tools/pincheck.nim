## Checks what a `-d:radioDiag` board reports about its own pins
## (`pincap.nim`). Run on the host:
##
##   curl -X POST 'http://<radio>/selftest/capture?t=now'     # calibrates the rate
##   curl -X POST 'http://<radio>/selftest/capture?t=init'
##   curl -o init.bin http://<radio>/selftest/capture
##   curl -X POST 'http://<radio>/selftest/capture?t=fast'
##   curl -o fast.bin http://<radio>/selftest/capture
##   curl -o i2s.txt http://<radio>/selftest/i2s               # while playing
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tools/pincheck.nim \
##     init.bin fast.bin i2s.txt
##
## Display captures (CS, D/C and RES are GPIOs, so the chip can read their
## pads back): the pattern of chip selects and D/C levels must be the
## driver's command lists, each byte taking as long as the SPI clock says.
## The I2S report: the block's registers must describe what a PCM5102A
## expects, and the measured frame rate must be the stream's sample rate.
##
## The BL808 only reads a pad back while it is a GPIO, so the I2S pins and
## SCLK/SDIN themselves cannot be seen this way: those need the real parts
## or a logic analyser.

import std/[os, strutils, parseutils, math]
import ../board, ../framebuf, ../ssd1322

const
  HeaderBytes = 64
  ExcerptBytes = 1024
  SpiSourceHz = 40_000_000
  SlowHz = 1_000_000

var failures = 0

proc check(ok: bool; what: string) =
  echo (if ok: "  ok    " else: "  FAIL  "), what
  if not ok: inc failures

proc le32(s: string; at: int): uint32 =
  for i in 0 .. 3: result = result or (s[at + i].uint32 shl (8 * i))

func byteUs(prescaler: int): float =
  ## One byte on the wire: eight bits of two half-periods, plus the start,
  ## stop and interval delays, each (prescaler + 1) source clocks.
  float(19 * (prescaler + 1)) / (SpiSourceHz / 1_000_000)

type Run = tuple[low: bool, us: float]

proc display(path, data: string) =
  let samples = data.le32(4).int
  var rate = data.le32(12).float
  let trigger = data.le32(16)
  let cs = data[32 + 5].int
  let dc = data[32 + 6].int
  let res = data[32 + 7].int
  echo path, ": ", ["at once", "a slow frame", "panel init and a slow frame",
                    "a frame at full speed"][min(trigger, 3)]
  if rate == 0:
    rate = 4_163_000
    echo "  note  no sampling rate in the capture (POST t=now first); assuming ", rate.int
  template level(i, pin: int): bool =
    ((data.le32(HeaderBytes + ExcerptBytes + 4 * i) shr pin) and 1) != 0
  let us = 1e6 / rate

  var resHigh = true
  for i in 0 ..< samples:
    if not level(i, res): resHigh = false
  check resHigh, "RES stays high"
  if trigger == 0:
    echo "  note  nothing to decode: interrupts were off, so no frame was being sent"
    return

  # Each chip select: the runs of D/C low (command bytes) and high (arguments).
  var selects: seq[seq[Run]]
  var i = 0
  var lastEndsOpen = false
  while i < samples:
    if level(i, cs):
      inc i
      continue
    var runs: seq[Run]
    while i < samples and not level(i, cs):
      let low = not level(i, dc)
      var j = i
      while j < samples and not level(j, cs) and (not level(j, dc)) == low: inc j
      runs.add (low, float(j - i) * us)
      i = j
    lastEndsOpen = i >= samples
    selects.add runs

  let slow = trigger != 3
  let perByte = byteUs(spiPrescaler(SpiSourceHz, if slow: SlowHz else: OledSpiHz))
  let frameUs = BufLen.float * perByte

  if not slow:
    # Full speed: too fast to count bytes, but the frame's length shows.
    var dataUs = 0.0
    var whole = false
    for n, runs in selects:
      if runs.len > 0 and not runs[^1].low and runs[^1].us > 1000:
        dataUs = runs[^1].us
        whole = n < selects.high or not lastEndsOpen
        break
    check dataUs > 0, "a frame's data was seen"
    if dataUs > 0:
      echo "  note  the 8192 bytes took ", formatFloat(dataUs / 1000, ffDecimal, 1),
        " ms", (if whole: "" else: " or more (the capture ended first)"),
        "; the SPI clock alone needs ", formatFloat(frameUs / 1000, ffDecimal, 1),
        " ms. The capture DMA shares the bus with the display DMA, so read",
        " the normal frame rate from \"display frames\" in /stats."
      check dataUs >= frameUs * 0.98, "not faster than the configured clock allows"
      check (not whole) or dataUs < 90_000, "inside the 100 ms frame deadline"
    return

  # Slow: turn the runs into commands with argument counts.
  var seen: seq[int]            # argument bytes of each command, in order
  var first = true
  var dataRun = 0.0
  for runs in selects:
    var k = 0
    while k < runs.len:
      if not runs[k].low:
        # CS falls an instruction before D/C: a sample can land in between.
        check runs[k].us < perByte / 2, "D/C is low when a chip select starts"
        inc k
        continue
      # The first byte after the capture starts can be late (cold code).
      let cmds = if first: 1 else: max(1, int(round(runs[k].us / perByte)))
      first = false
      for _ in 1 ..< cmds: seen.add 0
      if k + 1 < runs.len:
        if runs[k + 1].us > 100 * perByte: dataRun = runs[k + 1].us
        seen.add int(round(runs[k + 1].us / perByte))
        k += 2
      else:
        seen.add 0
        k += 1

  var expected: seq[int]
  var names: seq[byte]
  if trigger == 2:
    for cmd, _, count in initCommands().commands:
      expected.add count
      names.add cmd
  for cmd, _, count in windowCommands().commands:
    expected.add count
    names.add cmd
  names.add CmdWriteRam

  check seen.len == expected.len + 1,
    $seen.len & " commands seen, " & $(expected.len + 1) & " sent"
  var same = seen.len == expected.len + 1
  if same:
    for n in 0 ..< expected.len:
      if seen[n] != expected[n]:
        same = false
        echo "        command 0x", toHex(names[n]), ": ", seen[n], " argument bytes, sent ",
          expected[n]
  check same, "every command has its argument count (D/C low for the command byte only)"
  check dataRun > 0, "pixel data follows 0x5C with D/C high"
  if dataRun > 0 and not lastEndsOpen:
    check abs(dataRun - frameUs) < frameUs * 0.05,
      "the frame is " & $int(round(dataRun / perByte)) & " bytes long at 1 MHz"
  elif dataRun > 0:
    echo "  note  the capture ended ", int(dataRun / perByte), " bytes into the frame"
  echo "  note  one byte takes ", formatFloat(perByte, ffDecimal, 2),
    " us at 1 MHz; the counts above only come out right if SPI0 really clocks at that rate"

proc i2s(path, text: string) =
  echo path, ": I2S"
  var config, bclk, fifo0, io: uint32
  var frames, us = 0
  for line in text.splitLines:
    template hexAfter(prefix: string; into: var uint32) =
      if line.startsWith(prefix):
        var v: int
        discard parseHex(line[prefix.len .. ^1].strip, v)
        into = v.uint32
    hexAfter("i2s config ", config)
    hexAfter("i2s bclk ", bclk)
    hexAfter("i2s fifo0 ", fifo0)
    hexAfter("i2s io ", io)
    if line.startsWith("i2s frames taken: "):
      let parts = line.splitWhitespace
      frames = parseInt(parts[3])
      us = parseInt(parts[5])
  template bits(v: uint32; lo, n: int): uint32 = (v shr lo) and ((1'u32 shl n) - 1)
  # What a PCM5102A in its default (I2S) format with SCK grounded needs.
  check config.bits(0, 1) == 1 and config.bits(1, 1) == 0, "master: the BL808 makes BCK and LCK"
  check config.bits(2, 1) == 1, "transmitter on"
  check config.bits(4, 2) == 0, "stereo, not muted"
  check config.bits(6, 1) == 0 and config.bits(7, 2) == 0,
    "LCK is a 50% square wave, two channels per frame"
  check config.bits(12, 2) == 3, "32 BCK per channel: BCK = 64 x fs"
  check config.bits(14, 2) == 1, "16-bit samples"
  check config.bits(16, 2) == 0 and config.bits(25, 1) == 1 and config.bits(20, 5) == 0,
    "Philips I2S: MSB one BCK after the LCK edge"
  check config.bits(18, 1) == 0, "MSB first"
  check io == 0, "no signal inverted: left while LCK is low, data changes on BCK falling"
  check fifo0.bits(8, 1) == 1 and fifo0.bits(9, 1) == 0,
    "one FIFO word per stereo frame, left in the low half"
  check fifo0.bits(0, 1) == 1, "DMA requests for the transmitter"
  check bclk.bits(0, 12) == bclk.bits(16, 12), "BCK has a 50% duty cycle"
  if us > 0:
    let hz = frames.float * 1e6 / us.float
    var nearest = 0.0
    for rate in [8000.0, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]:
      if abs(hz - rate) < abs(hz - nearest): nearest = rate
    let ppm = (hz - nearest) / nearest * 1e6
    echo "  note  measured ", formatFloat(hz, ffDecimal, 1), " frames/s"
    check abs(ppm) < 500,
      "the block takes frames at " & $nearest.int & " Hz (" & formatFloat(ppm, ffDecimal, 0) &
      " ppm off; one frame of the measurement is " &
      formatFloat(1e6 / frames.float, ffDecimal, 0) & " ppm)"
    let dividers = (bclk.bits(0, 12) + bclk.bits(16, 12) + 2).float
    echo "  note  so BCK = ", formatFloat(hz * 64 / 1e6, ffDecimal, 4), " MHz and the audio PLL gives ",
      formatFloat(hz * 64 * dividers / 1e6, ffDecimal, 4), " MHz"
  else:
    check false, "a frame rate was measured"

when isMainModule:
  if paramCount() == 0:
    quit "usage: pincheck <capture.bin | i2s.txt>..."
  for path in commandLineParams():
    let data = readFile(path)
    if data.len >= HeaderBytes and data.le32(0) == 0x31504350'u32:
      display(path, data)
    elif "i2s config" in data:
      i2s(path, data)
    else:
      echo path, ": not a capture or an I2S report"
      inc failures
  if failures > 0: quit($failures & " check(s) failed", 1)
  echo "all checks passed"
