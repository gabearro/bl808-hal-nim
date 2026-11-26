## SSD1322 OLED driver (256x64, 4-bit grayscale) over 4-wire SPI: a port of
## upstream `src/ssd1322.rs`.
##
## The first half is pure and host-tested: what to send (the init sequence,
## the analog tuning, the gamma table, the dim settings, the frame window)
## as lists of command bytes. The second half exists only in the firmware:
## the pins, SPI0, and sending those lists and the framebuffer.

import ./framebuf

{.localPassC: "-ffp-contract=off".}   # the gamma table must round as upstream's

const
  ColStart* = 0x1C'u8
    ## The SSD1322 has 480 columns of RAM; 256-pixel-wide panels are wired
    ## to the middle of it. One column address = 4 pixels, so 0x1C..0x5B is
    ## 256 pixels.
  ColEnd* = ColStart + uint8(Width div 4) - 1
  Remap* = [0x14'u8, 0x11]
    ## Command 0xA0: horizontal address increment, nibble re-map, COM scan
    ## reversed; the second byte enables dual COM line mode. The usual
    ## setting for 256x64 modules. If the image is mirrored or upside-down,
    ## toggle bit 1 (column re-map) and/or bit 4 (COM scan direction).
  CmdWriteRam* = 0x5C'u8
  CmdDisplayOn* = 0xAF'u8

type
  Tuning* = object
    ## The SSD1322's adjustable analog and timing settings.
    contrastCurrent*: uint8   ## 0xC1: segment drive current, 0..255
    masterContrast*: uint8    ## 0xC7: master scale on all currents, 0..15
    phase1*: uint8            ## 0xB1 low nibble: phase 1 (reset) length, 2..15
    phase2*: uint8            ## 0xB1 high nibble: first pre-charge length, 3..15
    prechargeVoltage*: uint8  ## 0xBB: 0..31 -> 0.20..0.60 x VCC
    secondPrecharge*: uint8   ## 0xB6: second pre-charge period, 0..15 clocks
    vcomh*: uint8             ## 0xBE: COM deselect voltage, 0..7
    externalVsl*: bool        ## 0xB4 A: external VSL (most modules) vs internal
    enhancedLowGs*: bool      ## 0xB4 B: "enhanced low gray-scale display quality"
    clockDiv*: uint8          ## 0xB3 low nibble: divide ratio, 0..10
    oscFreq*: uint8           ## 0xB3 high nibble: oscillator frequency, 0..15
    gammaX10*: uint8          ## gamma x10, 5..30; 10 = the built-in linear table

  Cmds* = object
    ## A list of commands: each is the command byte, its argument count,
    ## then the arguments.
    data: array[96, byte]
    len: int

const
  DefaultTuning* = Tuning(
    contrastCurrent: 0x9F, masterContrast: 0x0F, phase1: 2, phase2: 14,
    prechargeVoltage: 0x1F, secondPrecharge: 0x08, vcomh: 0x07,
    externalVsl: true, enhancedLowGs: true, clockDiv: 1, oscFreq: 9,
    gammaX10: 10)
    ## Typical for 256x64 modules.

func add*(c: var Cmds; cmd: byte; args: openArray[byte] = []) =
  doAssert c.len + 2 + args.len <= c.data.len
  c.data[c.len] = cmd
  c.data[c.len + 1] = args.len.byte
  for i, a in args: c.data[c.len + 2 + i] = a
  c.len += 2 + args.len

iterator commands*(c: Cmds): tuple[cmd: byte; first, count: int] =
  ## Each command with where its arguments are: `c.arg(first + i)`.
  var i = 0
  while i < c.len:
    let n = c.data[i + 1].int
    yield (c.data[i], i + 2, n)
    i += 2 + n

func arg*(c: Cmds; i: int): byte {.inline.} = c.data[i]

func argsPtr*(c: var Cmds; first: int): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](addr c.data[first])

func flat*(c: Cmds): seq[byte] =
  ## Command and argument bytes in sending order (for tests).
  for cmd, first, count in c.commands:
    result.add cmd
    for i in 0 ..< count: result.add c.data[first + i]

func clamped*(t: Tuning): Tuning =
  ## Every field within the range the SSD1322 datasheet allows.
  result = t
  result.masterContrast = min(t.masterContrast, 15)
  result.phase1 = clamp(t.phase1, 2, 15)
  result.phase2 = clamp(t.phase2, 3, 15)
  result.prechargeVoltage = min(t.prechargeVoltage, 31)
  result.secondPrecharge = min(t.secondPrecharge, 15)
  result.vcomh = min(t.vcomh, 7)
  result.clockDiv = min(t.clockDiv, 10)
  result.oscFreq = min(t.oscFreq, 15)
  result.gammaX10 = clamp(t.gammaX10, 5, 30)

const Ln2 = 0.693_147_180_559_945_309_417_232_121_458_176_568'f32

func ln(x: float32): float32 =
  ## Natural log for x > 0 (upstream's: split off the binary exponent, then
  ## ln(m) = 2 atanh((m - 1) / (m + 1)) by series).
  let bits = cast[uint32](x)
  let e = int32((bits shr 23) and 0xFF) - 127
  let m = cast[float32]((bits and 0x007F_FFFF'u32) or 0x3F80_0000'u32)
  let z = (m - 1.0'f32) / (m + 1.0'f32)
  let z2 = z * z
  let series = z * (1.0'f32 + z2 * (1.0'f32 / 3.0'f32 + z2 * (1.0'f32 / 5.0'f32 +
    z2 * (1.0'f32 / 7.0'f32 + z2 / 9.0'f32))))
  e.float32 * Ln2 + 2.0'f32 * series

func exp(y: float32): float32 =
  ## e^y for y <= 0: 2^k times a series for the rest (upstream's).
  let k = int32(y / Ln2) - 1
  let r = y - k.float32 * Ln2
  var term = 1.0'f32
  var sum = 1.0'f32
  for n in 1 .. 9:
    term *= r / n.float32
    sum += term
  if k < -126: 0.0'f32
  else: sum * cast[float32](uint32(k + 127) shl 23)

func gammaTable*(gammaX10: uint8): array[15, uint8] =
  ## Gray-scale table GS1..GS15 (pulse widths 0..180, strictly increasing):
  ## GSn = 180 (n/15)^gamma.
  let gamma = gammaX10.float32 / 10.0'f32
  var prev = 0
  for i in 0 ..< 15:
    let x = float32(i + 1) / 15.0'f32
    var v = int(180.0'f32 * exp(gamma * ln(x)) + 0.5'f32)
    # Strictly increasing, leaving room for the remaining steps.
    v = min(max(v, prev + 1), 180 - (14 - i))
    result[i] = v.uint8
    prev = v

func addTuning*(c: var Cmds; tuning: Tuning) =
  ## Clock, currents, timings, voltages and gamma.
  let t = tuning.clamped
  c.add 0xB3, [(t.oscFreq shl 4) or t.clockDiv]
  c.add 0xB4, [if t.externalVsl: 0xA0'u8 else: 0xA2, if t.enhancedLowGs: 0xFD'u8 else: 0xB5]
  c.add 0xC1, [t.contrastCurrent]
  c.add 0xC7, [t.masterContrast]
  c.add 0xB1, [(t.phase2 shl 4) or t.phase1]
  c.add 0xBB, [t.prechargeVoltage]
  c.add 0xB6, [t.secondPrecharge]
  c.add 0xBE, [t.vcomh]
  if t.gammaX10 == 10:
    c.add 0xB9                      # built-in linear grayscale table
  else:
    c.add 0xB8, gammaTable(t.gammaX10)   # custom table...
    c.add 0x00                      # ...and enable it

func initCommands*(tuning = DefaultTuning): Cmds =
  ## Everything sent after the hardware reset and before the first frame.
  ## The display is switched on (`CmdDisplayOn`) after that frame.
  result.add 0xFD, [0x12'u8]        # unlock command interface
  result.add 0xAE                   # display off
  result.add 0xCA, [0x3F'u8]        # multiplex ratio: 64 rows
  result.add 0xA2, [0x00'u8]        # display offset
  result.add 0xA1, [0x00'u8]        # display start line
  result.add 0xA0, Remap            # re-map and dual COM mode
  result.add 0xB5, [0x00'u8]        # GPIO pins disabled
  result.add 0xAB, [0x01'u8]        # internal VDD regulator
  result.add 0xD1, [0xA2'u8, 0x20]  # display enhancement B: normal
  result.addTuning tuning
  result.add 0xA6                   # normal display mode
  result.add 0xA9                   # exit partial display

func dimCommands*(amount: float32): Cmds =
  ## Dimming, 0.0 (normal) .. 1.0 (dimmest). The panel's brightness has a
  ## floor set by the pre-charge stage, so lowering only the drive current
  ## or master contrast barely dims it. This fades four settings together,
  ## from their init values to their minimums: master contrast (0xC7),
  ## segment current (0xC1), pre-charge voltage (0xBB) and second
  ## pre-charge period (0xB6). The gray-scale table is untouched, so
  ## gradients keep their shape.
  let d = clamp(amount, 0.0'f32, 1.0'f32)
  template lerp(a, b: uint8): uint8 =
    uint8(a.float32 + (b.float32 - a.float32) * d + 0.5'f32)
  let t = DefaultTuning
  result.add 0xC7, [lerp(t.masterContrast, 0)]
  result.add 0xC1, [lerp(t.contrastCurrent, 40)]
  result.add 0xBB, [lerp(t.prechargeVoltage, 0)]
  result.add 0xB6, [lerp(t.secondPrecharge, 1)]

func windowCommands*(): Cmds =
  ## Address window for a whole frame; `CmdWriteRam` and the pixels follow.
  result.add 0x15, [ColStart, ColEnd]
  result.add 0x75, [0'u8, uint8(Height - 1)]

func spiPrescaler*(sourceHz, maxHz: int): int =
  ## BL808 SPI period setting for the fastest clock not above `maxHz`: each
  ## half of a bit lasts (value + 1) source clocks.
  let phase = (sourceHz + 2 * maxHz - 1) div (2 * maxHz)
  clamp(phase - 1, 0, 255)

# ---- Hardware (firmware only) -------------------------------------------------

when defined(bl808m0):
  import bl808/[gpio, glb, spi]
  import bl808/kernel/[runtime, asyncspi]
  import ./board

  const
    SpiSourceHz = 40_000_000
      ## SPI0 is clocked from XCLK, the Ox64's 40 MHz crystal (main selects
      ## it for the console too), so the rate does not depend on a PLL.
    Prescaler = spiPrescaler(SpiSourceHz, OledSpiHz)

  type
    Oled* = object
      aspi: AsyncSpi
      frame: CpsFuture[SpiError]    ## the frame being sent, if any

  proc oledOpen*(): Oled =
    ## Pins and SPI0. CS, D/C and RES idle high; the panel is not touched.
    for pin in [OledCsPin, OledDcPin, OledResPin]:
      gpioInitOutput(pin.uint32, drive1, pullNone)
      gpioWrite(pin.uint32, true)
    gpioSetupSpiPin(OledSclkPin.uint32)
    gpioSetupSpiPin(OledSdinPin.uint32)

    # The data output on the pad the board uses, and the 40 MHz clock.
    swapSpi0MosiMiso(OledSpiSwap)
    enablePeriphClock(periphSpi)
    setSpiClock(true, spiClkXclk)

    # The SSD1322 samples on the rising edge with the clock idle low. Frames
    # go out from the SPI0 interrupt (`asyncspi`); commands are sent blocking.
    result.aspi = initAsyncSpi(spi0, SpiConfig(
      mode: spiMode0, frameSize: frame8bit, role: spiMaster,
      prescaler: Prescaler.uint32, deglitch: false))

  proc setSlow*(o: Oled; slow: bool) =
    ## Diag: clock the panel at 1 MHz (slow enough for the pin self-test to
    ## read every bit) or back at the normal rate. Between frames only.
    o.aspi.spi.setPrescaler(
      if slow: spiPrescaler(SpiSourceHz, 1_000_000).uint32 else: Prescaler.uint32)

  proc resetPin*(o: Oled; high: bool) =
    ## RES: low for 1 ms, then high for 10 ms before the first command.
    gpioWrite(OledResPin.uint32, high)

  proc command(o: Oled; cmd: byte; args: ptr UncheckedArray[byte]; count: int) =
    gpioClear(OledCsPin.uint32)
    gpioClear(OledDcPin.uint32)
    discard o.aspi.spi.send([cmd])
    if count > 0:
      gpioSet(OledDcPin.uint32)
      discard o.aspi.spi.send(args.toOpenArray(0, count - 1))
    gpioSet(OledCsPin.uint32)

  proc command*(o: Oled; cmd: byte) =
    o.command(cmd, nil, 0)

  proc send*(o: Oled; cmds: Cmds) =
    ## Send a command list (blocking; a few dozen bytes at most).
    var c = cmds
    for cmd, first, count in c.commands:
      o.command(cmd, c.argsPtr(first), count)

  proc flushStart*(o: var Oled; buf: ptr array[BufLen, byte]) =
    ## Begin sending the whole framebuffer (8 KB, about 12 ms). The
    ## bytes go out from the SPI interrupt, 16 or more at a time, so other
    ## tasks keep running. Poll `flushDone`, then call `flushEnd`; or
    ## `flushAbort` to give up.
    o.send windowCommands()
    gpioClear(OledCsPin.uint32)
    gpioClear(OledDcPin.uint32)
    discard o.aspi.spi.send([CmdWriteRam])
    gpioSet(OledDcPin.uint32)
    o.frame = o.aspi.sendPtr(cast[ptr UncheckedArray[byte]](buf), BufLen)

  proc flushDone*(o: Oled): bool =
    ## The whole frame has left the chip.
    o.frame != nil and o.frame.finished and not o.frame.hasError and
      o.frame.read() == spiOk

  proc flushEnd*(o: var Oled) =
    ## After `flushDone`: deselect the panel.
    o.frame = nil
    o.aspi.spi.clearFifos()       # the bytes clocked in while sending
    gpioSet(OledCsPin.uint32)

  proc flushAbort*(o: var Oled) =
    ## Give up on a frame that is stuck. Nothing of it remains: the next
    ## `flushStart` begins a fresh transfer, however often this happens.
    o.aspi.cancel()
    o.flushEnd()
