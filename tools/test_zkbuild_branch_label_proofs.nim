## All seven singleton types and empty blocks/loops, using one component key.
## Trace/environment inputs are public; this is not a module-admission proof.
import std/os
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures, wasm_branch_environment,
  wasm_branch_validation]
import zkbuild_branch_test_helpers

const valueTypes = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(tag: int, loop: bool): WasmModule =
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32])
  var locals: seq[LocalDecl]
  for kind in valueTypes:
    result.types.add FuncType(results: @[kind])
    locals.add LocalDecl(count: 1, valType: kind)
  var code = @[Instr(op: (if loop: opLoop else: opBlock), pad: uint16(tag+1))]
  code.add (if tag < 0: Instr(op: opNop) else: Instr(op: opLocalGet, imm1: uint32(tag)))
  code.add Instr(op: (if loop and tag >= 0: opDrop else: opNop))
  code.add @[Instr(op: opI32Const), Instr(op: opBrTable), Instr(op: opEnd)]
  code.add Instr(op: (if tag >= 0: opDrop else: opNop))
  result.codes.add FuncBody(locals: locals, code: Expr(code: code,
    brTables: @[BrTableData(labels: @[0'u32, 0], defaultLabel: 0)]))

proc build(tag: int, loop: bool): Circuit =
  let module = fixture(tag, loop)
  let rows = branchRows(module, 64)
  let branches = buildBranchEnvironment(module, 2, 8)
  let immediate = instructionImmediates(module, rows, 0)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(signatures)
  let witness = buildBranchValidationWitness(buildTypeEnvironment(module), signatures,
    indexed, branches, rows, immediate.p, immediate.s, immediate.pads)
  var labels, arguments: int
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veLabelCheck)):
      inc labels
      let length = witness.branchTypes.indexedQueries.lengths[i]
      let singleton = witness.branchTypes.indexedQueries.singletons[i]
      require(length.active and length.value == uint64(ord(tag >= 0 and not loop)), "label arity")
      require(not witness.branchTypes.metadataQueries[i].active, "inline label queried type metadata")
      require(singleton.active == (tag >= 0), "singleton query activity")
      if tag >= 0: require(singleton.address == uint64(tag), "singleton query type")
      if loop or tag < 0: require(length.address == 0, "empty label did not select nil")
      else: require(length.address == singleton.value and length.address != 0, "singleton label head")
    let member = witness.branchTypes.indexedQueries.members[i]
    if member.active:
      inc arguments
      require(tag >= 0 and not loop and member.value mod 8 == uint64(tag), "label operand tag")
  require(labels == 3 and arguments == (if tag >= 0 and not loop: 3 else: 0), "label coverage")
  result = buildBranchTypes(module, rows, branches)
  require(result.satisfied(), "branch label circuit")

proc main() =
  require(paramCount() == 1, "usage: test_branch_label_proofs WORK_DIR")
  createDir(paramStr(1))
  let prototype = build(-1, false)
  let key = setup(prototype)
  var proofs: seq[seq[byte]]
  var statements: seq[seq[Scalar]]
  var substitutions, malformed: int
  for tag in -1..6:
    for loop in [false, true]:
      let name = (if tag < 0: "empty" else: $valueTypes[tag]) & (if loop: "-loop" else: "-block")
      let circuit = build(tag, loop)
      require(prototype.sameShape(circuit), "branch label changed fixed circuit shape: " & name)
      let inputs = circuit.values[1..circuit.publicCount]
      let proof = encodeProof(prove(key, circuit))
      require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, inputs), "label proof: " & name)
      require(not decodeAndVerify(key.verificationKey, proof[0..^2], inputs), "truncated proof accepted")
      require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8], inputs), "trailing proof byte accepted")
      malformed += 2
      var changed = @inputs
      changed[^1] += scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "changed label statement accepted")
      inc substitutions
      var bytes = newString(proof.len)
      for i, value in proof: bytes[i] = char(value)
      writeFile(paramStr(1)/(name & ".proof"), bytes)
      proofs.add @proof
      statements.add inputs
      echo "branch label proof PASS: case=", name, " bytes=", proof.len
  for i, proof in proofs:
    for j, inputs in statements:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, inputs), "cross-label proof accepted")
        inc substitutions
  echo "zkbuild branch label proofs: PASS (16 cases; one reused key; 16 proofs of 192 bytes; ",
    substitutions, " statement substitutions rejected; ", malformed, " malformed encodings rejected; ",
    prototype.constraints.len, " constraints/64 rows; QAP ", key.domainSize, ")"

main()
