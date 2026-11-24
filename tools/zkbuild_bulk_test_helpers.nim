import cps/wasm/[types, validate]
import cps/zk/[r1cs, range_check, read_only_memory, wasm_operand_events, wasm_control_events,
  wasm_instruction_events, wasm_bulk_context, wasm_memory_metadata, wasm_branch_environment]
import zkbuild_branch_test_helpers
export zkbuild_branch_test_helpers

proc bulkFixture*(code: Opcode, primary = 0'u32, secondary = 0'u32): WasmModule =
  WasmModule(startFunc: -1, dataCount: 1, types: @[FuncType()], funcTypeIdxs: @[0'u32],
    memories: @[MemType(limits: Limits(min: 1))], datas: @[DataSegment(mode: dataPassive)],
    tables: @[TableType(elemType: vtFuncRef, limits: Limits(min: 1)),
      TableType(elemType: vtExternRef, limits: Limits(min: 1))],
    elements: @[ElemSegment(mode: elemPassive, elemType: vtFuncRef),
      ElemSegment(mode: elemDeclarative, elemType: vtExternRef)],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opUnreachable), Instr(op: code, imm1: primary, imm2: secondary)]))])

proc fullBulk*(module: WasmModule, rows: seq[InstructionEventRow], environment: var BulkEnvironment,
    binding = true): Circuit =
  var memory = buildMemoryEnvironment(module)
  buildBranchTypes(module, rows, buildBranchEnvironment(module), memory = addr memory,
    bulk = addr environment, bulkBinding = binding)

proc buildBulkUnit*(code: uint64, primary, secondary: uint64, memoryCount: uint32,
    environment: BulkEnvironment, objects: seq[ReadOnlyEntry]): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let op = result.publicInput(scalar(code))
  let p = result.publicInput(scalar(primary))
  let s = result.publicInput(scalar(secondary))
  let memory = result.publicInput(scalar(memoryCount))
  var env = BulkEnvironmentWires(hasDataCount: result.publicInput(scalar(ord(environment.hasDataCount))),
    dataCount: result.publicInput(scalar(environment.dataCount)), declaredDataCount: result.publicInput(scalar(environment.declaredDataCount)))
  for entry in environment.elements:
    env.elements.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  var tables: seq[ReadOnlyWires]
  for entry in objects:
    tables.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  let row = InstructionEventWires(opcode: op)
  let actual = @[InstructionEventRow(opcode: uint16(code and 0xffff), control: ControlEventRow(operand:
    OperandEventRow(kind: uint8(ord(veInstructionBegin)))))]
  let witness = buildBulkContextWitness(environment, objects, actual,
    [uint32(primary and 0xffffffff'u64)], [uint32(secondary and 0xffffffff'u64)])
  let projection = OperandEventProjection(flags: @[OperandEventFlags(instructionBegin: constant(1))])
  result.constrainBulkContext([row], [p], [s], projection, memory, env, tables, witness)
