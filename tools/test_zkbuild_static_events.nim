import cps/wasm/[types, static_typing, validate]
import cps/zk/[r1cs, prover, wasm_control_events, wasm_instruction_events]
import zkbuild_event_test_helpers, zkbuild_static_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  var cases, mutations = 0
  for code in 0..<2048:
    let rule = staticRuleForCode(uint16(code))
    if not rule.present or (code in 0x41..0xc4) or (code in 0x100..0x107): continue
    for polymorphic in [false, true]:
      let rows = buildInstructionEventRows(traceModuleValidation(moduleForStaticRule(uint16(code), polymorphic)), 64)
      require(build(rows).satisfied(), "fixed opcode trace " & $code)
      inc cases
      if rule.inputCount > 0:
        var changed = @rows
        var position = 0
        for row in changed.mitems:
          if row.opcode == uint16(code) and row.control.operand.kind == uint8(ord(veOperandPop)):
            var bad = -1
            for actual in 0..6:
              if not staticPopMatches(rule, position, actual): bad = actual; break
            if bad >= 0:
              row.control.operand.valueType = uint8(bad)
              break
            inc position
        if changed != rows:
          require(not build(changed).satisfied(), "fixed input type forgery " & $code)
          inc mutations
      if rule.outputCount > 0:
        var changed = @rows
        for row in changed.mitems:
          if row.opcode == uint16(code) and row.control.operand.kind == uint8(ord(veOperandPush)):
            row.control.operand.valueType = (rule.outputType+1) mod 7
        require(not build(changed).satisfied(), "fixed output type forgery " & $code)
        inc mutations

  # Representative full compositions: heterogeneous stores/replacements,
  # three-input bulk operations, zero-output rules, and reference classes.
  for code in [0x00'u16, 0x01, 0x1a, 0x39, 0x108, 0xd1, 0xd2, 0x301, 0x31f, 0x332, 0x342]:
    let rows = buildInstructionEventRows(traceModuleValidation(moduleForStaticRule(code)), 64)
    require(build(rows, full = true).satisfied(), "authenticated fixed-rule trace " & $code)

  # A void store cannot smuggle a result even when its later read is added.
  var forgedStore = traceModuleValidation(moduleForStaticRule(0x39))
  var storeEnd = -1
  for i, e in forgedStore:
    if e.opcode == opF64Store and e.kind == veInstructionEnd: storeEnd = i
  require(storeEnd >= 0, "void store fixture")
  let storePc = forgedStore[storeEnd].instructionIndex
  forgedStore[storeEnd].operandHeight = 1
  for e in forgedStore.mitems:
    if e.opcode == opEnd and e.kind == veInstructionBegin: e.operandHeight = 1
  forgedStore.insert(ValidationEvent(kind: veOperandPush, opcode: opF64Store,
    instructionIndex: storePc, operandHeight: 1, controlHeight: 1, valueType: svI32), storeEnd)
  var finalPop = -1
  for i, e in forgedStore:
    if e.opcode == opEnd and e.kind == veControlPop: finalPop = i
  require(finalPop >= 0, "void store closing frame")
  forgedStore.insert(ValidationEvent(kind: veOperandPop, opcode: opEnd,
    instructionIndex: storePc+1, operandHeight: 0, controlHeight: 1, valueType: svI32), finalPop)
  let storeRows = buildInstructionEventRows(forgedStore, 64)
  require(build(storeRows, full = true, instruction = false).satisfied(), "store forgery should pass stack-only relation")
  require(not build(storeRows, full = true).satisfied(), "void store smuggled a result")

  var skippedClear = traceModuleValidation(moduleForStaticRule(0x00))
  var clear = -1
  for i, e in skippedClear:
    if e.kind == veUnreachable: clear = i; break
  require(clear >= 0, "unreachable fixture")
  skippedClear.delete(clear)
  let skippedRows = buildInstructionEventRows(skippedClear, 32)
  require(build(skippedRows, full = true, instruction = false).satisfied(), "missing-clear forgery should pass stack-only relation")
  require(not build(skippedRows, full = true).satisfied(), "unreachable omitted its state update")

  # Exercise the vector signature in a real composed Groth16 proof.
  let module = moduleForStaticRule(0x302)
  let rows = buildInstructionEventRows(traceModuleValidation(module), 16)
  let circuit = build(rows, full = true)
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "SIMD trace proof")
  echo "zkbuild fixed events: PASS (", cases, " additional opcode traces; ", mutations,
    " type mutations; 11 authenticated compositions; ", circuit.constraints.len,
    " constraints/16 rows; ", proof.len, "-byte SIMD proof)"

main()
