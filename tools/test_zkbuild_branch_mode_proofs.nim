## Fresh Groth16 component proofs, including complete branch typing. The public
## statements expose trace/environment inputs; these are not module-admission keys.
import std/os
import cps/wasm/types
import cps/zk/[r1cs, prover, wasm_branch_environment]
import zkbuild_branch_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(mode: int): WasmModule =
  var code: seq[Instr]
  if mode in [3, 4]: code.add Instr(op: (if mode == 3: opBlock else: opLoop))
  code.add Instr(op: (if mode == 5: opUnreachable else: opI32Const))
  code.add Instr(op: opBrTable)
  if mode in [3, 4]: code.add Instr(op: opEnd)
  let labels = case mode
    of 1: @[0'u32, 0]
    of 2: @[0'u32, 0, 0, 0]
    of 3, 4: @[0'u32, 1]
    else: newSeq[uint32]()
  WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: code, brTables: @[BrTableData(labels: labels, defaultLabel: 0)]))])

proc main() =
  require(paramCount() == 1, "usage: test_zkbuild_branch_mode_proofs WORK_DIR")
  createDir(paramStr(1))
  const labels = ["default", "duplicates", "five-targets", "block-depths", "loop-depths", "unreachable"]
  var circuits: seq[Circuit]
  for i in 0..<labels.len:
    let module = fixture(i)
    let circuit = buildBranchTypes(module, branchRows(module, 32), buildBranchEnvironment(module, 2, 8))
    require(circuit.satisfied(), "branch-mode witness rejected: " & labels[i])
    if circuits.len > 0:
      require(circuits[0].sameShape(circuit), "branch mode changed the circuit shape: " & labels[i])
    circuits.add circuit
  let key = setup(circuits[0])
  var proofs: seq[seq[byte]]
  var substitutions = 0
  for i, circuit in circuits:
    let proof = encodeProof(prove(key, circuit))
    let inputs = circuit.values[1..circuit.publicCount]
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, inputs), "branch-mode proof failed: " & labels[i])
    require(not decodeAndVerify(key.verificationKey, proof[0..^2], inputs), "truncated branch proof accepted")
    require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8], inputs), "trailing branch proof byte accepted")
    var changed = @inputs
    changed[^1] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, changed), "changed branch statement accepted")
    inc substitutions
    var bytes = newString(proof.len)
    for j, value in proof: bytes[j] = char(value)
    writeFile(paramStr(1)/("branch-" & labels[i] & ".proof"), bytes)
    proofs.add @proof
    echo "branch mode proof PASS: case=", labels[i], " bytes=", proof.len
  for i, proof in proofs:
    for j, circuit in circuits:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]),
          "proof accepted for a different branch statement")
        inc substitutions
  echo "zkbuild branch mode proofs: PASS (6 cases; one reused key; 6 proofs of 192 bytes; ", substitutions,
    " statement substitutions rejected; 12 malformed encodings rejected; ", circuits[0].constraints.len,
    " constraints/32 rows; QAP ", key.domainSize, ")"

main()
