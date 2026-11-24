## Exact, variable-arity call typing from authenticated shared type lists.
## Composes with instruction scheduling and both validation stacks.
import r1cs, range_check, read_only_memory
import wasm_signature_environment, wasm_instruction_events, wasm_operand_events

proc constrainCallEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary: openArray[Linear], operand: OperandEventProjection,
    environment: SignatureEnvironmentWires, objects: openArray[ReadOnlyWires],
    witness: SignatureEnvironmentWitness) =
  if rows.len != primary.len or rows.len != secondary.len or rows.len != operand.flags.len or
      rows.len != witness.metadataQueries.len or rows.len != witness.operandQueries.len or
      rows.len != witness.tableQueries.len:
    raise newException(ValueError, "call-event circuit dimensions differ")
  when defined(zkbuildDynamicTypingAudit):
    let auditMarker = c.beginSourceProgram()
    var audit = DynamicTypingStageAudit(kind: 3,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags))
    for i in 0..<rows.len: audit.inputs.add copyAuditExpressions([primary[i],secondary[i]])
  var metadata, nodes, tables: seq[ReadOnlyWires]
  var params, results, pending, pushed, cleared, rootResults = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let direct = c.zeroIndicator(row.opcode-constant(0x10))
    let indirect = c.zeroIndicator(row.opcode-constant(0x11))
    let returnDirect = c.zeroIndicator(row.opcode-constant(0x12))
    let returnIndirect = c.zeroIndicator(row.opcode-constant(0x13))
    let call = direct+indirect+returnDirect+returnIndirect
    let tail = returnDirect+returnIndirect
    let indexed = indirect+returnIndirect
    let begin = c.multiply(call, flags.instructionBegin)
    let indirectBegin = c.multiply(indexed, flags.instructionBegin)
    let reset = flags.functionBegin+flags.instructionBegin
    discard c.constrainUnsigned(primary[i], 32)
    discard c.constrainUnsigned(secondary[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, primary[i], constant(0))
    c.constrain(constant(1)-flags.instructionBegin, secondary[i], constant(0))
    let metaActive = flags.functionBegin+begin
    let metaAddress = c.multiply(flags.functionBegin, row.control.operand.functionIndex.scale(scalar(2)))+
      c.multiply(begin, primary[i].scale(scalar(2))+indexed)
    let packed = c.allocate(scalar(witness.metadataQueries[i].value))
    metadata.add ReadOnlyWires(active: metaActive, address: metaAddress, value: packed)
    let heads = c.splitSignatureHeads(packed)
    rootResults = c.selectWire(flags.functionBegin, heads.results, rootResults)
    c.constrain(c.multiply(tail, flags.instructionBegin), heads.results-rootResults, constant(0))
    params = c.selectWire(reset, heads.params, params)
    results = c.selectWire(reset, heads.results, results)
    pending = c.selectWire(reset, indexed, pending)
    pushed = c.selectWire(reset, constant(0), pushed)
    cleared = c.selectWire(reset, constant(0), cleared)

    let tableValue = c.allocate(scalar(witness.tableQueries[i].value))
    tables.add ReadOnlyWires(active: indirectBegin,
      address: c.multiply(indirectBegin, secondary[i].scale(scalar(2))+constant(1)), value: tableValue)
    c.constrain(indirectBegin, tableValue-constant(5), constant(0))
    let pop = c.multiply(call, flags.operandPop)
    let indexPop = c.multiply(pop, pending)
    let argumentPop = pop-indexPop
    let push = c.multiply(call, flags.operandPush)
    let clear = c.multiply(call, flags.clear)
    let actual = row.control.operand.valueType
    let unknown = c.zeroIndicator(actual-constant(7))
    c.constrain(indexPop, constant(1)-unknown-c.zeroIndicator(actual), constant(0))
    c.constrain(pop, pushed+cleared, constant(0))
    c.constrain(push, tail+pending+cleared, constant(0))
    c.constrain(push, params, constant(0))
    let nodeValue = c.allocate(scalar(witness.operandQueries[i].value))
    when defined(zkbuildDynamicTypingAudit): audit.auxiliary.add copyAuditExpressions([packed,tableValue,nodeValue])
    nodes.add ReadOnlyWires(active: argumentPop+push,
      address: c.multiply(argumentPop, params)+c.multiply(push, results), value: nodeValue)
    let node = c.splitSignatureNode(nodeValue)
    c.constrain(argumentPop, constant(1)-unknown-c.zeroIndicator(actual-node.tag), constant(0))
    c.constrain(push, actual-node.tag, constant(0))
    params = c.selectWire(argumentPop, node.next, params)
    results = c.selectWire(push, node.next, results)
    pending = c.materialize(pending-indexPop)
    pushed = c.selectWire(push, constant(1), pushed)
    c.constrain(call, flags.controlPush+flags.controlPop, constant(0))
    c.constrain(clear, constant(1)-tail, constant(0))
    c.constrain(clear, params+pending+cleared, constant(0))
    cleared = c.materialize(cleared+clear)
    let finish = c.multiply(call, flags.instructionEnd)
    c.constrain(finish, params, constant(0))
    c.constrain(finish, pending, constant(0))
    c.constrain(finish, cleared-tail, constant(0))
    c.constrain(c.multiply(direct+indirect, flags.instructionEnd), results, constant(0))
  when defined(zkbuildDynamicTypingAudit):
    audit.program = c.endSourceProgram(auditMarker)
  c.constrainSignatureEnvironment(environment, metadata, nodes, witness)
  when defined(zkbuildDynamicTypingAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(objects, tables, witness.tables, 33, 4)
  when defined(zkbuildDynamicTypingAudit): c.dynamicTypingRecords.add audit
