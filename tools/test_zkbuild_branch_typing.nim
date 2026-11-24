import std/[os, osproc, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events,
  wasm_branch_environment, wasm_trace_check]
import cps/zk/wasm_validation_witness
import zkbuild_branch_test_helpers
import zkbuild_branch_plan_test_helpers

var planCases: seq[string]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc branchModule(values: seq[ValType], labels: seq[uint32],
    loop = false, polymorphic = false): WasmModule =
  var code: seq[Instr]
  for i in 0..<values.len: code.add Instr(op: opLocalGet, imm1: uint32(i))
  code.add Instr(op: (if loop: opLoop else: opBlock), pad: 0x101)
  if polymorphic: code.add Instr(op: opUnreachable)
  else: code.add Instr(op: opI32Const)
  code.add Instr(op: opBrTable)
  code.add Instr(op: opEnd)
  WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: values, results: values), FuncType(params: values, results: values)],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(code: Expr(code: code,
      brTables: @[BrTableData(labels: labels, defaultLabel: 0)]))])

proc emptyBranch(labels: seq[uint32]): WasmModule =
  WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opI32Const), Instr(op: opBrTable)],
      brTables: @[BrTableData(labels: labels, defaultLabel: 0)]))])

proc check(module: WasmModule) =
  let events = traceModuleValidation(module, labelChecks = true)
  require(checkValidationTraceStructure(module, events, labelChecks = true).accepted, "branch structural replay")
  require(buildBranchTypes(module, buildInstructionEventRows(events), buildBranchEnvironment(module)).satisfied(), "branch type trace")
  planCases.add branchPlanCases(module, events)

proc checkPlans(checker, workDir: string): int =
  createDir(workDir)
  let path = absolutePath(workDir/"branch-plans.txt")
  writeFile(path, planCases.join("\n") & "\n")
  let command = quoteShell(absolutePath(checker)) & " "
  let accepted = execCmdEx(command & quoteShell(path))
  require(accepted.exitCode == 0 and accepted.output.strip == "ZKBRANCH1 " & $planCases.len & " " & $planCases.len,
    "independent Lean branch plans: " & accepted.output)
  let bad = absolutePath(workDir/"bad-branch-plans.txt")
  for mutation in 0..3:
    var altered = @planCases
    var fields = altered[0].splitWhitespace()
    let count = parseInt(fields[0])
    var actionStart = 2
    for i in 0..<count: actionStart += 1+parseInt(fields[actionStart])
    if mutation == 0: fields[actionStart] = "1" # Condition must be i32/unknown.
    elif mutation == 1:
      fields.delete(actionStart+1) # Omit a label marker, including zero arity.
      fields[1] = $(parseInt(fields[1])-1)
    elif mutation == 2:
      fields.add "33" # Duplicate clear.
      fields[1] = $(parseInt(fields[1])+1)
    else:
      fields.add "16" # Output after default.
      fields[1] = $(parseInt(fields[1])+1)
    altered[0] = fields.join(" ")
    writeFile(bad, altered.join("\n") & "\n")
    require(execCmdEx(command & quoteShell(bad)).exitCode == 1, "Lean accepted a mutated branch plan")
  planCases.len

proc main() =
  require(paramCount() == 2, "usage: test_branch_typing CHECKER WORK_DIR")
  var cases, forgeries: int
  for values in [newSeq[ValType](), @[vtI64], @[vtI32, vtExternRef, vtV128]]:
    for loop in [false, true]:
      for poly in [false, true]:
        let module = branchModule(values, @[0'u32, 0], loop, poly)
        check(module)
        inc cases
  let polyTypes = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opBlock, pad: 2), Instr(op: opBlock, pad: 1),
      Instr(op: opUnreachable), Instr(op: opBrTable), Instr(op: opEnd), Instr(op: opDrop),
      Instr(op: opUnreachable), Instr(op: opEnd)],
      brTables: @[BrTableData(labels: @[0'u32], defaultLabel: 1)]))])
  check(polyTypes)
  inc cases
  for value in [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]:
    check(branchModule(@[value], @[]))
    inc cases
  for loop in [false, true]:
    var mixed = WasmModule(startFunc: -1, dataCount: -1,
      types: @[FuncType(params: @[vtI32], results: @[vtI64]), FuncType(params: @[vtI32], results: @[vtI64])],
      funcTypeIdxs: @[0'u32])
    var code = @[Instr(op: opLocalGet), Instr(op: (if loop: opLoop else: opBlock), pad: 0x101)]
    if not loop:
      code.add Instr(op: opDrop)
      code.add Instr(op: opI64Const)
    code.add @[Instr(op: opI32Const), Instr(op: opBrTable), Instr(op: opEnd)]
    mixed.codes.add FuncBody(code: Expr(code: code, brTables: @[BrTableData(labels: @[0'u32], defaultLabel: 0)]))
    check(mixed)
    inc cases
    if loop:
      var wrongType = buildBranchEnvironment(mixed)
      wrongType.nodes[^1].value = (wrongType.nodes[^1].value and 0xffffffff00000000'u64) or 1
      let rows = branchRows(mixed)
      require(buildBranchTypes(mixed, rows, wrongType, typed = false).satisfied(), "concrete label-type forgery preceding relation")
      require(not buildBranchTypes(mixed, rows, wrongType).satisfied(), "concrete loop/root label type mismatch")
      inc forgeries
  block:
    var imported = branchModule(@[vtExternRef], @[0'u32], polymorphic = true)
    imported.imports.add Import(kind: ikFunc, funcTypeIdx: 0)
    check(imported)
    inc cases
  block:
    var multiple = emptyBranch(@[])
    multiple.funcTypeIdxs.add 0
    multiple.codes.add emptyBranch(@[0'u32, 0]).codes[0]
    check(multiple)
    inc cases
  block:
    var twoBanks = emptyBranch(@[])
    twoBanks.codes[0].code.code.add Instr(op: opBrTable, imm1: 1)
    twoBanks.codes[0].code.brTables.add BrTableData(labels: @[0'u32, 0], defaultLabel: 0)
    check(twoBanks)
    inc cases
  block:
    var combined = emptyBranch(@[0'u32])
    combined.codes[0].code.code = @[Instr(op: opRefNull, imm1: 0x70),
      Instr(op: opRefNull, imm1: 0x70), Instr(op: opI32Const),
      Instr(op: opSelectTyped, imm1: 0x70), Instr(op: opDrop),
      Instr(op: opI32Const), Instr(op: opBrTable)]
    check(combined)
    inc cases
  block:
    var combined = emptyBranch(@[0'u32, 0])
    combined.codes[0].code.code = @[Instr(op: opUnreachable), Instr(op: opSelect),
      Instr(op: opDrop), Instr(op: opBrTable)]
    check(combined)
    inc cases
  block:
    let bytes = @[0'u8, 97, 115, 109, 1, 0, 0, 0,
      1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0,
      10, 11, 1, 9, 0, 0x41, 0, 0x0e, 2, 0, 0, 0, 0x0b]
    let witness = buildFullValidationWitness(bytes, labelChecks = true)
    require(witness.labelChecks and witness.bytes == bytes, "ordinary WASM branch frontend")
    require(buildBranchTypes(witness.module, buildInstructionEventRows(witness.events),
      buildBranchEnvironment(witness.module)).satisfied(), "ordinary WASM branch relation")
    planCases.add branchPlanCases(witness.module, witness.events)
    inc cases
  block:
    let arityModule = WasmModule(startFunc: -1, dataCount: -1,
      types: @[FuncType(results: @[vtI64, vtI64]), FuncType(results: @[vtI64, vtI64])], funcTypeIdxs: @[0'u32],
      codes: @[FuncBody(code: Expr(code: @[Instr(op: opBlock, pad: 0x101), Instr(op: opBlock, pad: 1),
        Instr(op: opUnreachable), Instr(op: opBrTable), Instr(op: opEnd), Instr(op: opDrop),
        Instr(op: opUnreachable), Instr(op: opEnd)],
        brTables: @[BrTableData(labels: @[0'u32, 0], defaultLabel: 0)]))])
    check(arityModule)
    inc cases
    var changed = buildBranchEnvironment(arityModule)
    changed.nodes[1].value = (changed.nodes[1].value and 0xffffffff00000000'u64) or 1
    let rows = branchRows(arityModule)
    require(buildBranchTypes(arityModule, rows, changed, typed = false).satisfied(), "arity forgery preceding partial relation")
    require(not buildBranchTypes(arityModule, rows, changed).satisfied(), "nondefault target arity mismatch")
    inc forgeries
  let module = branchModule(@[vtI32], @[0'u32], polymorphic = true)
  let events = traceModuleValidation(module, labelChecks = true)
  let banks = buildBranchEnvironment(module)
  require(not buildBranchTypes(module, branchRows(module), banks, cancelMetadata = true).satisfied(),
    "inactive query cancelled an incorrect active metadata query")
  inc forgeries
  template rejectEvents(changed: seq[ValidationEvent], message: string) =
    block:
      let rows = buildInstructionEventRows(changed)
      require(buildBranchTypes(module, rows, banks, typed = false).satisfied(), message & " did not pass preceding partial relation")
      require(not buildBranchTypes(module, rows, banks).satisfied(), message)
      inc forgeries
  block:
    var changed = @events
    for i, event in changed:
      if event.opcode == opBrTable and event.kind == veOperandPop:
        changed.delete(i)
        break
    rejectEvents(changed, "omitted polymorphic condition")
  block:
    var changed = @events
    for i, event in changed:
      if event.opcode == opBrTable and event.kind == veOperandPop:
        changed.insert(event, i)
        break
    rejectEvents(changed, "extra polymorphic condition")
  block:
    var changed = @events
    var afterPush = false
    for i, event in changed:
      if event.opcode == opBrTable and event.kind == veOperandPush:
        changed[i].valueType = svI32
        afterPush = true
      elif afterPush and event.opcode == opBrTable and event.kind == veOperandPop:
        changed[i].valueType = svI32
    rejectEvents(changed, "unknown restore changed to declared type")
  block:
    var changed = @events
    for i, event in changed:
      if event.opcode == opBrTable and event.kind == veUnreachable:
        changed.insert(event, i)
        break
    rejectEvents(changed, "duplicate branch clear")
  block:
    var changed = @events
    var pops = 0
    for i, event in changed:
      if event.opcode == opBrTable and event.kind == veOperandPop:
        inc pops
        if pops == 2:
          changed.delete(i)
          break
    rejectEvents(changed, "omitted virtual argument")
  let zero = emptyBranch(@[0'u32, 0])
  let zeroEvents = traceModuleValidation(zero, labelChecks = true)
  block:
    var changed = @zeroEvents
    for i, event in changed:
      if event.kind == veLabelCheck:
        changed.delete(i)
        break
    require(not checkValidationTraceStructure(zero, changed, labelChecks = true).accepted, "replay omitted zero-arity target")
    require(not buildBranchTypes(zero, buildInstructionEventRows(changed), buildBranchEnvironment(zero)).satisfied(), "omitted zero-arity target")
    inc forgeries
  for mutation in 0..5:
    var changed = buildBranchEnvironment(zero)
    case mutation
    of 0: changed.banks[0].value = 0
    of 1: changed.nodes[^1].value = changed.nodes[^1].value and 0xffffffff'u64
    of 2: changed.nodes[0].value = uint64(changed.nodes.len) shl 32
    of 3: changed.nodes[^1].value = uint64(changed.nodes.len-1) shl 32 or uint64(high(uint32))
    of 4: changed.banks.add changed.banks[0]
    of 5: changed.nodes.add changed.nodes[^1]
    else: discard
    require(not buildBranchTypes(zero, buildInstructionEventRows(zeroEvents), changed).satisfied(), "branch environment forgery " & $mutation)
    inc forgeries
  let first = emptyBranch(@[])
  let second = emptyBranch(@[0'u32, 0])
  planCases.add branchPlanCases(first, traceModuleValidation(first, labelChecks = true))
  planCases.add branchPlanCases(second, traceModuleValidation(second, labelChecks = true))
  let oracleCases = checkPlans(paramStr(1), paramStr(2))
  let a = buildBranchTypes(first, branchRows(first, 16), buildBranchEnvironment(first, 2, 3))
  let b = buildBranchTypes(second, branchRows(second, 16), buildBranchEnvironment(second, 2, 3))
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "branch proof profile shape")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "branch Groth16 proof")
    for index in [0, circuit.publicCount div 2, circuit.publicCount-1]:
      var changed = circuit.values[1..circuit.publicCount]
      changed[index] = changed[index]+scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "changed public branch claim")
  echo "zkbuild branch typing: PASS (", cases, " valid traces; ", forgeries,
    " coherent/environment forgeries rejected; ", oracleCases, " Lean action plans; 4 Lean mutations; ",
    a.constraints.len, " constraints/16 rows; QAP ",
    key.domainSize, "; two 192-byte proofs)"

main()
