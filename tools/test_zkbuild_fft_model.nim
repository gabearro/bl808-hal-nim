## Trace the real FFT loops against indices exported from the proved Lean
## layout. Instrumentation is compiled only into this test executable.
import std/[os, strutils]
import cps/zk/[field, fft]

when not defined(zkbuildFftTrace): {.error: "FFT conformance needs -d:zkbuildFftTrace".}
when sizeof(int) < 8: {.error: "FFT model conformance requires a 64-bit host".}

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  require(paramCount() == 1, "usage: test_zkbuild_fft_model TRACE")
  let input = open(paramStr(1))
  defer: input.close()
  require(input.readLine() == "ZKFFT4 15 33", "FFT model header")
  # Compare every supported root against the modular exponentiation in Lean,
  # including domains too large to allocate a transform in a host test.
  for depth in 0..32:
    let fields = input.readLine().splitWhitespace()
    require(fields.len == 3 and fields[0] == "R" and fields[1] == $depth, "root fixture order")
    var raw: BigInt[255]
    require(bool(raw.fromDecimal(fields[2])), "root fixture encoding")
    var encoded: array[32, byte]
    require(encoded.marshal(raw, bigEndian), "root fixture width")
    var expected: Scalar
    require(decodeScalar(encoded, expected), "root fixture is canonical")
    let n = 1 shl depth
    let root = rootOfUnity(n)
    require(root.equals(expected), "FFT root differs from formal model at depth " & $depth)
    require(root.power(n.uint64).equals(scalar(1)), "FFT root order")
    if depth > 0:
      require(root.power((n div 2).uint64).equals(scalar(-1)), "FFT primitive half power")
    require(not (scalar(7).power(n.uint64) - scalar(1)).zero(), "FFT coset separation")
  require(input.readLine() == "COUNTERS", "counter fixture header")
  var counterCases = 0
  while true:
    let line = input.readLine()
    if line == "ENDCOUNTERS": break
    let fields = line.splitWhitespace()
    require(fields.len == 4 and fields[0] == "C", "counter fixture shape")
    let depth = fields[1].parseInt()
    require(depth in 0..32, "counter fixture depth")
    let n = 1 shl depth
    let current = fields[2].parseInt()
    let expected = fields[3].parseInt()
    require(current in 0..<n and expected in 0..<n, "counter fixture bounds")
    require(counterTransitionForTest(current, n) == expected, "counter differs from formal model")
    inc counterCases
  require(counterCases == 858, "complete counter fixture set")
  require(input.readLine() == "WIDTHS", "width fixture header")
  var widthCases, widthsChecked: int
  while true:
    let line = input.readLine()
    if line == "ENDWIDTHS": break
    let fields = line.splitWhitespace()
    require(fields.len >= 4 and fields[0] == "W", "width fixture shape")
    let depth = fields[1].parseInt()
    let direction = fields[2].parseInt()
    let count = fields[3].parseInt()
    require(depth in 0..32 and direction in 0..1 and count == depth, "width fixture bounds")
    require(fields.len == 4+count, "width fixture length")
    let actual = stageWidthsForTest(1 shl depth, direction == 1)
    require(actual.len == count, "width schedule length")
    for i in 0..<count:
      require(actual[i] == fields[4+i].parseInt(), "width differs from formal model")
    inc widthCases
    widthsChecked += count
  require(widthCases == 66 and widthsChecked == 1056, "complete width fixture set")
  var events = 0
  fftTrace = proc(kind: FftTraceKind, n, width, left, right, exponent: int) =
    let label = case kind
      of ftkPermutation: "P"
      of ftkForward: "F"
      of ftkInverse: "I"
    let actual = label & " " & $n & " " & $width & " " & $left & " " & $right & " " & $exponent
    let expected = input.readLine()
    require(actual == expected, "FFT schedule differs at event " & $events & ": " & actual & " / " & expected)
    inc events
  for bits in 0..<15:
    let n = 1 shl bits
    for inverse in [false, true]:
      require(input.readLine() == "T " & $n & " " & $ord(inverse), "FFT case header")
      var values = newSeq[Scalar](n)
      values.fft(inverse)
      require(input.readLine() == "E", "FFT trace ended early")
  fftTrace = nil
  require(input.endOfFile(), "trailing FFT trace")
  echo "zkbuild FFT conformance: PASS (33 exact roots, ", counterCases,
    " counter cases, ", widthsChecked, " widths, 15 domains, ", events, " loop events)"

main()
