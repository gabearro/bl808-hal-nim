## Independent test-oracle input: direct module block types and the structurally
## replayed validation frames. No proving-table or frame-witness decoder is used.
import std/[strutils, sequtils]
import cps/wasm/[types, validate, variable_typing, block_types]
import cps/zk/wasm_trace_check

type Frame = object
  opcode: Opcode
  params, results: seq[int]

proc tags(values: seq[ValType]): seq[int] =
  for value in values: result.add int(stackTypeTag(value))

proc blockTypes(module: WasmModule, pad: uint64): tuple[params, results: seq[int]] =
  if pad == 0: discard
  elif pad <= 7: result.results = @[int(pad)-1]
  else:
    result.params = tags(module.types[int(pad)-0x100].params)
    result.results = tags(module.types[int(pad)-0x100].results)

proc controlPlanCases*(module: WasmModule, events: seq[ValidationEvent]): seq[string] =
  if not checkValidationTraceStructure(module, events).accepted:
    raise newException(ValueError, "control oracle requires structurally replayed traces")
  var imports: uint32
  for item in module.imports:
    if item.kind == ikFunc: inc imports
  var frames: seq[Frame]
  var header, params, results, labels, actions: seq[int]
  var active = false
  for event in events:
    if event.kind == veInstructionBegin:
      let code = ord(event.opcode)
      active = code in [2, 3, 4, 5, 11, 12, 13, 15, 31]
      if active:
        params = @[]; results = @[]; labels = @[]; actions = @[]
        var root, implicitElse: int
        let body = int(event.functionIndex-imports)
        let instructions = module.codes[body].code.code
        let instruction = if int(event.instructionIndex) < instructions.len:
            instructions[int(event.instructionIndex)] else: Instr(op: opEnd)
        case event.opcode
        of opBlock, opLoop, opIf, opTryTable:
          let types = blockTypes(module, normalizedBlockPad(module.codes[body].code, int(event.instructionIndex)))
          params = types.params
          results = types.results
        of opEnd, opElse:
          params = frames[^1].params
          results = frames[^1].results
          root = ord(event.opcode == opEnd and frames.len == 1)
          implicitElse = ord(event.opcode == opEnd and frames[^1].opcode == opIf)
        of opBr, opBrIf:
          let target = frames[frames.len-1-int(instruction.imm1)]
          labels = if target.opcode == opLoop: target.params else: target.results
        of opReturn: results = frames[0].results
        else: discard
        header = @[code, root, implicitElse]
    elif event.kind == veInstructionEnd:
      if active:
        let fields = header & @[params.len, results.len, labels.len, actions.len] & params & results & labels & actions
        result.add fields.mapIt($it).join(" ")
      active = false
    else:
      if active:
        case event.kind
        of veOperandPop: actions.add ord(event.valueType)
        of veOperandPush: actions.add 16+ord(event.valueType)
        of veControlPush: actions.add 32
        of veControlPop: actions.add 33
        of veUnreachable: actions.add 34
        else: discard
      case event.kind
      of veControlPush:
        var frame = Frame(opcode: event.frameOpcode)
        for value in event.startTypes: frame.params.add ord(value)
        for value in event.endTypes: frame.results.add ord(value)
        frames.add frame
      of veControlPop: frames.setLen(frames.len-1)
      else: discard
