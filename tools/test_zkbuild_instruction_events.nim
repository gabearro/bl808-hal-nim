import cps/wasm/[types, validate, numeric_typing]
import zkbuild_event_test_helpers
import cps/zk/[r1cs, prover, memory_consistency, wasm_operand_events, wasm_control_events,
  wasm_instruction_events]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc numericModule(code: uint16, polymorphic = false): WasmModule =
  let rule = numericRuleForCode(code)
  var params: seq[ValType]
  var instructions: seq[Instr]
  if polymorphic:
    instructions.add Instr(op: opUnreachable)
  else:
    for i in 0..<int(rule.inputCount):
      params.add rule.inputType
      instructions.add Instr(op: opLocalGet, imm1: uint32(i))
  instructions.add Instr(op: Opcode(code))
  result = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: params, results: @[rule.outputType])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: instructions))])


proc main() =
  var cases = 0
  let shape = build(buildInstructionEventRows(traceModuleValidation(numericModule(0x41)), 64))
  for code in 0..0x107:
    let rule = numericRuleForCode(uint16(code))
    if not rule.present: continue
    for polymorphic in [false, true]:
      let rows = buildInstructionEventRows(traceModuleValidation(numericModule(uint16(code), polymorphic)), 64)
      let circuit = build(rows)
      require(circuit.satisfied(), "numeric instruction transcript " & $code)
      require(circuit.sameShape(shape), "witness-dependent instruction circuit")
      inc cases
      # Change the typed result and its later read coherently. This would
      # preserve LIFO memory, but contradicts the instruction's output type.
      var changed = @rows
      let output = uint8((127-ord(rule.outputType)+1) mod 4)
      for row in changed.mitems:
        if row.opcode == uint16(code) and row.control.operand.kind == uint8(ord(veOperandPush)):
          row.control.operand.valueType = output
        elif row.opcode == uint16(ord(opEnd)) and row.control.operand.kind == uint8(ord(veOperandPop)):
          row.control.operand.valueType = output
      require(not build(changed).satisfied(), "numeric output type forgery " & $code)
      if not polymorphic and rule.inputCount > 0:
        var changedInput = @rows
        let input = uint8((127-ord(rule.inputType)+1) mod 4)
        for row in changedInput.mitems:
          if (row.opcode == uint16(ord(opLocalGet)) and row.control.operand.kind == uint8(ord(veOperandPush))) or
              (row.opcode == uint16(code) and row.control.operand.kind == uint8(ord(veOperandPop))):
            row.control.operand.valueType = input
        require(not build(changedInput).satisfied(), "numeric input type forgery " & $code)

  require(cases == 280, "numeric instruction coverage")
  let trace = traceModuleValidation(numericModule(0x6a, true))
  let rows = buildInstructionEventRows(trace, 32)
  require(build(rows, full = true).satisfied(), "authenticated polymorphic arithmetic")
  var coherentOutput = @rows
  for row in coherentOutput.mitems:
    if row.control.operand.kind == uint8(ord(veOperandPush)) or
        (row.opcode == uint16(ord(opEnd)) and row.control.operand.kind == uint8(ord(veOperandPop))):
      row.control.operand.valueType = uint8(ord(svI64))
  require(build(coherentOutput, full = true, instruction = false).satisfied(), "output forgery should pass stack-only relation")
  require(not build(coherentOutput, full = true).satisfied(), "output forgery escaped numeric lookup")

  var extra = @trace
  var missing = @trace
  var found = -1
  for i, event in trace:
    if event.opcode == opI32Add and event.kind == veOperandPop:
      found = i
      break
  require(found >= 0, "virtual pop fixture")
  extra.insert(trace[found], found)
  missing.delete(found)
  for changed in [extra, missing]:
    let mutated = buildInstructionEventRows(changed, 32)
    require(build(mutated, full = true, instruction = false).satisfied(), "arity forgery should pass stack-only relation")
    require(not build(mutated, full = true).satisfied(), "numeric arity forgery accepted")

  var hiddenControl = @trace
  var start = -1
  for i, event in trace:
    if event.opcode == opI32Add and event.kind == veInstructionBegin:
      start = i
      break
  require(start >= 0, "numeric body fixture")
  let pc = trace[start].instructionIndex
  hiddenControl.insert(ValidationEvent(kind: veControlPush, functionIndex: 0, instructionIndex: pc,
    opcode: opI32Add, operandHeight: 0, controlHeight: 2, valueType: svUnknown,
    frameOpcode: opBlock), start+1)
  hiddenControl.insert(ValidationEvent(kind: veControlPop, functionIndex: 0, instructionIndex: pc,
    opcode: opI32Add, operandHeight: 0, controlHeight: 1, valueType: svUnknown,
    frameOpcode: opBlock), start+2)
  let controlForgery = buildInstructionEventRows(hiddenControl, 32)
  require(build(controlForgery, full = true, instruction = false).satisfied(),
    "hidden-control forgery should pass stack-only relation")
  require(not build(controlForgery, full = true).satisfied(), "control events hidden inside numeric body")

  var wrongPc = @rows
  var wrongOpcode = @rows
  var wrongOrder = @rows
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veInstructionBegin)):
      wrongPc[i].pc += 1
      wrongOrder[i].control.operand.kind = uint8(ord(veInstructionEnd))
      break
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veOperandPop)) and row.opcode == uint16(ord(opI32Add)):
      wrongOpcode[i].opcode = uint16(ord(opI32Sub))
      break
  for changed in [wrongPc, wrongOpcode, wrongOrder]:
    require(not build(changed).satisfied(), "instruction schedule forgery accepted")
  var missingRoot = @rows
  missingRoot[1].control.operand.kind = uint8(ord(veInstructionEnd))
  require(not build(missingRoot).satisfied(), "missing initial control frame")
  var padOpcode = @rows
  padOpcode[^1].opcode = uint16(ord(opI32Const))
  require(not build(padOpcode).satisfied(), "noncanonical padding opcode")
  var padPc = @rows
  padPc[^1].pc = 1
  require(not build(padPc).satisfied(), "noncanonical padding program counter")

  var twoFunctions = numericModule(0x41)
  twoFunctions.funcTypeIdxs.add 0'u32
  twoFunctions.codes.add FuncBody(code: Expr(code: @[
    Instr(op: opI32Const, imm1: 2), Instr(op: opI32Const, imm1: 3), Instr(op: opI32Add)]))
  let twoFunctionRows = buildInstructionEventRows(traceModuleValidation(twoFunctions), 64)
  require(build(twoFunctionRows, full = true).satisfied(), "program counter resets between function bodies")

  let concrete = buildInstructionEventRows(traceModuleValidation(numericModule(0x41)), 16)
  let circuit = build(concrete, full = true)
  require(circuit.satisfied(), "composed numeric validation trace")
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(decodeAndVerify(key.verificationKey, proof,
    circuit.values[1..circuit.publicCount]), "numeric trace Groth16 proof")
  var changedPublic = circuit.values[1..circuit.publicCount]
  changedPublic[9] += scalar(1) # first row opcode
  require(not decodeAndVerify(key.verificationKey, proof, changedPublic), "numeric trace public substitution")
  echo "zkbuild instruction events: PASS (", cases, " numeric transcripts; coherent type/arity and",
    " schedule forgeries rejected; ", circuit.constraints.len, " constraints/16 rows; QAP ",
    key.domainSize, "; ", proof.len, "-byte proof)"

main()
