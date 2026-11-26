## Bass / mid / treble equaliser (the filter half of upstream `src/eq.rs`):
## three biquads on the decoded PCM, before the volume. Bass is a low shelf
## at 200 Hz, mid a broad peak at 1 kHz, treble a high shelf at 4 kHz (RBJ
## audio-EQ-cookbook designs), each +-`prefs.EqMaxDb` in 1 dB steps. The
## gains live in `prefs`; the audio task owns an `Eq` and calls `update` and
## `process`.
##
## Boosting would clip loud music, so the input is turned down by the
## largest boost (the volume control makes it up). With every gain at 0 the
## filters are bypassed entirely: no CPU, bit-exact output.
##
## The few functions the filter design needs (exp2, sin, cos, sqrt) are
## upstream's small approximations, good to ~1e-5, kept so the coefficients
## are the same numbers. Pure Nim, single precision throughout.

import ./prefs

{.localPassC: "-ffp-contract=off".}   # Rust never fuses a*b+c; neither may we

# ---- Math ---------------------------------------------------------------

func exp2*(x: float32): float32 =
  ## 2^x for |x| < ~100.
  var n = int32(x)                    # truncates towards zero
  if float32(n) > x:
    n -= 1                            # floor
  let f = x - float32(n)              # 0.0 ..< 1.0
  let p = 1.0'f32 + f * (0.693_147_2'f32 + f * (0.240_226_5'f32 + f *
    (0.055_504_1'f32 + f * (0.009_618_1'f32 + f * 0.001_333_4'f32))))
  p * cast[float32](uint32(n + 127) shl 23)

func sqrtApprox*(x: float32): float32 =
  if x <= 0.0'f32:
    return 0.0'f32
  var y = cast[float32]((cast[uint32](x) shr 1) + 0x1FBD_1DF5'u32)
  for _ in 0 ..< 3:
    y = 0.5'f32 * (y + x / y)
  y

const
  Pi32 = 3.14159265358979323846'f32
  HalfPi32 = 1.57079632679489661923'f32

func sinCos*(x: float32): tuple[sin, cos: float32] =
  ## (sin, cos) of x in 0..PI.
  # Reduce to 0..PI/2: sin(x) = sin(PI - x), cos(x) = -cos(PI - x).
  let flip = x > HalfPi32
  let t = if flip: Pi32 - x else: x
  let t2 = t * t
  let s = t * (1.0'f32 - t2 / 6.0'f32 * (1.0'f32 - t2 / 20.0'f32 *
    (1.0'f32 - t2 / 42.0'f32 * (1.0'f32 - t2 / 72.0'f32))))
  let c = 1.0'f32 - t2 / 2.0'f32 * (1.0'f32 - t2 / 12.0'f32 * (1.0'f32 - t2 / 30.0'f32 *
    (1.0'f32 - t2 / 56.0'f32 * (1.0'f32 - t2 / 90.0'f32))))
  (s, if flip: -c else: c)

# ---- Filter design ------------------------------------------------------

type
  Kind* = enum
    LowShelf, Peak, HighShelf
  Coef* = array[5, float32]
    ## Normalised biquad coefficients [b0, b1, b2, a1, a2].

func design*(kind: Kind; freq, rate: float32; db: int): Coef =
  ## RBJ cookbook.
  let a = exp2(float32(db) * 0.083_048_2'f32)   # 10^(dB / 40)
  let (sin, cos) = sinCos(2.0'f32 * Pi32 * freq / rate)
  var b0, b1, b2, a0, a1, a2: float32
  case kind
  of Peak:
    let alpha = sin / 1.4'f32                   # Q = 0.7: broad
    b0 = 1.0'f32 + alpha * a
    b1 = -2.0'f32 * cos
    b2 = 1.0'f32 - alpha * a
    a0 = 1.0'f32 + alpha / a
    a1 = -2.0'f32 * cos
    a2 = 1.0'f32 - alpha / a
  of LowShelf, HighShelf:
    # Shelf slope 1: alpha = sin / sqrt(2).
    let twoSqrtAAlpha = 2.0'f32 * sqrtApprox(a) * sin * 0.707_106_8'f32
    let ap = a + 1.0'f32
    let am = a - 1.0'f32
    if kind == LowShelf:
      b0 = a * (ap - am * cos + twoSqrtAAlpha)
      b1 = 2.0'f32 * a * (am - ap * cos)
      b2 = a * (ap - am * cos - twoSqrtAAlpha)
      a0 = ap + am * cos + twoSqrtAAlpha
      a1 = -2.0'f32 * (am + ap * cos)
      a2 = ap + am * cos - twoSqrtAAlpha
    else:
      b0 = a * (ap + am * cos + twoSqrtAAlpha)
      b1 = -2.0'f32 * a * (am + ap * cos)
      b2 = a * (ap + am * cos - twoSqrtAAlpha)
      a0 = ap - am * cos + twoSqrtAAlpha
      a1 = 2.0'f32 * (am - ap * cos)
      a2 = ap - am * cos - twoSqrtAAlpha
  let inv = 1.0'f32 / a0
  [b0 * inv, b1 * inv, b2 * inv, a1 * inv, a2 * inv]

const BandDesign: array[3, tuple[kind: Kind, freq: float32]] =
  [(LowShelf, 200.0'f32), (Peak, 1000.0'f32), (HighShelf, 4000.0'f32)]

# ---- The equaliser ------------------------------------------------------

type
  Eq* = object
    coef: array[3, Coef]
    state: array[2, array[3, array[2, float32]]]
      ## Transposed direct form II state: [channel][band][z1, z2].
    pre: float32          ## input scale (turns the signal down by the largest boost)
    gains: array[3, int8] ## the gains and sample rate the coefficients were made for
    rate: uint32
    active: bool

func initEq*(): Eq =
  ## Flat and bypassed (the all-zero state is the same thing).
  Eq(pre: 1.0'f32)

func active*(e: Eq): bool {.inline.} = e.active
func coefficients*(e: Eq; band: int): Coef {.inline.} = e.coef[band]
func preScale*(e: Eq): float32 {.inline.} = e.pre

proc update*(e: var Eq; rate: uint32; gains: array[3, int8]) =
  ## Pick up changed gains or sample rate (cheap when nothing changed).
  if gains == e.gains and rate == e.rate:
    return
  e.gains = gains
  e.rate = rate
  e.active = gains != [0'i8, 0, 0] and rate >= 8000
  if not e.active:
    e.state = default(typeof(e.state))   # no stale tail when re-enabled
    return
  for i in 0 .. 2:
    e.coef[i] = design(BandDesign[i].kind, BandDesign[i].freq, float32(rate), gains[i].int)
  let boost = float32(max(max(gains[0], max(gains[1], gains[2])), 0'i8))
  e.pre = exp2(-boost * 0.166_096_4'f32)  # 10^(-boost / 20)

proc update*(e: var Eq; rate: uint32) {.inline.} =
  ## With the user's gains from `prefs`.
  e.update(rate, prefs.eqGains())

func toSample(v: float32): int16 {.inline.} =
  ## Rust's `(v as i32).clamp(-32768, 32767) as i16`: truncate towards
  ## zero, saturate, NaN gives 0.
  if v >= 32767.0'f32: 32767'i16
  elif v <= -32768.0'f32: -32768'i16
  elif v != v: 0'i16
  else: int16(int32(v))

proc channel(e: var Eq; ch: int; x: int16): int16 {.inline.} =
  var v = float32(x) * e.pre
  for band in 0 .. 2:
    let y = e.coef[band][0] * v + e.state[ch][band][0]
    e.state[ch][band][0] = e.coef[band][1] * v - e.coef[band][3] * y + e.state[ch][band][1]
    e.state[ch][band][1] = e.coef[band][2] * v - e.coef[band][4] * y
    v = y
  toSample(v)

proc process*(e: var Eq; l, r: int16): tuple[l, r: int16] =
  ## Filter one stereo sample. (Deliberately not `inline`: the arithmetic
  ## must be compiled in this file, under the flag above.)
  if not e.active:
    return (l, r)
  (e.channel(0, l), e.channel(1, r))
