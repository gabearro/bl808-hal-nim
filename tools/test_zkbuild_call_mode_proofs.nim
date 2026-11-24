## Actual Groth16 proofs for all call modes under one fixed component key.
## These public trace/environment statements are component tests, not WASM
## module-digest certificates or keys suitable for kernel admission.
import std/os
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment]
import zkbuild_call_test_helpers, zkbuild_call_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc build(code: uint16): Circuit =
  let module = moduleForCall(code, @[vtI64], @[vtF32], true)
  let rows = buildInstructionEventRows(traceModuleValidation(module), 32)
  var primary, secondary: seq[uint32]
  primary.setLen(rows.len)
  secondary.setLen(rows.len)
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veInstructionBegin)) and int(row.pc) < module.codes[0].code.code.len:
      let instruction = module.codes[0].code.code[int(row.pc)]
      primary[i] = instruction.imm1
      secondary[i] = instruction.imm2
  result = buildCalls(rows, buildTypeEnvironment(module, 2, 2), buildSignatureEnvironment(module, 4, 8),
    primary, secondary, full = true)
  require(result.satisfied(), "call-mode witness rejected: " & $code)

proc main() =
  require(paramCount() == 1, "usage: test_zkbuild_call_mode_proofs WORK_DIR")
  createDir(paramStr(1))
  var circuits: seq[Circuit]
  for code in [0x10'u16, 0x11, 0x12, 0x13]:
    let circuit = build(code)
    if circuits.len > 0: require(circuits[0].sameShape(circuit), "call mode changed the circuit shape")
    circuits.add circuit
  let key = setup(circuits[0])
  var proofs: seq[seq[byte]]
  var substitutions = 0
  for i, circuit in circuits:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "call-mode proof failed: " & $i)
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
    writeFile(paramStr(1)/("call-" & $(16+i) & ".proof"), bytes)
    proofs.add @proof
    echo "call mode proof PASS: opcode=", 16+i, " bytes=", proof.len
  for i, proof in proofs:
    for j, circuit in circuits:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]),
          "proof accepted for a different call mode")
        inc substitutions
  echo "zkbuild call mode proofs: PASS (4 modes; one reused key; 4 proofs of 192 bytes; ", substitutions,
    " statement substitutions rejected; 8 malformed encodings rejected; ", circuits[0].constraints.len,
    " constraints/32 rows; QAP ", key.domainSize, ")"

main()
