import std/[os, osproc, strutils]
import cps/wasm/[types, validate, exception_typing]
import cps/zk/[r1cs, prover, range_check, read_only_memory, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_signature_environment, wasm_throw_events,
  wasm_reference_context, wasm_branch_environment, wasm_memory_metadata, wasm_bulk_context,
  wasm_validation_witness, wasm_trace_check]
import zkbuild_branch_test_helpers

const Types = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(params: seq[ValType], polymorphic = false, opaque = false): WasmModule =
  var code: seq[Instr]
  if polymorphic: code.add Instr(op: opUnreachable)
  else:
    for i in 0..<params.len: code.add Instr(op: opLocalGet, imm1: uint32(i))
  code.add Instr(op: (if opaque: opThrowRef else: opThrow))
  WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: params), FuncType(params: params)], funcTypeIdxs: @[0'u32],
    tagDefs: @[WasmTagDef(typeIdx: 1)], codes: @[FuncBody(code: Expr(code: code))])

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc unit(code: uint16, params: seq[ValType], first, second, pattern: int): Circuit =
  var module = WasmModule(types: @[FuncType(params: params)], tagDefs: @[WasmTagDef(typeIdx: 0)])
  let signatures = buildSignatureEnvironment(module, 2, 16, includeSingletons = true)
  let tags = buildTagEnvironment(module, signatures, 1)
  result = initCircuit(reuseRangeWitnesses = true)
  let op = result.publicInput(scalar(code))
  let signatureWires = SignatureEnvironmentWires(signatures: result.inputs(signatures.signatures), nodes: result.inputs(signatures.nodes))
  var tagWires = TagEnvironmentWires(tags: result.inputs(tags.tags))
  tagWires.typeIndices.add result.publicInput(scalar(0))
  var kinds = @[uint8(ord(veInstructionBegin))]
  var values = @[7'u8]
  template add(kind: ValidationEventKind, value: int) =
    kinds.add uint8(ord(kind)); values.add uint8(value)
  case pattern
  of 0: add(veUnreachable, 7)
  of 1: add(veOperandPop, first); add(veUnreachable, 7)
  of 2: add(veOperandPop, first); add(veOperandPop, second); add(veUnreachable, 7)
  of 3: add(veUnreachable, 7); add(veOperandPop, first)
  of 4: add(veOperandPush, first); add(veUnreachable, 7)
  else: add(veOperandPop, first)
  while kinds.len < 4: kinds.add 255; values.add 7
  add(veInstructionEnd, 7)
  var rows: seq[InstructionEventRow]
  var wires: seq[InstructionEventWires]
  var primary: seq[Linear]
  var projection: OperandEventProjection
  var booleans, typeValues: seq[Linear]
  for i, kind in kinds:
    let actual = result.publicInput(scalar(values[i]))
    typeValues.add actual
    wires.add InstructionEventWires(opcode: op, control: ControlEventWires(operand: OperandEventWires(valueType: actual)))
    rows.add InstructionEventRow(opcode: code, control: ControlEventRow(operand: OperandEventRow(kind: kind)))
    primary.add result.publicInput(scalar(0))
    var flags: OperandEventFlags
    template flag(field: untyped, expected: ValidationEventKind) =
      flags.field = result.publicInput(scalar(ord(kind == uint8(ord(expected)))))
      booleans.add flags.field
    flag(instructionBegin, veInstructionBegin)
    flag(instructionEnd, veInstructionEnd)
    flag(operandPop, veOperandPop)
    flag(operandPush, veOperandPush)
    flag(clear, veUnreachable)
    flag(controlPush, veControlPush)
    flag(controlPop, veControlPop)
    projection.flags.add flags
  for value in booleans: result.constrainBoolean(value)
  for value in typeValues: discard result.constrainUnsigned(value, 3)
  result.constrainThrowEvents(wires, primary, projection, tagWires, signatureWires,
    buildThrowEventsWitness(tags, signatures, rows, newSeq[uint32](rows.len)))

proc full(module: WasmModule, rows: seq[InstructionEventRow], tags: var TagEnvironment,
    binding = true): Circuit =
  var memory = buildMemoryEnvironment(module)
  var bulk = buildBulkEnvironment(module)
  var references = buildReferenceEnvironment(module)
  buildBranchTypes(module, rows, buildBranchEnvironment(module), memory = addr memory, bulk = addr bulk,
    references = addr references, tags = addr tags, throwBinding = binding)

proc check(module: WasmModule): int =
  let events = traceModuleValidation(module, labelChecks = true)
  require(checkValidationTraceStructure(module, events, true).accepted, "independent throw replay")
  var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
  require(full(module, buildInstructionEventRows(events), tags).satisfied(), "composed throw validation")
  1

proc forged(module: WasmModule, rows: seq[InstructionEventRow], tags: var TagEnvironment, message: string) =
  require(full(module, rows, tags, false).satisfied(), message & " preceding partial relation")
  require(not full(module, rows, tags).satisfied(), message)

proc main() =
  require(paramCount() == 2, "usage: test_throw_events EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = paramStr(2) / "throw.txt"
  require(execCmd(quoteShell(paramStr(1)) & " " & quoteShell(path)) == 0, "throw oracle exporter")
  let lines = readFile(path).splitLines()
  require(lines[0] == "ZKTHROW1 16128", "throw oracle header")
  var finite, matrices, cases, forgeries: int
  var shape: Circuit
  for line in lines[1..^1]:
    if line.len == 0: continue
    var v: seq[int]
    for item in line.splitWhitespace(): v.add parseInt(item)
    var params: seq[ValType]
    for i in 0..<v[1]: params.add Types[(i+v[2]) mod 7]
    let rule = exceptionRule(fixture(params), Instr(op: Opcode(v[0])))
    require(rule.present, "throw signature resolution")
    let host = case v[5]
      of 0: rule.inputs.len == 0
      of 1: rule.inputs.len == 1 and (v[3] == 7 or v[3] == int(rule.inputs[0]))
      of 2: rule.inputs.len == 2 and (v[3] == 7 or v[3] == int(rule.inputs[0])) and
        (v[4] == 7 or v[4] == int(rule.inputs[1]))
      else: false
    require(host == (v[6] == 1), "Nim/Lean throw signature and body " & line)
    if finite mod 47 == 0:
      let circuit = unit(uint16(v[0]), params, v[3], v[4], v[5])
      require(circuit.satisfied() == (v[6] == 1), "R1CS/Lean throw case " & line)
      if matrices == 0: shape = circuit
      else: require(circuit.sameShape(shape), "throw matrix depends on witness values")
      inc matrices
    inc finite
  require(finite == 16128, "throw oracle coverage")
  for count in 0..3:
    for seed in 0..6:
      var params: seq[ValType]
      for i in 0..<count: params.add Types[(i+seed) mod 7]
      for polymorphic in [false, true]: cases += check(fixture(params, polymorphic))
  cases += check(fixture(@[vtExternRef], opaque = true))
  cases += check(fixture(@[], polymorphic = true, opaque = true))
  block:
    var module = fixture(@[vtI32])
    let rows = branchRows(module)
    var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
    module.codes[0].code.code[^1].imm1 = 1
    require(not accepted(module), "missing tag must fail source validation")
    forged(module, rows, tags, "nonexistent tag")
    inc forgeries
  block:
    var module = fixture(@[vtI64])
    let rows = branchRows(module)
    module.types[1].params = @[vtI32]
    require(not accepted(module), "wrong payload type must fail source validation")
    var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
    forged(module, rows, tags, "coherently regenerated wrong payload type")
    inc forgeries
  for mutation in 0..2:
    var module = fixture(@[vtI32])
    if mutation == 0: module.types[1].params = @[]
    elif mutation == 1:
      module.types[0].params = @[vtI32, vtI32]
      module.types[1].params = @[vtI32, vtI32]
      module.codes[0].code.code.insert(Instr(op: opLocalGet, imm1: 1), 1)
    let rows = branchRows(module)
    if mutation == 0: module.types[1].params = @[vtI32]
    elif mutation == 1: module.types[1].params = @[vtI32]
    else: module.types[1].results = @[vtI64]
    require(accepted(module) == (mutation != 2), "throw forgery source context")
    var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
    forged(module, rows, tags, "missing/extra payload or resultful tag " & $mutation)
    inc forgeries
  block:
    var module = fixture(@[vtI32])
    module.imports = @[Import(kind: ikFunc, funcTypeIdx: 0), Import(kind: ikFunc, funcTypeIdx: 0)]
    # A function metadata entry exists at index two, but type index two does not.
    let rows = branchRows(module)
    var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
    tags.typeIndices[0] = 2
    forged(module, rows, tags, "function/type tag namespace alias")
    inc forgeries
  block:
    var module = fixture(@[vtI32])
    let rows = branchRows(module)
    var tags = buildTagEnvironment(module, buildSignatureEnvironment(module, includeSingletons = true))
    tags.tags[0].address = 1
    module.codes[0].code.code[^1].imm1 = 1
    forged(module, rows, tags, "sparse tag index forgery")
    inc forgeries
  for value in [1'u32, high(uint32)]:
    var module = fixture(@[])
    module.tagDefs[0].typeIdx = value+uint32(ord(value == 1))
    require(not accepted(module), "invalid tag type index")
    inc forgeries
  let base = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 1, 0x6f, 0, 3, 2, 1, 0, 13, 3, 1, 0, 0]
  let aBytes = base & @[10'u8, 8, 1, 6, 0, 0x20, 0, 8, 0, 0x0b]
  let bBytes = base & @[10'u8, 7, 1, 5, 0, 0x20, 0, 10, 0x0b]
  let aw = buildFullValidationWitness(aBytes, labelChecks = true)
  let bw = buildFullValidationWitness(bBytes, labelChecks = true)
  var at = buildTagEnvironment(aw.module, buildSignatureEnvironment(aw.module, includeSingletons = true), 1)
  var bt = buildTagEnvironment(bw.module, buildSignatureEnvironment(bw.module, includeSingletons = true), 1)
  let a = full(aw.module, buildInstructionEventRows(aw.events, 16), at)
  let b = full(bw.module, buildInstructionEventRows(bw.events, 16), bt)
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "tagged/opaque throw binary profile")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "throw Groth16 proof")
    for index in [0, circuit.publicCount div 2, circuit.publicCount-1]:
      var changed = circuit.values[1..circuit.publicCount]
      changed[index] = changed[index]+scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "throw public substitution")
  echo "zkbuild throw events: PASS (", finite, " Lean cases; ", matrices, " R1CS shapes; ", cases,
    " full traces; ", forgeries, " context/arity/type forgeries; ", a.constraints.len,
    " constraints/16 rows; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
