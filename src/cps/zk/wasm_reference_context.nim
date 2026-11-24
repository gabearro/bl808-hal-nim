## Exact ref.func declaration membership. The initializer bounds also establish
## function existence; raw-binary construction of this table remains separate.
import ../wasm/[types, validate, reference_context]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events

type
  ReferenceEnvironment* = object
    functionCount*: uint32
    declarations*: seq[ReadOnlyEntry]
  ReferenceEnvironmentWires* = object
    functionCount*: Linear
    declarations*: seq[ReadOnlyWires]
  ReferenceContextWitness* = object
    declarations*: MemoryWitness

proc buildReferenceEnvironment*(module: WasmModule, declarationCapacity = 0): ReferenceEnvironment =
  var functions = uint64(module.funcTypeIdxs.len)
  for item in module.imports:
    if item.kind == ikFunc: inc functions
  if declarationCapacity < 0 or functions > uint64(high(uint32)):
    raise newException(ValueError, "invalid reference context dimensions")
  result.functionCount = uint32(functions)
  for index in declaredFunctionReferences(module):
    result.declarations.add ReadOnlyEntry(active: true, address: uint64(index), value: 1)
  if declarationCapacity != 0:
    if result.declarations.len > declarationCapacity: raise newException(ValueError, "reference context profile overflow")
    result.declarations.setLen(declarationCapacity)

proc buildReferenceContextWitness*(environment: ReferenceEnvironment,
    rows: openArray[InstructionEventRow], primary: openArray[uint32]): ReferenceContextWitness =
  if rows.len != primary.len: raise newException(ValueError, "reference witness dimensions differ")
  var queries: seq[ReadOnlyEntry]
  for i, row in rows:
    let active = row.control.operand.kind == uint8(ord(veInstructionBegin)) and row.opcode == uint16(ord(opRefFunc))
    queries.add(if active: ReadOnlyEntry(active: true, address: uint64(primary[i]), value: 1) else: ReadOnlyEntry())
  result.declarations = buildReadOnlyWitness(environment.declarations, queries)

proc constrainReferenceContext*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary: openArray[Linear], operand: OperandEventProjection,
    environment: ReferenceEnvironmentWires, witness: ReferenceContextWitness) =
  if rows.len == 0 or rows.len != primary.len or rows.len != operand.flags.len:
    raise newException(ValueError, "reference circuit dimensions differ")
  when defined(zkbuildRuntimeContextAudit):
    let marker = c.beginSourceProgram()
  discard c.constrainUnsigned(environment.functionCount, 32)
  for entry in environment.declarations:
    c.constrain(entry.active, entry.value-constant(1), constant(0))
    let gap = c.multiply(entry.active, environment.functionCount-entry.address-constant(1))
    discard c.constrainUnsigned(gap, 32)
  var queries: seq[ReadOnlyWires]
  for i, row in rows:
    discard c.constrainUnsigned(row.opcode, 16)
    discard c.constrainUnsigned(primary[i], 32)
    let begin = operand.flags[i].instructionBegin
    c.constrain(constant(1)-begin, primary[i], constant(0))
    let active = c.multiply(begin, c.zeroIndicator(row.opcode-constant(ord(opRefFunc))))
    queries.add ReadOnlyWires(active: active, address: c.multiply(active, primary[i]), value: active)
  when defined(zkbuildRuntimeContextAudit):
    var audit = DynamicTypingStageAudit(kind: 2,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      auxiliary: @[copyAuditExpressions([environment.functionCount])],program: c.endSourceProgram(marker),banks: @[c.readOnlyRecords.len])
    for value in primary: audit.inputs.add copyAuditExpressions([value])
    c.runtimeContextRecords.add audit
  c.constrainReadOnly(environment.declarations, queries, witness.declarations, 32, 1)
