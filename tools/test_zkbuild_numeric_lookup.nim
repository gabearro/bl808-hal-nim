import cps/zk/[r1cs, numeric_lookup]
import cps/wasm/numeric_typing

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc build(code: uint16, automatic = false): Circuit =
  result = initCircuit()
  let rule = numericRuleForCode(code)
  let op = result.publicInput(scalar(code))
  let present = result.publicInput(scalar(ord(rule.present)))
  let count = result.publicInput(scalar(if rule.present: int(rule.inputCount) else: 0))
  let input = result.publicInput(scalar(if rule.present: 127-ord(rule.inputType) else: 0))
  let output = result.publicInput(scalar(if rule.present: 127-ord(rule.outputType) else: 0))
  let actual = if automatic: result.constrainNumericRule(op) else: result.constrainNumericRule(op, code)
  result.assertEqual(actual.present, present)
  result.assertEqual(actual.inputCount, count)
  result.assertEqual(actual.inputType, input)
  result.assertEqual(actual.outputType, output)

proc main() =
  let reference = build(0)
  require(reference.satisfied(), "invalid-code lookup")
  var cases = 0
  for code in 0..<1024:
    let circuit = build(uint16(code))
    require(circuit.satisfied(), "numeric lookup case " & $code)
    require(circuit.sameShape(reference), "witness-dependent lookup shape")
    let automatic = build(uint16(code), automatic = true)
    require(automatic.satisfied() and automatic.sameShape(circuit), "automatic opcode witness shape")
    for i in 0..<circuit.values.len:
      require(circuit.values[i].equals(automatic.values[i]), "automatic opcode witness differs")
    for wire in 1..5:
      var changed = build(uint16(code))
      changed.values[wire] = changed.values[wire] + scalar(1)
      require(not changed.satisfied(), "numeric lookup accepted changed public value")
    inc cases
  for code in [1024'u16, 0x1041, 0x8041, 65535]:
    let circuit = build(code)
    require(circuit.satisfied() and circuit.sameShape(reference), "high opcode aliases a numeric opcode")
    inc cases
  var nonBoolean = build(0x41)
  nonBoolean.values[6] = scalar(2)
  require(not nonBoolean.satisfied(), "non-Boolean opcode bit accepted")
  for value in [scalar(65536), scalar(65536+0x41), scalar(1'u64 shl 32), scalar(-1)]:
    var high = initCircuit()
    let opcode = high.publicInput(value)
    discard high.constrainNumericRule(opcode)
    require(not high.satisfied(), "automatic opcode witness aliased high field bits")
  echo "zkbuild numeric lookup: PASS (", cases, " opcodes; ", numericLookupBranches(),
    " shared branches; ", reference.constraints.len, " constraints; 5120 public mutations rejected)"

main()
