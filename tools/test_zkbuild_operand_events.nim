import std/[random, tables]
import cps/wasm/[types, binary, validate]
import cps/zk/[r1cs, prover, memory_consistency, wasm_operand_events]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc event(kind: ValidationEventKind, height: uint32, value = svUnknown,
    floor = 0'u32, unreachable = false, polymorphic = false, functionIndex = 0'u32): OperandEventRow =
  OperandEventRow(kind: uint8(ord(kind)), height: height, valueType: uint8(ord(value)),
    floor: floor, unreachable: unreachable, polymorphic: polymorphic, functionIndex: functionIndex)

proc wires(c: var Circuit, rows: openArray[OperandEventRow]): seq[OperandEventWires] =
  for row in rows:
    result.add OperandEventWires(kind: c.publicInput(scalar(row.kind)),
      functionIndex: c.publicInput(scalar(row.functionIndex)), height: c.publicInput(scalar(row.height)),
      floor: c.publicInput(scalar(row.floor)), valueType: c.publicInput(scalar(row.valueType)),
      polymorphic: c.publicInput(scalar(ord(row.polymorphic))),
      unreachable: c.publicInput(scalar(ord(row.unreachable))))

proc build(rows: openArray[OperandEventRow], memory = true): Circuit =
  result = initCircuit()
  let events = result.wires(rows)
  let accesses = result.constrainOperandEvents(events)
  if memory:
    var values: seq[MemoryAccess]
    try: values = operandEventAccesses(rows)
    except ValueError: values = newSeq[MemoryAccess](rows.len)
    discard result.constrainMemory(accesses, buildMemoryWitness(values), 64, 3)

proc valid(rows: openArray[OperandEventRow], memory = true): bool =
  var before = 0'u64
  var padded = false
  var ram = initTable[uint64, uint64]()
  for row in rows:
    let padding = row.kind == OperandPaddingKind
    if row.kind > uint8(ord(veFunctionEnd)) and not padding: return false
    if padded and not padding: return false
    padded = padding
    if row.valueType > 7: return false
    let push = row.kind == uint8(ord(veOperandPush))
    let pop = row.kind == uint8(ord(veOperandPop))
    if row.polymorphic and (not pop or row.valueType != 7 or
        before != uint64(row.floor) or not row.unreachable): return false
    if not push and not pop and row.valueType != 7: return false
    if padding and (row.functionIndex != 0 or row.floor != 0 or row.unreachable): return false
    if push:
      if uint64(row.height) != before+1: return false
    elif pop and not row.polymorphic:
      if before <= uint64(row.floor) or uint64(row.height)+1 != before: return false
    elif row.kind == uint8(ord(veUnreachable)):
      if uint64(row.floor) > before or row.height != row.floor: return false
    elif uint64(row.height) != before: return false
    if row.kind in [uint8(ord(veFunctionBegin)), uint8(ord(veFunctionEnd))] and row.height != 0:
      return false
    if memory and (push or (pop and not row.polymorphic)):
      let slot = uint64(row.height)-uint64(ord(push))
      let address = (uint64(row.functionIndex) shl 32) or slot
      if push: ram[address] = row.valueType
      elif not ram.hasKey(address) or ram[address] != uint64(row.valueType): return false
    before = row.height
  before == 0

proc main() =
  let example = @[
    event(veFunctionBegin, 0), event(veOperandPush, 1, svI32),
    event(veOperandPush, 2, svI64), event(veOperandPop, 1, svI64),
    event(veOperandPop, 0, svI32), event(veUnreachable, 0),
    event(veOperandPop, 0, unreachable = true, polymorphic = true), event(veFunctionEnd, 0)]
  let reference = build(example)
  require(valid(example) and reference.satisfied(), "operand event binding")
  var mutations = 0
  for index in 1..reference.publicCount:
    var changed = reference
    changed.values = @(reference.values)
    # The context's unreachable flag is irrelevant outside virtual pops.
    # Test its Boolean range rather than rejecting a permitted flag change.
    changed.values[index] += scalar(if index mod 7 == 0: 2 else: 1)
    require(not changed.satisfied(), "changed operand-event public field " & $index)
    inc mutations
  var malformed: seq[seq[OperandEventRow]]
  template changed(index: int, field: untyped, value: untyped) =
    block:
      var rows = @example
      rows[index].field = value
      malformed.add rows
  changed(1, height, 0'u32)
  changed(3, valueType, uint8(ord(svF32)))
  changed(3, floor, 2'u32)
  changed(3, functionIndex, 1'u32)
  changed(6, unreachable, false)
  changed(6, floor, 1'u32)
  changed(6, valueType, uint8(ord(svI32)))
  changed(1, polymorphic, true)
  changed(5, height, 1'u32)
  changed(5, floor, 1'u32)
  changed(0, kind, uint8(ord(veUnsupported)))
  changed(7, kind, 14'u8)
  changed(0, valueType, uint8(ord(svI32)))
  changed(2, valueType, 8'u8)
  changed(4, height, uint32.high)
  for rows in malformed:
    require(not valid(rows) and not build(rows).satisfied(), "coherent malformed event trace")

  var padding = @example
  padding[7] = OperandEventRow(kind: OperandPaddingKind, valueType: 7)
  require(valid(padding) and build(padding).satisfied(), "canonical padding")
  padding[7].floor = 1
  require(not valid(padding) and not build(padding).satisfied(), "noncanonical padding")
  padding = @example
  padding[5] = OperandEventRow(kind: OperandPaddingKind, valueType: 7)
  require(not valid(padding) and not build(padding).satisfied(), "events after padding")

  var rng = initRand(0x45564e54)
  var cases = 0
  let empty = newSeq[OperandEventRow](32)
  var emptyRows = empty
  for row in emptyRows.mitems: row = OperandEventRow(kind: OperandPaddingKind, valueType: 7)
  let shape = build(emptyRows)
  for sample in 0..<40:
    var rows: seq[OperandEventRow]
    var stack: seq[StackVal]
    while rows.len < 24:
      if stack.len == 0 or rng.rand(1) == 0:
        let value = StackVal(rng.rand(7))
        stack.add value
        rows.add event(veOperandPush, uint32(stack.len), value, functionIndex = uint32(sample))
      else:
        let value = stack.pop()
        rows.add event(veOperandPop, uint32(stack.len), value, functionIndex = uint32(sample))
    if stack.len > 0:
      rows.add event(veUnreachable, 0, functionIndex = uint32(sample))
    while rows.len < 32: rows.add OperandEventRow(kind: OperandPaddingKind, valueType: 7)
    let circuit = build(rows)
    require(valid(rows) and circuit.satisfied() and circuit.sameShape(shape), "random operand transcript")
    inc cases
    for row in rows.mitems:
      if row.kind == uint8(ord(veOperandPop)):
        row.valueType = (row.valueType+1) mod 8
        break
    require(build(rows).satisfied() == valid(rows), "random changed pop value")

  # Real validator events, including nested control contexts and virtual pops.
  var module = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: decodeExprBytes(@[0x02'u8, 0x7e, 0x42, 7, 0x0b, 0x1a,
      0x02, 0x7e, 0, 0x0b, 0x0b], optimize = false))])
  let rows = buildOperandEventRows(traceModuleValidation(module))
  require(valid(rows) and build(rows).satisfied(), "real WASM validation transcript")

  let key = setup(reference)
  let proof = encodeProof(prove(key, reference))
  require(decodeAndVerify(key.verificationKey, proof,
    reference.values[1..reference.publicCount]), "operand-event Groth16 proof")
  echo "zkbuild operand events: PASS (", cases, " random traces; ", malformed.len,
    " coherent forgeries; ", mutations, " field mutations; ", rows.len,
    " real WASM rows; ", reference.constraints.len, " constraints/8 rows; ", proof.len, "-byte proof)"

main()
