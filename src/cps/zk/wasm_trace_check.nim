## Independent structural replay of a general WASM validation transcript.
## This checks transcript integrity, not complete opcode typing or binary
## decoding. It is a component of the future full-module proof relation.
import ../wasm/[types, validate]
import ../wasm/static_typing
import ../wasm/variable_typing
import ../wasm/call_typing
import ../wasm/exception_typing
import ../wasm/block_types

type
  TraceError* = enum
    teNone, teModuleShape, teFunctionOrder, teInstructionOrder, tePayload,
    teOperandStack, teControlStack, teUnsupported, teIncomplete
  TraceCheck* = object
    error*: TraceError
    eventIndex*: int
  Frame = object
    opcode: Opcode
    height: int
    unreachable: bool
    inputs, outputs: seq[StackVal]

func accepted*(check: TraceCheck): bool = check.error == teNone

func stackType(value: ValType): StackVal =
  case value
  of vtI32: svI32
  of vtI64: svI64
  of vtF32: svF32
  of vtF64: svF64
  of vtV128: svV128
  of vtFuncRef: svFuncRef
  of vtExternRef: svExternRef

func types(values: seq[ValType]): seq[StackVal] =
  for value in values: result.add stackType(value)

func plain(event: ValidationEvent): bool =
  event.frameOpcode == opUnreachable and event.frameHeight == 0 and
    not event.frameUnreachable and event.startTypes.len == 0 and event.endTypes.len == 0

func matches(frame: Frame, event: ValidationEvent): bool =
  frame.opcode == event.frameOpcode and frame.height == event.frameHeight and
    frame.unreachable == event.frameUnreachable and frame.inputs == event.startTypes and
    frame.outputs == event.endTypes

proc blockTypes(module: WasmModule, expression: Expr, pc: int,
    inputs, outputs: var seq[StackVal]): bool =
  var pad: uint64
  try: pad = expression.normalizedBlockPad(pc)
  except ValueError: return false
  if pad == 0: return true
  if pad < 0x100:
    if pad > 7: return false
    outputs.add StackVal(pad-1)
  else:
    let index = uint32(pad-0x100)
    if uint64(index) >= uint64(module.types.len): return false
    inputs = types(module.types[index.int].params)
    outputs = types(module.types[index.int].results)
  true

proc checkValidationTraceStructure*(module: WasmModule,
    events: openArray[ValidationEvent], labelChecks = false, catchChecks = false): TraceCheck =
  ## A successful result proves only the invariants listed above. In
  ## particular it must not be used as kernel admission or as a ZK proof.
  var position = 0
  template reject(reason: TraceError): untyped =
    return TraceCheck(error: reason, eventIndex: position)
  if module.codes.len != module.funcTypeIdxs.len:
    reject(teModuleShape)
  var imports = 0'u64
  for item in module.imports:
    if item.kind == ikFunc: inc imports
  if imports + uint64(module.codes.len) > uint64(high(uint32)):
    reject(teModuleShape)
  var body, nextPc: int
  var active, rootPending, instructionOpen: bool
  var opcode = opBlock
  var operands: seq[StackVal]
  var controls: seq[Frame]
  var pushes, pops, clears: int
  var fixed: StaticRule
  var fixedPops, fixedPushes: int
  var call: CallRule
  var callPops, callPushes: int
  var lastPopped: Frame
  var havePopped: bool
  var labelPosition = 0
  for index, event in events:
    position = index
    if event.operandHeight < 0 or event.controlHeight < 0 or event.frameHeight < 0:
      reject(tePayload)
    if uint64(event.functionIndex) != imports + uint64(body):
      reject(teFunctionOrder)
    if event.kind == veUnsupported:
      reject(teUnsupported)
    if event.kind in {veControlPush, veControlPop, veUnreachable, veLabelCheck}:
      if event.valueType != svUnknown or event.polymorphic: reject(tePayload)
    else:
      if not plain(event): reject(tePayload)
      if event.kind != veOperandPop and event.polymorphic: reject(tePayload)
      if event.kind notin {veOperandPush, veOperandPop} and event.valueType != svUnknown:
        reject(tePayload)
    case event.kind
    of veFunctionBegin:
      if active or body >= module.codes.len or event.instructionIndex != 0 or
          event.opcode != opBlock or operands.len != 0 or controls.len != 0:
        reject(teFunctionOrder)
      if uint64(module.funcTypeIdxs[body]) >= uint64(module.types.len): reject(teModuleShape)
      active = true
      rootPending = true
      nextPc = 0
      opcode = opBlock
    of veInstructionBegin:
      if not active or rootPending or instructionOpen or controls.len == 0 or
          uint64(event.instructionIndex) != uint64(nextPc): reject(teInstructionOrder)
      let code = module.codes[body].code.code
      if nextPc > code.len: reject(teInstructionOrder)
      opcode = if nextPc == code.len: opEnd else: code[nextPc].op
      if event.opcode != opcode: reject(teInstructionOrder)
      instructionOpen = true
      pushes = 0
      pops = 0
      clears = 0
      havePopped = false
      labelPosition = 0
      fixed = staticRule(opcode)
      if typeEnvironmentKind(uint16(ord(opcode))) != tekNone:
        if nextPc >= code.len: reject(teInstructionOrder)
        fixed = variableRule(module, body, code[nextPc])
        if not fixed.present: reject(teModuleShape)
      fixedPops = 0
      fixedPushes = 0
      call = CallRule()
      if opcode in {opCall, opCallIndirect, opReturnCall, opReturnCallIndirect}:
        if nextPc >= code.len: reject(teInstructionOrder)
        call = callRule(module, body, code[nextPc])
        if not call.present: reject(teModuleShape)
      elif opcode in {opThrow, opThrowRef}:
        let thrown = exceptionRule(module, code[nextPc])
        if not thrown.present: reject(teModuleShape)
        # Shared variable-arity pop replay; the control rules require clear.
        call = CallRule(present: true, inputs: thrown.inputs)
      callPops = 0
      callPushes = 0
    of veOperandPush:
      if not instructionOpen: reject(teInstructionOrder)
      if fixed.present:
        if fixedPops != int(fixed.inputCount) or fixedPushes != 0 or fixed.outputCount != 1 or
            ord(event.valueType) != int(fixed.outputType): reject(teOperandStack)
        inc fixedPushes
      if call.present:
        if callPops != call.inputs.len or callPushes >= call.outputs.len or
            ord(event.valueType) != int(call.outputs[callPushes]): reject(teOperandStack)
        inc callPushes
      operands.add event.valueType
    of veOperandPop:
      if not instructionOpen or controls.len == 0: reject(teInstructionOrder)
      if fixed.present:
        if fixedPops >= int(fixed.inputCount) or fixedPushes != 0 or
            not staticPopMatches(fixed, fixedPops, ord(event.valueType)):
          reject(teOperandStack)
        inc fixedPops
      if call.present:
        if callPops >= call.inputs.len or callPushes != 0 or
            (event.valueType != svUnknown and ord(event.valueType) != int(call.inputs[callPops])):
          reject(teOperandStack)
        inc callPops
      let top = controls[^1]
      if event.polymorphic:
        if operands.len != top.height or not top.unreachable or event.valueType != svUnknown:
          reject(teOperandStack)
      else:
        if operands.len <= top.height or operands[^1] != event.valueType: reject(teOperandStack)
        operands.setLen(operands.len-1)
    of veControlPush:
      if not active or (not rootPending and not instructionOpen): reject(teInstructionOrder)
      if event.frameHeight != operands.len or event.frameUnreachable: reject(teControlStack)
      var inputs, outputs: seq[StackVal]
      var expected: Opcode
      if rootPending:
        if event.instructionIndex != 0: reject(teInstructionOrder)
        expected = opBlock
        outputs = types(module.types[module.funcTypeIdxs[body].int].results)
        rootPending = false
      elif opcode == opElse:
        if not havePopped or lastPopped.opcode != opIf: reject(teControlStack)
        expected = opElse
        inputs = lastPopped.inputs
        outputs = lastPopped.outputs
      else:
        if opcode notin {opBlock, opLoop, opIf, opTryTable}: reject(teControlStack)
        expected = if opcode == opTryTable: opBlock else: opcode
        if not blockTypes(module, module.codes[body].code, nextPc, inputs, outputs):
          reject(teModuleShape)
      if event.frameOpcode != expected or event.startTypes != inputs or event.endTypes != outputs:
        reject(teControlStack)
      controls.add Frame(opcode: expected, height: operands.len, inputs: inputs, outputs: outputs)
      if instructionOpen: inc pushes
    of veControlPop:
      if not instructionOpen or opcode notin {opEnd, opElse} or controls.len == 0:
        reject(teControlStack)
      let frame = controls[^1]
      if operands.len != frame.height or not frame.matches(event): reject(teControlStack)
      lastPopped = frame
      havePopped = true
      controls.setLen(controls.len-1)
      inc pops
    of veUnreachable:
      if not instructionOpen or controls.len == 0 or
          opcode notin {opUnreachable, opBr, opBrTable, opReturn, opReturnCall,
            opReturnCallIndirect, opThrow, opThrowRef}: reject(teControlStack)
      if call.present and (callPops != call.inputs.len or callPushes != 0): reject(teOperandStack)
      if operands.len < controls[^1].height: reject(teOperandStack)
      controls[^1].unreachable = true
      operands.setLen(controls[^1].height)
      if not controls[^1].matches(event): reject(teControlStack)
      inc clears
    of veLabelCheck:
      if not instructionOpen or controls.len == 0:
        reject(teInstructionOrder)
      let instruction = module.codes[body].code.code[nextPc]
      var depth: uint32
      if opcode == opBrTable and labelChecks:
        let banks = module.codes[body].code.brTables
        if uint64(instruction.imm1) >= uint64(banks.len): reject(teModuleShape)
        let bank = banks[int(instruction.imm1)]
        if labelPosition > bank.labels.len: reject(teInstructionOrder)
        depth = if labelPosition == bank.labels.len: bank.defaultLabel else: bank.labels[labelPosition]
      elif opcode == opTryTable and catchChecks:
        let banks = module.codes[body].code.catchTables
        if uint64(instruction.imm2) >= uint64(banks.len): reject(teModuleShape)
        let bank = banks[int(instruction.imm2)]
        if labelPosition >= bank.len or pushes != 0 or fixedPops != 0: reject(teInstructionOrder)
        let clause = bank[labelPosition]
        depth = clause.labelDepth
        if uint64(depth) >= uint64(controls.len): reject(teControlStack)
        let target = controls[controls.len-1-int(depth)]
        let payload = catchPayload(module, clause)
        if not payload.present: reject(teModuleShape)
        let expected = if target.opcode == opLoop: target.inputs else: target.outputs
        if payload.inputs.len != expected.len: reject(teControlStack)
        for i, value in payload.inputs:
          if int(value) != ord(expected[i]): reject(teControlStack)
      else: reject(teInstructionOrder)
      if uint64(depth) >= uint64(controls.len): reject(teControlStack)
      if not controls[controls.len-1-int(depth)].matches(event): reject(teControlStack)
      inc labelPosition
    of veInstructionEnd:
      if not instructionOpen: reject(teInstructionOrder)
      let expectedPushes = if opcode in {opBlock, opLoop, opIf, opElse, opTryTable}: 1 else: 0
      let expectedPops = if opcode in {opEnd, opElse}: 1 else: 0
      let expectedClears = if opcode in {opUnreachable, opBr, opBrTable, opReturn,
        opReturnCall, opReturnCallIndirect, opThrow, opThrowRef}: 1 else: 0
      if pushes != expectedPushes or pops != expectedPops or clears != expectedClears:
        reject(teControlStack)
      if fixed.present and (fixedPops != int(fixed.inputCount) or fixedPushes != int(fixed.outputCount)):
        reject(teOperandStack)
      if call.present and (callPops != call.inputs.len or callPushes != call.outputs.len):
        reject(teOperandStack)
      if labelChecks and opcode == opBrTable:
        let instruction = module.codes[body].code.code[nextPc]
        let banks = module.codes[body].code.brTables
        if uint64(instruction.imm1) >= uint64(banks.len) or
            labelPosition != banks[int(instruction.imm1)].labels.len+1:
          reject(teInstructionOrder)
      if catchChecks and opcode == opTryTable:
        let instruction = module.codes[body].code.code[nextPc]
        let banks = module.codes[body].code.catchTables
        if uint64(instruction.imm2) >= uint64(banks.len) or labelPosition != banks[int(instruction.imm2)].len:
          reject(teInstructionOrder)
      if nextPc == module.codes[body].code.code.len and controls.len != 0:
        reject(teControlStack)
      instructionOpen = false
      inc nextPc
    of veFunctionEnd:
      if not active or instructionOpen or rootPending or controls.len != 0 or operands.len != 0 or
          nextPc != module.codes[body].code.code.len+1: reject(teIncomplete)
      active = false
      inc body
    of veUnsupported: discard # Rejected above.
    if event.kind notin {veFunctionBegin, veInstructionBegin}:
      if event.opcode != opcode or uint64(event.instructionIndex) !=
          uint64(if event.kind == veFunctionEnd: nextPc-1 elif event.kind == veInstructionEnd: nextPc-1 else: nextPc):
        reject(teInstructionOrder)
    if event.operandHeight != operands.len: reject(teOperandStack)
    if event.controlHeight != controls.len: reject(teControlStack)
  position = events.len
  if active or instructionOpen or rootPending or body != module.codes.len:
    reject(teIncomplete)
  TraceCheck(error: teNone, eventIndex: events.len)
