## WebAssembly module validation
## Implements the type checking algorithm from the spec:
## - Operand type stack simulation
## - Control frame stack (block/loop/if tracking)
## - Stack polymorphism after unreachable/br/return
## - All instruction typing rules for MVP + bulk memory + reference types
## - Module-level validation (imports, exports, limits, globals)

import ./types
import ./numeric_typing
import ./static_typing
import ./instruction_metadata
import ./reference_context
import ./module_rules
import ./block_types

when defined(bl808lp) and defined(bl808WasmTrace):
  import bl808/mmio

type
  ValidationError* = ModuleValidationError

  # Value on the operand type stack (None = polymorphic/unknown after unreachable)
  StackVal* = enum
    svI32
    svI64
    svF32
    svF64
    svV128
    svFuncRef
    svExternRef
    svUnknown  # Bottom type — matches anything (after unreachable)

when defined(wasmFunctionReferences):
  type OperandType = object
    lane: StackVal
    reference: CoreReferenceType
else:
  type OperandType = StackVal

type
  ValidationEventKind* = enum
    veFunctionBegin, veInstructionBegin, veOperandPush, veOperandPop,
    veControlPush, veControlPop, veUnreachable, veInstructionEnd, veFunctionEnd,
    veLabelCheck, veUnsupported

  ValidationEvent* = object
    ## Linear witness events. Full stacks are not copied for each instruction.
    kind*: ValidationEventKind
    functionIndex*, instructionIndex*: uint32
    opcode*: Opcode
    operandHeight*, controlHeight*: int
    valueType*: StackVal
    polymorphic*: bool
    frameOpcode*: Opcode
    frameHeight*: int
    frameUnreachable*: bool
    startTypes*, endTypes*: seq[StackVal]

  CtrlFrame = object
    opcode: Opcode          # block, loop, if
    startTypes: seq[OperandType]
    endTypes: seq[OperandType]
    height: int             # operand stack height at entry
    unreachable: bool       # after unreachable/br/return/br_table

  ValidationContext = object
    types: seq[FuncType]
    funcs: seq[FuncType]      # type of each function (imports + internal)
    declaredReferences: seq[uint32]
    tables: seq[TableType]
    mems: seq[MemType]
    globals: seq[GlobalType]
    locals: seq[ValType]
    localDecls: seq[LocalDecl]
    localEnds: seq[uint64]
    localCount: uint64
    labels: seq[CtrlFrame]    # control frame stack
    operands: seq[OperandType]
    when defined(wasmFunctionReferences):
      signature: FuncType
      functionTypeIndices: seq[uint32]
    numImportFuncs: int
    numImportGlobals: int
    vectorConstants: int
    trace: ptr seq[ValidationEvent]
    labelChecks, catchChecks: bool
    functionIndex, instructionIndex: uint32
    opcode: Opcode

proc lane(value: OperandType): StackVal {.inline.} =
  when defined(wasmFunctionReferences): value.lane
  else: value

proc operand(lane: StackVal, reference = CoreReferenceType()): OperandType {.inline.} =
  when defined(wasmFunctionReferences): OperandType(lane: lane, reference: reference)
  else: lane

proc matchesOperand(actual, expected: OperandType): bool =
  if actual.lane == svUnknown or expected.lane == svUnknown: return true
  if actual.lane != expected.lane: return false
  when defined(wasmFunctionReferences):
    if expected.lane in {svFuncRef, svExternRef}:
      return matchesCoreReference(actual.reference, expected.reference)
  true

proc matchesOperands(actual, expected: openArray[OperandType]): bool =
  if actual.len != expected.len: return false
  for i, value in actual:
    if not matchesOperand(value, expected[i]): return false
  true

proc emitEvent(ctx: ValidationContext, kind: ValidationEventKind,
    valueType = svUnknown, polymorphic = false) =
  if ctx.trace.isNil: return
  ctx.trace[].add ValidationEvent(kind: kind, functionIndex: ctx.functionIndex,
    instructionIndex: ctx.instructionIndex, opcode: ctx.opcode,
    operandHeight: ctx.operands.len, controlHeight: ctx.labels.len,
    valueType: valueType, polymorphic: polymorphic)

proc emitFrame(ctx: ValidationContext, kind: ValidationEventKind, frame: CtrlFrame) =
  if ctx.trace.isNil: return
  var event = ValidationEvent(kind: kind, functionIndex: ctx.functionIndex,
    instructionIndex: ctx.instructionIndex, opcode: ctx.opcode,
    operandHeight: ctx.operands.len, controlHeight: ctx.labels.len,
    valueType: svUnknown,
    frameOpcode: frame.opcode, frameHeight: frame.height,
    frameUnreachable: frame.unreachable)
  for value in frame.startTypes: event.startTypes.add value.lane
  for value in frame.endTypes: event.endTypes.add value.lane
  ctx.trace[].add event

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc valToStack(vt: ValType): StackVal =
  case vt
  of vtI32: svI32
  of vtI64: svI64
  of vtF32: svF32
  of vtF64: svF64
  of vtV128: svV128
  of vtFuncRef: svFuncRef
  of vtExternRef: svExternRef

proc parameterOperands(ft: FuncType): seq[OperandType] =
  result = newSeqOfCap[OperandType](ft.params.len)
  for i, vt in ft.params:
    when defined(wasmFunctionReferences):
      result.add(operand(valToStack(vt), ft.coreParamReference(i)))
    else: result.add(valToStack(vt))

proc resultOperands(ft: FuncType): seq[OperandType] =
  result = newSeqOfCap[OperandType](ft.results.len)
  for i, vt in ft.results:
    when defined(wasmFunctionReferences):
      result.add(operand(valToStack(vt), ft.coreResultReference(i)))
    else: result.add(valToStack(vt))

proc validErr(msg: string) =
  raise newException(ValidationError, msg)

proc localDeclaration(ctx: ValidationContext, index: uint32): LocalDecl =
  if uint64(index) >= ctx.localCount: validErr("local index out of range")
  if uint64(index) < uint64(ctx.locals.len):
    return LocalDecl(count: 1, valType: ctx.locals[int(index)])
  var low = 0
  var limit = ctx.localEnds.len
  while low < limit:
    let middle = low+(limit-low) div 2
    if ctx.localEnds[middle] <= uint64(index): low = middle+1
    else: limit = middle
  ctx.localDecls[low]

proc localType(ctx: ValidationContext, index: uint32): ValType {.inline.} =
  ctx.localDeclaration(index).valType

proc validateStage(code: uint32) {.inline.} =
  when defined(bl808lp) and defined(bl808WasmTrace):
    regWrite(0x40002E84'u, code)
  else:
    discard code

# ---------------------------------------------------------------------------
# Operand stack operations
# ---------------------------------------------------------------------------

proc pushOp(ctx: var ValidationContext, value: OperandType) =
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and value.lane in {svFuncRef, svExternRef} and
        not value.reference.isSharedCoreReference():
      validErr("shared core function uses an unshared reference")
  ctx.operands.add(value)
  ctx.emitEvent(veOperandPush, value.lane)

when defined(wasmFunctionReferences):
  proc pushOp(ctx: var ValidationContext, lane: StackVal) {.inline.} =
    ctx.pushOp(operand(lane))

proc pushOps(ctx: var ValidationContext, svs: seq[OperandType]) =
  for sv in svs:
    ctx.pushOp(sv)

proc popOp(ctx: var ValidationContext): OperandType =
  if ctx.labels.len > 0:
    let frame = ctx.labels[^1]
    if ctx.operands.len == frame.height:
      if frame.unreachable:
        ctx.emitEvent(veOperandPop, svUnknown, polymorphic = true)
        return operand(svUnknown)
      validErr("type mismatch: operand stack underflow")
  elif ctx.operands.len == 0:
    validErr("type mismatch: operand stack underflow")
  result = ctx.operands.pop()
  ctx.emitEvent(veOperandPop, result.lane)

proc popExpect(ctx: var ValidationContext, expected: OperandType): OperandType =
  let actual = ctx.popOp()
  if actual.lane == svUnknown: return expected
  if not matchesOperand(actual, expected):
    validErr("type mismatch: expected " & $expected.lane & ", got " & $actual.lane)
  actual

when defined(wasmFunctionReferences):
  proc popExpect(ctx: var ValidationContext, expected: StackVal): OperandType {.inline.} =
    ctx.popExpect(operand(expected))

proc popOps(ctx: var ValidationContext, expected: seq[OperandType]): seq[OperandType] =
  result = newSeq[OperandType](expected.len)
  for i in countdown(expected.len - 1, 0):
    result[i] = ctx.popExpect(expected[i])

when defined(wasmFunctionReferences):
  proc functionReference(ctx: ValidationContext, tag: uint32, nonNull = false,
                         sharedAbstract = false): CoreReferenceType =
    if tag notin [0'u32, WasmNoFuncHeapTag]:
      return ctx.types[tag.int - 1].coreFunctionReference(nonNull)
    result = CoreReferenceType(member: tag, nonNull: nonNull)
    when defined(wasmSharedCoreTypes): result.sharedAbstract = sharedAbstract

proc localOperand(ctx: ValidationContext, index: uint32): OperandType =
  let local = ctx.localDeclaration(index)
  let lane = valToStack(local.valType)
  when defined(wasmFunctionReferences):
    let reference = if index.uint64 < ctx.locals.len.uint64:
        ctx.signature.coreParamReference(index.int)
      else: ctx.functionReference(local.functionType, sharedAbstract =
        (when defined(wasmSharedCoreTypes): local.sharedReference else: false))
    operand(lane, reference)
  else: lane

proc pushLocal(ctx: var ValidationContext, index: uint32) =
  ctx.pushOp(ctx.localOperand(index))

proc popLocal(ctx: var ValidationContext, index: uint32) =
  discard ctx.popExpect(ctx.localOperand(index))

# ---------------------------------------------------------------------------
# Control frame operations
# ---------------------------------------------------------------------------

proc pushCtrl(ctx: var ValidationContext, op: Opcode,
              startTypes, endTypes: seq[OperandType]) =
  let frame = CtrlFrame(
    opcode: op,
    startTypes: startTypes,
    endTypes: endTypes,
    height: ctx.operands.len,
    unreachable: false,
  )
  ctx.labels.add(frame)
  ctx.emitFrame(veControlPush, frame)
  ctx.pushOps(startTypes)

proc popCtrl(ctx: var ValidationContext): CtrlFrame =
  if ctx.labels.len == 0:
    validErr("control frame stack underflow")
  let frame = ctx.labels[^1]
  discard ctx.popOps(frame.endTypes)
  if ctx.operands.len != frame.height:
    validErr("type mismatch: stack height mismatch at end of block (expected " &
             $frame.height & ", got " & $ctx.operands.len & ")")
  # Reset stack to frame entry height (discard any excess from unreachable polymorphism)
  ctx.operands.setLen(frame.height)
  ctx.labels.setLen(ctx.labels.len - 1)
  ctx.emitFrame(veControlPop, frame)
  frame

proc labelTypes(frame: CtrlFrame): seq[OperandType] =
  ## For loop, the branch target expects startTypes (restart).
  ## For block/if, the branch target expects endTypes (exit).
  if frame.opcode == opLoop:
    frame.startTypes
  else:
    frame.endTypes

proc validateConditionalTarget(ctx: var ValidationContext, depth: uint32) =
  if depth.uint64 >= ctx.labels.len.uint64:
    validErr("br_if: invalid label depth " & $depth)
  let frame = ctx.labels[ctx.labels.len - 1 - depth.int]
  let vals = ctx.popOps(frame.labelTypes)
  ctx.pushOps(vals)

proc setUnreachable(ctx: var ValidationContext) =
  if ctx.labels.len > 0:
    ctx.operands.setLen(ctx.labels[^1].height)
    ctx.labels[^1].unreachable = true
    ctx.emitFrame(veUnreachable, ctx.labels[^1])

# ---------------------------------------------------------------------------
# Block type resolution
# ---------------------------------------------------------------------------

proc resolveBlockType(ctx: ValidationContext, bt: BlockType): (seq[OperandType], seq[OperandType]) =
  case bt.kind
  of btkEmpty:
    (@[], @[])
  of btkValType:
    (@[], @[operand(valToStack(bt.valType))])
  of btkTypeIdx:
    if uint64(bt.typeIdx) >= uint64(ctx.types.len):
      validErr("invalid block type index: " & $bt.typeIdx)
    let idx = int(bt.typeIdx)
    if uint64(idx) >= uint64(ctx.types.len):
      validErr("invalid block type index: " & $idx)
    let ft = ctx.types[int(idx)]
    when defined(wasmSharedCoreTypes):
      if ctx.signature.shared and not ft.shared:
        validErr("shared core function uses an unshared block type")
    (ft.parameterOperands(), ft.resultOperands())

# ---------------------------------------------------------------------------
# Instruction validation
# ---------------------------------------------------------------------------

proc getBlockType(expression: Expr, pc: int): BlockType =
  try: block_types.resolveBlockType(expression, pc)
  except ValueError as error: validErr(error.msg); BlockType(kind: btkEmpty)

proc exceptionTagType(module: WasmModule, index: uint32): FuncType =
  let typeIndex = module.tagTypeIndex(index)
  if typeIndex < 0: validErr("invalid exception tag index: " & $index)
  if uint64(typeIndex) >= uint64(module.types.len): validErr("exception tag: invalid type index")
  result = module.types[int(typeIndex)]
  if result.results.len != 0: validErr("exception tag type must have no results")

when defined(wasmSharedCoreTypes):
  proc requireSharedCallee(ctx: ValidationContext, signature: FuncType) =
    if ctx.signature.shared and not signature.shared:
      validErr("shared core function calls an unshared function type")

proc tableType(ctx: ValidationContext, index: uint32, op: static string): TableType =
  if index.uint64 >= ctx.tables.len.uint64: validErr(op & ": invalid table index")
  result = ctx.tables[index.int]
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and not result.limits.shared:
      validErr("shared core function accesses an unshared table")

proc elementSegment(ctx: ValidationContext, module: WasmModule, index: uint32,
                    op: static string): ElemSegment =
  if index.uint64 >= module.elements.len.uint64: validErr(op & ": invalid element index")
  result = module.elements[index.int]
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and not result.shared:
      validErr("shared core function accesses an unshared element segment")

template tableOperand(value: TableType | ElemSegment): OperandType =
  when defined(wasmFunctionReferences): operand(valToStack(value.elemType), value.elementReference)
  else: operand(valToStack(value.elemType))

proc requireIndirectTable(ctx: ValidationContext, index: uint32, op: static string) =
  let table {.cursor.} = ctx.tableType(index, op)
  if table.elemType != vtFuncRef:
    validErr(op & ": table must contain function references")
  when defined(wasmSharedCoreTypes):
    if table.elementReference.isSharedCoreReference():
      validErr(op & ": shared function references require table.get and call_ref")

proc globalType(ctx: ValidationContext, index: uint32, op: static string): GlobalType =
  if index.uint64 >= ctx.globals.len.uint64: validErr(op & ": invalid global index")
  result = ctx.globals[index.int]
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and not result.shared:
      validErr("shared core function accesses an unshared global")

proc globalOperand(value: GlobalType): OperandType =
  when defined(wasmFunctionReferences): operand(valToStack(value.valType), value.reference)
  else: operand(valToStack(value.valType))

proc checkMemory(ctx: ValidationContext, index: uint32, op: static string) =
  if index.uint64 >= ctx.mems.len.uint64: validErr(op & ": invalid memory index")
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and not ctx.mems[index.int].limits.shared:
      validErr("shared core function accesses an unshared memory")

proc checkDataSegment(ctx: ValidationContext, module: WasmModule,
                      index: uint32, op: static string) =
  if module.dataCount < 0: validErr(op & " requires data count section")
  if index.uint64 >= module.datas.len.uint64: validErr(op & ": invalid data index")
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and not module.datas[index.int].shared:
      validErr("shared core function accesses an unshared data segment")

proc validateInstr(ctx: var ValidationContext, instr: Instr,
                    module: WasmModule, expression: Expr) =
  let brTables = expression.brTables
  let catchTables = expression.catchTables
  ## Validate a single instruction, updating the operand and control stacks.
  let numeric = numericRule(instr.op)
  if numeric.present:
    for _ in 0..<int(numeric.inputCount):
      discard ctx.popExpect(valToStack(numeric.inputType))
    ctx.pushOp(valToStack(numeric.outputType))
    return
  let code = uint16(ord(instr.op))
  let metadata = instructionMetadata(code)
  when defined(wasmSharedCoreTypes):
    if ctx.signature.shared and instr.op in {opThrow, opThrowRef}:
      validErr("shared core function accesses unshared module state")
  if metadata.memoryArgument:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    ctx.checkMemory(instr.pad.uint32, "memory argument")
    let alignment = if metadata.vectorArgument: instr.imm1 else: instr.imm2
    if alignment > uint32(metadata.maxAlignment):
      validErr("memory alignment exceeds natural alignment")
  if metadata.memoryIndex: ctx.checkMemory(instr.imm1, "memory instruction")
  if code >= 0x300 and code <= 0x342:
    let rule = staticRule(instr.op)
    let lanes = simdLaneCount(code)
    if lanes != 0 and instr.imm1 >= lanes: validErr("SIMD lane index out of range")
    if instr.op == opV128Const and uint64(instr.imm1) >= uint64(ctx.vectorConstants):
      validErr("SIMD constant index out of range")
    for i in 0..<int(rule.inputCount):
      discard ctx.popExpect(StackVal(rule.inputs[i]))
    if rule.outputCount != 0: ctx.pushOp(StackVal(rule.outputType))
    return
  case instr.op

  # ---- Control ----
  of opUnreachable:
    ctx.setUnreachable()

  of opNop:
    discard

  of opBlock:
    let bt = getBlockType(expression, int(ctx.instructionIndex))
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opBlock, ins, outs)

  of opLoop:
    let bt = getBlockType(expression, int(ctx.instructionIndex))
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opLoop, ins, outs)

  of opIf:
    let bt = getBlockType(expression, int(ctx.instructionIndex))
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popExpect(svI32)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opIf, ins, outs)

  of opElse:
    let frame = ctx.popCtrl()
    if frame.opcode != opIf:
      validErr("else without matching if")
    ctx.pushCtrl(opElse, frame.startTypes, frame.endTypes)

  of opEnd:
    let frame = ctx.popCtrl()
    if frame.opcode == opIf and not matchesOperands(frame.startTypes, frame.endTypes):
      validErr("if without else: parameter and result types differ")
    ctx.pushOps(frame.endTypes)

  of opBr:
    let l = instr.imm1
    if uint64(l) >= uint64(ctx.labels.len):
      validErr("br: invalid label depth " & $l)
    let frame = ctx.labels[ctx.labels.len - 1 - int(l)]
    discard ctx.popOps(frame.labelTypes)
    ctx.setUnreachable()

  of opBrIf:
    discard ctx.popExpect(svI32)
    ctx.validateConditionalTarget(instr.imm1)

  of opBrTable:
    if uint64(instr.imm1) >= uint64(brTables.len):
      validErr("br_table: invalid table index")
    let targets = brTables[instr.imm1.int]
    template targetTypes(depth: uint32): seq[OperandType] =
      block:
        if uint64(depth) >= uint64(ctx.labels.len):
          validErr("br_table: invalid label depth")
        ctx.labels[ctx.labels.len - 1 - depth.int].labelTypes
    let defaultTypes = targetTypes(targets.defaultLabel)
    discard ctx.popExpect(svI32)
    for depth in targets.labels:
      let types = targetTypes(depth)
      if types.len != defaultTypes.len:
        validErr("br_table: label arity mismatch")
      if ctx.labelChecks:
        ctx.emitFrame(veLabelCheck, ctx.labels[ctx.labels.len-1-depth.int])
      var actual = newSeq[OperandType](types.len)
      for i in countdown(types.high, 0):
        actual[i] = ctx.popOp()
        if not matchesOperand(actual[i], types[i]):
          validErr("br_table: label type mismatch")
      ctx.pushOps(actual)
    if ctx.labelChecks:
      ctx.emitFrame(veLabelCheck, ctx.labels[ctx.labels.len-1-targets.defaultLabel.int])
    discard ctx.popOps(defaultTypes)
    ctx.setUnreachable()

  of opReturn:
    # Pop return types
    if ctx.labels.len > 0:
      let frame = ctx.labels[0]  # outermost frame
      discard ctx.popOps(frame.endTypes)
    ctx.setUnreachable()

  of opCall:
    let funcIdx = instr.imm1
    if uint64(funcIdx) >= uint64(ctx.funcs.len):
      validErr("call: invalid function index " & $funcIdx)
    let ft = ctx.funcs[int(funcIdx)]
    when defined(wasmSharedCoreTypes): ctx.requireSharedCallee(ft)
    discard ctx.popOps(ft.parameterOperands())
    ctx.pushOps(ft.resultOperands())

  of opCallIndirect:
    if uint64(instr.imm1) >= uint64(ctx.types.len):
      validErr("call_indirect: invalid type index " & $instr.imm1)
    let typeIdx = instr.imm1
    ctx.requireIndirectTable(instr.imm2, "call_indirect")
    # Pop i32 index
    discard ctx.popExpect(svI32)
    let ft = ctx.types[int(typeIdx)]
    discard ctx.popOps(ft.parameterOperands())
    ctx.pushOps(ft.resultOperands())

  of opCallRef, opReturnCallRef:
    when defined(wasmFunctionReferences):
      let typeIndex = instr.imm1
      if typeIndex.uint64 >= ctx.types.len.uint64:
        validErr("call_ref: invalid type index")
      let ft = ctx.types[typeIndex.int]
      when defined(wasmSharedCoreTypes): ctx.requireSharedCallee(ft)
      discard ctx.popExpect(operand(svFuncRef, ctx.functionReference(typeIndex + 1)))
      discard ctx.popOps(ft.parameterOperands())
      if instr.op == opReturnCallRef:
        if not matchesOperands(ft.resultOperands(), ctx.labels[0].endTypes):
          validErr("return_call_ref: callee return type mismatch")
        ctx.setUnreachable()
      else: ctx.pushOps(ft.resultOperands())
    else: validErr("typed function references are disabled")

  # ---- Tail calls (return_call, return_call_indirect) ----
  of opReturnCall:
    let funcIdx = instr.imm1
    if uint64(funcIdx) >= uint64(ctx.funcs.len):
      validErr("return_call: invalid function index " & $funcIdx)
    let ft = ctx.funcs[int(funcIdx)]
    when defined(wasmSharedCoreTypes): ctx.requireSharedCallee(ft)
    if not matchesOperands(ft.resultOperands(), ctx.labels[0].endTypes):
      validErr("return_call: callee return type mismatch")
    discard ctx.popOps(ft.parameterOperands())
    ctx.setUnreachable()

  of opReturnCallIndirect:
    let typeIdx = instr.imm1
    if uint64(typeIdx) >= uint64(ctx.types.len):
      validErr("return_call_indirect: invalid type index " & $typeIdx)
    ctx.requireIndirectTable(instr.imm2, "return_call_indirect")
    discard ctx.popExpect(svI32)  # table index
    let ft = ctx.types[int(typeIdx)]
    if not matchesOperands(ft.resultOperands(), ctx.labels[0].endTypes):
      validErr("return_call_indirect: callee return type mismatch")
    discard ctx.popOps(ft.parameterOperands())
    ctx.setUnreachable()

  # ---- Exception handling (try_table, throw, throw_ref) ----
  of opThrow:
    # imm1 = tag index; pops tag's param types, then unreachable
    discard ctx.popOps(exceptionTagType(module, instr.imm1).parameterOperands())
    ctx.setUnreachable()

  of opThrowRef:
    # Pops exnref, rethrows
    discard ctx.popExpect(svExternRef)  # exnref treated as externref for now
    ctx.setUnreachable()

  of opTryTable:
    let bt = getBlockType(expression, int(ctx.instructionIndex))
    let (startTypes, endTypes) = ctx.resolveBlockType(bt)
    if uint64(instr.imm2) >= uint64(catchTables.len):
      validErr("try_table: invalid catch table index")
    let clauses = catchTables[int(instr.imm2)]
    # Catch depths are relative to the OUTER context, before pushing try_table.
    for clause in clauses:
      when defined(wasmSharedCoreTypes):
        if ctx.signature.shared and clause.kind != ckCatchAll:
          validErr("shared core function uses an unshared exception tag or reference")
      if uint64(clause.labelDepth) >= uint64(ctx.labels.len): validErr("catch: invalid label depth")
      var payload: seq[OperandType]
      if clause.kind in {ckCatch, ckCatchRef}:
        payload = exceptionTagType(module, clause.tagIdx).parameterOperands()
      if clause.kind in {ckCatchRef, ckCatchAllRef}: payload.add operand(svExternRef)
      let target = ctx.labels[ctx.labels.len-1-int(clause.labelDepth)]
      if not matchesOperands(payload, target.labelTypes): validErr("catch: target label type mismatch")
      if ctx.catchChecks: ctx.emitFrame(veLabelCheck, target)
    discard ctx.popOps(startTypes)
    ctx.pushCtrl(opBlock, startTypes, endTypes)

  # ---- Parametric ----
  of opDrop:
    discard ctx.popOp()

  of opSelect:
    discard ctx.popExpect(svI32)
    let t1 = ctx.popOp().lane
    let t2 = ctx.popOp().lane
    if t1 != svUnknown and t2 != svUnknown and t1 != t2:
      validErr("select: type mismatch")
    if t1 in {svFuncRef, svExternRef} or t2 in {svFuncRef, svExternRef}:
      validErr("select: references require a typed select")
    let resultType = if t1 == svUnknown: t2 else: t1
    ctx.pushOp(resultType)

  of opSelectTyped:
    discard ctx.popExpect(svI32)
    let expected = case instr.imm1
      of uint32(ord(vtI32)): svI32
      of uint32(ord(vtI64)): svI64
      of uint32(ord(vtF32)): svF32
      of uint32(ord(vtF64)): svF64
      of uint32(ord(vtV128)): svV128
      of uint32(ord(vtFuncRef)): svFuncRef
      of uint32(ord(vtExternRef)): svExternRef
      else:
        validErr("select(t): invalid declared type")
        svUnknown
    discard ctx.popExpect(expected)
    discard ctx.popExpect(expected)
    ctx.pushOp(expected)

  # ---- Variable ----
  of opLocalGet:
    let idx = instr.imm1
    if idx >= ctx.localCount:
      validErr("local.get: invalid local index " & $idx)
    ctx.pushLocal(idx)

  of opLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount:
      validErr("local.set: invalid local index " & $idx)
    ctx.popLocal(idx)

  of opLocalTee:
    let idx = instr.imm1
    if idx >= ctx.localCount:
      validErr("local.tee: invalid local index " & $idx)
    ctx.popLocal(idx)
    ctx.pushLocal(idx)

  of opGlobalGet:
    ctx.pushOp(globalOperand(ctx.globalType(instr.imm1, "global.get")))

  of opGlobalSet:
    let global {.cursor.} = ctx.globalType(instr.imm1, "global.set")
    if global.mut != mutVar: validErr("global.set: immutable global " & $instr.imm1)
    discard ctx.popExpect(globalOperand(global))

  of opGlobalAtomicGet .. opGlobalAtomicCmpXchg:
    when defined(wasmSharedCoreTypes):
      let global {.cursor.} = ctx.globalType(instr.imm1, "global.atomic")
      if global.valType notin {vtI32, vtI64}:
        validErr("global.atomic requires an i32 or i64 global")
      if not validGlobalAtomicOrdering(instr.op, instr.pad):
        validErr("invalid global atomic ordering")
      let value = globalOperand(global)
      if instr.op != opGlobalAtomicGet:
        if global.mut != mutVar: validErr("global.atomic: immutable global")
        discard ctx.popExpect(value)
        if instr.op == opGlobalAtomicCmpXchg: discard ctx.popExpect(value)
      if instr.op != opGlobalAtomicSet: ctx.pushOp(value)
    else:
      validErr("global atomic instructions are disabled")

  of opMemoryAtomic:
    when defined(wasmSharedCoreTypes):
      let access = memoryAtomicSpec(instr.imm2 and 0xff)
      if access.kind == maInvalid: validErr("unknown memory atomic operation")
      if instr.imm2 shr 8 != access.alignment.uint32:
        validErr("memory atomic alignment must match the access width")
      ctx.checkMemory(instr.pad.uint32, "memory atomic")
      let lane = valToStack(access.lane)
      if access.kind != maLoad: discard ctx.popExpect(lane)
      if access.kind == maCompareExchange: discard ctx.popExpect(lane)
      discard ctx.popExpect(svI32)
      if access.kind != maStore: ctx.pushOp(lane)
    else:
      validErr("atomic instructions are disabled")

  of opMemoryAtomicNotify, opMemoryAtomicWait32, opMemoryAtomicWait64:
    when defined(wasmSharedCoreTypes) and defined(wasmAtomicWait):
      let wide = instr.op == opMemoryAtomicWait64
      if instr.imm2 != (if wide: 3'u32 else: 2'u32):
        validErr("memory atomic alignment must match the access width")
      ctx.checkMemory(instr.pad.uint32, "memory atomic")
      if instr.op == opMemoryAtomicNotify:
        discard ctx.popExpect(svI32)
      else:
        discard ctx.popExpect(svI64) # timeout in nanoseconds
        discard ctx.popExpect(if wide: svI64 else: svI32)
      discard ctx.popExpect(svI32)
      ctx.pushOp(svI32)
    else:
      validErr("atomic wait and notify are disabled")

  of opAtomicFence:
    when not defined(wasmSharedCoreTypes): validErr("atomic instructions are disabled")

  # ---- Table ----
  of opTableGet:
    let table {.cursor.} = ctx.tableType(instr.imm1, "table.get")
    discard ctx.popExpect(svI32)
    ctx.pushOp(tableOperand(table))

  of opTableSet:
    let table {.cursor.} = ctx.tableType(instr.imm1, "table.set")
    discard ctx.popExpect(tableOperand(table))
    discard ctx.popExpect(svI32)

  # ---- Memory loads ----
  of opI32Load, opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opI64Load, opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
     opI64Load32S, opI64Load32U:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI64)

  of opF32Load:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF32)

  of opF64Load:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF64)

  # ---- Memory stores ----
  of opI32Store, opI32Store8, opI32Store16:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)

  of opI64Store, opI64Store8, opI64Store16, opI64Store32:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI64)
    discard ctx.popExpect(svI32)

  of opF32Store:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svF32)
    discard ctx.popExpect(svI32)

  of opF64Store:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svF64)
    discard ctx.popExpect(svI32)

  # ---- Memory management ----
  of opMemorySize:
    if ctx.mems.len == 0: validErr("memory.size without memory")
    ctx.pushOp(svI32)

  of opMemoryGrow:
    if ctx.mems.len == 0: validErr("memory.grow without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- Reference ----
  of opRefNull:
    # imm1 encodes the ref type
    let vt = case instr.imm1
      of 0x70'u32: svFuncRef
      of 0x6F'u32: svExternRef
      else:
        validErr("ref.null: invalid reference type")
        svUnknown
    when defined(wasmFunctionReferences):
      if instr.imm2 != 0 and (vt != svFuncRef or not validFunctionHeapTag(instr.imm2, ctx.types.len)):
        validErr("ref.null: invalid function heap type")
      ctx.pushOp(operand(vt, ctx.functionReference(instr.imm2, sharedAbstract = instr.pad != 0)))
    else: ctx.pushOp(vt)

  of opRefIsNull:
    let t = ctx.popOp().lane
    if t != svUnknown and t != svFuncRef and t != svExternRef:
      validErr("ref.is_null: expected reference type, got " & $t)
    ctx.pushOp(svI32)

  of opRefFunc:
    if uint64(instr.imm1) >= uint64(ctx.funcs.len):
      validErr("ref.func: invalid function index " & $instr.imm1)
    if not hasDeclaredReference(ctx.declaredReferences, instr.imm1):
      validErr("ref.func: undeclared function reference " & $instr.imm1)
    when defined(wasmFunctionReferences):
      ctx.pushOp(operand(svFuncRef, ctx.functionReference(ctx.functionTypeIndices[instr.imm1.int] + 1,
        nonNull = true)))
    else: ctx.pushOp(svFuncRef)

  of opRefAsNonNull:
    when defined(wasmFunctionReferences):
      var value = ctx.popOp()
      if value.lane notin {svFuncRef, svExternRef, svUnknown}:
        validErr("ref.as_non_null: expected a reference type")
      value.reference.nonNull = true
      ctx.pushOp(value)
    else: validErr("typed function references are disabled")

  # ---- Bulk memory ----
  of opMemoryInit:
    if ctx.mems.len == 0: validErr("memory.init without memory")
    ctx.checkDataSegment(module, instr.imm1, "memory.init")
    ctx.checkMemory(instr.imm2, "memory.init")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opDataDrop:
    ctx.checkDataSegment(module, instr.imm1, "data.drop")

  of opMemoryCopy:
    if ctx.mems.len == 0: validErr("memory.copy without memory")
    ctx.checkMemory(instr.imm1, "memory.copy")
    ctx.checkMemory(instr.imm2, "memory.copy")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opMemoryFill:
    if ctx.mems.len == 0: validErr("memory.fill without memory")
    ctx.checkMemory(instr.imm1, "memory.fill")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # value
    discard ctx.popExpect(svI32)  # dest

  # ---- Bulk table ----
  of opTableInit:
    let segment {.cursor.} = ctx.elementSegment(module, instr.imm1, "table.init")
    let table {.cursor.} = ctx.tableType(instr.imm2, "table.init")
    if not matchesOperand(tableOperand(segment), tableOperand(table)):
      validErr("table.init: incompatible element/table types")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opElemDrop:
    discard ctx.elementSegment(module, instr.imm1, "elem.drop")

  of opTableCopy:
    let destination {.cursor.} = ctx.tableType(instr.imm1, "table.copy")
    let source {.cursor.} = ctx.tableType(instr.imm2, "table.copy")
    if not matchesOperand(tableOperand(source), tableOperand(destination)):
      validErr("table.copy: incompatible table types")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opTableGrow:
    let table {.cursor.} = ctx.tableType(instr.imm1, "table.grow")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(tableOperand(table))
    ctx.pushOp(svI32)

  of opTableSize:
    discard ctx.tableType(instr.imm1, "table.size")
    ctx.pushOp(svI32)

  of opTableFill:
    let table {.cursor.} = ctx.tableType(instr.imm1, "table.fill")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(tableOperand(table))
    discard ctx.popExpect(svI32)

  # ---- Superinstructions (fused) — same typing as individual ops ----
  of opLocalGetLocalGet:
    let idx1 = instr.imm1
    let idx2 = instr.imm2
    if idx1 >= ctx.localCount or idx2 >= ctx.localCount:
      validErr("fused local.get: invalid local index")
    ctx.pushLocal(idx1)
    ctx.pushLocal(idx2)

  of opLocalGetI32Add:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused local.get+i32.add: invalid local index")
    ctx.pushOp(valToStack(ctx.localType(idx)))
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opLocalGetI32Sub:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused local.get+i32.sub: invalid local index")
    ctx.pushOp(valToStack(ctx.localType(idx)))
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- More fused superinstructions ----
  of opLocalGetI32Store:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.mems.len == 0: validErr("fused: memory instruction without memory")
    ctx.pushOp(valToStack(ctx.localType(idx)))
    discard ctx.popExpect(svI32)  # value
    discard ctx.popExpect(svI32)  # addr
  of opLocalGetI32Load:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.mems.len == 0: validErr("fused: memory instruction without memory")
    if valToStack(ctx.localType(idx)) != svI32:
      validErr("fused local.get+i32.load: local address must be i32")
    ctx.pushOp(svI32)
  of opLocalGetI32LoadI32Add:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.mems.len == 0: validErr("fused: memory instruction without memory")
    if valToStack(ctx.localType(idx)) != svI32:
      validErr("fused local.get+i32.load+i32.add: local address must be i32")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32Add:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32Sub:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opLocalSetLocalGet:
    let setIdx = instr.imm1
    let getIdx = instr.imm2
    if setIdx >= ctx.localCount or getIdx >= ctx.localCount:
      validErr("fused: invalid local index")
    ctx.popLocal(setIdx)
    ctx.pushLocal(getIdx)
  of opLocalTeeLocalGet:
    let teeIdx = instr.imm1
    let getIdx = instr.imm2
    if teeIdx >= ctx.localCount or getIdx >= ctx.localCount:
      validErr("fused: invalid local index")
    ctx.popLocal(teeIdx)
    ctx.pushLocal(teeIdx)
    ctx.pushLocal(getIdx)
  of opLocalGetI32Const:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    ctx.pushLocal(idx)
    ctx.pushOp(svI32)
  of opI32AddLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.localType(idx) != vtI32: validErr("fused i32.add: local must be i32")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    # i32.add result stored to local (no push)
  of opI32SubLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.localType(idx) != vtI32: validErr("fused i32.sub: local must be i32")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    # i32.sub result stored to local (no push)
  of opI32EqzBrIf:
    discard ctx.popExpect(svI32)
    ctx.validateConditionalTarget(instr.imm1)
  of opI32EqBrIf, opI32NeBrIf, opI32LtSBrIf, opI32GeSBrIf,
     opI32GtSBrIf, opI32LeSBrIf, opI32LtUBrIf, opI32GeUBrIf,
     opI32GtUBrIf, opI32LeUBrIf:
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.validateConditionalTarget(instr.imm1)
  of opI32ConstI32EqBrIf, opI32ConstI32NeBrIf, opI32ConstI32LtSBrIf,
     opI32ConstI32GeSBrIf, opI32ConstI32GtUBrIf, opI32ConstI32LeUBrIf:
    discard ctx.popExpect(svI32)
    ctx.validateConditionalTarget(instr.imm2)
  of opLocalGetLocalGetI32Add:
    let idx1 = instr.imm1
    let idx2 = instr.imm2
    if idx1 >= ctx.localCount or idx2 >= ctx.localCount:
      validErr("fused: invalid local index")
    if ctx.localType(idx1) != vtI32 or ctx.localType(idx2) != vtI32:
      validErr("fused i32.add: locals must be i32")
    # Push both locals, then add: net effect = push i32
    ctx.pushOp(svI32)
  of opLocalGetLocalGetI32Sub:
    let idx1 = instr.imm1
    let idx2 = instr.imm2
    if idx1 >= ctx.localCount or idx2 >= ctx.localCount:
      validErr("fused: invalid local index")
    if ctx.localType(idx1) != vtI32 or ctx.localType(idx2) != vtI32:
      validErr("fused i32.sub: locals must be i32")
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Sub:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.localType(idx) != vtI32: validErr("fused i32.sub: local must be i32")
    # local.get X; i32.const C; i32.sub → push i32
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Add:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.localType(idx) != vtI32: validErr("fused i32.add: local must be i32")
    ctx.pushOp(svI32)
  of opLocalGetLocalTee:
    # local.get X; local.tee Y → push local[X], tee to Y (net: push 1 value)
    let getIdx = instr.imm1
    let teeIdx = instr.imm2
    if getIdx >= ctx.localCount or teeIdx >= ctx.localCount:
      validErr("fused: invalid local index")
    ctx.pushLocal(getIdx)
    ctx.popLocal(teeIdx)
    ctx.pushLocal(teeIdx)
  of opI32ConstI32GtU:
    # i32.const C; i32.gt_u → pop i32, push i32 (comparison result)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32LtS:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32GeS:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opLocalTeeBrIf:
    # local.tee X; br_if L → pop i32, store to local, branch if nonzero
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    if ctx.localType(idx) != vtI32: validErr("fused: branch condition local must be i32")
    discard ctx.popExpect(svI32)
    ctx.validateConditionalTarget(instr.imm2)

  else:
    ctx.emitEvent(veUnsupported)
    discard  # Unknown fused ops — skip

# ---------------------------------------------------------------------------
# Function body validation
# ---------------------------------------------------------------------------

proc validateFunctionImpl(module: WasmModule, funcIdx: int,
    trace: ptr seq[ValidationEvent], labelChecks, catchChecks: bool, context: ModuleContext) =
  ## Validate a single function body.
  let numImportFuncs = context.importedFunctions
  let bodyIdx = funcIdx - numImportFuncs
  if bodyIdx < 0 or bodyIdx >= module.codes.len:
    validErr("function index out of range: " & $funcIdx)

  let typeIdx = module.funcTypeIdxs[bodyIdx]
  if typeIdx.int >= module.types.len:
    validErr("function type index out of range: " & $typeIdx)
  let funcType = module.types[typeIdx.int]
  let body = module.codes[bodyIdx]

  var localCount = uint64(funcType.params.len)
  var localEnds: seq[uint64]
  for declaration in body.locals:
    localCount += uint64(declaration.count)
    localEnds.add localCount

  var ctx = ValidationContext(
    types: module.types,
    funcs: context.functions,
    declaredReferences: context.declaredReferences,
    tables: context.tables,
    mems: context.memories,
    globals: context.globals,
    locals: funcType.params,
    localDecls: body.locals,
    localEnds: localEnds,
    localCount: localCount,
    vectorConstants: body.code.v128Consts.len,
    trace: trace,
    labelChecks: labelChecks,
    catchChecks: catchChecks,
    numImportFuncs: numImportFuncs,
    functionIndex: uint32(funcIdx),
    opcode: opBlock,
  )
  when defined(wasmFunctionReferences):
    ctx.functionTypeIndices = context.functionTypeIndices
    ctx.signature = funcType

  # Push initial frame for function body
  ctx.emitEvent(veFunctionBegin)
  let resultTypes = funcType.resultOperands()
  ctx.pushCtrl(opBlock, @[], resultTypes)

  # Validate each instruction
  for pc, instr in body.code.code:
    ctx.instructionIndex = uint32(pc)
    ctx.opcode = instr.op
    ctx.emitEvent(veInstructionBegin)
    when defined(bl808WasmTraceValidate):
      validateStage(0x57534000'u32 or (uint32(bodyIdx and 0xFF) shl 8) or uint32(pc and 0xFF))
    ctx.validateInstr(instr, module, body.code)
    ctx.emitEvent(veInstructionEnd)
    when defined(bl808WasmTraceValidate):
      validateStage(0x57535000'u32 or (uint32(bodyIdx and 0xFF) shl 8) or uint32(pc and 0xFF))
    if ctx.labels.len == 0:
      validErr("unexpected function end in decoded instruction body")
  # readExpr consumes the function's final end byte; nested ends remain in IR.
  if ctx.labels.len != 1:
    validErr("function contains unterminated control frames")
  ctx.instructionIndex = uint32(body.code.code.len)
  ctx.opcode = opEnd
  ctx.emitEvent(veInstructionBegin)
  discard ctx.popCtrl()
  ctx.emitEvent(veInstructionEnd)
  ctx.emitEvent(veFunctionEnd)

proc validateFunction*(module: WasmModule, funcIdx: int,
    trace: ptr seq[ValidationEvent] = nil, labelChecks = false, catchChecks = false) =
  validateFunctionImpl(module, funcIdx, trace, labelChecks, catchChecks, validateModuleContext(module))


# ---------------------------------------------------------------------------
# Module-level validation
# ---------------------------------------------------------------------------

proc validateModule*(module: WasmModule, trace: ptr seq[ValidationEvent] = nil,
    labelChecks = false, catchChecks = false, allowMultipleMemories = false,
    allowFunctionSubtyping = false) =
  ## Validate an entire WASM module: types, functions, tables, memories,
  ## globals, exports, start function.
  let context = validateModuleContext(module, allowMultipleMemories, allowFunctionSubtyping)
  for index in context.importedFunctions..<context.functions.len:
    try:
      validateFunctionImpl(module, index, trace, labelChecks, catchChecks, context)
    except ValidationError as error:
      validErr("function " & $index & ": " & error.msg)

proc traceModuleValidation*(module: WasmModule, labelChecks = false, catchChecks = false): seq[ValidationEvent] =
  ## Trace only successfully validated modules. Callers bind the module bytes
  ## and still need to prove these transitions before kernel admission.
  validateModule(module, addr result, labelChecks, catchChecks)
