## I2S audio output to the PCM5102A with a circular DMA ring (the hardware
## half of upstream `src/i2s.rs`, for the BL808's I2S block and DMA0).
##
## Pins (board.nim): BCK = `I2sBclkPin`, LCK = `I2sFsPin`, DIN = `I2sDoPin`.
## No master clock is output: the PCM5102A generates its own from BCK when
## its SCK pin is tied to GND.
##
## Format: Philips I2S, 16-bit samples in 32-bit channel slots, so
## BCK = 64 x fs (the PCM5102A's PLL mode is happiest with 64 fs).
##
## Clock: audio PLL / post divider gives 22.5792 MHz (the 44.1 kHz family)
## or 24.576 MHz (the 48 kHz family); the I2S block divides that down to
## BCK. Every MPEG sample rate is an even division, so the rates are exact
## up to the PLL's fractional resolution (a few ppm).
##
## Data: the FIFO runs in "L/R merged" mode, one 32-bit word per stereo
## frame (left in the low half), which is exactly the ring's interleaved
## int16 layout. DMA0 loops over the ring forever through a circular linked
## list (a list item moves at most 4095 words, so the ring is two items).
## Left and right therefore cannot end up swapped, wherever the DMA starts.
##
## The ring lives in PSRAM behind the M0 data cache: the DMA reads the
## memory, not the cache, so every span the CPU writes is cleaned
## (`commit`). The ring's place and length are build-time constants
## (`-d:radioRingAddress`, `-d:radioRingFrames`) so the ring and the DMA
## list can be moved to uncached RAM if DMA from PSRAM turns out not to work
## on the board.
##
## The clock arithmetic is plain Nim and host-tested; the hardware half is
## only compiled for the M0 and goes through the HAL (`bl808/glb` for the
## audio PLL and the clock gates, `bl808/i2s`, `bl808/dma`).

const
  XtalHz = 40_000_000'u64
    ## The Ox64's crystal.
  PllRefDiv = 4'u64
  SlotBits = 32'u64
  BclkPerFrame = 2 * SlotBits

type
  ClockPlan* = object
    sdmin*: uint32        ## audio PLL fractional multiplier (19 bits, /2048)
    postDiv*: uint32      ## audio PLL post divider
    bclkDivL*, bclkDivH*: uint32
      ## BCK low and high times, in I2S clock cycles minus one

func pllOutHz(sdmin, postDiv: uint32): uint64 {.inline.} =
  XtalHz div PllRefDiv * sdmin div 2048 div postDiv

func clockPlan*(sampleRate: uint32): ClockPlan =
  ## The PLL setting and dividers for `sampleRate`.
  # The vendor's values for a 40 MHz crystal: VCO 451.584 MHz / 20 and
  # 442.368 MHz / 18.
  if sampleRate mod 11_025 == 0:
    result.sdmin = 0x16944
    result.postDiv = 0x14
  else:
    result.sdmin = 0x161E5
    result.postDiv = 0x12
  let clk = pllOutHz(result.sdmin, result.postDiv)
  let bclk = BclkPerFrame * max(sampleRate, 1'u32)
  let total = clamp((clk + bclk div 2) div bclk, 2, 0x2000)   # I2S clocks per BCK cycle
  result.bclkDivL = uint32(total div 2 - 1)
  result.bclkDivH = uint32(total - total div 2 - 1)

func actualRate*(sampleRate: uint32): uint32 =
  ## The exact rate the clock dividers give for `sampleRate`, to the
  ## nearest hertz.
  let plan = clockPlan(sampleRate)
  let num = XtalHz div PllRefDiv * plan.sdmin
  let den = 2048'u64 * plan.postDiv * (plan.bclkDivL + plan.bclkDivH + 2) * BclkPerFrame
  uint32((num + den div 2) div den)

when defined(bl808m0):
  import bl808/[glb, gpio, dma, i2s, core]
  import ./board, ./diag, ./timebase, ./i2s_ring

  const
    RingAddress* {.intdefine: "radioRingAddress".} = 0
      ## 0: allocate the ring and the DMA list on the (PSRAM) heap.
      ## Otherwise a fixed address the DMA can read, with room for both (4
      ## bytes per frame plus 32): e.g. the 13 KB of uncached windows this
      ## firmware leaves unused at 0x2204_CC00, with
      ## -d:radioRingAddress=570739712 -d:radioRingFrames=3072 (a define
      ## takes decimal numbers only).
    DmaChannel = 0
    LliCount = 2
    LliFrames = RingFrames div LliCount
      ## Transfers (one frame each) per list item.
    RingBytes = RingLen * 2

  static:
    doAssert RingFrames mod LliCount == 0 and LliFrames <= 4095,
      "a DMA list item moves at most 4095 frames"
    # The plan's arithmetic and the HAL's PLL settings are the same clock.
    for rate in [44_100'u32, 48_000]:
      let plan = clockPlan(rate)
      doAssert pllOutHz(plan.sdmin, plan.postDiv) == audioPllHz(audioPllFor(rate)).uint64

  type
    Output = object
      ring: ptr UncheckedArray[int16]
      lli: ptr array[LliCount, DmaLli]
      i2s: I2s
      dma: Dma
      plan: ClockPlan     ## what the PLL and dividers are set to

  var o: Output

  when RingAddress == 0:
    proc alignedAlloc(bytes: uint): pointer =
      ## Zeroed, cache-line aligned and a whole number of lines long, so
      ## cleaning it never touches a neighbour's lines. Never freed.
      const CacheLine = 32'u
      let size = (bytes + CacheLine - 1) and not (CacheLine - 1)
      let raw = cast[uint](allocShared0(size + CacheLine))
      cast[pointer]((raw + CacheLine - 1) and not (CacheLine - 1))

  # ---- Clock ---------------------------------------------------------------

  proc setClock(sampleRate: uint32) =
    ## The audio PLL (reprogrammed only when the rate family changes), the
    ## I2S clock straight from it, and the BCK dividers.
    let plan = clockPlan(sampleRate)
    if plan.sdmin != o.plan.sdmin or plan.postDiv != o.plan.postDiv:
      discard configAudioPll(audioPllFor(sampleRate))   # for the 40 MHz crystal
    setI2sRefClock(enable = true)
    o.i2s.setBclkDiv(plan.bclkDivL, plan.bclkDivH)
    o.plan = plan

  # ---- DMA -------------------------------------------------------------------

  proc loadChannel() =
    ## Point the (stopped) channel at the start of the ring.
    o.dma.configureChannelLli(DmaChannel, addr o.lli[0], DmaTransferConfig(
      flow: flowM2P_Dma, dstPeriph: dmaPeriphI2sTx.uint32))

  proc buildList() =
    for i in 0 ..< LliCount:
      # One word per request, like the vendor's driver (the FIFO asks as
      # soon as it has room for one).
      o.lli[i] = buildLli(
        srcAddr = cast[uint32](o.ring) + uint32(i * LliFrames * 4),
        dstAddr = o.i2s.txFifoAddr.uint32,
        transferSize = LliFrames.uint32,
        srcWidth = width32, dstWidth = width32,
        srcIncr = true, dstIncr = false,
        nextLli = cast[uint32](addr o.lli[(i + 1) mod LliCount]),
        srcBurst = burst1, dstBurst = burst1)
    dcacheCleanRange(cast[uint](o.lli), sizeof(o.lli[]).uint)

  # ---- Public ----------------------------------------------------------------

  proc ringBuffer*(): ptr UncheckedArray[int16] {.inline.} = o.ring
    ## `RingLen` samples; valid after `i2sOutInit`.

  proc readPos*(): int =
    ## Sample index the DMA will read next (even = start of a frame).
    let offset = o.dma.channelSrcAddr(DmaChannel) - cast[uint32](o.ring)
    let frame = int(offset shr 2)
    if frame >= RingFrames: 0 else: 2 * frame    # at the very end of the ring (or not running): the start

  proc commit*(ring: var I2sRing) =
    ## Push what the CPU wrote to the ring out of the data cache, where the
    ## DMA can see it.
    var spans: array[8, Span]
    let n = ring.takeDirty(spans)
    for i in 0 ..< n:
      dcacheCleanRange(cast[uint](o.ring) + uint(spans[i].start * 2), uint(spans[i].len * 2))

  proc pollErrors*() =
    ## Count the times the transmitter ran out of data (the DMA missed a
    ## sample slot, which is an audible click) and DMA transfer errors.
    if o.i2s.txUnderflow():
      stats.i2sUnderruns += 1
      o.i2s.clearTxFifo()                     # the only way to clear the flag
    if o.dma.errInterruptPending(DmaChannel):
      stats.dmaErrors += 1
      o.dma.clearErrInterrupt(DmaChannel)

  proc stretchClock*(factor: uint32) =
    ## Diag: make BCK (and so the sample rate) `factor` times slower, for
    ## the pin self-test to read every bit; 1 is normal. The data and the
    ## framing are unchanged.
    let total = (o.plan.bclkDivL + o.plan.bclkDivH + 2) * max(factor, 1)
    o.i2s.setBclkDiv(total div 2 - 1, total - total div 2 - 1)

  proc start() =
    ## Clear the FIFO, then DMA, DMA requests and the transmitter, in the
    ## vendor driver's order.
    o.i2s.clearTxFifo()
    o.i2s.clearRxFifo()
    loadChannel()
    o.dma.startChannel(DmaChannel)
    o.i2s.enableDmaTx()
    o.i2s.enable(i2sMaster)
    o.i2s.enableTx()

  proc stop() =
    ## Stop DMA requests first, let the frames in the FIFO drain, then stop
    ## the transmitter and the channel. The wait is bounded so a wedged
    ## peripheral cannot hang us.
    o.i2s.disableDmaTx()
    let started = nowUs()
    var guard = 0
    # The count is the room left: the FIFO is empty when it reads its depth.
    while o.i2s.txFifoCount() < I2sFifoDepth and
          nowUs() - started < 3000 and guard < 1_000_000:
      inc guard
    o.i2s.disableTx()
    o.i2s.disable()
    o.dma.stopChannel(DmaChannel)

  proc setSampleRate*(ring: var I2sRing; sampleRate: uint32) =
    ## Change the sample rate: stop the I2S clock and the DMA, reprogram the
    ## dividers (and the PLL when the rate family changes), and restart
    ## both from the beginning of a silent ring.
    stop()
    ring.restart()
    commit(ring)
    setClock(sampleRate)
    start()

  proc i2sOutInit*(sampleRate: uint32) =
    ## Configure the pins, the clocks, the I2S block in master-transmit
    ## mode and the DMA ring, then start clocking out (silence) at
    ## `sampleRate`. Needs the heap and `timebase`'s clock.
    enablePeriphClock(periphI2s)
    enableDma0Clock()

    for pin in [I2sBclkPin, I2sFsPin, I2sDoPin]:
      gpioInitOutput(pin.uint32, drive1, pullNone)
      gpioSetFunction(pin.uint32, funcI2s)

    when RingAddress != 0:
      o.ring = cast[ptr UncheckedArray[int16]](RingAddress)
      o.lli = cast[ptr array[LliCount, DmaLli]](RingAddress + RingBytes)
    else:
      o.ring = cast[ptr UncheckedArray[int16]](alignedAlloc(RingBytes.uint))
      o.lli = cast[ptr array[LliCount, DmaLli]](alignedAlloc(sizeof(o.lli[]).uint))
    zeroMem(o.ring, RingBytes)
    dcacheCleanRange(cast[uint](o.ring), RingBytes.uint)

    # Philips I2S, stereo, 16-bit samples in 32-bit slots, MSB first. The
    # block stays off until `start`: a whole stereo frame per FIFO word (the
    # ring's layout), and the clock set before anything runs from it.
    o.plan = ClockPlan()
    o.i2s = initI2s(i2sStandard, i2sData16bit, i2sMaster, slotSize = i2sData32bit,
                    start = false)
    setClock(sampleRate)
    o.i2s.setFifoFormat(lrMerge = true)
    o.i2s.setFifoThresholds(0, 0)
    buildList()

    o.dma = initDma(dma0)
    o.dma.stopChannel(DmaChannel)
    o.dma.clearTcInterrupt(DmaChannel)
    o.dma.clearErrInterrupt(DmaChannel)
    start()
