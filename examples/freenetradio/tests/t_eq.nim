## Host tests for the equaliser (eq.nim), bit-exact against upstream's
## `src/eq.rs`.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_eq.nim
##
## The reference is the text printed by a small Rust harness around the
## filter half of upstream's file (coefficients, a filtered noise signal and
## the three approximations, as float bit patterns). Its FNV-1a hash is
## pinned below; set EQ_REF to the harness's output file to see the first
## differing line instead.

import std/[strutils, os, math]
import ../eq, ../prefs

{.localPassC: "-ffp-contract=off".}   # the harness's inputs are computed here

const
  RefHash = 0xFAC9558242CEE5A4'u64
  RefLines = 256

func hex8(v: float32): string = toHex(cast[uint32](v), 8).toLowerAscii

proc lcg(x: var uint32): uint32 =
  x = x * 1664525'u32 + 1013904223'u32
  x

proc reference(): string =
  ## The same lines as the Rust harness.
  const rates = [8000'u32, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
  const sets: array[9, array[3, int8]] = [[6'i8, 0, 0], [0'i8, 0, 6], [-2'i8, 3, 2],
    [5'i8, -2, 4], [3'i8, 0, -3], [10'i8, 10, 10], [-10'i8, -10, -10], [1'i8, -1, 0], [0'i8, 7, 0]]
  for rate in rates:
    for g in sets:
      var e = initEq()
      e.update(rate, g)
      result.add "C " & $rate & " " & $g[0] & " " & $g[1] & " " & $g[2]
      for b in 0 .. 2:
        for k in 0 .. 4:
          result.add " " & hex8(e.coefficients(b)[k])
      result.add " " & hex8(e.preScale) & "\n"
      var x = 0x1234_5678'u32
      var sum = 0'u64
      var first: array[8, int16]
      for i in 0 ..< 4000:
        let l = cast[int16](uint16(lcg(x) shr 16))
        let r = int16(cast[int16](uint16(lcg(x) shr 16)).int div 3)
        let (ol, orr) = e.process(l, r)
        sum = (sum * 1_000_003'u64 + cast[uint16](ol).uint64) * 1_000_003'u64 + cast[uint16](orr).uint64
        if i < 4:
          first[2 * i] = ol
          first[2 * i + 1] = orr
      result.add "P " & toHex(sum, 16).toLowerAscii & " [" & first.join(", ") & "]\n"
  for i in 0 ..< 41:
    let x = -10.0'f32 + float32(i) * 0.5'f32
    result.add "E " & hex8(x) & " " & hex8(exp2(x)) & "\n"
  const Pi32 = 3.14159265358979323846'f32
  for i in 0 ..< 33:
    let x = Pi32 * float32(i) / 32.0'f32
    let (s, c) = sinCos(x)
    result.add "S " & hex8(x) & " " & hex8(s) & " " & hex8(c) & "\n"
  for i in 0 ..< 20:
    let x = 0.1'f32 + float32(i) * 0.37'f32
    result.add "Q " & hex8(x) & " " & hex8(sqrtApprox(x)) & "\n"

func fnv1a(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor c.uint64) * 0x100000001b3'u64

block: # bitExactAgainstUpstream
  let mine = reference()
  let refPath = getEnv("EQ_REF")
  if refPath.len > 0:
    let want = readFile(refPath).splitLines
    let got = mine.splitLines
    for i in 0 ..< min(want.len, got.len):
      doAssert want[i] == got[i], "line " & $(i + 1) & "\n want " & want[i] & "\n got  " & got[i]
    doAssert want.len == got.len
  doAssert mine.countLines == RefLines + 1
  doAssert fnv1a(mine) == RefHash, "hash " & toHex(fnv1a(mine))

block: # approximationsAreClose
  for i in -40 .. 40:
    let x = i.float32 * 0.25'f32
    doAssert abs(exp2(x) / pow(2.0'f32, x) - 1.0'f32) < 2e-5'f32
  for i in 1 .. 200:
    let x = i.float32 * 0.173'f32
    doAssert abs(sqrtApprox(x) / sqrt(x) - 1.0'f32) < 1e-5'f32
  doAssert sqrtApprox(0.0'f32) == 0.0'f32 and sqrtApprox(-4.0'f32) == 0.0'f32
  for i in 0 .. 64:
    let x = PI.float32 * i.float32 / 64.0'f32
    let (s, c) = sinCos(x)
    doAssert abs(s - sin(x)) < 2e-5'f32 and abs(c - cos(x)) < 2e-5'f32

block: # designsHaveTheRightShape
  # Gain at DC and at Nyquist from the coefficients: (b0+b1+b2)/(1+a1+a2)
  # and (b0-b1+b2)/(1-a1+a2).
  func dc(c: Coef): float32 = (c[0] + c[1] + c[2]) / (1.0'f32 + c[3] + c[4])
  func nyq(c: Coef): float32 = (c[0] - c[1] + c[2]) / (1.0'f32 - c[3] + c[4])
  func lin(db: float32): float32 = pow(10.0'f32, db / 20.0'f32)
  for db in [-10, -3, 4, 10]:
    let lo = design(LowShelf, 200.0'f32, 44100.0'f32, db)
    doAssert abs(dc(lo) / lin(db.float32) - 1.0'f32) < 2e-3'f32
    doAssert abs(nyq(lo) - 1.0'f32) < 2e-3'f32
    let hi = design(HighShelf, 4000.0'f32, 44100.0'f32, db)
    doAssert abs(nyq(hi) / lin(db.float32) - 1.0'f32) < 2e-3'f32
    doAssert abs(dc(hi) - 1.0'f32) < 2e-3'f32
    let pk = design(Peak, 1000.0'f32, 44100.0'f32, db)
    doAssert abs(dc(pk) - 1.0'f32) < 2e-3'f32 and abs(nyq(pk) - 1.0'f32) < 2e-3'f32
  # 0 dB designs are the identity filter (b == a).
  for kind in Kind:
    let c = design(kind, 1000.0'f32, 48000.0'f32, 0)
    doAssert abs(c[0] - 1.0'f32) < 1e-5'f32 and abs(c[1] - c[3]) < 1e-5'f32 and abs(c[2] - c[4]) < 1e-5'f32

block: # bypassIsBitExact
  var e = initEq()
  doAssert not e.active
  e.update(44100, [0'i8, 0, 0])
  doAssert not e.active
  var x = 99'u32
  for _ in 0 ..< 2000:
    let l = cast[int16](uint16(lcg(x) shr 16))
    let r = cast[int16](uint16(lcg(x) shr 16))
    doAssert e.process(l, r) == (l, r)
  doAssert e.process(-32768, 32767) == (-32768'i16, 32767'i16)
  # Below 8 kHz the filters stay off whatever the gains.
  e.update(7999, [6'i8, 0, 0])
  doAssert not e.active
  e.update(8000, [6'i8, 0, 0])
  doAssert e.active

block: # preAttenuationAndClipping
  var e = initEq()
  e.update(44100, [6'i8, -3, 2])
  doAssert abs(e.preScale - pow(10.0'f32, -6.0'f32 / 20.0'f32)) < 1e-4'f32
  e.update(44100, [-6'i8, -3, -2])        # cuts only: no attenuation
  doAssert e.preScale == 1.0'f32
  # A full-scale square wave through +10 dB on every band: the output
  # saturates rather than wrapping.
  e.update(44100, [10'i8, 10, 10])
  var lo = high(int16)
  var hi = low(int16)
  for i in 0 ..< 20000:
    let v = if (i div 37) mod 2 == 0: 32767'i16 else: -32768'i16
    let (l, r) = e.process(v, v)
    doAssert l == r
    lo = min(lo, l)
    hi = max(hi, l)
  doAssert hi == 32767 and lo == -32768
  # A full-scale sine at 100 Hz with +6 dB bass comes out at about full
  # scale again (boost made up for by the pre-attenuation), never above.
  e = initEq()
  e.update(44100, [6'i8, 0, 0])
  var peak = 0
  for i in 0 ..< 44100:
    let v = int16(32767.0 * sin(2.0 * PI * 100.0 * i.float / 44100.0))
    let (l, _) = e.process(v, 0)
    if i > 22050: peak = max(peak, abs(l.int))
  doAssert peak > 26000 and peak <= 32767, $peak

block: # updateTracksPrefsAndClearsState
  prefsInit()
  var e = initEq()
  e.update(44100)
  doAssert not e.active
  setEqGain(0, 6)
  e.update(44100)
  doAssert e.active
  let c0 = e.coefficients(0)
  discard e.process(12000, -12000)
  e.update(44100)                           # nothing changed: state kept
  let (l1, _) = e.process(0, 0)
  doAssert l1 != 0                          # the filter tail
  e.update(48000)                           # new rate: new coefficients
  doAssert e.coefficients(0) != c0
  setEqGain(0, 0)
  e.update(48000)                           # flat: bypass and a clean state
  doAssert not e.active
  setEqGain(2, -4)
  e.update(48000)
  doAssert e.process(0, 0) == (0'i16, 0'i16)
  prefsInit()

echo "t_eq: ok"
