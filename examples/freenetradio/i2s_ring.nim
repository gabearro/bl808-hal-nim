## The PCM ring between the audio task and the DAC's DMA (the arithmetic of
## upstream `src/i2s.rs`, without the hardware).
##
## The DMA loops over the ring forever. The audio task writes decoded samples
## ahead of the DMA's read position and zeroes what has been played, so if
## the writer stalls the output falls silent instead of repeating old audio.
## Positions are sample indices (even = start of a stereo frame); the caller
## passes in where the DMA will read next (`readPos`).
##
## On the BL808 the ring sits behind the data cache, so every span the CPU
## writes is also recorded here; the driver takes them with `takeDirty` and
## cleans those cache lines. Pure Nim.

const
  RingFrames* {.intdefine: "radioRingFrames".} = 4096
    ## Ring size in stereo frames (4096 = 93 ms at 44.1 kHz).
  RingLen* = RingFrames * 2
    ## Interleaved L/R int16 samples.
  FadeMargin = 16
    ## Frames left untouched just ahead of the DMA when fading out.
  RestartLead = 128
    ## Frames of silence between the DMA and the writer after a restart.
  MaxDirty = 4

static:
  doAssert RingFrames >= 2048 and RingFrames mod 16 == 0

type
  Span* = object
    ## `len` samples starting at sample `start`.
    start*, len*: int

  I2sRing* = object
    buf: ptr UncheckedArray[int16]
    write: int
      ## Next sample index (even) the writer will fill.
    played: int
      ## Read position seen at the last `consumePlayed`.
    writtenTotal, playedTotal: uint64
      ## Running totals (frames) of what has been queued and what the DMA
      ## has played. Unlike ring positions these cannot wrap, so they show
      ## when the DMA has overtaken the writer (an underrun) however late
      ## we are.
    runStart, runLen: int
      ## Samples appended by `push` since the last bookkeeping (kept apart
      ## so `push` stays a couple of stores).
    dirty: array[MaxDirty, Span]
    dirtyN: int

# ---- Written-span bookkeeping ---------------------------------------------

proc mark(r: var I2sRing; start, len: int) =
  if len <= 0:
    return
  if len >= RingLen:
    r.dirty[0] = Span(start: 0, len: RingLen)
    r.dirtyN = 1
    return
  if r.dirtyN > 0:
    let last = addr r.dirty[r.dirtyN - 1]
    if last.len >= RingLen:
      return
    if (last.start + last.len) mod RingLen == start:
      last.len = min(last.len + len, RingLen)
      if last.len >= RingLen:
        r.dirty[0] = Span(start: 0, len: RingLen)
        r.dirtyN = 1
      return
  if r.dirtyN == MaxDirty:
    r.dirty[0] = Span(start: 0, len: RingLen)
    r.dirtyN = 1
    return
  r.dirty[r.dirtyN] = Span(start: start, len: len)
  inc r.dirtyN

proc closeRun(r: var I2sRing) {.inline.} =
  if r.runLen > 0:
    r.mark(r.runStart, r.runLen)
    r.runLen = 0

proc takeDirty*(r: var I2sRing; spans: var array[2 * MaxDirty, Span]): int =
  ## The spans written since the last call, none of them crossing the end
  ## of the ring; returns how many. Forgets them.
  r.closeRun()
  for i in 0 ..< r.dirtyN:
    let s = r.dirty[i]
    let first = min(s.len, RingLen - s.start)
    spans[result] = Span(start: s.start, len: first)
    inc result
    if s.len > first:
      spans[result] = Span(start: 0, len: s.len - first)
      inc result
  r.dirtyN = 0

proc zeroAll(r: var I2sRing) =
  zeroMem(r.buf, RingLen * sizeof(int16))
  r.runLen = 0
  r.mark(0, RingLen)

# ---- The ring ---------------------------------------------------------------

proc initRing*(r: var I2sRing; buf: ptr UncheckedArray[int16]) =
  ## `buf` holds `RingLen` samples and outlives the ring. Starts silent with
  ## the DMA expected at sample 0.
  r = I2sRing(buf: buf)
  r.zeroAll()

func writePos*(r: I2sRing): int {.inline.} = r.write
func playedPos*(r: I2sRing): int {.inline.} = r.played
func writtenTotal*(r: I2sRing): uint64 {.inline.} = r.writtenTotal
func playedTotal*(r: I2sRing): uint64 {.inline.} = r.playedTotal

proc restart*(r: var I2sRing) =
  ## After a sample-rate change: the output was stopped and will start
  ## again from the beginning of a silent ring (so the left/right order
  ## cannot end up swapped).
  r.zeroAll()
  r.played = 0
  r.write = 2 * RestartLead
  r.writtenTotal = r.playedTotal + uint64(RestartLead)

proc consumePlayed*(r: var I2sRing; readPos: int) =
  ## Account for (and zero) everything the DMA has played since the last
  ## call, so a stalled writer produces silence rather than looping stale
  ## audio. Must be called at least once per ring period (~93 ms).
  let n = (readPos + RingLen - r.played) mod RingLen
  var i = r.played
  for _ in 0 ..< n:
    r.buf[i] = 0
    inc i
    if i == RingLen: i = 0
  r.closeRun()
  r.mark(r.played, n)
  r.playedTotal += uint64(n div 2)
  r.played = readPos

func queuedFrames*(r: I2sRing): int {.inline.} =
  ## Frames queued but not yet played (0 if the DMA has overtaken us).
  if r.writtenTotal > r.playedTotal: int(r.writtenTotal - r.playedTotal) else: 0

func freeFrames*(r: I2sRing): int {.inline.} =
  ## Frames that can be written without overwriting unplayed audio.
  max(RingFrames - 1 - r.queuedFrames, 0)

proc resyncIfUnderrun*(r: var I2sRing; readPos, leadFrames: int): bool =
  ## If the DMA has caught up with or overtaken the writer (an underrun),
  ## restart writing a little ahead of it. Returns true if that happened.
  if r.writtenTotal <= r.playedTotal:
    r.closeRun()
    r.write = (readPos + leadFrames * 2) mod RingLen
    r.writtenTotal = r.playedTotal + uint64(leadFrames)
    true
  else:
    false

proc push*(r: var I2sRing; left, right: int16) {.inline.} =
  ## Append one stereo frame.
  r.buf[r.write] = left
  r.buf[r.write + 1] = right
  if r.runLen == 0:
    r.runStart = r.write
  if r.runLen < RingLen:
    r.runLen += 2
  r.write += 2
  if r.write == RingLen: r.write = 0
  r.writtenTotal += 1

proc fadeOut*(r: var I2sRing; readPos, frames: int) =
  ## Fade the audio already queued for the DAC down to silence over at most
  ## `frames` frames, and silence everything after that, so stopping does
  ## not cut the waveform off mid-cycle (an audible click). The DMA keeps
  ## playing meanwhile; we start a little ahead of it.
  let queued = r.queuedFrames
  if queued <= FadeMargin:
    return
  let start = (readPos + 2 * FadeMargin) mod RingLen
  let count = queued - FadeMargin
  let n = max(min(count, frames), 1)
  var i = start
  for k in 0 ..< count:
    let gain = if k < n: int32((n - k) * 32768 div n) else: 0'i32
    r.buf[i] = int16(ashr(int32(r.buf[i]) * gain, 15))
    r.buf[i + 1] = int16(ashr(int32(r.buf[i + 1]) * gain, 15))
    i += 2
    if i == RingLen: i = 0
  r.closeRun()
  r.mark(start, 2 * count)
  r.write = (start + 2 * n) mod RingLen
  r.writtenTotal = r.playedTotal + uint64(FadeMargin + n)

proc flushSilence*(r: var I2sRing; readPos: int) =
  ## Silence the whole ring and restart writing just ahead of the DMA.
  r.zeroAll()
  r.playedTotal += uint64(((readPos + RingLen - r.played) mod RingLen) div 2)
  r.played = readPos
  r.write = (readPos + 2 * RestartLead) mod RingLen
  r.writtenTotal = r.playedTotal + uint64(RestartLead)
