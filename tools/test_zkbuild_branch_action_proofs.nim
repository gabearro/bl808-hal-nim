## Complete branch action plans and actual type restoration, with a reused key.
## Public trace/environment component proofs; not general module admission.
import std/os
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_branch_environment]
import zkbuild_branch_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(arity: int, loop, unknown: bool, mixed = false): WasmModule =
  result = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(), FuncType(results: @[vtI32]), FuncType(results: @[vtI32, vtI64]),
      FuncType(params: @[vtI32]), FuncType(params: @[vtI32, vtI64])], funcTypeIdxs: @[0'u32])
  var code: seq[Instr]
  proc arguments() =
    if arity > 0: code.add Instr(op: opI32Const)
    if arity > 1: code.add Instr(op: opI64Const)
  if mixed: code.add Instr(op: opBlock, pad: uint16(256+arity))
  if loop: arguments()
  let signature = if arity == 0: 0 else: arity + (if loop: 2 else: 0)
  code.add Instr(op: (if loop: opLoop else: opBlock), pad: uint16(256+signature))
  if unknown: code.add Instr(op: opUnreachable)
  else:
    if not loop: arguments()
    code.add Instr(op: opI32Const)
  code.add @[Instr(op: opBrTable), Instr(op: opEnd)]
  if mixed: code.add @[Instr(op: opUnreachable), Instr(op: opEnd)]
  if not loop or mixed:
    for _ in 0..<arity: code.add Instr(op: opDrop)
  var labels = newSeq[uint32](arity)
  if mixed: labels[^1] = 1
  result.codes.add FuncBody(code: Expr(code: code,
    brTables: @[BrTableData(labels: labels, defaultLabel: 0)]))

proc build(arity: int, loop, unknown: bool, mixed = false): Circuit =
  let module = fixture(arity, loop, unknown, mixed)
  let rows = branchRows(module, 64)
  var expectedKinds: seq[ValidationEventKind] = @[veOperandPop]
  var expectedTypes: seq[int] = @[if unknown: 7 else: 0]
  for target in 0..arity:
    expectedKinds.add veLabelCheck
    expectedTypes.add -1
    for p in countdown(arity-1, 0):
      expectedKinds.add veOperandPop
      expectedTypes.add (if unknown: 7 else: p)
    if target < arity:
      for p in 0..<arity:
        expectedKinds.add veOperandPush
        expectedTypes.add (if unknown: 7 else: p)
    else:
      expectedKinds.add veUnreachable
      expectedTypes.add -1
  var found, opened: bool
  var index: int
  for row in rows:
    let e = row.control.operand
    if row.opcode == uint16(ord(opBrTable)):
      if e.kind == uint8(ord(veInstructionBegin)):
        require(not found, "duplicate branch instruction")
        found = true
        opened = true
      elif e.kind == uint8(ord(veInstructionEnd)):
        require(opened and index == expectedKinds.len, "incomplete branch action plan")
        opened = false
      elif opened:
        require(index < expectedKinds.len and e.kind == uint8(ord(expectedKinds[index])), "branch action order")
        if expectedTypes[index] >= 0:
          require(int(e.valueType) == expectedTypes[index], "branch argument/restoration type")
        inc index
  require(found and not opened, "missing or open branch body")
  result = buildBranchTypes(module, rows, buildBranchEnvironment(module, 2, 8))
  require(result.satisfied(), "branch action circuit")

proc main() =
  require(paramCount() == 1 or (paramCount() == 2 and paramStr(2) == "--check"),
    "usage: test_branch_action_proofs WORK_DIR [--check]")
  createDir(paramStr(1))
  let prototype = build(0, false, false)
  var cases: seq[tuple[arity: int, loop, unknown, mixed: bool]]
  for arity in 0..2:
    for loop in [false, true]:
      for unknown in [false, true]: cases.add (arity, loop, unknown, false)
  for arity in 1..2:
    for unknown in [false, true]: cases.add (arity, true, unknown, true)
  if paramCount() == 2:
    for (arity, loop, unknown, mixed) in cases:
      require(prototype.sameShape(build(arity, loop, unknown, mixed)), "branch action preflight shape")
    echo "branch action circuit preflight: PASS (", cases.len, " cases)"
    return
  let key = setup(prototype)
  var proofs: seq[seq[byte]]
  var statements: seq[seq[Scalar]]
  var substitutions, malformed: int
  for (arity, loop, unknown, mixed) in cases:
    let name = "arity" & $arity & (if mixed: "-mixed" elif loop: "-loop" else: "-block") &
      (if unknown: "-unknown" else: "-known")
    let circuit = build(arity, loop, unknown, mixed)
    require(prototype.sameShape(circuit), "branch action shape: " & name)
    let inputs = circuit.values[1..circuit.publicCount]
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, inputs), "branch action proof: " & name)
    require(not decodeAndVerify(key.verificationKey, proof[0..^2], inputs), "truncated proof accepted")
    require(not decodeAndVerify(key.verificationKey, @proof & @[0'u8], inputs), "trailing proof byte accepted")
    malformed += 2
    var changed = @inputs
    changed[^1] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, changed), "changed statement accepted")
    inc substitutions
    var bytes = newString(proof.len)
    for i, value in proof: bytes[i] = char(value)
    writeFile(paramStr(1)/(name & ".proof"), bytes)
    proofs.add @proof
    statements.add inputs
    echo "branch action proof PASS: case=", name, " bytes=", proof.len
  for i, proof in proofs:
    for j, inputs in statements:
      if i != j:
        require(not decodeAndVerify(key.verificationKey, proof, inputs), "cross-plan proof accepted")
        inc substitutions
  echo "zkbuild branch action proofs: PASS (16 cases; one reused key; 16 proofs of 192 bytes; ",
    substitutions, " statement substitutions rejected; ", malformed, " malformed encodings rejected; ",
    prototype.constraints.len, " constraints/64 rows; QAP ", key.domainSize, ")"

main()
