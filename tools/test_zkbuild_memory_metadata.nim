import cps/wasm/[types, validate, static_typing]
import cps/zk/[r1cs, prover, range_check, read_only_memory, wasm_operand_events, wasm_control_events,
  wasm_instruction_events, wasm_memory_metadata, wasm_branch_environment, wasm_validation_witness]
import zkbuild_branch_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc buildUnit(code: uint16, primary, secondary: uint64, environment: MemoryEnvironment,
    functionIndex = 0'u32): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let op = result.publicInput(scalar(code))
  let p = result.publicInput(scalar(primary))
  let s = result.publicInput(scalar(secondary))
  let fn = result.publicInput(scalar(functionIndex))
  var env = MemoryEnvironmentWires(memoryCount: result.publicInput(scalar(environment.memoryCount)))
  for entry in environment.vectorCounts:
    env.vectorCounts.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  discard result.constrainUnsigned(fn, 32)
  let row = InstructionEventWires(opcode: op, control: ControlEventWires(operand: OperandEventWires(functionIndex: fn)))
  let rows = @[InstructionEventRow(opcode: code, control: ControlEventRow(operand:
    OperandEventRow(kind: uint8(ord(veInstructionBegin)), functionIndex: functionIndex)))]
  let projection = OperandEventProjection(flags: @[OperandEventFlags(instructionBegin: constant(1))])
  result.constrainMemoryMetadata([row], [p], [s], projection, env, buildMemoryMetadataWitness(environment, rows))

proc fixture(instruction: Instr, memories = 1, constants = 0): WasmModule =
  var code = @[Instr(op: opUnreachable), instruction]
  if staticRule(instruction.op).outputCount != 0: code.add Instr(op: opDrop)
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: code))])
  result.codes[0].code.v128Consts.setLen(constants)
  for i in 0..<memories: result.memories.add MemType(limits: Limits(min: 1))

proc full(module: WasmModule, rows: seq[InstructionEventRow], environment: var MemoryEnvironment,
    binding = true): Circuit =
  buildBranchTypes(module, rows, buildBranchEnvironment(module), memory = addr environment, memoryBinding = binding)

proc main() =
  var cases, forgeries: int
  let env = MemoryEnvironment(memoryCount: 1, vectorCounts: @[
    ReadOnlyEntry(active: true, address: 0, value: 3), ReadOnlyEntry(active: true, address: 2, value: 1)])
  const Alignments = [2, 3, 2, 3, 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 2, 3, 2, 3, 0, 1, 0, 1, 2]
  let shape = buildUnit(0, 0, 0, env)
  for code in 0x28..0x3e:
    for alignment in [0'u32, uint32(Alignments[code-0x28]), uint32(Alignments[code-0x28]+1), high(uint32)]:
      let circuit = buildUnit(uint16(code), high(uint32), alignment, env)
      require(circuit.satisfied() == (alignment <= uint32(Alignments[code-0x28])), "scalar alignment circuit " & $code)
      require(circuit.sameShape(shape), "alignment-dependent matrix")
      inc cases
  for code in [0x300'u16, 0x301]:
    for alignment in [0'u32, 4, 5, high(uint32)]:
      require(buildUnit(code, alignment, high(uint32), env).satisfied() == (alignment <= 4), "SIMD alignment circuit")
      inc cases
  for code in [0x3f'u16, 0x40]:
    for index in [0'u32, 1, high(uint32)]:
      require(buildUnit(code, index, 0, env).satisfied() == (index == 0), "memory index circuit")
      inc cases
  for code in 0x300..0x342:
    let lanes = simdLaneCount(uint16(code))
    if lanes == 0: continue
    for index in [0'u32, lanes-1, lanes, high(uint32)]:
      require(buildUnit(uint16(code), index, 0, env).satisfied() == (index < lanes), "lane index circuit")
      inc cases
  for fn in [0'u32, 1, 2]:
    for index in [0'u32, 1, 2, 3, high(uint32)]:
      let accepted = (fn == 0 and index < 3) or (fn == 2 and index == 0)
      require(buildUnit(0x302, index, 0, env, fn).satisfied() == accepted, "constant pool/function namespace")
      inc cases
  var noMemory = env
  noMemory.memoryCount = 0
  for code in [0x28'u16, 0x3e, 0x3f, 0x40, 0x108, 0x10a, 0x10b, 0x300, 0x301]:
    require(not buildUnit(code, 0, 0, noMemory).satisfied(), "missing memory accepted")
    inc cases
  var tooMany = env
  tooMany.memoryCount = 2
  require(not buildUnit(0x01, 0, 0, tooMany).satisfied(), "unsupported memory count")
  inc forgeries
  require(not buildUnit(0x309, 1'u64 shl 32, 0, env).satisfied(), "wide lane aliases low bits")
  require(not buildUnit(0x28, 0, 1'u64 shl 32, env).satisfied(), "wide scalar alignment aliases low bits")
  forgeries += 2
  block:
    var wide = env
    wide.vectorCounts[0].value = 1'u64 shl 32
    require(not buildUnit(0x302, 0, 0, wide).satisfied(), "wide pool count")
    inc forgeries
  for instruction in [Instr(op: opI32Load, imm2: 2), Instr(op: opV128Load, imm1: 4),
      Instr(op: opI32x4ExtractLane, imm1: 3), Instr(op: opV128Const)]:
    var module = fixture(instruction, constants = 1)
    let rows = branchRows(module)
    var environment = buildMemoryEnvironment(module)
    require(full(module, rows, environment).satisfied(), "production memory composition")
    inc cases
    if instruction.op == opI32Load: module.codes[0].code.code[1].imm2 = 3
    elif instruction.op == opV128Load: module.codes[0].code.code[1].imm1 = 5
    elif instruction.op == opI32x4ExtractLane: module.codes[0].code.code[1].imm1 = 4
    else: module.codes[0].code.code[1].imm1 = 1
    require(full(module, rows, environment, false).satisfied(), "metadata forgery preceding partial relation")
    require(not full(module, rows, environment).satisfied(), "coherent immediate forgery")
    inc forgeries
  block:
    let module = fixture(Instr(op: opI32Load, imm2: 2))
    let rows = branchRows(module)
    var environment = buildMemoryEnvironment(module)
    environment.memoryCount = 0
    require(full(module, rows, environment, false).satisfied(), "missing-memory forgery preceding relation")
    require(not full(module, rows, environment).satisfied(), "coherent missing-memory forgery")
    inc forgeries
  block:
    var module = fixture(Instr(op: opV128Const), memories = 0, constants = 1)
    module.imports = @[Import(kind: ikFunc, funcTypeIdx: 0),
      Import(kind: ikMemory, memType: MemType(limits: Limits(min: 1)))]
    let rows = branchRows(module)
    var environment = buildMemoryEnvironment(module)
    require(environment.memoryCount == 1 and environment.vectorCounts[0].address == 1 and
      full(module, rows, environment).satisfied(), "imported memory and function namespace")
    inc cases
    environment.vectorCounts[0].address = 0
    require(full(module, rows, environment, false).satisfied(), "pool namespace forgery preceding relation")
    require(not full(module, rows, environment).satisfied(), "imported function/pool namespace alias")
    inc forgeries
  let header = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0]
  var vectorBytes = header & @[10'u8, 23, 1, 21, 0, 0xfd, 12]
  for i in 0..<16: vectorBytes.add byte(i)
  vectorBytes.add @[0x1a'u8, 0x0b]
  let memoryBytes = header & @[5'u8, 3, 1, 0, 1, 10, 7, 1, 5, 0, 0x3f, 0, 0x1a, 0x0b]
  let firstWitness = buildFullValidationWitness(vectorBytes, labelChecks = true)
  let secondWitness = buildFullValidationWitness(memoryBytes, labelChecks = true)
  let first = firstWitness.module
  let second = secondWitness.module
  var firstEnv = buildMemoryEnvironment(first)
  var secondEnv = buildMemoryEnvironment(second)
  let a = full(first, buildInstructionEventRows(firstWitness.events, 16), firstEnv)
  let b = full(second, buildInstructionEventRows(secondWitness.events, 16), secondEnv)
  cases += 2
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "memory/vector profile matrix")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "memory metadata Groth16 proof")
  echo "zkbuild memory metadata: PASS (", cases, " memory/alignment/lane/pool cases; ", forgeries,
    " coherent/environment forgeries rejected; ", a.constraints.len,
    " constraints/16 composed rows; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
