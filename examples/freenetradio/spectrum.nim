## Spectrum analyser data (upstream `src/spectrum.rs`). The MP3 decoder sums
## the energy of its frequency lines into `Bands` bands per frame; `publish`
## turns that into bar heights on a dB scale for the display. Pure Nim.

import ./timebase, ./diag

const
  Bands* = 40
  SpectrumFloorDb* = -62.0'f32
  SpectrumRangeDb* = 40.0'f32
    ## A band's mean power in dB maps floor .. floor + range onto 0 .. 255.
  FreshMs = 120
    ## Newer data than this is "live"; older means the decoder has stopped.

var
  bars: array[Bands, uint8]
  publishedMs: uint64
  published: bool

func log2Approx*(x: float32): float32 =
  ## log2 of a positive, normal float32, accurate to about 0.01 (upstream's
  ## cubic fit of the mantissa, kept so the bars match).
  let bits = cast[uint32](x)
  let e = int((bits shr 23) and 0xFF) - 127
  let m = cast[float32]((bits and 0x007F_FFFF'u32) or 0x3F80_0000'u32)
  let frac = -1.741_793_9'f32 + (2.821_202_6'f32 + (-1.469_956_8'f32 +
    (0.447_179_55'f32 - 0.056_570_851'f32 * m) * m) * m) * m
  e.float32 + frac

proc publish*(energy: array[Bands, float32]; n: uint32) =
  ## Convert the decoder's band sums (over `n` granule-channels) to bars.
  if n == 0: return
  var fresh: array[Bands, uint8]
  var dbg: array[5, int16]
  for i in 0 ..< Bands:
    let p = energy[i] / n.float32
    if p > 1e-8'f32:
      let db = 3.0103'f32 * log2Approx(p)
      fresh[i] = clamp((db - SpectrumFloorDb) * 255.0'f32 / SpectrumRangeDb,
                       0.0'f32, 255.0'f32).uint8
      let k = [0, 10, 20, 30, 39].find(i)
      if k >= 0: dbg[k] = db.int16
  bars = fresh
  publishedMs = nowMs()
  published = true
  stats.spectrumDb = dbg

proc read*(dst: var array[Bands, uint8]): bool =
  ## The latest bars; false if there is no live data (not decoding).
  if not published or elapsedMs(publishedMs, nowMs()) >= FreshMs:
    return false
  dst = bars
  true

proc spectrumInit*() =
  published = false
