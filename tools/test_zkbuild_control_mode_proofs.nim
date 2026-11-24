## Fresh public-trace component proofs for every ordinary control-typing mode.
import std/[os, osproc, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures]
import zkbuild_control_type_test_helpers
import zkbuild_control_plan_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

const Modes = [opBlock, opLoop, opIf, opElse, opEnd, opBr, opBrIf, opReturn, opTryTable]

proc fixture(mode: Opcode, unknown: bool): WasmModule =
  let signature = FuncType(params: @[vtI32, vtI64], results: @[vtI32, vtI64])
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[signature, signature],
    funcTypeIdxs: @[0'u32])
  var code: seq[Instr]
  if unknown: code.add Instr(op: opUnreachable)
  else: code.add @[Instr(op: opLocalGet), Instr(op: opLocalGet, imm1: 1)]
  if mode != opEnd:
    let opener = case mode
      of opLoop: opLoop
      of opIf, opElse: opIf
      of opTryTable: opTryTable
      else: opBlock
    if opener == opIf and not unknown: code.add Instr(op: opI32Const)
    code.add Instr(op: opener, pad: 0x101)
    if unknown: code.add Instr(op: opUnreachable)
    case mode
    of opElse: code.add Instr(op: opElse)
    of opBr, opBrIf, opReturn:
      if mode == opBrIf and not unknown: code.add Instr(op: opI32Const)
      code.add Instr(op: mode)
    else: discard
    code.add Instr(op: opEnd)
  result.codes.add FuncBody(code: Expr(code: code, catchTables: @[newSeq[CatchClause]()]))

proc build(mode: Opcode, unknown: bool, plans: var seq[string]): Circuit =
  let module = fixture(mode, unknown)
  let events = traceModuleValidation(module)
  plans.add controlPlanCases(module, events)
  let rows = buildInstructionEventRows(events, 64)
  let immediates = instructionImmediates(module, rows)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  result = buildControlTypes(rows, buildTypeEnvironment(module), signatures,
    buildIndexedSignatures(signatures), immediates.p, immediates.s, immediates.pads, full = true)
  require(result.satisfied(), "control mode circuit: " & $mode)

proc main() =
  require(paramCount() == 2 or (paramCount() == 3 and paramStr(3) == "--check"),
    "usage: test_control_mode_proofs CHECKER WORK_DIR [--check]")
  createDir(paramStr(2))
  var ignored, plans: seq[string]
  let prototype = build(opEnd, false, ignored)
  var proofBytes: seq[seq[byte]]
  var statements: seq[seq[Scalar]]
  var substitutions, malformed: int
  let preflight = paramCount() == 3
  let key = if preflight: default(ProvingKey) else: setup(prototype)
  for mode in Modes:
    for unknown in [false, true]:
      let name = $mode & (if unknown: "-unknown" else: "-known")
      let circuit = build(mode, unknown, plans)
      require(prototype.sameShape(circuit), "control mode shape: " & name)
      if preflight: continue
      let inputs = circuit.values[1..circuit.publicCount]
      let proof = encodeProof(prove(key, circuit))
      require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, inputs), "control mode proof: " & name)
      require(not decodeAndVerify(key.verificationKey, proof[0..^2], inputs), "truncated control proof accepted")
      require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8], inputs), "trailing control proof byte accepted")
      malformed += 2
      var changed = @inputs
      changed[^1] += scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "changed control statement accepted")
      inc substitutions
      var bytes = newString(proof.len)
      for i, value in proof: bytes[i] = char(value)
      writeFile(paramStr(2)/(name & ".proof"), bytes)
      proofBytes.add @proof
      statements.add inputs
      echo "control mode proof PASS: case=", name, " bytes=", proof.len
  let planPath = absolutePath(paramStr(2)/"plans.txt")
  writeFile(planPath, plans.join("\n") & "\n")
  let checked = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(planPath))
  require(checked.exitCode == 0 and checked.output.strip == "ZKCONTROL1 " & $plans.len & " " & $plans.len,
    "independent control action plans: " & checked.output)
  if preflight:
    echo "control mode preflight: PASS (18 cases; ", plans.len, " independent action plans)"
    return
  for i, proof in proofBytes:
    for j, inputs in statements:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, inputs), "cross-mode control proof accepted")
        inc substitutions
  echo "zkbuild control mode proofs: PASS (18 cases; one reused key; 18 proofs of 192 bytes; ",
    substitutions, " statement substitutions rejected; ", malformed, " malformed encodings rejected; ",
    plans.len, " independent action plans; ", prototype.constraints.len, " constraints/64 rows; QAP ", key.domainSize, ")"

main()
