import std/[os, osproc, strutils]
import cps/wasm/[types, static_typing, variable_typing, validate]
import cps/zk/[r1cs, prover, wasm_trace_check, wasm_type_environment, wasm_instruction_events]
import zkbuild_variable_test_modules
import zkbuild_variable_test_helpers, zkbuild_event_test_helpers, zkbuild_static_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc checkOracle(exporter, workDir: string): int =
  createDir(workDir)
  let path = absolutePath(workDir/"variable-rules.txt")
  let generated = execCmdEx(quoteShell(absolutePath(exporter)) & " " & quoteShell(path))
  require(generated.exitCode == 0, "variable rule oracle: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKVARIABLE1 1024 7 45", "variable oracle header")
  for code in 0..<1024:
    for declared in 0'u8..6'u8:
      let row = reference.readLine().splitWhitespace()
      require(row.len == 10 and parseInt(row[0]) == code and parseInt(row[1]) == int(declared),
        "variable oracle row")
      let rule = variableRuleForCode(uint16(code), declared)
      let expected = [ord(typeEnvironmentKind(uint16(code))), ord(rule.present),
        int(rule.inputCount), int(rule.outputCount), int(rule.outputType),
        int(rule.inputs[0]), int(rule.inputs[1]), int(rule.inputs[2])]
      for i, value in expected:
        require(value == parseInt(row[i+2]), "variable rule differs from Lean: " & $code & "/" & $declared)
      if rule.present: inc result
  require(result == 45 and reference.endOfFile(), "variable rule coverage")

proc main() =
  require(paramCount() == 2, "usage: test_variable_events EXPORTER WORK_DIR")
  let signatures = checkOracle(paramStr(1), paramStr(2))
  var cases, mutations = 0
  for code in [0x20'u16, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x10f, 0x110, 0x111]:
    for declared in 0'u8..6'u8:
      let rule = variableRuleForCode(code, declared)
      if not rule.present: continue
      for polymorphic in [false, true]:
        let module = moduleForVariable(code, declared, polymorphic)
        let events = traceModuleValidation(module)
        require(checkValidationTraceStructure(module, events).accepted, "variable replay " & $code)
        let rows = buildInstructionEventRows(events, 64)
        let primary = variableImmediates(module, rows)
        let environment = buildTypeEnvironment(module, 4, 4)
        require(buildTyped(rows, environment, primary).satisfied(), "typed variable trace " & $code & "/" & $declared)
        inc cases
        var changed = @rows
        for row in changed.mitems:
          if row.opcode == code and row.control.operand.kind in [uint8(ord(veOperandPop)), uint8(ord(veOperandPush))]:
            let expected = if row.control.operand.kind == uint8(ord(veOperandPush)): rule.outputType else: rule.inputs[0]
            row.control.operand.valueType = (expected+1) mod 7
            break
        if changed != rows:
          require(not buildTyped(changed, environment, primary).satisfied(), "variable type mutation")
          inc mutations
        var wrongIndex = @primary
        for i, row in rows:
          if row.opcode == code and row.control.operand.kind == uint8(ord(veInstructionBegin)):
            wrongIndex[i] = high(uint32)
        require(not buildTyped(rows, environment, wrongIndex).satisfied(), "out-of-range type lookup")

  # Result-type and immutable-global forgeries pass the old stack/signature
  # relation; the new environment-backed relation must reject both.
  let module = moduleForVariable(0x20, 1)
  var forged = traceModuleValidation(module)
  for event in forged.mitems:
    if event.kind in {veOperandPush, veOperandPop}: event.valueType = svI32
  let rows = buildInstructionEventRows(forged, 16)
  let primary = variableImmediates(module, rows)
  let environment = buildTypeEnvironment(module, 4, 4)
  require(build(rows, full = true).satisfied(), "type forgery should pass previous partial relation")
  require(not checkValidationTraceStructure(module, forged).accepted, "independent replay accepted local type forgery")
  require(not buildTyped(rows, environment, primary, full = true).satisfied(), "local declaration was not authenticated")

  let setter = moduleForVariable(0x24, 2)
  let setterRows = buildInstructionEventRows(traceModuleValidation(setter), 32)
  let setterImmediates = variableImmediates(setter, setterRows)
  var immutable = buildTypeEnvironment(setter, 4, 4)
  for entry in immutable.objects.mitems:
    if entry.active and entry.address == globalTypeAddress(1): entry.value -= 8
  require(build(setterRows, full = true).satisfied(), "immutable setter fixture should pass previous relation")
  require(not buildTyped(setterRows, immutable, setterImmediates, full = true).satisfied(), "immutable global write")

  let polymorphicSetter = moduleForVariable(0x21, 2, true)
  let setterEnvironment = buildTypeEnvironment(polymorphicSetter, 4, 4)
  let setterEvents = traceModuleValidation(polymorphicSetter)
  var popPosition = -1
  for i, event in setterEvents:
    if event.opcode == opLocalSet and event.kind == veOperandPop: popPosition = i
  require(popPosition >= 0 and setterEvents[popPosition].polymorphic, "virtual variable-pop fixture")
  for omit in [false, true]:
    var changed = @setterEvents
    if omit: changed.delete(popPosition)
    else: changed.insert(setterEvents[popPosition], popPosition)
    let changedRows = buildInstructionEventRows(changed, 32)
    require(build(changedRows, full = true).satisfied(), "variable arity forgery should pass previous relation")
    require(not checkValidationTraceStructure(polymorphicSetter, changed).accepted, "replay accepted variable arity forgery")
    require(not buildTyped(changedRows, setterEnvironment, variableImmediates(polymorphicSetter, changedRows),
      full = true).satisfied(), "variable virtual-pop count forgery")

  # Namespace keys retain all 32 bits of both function and local indices.
  var imported = module
  imported.imports.insert(Import(kind: ikFunc, module: "host", name: "call", funcTypeIdx: 0), 0)
  let importedRows = buildInstructionEventRows(traceModuleValidation(imported), 16)
  let importedEnvironment = buildTypeEnvironment(imported, 4, 4)
  let importedImmediates = variableImmediates(imported, importedRows, 1)
  require(buildTyped(importedRows, importedEnvironment, importedImmediates, 1, full = true).satisfied(), "imported function namespace")
  var wrongNamespace = @importedRows
  for row in wrongNamespace.mitems:
    if row.control.operand.kind != 15: row.control.operand.functionIndex = 0
  require(not buildTyped(wrongNamespace, importedEnvironment, importedImmediates, full = true).satisfied(), "type namespace substitution")
  require(localTypeAddress(high(uint32), high(uint32)) == high(uint64), "full-width local key")
  require(globalTypeAddress(high(uint32)) != tableTypeAddress(high(uint32)), "object category key")

  let validRows = buildInstructionEventRows(traceModuleValidation(module), 16)
  let circuit = buildTyped(validRows, environment, primary, full = true)
  require(circuit.satisfied(), "composed variable proof circuit")
  for code in [0x21'u16, 0x22, 0x23, 0x24, 0x25, 0x26, 0x10f, 0x110, 0x111]:
    let other = moduleForVariable(code, 6)
    let otherRows = buildInstructionEventRows(traceModuleValidation(other), 64)
    require(buildTyped(otherRows, buildTypeEnvironment(other, 4, 4), variableImmediates(other, otherRows),
      full = true).satisfied(), "authenticated variable composition " & $code)
  var unknown = environment
  unknown.locals = @(environment.locals)
  for entry in unknown.locals.mitems:
    if entry.active: entry.value = 7
  require(not buildTyped(validRows, unknown, primary).satisfied(), "unknown declared local type")
  var invalidUnused = environment
  invalidUnused.objects = @(environment.objects)
  invalidUnused.objects[0].value = 7
  require(not buildTyped(validRows, invalidUnused, primary).satisfied(), "unknown unused global declaration")
  invalidUnused.objects[0].value = environment.objects[0].value
  invalidUnused.objects[1].value = 0
  require(not buildTyped(validRows, invalidUnused, primary).satisfied(), "nonreference unused table declaration")
  let tableModule = moduleForVariable(0x25, 5)
  let tableRows = buildInstructionEventRows(traceModuleValidation(tableModule), 32)
  var invalidTableType = buildTypeEnvironment(tableModule, 4, 4)
  for entry in invalidTableType.objects.mitems:
    if entry.active and entry.address == tableTypeAddress(1): entry.value = 0
  require(not buildTyped(tableRows, invalidTableType, variableImmediates(tableModule, tableRows)).satisfied(),
    "nonreference table declaration")
  var noncanonical = @primary
  noncanonical[0] = 1
  require(not buildTyped(validRows, environment, noncanonical).satisfied(), "immediate outside instruction begin")

  let secondModule = moduleForVariable(0x20, 6)
  let secondRows = buildInstructionEventRows(traceModuleValidation(secondModule), 16)
  let second = buildTyped(secondRows, buildTypeEnvironment(secondModule, 4, 4), variableImmediates(secondModule, secondRows), full = true)
  require(circuit.sameShape(second), "type-dependent circuit shape")
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "variable proof")
  let secondProof = encodeProof(prove(key, second))
  require(decodeAndVerify(key.verificationKey, secondProof, second.values[1..second.publicCount]), "variable proof key reuse")
  for i in [3, 4, circuit.publicCount]:
    var publicInputs = circuit.values[1..circuit.publicCount]
    publicInputs[i-1] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, publicInputs), "variable proof substitution")
  echo "zkbuild variable events: PASS (", signatures, " Lean signatures; ", cases,
    " concrete/polymorphic transcripts; ", mutations, " type mutations; 10 authenticated compositions; ",
    circuit.constraints.len, " constraints/16 rows; two 192-byte proofs)"

main()
