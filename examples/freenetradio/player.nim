## Decoding and output: MP3 from the `pipe.stream` buffer into the I2S ring,
## with buffering, the equaliser, volume, sample-rate changes, meters and
## fading in/out around starts and stops (the audio half of upstream
## `src/radio.rs`: `audio_task` and `meter_level`).
##
## Upstream's task is a loop; here one `step` is one piece of it and the
## result says how the caller should wait before the next: 20 ms when there
## is nothing to play, 10 ms at the end of a pass, or just a yield after
## decoding a frame (a frame takes milliseconds to decode: the display and
## network run between frames rather than after several back to back).
##
## The decoder and the DAC are reached through small proc tables, so this
## module has no hardware in it and is tested on the host. Pure Nim.

import ./mp3dec, ./i2s_ring, ./eq, ./pipe, ./status, ./spectrum, ./diag, ./timebase

const
  Prebuffer* = PipeLen * 15 div 16
    ## Start (or resume) playback once the pipe is (nearly) full and has
    ## stayed so for `PrebufferHoldMs`, so the TCP receive buffer behind it
    ## fills too. Starting with every buffer full matters at high bitrates:
    ## the buffers are sized in bytes, ~0.5 s in all at 320 kbit/s, and some
    ## servers send in ~16 KB lumps with pauses of up to ~0.5 s between them.
  PrebufferHoldMs* = 400
  Window* = 4 * 1024
    ## Decoder input window. The decoder needs a couple of frames beyond the
    ## current one to recognise it (an MP3 frame is ~420 bytes at
    ## 128 kbit/s, ~1 KB at 320 kbit/s).
  MinDecodeInput* = 2560
  FadeFrames* = 1024
    ## Fade length for starting and stopping: ~23 ms at 44.1 kHz. Without
    ## these the output would jump between silence and mid-waveform audio,
    ## which clicks.
  ResyncLeadFrames = 256
  StarvedQueueFrames = 512
  InitialSampleRate* = 44_100'u32

type
  StepResult* = enum
    srIdle    ## nothing to play or still buffering: come back in 20 ms
    srWait    ## the ring is full or the data ran out: come back in 10 ms
    srYield   ## a frame was decoded: let the other tasks run, then continue

  DecodeFn* = proc(ctx: pointer; mp3: openArray[byte]; pcm: var openArray[int16];
                   info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] {.nimcall.}
  SpectrumFn* = proc(ctx: pointer; energy: var array[SpectrumBands, float32]): uint32 {.nimcall.}

  DecoderOps* = object
    ctx*: pointer
    decode*: DecodeFn
    takeSpectrum*: SpectrumFn

  OutputOps* = object
    ## The DAC side. All four are required.
    readPos*: proc(): int {.nimcall.}
      ## Sample index (even) the DMA will read next.
    commit*: proc(ring: var I2sRing) {.nimcall.}
      ## Make what was written to the ring visible to the DMA
      ## (`ring.takeDirty`, then clean those cache lines).
    setSampleRate*: proc(ring: var I2sRing; rate: uint32) {.nimcall.}
      ## Stop the output, call `ring.restart()`, commit, set the new rate
      ## and start reading again from sample 0.
    actualRate*: proc(rate: uint32): uint32 {.nimcall.}
      ## The exact rate the clock dividers give for `rate`.

  Player* = object
    ring*: I2sRing
    dec: DecoderOps
    output: OutputOps
    window: ptr UncheckedArray[byte]   ## `Window` bytes
    pcm: ptr UncheckedArray[int16]     ## `MaxSamplesPerFrame` samples
    windowLen: int
    eq: Eq
    sampleRate: uint32                 ## what the output is running at
    playing: bool
    generation: uint32
    decodeTotalUs: uint64
    decodeCount: uint32
    fadeInLeft: int                    ## frames of fade-in still to apply
    playStartedUs: uint64
    fullSince: uint64                  ## when the pipe became full while prebuffering
    fullSinceSet: bool
    lastPassUs: uint64
    inPass: bool                       ## between the top of a pass and its end
    gain: int32                        ## this pass's volume, 0..32768

static:
  doAssert SpectrumBands == spectrum.Bands

template st: untyped = status.player
  ## The shared status (this module's own name hides the bare identifier).

func meterLevel*(peak: int32): uint8 =
  ## Peak sample (0..32768) to a meter level 0..255 on a decibel scale
  ## spanning -48 dB (0) to full scale (255). log2 from the bit position
  ## plus 4 bits of mantissa; no floating point needed.
  if peak <= 0:
    return 0
  var bits = 0'i32                     # floor(log2)
  while (peak shr (bits + 1)) != 0:
    inc bits
  let mantissa = if bits >= 4: (peak shr (bits - 4)) and 15 else: (peak shl (4 - bits)) and 15
  let log2x16 = bits * 16 + mantissa   # full scale (2^15) = 240
  const RangeX16 = 8 * 16              # 8 bits = 48 dB
  uint8(clamp((log2x16 - (240 - RangeX16)) * 255 div RangeX16, 0, 255))

func satU32(v: uint64): uint32 {.inline.} =
  if v > high(uint32).uint64: high(uint32) else: uint32(v)

func volumeGain*(volume: int): int32 {.inline.} =
  ## 0..100 to 0..32768 on a perceptual-ish (square) curve.
  int32((volume * volume * 32768) div 10_000)

proc initPlayer*(p: var Player; ringBuf: ptr UncheckedArray[int16];
                 window: ptr UncheckedArray[byte]; pcm: ptr UncheckedArray[int16];
                 dec: DecoderOps; output: OutputOps) =
  ## `ringBuf` holds `RingLen` samples, `window` `Window` bytes and `pcm`
  ## `MaxSamplesPerFrame` samples; the output is already running (silence)
  ## at `InitialSampleRate`, reading from sample 0.
  p = Player(dec: dec, output: output, window: window, pcm: pcm,
             eq: initEq(), sampleRate: InitialSampleRate,
             generation: high(uint32), lastPassUs: nowUs())
  initRing(p.ring, ringBuf)
  p.output.commit(p.ring)

func playing*(p: Player): bool {.inline.} = p.playing
func sampleRate*(p: Player): uint32 {.inline.} = p.sampleRate
func windowLen*(p: Player): int {.inline.} = p.windowLen

proc fadeOut(p: var Player) {.inline.} =
  p.ring.fadeOut(p.output.readPos(), FadeFrames)

proc beginPass(p: var Player): bool =
  ## The top of upstream's loop, down to the decode loop. False means there
  ## is nothing to decode now (wait 20 ms).
  stats.audioLoops += 1
  p.ring.consumePlayed(p.output.readPos())
  let now = nowUs()
  stats.maxLoopGapUs = max(stats.maxLoopGapUs, satU32(now - p.lastPassUs))
  p.lastPassUs = now
  if p.playing:
    stats.minQueued = min(stats.minQueued, p.ring.queuedFrames.uint32)
  let phase = st.phase
  let volume = if st.muted: 0 else: st.volume.int

  # New stream or stopped: drop everything and go quiet.
  if st.generation != p.generation:
    p.generation = st.generation
    p.windowLen = 0
    p.playing = false
    p.fadeOut()
  if phase notin {phBuffering, phPlaying}:
    if p.playing:
      p.playing = false
      p.fadeOut()
    return false

  let buffered = stream.len + p.windowLen
  st.bufferPct = uint8(buffered * 100 div (PipeLen + Window))

  if not p.playing:
    if buffered < Prebuffer:
      p.fullSinceSet = false
      return false
    if not p.fullSinceSet:
      p.fullSince = now
      p.fullSinceSet = true
    if nowUs() - p.fullSince < PrebufferHoldMs * 1000:
      return false
    p.fullSinceSet = false
    p.playing = true
    p.playStartedUs = nowUs()
    p.ring.flushSilence(p.output.readPos())
    p.fadeInLeft = FadeFrames
    setPhase(phPlaying, "")

  p.gain = volumeGain(volume)
  true

proc emitFrame(p: var Player; info: FrameInfo; us: uint32) =
  ## One decoded frame: EQ, fade-in, volume and meters into the ring.
  p.decodeTotalUs += us
  p.decodeCount += 1
  let rate = info.sampleRate.uint32
  if rate != p.sampleRate:
    p.sampleRate = rate
    p.output.setSampleRate(p.ring, rate)
  let stereo = info.channels == 2
  p.eq.update(rate)
  var peakL, peakR = 0'i32
  for f in 0 ..< info.samplesProduced:
    let l = if stereo: p.pcm[2 * f] else: p.pcm[f]
    let r = if stereo: p.pcm[2 * f + 1] else: p.pcm[f]
    var g = p.gain
    if p.fadeInLeft > 0:
      dec p.fadeInLeft
      g = int32(int64(p.gain) * int64(FadeFrames - p.fadeInLeft) div FadeFrames)
    # Meter the music itself (before volume), so it moves even at low volume.
    peakL = max(peakL, abs(l.int32))
    peakR = max(peakR, abs(r.int32))
    let (el, er) = p.eq.process(l, r)
    p.ring.push(int16(ashr(el.int32 * g, 15)), int16(ashr(er.int32 * g, 15)))
  var energy: array[SpectrumBands, float32]
  let n = p.dec.takeSpectrum(p.dec.ctx, energy)
  spectrum.publish(energy, n)
  st.sampleRate = p.output.actualRate(rate)
  st.bitrate = info.bitrateKbps.uint32
  st.channels = info.channels.uint8
  # Nothing on the meters when muted / volume 0.
  st.levelL = if p.gain == 0: 0'u8 else: meterLevel(peakL)
  st.levelR = if p.gain == 0: 0'u8 else: meterLevel(peakR)
  st.decodeMaxUs = max(st.decodeMaxUs, us)
  st.decodeAvgUs = satU32(p.decodeTotalUs div max(p.decodeCount, 1).uint64)
  if p.decodeCount >= 1000:
    p.decodeTotalUs = p.decodeTotalUs div 2
    p.decodeCount = p.decodeCount div 2

proc decodeOne(p: var Player): bool =
  ## One turn of upstream's decode loop. True if a frame's worth of input
  ## was used and the loop goes on (after a yield).
  # Decode while there's room for a whole frame in the ring.
  if p.ring.freeFrames <= MaxSamplesPerFrame div 2 + 64:
    return false
  if p.windowLen < Window:
    p.windowLen += stream.read(toOpenArray(p.window, p.windowLen, Window - 1))
  if p.windowLen < MinDecodeInput:
    return false
  var info: FrameInfo
  let started = nowUs()
  let (used, status) = p.dec.decode(p.dec.ctx, toOpenArray(p.window, 0, p.windowLen - 1),
                                    toOpenArray(p.pcm, 0, MaxSamplesPerFrame - 1), info)
  let us = satU32(nowUs() - started)
  if used > 0:
    moveMem(addr p.window[0], addr p.window[used], p.windowLen - used)
  p.windowLen -= used

  case status
  of dsDecoded: p.emitFrame(info, us)
  of dsNoFrame: stats.decodeErrors[0] += 1
  of dsReservoirUnavailable: stats.decodeErrors[1] += 1
  of dsCorrupt: stats.decodeErrors[2] += 1
  of dsUnsupportedLayer: stats.decodeErrors[3] += 1
  used != 0   # 0 shouldn't happen; avoid spinning

proc endPass(p: var Player) =
  ## Running dry: go back to buffering. If audio is still queued, fade it
  ## out; if the DMA already caught up, the output is silent anyway.
  let buffered = stream.len + p.windowLen
  let starved = buffered < MinDecodeInput
  let queued = p.ring.queuedFrames
  let overtaken = p.ring.resyncIfUnderrun(p.output.readPos(), ResyncLeadFrames)
  if overtaken or (starved and queued < StarvedQueueFrames):
    stats.underrunInfo = [satU32((nowUs() - p.playStartedUs) div 1000),
                          (if overtaken: 1'u32 else: 2'u32), buffered.uint32, queued.uint32]
    st.underruns += 1
    p.playing = false
    p.fadeOut()
    setPhase(phBuffering, "")

proc step*(p: var Player): StepResult =
  ## Run the player a little; see `StepResult` for what to do next.
  if not p.inPass:
    if not p.beginPass():
      p.output.commit(p.ring)
      return srIdle
    p.inPass = true
  if p.decodeOne():
    result = srYield
  else:
    p.inPass = false
    p.endPass()
    result = srWait
  p.output.commit(p.ring)
