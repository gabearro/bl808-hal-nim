import std/[os, osproc, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures, wasm_signature_frames]
import zkbuild_control_type_test_helpers
import zkbuild_control_plan_test_helpers

const Values = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]
var planCases: seq[string]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc identity(opcode: Opcode, values: seq[ValType], otherwise = false, polymorphic = false): WasmModule =
  var code: seq[Instr]
  if polymorphic: code.add Instr(op: opUnreachable)
  else:
    for i in 0..<values.len: code.add Instr(op: opLocalGet, imm1: uint32(i))
    if opcode == opIf: code.add Instr(op: opI32Const)
  code.add Instr(op: opcode, pad: 0x101)
  if otherwise: code.add Instr(op: opElse)
  code.add Instr(op: opEnd)
  WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: values, results: values), FuncType(params: values, results: values)],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(code: Expr(code: code))])

proc check(module: WasmModule, full = false): Circuit =
  let events = traceModuleValidation(module)
  planCases.add controlPlanCases(module, events)
  let rows = buildInstructionEventRows(events)
  var firstFunction = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc firstFunction
  let im = instructionImmediates(module, rows, firstFunction)
  let env = buildTypeEnvironment(module)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(signatures)
  result = buildControlTypes(rows, env, signatures, indexed, im.p, im.s, im.pads,
    firstFunction = firstFunction, full = full)
  require(result.satisfied(), "structured-control trace")

proc mismatchCheck(module: WasmModule, rows: seq[InstructionEventRow],
    p, s: seq[uint32], pads: seq[uint64], message: string) =
  let env = buildTypeEnvironment(module)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(signatures)
  require(buildControlTypes(rows, env, signatures, indexed, p, s, pads, full = true, binding = false).satisfied(),
    message & " should pass preceding partial relation")
  require(not buildControlTypes(rows, env, signatures, indexed, p, s, pads).satisfied(), message)

proc checkPlans(exporter, workDir: string): int =
  createDir(workDir)
  let path = absolutePath(workDir/"control-plans.txt")
  writeFile(path, planCases.join("\n") & "\n")
  let command = quoteShell(absolutePath(exporter)) & " "
  let checked = execCmdEx(command & quoteShell(path))
  require(checked.exitCode == 0 and checked.output.strip == "ZKCONTROL1 " & $planCases.len & " " & $planCases.len,
    "independent Lean control plans: " & checked.output)
  let badPath = absolutePath(workDir/"bad-control-plans.txt")
  for mutation in 0..2:
    var changed = @planCases
    var fields = changed[0].splitWhitespace()
    let firstAction = 7+parseInt(fields[3])+parseInt(fields[4])+parseInt(fields[5])
    if mutation == 0:
      fields.delete(firstAction)
      fields[6] = $(parseInt(fields[6])-1)
    elif mutation == 1:
      var found = false
      for i in firstAction..<fields.len:
        let action = parseInt(fields[i])
        if action in 16..22:
          fields[i] = $(16+(action-16+1) mod 7)
          found = true
          break
      require(found, "control output mutation fixture")
    else:
      fields.add "32"
      fields[6] = $(parseInt(fields[6])+1)
    changed[0] = fields.join(" ")
    writeFile(badPath, changed.join("\n") & "\n")
    let rejected = execCmdEx(command & quoteShell(badPath))
    require(rejected.exitCode == 1, "Lean control checker accepted a malformed action plan")
  planCases.len

proc main() =
  require(paramCount() == 2, "usage: test_control_typing CHECKER WORK_DIR")
  var cases, forgeries = 0
  for opcode in [opBlock, opLoop, opIf]:
    for poly in [false, true]:
      discard check(identity(opcode, @[vtI64], polymorphic = poly))
      inc cases
  for poly in [false, true]:
    discard check(identity(opIf, @[vtFuncRef], otherwise = true, polymorphic = poly))
    inc cases
  for opcode in [opBlock, opLoop, opIf]:
    discard check(identity(opcode, @[]))
    inc cases
  discard check(identity(opIf, @[vtI32, vtI64, vtExternRef]))
  inc cases
  for tag, value in Values:
    let module = WasmModule(startFunc: -1, dataCount: -1,
      types: @[FuncType(params: @[value], results: @[value])], funcTypeIdxs: @[0'u32],
      codes: @[FuncBody(code: Expr(code: @[Instr(op: opBlock, pad: uint16(tag+1)),
        Instr(op: opLocalGet), Instr(op: opEnd)]))])
    discard check(module)
    inc cases

  for opcode in [opBlock, opLoop]:
    var module = identity(opcode, @[vtI32])
    module.codes[0].code.code.insert(Instr(op: opI32Const), 2)
    module.codes[0].code.code.insert(Instr(op: opBrIf), 3)
    discard check(module)
    inc cases
  var multiBranch = identity(opLoop, @[vtI32, vtI64])
  multiBranch.codes[0].code.code.insert(Instr(op: opBr), 3)
  discard check(multiBranch)
  inc cases
  var polyBranchIf = identity(opLoop, @[vtI32, vtI64])
  polyBranchIf.codes[0].code.code.insert(Instr(op: opUnreachable), 3)
  polyBranchIf.codes[0].code.code.insert(Instr(op: opBrIf), 4)
  discard check(polyBranchIf)
  inc cases
  let branch = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI64]), FuncType(params: @[vtI32], results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opBlock, pad: 2), Instr(op: opI32Const),
      Instr(op: opLoop, pad: 0x101), Instr(op: opBr), Instr(op: opEnd), Instr(op: opEnd)]))])
  discard check(branch, full = true)
  inc cases
  let returning = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtI64], results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opBlock), Instr(op: opLocalGet),
      Instr(op: opReturn), Instr(op: opEnd), Instr(op: opLocalGet)]))])
  discard check(returning, full = true)
  inc cases
  let explicitElse = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtF64], results: @[vtF64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opI32Const), Instr(op: opIf, pad: 4),
      Instr(op: opLocalGet), Instr(op: opElse), Instr(op: opLocalGet), Instr(op: opEnd)]))])
  discard check(explicitElse)
  inc cases
  let imported = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtI64], results: @[vtI64])],
    imports: @[Import(kind: ikFunc, module: "host", name: "callee", funcTypeIdx: 0)],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(code: Expr(code: @[Instr(op: opLocalGet)]))])
  discard check(imported, full = true)
  inc cases

  # The same coherent stack can be given a conflicting declared root result.
  let i32module = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI32])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opI32Const)]))])
  let i32rows = buildInstructionEventRows(traceModuleValidation(i32module), 16)
  let im = instructionImmediates(i32module, i32rows)
  var wrongRoot = i32module
  wrongRoot.types[0].results = @[vtI64]
  mismatchCheck(wrongRoot, i32rows, im.p, im.s, im.pads, "forged function result type")
  inc forgeries
  let blockModule = identity(opBlock, @[vtI64])
  let blockRows = buildInstructionEventRows(traceModuleValidation(blockModule))
  let blockIm = instructionImmediates(blockModule, blockRows)
  for pad in [0'u16, 1, 8, 255, 0x1ff]:
    var changed = @(blockIm.pads)
    for i, row in blockRows:
      if row.opcode == uint16(ord(opBlock)) and row.control.operand.kind == uint8(ord(veInstructionBegin)):
        changed[i] = pad
    mismatchCheck(blockModule, blockRows, blockIm.p, blockIm.s, changed, "forged or invalid block signature " & $pad)
    inc forgeries
  let branchRows = buildInstructionEventRows(traceModuleValidation(branch))
  let branchIm = instructionImmediates(branch, branchRows)
  var wrongDepth = @(branchIm.p)
  for i, row in branchRows:
    if row.opcode == uint16(ord(opBr)) and row.control.operand.kind == uint8(ord(veInstructionBegin)): wrongDepth[i] = 1
  mismatchCheck(branch, branchRows, wrongDepth, branchIm.s, branchIm.pads, "branch used wrong live target signature")
  inc forgeries
  wrongDepth = @(branchIm.p)
  for i, row in branchRows:
    if row.opcode == uint16(ord(opBr)) and row.control.operand.kind == uint8(ord(veInstructionBegin)): wrongDepth[i] = high(uint32)
  mismatchCheck(branch, branchRows, wrongDepth, branchIm.s, branchIm.pads, "invalid branch depth")
  inc forgeries
  var wrongReturn = @branchRows
  for row in wrongReturn.mitems:
    if row.opcode == uint16(ord(opBr)): row.opcode = uint16(ord(opReturn))
  mismatchCheck(branch, wrongReturn, branchIm.p, branchIm.s, branchIm.pads, "return used inner loop parameters")
  inc forgeries

  # A block with different inputs/results becomes an invalid if without else.
  # The extra condition is a valid virtual pop in the unreachable parent.
  let differing = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI64]), FuncType(params: @[vtI32], results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opUnreachable), Instr(op: opBlock, pad: 0x101),
      Instr(op: opDrop), Instr(op: opI64Const), Instr(op: opEnd)]))])
  var forgedIf = traceModuleValidation(differing)
  var begin = -1
  for i, event in forgedIf:
    if event.opcode == opBlock and event.kind == veInstructionBegin: begin = i
  require(begin >= 0, "implicit else fixture")
  let pc = forgedIf[begin].instructionIndex
  for event in forgedIf.mitems:
    if event.instructionIndex == pc and event.kind notin {veFunctionBegin, veFunctionEnd}: event.opcode = opIf
  forgedIf.insert(ValidationEvent(kind: veOperandPop, opcode: opIf, instructionIndex: pc,
    operandHeight: 0, controlHeight: 1, valueType: svUnknown, polymorphic: true), begin+1)
  let forgedRows = buildInstructionEventRows(forgedIf)
  let forgedIm = instructionImmediates(differing, forgedRows)
  mismatchCheck(differing, forgedRows, forgedIm.p, forgedIm.s, forgedIm.pads, "implicit else signature mismatch")
  inc forgeries

  let emptyBlock = identity(opBlock, @[])
  var skipped = traceModuleValidation(emptyBlock)
  var inside = false
  var cleaned: seq[ValidationEvent]
  var instructionOpen = false
  for event in skipped:
    if event.kind == veInstructionBegin: instructionOpen = true
    if instructionOpen and event.kind == veControlPush and event.opcode == opBlock:
      inside = true
      continue
    if inside and event.kind == veControlPop:
      inside = false
      continue
    var changed = event
    if inside: dec changed.controlHeight
    cleaned.add changed
    if event.kind == veInstructionEnd: instructionOpen = false
  let skippedRows = buildInstructionEventRows(cleaned)
  let skippedIm = instructionImmediates(emptyBlock, skippedRows)
  mismatchCheck(emptyBlock, skippedRows, skippedIm.p, skippedIm.s, skippedIm.pads, "empty block omitted its frame lifecycle")
  inc forgeries
  let polyRows = traceModuleValidation(polyBranchIf)
  var condition = -1
  for i, event in polyRows:
    if event.opcode == opBrIf and event.kind == veOperandPop:
      condition = i
      break
  require(condition >= 0 and polyRows[condition].polymorphic, "branch condition fixture")
  for omit in [false, true]:
    var changed = @polyRows
    if omit: changed.delete(condition)
    else: changed.insert(polyRows[condition], condition)
    let changedRows = buildInstructionEventRows(changed)
    let changedIm = instructionImmediates(polyBranchIf, changedRows)
    mismatchCheck(polyBranchIf, changedRows, changedIm.p, changedIm.s, changedIm.pads, "branch condition/label arity forgery")
    inc forgeries

  # Reuse one key with different scalar/reference signatures and the same
  # profile. This remains a public-event component proof, not byte admission.
  let module = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtI64], results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opLocalGet)]))])
  let rows = buildInstructionEventRows(traceModuleValidation(module), 16)
  let primary = instructionImmediates(module, rows)
  let signatures = buildSignatureEnvironment(module, 2, 8, includeSingletons = true)
  let indexed = buildIndexedSignatures(signatures, 8, 8)
  let circuit = buildControlTypes(rows, buildTypeEnvironment(module, 1, 1), signatures, indexed,
    primary.p, primary.s, primary.pads, full = true)
  require(circuit.satisfied(), "structured validation proof circuit")
  var other = module
  other.types[0] = FuncType(params: @[vtExternRef], results: @[vtExternRef])
  other.codes[0].code.code = @[Instr(op: opBlock), Instr(op: opEnd), Instr(op: opLocalGet)]
  let otherRows = buildInstructionEventRows(traceModuleValidation(other), 16)
  let otherIm = instructionImmediates(other, otherRows)
  let otherSignatures = buildSignatureEnvironment(other, 2, 8, includeSingletons = true)
  let second = buildControlTypes(otherRows, buildTypeEnvironment(other, 1, 1), otherSignatures,
    buildIndexedSignatures(otherSignatures, 8, 8), otherIm.p, otherIm.s, otherIm.pads, full = true)
  require(second.satisfied() and circuit.sameShape(second), "structured validation type/control-dependent matrix")
  planCases.add controlPlanCases(module, traceModuleValidation(module))
  planCases.add controlPlanCases(other, traceModuleValidation(other))
  let oracleCases = checkPlans(paramStr(1), paramStr(2))
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "structured validation proof")
  let secondProof = encodeProof(prove(key, second))
  require(decodeAndVerify(key.verificationKey, secondProof, second.values[1..second.publicCount]), "structured validation key reuse")
  echo "zkbuild control typing: PASS (", cases, " structured/branch/return transcripts; ", forgeries,
    " coherent signature forgeries rejected; ", oracleCases, " Lean action plans; 3 Lean mutations; ",
    circuit.constraints.len, " constraints/16 rows; QAP ",
    key.domainSize, "; two 192-byte proofs)"

main()
