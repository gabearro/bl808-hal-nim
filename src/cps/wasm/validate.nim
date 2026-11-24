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
    startTypes: seq[StackVal]  # input types
    endTypes: seq[StackVal]    # output types
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
    operands: seq[StackVal]   # operand type stack
    numImportFuncs: int
    numImportGlobals: int
    vectorConstants: int
    trace: ptr seq[ValidationEvent]
    labelChecks, catchChecks: bool
    functionIndex, instructionIndex: uint32
    opcode: Opcode

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
  for value in frame.startTypes: event.startTypes.add value
  for value in frame.endTypes: event.endTypes.add value
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

proc valsToStack(vts: seq[ValType]): seq[StackVal] =
  for vt in vts:
    result.add(valToStack(vt))

proc validErr(msg: string) =
  raise newException(ValidationError, msg)

proc localType(ctx: ValidationContext, index: uint32): ValType =
  if uint64(index) >= ctx.localCount: validErr("local index out of range")
  if uint64(index) < uint64(ctx.locals.len): return ctx.locals[int(index)]
  var low = 0
  var limit = ctx.localEnds.len
  while low < limit:
    let middle = low+(limit-low) div 2
    if ctx.localEnds[middle] <= uint64(index): low = middle+1
    else: limit = middle
  ctx.localDecls[low].valType

proc validateStage(code: uint32) {.inline.} =
  when defined(bl808lp) and defined(bl808WasmTrace):
    regWrite(0x40002E84'u, code)
  else:
    discard code

# ---------------------------------------------------------------------------
# Operand stack operations
# ---------------------------------------------------------------------------

proc pushOp(ctx: var ValidationContext, sv: StackVal) =
  ctx.operands.add(sv)
  ctx.emitEvent(veOperandPush, sv)

proc pushOps(ctx: var ValidationContext, svs: seq[StackVal]) =
  for sv in svs:
    ctx.pushOp(sv)

proc popOp(ctx: var ValidationContext): StackVal =
  if ctx.labels.len > 0:
    let frame = ctx.labels[^1]
    if ctx.operands.len == frame.height:
      if frame.unreachable:
        ctx.emitEvent(veOperandPop, svUnknown, polymorphic = true)
        return svUnknown
      validErr("type mismatch: operand stack underflow")
  elif ctx.operands.len == 0:
    validErr("type mismatch: operand stack underflow")
  result = ctx.operands.pop()
  ctx.emitEvent(veOperandPop, result)

proc popExpect(ctx: var ValidationContext, expected: StackVal): StackVal =
  let actual = ctx.popOp()
  if actual == svUnknown: return expected
  if expected == svUnknown: return actual
  if actual != expected:
    validErr("type mismatch: expected " & $expected & ", got " & $actual)
  actual

proc popOps(ctx: var ValidationContext, expected: seq[StackVal]): seq[StackVal] =
  result = newSeq[StackVal](expected.len)
  for i in countdown(expected.len - 1, 0):
    result[i] = ctx.popExpect(expected[i])

# ---------------------------------------------------------------------------
# Control frame operations
# ---------------------------------------------------------------------------

proc pushCtrl(ctx: var ValidationContext, op: Opcode,
              startTypes, endTypes: seq[StackVal]) =
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

proc labelTypes(frame: CtrlFrame): seq[StackVal] =
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

proc resolveBlockType(ctx: ValidationContext, bt: BlockType): (seq[StackVal], seq[StackVal]) =
  case bt.kind
  of btkEmpty:
    (@[], @[])
  of btkValType:
    (@[], @[valToStack(bt.valType)])
  of btkTypeIdx:
    if uint64(bt.typeIdx) >= uint64(ctx.types.len):
      validErr("invalid block type index: " & $bt.typeIdx)
    let idx = int(bt.typeIdx)
    if uint64(idx) >= uint64(ctx.types.len):
      validErr("invalid block type index: " & $idx)
    let ft = ctx.types[int(idx)]
    (valsToStack(ft.params), valsToStack(ft.results))

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
  if metadata.memoryArgument:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    let alignment = if metadata.vectorArgument: instr.imm1 else: instr.imm2
    if alignment > uint32(metadata.maxAlignment):
      validErr("memory alignment exceeds natural alignment")
  if metadata.memoryIndex and uint64(instr.imm1) >= uint64(ctx.mems.len):
    validErr("memory instruction: invalid memory index")
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
    if frame.opcode == opIf and frame.startTypes != frame.endTypes:
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
    template targetTypes(depth: uint32): seq[StackVal] =
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
      var actual = newSeq[StackVal](types.len)
      for i in countdown(types.high, 0):
        actual[i] = ctx.popOp()
        if actual[i] != svUnknown and actual[i] != types[i]:
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
    discard ctx.popOps(valsToStack(ft.params))
    ctx.pushOps(valsToStack(ft.results))

  of opCallIndirect:
    if uint64(instr.imm1) >= uint64(ctx.types.len):
      validErr("call_indirect: invalid type index " & $instr.imm1)
    let typeIdx = instr.imm1
    if uint64(instr.imm2) >= uint64(ctx.tables.len):
      validErr("call_indirect: invalid table index " & $instr.imm2)
    let tableIdx = instr.imm2
    if ctx.tables[int(tableIdx)].elemType != vtFuncRef:
      validErr("call_indirect: table must contain function references")
    # Pop i32 index
    discard ctx.popExpect(svI32)
    let ft = ctx.types[int(typeIdx)]
    discard ctx.popOps(valsToStack(ft.params))
    ctx.pushOps(valsToStack(ft.results))

  # ---- Tail calls (return_call, return_call_indirect) ----
  of opReturnCall:
    let funcIdx = instr.imm1
    if uint64(funcIdx) >= uint64(ctx.funcs.len):
      validErr("return_call: invalid function index " & $funcIdx)
    let ft = ctx.funcs[int(funcIdx)]
    # Callee return types must match the current function's return types
    if ctx.labels.len > 0:
      let outerFrame = ctx.labels[0]
      let calleeResults = valsToStack(ft.results)
      if calleeResults.len != outerFrame.endTypes.len:
        validErr("return_call: callee return arity mismatch")
      for i in 0 ..< calleeResults.len:
        if calleeResults[i] != outerFrame.endTypes[i]:
          validErr("return_call: callee return type mismatch")
    discard ctx.popOps(valsToStack(ft.params))
    ctx.setUnreachable()

  of opReturnCallIndirect:
    let typeIdx = instr.imm1
    if uint64(typeIdx) >= uint64(ctx.types.len):
      validErr("return_call_indirect: invalid type index " & $typeIdx)
    let tableIdx = instr.imm2
    if uint64(tableIdx) >= uint64(ctx.tables.len):
      validErr("return_call_indirect: invalid table index " & $tableIdx)
    if ctx.tables[int(tableIdx)].elemType != vtFuncRef:
      validErr("return_call_indirect: table must contain function references")
    discard ctx.popExpect(svI32)  # table index
    let ft = ctx.types[int(typeIdx)]
    if ctx.labels.len > 0:
      let outerFrame = ctx.labels[0]
      let calleeResults = valsToStack(ft.results)
      if calleeResults.len != outerFrame.endTypes.len:
        validErr("return_call_indirect: callee return arity mismatch")
      for i in 0 ..< calleeResults.len:
        if calleeResults[i] != outerFrame.endTypes[i]:
          validErr("return_call_indirect: callee return type mismatch")
    discard ctx.popOps(valsToStack(ft.params))
    ctx.setUnreachable()

  # ---- Exception handling (try_table, throw, throw_ref) ----
  of opThrow:
    # imm1 = tag index; pops tag's param types, then unreachable
    discard ctx.popOps(valsToStack(exceptionTagType(module, instr.imm1).params))
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
      if uint64(clause.labelDepth) >= uint64(ctx.labels.len): validErr("catch: invalid label depth")
      var payload: seq[StackVal]
      if clause.kind in {ckCatch, ckCatchRef}:
        payload = valsToStack(exceptionTagType(module, clause.tagIdx).params)
      if clause.kind in {ckCatchRef, ckCatchAllRef}: payload.add svExternRef
      let target = ctx.labels[ctx.labels.len-1-int(clause.labelDepth)]
      if payload != target.labelTypes: validErr("catch: target label type mismatch")
      if ctx.catchChecks: ctx.emitFrame(veLabelCheck, target)
    discard ctx.popOps(startTypes)
    ctx.pushCtrl(opBlock, startTypes, endTypes)

  # ---- Parametric ----
  of opDrop:
    discard ctx.popOp()

  of opSelect:
    discard ctx.popExpect(svI32)
    let t1 = ctx.popOp()
    let t2 = ctx.popOp()
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
    ctx.pushOp(valToStack(ctx.localType(idx)))

  of opLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount:
      validErr("local.set: invalid local index " & $idx)
    discard ctx.popExpect(valToStack(ctx.localType(idx)))

  of opLocalTee:
    let idx = instr.imm1
    if idx >= ctx.localCount:
      validErr("local.tee: invalid local index " & $idx)
    let expected = valToStack(ctx.localType(idx))
    let val = ctx.popExpect(expected)
    ctx.pushOp(val)

  of opGlobalGet:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.globals.len):
      validErr("global.get: invalid global index " & $idx)
    ctx.pushOp(valToStack(ctx.globals[int(idx)].valType))

  of opGlobalSet:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.globals.len):
      validErr("global.set: invalid global index " & $idx)
    if ctx.globals[int(idx)].mut != mutVar:
      validErr("global.set: immutable global " & $idx)
    discard ctx.popExpect(valToStack(ctx.globals[int(idx)].valType))

  # ---- Table ----
  of opTableGet:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.tables.len):
      validErr("table.get: invalid table index")
    discard ctx.popExpect(svI32)
    ctx.pushOp(valToStack(ctx.tables[int(idx)].elemType))

  of opTableSet:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.tables.len):
      validErr("table.set: invalid table index")
    discard ctx.popExpect(valToStack(ctx.tables[int(idx)].elemType))
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
    ctx.pushOp(vt)

  of opRefIsNull:
    let t = ctx.popOp()
    if t != svUnknown and t != svFuncRef and t != svExternRef:
      validErr("ref.is_null: expected reference type, got " & $t)
    ctx.pushOp(svI32)

  of opRefFunc:
    if uint64(instr.imm1) >= uint64(ctx.funcs.len):
      validErr("ref.func: invalid function index " & $instr.imm1)
    if not hasDeclaredReference(ctx.declaredReferences, instr.imm1):
      validErr("ref.func: undeclared function reference " & $instr.imm1)
    ctx.pushOp(svFuncRef)

  # ---- Bulk memory ----
  of opMemoryInit:
    if ctx.mems.len == 0: validErr("memory.init without memory")
    if module.dataCount < 0: validErr("memory.init requires data count section")
    if uint64(instr.imm1) >= uint64(module.datas.len): validErr("memory.init: invalid data index")
    if uint64(instr.imm2) >= uint64(ctx.mems.len): validErr("memory.init: invalid memory index")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opDataDrop:
    if module.dataCount < 0: validErr("data.drop requires data count section")
    if uint64(instr.imm1) >= uint64(module.datas.len): validErr("data.drop: invalid data index")

  of opMemoryCopy:
    if ctx.mems.len == 0: validErr("memory.copy without memory")
    if uint64(instr.imm1) >= uint64(ctx.mems.len) or uint64(instr.imm2) >= uint64(ctx.mems.len):
      validErr("memory.copy: invalid memory index")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opMemoryFill:
    if ctx.mems.len == 0: validErr("memory.fill without memory")
    if uint64(instr.imm1) >= uint64(ctx.mems.len): validErr("memory.fill: invalid memory index")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # value
    discard ctx.popExpect(svI32)  # dest

  # ---- Bulk table ----
  of opTableInit:
    if uint64(instr.imm1) >= uint64(module.elements.len): validErr("table.init: invalid element index")
    if uint64(instr.imm2) >= uint64(ctx.tables.len): validErr("table.init: invalid table index")
    if module.elements[int(instr.imm1)].elemType != ctx.tables[int(instr.imm2)].elemType:
      validErr("table.init: incompatible element/table types")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opElemDrop:
    if uint64(instr.imm1) >= uint64(module.elements.len): validErr("elem.drop: invalid element index")

  of opTableCopy:
    if uint64(instr.imm1) >= uint64(ctx.tables.len) or uint64(instr.imm2) >= uint64(ctx.tables.len):
      validErr("table.copy: invalid table index")
    if ctx.tables[int(instr.imm1)].elemType != ctx.tables[int(instr.imm2)].elemType:
      validErr("table.copy: incompatible table types")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opTableGrow:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.tables.len): validErr("table.grow: invalid table index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(valToStack(ctx.tables[int(idx)].elemType))
    ctx.pushOp(svI32)

  of opTableSize:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.tables.len): validErr("table.size: invalid table index")
    ctx.pushOp(svI32)

  of opTableFill:
    let idx = instr.imm1
    if uint64(idx) >= uint64(ctx.tables.len): validErr("table.fill: invalid table index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(valToStack(ctx.tables[int(idx)].elemType))
    discard ctx.popExpect(svI32)

  # ---- Superinstructions (fused) — same typing as individual ops ----
  of opLocalGetLocalGet:
    let idx1 = instr.imm1
    let idx2 = instr.imm2
    if idx1 >= ctx.localCount or idx2 >= ctx.localCount:
      validErr("fused local.get: invalid local index")
    ctx.pushOp(valToStack(ctx.localType(idx1)))
    ctx.pushOp(valToStack(ctx.localType(idx2)))

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
    discard ctx.popExpect(valToStack(ctx.localType(setIdx)))
    ctx.pushOp(valToStack(ctx.localType(getIdx)))
  of opLocalTeeLocalGet:
    let teeIdx = instr.imm1
    let getIdx = instr.imm2
    if teeIdx >= ctx.localCount or getIdx >= ctx.localCount:
      validErr("fused: invalid local index")
    let val = ctx.popExpect(valToStack(ctx.localType(teeIdx)))
    ctx.pushOp(val)  # tee keeps value
    ctx.pushOp(valToStack(ctx.localType(getIdx)))
  of opLocalGetI32Const:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    ctx.pushOp(valToStack(ctx.localType(idx)))
    ctx.pushOp(svI32)
  of opI32AddLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    # i32.add result stored to local (no push)
  of opI32SubLocalSet:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
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
    # Push both locals, then add: net effect = push i32
    ctx.pushOp(svI32)
  of opLocalGetLocalGetI32Sub:
    let idx1 = instr.imm1
    let idx2 = instr.imm2
    if idx1 >= ctx.localCount or idx2 >= ctx.localCount:
      validErr("fused: invalid local index")
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Sub:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    # local.get X; i32.const C; i32.sub → push i32
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Add:
    let idx = instr.imm1
    if idx >= ctx.localCount: validErr("fused: invalid local index")
    ctx.pushOp(svI32)
  of opLocalGetLocalTee:
    # local.get X; local.tee Y → push local[X], tee to Y (net: push 1 value)
    let getIdx = instr.imm1
    let teeIdx = instr.imm2
    if getIdx >= ctx.localCount or teeIdx >= ctx.localCount:
      validErr("fused: invalid local index")
    ctx.pushOp(valToStack(ctx.localType(getIdx)))
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

  # Push initial frame for function body
  ctx.emitEvent(veFunctionBegin)
  let resultTypes = valsToStack(funcType.results)
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
    labelChecks = false, catchChecks = false) =
  ## Validate an entire WASM module: types, functions, tables, memories,
  ## globals, exports, start function.
  let context = validateModuleContext(module)
  for index in context.importedFunctions..<context.functions.len:
    try:
      validateFunctionImpl(module, index, trace, labelChecks, catchChecks, context)
    except ValidationError as error:
      validErr("function " & $index & ": " & error.msg)

proc traceModuleValidation*(module: WasmModule, labelChecks = false, catchChecks = false): seq[ValidationEvent] =
  ## Trace only successfully validated modules. Callers bind the module bytes
  ## and still need to prove these transitions before kernel admission.
  validateModule(module, addr result, labelChecks, catchChecks)
