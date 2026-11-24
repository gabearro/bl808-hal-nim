import std/[os, osproc, strutils]
import cps/wasm/[types, validate, call_typing, variable_typing]
import cps/zk/[r1cs, prover, read_only_memory, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_trace_check]
import zkbuild_call_test_helpers, zkbuild_variable_test_helpers, zkbuild_static_test_modules, zkbuild_call_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)


proc immediates(module: WasmModule, rows: openArray[InstructionEventRow]): tuple[p, s: seq[uint32]] =
  result.p.setLen(rows.len)
  result.s.setLen(rows.len)
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veInstructionBegin)) and int(row.pc) < module.codes[0].code.code.len:
      let instruction = module.codes[0].code.code[int(row.pc)]
      result.p[i] = instruction.imm1
      result.s[i] = instruction.imm2

proc testTrace(code: uint16, params, results: seq[ValType], polymorphic: bool, capacity: int,
    full = false): Circuit =
  let module = moduleForCall(code, params, results, polymorphic)
  let events = traceModuleValidation(module)
  require(checkValidationTraceStructure(module, events).accepted, "independent call replay")
  let rows = buildInstructionEventRows(events, capacity)
  let immediate = immediates(module, rows)
  let environment = buildTypeEnvironment(module, max(1, params.len+1), 2)
  let signatures = buildSignatureEnvironment(module, 4, max(4, 2*params.len+2*results.len+1))
  result = buildCalls(rows, environment, signatures, immediate.p, immediate.s, full = full)
  require(result.satisfied(), "call trace " & $code & "/" & $params.len & "/" & $results.len & "/" & $polymorphic)

proc checkOracle(exporter, workDir: string): int =
  createDir(workDir)
  let path = absolutePath(workDir/"call-rules.txt")
  let generated = execCmdEx(quoteShell(absolutePath(exporter)) & " " & quoteShell(path))
  require(generated.exitCode == 0, "call oracle: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKCALL1 6048", "call oracle header")
  while not reference.endOfFile():
    let fields = reference.readLine().splitWhitespace()
    require(fields.len >= 9, "call oracle row")
    let code = uint16(parseInt(fields[0]))
    let p = parseInt(fields[1])
    let r = parseInt(fields[2])
    let seed = parseInt(fields[3])
    var params, results: seq[ValType]
    for i in 0..<p: params.add ValueTypes[(i+seed) mod 7]
    for i in 0..<r: results.add ValueTypes[(3*i+seed+1) mod 7]
    var module = moduleForCall(code, params, results)
    if parseInt(fields[4]) != 0: module.types[1].results = (if results.len == 0: @[vtI32] else: @[])
    module.tables[0].elemType = ValueTypes[parseInt(fields[5])]
    let rule = callRule(module, 0, module.codes[0].code.code[^1])
    require(rule.present == (parseInt(fields[6]) == 1), "call oracle acceptance")
    if rule.present:
      require(rule.inputs.len == parseInt(fields[7]) and rule.outputs.len == parseInt(fields[8]), "call oracle arity")
      require(fields.len == 9+rule.inputs.len+rule.outputs.len, "call oracle payload length")
      for i, tag in rule.inputs: require(int(tag) == parseInt(fields[9+i]), "call oracle parameter order")
      for i, tag in rule.outputs: require(int(tag) == parseInt(fields[9+rule.inputs.len+i]), "call oracle result order")
    inc result
  require(result == 6048, "call oracle coverage")

proc checkInterning(): int =
  var signatures: seq[FuncType]
  var lengthStart = 0
  var count = 1
  signatures.add FuncType()
  for length in 1..4:
    let previousStart = lengthStart
    lengthStart = signatures.len
    for i in 0..<count:
      for tag in ValueTypes:
        var values = signatures[previousStart+i].params
        values.add tag
        signatures.add FuncType(params: values)
    count *= 7
  let module = WasmModule(startFunc: -1, dataCount: -1, types: signatures)
  let environment = buildSignatureEnvironment(module)
  require(environment.signatures.len == 2801 and environment.nodes.len == 2800, "type-list interning size")
  for i, entry in environment.signatures:
    require(entry.address == typeSignatureAddress(uint32(i)) and entry.value shr 32 == 0, "type-list metadata")
    var id = entry.value and 0xffffffff'u64
    var position = signatures[i].params.len
    while id != 0:
      require(id <= uint64(environment.nodes.len) and position > 0, "type-list bounds")
      let node = environment.nodes[int(id)-1]
      dec position
      require(node.address == id and node.value shr 3 < id and
        (node.value and 7) == uint64(stackTypeTag(signatures[i].params[position])), "type-list representation")
      id = node.value shr 3
    require(position == 0, "type-list terminated early")
    inc result

proc main() =
  require(paramCount() == 2, "usage: test_call_events EXPORTER WORK_DIR")
  let oracleCases = checkOracle(paramStr(1), paramStr(2))
  let internCases = checkInterning()
  var cases, mutations = 0
  for code in [0x10'u16, 0x11, 0x12, 0x13]:
    for tag in 0..<7:
      let params = @[ValueTypes[tag], ValueTypes[(tag+2) mod 7]]
      let results = @[ValueTypes[(tag+4) mod 7], ValueTypes[(tag+1) mod 7]]
      for polymorphic in [false, true]:
        discard testTrace(code, params, results, polymorphic, 64)
        inc cases
    discard testTrace(code, @[], @[], false, 16, full = true)
    discard testTrace(code, @[vtI64, vtFuncRef, vtV128], @[vtExternRef, vtF64], false, 64, full = true)
    inc cases, 2
  var manyParams, manyResults: seq[ValType]
  for i in 0..<17: manyParams.add ValueTypes[i mod 7]
  for i in 0..<5: manyResults.add ValueTypes[(6-i) mod 7]
  discard testTrace(0x10, manyParams, manyResults, false, 128)
  discard testTrace(0x13, manyParams, manyResults, true, 64)
  cases += 2

  # These coherent transcripts satisfy the preceding partial relation.
  # Both synthetic argument counts and exact tail clear counts are now bound.
  for code in [0x10'u16, 0x11, 0x12, 0x13]:
    let module = moduleForCall(code, @[vtI64], @[vtF64], true)
    let original = traceModuleValidation(module)
    let environment = buildTypeEnvironment(module, 2, 2)
    let signatures = buildSignatureEnvironment(module, 4, 8)
    var argument = -1
    for i, event in original:
      if uint16(ord(event.opcode)) == code and event.kind == veOperandPop: argument = i
    require(argument >= 0 and original[argument].polymorphic, "call arity fixture")
    for omit in [false, true]:
      var changed = @original
      if omit: changed.delete(argument)
      else: changed.insert(original[argument], argument)
      let rows = buildInstructionEventRows(changed, 32)
      let immediate = immediates(module, rows)
      require(buildTyped(rows, environment, immediate.p, 1, full = true).satisfied(), "call arity should pass previous partial relation")
      require(not buildCalls(rows, environment, signatures, immediate.p, immediate.s, full = true).satisfied(), "call arity forgery")
      require(not checkValidationTraceStructure(module, changed).accepted, "call replay arity forgery")
      inc mutations
    if code >= 0x12:
      var clear = -1
      for i, event in original:
        if uint16(ord(event.opcode)) == code and event.kind == veUnreachable: clear = i
      require(clear >= 0, "tail clear fixture")
      for omit in [false, true]:
        var changed = @original
        if omit: changed.delete(clear)
        else: changed.insert(original[clear], clear)
        let rows = buildInstructionEventRows(changed, 32)
        let immediate = immediates(module, rows)
        require(buildTyped(rows, environment, immediate.p, 1, full = true).satisfied(), "tail clear should pass previous relation")
        require(not buildCalls(rows, environment, signatures, immediate.p, immediate.s, full = true).satisfied(), "tail clear count forgery")
        inc mutations

  let module = moduleForCall(0x10, @[], @[vtI64])
  let original = traceModuleValidation(module)
  let environment = buildTypeEnvironment(module, 1, 2)
  let signatures = buildSignatureEnvironment(module, 4, 4)
  var changed = @original
  for event in changed.mitems:
    if event.kind in {veOperandPush, veOperandPop}: event.valueType = svI32
  let rows = buildInstructionEventRows(changed, 16)
  let immediate = immediates(module, rows)
  require(buildTyped(rows, environment, immediate.p, 1, full = true).satisfied(), "call result fixture should pass previous relation")
  require(not buildCalls(rows, environment, signatures, immediate.p, immediate.s, full = true).satisfied(), "coherent call result forgery")
  require(not checkValidationTraceStructure(module, changed).accepted, "replay accepted call result forgery")
  inc mutations

  let empty = moduleForCall(0x10, @[], @[])
  var extraResult = traceModuleValidation(empty)
  var callEnd = -1
  for i, event in extraResult:
    if event.opcode == opCall and event.kind == veInstructionEnd: callEnd = i
  require(callEnd >= 0, "void call fixture")
  extraResult[callEnd].operandHeight = 1
  for event in extraResult.mitems:
    if event.opcode == opEnd and event.kind == veInstructionBegin: event.operandHeight = 1
  extraResult.insert(ValidationEvent(kind: veOperandPush, functionIndex: 1, opcode: opCall,
    instructionIndex: 0, operandHeight: 1, controlHeight: 1, valueType: svI32), callEnd)
  var finalPop = -1
  for i, event in extraResult:
    if event.opcode == opEnd and event.kind == veControlPop: finalPop = i
  require(finalPop >= 0, "void call final frame")
  extraResult.insert(ValidationEvent(kind: veOperandPop, functionIndex: 1, opcode: opEnd,
    instructionIndex: 1, operandHeight: 0, controlHeight: 1, valueType: svI32), finalPop)
  let extraRows = buildInstructionEventRows(extraResult, 16)
  let extraImmediate = immediates(empty, extraRows)
  let emptyEnvironment = buildTypeEnvironment(empty, 1, 2)
  require(buildTyped(extraRows, emptyEnvironment, extraImmediate.p, 1, full = true).satisfied(), "extra call result should pass previous relation")
  require(not buildCalls(extraRows, emptyEnvironment, buildSignatureEnvironment(empty, 4, 4),
    extraImmediate.p, extraImmediate.s, full = true).satisfied(), "void call fabricated a result")
  inc mutations

  let twoResults = moduleForCall(0x10, @[], @[vtI64, vtI32])
  let shortRows = buildInstructionEventRows(original, 16)
  let shortImmediate = immediates(twoResults, shortRows)
  require(buildTyped(shortRows, environment, shortImmediate.p, 1, full = true).satisfied(), "missing result should pass previous relation")
  require(not buildCalls(shortRows, environment, buildSignatureEnvironment(twoResults, 4, 8),
    shortImmediate.p, shortImmediate.s, full = true).satisfied(), "call omitted a declared result")
  inc mutations
  var invalidFunction = @(immediate.p)
  for i, row in rows:
    if row.opcode == 0x10 and row.control.operand.kind == uint8(ord(veInstructionBegin)): invalidFunction[i] = high(uint32)
  require(not buildCalls(rows, environment, signatures, invalidFunction, immediate.s).satisfied(), "out-of-range function lookup")
  inc mutations

  # Tail result equality is structural: distinct type indices with equal result
  # lists share a head, while unequal lists cannot be substituted.
  for code in [0x12'u16, 0x13]:
    let tailModule = moduleForCall(code, @[vtI32], @[vtI64], true)
    let events = traceModuleValidation(tailModule)
    let tailRows = buildInstructionEventRows(events, 32)
    let im = immediates(tailModule, tailRows)
    let env = buildTypeEnvironment(tailModule, 2, 2)
    var badModule = tailModule
    badModule.types[0].results = @[vtF64]
    let bad = buildSignatureEnvironment(badModule, 4, 8)
    require(not buildCalls(tailRows, env, bad, im.p, im.s).satisfied(), "tail result mismatch")
    require(not callRule(badModule, 0, badModule.codes[0].code.code[^1]).present, "tail resolver result mismatch")
    var originForgery = bad
    originForgery.signatures = @(bad.signatures)
    var rootResults: uint64
    for entry in bad.signatures:
      if entry.active and entry.address == functionSignatureAddress(1): rootResults = entry.value shr 32
    for entry in originForgery.signatures.mitems:
      if entry.active and entry.address == functionSignatureAddress(0):
        entry.value = (entry.value and 0xffffffff'u64)+(rootResults shl 32)
    require(not buildCalls(tailRows, env, originForgery, im.p, im.s).satisfied(), "function/type metadata origin forgery")
    mutations += 2

  let indirect = moduleForCall(0x11, @[vtI64], @[vtF32], true)
  let indirectRows = buildInstructionEventRows(traceModuleValidation(indirect), 32)
  let im = immediates(indirect, indirectRows)
  let indirectEnv = buildTypeEnvironment(indirect, 2, 2)
  let indirectSignatures = buildSignatureEnvironment(indirect, 4, 8)
  for typeIndex in [false, true]:
    var p = @(im.p)
    var s = @(im.s)
    for i, row in indirectRows:
      if row.opcode == 0x11 and row.control.operand.kind == uint8(ord(veInstructionBegin)):
        if typeIndex: p[i] = high(uint32)
        else: s[i] = high(uint32)
    require(not buildCalls(indirectRows, indirectEnv, indirectSignatures, p, s).satisfied(), "indirect lookup bounds")
    inc mutations
  var wrongTable = @(im.s)
  for i, row in indirectRows:
    if row.opcode == 0x11 and row.control.operand.kind == uint8(ord(veInstructionBegin)): wrongTable[i] = 0
  require(not buildCalls(indirectRows, indirectEnv, indirectSignatures, im.p, wrongTable).satisfied(), "externref indirect table")
  inc mutations

  let validRows = buildInstructionEventRows(original, 16)
  let validImmediate = immediates(module, validRows)
  let circuit = buildCalls(validRows, environment, signatures, validImmediate.p, validImmediate.s, full = true)
  require(circuit.satisfied(), "call proof circuit")
  # Invalid unused nodes/signatures must fail even if no operand visits them.
  var invalidNodes = signatures
  invalidNodes.nodes = @(signatures.nodes)
  for cycle in [false, true]:
    invalidNodes.nodes[1] = ReadOnlyEntry(active: true, address: 2,
      value: (if cycle: 2'u64 shl 3 else: 7'u64))
    require(not buildCalls(validRows, environment, invalidNodes, validImmediate.p, validImmediate.s).satisfied(), "invalid unused signature node")
    inc mutations
  var missing = buildSignatureEnvironment(module, 8, 4)
  missing.signatures[4] = ReadOnlyEntry(active: true, address: typeSignatureAddress(2), value: high(uint32).uint64)
  require(not buildCalls(validRows, environment, missing, validImmediate.p, validImmediate.s).satisfied(), "uninitialized unused signature head")
  inc mutations

  let other = moduleForCall(0x10, @[], @[vtExternRef])
  let otherRows = buildInstructionEventRows(traceModuleValidation(other), 16)
  let otherImmediate = immediates(other, otherRows)
  let second = buildCalls(otherRows, buildTypeEnvironment(other, 1, 2), buildSignatureEnvironment(other, 4, 4),
    otherImmediate.p, otherImmediate.s, full = true)
  require(second.satisfied() and circuit.sameShape(second), "call proof shape depends on type")
  let differentArity = moduleForCall(0x10, @[vtI32], @[])
  let differentRows = buildInstructionEventRows(traceModuleValidation(differentArity), 16)
  let differentImmediate = immediates(differentArity, differentRows)
  let differentCircuit = buildCalls(differentRows, buildTypeEnvironment(differentArity, 1, 2),
    buildSignatureEnvironment(differentArity, 4, 4), differentImmediate.p, differentImmediate.s, full = true)
  require(differentCircuit.satisfied() and circuit.sameShape(differentCircuit), "call proof shape depends on arity")
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "call proof")
  let secondProof = encodeProof(prove(key, second))
  require(decodeAndVerify(key.verificationKey, secondProof, second.values[1..second.publicCount]), "call proof key reuse")
  var publicInputs = circuit.values[1..circuit.publicCount]
  publicInputs[^1] += scalar(1)
  require(not decodeAndVerify(key.verificationKey, proof, publicInputs), "call proof substitution")
  echo "zkbuild call events: PASS (", oracleCases, " Lean signature cases; ", internCases,
    " exhaustive interned lists; ", cases, " normal/tail direct/indirect traces; ", mutations,
    " coherent or environment forgeries rejected; variable arities through 17/5; ",
    circuit.constraints.len, " constraints/16 rows; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
