## Host tests for the PCM ring (i2s_ring.nim).
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_i2s_ring.nim
##
## `Dac` stands in for the DMA and the data cache: it only ever sees what
## the ring reported through `takeDirty` (the driver cleans exactly those
## cache lines), and it records what it "plays".

import std/random
import ../i2s_ring, ../i2s_out

type
  Dac = object
    cpu: array[RingLen, int16]      ## the ring as the CPU sees it
    mem: array[RingLen, int16]      ## the ring as the DMA sees it
    pos: int                        ## sample index the DMA reads next
    played: seq[int16]              ## left samples, in the order played

var
  dac: Dac
  ring: I2sRing

proc commit() =
  ## What the driver does: copy (clean) the reported spans, and check that
  ## nothing else changed.
  var spans: array[8, Span]
  let n = ring.takeDirty(spans)
  for i in 0 ..< n:
    doAssert spans[i].len > 0 and spans[i].start >= 0
    doAssert spans[i].start + spans[i].len <= RingLen, "a span crosses the end"
    for k in spans[i].start ..< spans[i].start + spans[i].len:
      dac.mem[k] = dac.cpu[k]
  doAssert dac.mem == dac.cpu, "a write was not reported"
  doAssert ring.takeDirty(spans) == 0

proc run(frames: int) =
  ## The DMA plays `frames` frames.
  for _ in 0 ..< frames:
    dac.played.add dac.mem[dac.pos]
    doAssert dac.mem[dac.pos] == dac.mem[dac.pos + 1] or dac.mem[dac.pos + 1] == -dac.mem[dac.pos],
      "left and right got out of step"
    dac.pos = (dac.pos + 2) mod RingLen

proc reset() =
  dac = Dac()
  for i in 0 ..< RingLen: dac.cpu[i] = 0x5A5A       # stale junk
  dac.mem = dac.cpu
  initRing(ring, cast[ptr UncheckedArray[int16]](addr dac.cpu[0]))
  commit()

proc invariants() =
  doAssert ring.writePos mod 2 == 0 and ring.writePos < RingLen
  doAssert ring.playedPos mod 2 == 0 and ring.playedPos < RingLen
  doAssert ring.queuedFrames >= 0 and ring.queuedFrames <= RingFrames
  doAssert ring.freeFrames == max(RingFrames - 1 - ring.queuedFrames, 0)
  if ring.writtenTotal >= ring.playedTotal:
    doAssert ring.queuedFrames.uint64 == ring.writtenTotal - ring.playedTotal
    # The writer is exactly `queued` frames ahead of the accounted position.
    doAssert (ring.playedPos + 2 * ring.queuedFrames) mod RingLen == ring.writePos
  else:
    doAssert ring.queuedFrames == 0

block: # startsSilentAndReportsEverything
  reset()
  for v in dac.cpu: doAssert v == 0
  doAssert ring.queuedFrames == 0 and ring.freeFrames == RingFrames - 1
  doAssert ring.writePos == 0 and ring.playedPos == 0
  invariants()

block: # pushConsumeAndWrap
  reset()
  # Keep the ring topped up for many laps; what the DAC plays is exactly
  # the pushed sequence, in order, with nothing repeated.
  var next = 1'i16
  var want: seq[int16]
  for round in 0 ..< 400:
    ring.consumePlayed(dac.pos)
    var room = min(ring.freeFrames, 300 + (round mod 7) * 100)
    while room > 0:
      ring.push(next, -next)
      want.add next
      next = if next == 30000: 1'i16 else: next + 1
      dec room
    commit()
    invariants()
    run(250)
    doAssert ring.writtenTotal == want.len.uint64
  doAssert dac.played.len == 400 * 250
  doAssert ring.playedTotal == 399 * 250
  doAssert dac.played == want[0 ..< dac.played.len]
  # Everything behind the DMA has been zeroed.
  ring.consumePlayed(dac.pos)
  commit()
  var live = 0
  for i in 0 ..< RingFrames:
    if dac.mem[2 * i] != 0: inc live
  doAssert live == ring.queuedFrames

block: # freeFramesNeverLetsTheWriterLapTheReader
  reset()
  var n = 0
  while ring.freeFrames > 0:
    ring.push(7, 7)
    inc n
  doAssert n == RingFrames - 1 and ring.queuedFrames == RingFrames - 1
  commit()
  invariants()
  run(100)
  ring.consumePlayed(dac.pos)
  doAssert ring.freeFrames == 100
  commit()

block: # stalledWriterGivesSilenceNotAnEcho
  reset()
  for i in 0 ..< 1000: ring.push(1000, 1000)
  commit()
  # The writer stalls; the audio task still accounts for what was played.
  for _ in 0 ..< 40:                         # 40 x 500 frames: almost 5 laps
    run(500)
    ring.consumePlayed(dac.pos)
    commit()
    invariants()
  doAssert dac.played.len == 20000
  for i in 0 ..< 1000: doAssert dac.played[i] == 1000
  for i in 1000 ..< 20000: doAssert dac.played[i] == 0
  doAssert ring.queuedFrames == 0 and ring.playedTotal == 20000
  doAssert ring.writtenTotal < ring.playedTotal

block: # underrunResync
  reset()
  doAssert ring.resyncIfUnderrun(dac.pos, 256)   # nothing queued yet counts
  doAssert ring.queuedFrames == 256 and ring.writePos == 512
  for i in 0 ..< 300: ring.push(5, 5)
  commit()
  doAssert not ring.resyncIfUnderrun(dac.pos, 256)
  run(100)
  ring.consumePlayed(dac.pos)
  doAssert not ring.resyncIfUnderrun(dac.pos, 256)   # 456 still queued
  doAssert ring.queuedFrames == 456
  # A stall longer than what was queued, but shorter than the ring.
  run(3000)
  ring.consumePlayed(dac.pos)
  doAssert ring.queuedFrames == 0
  doAssert ring.resyncIfUnderrun(dac.pos, 256)
  doAssert ring.writePos == (dac.pos + 512) mod RingLen
  doAssert ring.queuedFrames == 256
  doAssert ring.writtenTotal == ring.playedTotal + 256
  commit()
  invariants()
  # Writing resumes 256 frames ahead: the DAC plays 256 frames of silence,
  # then the new audio.
  dac.played.setLen 0
  for i in 0 ..< 400: ring.push(9, 9)
  commit()
  run(656)
  for i in 0 ..< 256: doAssert dac.played[i] == 0
  for i in 256 ..< 656: doAssert dac.played[i] == 9
  # Exactly caught up (written == played) is an underrun too.
  ring.consumePlayed(dac.pos)
  doAssert ring.writtenTotal == ring.playedTotal
  doAssert ring.resyncIfUnderrun(dac.pos, 256)
  # Across the end of the ring.
  reset()
  run(RingFrames - 100)
  ring.consumePlayed(dac.pos)
  doAssert ring.resyncIfUnderrun(dac.pos, 256)
  doAssert ring.writePos == 2 * 156
  invariants()

block: # longStallsKeepTheTotalsMonotonic
  reset()
  var lastPlayed = 0'u64
  var rng = initRand(42)
  for round in 0 ..< 2000:
    run(rng.rand(0 .. 2 * RingFrames))       # sometimes more than a whole lap
    ring.consumePlayed(dac.pos)
    doAssert ring.playedTotal >= lastPlayed
    lastPlayed = ring.playedTotal
    discard ring.resyncIfUnderrun(dac.pos, 256)
    var room = min(ring.freeFrames, rng.rand(0 .. 1500))
    while room > 0:
      ring.push(3, 3)
      dec room
    if rng.rand(20) == 0: ring.fadeOut(dac.pos, 1024)
    if rng.rand(50) == 0: ring.flushSilence(dac.pos)
    commit()
    invariants()

block: # fadeOut
  reset()
  run(50)
  ring.consumePlayed(dac.pos)
  discard ring.resyncIfUnderrun(dac.pos, 0)
  for i in 0 ..< 3000: ring.push(16000, -16000)
  commit()
  run(10)                                    # the DMA moved on since the last accounting
  let pos = dac.pos
  ring.fadeOut(pos, 1024)
  commit()
  # 16 frames ahead of the DMA are untouched, then a 1024-frame ramp down,
  # then silence to the end of what was queued.
  let queued = 3000
  for k in 0 ..< queued - 10:
    let v = dac.mem[(pos + 2 * k) mod RingLen].int
    let r = dac.mem[(pos + 2 * k + 1) mod RingLen].int
    doAssert r == -v or (v == 0 and r == 0) or r == -v - 1
    if k < 16: doAssert v == 16000
    elif k < 16 + 1024:
      let n = 1024
      doAssert v == (16000 * ((n - (k - 16)) * 32768 div n)) shr 15
    else: doAssert v == 0
  doAssert dac.mem[(pos + 2 * 16) mod RingLen] == 16000      # gain 1 at the start
  doAssert dac.mem[(pos + 2 * (16 + 1023)) mod RingLen] == 15  # 16000 / 1024
  doAssert ring.writePos == (pos + 2 * (16 + 1024)) mod RingLen
  doAssert ring.writtenTotal == ring.playedTotal + 16 + 1024
  doAssert ring.queuedFrames == 1040
  # Negative samples round towards minus infinity, like upstream's `>> 15`.
  doAssert dac.mem[(pos + 2 * (16 + 1023) + 1) mod RingLen] == -16
  # New audio pushed after the fade lands right behind it.
  ring.push(77, 77)
  commit()
  doAssert dac.mem[(pos + 2 * 1040) mod RingLen] == 77

  # Less queued than the fade length: the ramp is squeezed into what's there.
  reset()
  for i in 0 ..< 216: ring.push(-20000, 20000)
  commit()
  ring.fadeOut(dac.pos, 1024)
  commit()
  for k in 0 ..< 216:
    let v = dac.mem[2 * k].int
    if k < 16: doAssert v == -20000
    else: doAssert v == ashr(-20000 * ((200 - (k - 16)) * 32768 div 200), 15)
  doAssert ring.queuedFrames == 216 and ring.writePos == 432

  # At most the margin queued: left alone.
  reset()
  for i in 0 ..< 16: ring.push(123, 123)
  commit()
  ring.fadeOut(dac.pos, 1024)
  var spans: array[8, Span]
  doAssert ring.takeDirty(spans) == 0
  doAssert ring.queuedFrames == 16 and dac.cpu[0] == 123
  ring.fadeOut(dac.pos, 0)                   # a zero-length fade: one frame, no division by zero
  reset()
  for i in 0 ..< 100: ring.push(123, 123)
  ring.fadeOut(dac.pos, 0)
  commit()
  doAssert dac.mem[2 * 16] == 123 and dac.mem[2 * 17] == 0
  doAssert ring.queuedFrames == 17

  # A fade that wraps round the end of the ring.
  reset()
  run(RingFrames - 300)
  ring.consumePlayed(dac.pos)
  discard ring.resyncIfUnderrun(dac.pos, 0)
  for i in 0 ..< 2000: ring.push(8000, 8000)
  commit()
  ring.fadeOut(dac.pos, 1024)
  commit()
  invariants()
  dac.played.setLen 0
  run(2000)
  for k in 0 ..< 2000:
    if k < 16: doAssert dac.played[k] == 8000
    elif k < 1040: doAssert dac.played[k] == int16((8000 * ((1024 - (k - 16)) * 32768 div 1024)) shr 15)
    else: doAssert dac.played[k] == 0
  for k in 17 ..< 1040: doAssert dac.played[k] <= dac.played[k - 1]

block: # flushSilence
  reset()
  for i in 0 ..< 2000: ring.push(4000, 4000)
  commit()
  run(700)
  ring.flushSilence(dac.pos)
  commit()
  for v in dac.mem: doAssert v == 0
  doAssert ring.playedTotal == 700 and ring.playedPos == dac.pos
  doAssert ring.writePos == dac.pos + 256
  doAssert ring.queuedFrames == 128 and ring.writtenTotal == 828
  invariants()

block: # restartAfterARateChange
  reset()
  for i in 0 ..< 2000: ring.push(4000, 4000)
  commit()
  run(900)
  ring.consumePlayed(dac.pos)
  let playedBefore = ring.playedTotal
  # The driver stops the output, restarts the ring and starts the DMA again
  # at sample 0.
  ring.restart()
  commit()
  dac.pos = 0
  for v in dac.mem: doAssert v == 0
  doAssert ring.playedPos == 0 and ring.writePos == 256
  doAssert ring.playedTotal == playedBefore and ring.queuedFrames == 128
  invariants()
  dac.played.setLen 0
  for i in 0 ..< 10: ring.push(1, 1)
  commit()
  run(138)
  for i in 0 ..< 128: doAssert dac.played[i] == 0
  for i in 128 ..< 138: doAssert dac.played[i] == 1

block: # dirtySpans
  var spans: array[8, Span]
  reset()
  # One run of pushes is one span.
  for i in 0 ..< 100: ring.push(1, 1)
  doAssert ring.takeDirty(spans) == 1 and spans[0] == Span(start: 0, len: 200)
  # A run across the end of the ring is split in two.
  reset()
  run(RingFrames - 10)
  ring.consumePlayed(dac.pos)
  commit()
  discard ring.resyncIfUnderrun(dac.pos, 0)
  for i in 0 ..< 30: ring.push(1, 1)
  doAssert ring.takeDirty(spans) == 2
  doAssert spans[0] == Span(start: RingLen - 20, len: 20) and spans[1] == Span(start: 0, len: 40)
  # Zeroing behind the DMA and pushing ahead of it are separate spans.
  reset()
  for i in 0 ..< 500: ring.push(1, 1)
  commit()
  run(100)
  ring.consumePlayed(dac.pos)
  for i in 0 ..< 50: ring.push(1, 1)
  doAssert ring.takeDirty(spans) == 2
  doAssert spans[0] == Span(start: 0, len: 200) and spans[1] == Span(start: 1000, len: 100)
  # More scattered writes than the ring tracks: the whole ring is reported.
  reset()
  for round in 0 ..< 6:
    for i in 0 ..< 10: ring.push(1, 1)
    discard ring.resyncIfUnderrun(dac.pos, 0)        # no underrun: nothing happens
    run(4)
    ring.consumePlayed(dac.pos)
    ring.fadeOut(dac.pos, 0)
  let n = ring.takeDirty(spans)
  var total = 0
  for i in 0 ..< n: total += spans[i].len
  doAssert total <= RingLen
  for i in 0 ..< RingLen: dac.mem[i] = 0
  for i in 0 ..< n:
    for k in spans[i].start ..< spans[i].start + spans[i].len: dac.mem[k] = dac.cpu[k]
  doAssert dac.mem == dac.cpu

block: # clockPlan (the pure part of i2s_out.nim)
  # Audio PLL output for a 40 MHz crystal: 10 MHz x sdmin / 2048 / post divider.
  func pllHz(p: ClockPlan): float = 10e6 * p.sdmin.float / 2048.0 / p.postDiv.float
  for rate in [8000'u32, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]:
    let p = clockPlan(rate)
    # The two vendor settings: 451.584 MHz / 20 and 442.368 MHz / 18.
    if rate mod 11025 == 0:
      doAssert p.sdmin == 0x16944 and p.postDiv == 20
      doAssert abs(pllHz(p) - 22_579_200.0) < 200.0
    else:
      doAssert p.sdmin == 0x161E5 and p.postDiv == 18
      doAssert abs(pllHz(p) - 24_576_000.0) < 200.0
    # BCK = 64 fs with a 50 % duty cycle, exact for every MPEG rate.
    doAssert p.bclkDivL == p.bclkDivH and p.bclkDivL <= 0xFFF
    let got = pllHz(p) / (p.bclkDivL + p.bclkDivH + 2).float / 64.0
    doAssert abs(got / rate.float - 1.0) < 10e-6          # within 10 ppm
    doAssert actualRate(rate) == rate
    doAssert abs(actualRate(rate).float - got) <= 0.5
  doAssert clockPlan(44100).bclkDivL == 3 and clockPlan(48000).bclkDivL == 3
  doAssert clockPlan(8000).bclkDivL == 23 and clockPlan(11025).bclkDivL == 15
  # A rate the dividers cannot hit exactly reports what it really gets, and
  # nonsense does not divide by zero or overflow the 12-bit fields.
  doAssert clockPlan(44000).bclkDivL + clockPlan(44000).bclkDivH + 2 == 9
  doAssert actualRate(44000) == 42667
  doAssert clockPlan(0).bclkDivL <= 0xFFF and clockPlan(high(uint32)).bclkDivL == 0
  doAssert actualRate(1) > 0

echo "t_i2s_ring: ok"
