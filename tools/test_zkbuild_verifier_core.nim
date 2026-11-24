## Check the exact production verifier core against a Lean schedule using
## symbolic group operations, then exercise the accumulator on real BLS points.
import std/[os, osproc, strutils]
import cps/zk/[groups, verifier_core]

type
  SymbolicTerm = object
    point, scalar, sign: int
  SymbolicPoint = object
    terms: seq[SymbolicTerm]
  SymbolicScalar = object
    index: int
  SymbolicRight = object
    index: int
  PairSpec = tuple[sign, left, right: int]

var addCalls, multiplyCalls, negateCalls, pairingCalls: int
var oracleVerdict: bool
var observedLeft: array[4, SymbolicPoint]
var observedRight: array[4, SymbolicRight]
var observedProducts: seq[tuple[coefficient, input: int]]

proc require(condition: bool, message: string) =
  if not condition: raise newException(ValueError, message)

proc point(index: int): SymbolicPoint =
  SymbolicPoint(terms: @[SymbolicTerm(point: index, scalar: -1, sign: 1)])

proc add(a, b: SymbolicPoint): SymbolicPoint =
  inc addCalls
  SymbolicPoint(terms: a.terms & b.terms)

proc multiply(a: SymbolicPoint, b: SymbolicScalar): SymbolicPoint =
  inc multiplyCalls
  require(a.terms.len == 1 and a.terms[0].scalar == -1 and a.terms[0].point >= 0,
    "unexpected nonlinear symbolic multiplication")
  observedProducts.add (a.terms[0].point, b.index)
  SymbolicPoint(terms: @[SymbolicTerm(point: a.terms[0].point, scalar: b.index, sign: a.terms[0].sign)])

proc neg(a: var SymbolicPoint) =
  inc negateCalls
  var updated = newSeq[SymbolicTerm](a.terms.len)
  for i, term in a.terms:
    updated[i] = term
    updated[i].sign = -term.sign
  a.terms = updated

proc pairingProductIsOne(a: array[4, SymbolicPoint], b: array[4, SymbolicRight]): bool =
  inc pairingCalls
  observedLeft = a
  observedRight = b
  oracleVerdict

proc resetCalls() =
  addCalls = 0
  multiplyCalls = 0
  negateCalls = 0
  pairingCalls = 0
  observedProducts.setLen(0)

proc signed(a: SymbolicPoint, sign: int): SymbolicPoint =
  result.terms = newSeq[SymbolicTerm](a.terms.len)
  for i, term in a.terms:
    result.terms[i] = term
    result.terms[i].sign *= sign

proc checkCase(count: int, terms: seq[tuple[coefficient, input: int]], pairs: array[4, PairSpec]) =
  var coefficients = newSeq[SymbolicPoint](count+1)
  var inputs = newSeq[SymbolicScalar](count)
  for i in 0..<coefficients.len: coefficients[i] = point(i)
  for i in 0..<count: inputs[i] = SymbolicScalar(index: i)
  var expected = point(0)
  for term in terms:
    expected.terms.add SymbolicTerm(point: term.coefficient, scalar: term.input, sign: 1)
  let leftSources = [point(-1), point(-2), expected, point(-3)]
  let rightSources = [SymbolicRight(index: 0), SymbolicRight(index: 1),
                      SymbolicRight(index: 2), SymbolicRight(index: 3)]
  for verdict in [true, false]:
    resetCalls()
    oracleVerdict = verdict
    let accepted = verifyEquationCore(point(-2), rightSources[1], rightSources[2], rightSources[3],
      coefficients, point(-1), rightSources[0], point(-3), inputs)
    require(accepted == verdict, "pairing verdict not preserved")
    require(addCalls == count and multiplyCalls == count and negateCalls == 1 and pairingCalls == 1,
      "verifier operation count")
    require(observedProducts == terms, "public input schedule differs from Lean")
    for i, pair in pairs:
      require(pair.left in 0..3 and pair.right in 0..3 and pair.sign in [-1, 1], "invalid reference pair")
      require(observedLeft[i] == signed(leftSources[pair.left], pair.sign), "pairing left point or sign")
      require(observedRight[i] == rightSources[pair.right], "pairing right point or order")
    require(coefficients[0] == point(0), "input coefficient mutated")

  resetCalls()
  var accumulated = point(-99)
  require(accumulatePublic(coefficients, inputs, accumulated), "valid accumulator rejected")
  require(accumulated == expected and addCalls == count and multiplyCalls == count,
    "standalone accumulator result")

  for size in [0, count, count+2]:
    resetCalls()
    let invalid = newSeq[SymbolicPoint](size)
    var unchanged = point(-99)
    require(not accumulatePublic(invalid, inputs, unchanged) and unchanged == point(-99),
      "mismatched accumulator changed output")
    require(not verifyEquationCore(point(-2), rightSources[1], rightSources[2], rightSources[3],
      invalid, point(-1), rightSources[0], point(-3), inputs), "invalid arity accepted")
    require(addCalls == 0 and multiplyCalls == 0 and negateCalls == 0 and pairingCalls == 0,
      "invalid arity reached group arithmetic")

proc checkRealGroups() =
  for count in [0, 1, 5, 7, 10, 12, 16, 32]:
    var coefficients = newSeq[Point1](count+1)
    var inputs = newSeq[Scalar](count)
    for i in 0..<coefficients.len: coefficients[i] = generator1().multiply(scalar(i*i+7))
    var expected = scalar(7)
    for i in 0..<count:
      inputs[i] = scalar(i*3+11)
      expected = expected + scalar((i+1)*(i+1)+7) * inputs[i]
    var actual: Point1
    require(accumulatePublic(coefficients, inputs, actual), "real-group accumulation failed")
    require(bool(actual == generator1().multiply(expected)), "real-group weighted sum")
  var zero: Point1
  require(accumulatePublic([generator1(), generator1().multiply(scalar(-1))], [scalar(1)], zero),
    "neutral accumulator rejected")
  require(bool(zero.isNeutral()), "neutral weighted sum")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_verifier_core EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let path = work / "schedule.txt"
  let generated = execCmdEx(quoteShell(exporter) & " " & quoteShell(path))
  require(generated.exitCode == 0, "schedule export failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKVERIFY1 33", "reference header")
  for count in 0..32:
    require(reference.readLine() == "CASE " & $count, "reference case order")
    var terms: seq[tuple[coefficient, input: int]]
    for _ in 0..<count:
      let row = reference.readLine().splitWhitespace()
      require(row.len == 3 and row[0] == "TERM", "reference term")
      terms.add (parseInt(row[1]), parseInt(row[2]))
    var pairs: array[4, PairSpec]
    for i in 0..<4:
      let row = reference.readLine().splitWhitespace()
      require(row.len == 4 and row[0] == "PAIR", "reference pairing")
      pairs[i] = (parseInt(row[1]), parseInt(row[2]), parseInt(row[3]))
    require(reference.readLine() == "END", "reference case end")
    checkCase(count, terms, pairs)
  require(reference.endOfFile(), "trailing reference data")
  checkRealGroups()
  echo "zkbuild verifier core: PASS (33 symbolic schedules, both pairing verdicts, arity rejection, 8 real-group sums and neutral case)"

main()
