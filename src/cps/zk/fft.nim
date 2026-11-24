## Radix-2 FFT over the BLS12-381 scalar field, in natural order.
import field

when defined(zkbuildFftTrace):
  type FftTraceKind* = enum
    ftkPermutation, ftkForward, ftkInverse
  var fftTrace*: proc(kind: FftTraceKind, n, width, left, right, exponent: int) {.closure.}

func powerOfTwoCeil*(n: int): int =
  result = 1
  while result < n:
    if result > high(int) div 2: return 0
    result = result shl 1

proc checkFftSize(n: int) =
  if n == 0 or (n and (n - 1)) != 0 or n.uint64 > (1'u64 shl 32):
    raise newException(ValueError, "invalid FFT size")

func nextBitReversedIndex(current, size: int): int {.inline.} =
  ## Internal counter step: size is a positive power of two, current is in
  ## 0..<size. The all-ones input wraps to zero.
  result = current
  var bit = size shr 1
  while (result and bit) != 0:
    result = result xor bit
    bit = bit shr 1
  result = result xor bit

when defined(zkbuildFftTrace):
  func counterTransitionForTest*(current, size: int): int =
    nextBitReversedIndex(current, size)

iterator stageWidths(n: int, invert: bool): int =
  if invert:
    var width = n
    while width > 1:
      yield width
      width = width shr 1
  else:
    var width = 2
    while width <= n:
      yield width
      if width == n: break
      width = width shl 1

when defined(zkbuildFftTrace):
  proc stageWidthsForTest*(n: int, invert: bool): seq[int] =
    for width in stageWidths(n, invert): result.add width

proc bitReverse(a: var seq[Scalar]) =
  let n = a.len
  var j = 0
  for i in 1 ..< n:
    j = nextBitReversedIndex(j, n)
    when defined(zkbuildFftTrace):
      if not fftTrace.isNil: fftTrace(ftkPermutation, n, 0, i, j, 0)
    if i < j: swap(a[i], a[j])

proc fft*(a: var seq[Scalar], invert = false) =
  let n = a.len
  checkFftSize(n)
  if invert:
    # Reverse the forward butterfly stages, then undo its input permutation.
    # Each reverse stage introduces a factor of two, removed once at the end.
    for width in stageWidths(n, true):
      let root = rootOfUnity(width).inverse()
      for start in countup(0, n - 1, width):
        var w = scalar(1)
        for offset in 0 ..< width div 2:
          when defined(zkbuildFftTrace):
            if not fftTrace.isNil:
              fftTrace(ftkInverse, n, width, start+offset, start+offset+width div 2, offset)
          let u = a[start + offset]
          let v = a[start + offset + width div 2]
          a[start + offset] = u + v
          a[start + offset + width div 2] = (u - v) * w
          w *= root
    a.bitReverse()
    let invN = scalar(n).inverse()
    for x in a.mitems: x *= invN
    return
  a.bitReverse()
  for width in stageWidths(n, false):
    let root = rootOfUnity(width)
    for start in countup(0, n - 1, width):
      var w = scalar(1)
      for offset in 0 ..< width div 2:
        when defined(zkbuildFftTrace):
          if not fftTrace.isNil:
            fftTrace(ftkForward, n, width, start+offset, start+offset+width div 2, offset)
        let u = a[start + offset]
        let v = a[start + offset + width div 2] * w
        a[start + offset] = u + v
        a[start + offset + width div 2] = u - v
        w *= root
proc cosetFft*(a: var seq[Scalar], shift: Scalar, invert = false) =
  ## Forward: coefficients to evaluations at shift * omega^i.
  ## Inverse: those evaluations back to coefficients in the original basis.
  checkFftSize(a.len)
  if shift.zero(): raise newException(ValueError, "zero FFT coset shift")
  if invert: a.fft(invert = true)
  let factor = if invert: shift.inverse() else: shift
  var power = scalar(1)
  for value in a.mitems:
    value *= power
    power *= factor
  if not invert: a.fft()
