## Independent oracle: module branch banks and structurally replayed frames.
## It does not decode any proving-table, frame-token, or scratch witness.
import std/[sequtils, strutils]
import cps/wasm/[types, validate]
import cps/zk/wasm_trace_check

type Frame = object
  opcode: Opcode
  params, results: seq[int]

proc branchPlanCases*(module: WasmModule, events: seq[ValidationEvent]): seq[string] =
  if not checkValidationTraceStructure(module, events, labelChecks = true).accepted:
    raise newException(ValueError, "branch oracle requires structurally replayed traces")
  var first = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc first
  var frames: seq[Frame]
  var active = false
  var targets, actions: seq[int]
  var count: int
  for event in events:
    if event.kind == veInstructionBegin:
      active = event.opcode == opBrTable
      if active:
        targets = @[]; actions = @[]
        let body = module.codes[int(event.functionIndex-first)]
        let bank = body.code.brTables[int(body.code.code[int(event.instructionIndex)].imm1)]
        count = bank.labels.len+1
        for depth in bank.labels & @[bank.defaultLabel]:
          let frame = frames[frames.len-1-int(depth)]
          let values = if frame.opcode == opLoop: frame.params else: frame.results
          targets.add values.len
          for i in countdown(values.high, 0): targets.add values[i]
    elif event.kind == veInstructionEnd:
      if active:
        result.add (@[count, actions.len] & targets & actions).mapIt($it).join(" ")
      active = false
    else:
      if active:
        case event.kind
        of veOperandPop: actions.add ord(event.valueType)
        of veOperandPush: actions.add 16+ord(event.valueType)
        of veLabelCheck: actions.add 32
        of veUnreachable: actions.add 33
        else: discard
      case event.kind
      of veControlPush:
        var frame = Frame(opcode: event.frameOpcode)
        for value in event.startTypes: frame.params.add ord(value)
        for value in event.endTypes: frame.results.add ord(value)
        frames.add frame
      of veControlPop: frames.setLen(frames.len-1)
      else: discard
