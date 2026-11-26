## Host tests for the player state machine (player.nim): a fake decoder, a
## simulated DAC whose read position follows the fake clock, and the real
## pipe, status, prefs, spectrum and ring modules.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_player.nim

import ../player, ../i2s_ring, ../mp3dec, ../eq, ../pipe, ../status, ../prefs,
       ../spectrum, ../diag, ../timebase, ../text

template st: untyped = status.player
  ## The shared status (the module `player` hides the bare name here).

# ---- The fake stream format --------------------------------------------------
# A "frame" is FrameBytes long: 0xA5, a kind, an amplitude (x 256), filler.
const
  FrameBytes = 400
  Marker = 0xA5'u8

type
  Kind = enum
    kStereo44    ## 1152 frames, 44.1 kHz stereo, left = +amp, right = -amp
    kMono48      ## 576 frames, 48 kHz mono
    kCorrupt
    kReservoir
    kLayer2
    kStuck       ## the decoder reports 0 bytes used
    kEmpty       ## decodes, but produces no samples (44.1 kHz stereo)
    kRamp        ## 1152 frames, 44.1 kHz stereo, left = sample index + 1, right = 0

# ---- Simulated DAC -------------------------------------------------------------

type
  Dac = object
    cpu, mem: array[RingLen, int16]
    pos: int
    rate: uint32
    fracUs: uint64                  ## microseconds not yet turned into frames
    played: seq[array[2, int16]]
    rateChanges: seq[uint32]
    commits: int

var
  dac: Dac
  pl: Player
  window: array[Window, byte]
  pcm: array[MaxSamplesPerFrame, int16]
  decodeCostUs = 3000'u64
  decodeCalls = 0
  spectrumN = 0'u32

proc advanceUs(us: uint64) =
  ## Time passes: the DAC plays on.
  setFakeTimeUs(nowUs() + us)
  dac.fracUs += us * dac.rate
  let frames = dac.fracUs div 1_000_000
  dac.fracUs -= frames * 1_000_000
  for _ in 0 ..< frames.int:
    dac.played.add [dac.mem[dac.pos], dac.mem[dac.pos + 1]]
    dac.pos = (dac.pos + 2) mod RingLen

proc dacReadPos(): int {.nimcall.} = dac.pos

proc dacCommit(ring: var I2sRing) {.nimcall.} =
  var spans: array[8, Span]
  let n = ring.takeDirty(spans)
  for i in 0 ..< n:
    for k in spans[i].start ..< spans[i].start + spans[i].len:
      dac.mem[k] = dac.cpu[k]
  doAssert dac.mem == dac.cpu, "a ring write was not committed"
  inc dac.commits

proc dacSetRate(ring: var I2sRing; rate: uint32) {.nimcall.} =
  ring.restart()
  dacCommit(ring)
  dac.pos = 0
  dac.fracUs = 0
  dac.rate = rate
  dac.rateChanges.add rate

proc dacActualRate(rate: uint32): uint32 {.nimcall.} = rate + 1   # tells it apart from the nominal rate

# ---- Fake decoder ----------------------------------------------------------------

proc fakeDecode(ctx: pointer; mp3: openArray[byte]; pcm: var openArray[int16];
                info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] {.nimcall.} =
  doAssert ctx == addr decodeCalls
  doAssert mp3.len >= MinDecodeInput and mp3.len <= Window
  doAssert pcm.len == MaxSamplesPerFrame
  inc decodeCalls
  advanceUs(decodeCostUs)
  info = FrameInfo()
  var skip = 0
  while skip < mp3.len and mp3[skip] != Marker: inc skip
  if skip > 0:
    return (skip, dsNoFrame)                 # junk skipped
  let kind = Kind(mp3[1])
  let amp = int16(mp3[2].int * 256)
  info.layer = 3
  info.bitrateKbps = 128
  case kind
  of kStereo44, kRamp:
    info.samplesProduced = 1152
    info.channels = 2
    info.sampleRate = 44100
    for f in 0 ..< 1152:
      pcm[2 * f] = if kind == kRamp: int16(f + 1) else: amp
      pcm[2 * f + 1] = if kind == kRamp: 0'i16 else: -amp
    spectrumN += 4
    (FrameBytes, dsDecoded)
  of kMono48:
    info.samplesProduced = 576
    info.channels = 1
    info.sampleRate = 48000
    info.bitrateKbps = 64
    for f in 0 ..< 576: pcm[f] = amp
    for f in 576 ..< MaxSamplesPerFrame: pcm[f] = 0x7777   # must not be read
    spectrumN += 2
    (FrameBytes, dsDecoded)
  of kEmpty:
    info.channels = 2
    info.sampleRate = 44100
    (FrameBytes, dsDecoded)
  of kCorrupt: (FrameBytes, dsCorrupt)
  of kReservoir: (FrameBytes, dsReservoirUnavailable)
  of kLayer2:
    info.layer = 2
    (FrameBytes, dsUnsupportedLayer)
  of kStuck: (0, dsNoFrame)

proc fakeSpectrum(ctx: pointer; energy: var array[SpectrumBands, float32]): uint32 {.nimcall.} =
  for i in 0 ..< SpectrumBands: energy[i] = spectrumN.float32 * 1e-3'f32
  result = spectrumN
  spectrumN = 0

# ---- Helpers ------------------------------------------------------------------------

proc feed(kind: Kind; amp = 64; count = 1): int =
  ## Queue `count` frames in the pipe; returns how many fitted completely.
  var frame: array[FrameBytes, byte]
  frame[0] = Marker
  frame[1] = kind.ord.byte
  frame[2] = amp.byte
  for i in 3 ..< FrameBytes: frame[i] = 0x11
  for _ in 0 ..< count:
    if stream.free < FrameBytes: return
    doAssert stream.write(frame) == FrameBytes
    inc result

proc setup() =
  setFakeTimeUs(1_000_000)
  diagInit()
  statusInit()
  pipeInit()
  prefsInit()
  spectrumInit()
  dac = Dac(rate: 44100)
  for i in 0 ..< RingLen: dac.cpu[i] = 0x2222
  dac.mem = dac.cpu
  decodeCalls = 0
  spectrumN = 0
  decodeCostUs = 3000
  initPlayer(pl, cast[ptr UncheckedArray[int16]](addr dac.cpu[0]),
             cast[ptr UncheckedArray[byte]](addr window[0]),
             cast[ptr UncheckedArray[int16]](addr pcm[0]),
             DecoderOps(ctx: addr decodeCalls, decode: fakeDecode, takeSpectrum: fakeSpectrum),
             OutputOps(readPos: dacReadPos, commit: dacCommit,
                       setSampleRate: dacSetRate, actualRate: dacActualRate))
  doAssert dac.commits == 1
  for v in dac.mem: doAssert v == 0

proc tick(): StepResult =
  ## One step, then wait as the audio task would.
  let before = dac.commits
  result = pl.step()
  doAssert dac.commits > before, "every step ends with a commit"
  case result
  of srIdle: advanceUs(20_000)
  of srWait: advanceUs(10_000)
  of srYield: advanceUs(200)

proc startPlaying(kind = kStereo44; amp = 64) =
  ## Fill the pipe, hold for the prebuffer time, and step until playing.
  st.generation += 1
  setPhase(phBuffering, "")
  while feed(kind, amp) == 1: discard
  var guard = 0
  while not pl.playing:
    doAssert tick() != srWait or pl.playing
    inc guard
    doAssert guard < 100
  doAssert st.phase == phPlaying

proc keepFed(kind = kStereo44; amp = 64) =
  while feed(kind, amp) == 1: discard

# ---- Tests ---------------------------------------------------------------------------

block: # constantsAreUpstreams
  doAssert Prebuffer == 9600 and PrebufferHoldMs == 400
  doAssert Window == 4096 and MinDecodeInput == 2560 and FadeFrames == 1024
  doAssert PipeLen == 10240 and RingFrames == 4096 and MaxSamplesPerFrame == 2304
  doAssert InitialSampleRate == 44100

block: # meterLevel
  doAssert meterLevel(0) == 0 and meterLevel(-5) == 0
  doAssert meterLevel(32768) == 255
  doAssert meterLevel(32767) == 253         # log2 x16 = 239
  doAssert meterLevel(16384) == 223         # -6 dB: 224 -> (224 - 112) * 255 / 128
  doAssert meterLevel(128) == 0             # -48 dB: the bottom of the scale
  doAssert meterLevel(127) == 0 and meterLevel(1) == 0 and meterLevel(15) == 0
  doAssert meterLevel(136) == 1             # one mantissa step above -48 dB
  doAssert meterLevel(256) == 31
  doAssert meterLevel(24576) == 239         # 1.5 x 2^14: mantissa 8
  var last = 0'u8
  for peak in 0'i32 .. 32768:               # monotonic over the whole range
    let m = meterLevel(peak)
    doAssert m >= last
    last = m

block: # volumeCurve
  doAssert volumeGain(100) == 32768 and volumeGain(0) == 0
  doAssert volumeGain(50) == 8192 and volumeGain(10) == 327
  doAssert volumeGain(1) == 3 and volumeGain(2) == 13

block: # idleWhenStopped
  setup()
  for _ in 0 ..< 5:
    doAssert tick() == srIdle
  doAssert stats.audioLoops == 5 and decodeCalls == 0
  doAssert not pl.playing and st.bufferPct == 0
  # Data in the pipe is not touched while stopped, connecting, or in error.
  discard feed(kStereo44, count = 20)
  for ph in [phStopped, phConnecting, phError, phOffline]:
    setPhase(ph, "")
    doAssert tick() == srIdle
  doAssert stream.len == 20 * FrameBytes and decodeCalls == 0
  doAssert stats.maxLoopGapUs == 20_000

block: # prebufferAndHold
  setup()
  st.generation += 1
  setPhase(phBuffering, "")
  doAssert feed(kStereo44, count = 23) == 23          # 9200 bytes: just short
  doAssert tick() == srIdle
  doAssert st.bufferPct == uint8(9200 * 100 div (PipeLen + Window))   # 64
  doAssert st.bufferPct == 64
  for _ in 0 ..< 50:                                  # a whole second: still waiting
    doAssert tick() == srIdle
  doAssert not pl.playing and decodeCalls == 0 and st.phase == phBuffering
  doAssert feed(kStereo44) == 1                       # 9600: the threshold exactly
  let t0 = nowUs()
  var steps = 0
  while tick() == srIdle: inc steps
  # First seen full at t0; passes at +20 .. +380 ms wait; the one at +400 ms starts.
  doAssert steps == 20
  doAssert nowUs() - t0 >= 400_000 and nowUs() - t0 < 425_000
  doAssert pl.playing and st.phase == phPlaying and st.message.len == 0
  doAssert decodeCalls == 1
  doAssert st.bufferPct == 66                     # 9600 * 100 / 14336

  # Dipping below the threshold during the hold restarts it.
  setup()
  st.generation += 1
  setPhase(phBuffering, "")
  doAssert feed(kStereo44, count = 24) == 24
  for _ in 0 ..< 15: doAssert tick() == srIdle        # 300 ms into the hold
  var drop: array[FrameBytes, byte]
  doAssert stream.read(drop) == FrameBytes
  doAssert tick() == srIdle                           # below: hold forgotten
  doAssert feed(kStereo44) == 1
  for _ in 0 ..< 20: doAssert tick() == srIdle        # a fresh 400 ms
  doAssert not pl.playing
  doAssert tick() == srYield and pl.playing

block: # decodeLoopFillsTheRingOneFramePerStep
  setup()
  startPlaying()
  # startPlaying's last step decoded the first frame.
  doAssert decodeCalls == 1
  doAssert pl.ring.queuedFrames == 128 + 1152 - 0     # the flush lead plus one frame (DAC time is counted at the next pass)
  keepFed()
  # Each further step decodes exactly one frame until less than a frame +
  # 64 is free, then the pass ends with the 10 ms wait.
  doAssert tick() == srYield and decodeCalls == 2
  doAssert tick() == srYield and decodeCalls == 3
  # free = 4095 - (128 + 3456) = 511 <= 1216: full.
  doAssert pl.ring.freeFrames <= MaxSamplesPerFrame div 2 + 64
  doAssert tick() == srWait and decodeCalls == 3
  doAssert pl.playing and st.underruns == 0
  # Steady state: about 441 frames play per 10 ms; a frame is decoded
  # whenever 1217 are free.
  let loops = stats.audioLoops
  var yields, waits = 0
  for _ in 0 ..< 400:
    keepFed()
    case tick()
    of srYield: inc yields
    of srWait: inc waits
    of srIdle: doAssert false
  doAssert pl.playing and st.underruns == 0 and st.phase == phPlaying
  # One pass = one prologue (the last pass may still be decoding).
  doAssert stats.audioLoops - loops in [waits.uint32, waits.uint32 + 1]
  doAssert yields > 100
  # The frames played are continuous: no gaps of silence after the start.
  var firstSound = 0
  while dac.played[firstSound][0] == 0: inc firstSound
  for i in firstSound + FadeFrames ..< dac.played.len:
    doAssert dac.played[i] == [163'i16, -164'i16], $i & " " & $dac.played[i]   # 16384 * 327 >> 15
  doAssert stats.minQueued != high(uint32) and stats.minQueued >= 512
  doAssert st.sampleRate == 44101 and st.bitrate == 128 and st.channels == 2

block: # windowRefillAndMinimumInput
  setup()
  startPlaying()
  doAssert pl.windowLen == Window - FrameBytes        # filled to 4096, one frame used
  doAssert stream.len == 25 * FrameBytes - Window     # startPlaying filled the pipe: 25 frames
  doAssert st.bufferPct == 69                     # 10000 * 100 / 14336, set at the top of the pass

block: # fadeInVolumeAndMeters
  setup()
  setVolume(50)
  startPlaying(kRamp)
  # The first frame: fade-in over the first 1024 frames of the stream,
  # volume 50 = gain 8192, starting 128 frames (the flush lead) ahead.
  let start = pl.ring.writePos - 2 * 1152
  doAssert start mod RingLen == (pl.ring.playedPos + 256) mod RingLen
  for f in 0 ..< 1152:
    let s = f + 1
    let g = if f < FadeFrames: (8192 * (f + 1)) div FadeFrames else: 8192
    doAssert dac.mem[(start + 2 * f) mod RingLen] == int16((s * g) shr 15), $f
    doAssert dac.mem[(start + 2 * f + 1) mod RingLen] == 0
  # Meters: the peak before the volume (1152 on the left, silence right).
  doAssert st.levelL == meterLevel(1152) and st.levelL > 0
  doAssert st.levelR == 0
  # No fade on the following frames (the pipe holds more ramps).
  doAssert tick() == srYield
  for f in 0 ..< 1152:
    doAssert dac.mem[(start + 2 * (1152 + f)) mod RingLen] == int16(((f + 1) * 8192) shr 15)
  doAssert st.levelL == meterLevel(1152) and st.levelR == 0

  # Muted: silence out, and nothing on the meters.
  setup()
  doAssert toggleMute()
  startPlaying(kStereo44, 100)
  doAssert st.levelL == 0 and st.levelR == 0
  for v in dac.mem: doAssert v == 0
  # Unmuting takes effect at the next pass.
  doAssert not toggleMute()
  keepFed(kStereo44, 100)
  while tick() == srYield: discard
  for _ in 0 ..< 200:
    keepFed(kStereo44, 100)
    discard tick()
  doAssert st.levelL == meterLevel(25600)
  doAssert dac.played[^1] == [int16((25600 * 327) shr 15), int16(ashr(-25600 * 327, 15))]
  # Volume 100 passes samples through unchanged.
  setup()
  setVolume(100)
  startPlaying(kStereo44, 127)
  keepFed(kStereo44, 127)
  for _ in 0 ..< 100:
    keepFed(kStereo44, 127)
    discard tick()
  doAssert dac.played[^1] == [32512'i16, -32512'i16]

block: # monoAndSampleRateChange
  setup()
  setVolume(100)
  startPlaying(kMono48, 10)
  doAssert dac.rateChanges == @[48000'u32] and pl.sampleRate == 48000
  doAssert st.sampleRate == 48001 and st.channels == 1 and st.bitrate == 64
  # The ring restarted silent with the DMA at 0 and the writer 128 frames on;
  # the frame follows, the same sample on both channels.
  doAssert pl.ring.writePos == 256 + 2 * 576
  for f in 0 ..< 576:
    let g = (32768 * (f + 1)) div FadeFrames
    doAssert dac.mem[256 + 2 * f] == int16((2560 * g) shr 15)
    doAssert dac.mem[256 + 2 * f + 1] == dac.mem[256 + 2 * f]
  doAssert dac.mem[256 + 2 * 576] == 0
  # The same rate again does not touch the output.
  keepFed(kMono48, 10)
  for _ in 0 ..< 50:
    keepFed(kMono48, 10)
    discard tick()
  doAssert dac.rateChanges.len == 1
  doAssert dac.played[^1] == [2560'i16, 2560'i16]
  # Back to 44.1 kHz stereo mid-stream.
  for _ in 0 ..< 100:
    keepFed(kStereo44, 10)
    discard tick()
  doAssert dac.rateChanges == @[48000'u32, 44100'u32]
  doAssert st.channels == 2 and st.sampleRate == 44101
  doAssert dac.played[^1] == [2560'i16, -2560'i16]
  doAssert pl.playing and st.underruns == 0

block: # equaliserIsApplied
  setup()
  setVolume(100)
  setEqGain(0, 6)
  startPlaying(kRamp)
  var refEq = initEq()
  refEq.update(44100, [6'i8, 0, 0])
  let start = pl.ring.writePos - 2 * 1152
  var differs = false
  for f in 0 ..< 1152:
    let (l, r) = refEq.process(int16(f + 1), 0)
    let g = if f < FadeFrames: (32768 * (f + 1)) div FadeFrames else: 32768
    doAssert dac.mem[start + 2 * f] == int16(ashr(l.int * g, 15))
    doAssert dac.mem[start + 2 * f + 1] == int16(ashr(r.int * g, 15))
    if l != int16(f + 1): differs = true
  doAssert differs
  # The meter shows the music before the EQ and volume.
  doAssert st.levelL == meterLevel(1152)

block: # spectrumIsPublished
  setup()
  var bars: array[Bands, uint8]
  doAssert not spectrum.read(bars)
  startPlaying()
  doAssert spectrum.read(bars)
  doAssert spectrumN == 0                   # taken (and reset) after the frame
  doAssert bars[0] > 0

block: # decodeTiming
  setup()
  decodeCostUs = 5000
  startPlaying()
  doAssert st.decodeMaxUs == 5000 and st.decodeAvgUs == 5000
  decodeCostUs = 11_000
  keepFed()
  doAssert tick() == srYield
  doAssert st.decodeMaxUs == 11_000 and st.decodeAvgUs == 8000
  st.decodeMaxUs = 0                    # /stats takes the maximum
  decodeCostUs = 2000
  doAssert tick() == srYield
  doAssert st.decodeMaxUs == 2000 and st.decodeAvgUs == 6000
  # The running average halves its history at 1000 frames, so it follows
  # the recent cost.
  for _ in 0 ..< 6000:
    keepFed()
    discard tick()
  doAssert decodeCalls > 1100
  doAssert st.decodeAvgUs >= 2000 and st.decodeAvgUs <= 2010
  doAssert pl.playing and st.underruns == 0

block: # decodeErrorsAreCountedAndSkipped
  setup()
  setVolume(100)
  st.generation += 1
  setPhase(phBuffering, "")
  doAssert feed(kCorrupt) == 1
  doAssert feed(kReservoir, count = 2) == 2
  doAssert feed(kLayer2, count = 3) == 3
  var junk: array[100, byte]
  doAssert stream.write(junk) == 100
  doAssert feed(kEmpty) == 1
  doAssert feed(kStereo44, 20, count = 17) == 17      # 24 frames + 100 bytes = 9700
  while not pl.playing: discard tick()
  # The pass that started playback used the corrupt frame; no audio yet.
  doAssert stats.decodeErrors == [0'u32, 0, 1, 0]
  doAssert pl.ring.queuedFrames == 128
  for _ in 0 ..< 5: doAssert tick() == srYield        # 2 reservoir, 3 layer II
  doAssert stats.decodeErrors == [0'u32, 2, 1, 3]
  doAssert tick() == srYield                          # the junk is skipped
  doAssert stats.decodeErrors == [1'u32, 2, 1, 3]
  doAssert pl.ring.queuedFrames == 128 and st.sampleRate == 0
  doAssert tick() == srYield                          # an empty frame decodes: format known, no samples
  doAssert pl.ring.queuedFrames == 128 and st.sampleRate == 44101
  doAssert st.decodeAvgUs == 3000                 # only decoded frames are timed
  doAssert tick() == srYield
  doAssert pl.ring.queuedFrames == 128 + 1152
  doAssert stats.decodeErrors == [1'u32, 2, 1, 3]

  # A decoder that uses nothing must not spin: the pass ends.
  setup()
  st.generation += 1
  setPhase(phBuffering, "")
  doAssert feed(kStuck, count = 24) == 24
  while not pl.playing: discard tick()
  doAssert decodeCalls == 1 and stats.decodeErrors[0] == 1
  doAssert pl.windowLen == Window
  # (It was the step that began playing, so it already returned the wait.)
  doAssert tick() == srWait and decodeCalls == 2

block: # starvedGoesBackToBuffering
  setup()
  setVolume(100)
  startPlaying(kStereo44, 50)
  # No more data arrives. The player decodes what it has, plays the ring
  # down to under 512 frames, then gives up and fades the rest out.
  var guard = 0
  var n = 0                                           # frames played before the step that gave up
  while pl.playing:
    n = dac.played.len
    discard tick()
    inc guard
    doAssert guard < 2000
  doAssert st.underruns == 1 and st.phase == phBuffering
  doAssert stats.underrunInfo[1] == 2                 # ran out of stream data
  doAssert stats.underrunInfo[2] < MinDecodeInput     # compressed bytes left
  doAssert stats.underrunInfo[3] < 512                # frames queued
  doAssert stats.underrunInfo[0] > 400 and stats.underrunInfo[0] < 1000   # ~0.6 s of audio played
  # 25 frames went in; the last 2400 bytes (6 frames, under the decoder's
  # minimum input) stay undecoded.
  doAssert decodeCalls == 19
  doAssert stream.len + pl.windowLen == 2400
  # What was still queued was faded out, not cut off.
  for _ in 0 ..< 20: discard tick()
  doAssert dac.played[^1] == [0'i16, 0'i16]
  var steps = 0
  for i in n + 1 ..< dac.played.len:
    doAssert dac.played[i][0] <= dac.played[i - 1][0]           # only ever down
    if dac.played[i][0] != dac.played[i - 1][0]: inc steps
  doAssert steps > 50, $steps                                   # a ramp, not a step
  # Buffering again: the leftover data stays, and playback resumes only
  # after the pipe refills and the hold passes.
  doAssert tick() == srIdle
  keepFed(kStereo44, 50)
  for _ in 0 ..< 20: doAssert tick() == srIdle
  doAssert tick() == srYield and pl.playing and st.phase == phPlaying
  doAssert st.underruns == 1

block: # overtakenByTheDma
  setup()
  startPlaying()
  # The stream stops; everything decodable is decoded and queued.
  var guard = 0
  while true:
    let r = tick()
    if r == srWait and stream.len + pl.windowLen < MinDecodeInput: break
    inc guard
    doAssert guard < 100
  doAssert pl.playing
  let queued = pl.ring.queuedFrames            # as of that pass; 441 more have played since
  doAssert queued > 1500
  # Then the audio task is held up until just after the DAC runs dry.
  advanceUs(uint64(queued - 441 + 100) * 1_000_000 div 44100)
  doAssert tick() == srWait
  doAssert not pl.playing and st.underruns == 1 and st.phase == phBuffering
  doAssert stats.underrunInfo[1] == 1                 # the DMA overtook the decoder
  doAssert stats.underrunInfo[2] == 2400 and stats.underrunInfo[3] == 0
  doAssert stats.minQueued == 0
  # Writing restarts 256 frames ahead of the DMA, and the output is silent.
  doAssert pl.ring.writePos == (dac.pos - 441 * 2 + 512 + RingLen) mod RingLen
  let n = dac.played.len
  for _ in 0 ..< 10: discard tick()
  for i in n ..< dac.played.len: doAssert dac.played[i] == [0'i16, 0'i16]

  # With stream data waiting, a hold-up shorter than the ring period is a
  # glitch but not a re-buffer: the decode loop catches up within the pass
  # (as upstream) and playback goes on.
  setup()
  startPlaying()
  keepFed()
  for _ in 0 ..< 50:                                  # into the steady state
    keepFed()
    discard tick()
  var waits = 0                                       # to a pass that decoded nothing
  while waits < 2:
    keepFed()
    waits = if tick() == srWait: waits + 1 else: 0
  keepFed()
  let q = pl.ring.queuedFrames                        # at the top of that pass; 441 have played since
  doAssert q > 2000 and q + 150 < RingFrames
  advanceUs(uint64(q - 441 + 150) * 1_000_000 div 44100)   # 150 frames past empty, within one lap
  guard = 0
  while tick() == srYield:
    keepFed()
    inc guard
  doAssert guard >= 2 and guard < 6                   # several frames back to back
  doAssert pl.playing and st.underruns == 0 and st.phase == phPlaying
  doAssert stats.minQueued == 0
  doAssert stats.maxLoopGapUs > 60_000 and stats.maxLoopGapUs < 92_800
  for _ in 0 ..< 100:
    keepFed()
    discard tick()
  doAssert pl.playing and st.underruns == 0
  doAssert dac.played[^1] == [163'i16, -164'i16]

block: # newGenerationResets
  setup()
  setVolume(100)
  startPlaying(kStereo44, 40)
  keepFed(kStereo44, 40)
  for _ in 0 ..< 100:                                 # well past the fade-in
    keepFed(kStereo44, 40)
    discard tick()
  while tick() != srWait: keepFed(kStereo44, 40)      # to the end of a pass
  doAssert pl.windowLen > 0 and pl.ring.queuedFrames > 2000
  # A new station: the stream task clears the pipe and bumps the generation.
  stream.clear()
  beginGeneration()
  setPhase(phConnecting, "")
  let n = dac.played.len
  doAssert tick() == srIdle
  doAssert not pl.playing and pl.windowLen == 0
  doAssert st.levelL == 0 and st.bufferPct == 0
  # The queued audio fades out over 1024 frames (after the 16-frame margin).
  for _ in 0 ..< 5: doAssert tick() == srIdle
  doAssert dac.played.len - n > 1100
  for i in n + 1 ..< dac.played.len:
    doAssert dac.played[i][0] <= dac.played[i - 1][0]
  doAssert dac.played[n + 8] == [10240'i16, -10240'i16]
  doAssert dac.played[n + 1100] == [0'i16, 0'i16]
  doAssert st.underruns == 0
  # The new stream buffers from scratch and fades in.
  setPhase(phBuffering, "")
  keepFed(kStereo44, 40)
  doAssert tick() == srIdle
  for _ in 0 ..< 19: doAssert tick() == srIdle
  doAssert tick() == srYield and pl.playing

  # The generation is also noticed while the phase stays "buffering"
  # (a quick station change before anything played).
  setup()
  st.generation += 1
  setPhase(phBuffering, "")
  discard feed(kStereo44, count = 10)
  doAssert tick() == srIdle
  beginGeneration()
  doAssert tick() == srIdle and pl.windowLen == 0

block: # stopWithoutANewGenerationStillFades
  setup()
  setVolume(100)
  startPlaying(kStereo44, 40)
  keepFed(kStereo44, 40)
  while tick() == srYield: keepFed(kStereo44, 40)
  let queued = pl.ring.queuedFrames
  doAssert queued > 2000
  setPhase(phError, "The stream ended")
  doAssert tick() == srIdle
  doAssert not pl.playing
  doAssert pl.ring.queuedFrames <= 16 + FadeFrames    # the rest was dropped
  let w = pl.windowLen
  for _ in 0 ..< 10: doAssert tick() == srIdle        # and only once
  doAssert pl.windowLen == w                          # the window is kept (same generation)
  doAssert dac.played[^1] == [0'i16, 0'i16]

block: # diagnostics
  setup()
  doAssert stats.minQueued == high(uint32) and stats.audioLoops == 0
  startPlaying()
  doAssert stats.minQueued == high(uint32)            # sampled at the top of a pass, when already playing
  keepFed()
  while tick() == srYield: keepFed()
  while tick() == srYield: keepFed()                  # one more whole pass
  doAssert stats.minQueued < RingFrames and stats.minQueued > 2000
  resetWaterMarks()
  advanceUs(35_000)
  keepFed()
  discard tick()
  doAssert stats.maxLoopGapUs >= 35_000 and stats.maxLoopGapUs < 60_000

echo "t_player: ok"
