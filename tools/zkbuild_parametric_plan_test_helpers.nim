## Independent action plans from original module immediates and replayed
## events. No R1CS wires or parametric constraint helper is inspected here.
import std/[strutils, sequtils]
import cps/wasm/[types, validate]
import cps/zk/wasm_trace_check

proc parametricPlanCases*(module: WasmModule, events: seq[ValidationEvent]): seq[string] =
  if not checkValidationTraceStructure(module, events).accepted:
    raise newException(ValueError, "parametric oracle requires structurally replayed traces")
  var imports = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc imports
  var active = false
  var opcode, immediate: int
  var actions: seq[int]
  for event in events:
    if event.kind == veInstructionBegin:
      active = event.opcode in [opSelect, opSelectTyped, opRefNull]
      if active:
        opcode = ord(event.opcode)
        immediate = int(module.codes[int(event.functionIndex-imports)].code.code[int(event.instructionIndex)].imm1)
        actions = @[]
    elif event.kind == veInstructionEnd:
      if active:
        result.add (@[opcode, immediate, actions.len] & actions).mapIt($it).join(" ")
      active = false
    elif active:
      if event.kind == veOperandPop: actions.add ord(event.valueType)
      elif event.kind == veOperandPush: actions.add 16+ord(event.valueType)
      else: actions.add 32
