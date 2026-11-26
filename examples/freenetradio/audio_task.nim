## The audio task: MP3 decode, EQ, volume, fades and meters into the I2S ring
## (upstream `radio::audio_task`). All of the logic is in `player.nim`; this
## file gives it the real decoder and DAC, the buffers that are too big for
## anything but the heap, and a loop to run in. Firmware only.

import bl808/kernel/cps
import ./mp3dec, ./i2s_ring, ./i2s_out, ./player, ./diag

type
  Audio = object
    player: Player
    decoder: Mp3Decoder                          # ~22 KB
    window: array[Window, byte]
    pcm: array[MaxSamplesPerFrame, int16]

var audio: ptr Audio

proc decodeFrame(ctx: pointer; mp3: openArray[byte]; pcm: var openArray[int16];
                 info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] {.nimcall.} =
  cast[ptr Mp3Decoder](ctx)[].decode(mp3, pcm, info)

proc spectrumOf(ctx: pointer; energy: var array[SpectrumBands, float32]): uint32 {.nimcall.} =
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

proc audioTask(): CpsVoidFuture {.cps.} =
  while true:
    var next: StepResult
    timed(slAudio): next = audioStep()
    if next == srIdle:
      await sleepMs(20)
    elif next == srWait:
      await sleepMs(10)
    else:
      await yieldNow()

proc audioStart*() =
  ## Start the DAC clocking out silence at 44.1 kHz and the task that feeds
  ## it. Call once, after the heap, `timebase`, `status`, `pipe`, `prefs`,
  ## `spectrum` and `diag` are set up.
  audio = createShared(Audio)
  initDecoder(audio.decoder)
  i2sOutInit(InitialSampleRate)
  initPlayer(audio.player, ringBuffer(),
             cast[ptr UncheckedArray[byte]](addr audio.window[0]),
             cast[ptr UncheckedArray[int16]](addr audio.pcm[0]),
             DecoderOps(ctx: addr audio.decoder, decode: decodeFrame, takeSpectrum: spectrumOf),
             OutputOps(readPos: dacReadPos, commit: dacCommit,
                       setSampleRate: dacSetSampleRate, actualRate: dacActualRate))
  discard audioTask()
