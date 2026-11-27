## The audio task: MP3 decode, EQ, volume, fades and meters into the I2S ring
## (upstream `radio::audio_task`). All of the logic is in `player.nim`; this
## file gives it the real decoder and DAC, the buffers that are too big for
## anything but the heap, and a loop to run in. Firmware only.

import bl808/kernel/cps
import ./mp3dec, ./i2s_ring, ./i2s_out, ./player, ./diag, ./timebase
import ./mp3_d0_client
when defined(bl808m0) and defined(radioProfiler):
  import bl808/kernel/profiler
  import ./status

type
  Audio = object
    player: Player
    decoder: Mp3Decoder                          # ~22 KB
    window: array[Window, byte]
    pcm: array[MaxSamplesPerFrame, int16]

var audio: ptr Audio

proc decodeFrame(ctx: pointer; mp3: openArray[byte]; pcm: var openArray[int16];
                 info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] {.nimcall.} =
  when defined(bl808m0) and defined(radioProfiler):
    let span = beginProfileSpan()
  var decodedRemotely = false
  when radioD0Mp3Image.len != 0:
    if workerEnabled:
      result = decodeOnD0(mp3, pcm, info)
      decodedRemotely = workerEnabled
  if not decodedRemotely:
    result = cast[ptr Mp3Decoder](ctx)[].decode(mp3, pcm, info)
  when defined(bl808m0) and defined(radioProfiler):
    endProfileSpan(span, prDecode, work = (result.status == dsDecoded).uint32)

proc spectrumOf(ctx: pointer; energy: var array[SpectrumBands, float32]): uint32 {.nimcall.} =
  when radioD0Mp3Image.len != 0:
    if workerEnabled:
      return workerSpectrum(energy)
  cast[ptr Mp3Decoder](ctx)[].takeSpectrum(energy)

proc dacReadPos(): int {.nimcall.} = i2s_out.readPos()
proc dacCommit(ring: var I2sRing) {.nimcall.} = i2s_out.commit(ring)
proc dacSetSampleRate(ring: var I2sRing; rate: uint32) {.nimcall.} = i2s_out.setSampleRate(ring, rate)
proc dacActualRate(rate: uint32): uint32 {.nimcall.} = i2s_out.actualRate(rate)

const
  UrgentFrames = 3 * 1152
    ## With less than this queued for the DAC (78 ms at 44.1 kHz), decoding
    ## comes before the other tasks: every task shares one processor, and a
    ## turn of the scheduler can take longer than a frame lasts.
  UrgentBurst = 3
    ## At most this many frames in a row (about 15 ms) before the others run.

proc audioStep(): StepResult =
  pollErrors()
  result = audio.player.step()
  var burst = 1
  while result == srYield and burst < UrgentBurst and
        audio.player.queuedFrames < UrgentFrames:
    result = audio.player.step()
    inc burst

when DiagEnabled:
  proc recordAudioSleepOvershoot(startUs, budgetUs: uint64) =
    let elapsed = nowUs() - startUs
    let overshoot = if elapsed > budgetUs: elapsed - budgetUs else: 0'u64
    let value = uint32(min(overshoot, high(uint32).uint64))
    stats.audioSleepOvershootMaxUs = max(stats.audioSleepOvershootMaxUs, value)
    if value > 15_000'u32: inc stats.audioSleepOver15ms

template armAudioWait(deadline: untyped): untyped =
  # Keep optional types behind a template. CPS infers lifted local types
  # even in branches that the compiler later removes.
  when defined(bl808m0) and defined(radioProfiler):
    if recordingProfile() and status.player.phase == phPlaying:
      beginProfileWait(deadline.uint32)
    else:
      ProfileWait()
  else:
    default(tuple[])

template finishAudioWait(wait: untyped; yielded: static bool) =
  when defined(bl808m0) and defined(radioProfiler):
    endProfileWait(wait, yielded)

proc audioTask(): CpsVoidFuture {.cps.} =
  while true:
    var next: StepResult
    timed(slAudio): next = audioStep()
    when radioD0Mp3Image.len != 0:
      if next == srDecodePending:
        await decodeReady
        continue
    if next != srYield:
      let waitMs = if next == srIdle: 20'u64 else: 10'u64
      when DiagEnabled:
        let waitStart = nowUs()
      let due = readTick() + msToTicks(waitMs)
      let wait = armAudioWait(due)
      await sleepUntil(due)
      finishAudioWait(wait, false)
      when DiagEnabled:
        recordAudioSleepOvershoot(waitStart, waitMs * 1000)
    else:
      when DiagEnabled:
        let waitStart = nowUs()
      let wait = armAudioWait(readTick())
      await yieldNow()
      finishAudioWait(wait, true)
      when DiagEnabled:
        let value = uint32(min(nowUs() - waitStart, high(uint32).uint64))
        stats.audioYieldWaitMaxUs = max(stats.audioYieldWaitMaxUs, value)
        if value > 15_000'u32: inc stats.audioYieldWaitOver15ms

proc audioStart*() =
  ## Start the DAC clocking out silence at 44.1 kHz and the task that feeds
  ## it. Call once, after the heap, `timebase`, `status`, `pipe`, `prefs`,
  ## `spectrum` and `diag` are set up.
  audio = createShared(Audio)
  initDecoder(audio.decoder)
  var dec = DecoderOps(ctx: addr audio.decoder, decode: decodeFrame, takeSpectrum: spectrumOf)
  when radioD0Mp3Image.len != 0:
    startMp3Worker()
    dec.decodeUs = workerDecodeUs
  i2sOutInit(InitialSampleRate)
  initPlayer(audio.player, ringBuffer(),
             cast[ptr UncheckedArray[byte]](addr audio.window[0]),
             cast[ptr UncheckedArray[int16]](addr audio.pcm[0]),
             dec,
             OutputOps(readPos: dacReadPos, commit: dacCommit,
                       setSampleRate: dacSetSampleRate, actualRate: dacActualRate))
  discard audioTask()
