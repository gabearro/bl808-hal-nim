import cps/wasm/static_typing
import cps/zk/[r1cs, static_lookup]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

func expected(rule: StaticRule, index, actual: int): array[6, int] =
  if rule.present:
    [1, int(rule.inputCount), int(rule.outputCount), int(rule.outputType), int(rule.clearCount),
      ord(staticPopMatches(rule, index, actual))]
  else: [0, 0, 0, 0, 0, 0]

proc build(code: uint16, index, actual: uint8): Circuit =
  result = initCircuit()
  let values = expected(staticRuleForCode(code), int(index), int(actual))
  let op = result.publicInput(scalar(code))
  let slot = result.publicInput(scalar(index))
  let tag = result.publicInput(scalar(actual))
  var public: array[6, Linear]
  for i, value in values: public[i] = result.publicInput(scalar(value))
  let got = result.constrainStaticRule(op, slot, tag)
  result.assertEqual(got.inputIndex, slot)
  let outputs = [got.present, got.inputCount, got.outputCount, got.outputType, got.clearCount, got.allowedInput]
  for i in 0..<6: result.assertEqual(outputs[i], public[i])

proc main() =
  var seen: seq[StaticRule]
  var uniqueCodes: seq[uint16]
  var signatures, pureCases = 0
  for code in 0..65535:
    let rule = staticRuleForCode(uint16(code))
    if rule.present:
      inc signatures
      if rule notin seen:
        seen.add rule
        uniqueCodes.add uint16(code)
    for slot in 0..3:
      for tag in 0..7:
        require(lookupStaticRuleValue(uint16(code), uint8(slot), uint8(tag)) == expected(rule, slot, tag),
          "DAG signature or indexed input mismatch " & $code)
        inc pureCases
  let reference = build(0, 0, 7)
  require(reference.satisfied(), "unreachable signature")
  var matrixCases = 0
  for code in 0..<1024:
    var circuit = build(uint16(code), 0, 7)
    require(circuit.satisfied() and circuit.sameShape(reference), "static signature matrix")
    for wire in 1..9:
      let original = circuit.values[wire]
      circuit.values[wire] = original+scalar(1)
      require(not circuit.satisfied(), "changed lookup public field")
      circuit.values[wire] = original
    inc matrixCases
  for code in uniqueCodes:
    for slot in 0..3:
      for tag in 0..7:
        let circuit = build(code, uint8(slot), uint8(tag))
        require(circuit.satisfied() and circuit.sameShape(reference), "static rule input acceptance circuit")
        inc matrixCases
  for code in [1024'u16, 0x1041, 0x8342, 65535]:
    require(build(code, 0, 7).satisfied(), "undefined high opcode aliases a fixed rule")
    inc matrixCases
  for values in [[65536'u64, 0, 0], [0x41'u64, 4, 0], [0x41'u64, 0, 8]]:
    var circuit = initCircuit()
    let code = circuit.publicInput(scalar(values[0]))
    let slot = circuit.publicInput(scalar(values[1]))
    let tag = circuit.publicInput(scalar(values[2]))
    let got = circuit.constrainStaticRule(code, slot, tag)
    circuit.assertEqual(got.inputIndex, slot)
    require(not circuit.satisfied(), "high lookup argument aliases low bits")
  echo "zkbuild static lookup: PASS (", signatures, " signatures; ", pureCases,
    " exhaustive opcode/index/type queries; ", matrixCases, " R1CS cases; ",
    staticLookupBranches(), " shared branches; ", reference.constraints.len,
    " constraints; 9216 public mutations rejected)"

main()
