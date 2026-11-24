import std/random
import cps/wasm/[types, binary, validate]
import cps/zk/[r1cs, prover, memory_consistency, wasm_operand_events, wasm_control_events]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc event(kind: ValidationEventKind, height, depth: uint32, value = svUnknown,
    floor = 0'u32, unreachable = false, polymorphic = false,
    functionIndex = 0'u32): ControlEventRow =
  ControlEventRow(depth: depth, operand: OperandEventRow(kind: uint8(ord(kind)),
    functionIndex: functionIndex, height: height, floor: floor, valueType: uint8(ord(value)),
    unreachable: unreachable, polymorphic: polymorphic))

proc padded(rows: seq[ControlEventRow], size: int): seq[ControlEventRow] =
  result = rows
  while result.len < size:
    result.add ControlEventRow(operand: OperandEventRow(kind: OperandPaddingKind, valueType: 7))

proc build(rows: openArray[ControlEventRow], first = 0'u32, control = true): Circuit =
  result = initCircuit()
  let firstFunction = result.publicInput(scalar(first))
  var wires: seq[ControlEventWires]
  for row in rows:
    let e = row.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)),
      height: result.publicInput(scalar(e.height)), floor: result.publicInput(scalar(e.floor)),
      valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))),
      unreachable: result.publicInput(scalar(ord(e.unreachable))))
    wires.add ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.depth)))
  var witness: StackMemoryWitness
  try: witness = buildStackMemoryWitness(rows)
  except ValueError:
    witness.operand = buildMemoryWitness(newSeq[MemoryAccess](rows.len))
    witness.control = buildMemoryWitness(newSeq[MemoryAccess](2*rows.len))
  if control:
    result.constrainValidationStacks(wires, witness, firstFunction)
  else:
    var operands: seq[OperandEventWires]
    for row in wires: operands.add row.operand
    let access = result.constrainOperandEvents(operands)
    discard result.constrainMemory(access, witness.operand, 64, 3)

proc valid(rows: openArray[ControlEventRow], first = 0'u32): bool =
  ## Independent semantic oracle uses actual LIFO stacks, no RAM sort or route.
  var controls: seq[tuple[floor: int, unreachable: bool]]
  var operands: seq[uint8]
  var open = false
  var padding = false
  var nextFunction = uint64(first)
  for row in rows:
    let e = row.operand
    let pad = e.kind == OperandPaddingKind
    if padding and not pad: return false
    padding = pad
    if e.valueType > 7: return false
    let floor = if controls.len > 0: controls[^1].floor else: 0
    let unreachable = controls.len > 0 and controls[^1].unreachable
    if uint64(e.floor) != uint64(floor) or e.unreachable != unreachable: return false
    if pad:
      if open or e.functionIndex != 0 or e.valueType != 7 or e.polymorphic: return false
    else:
      if uint64(e.functionIndex) != nextFunction or e.kind > uint8(ord(veFunctionEnd)):
        return false
      if e.kind == uint8(ord(veFunctionBegin)):
        if open: return false
        open = true
      elif not open: return false
      if e.kind notin [uint8(ord(veOperandPush)), uint8(ord(veOperandPop))] and e.valueType != 7:
        return false
      if e.polymorphic and e.kind != uint8(ord(veOperandPop)): return false
      case ValidationEventKind(e.kind)
      of veOperandPush:
        if controls.len == 0: return false
        operands.add e.valueType
      of veOperandPop:
        if controls.len == 0: return false
        if e.polymorphic:
          if not unreachable or operands.len != floor or e.valueType != 7: return false
        else:
          if operands.len <= floor or operands[^1] != e.valueType: return false
          operands.setLen(operands.len-1)
      of veControlPush:
        controls.add (operands.len, false)
      of veControlPop:
        if controls.len == 0 or operands.len != floor: return false
        controls.setLen(controls.len-1)
      of veUnreachable:
        if controls.len == 0 or operands.len < floor: return false
        operands.setLen(floor)
        controls[^1].unreachable = true
      of veFunctionBegin:
        if operands.len != 0 or controls.len != 0: return false
      of veFunctionEnd:
        if operands.len != 0 or controls.len != 0: return false
        open = false
        inc nextFunction
      else: discard
    if uint64(row.depth) != uint64(controls.len) or uint64(e.height) != uint64(operands.len):
      return false
  not open and operands.len == 0 and controls.len == 0

proc main() =
  let example = padded(@[
    event(veFunctionBegin, 0, 0), event(veControlPush, 0, 1),
    event(veOperandPush, 1, 1, svI32), event(veControlPush, 1, 2),
    event(veUnreachable, 1, 2, floor = 1),
    event(veOperandPop, 1, 2, floor = 1, unreachable = true, polymorphic = true),
    event(veControlPop, 1, 1, floor = 1, unreachable = true),
    event(veOperandPop, 0, 1, svI32), event(veControlPop, 0, 0),
    event(veFunctionEnd, 0, 0)], 16)
  let reference = build(example)
  require(valid(example) and reference.satisfied(), "nested authenticated control stack")
  var malformed: seq[seq[ControlEventRow]]
  template change(index: int, field: untyped, value: untyped) =
    block:
      var rows = @example
      rows[index].operand.field = value
      malformed.add rows
  change(5, unreachable, false)
  change(3, floor, 1'u32)
  change(7, unreachable, true) # child reachability must not leak into parent
  change(7, floor, 1'u32)
  change(5, functionIndex, 1'u32)
  change(9, kind, uint8(ord(veInstructionEnd))) # no function end
  change(2, kind, uint8(ord(veFunctionBegin)))
  change(0, kind, uint8(ord(veFunctionEnd)))
  change(7, kind, OperandPaddingKind)
  var missingClear = @example
  missingClear[4].operand.kind = uint8(ord(veInstructionEnd))
  require(build(missingClear, control = false).satisfied(), "missing-clear forgery must pass operand-only checks")
  malformed.add missingClear # virtual pop guards are coherent, but no frame write set unreachable
  var wrongReset = @example
  for i in 4..6:
    wrongReset[i].operand.floor = 0
    wrongReset[i].operand.height = 0
  wrongReset[7] = event(veInstructionEnd, 0, 1)
  require(build(wrongReset, control = false).satisfied(), "wrong-floor forgery must pass operand-only checks")
  malformed.add wrongReset # coherently reset through the child frame's actual floor
  var badDepth = @example
  badDepth[3].depth = 1
  malformed.add badDepth
  for rows in malformed:
    require(not valid(rows) and not build(rows).satisfied(), "forged control transcript accepted")

  var imported = @example
  for row in imported.mitems:
    if row.operand.kind != OperandPaddingKind: row.operand.functionIndex = 3
  require(valid(imported, 3) and build(imported, 3).satisfied(), "imported function namespace")
  require(not build(imported).satisfied(), "wrong imported-function boundary")
  for row in imported.mitems:
    if row.operand.kind != OperandPaddingKind: row.operand.functionIndex = uint32.high
  require(valid(imported, uint32.high) and build(imported, uint32.high).satisfied(),
    "last uint32 function namespace")

  # Two bodies with one namespace transition and root-frame slot reuse.
  let small = @[
    event(veFunctionBegin, 0, 0), event(veControlPush, 0, 1),
    event(veOperandPush, 1, 1, svI64), event(veOperandPop, 0, 1, svI64),
    event(veControlPop, 0, 0), event(veFunctionEnd, 0, 0)]
  var two = @small
  for row in small:
    var next = row
    next.operand.functionIndex = 1
    two.add next
  two = padded(two, 16)
  require(valid(two) and build(two).satisfied(), "two function bodies")
  for i in small.len..<2*small.len: two[i].operand.functionIndex = 2
  require(not valid(two) and not build(two).satisfied(), "skipped function index")
  for i in 0..<small.len: two[i].operand.functionIndex = uint32.high
  for i in small.len..<2*small.len: two[i].operand.functionIndex = 0
  require(not valid(two, uint32.high) and not build(two, uint32.high).satisfied(),
    "function namespace wraps modulo uint32")

  # Generate legal stack histories independently, then compare fixed matrices.
  var rng = initRand(0x4354524c)
  var cases = 0
  let shape = build(padded(@[], 32))
  for sample in 0..<24:
    var rows = @[event(veFunctionBegin, 0, 0), event(veControlPush, 0, 1)]
    var stack: seq[StackVal]
    var frames = @[(floor: 0, unreachable: false)]
    while rows.len < 20:
      let top = frames[^1]
      let choice = rng.rand(5)
      if choice == 0 and frames.len < 4:
        rows.add event(veControlPush, uint32(stack.len), uint32(frames.len+1),
          floor = uint32(top.floor), unreachable = top.unreachable)
        frames.add (stack.len, false)
      elif choice == 1:
        rows.add event(veUnreachable, uint32(top.floor), uint32(frames.len),
          floor = uint32(top.floor), unreachable = top.unreachable)
        stack.setLen(top.floor)
        frames[^1].unreachable = true
      elif choice == 2 and stack.len == top.floor and top.unreachable:
        rows.add event(veOperandPop, uint32(stack.len), uint32(frames.len), floor = uint32(top.floor),
          unreachable = true, polymorphic = true)
      elif choice == 3 and stack.len > top.floor:
        let value = stack.pop()
        rows.add event(veOperandPop, uint32(stack.len), uint32(frames.len), value,
          floor = uint32(top.floor), unreachable = top.unreachable)
      elif choice == 4 and frames.len > 1 and stack.len == top.floor:
        rows.add event(veControlPop, uint32(stack.len), uint32(frames.len-1), floor = uint32(top.floor),
          unreachable = top.unreachable)
        frames.setLen(frames.len-1)
      else:
        let value = StackVal(rng.rand(7))
        stack.add value
        rows.add event(veOperandPush, uint32(stack.len), uint32(frames.len), value,
          floor = uint32(top.floor), unreachable = top.unreachable)
    while frames.len > 0:
      let top = frames[^1]
      if stack.len > top.floor:
        rows.add event(veUnreachable, uint32(top.floor), uint32(frames.len), floor = uint32(top.floor),
          unreachable = top.unreachable)
        stack.setLen(top.floor)
        frames[^1].unreachable = true
      rows.add event(veControlPop, uint32(stack.len), uint32(frames.len-1), floor = uint32(top.floor),
        unreachable = frames[^1].unreachable)
      frames.setLen(frames.len-1)
    rows.add event(veFunctionEnd, 0, 0)
    rows = padded(rows, 32)
    let circuit = build(rows)
    require(valid(rows) and circuit.satisfied() and circuit.sameShape(shape), "random control frames")
    inc cases

  let module = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtI64])], funcTypeIdxs: @[0'u32, 0],
    codes: @[FuncBody(code: decodeExprBytes(@[0x02'u8, 0x7e, 0x42, 7, 0x0b, 0x1a,
      0x02, 0x7e, 0, 0x0b, 0x0b], optimize = false)),
      FuncBody(code: decodeExprBytes(@[0x42'u8, 9, 0x0b], optimize = false))])
  let real = buildControlEventRows(traceModuleValidation(module))
  require(valid(real) and build(real).satisfied(), "real WASM control frames")

  let proofCircuit = build(padded(small, 8))
  let key = setup(proofCircuit)
  require(key.domainSize <= 8192, "eight-row stack proof exceeds its QAP budget")
  let proof = encodeProof(prove(key, proofCircuit))
  require(decodeAndVerify(key.verificationKey, proof,
    proofCircuit.values[1..proofCircuit.publicCount]), "authenticated stack proof")
  for index in 0..<proofCircuit.publicCount:
    var changed = proofCircuit.values[1..proofCircuit.publicCount]
    changed[index] += scalar(1)
    require(not decodeAndVerify(key.verificationKey, proof, changed), "stack proof public substitution")
  echo "zkbuild control events: PASS (", cases, " random traces; ", malformed.len,
    " coherent forgeries; ", real.len, " real WASM rows; ", proofCircuit.constraints.len,
    " constraints/8 rows; QAP ", key.domainSize, "; ", proof.len, "-byte proof; ",
    proofCircuit.publicCount, " public substitutions rejected)"

main()
