## Actual Groth16 proofs for all parametric modes under one fixed component key.
## These public trace/environment statements are component tests, not WASM
## module-digest certificates or keys suitable for kernel admission.
import std/os
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events]
import zkbuild_parametric_test_helpers, zkbuild_control_type_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc build(code: OpCode, value: ValType, polymorphic = false): Circuit =
  var instructions: seq[Instr]
  if code != opRefNull:
    if polymorphic: instructions.add Instr(op: opUnreachable)
    else: instructions.add @[Instr(op: opLocalGet), Instr(op: opLocalGet), Instr(op: opI32Const)]
  instructions.add Instr(op: code, imm1: (if code == opSelect: 0'u32 else: uint32(ord(value))))
  instructions.add Instr(op: opDrop)
  let module = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType(params: @[value])],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(code: Expr(code: instructions))])
  let rows = buildInstructionEventRows(traceModuleValidation(module), 32)
  result = buildParametric(rows, instructionImmediates(module, rows).p)
  require(result.satisfied(), "parametric-mode witness rejected: " & $code & "/" & $value)

proc main() =
  require(paramCount() == 1, "usage: test_zkbuild_parametric_mode_proofs WORK_DIR")
  createDir(paramStr(1))
  var circuits: seq[Circuit]
  var labels: seq[string]
  proc add(code: OpCode, value: ValType, poly = false) =
    let circuit = build(code, value, poly)
    if circuits.len > 0: require(circuits[0].sameShape(circuit), "parametric mode changed the circuit shape")
    circuits.add circuit
    labels.add $ord(code) & "-" & $ord(value) & (if poly: "-unknown" else: "")
  for value in [vtI32, vtI64, vtF32, vtF64, vtV128]: add(opSelect, value)
  add(opSelect, vtI32, true)
  for value in [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]: add(opSelectTyped, value)
  for value in [vtFuncRef, vtExternRef]: add(opRefNull, value)
  let key = setup(circuits[0])
  var proofs: seq[seq[byte]]
  var substitutions = 0
  for i, circuit in circuits:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "parametric-mode proof failed: " & $i)
    require(not decodeAndVerify(key.verificationKey, proof[0..^2],
      circuit.values[1..circuit.publicCount]), "truncated proof accepted")
    require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8],
      circuit.values[1..circuit.publicCount]), "trailing proof byte accepted")
    var changed = circuit.values[1..circuit.publicCount]
    changed[^1] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, changed), "changed public input accepted")
    inc substitutions
    var bytes = newString(proof.len)
    for j, value in proof: bytes[j] = char(value)
    writeFile(paramStr(1)/("parametric-" & labels[i] & ".proof"), bytes)
    proofs.add @proof
    echo "parametric mode proof PASS: case=", labels[i], " bytes=", proof.len
  for i, proof in proofs:
    for j, circuit in circuits:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]),
          "proof accepted for a different parametric statement")
        inc substitutions
  echo "zkbuild parametric mode proofs: PASS (3 opcodes; 15 cases; one reused key; 15 proofs of 192 bytes; ", substitutions,
    " statement substitutions rejected; 30 malformed encodings rejected; ", circuits[0].constraints.len,
    " constraints/32 rows; QAP ", key.domainSize, ")"

main()
