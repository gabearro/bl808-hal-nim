import cps/zk/[r1cs, range_check]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc simple(value: Scalar, width: int, reuse: bool): Circuit =
  result = initCircuit(reuseRangeWitnesses = reuse)
  let input = result.publicInput(value)
  discard result.constrainUnsigned(input, width)
  discard result.constrainUnsigned(input, width)

proc sameBits(a, b: seq[Linear]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i].len != b[i].len: return false
    for j in 0..<a[i].len:
      if a[i][j].wire != b[i][j].wire or not a[i][j].coefficient.equals(b[i][j].coefficient): return false
  true

proc main() =
  var cases = 0
  for width in [0, 1, 3, 8, 16, 32, 64, 128, 248]:
    let limit = scalar(2).power(uint64(width))
    let shape = simple(scalar(0), width, true)
    for value in [scalar(0), limit-scalar(1), limit, scalar(-1), scalar(2).power(200)]:
      let reused = simple(value, width, true)
      let separate = simple(value, width, false)
      require(reused.satisfied() == separate.satisfied(), "range reuse changed validity")
      require(reused.sameShape(shape), "value-dependent range reuse matrix")
      require(reused.constraints.len == width+1 and separate.constraints.len == 2*(width+1), "range reuse constraint count")
      inc cases
  for firstWidth in [8, 9]:
    var circuit = initCircuit(reuseRangeWitnesses = true)
    let input = circuit.publicInput(scalar(256))
    discard circuit.constrainUnsigned(input, firstWidth)
    discard circuit.constrainUnsigned(input, if firstWidth == 8: 9 else: 8)
    require(not circuit.satisfied(), "range width alias")
  var scaled = initCircuit(reuseRangeWitnesses = true)
  let large = scaled.publicInput(scalar(128))
  discard scaled.constrainUnsigned(large, 8)
  discard scaled.constrainUnsigned(large.scale(scalar(2)), 8)
  require(not scaled.satisfied(), "scaled expression reused a unit-wire range")
  var offset = initCircuit(reuseRangeWitnesses = true)
  let last = offset.publicInput(scalar(255))
  discard offset.constrainUnsigned(last, 8)
  discard offset.constrainUnsigned(last+constant(1), 8)
  require(not offset.satisfied(), "offset expression reused a unit-wire range")
  var aliases = initCircuit(reuseRangeWitnesses = true)
  let a = aliases.publicInput(scalar(3))
  let b = aliases.publicInput(scalar(3))
  let aBits = aliases.constrainUnsigned(a, 2)
  let bBits = aliases.constrainUnsigned(b, 2)
  require(not sameBits(aBits, bBits), "equal values aliased different wires")
  let before = aliases.constraints.len
  let again = aliases.constrainUnsigned(a, 2)
  require(sameBits(again, aBits) and aliases.constraints.len == before, "identical range certificate was not reused")
  var modified = aliases.constrainUnsigned(a, 2)
  modified[0][0].coefficient = scalar(0)
  when defined(zkbuildGadgetAudit):
    require(aliases.gadgets[^1].kind == gkReusedUnsigned and
      aliases.gadgets[^1].reference == 0, "audit lost the original range source")
    require(aliases.gadgets[^1].outputs[0][0].coefficient.equals(scalar(1)),
      "returned bit vector mutated the audit snapshot")
  require(sameBits(aliases.constrainUnsigned(a, 2), aBits), "returned bit vector mutated the cached certificate")
  aliases.values[a[0].wire] = scalar(4)
  discard aliases.constrainUnsigned(a, 2)
  require(not aliases.satisfied(), "cached bits accepted a changed out-of-range wire")
  var constants = initCircuit(reuseRangeWitnesses = true)
  let bits = constants.constrainUnsigned(constant(0), 1)
  let otherBits = constants.constrainUnsigned(constant(1), 1)
  require(not sameBits(bits, otherBits) and constants.satisfied() and constants.constraints.len == 0, "constant-wire alias/folding")
  for value in [scalar(256), scalar(-1)]:
    var invalidConstant = initCircuit(reuseRangeWitnesses = true)
    discard invalidConstant.constrainUnsigned(@[Term(wire: 0, coefficient: value)], 8)
    require(not invalidConstant.satisfied(), "out-of-range literal was folded as valid")
  var separate = initCircuit(reuseRangeWitnesses = true)
  let separateInput = separate.publicInput(scalar(0))
  discard separate.constrainUnsigned(separateInput, 1)
  require(separate.satisfied(), "range cache escaped its circuit")
  echo "zkbuild range reuse: PASS (", cases, " range/shape comparisons; width, coefficient, expression, constant, value, and circuit aliases rejected)"

main()
