## Complete signature families in one fixed control-typing component profile.
## Trace/environment inputs are public; these are not module-admission proofs.
import std/[os, osproc, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures]
import zkbuild_control_type_test_helpers
import zkbuild_control_plan_test_helpers

const valueTypes = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]
proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc caseName(i: int): string =
  if i < 16:
    let tag = i div 2 - 1
    (if tag < 0: "empty" else: $valueTypes[tag]) & (if i mod 2 == 0: "-block" else: "-loop")
  else: ["typed-block", "typed-loop", "function-results", "implicit-else"][i-16]

proc fixture(i: int): WasmModule =
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()],
    funcTypeIdxs: @[(if i == 18: 9'u32 else: 0'u32)])
  var locals: seq[LocalDecl]
  for kind in valueTypes:
    result.types.add FuncType(results: @[kind])
    locals.add LocalDecl(count: 1, valType: kind)
  result.types.add FuncType(params: @[vtI32, vtI64], results: @[vtI32, vtI64])
  result.types.add FuncType(results: @[vtI32, vtI64])
  var code: seq[Instr]
  if i < 16:
    let tag = i div 2 - 1
    code.add Instr(op: (if i mod 2 == 0: opBlock else: opLoop), pad: uint16(tag+1))
    if tag >= 0: code.add Instr(op: opLocalGet, imm1: uint32(tag))
    code.add Instr(op: opEnd)
    if tag >= 0: code.add Instr(op: opDrop)
  else:
    code.add @[Instr(op: opLocalGet), Instr(op: opLocalGet, imm1: 1)]
    if i != 18:
      if i == 19: code.add Instr(op: opI32Const)
      code.add Instr(op: (if i == 16: opBlock elif i == 17: opLoop else: opIf), pad: 0x108)
      code.add @[Instr(op: opEnd), Instr(op: opDrop), Instr(op: opDrop)]
  result.codes.add FuncBody(locals: locals, code: Expr(code: code))

proc build(i: int, plans: var seq[string]): Circuit =
  let module = fixture(i)
  let events = traceModuleValidation(module)
  plans.add controlPlanCases(module, events)
  let rows = buildInstructionEventRows(events, 64)
  let immediates = instructionImmediates(module, rows)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  result = buildControlTypes(rows, buildTypeEnvironment(module), signatures,
    buildIndexedSignatures(signatures), immediates.p, immediates.s, immediates.pads, full = true)
  require(result.satisfied(), "control signature circuit: " & caseName(i))

proc main() =
  require(paramCount() == 2 or (paramCount() == 3 and paramStr(3) == "--check"),
    "usage: test_control_signature_proofs CHECKER WORK_DIR [--check]")
  createDir(paramStr(2))
  var ignored, plans: seq[string]
  let prototype = build(0, ignored)
  let preflight = paramCount() == 3
  let key = if preflight: default(ProvingKey) else: setup(prototype)
  var proofs: seq[seq[byte]]
  var statements: seq[seq[Scalar]]
  var substitutions, malformed: int
  for i in 0..<20:
    let circuit = build(i, plans)
    require(prototype.sameShape(circuit), "control signature shape: " & caseName(i))
    if preflight: continue
    let inputs = circuit.values[1..circuit.publicCount]
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, inputs), "control signature proof: " & caseName(i))
    require(not decodeAndVerify(key.verificationKey, proof[0..^2], inputs), "truncated proof accepted")
    require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8], inputs), "trailing proof byte accepted")
    malformed += 2
    var changed = @inputs
    changed[^1] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, changed), "changed statement accepted")
    inc substitutions
    var bytes = newString(proof.len)
    for j, value in proof: bytes[j] = char(value)
    writeFile(paramStr(2)/(caseName(i) & ".proof"), bytes)
    proofs.add @proof
    statements.add inputs
    echo "control signature proof PASS: case=", caseName(i), " bytes=", proof.len
  let planPath = absolutePath(paramStr(2)/"plans.txt")
  writeFile(planPath, plans.join("\n") & "\n")
  let checked = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(planPath))
  require(checked.exitCode == 0 and checked.output.strip == "ZKCONTROL1 " & $plans.len & " " & $plans.len,
    "independent action plans: " & checked.output)
  if preflight:
    echo "control signature preflight: PASS (20 cases; ", plans.len, " independent action plans)"
    return
  for i, proof in proofs:
    for j, inputs in statements:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, inputs), "cross-signature proof accepted")
        inc substitutions
  echo "zkbuild control signature proofs: PASS (20 cases; one reused key; 20 proofs of 192 bytes; ",
    substitutions, " statement substitutions rejected; ", malformed, " malformed encodings rejected; ",
    plans.len, " independent action plans; ", prototype.constraints.len, " constraints/64 rows; QAP ", key.domainSize, ")"

main()
