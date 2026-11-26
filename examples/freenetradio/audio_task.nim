## The audio task: MP3 decode, EQ, volume, fades and meters into the I2S ring
## (upstream `radio::audio_task`). All of the logic is in `player.nim`; this
## file gives it the real decoder and DAC, the buffers that are too big for
## anything but the heap, and a loop to run in. Firmware only.

import bl808/kernel/cps
import ./mp3dec, ./i2s_ring, ./i2s_out, ./player

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

proc audioStep(): StepResult =
  pollErrors()
  audio.player.step()

proc audioTask(): CpsVoidFuture {.cps.} =
  while true:
    let next = audioStep()
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
