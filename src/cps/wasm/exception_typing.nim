## Direct signature resolution for independent transcript replay. exnref is
## currently represented as externref by this runtime, including throw_ref.
import types, variable_typing

type ExceptionRule* = object
  present*: bool
  inputs*: seq[uint8]

proc exceptionRule*(module: WasmModule, instruction: Instr): ExceptionRule =
  if instruction.op == opThrowRef:
    return ExceptionRule(present: true, inputs: @[6'u8])
  if instruction.op != opThrow: return
  let typeIndex = module.tagTypeIndex(instruction.imm1)
  if typeIndex < 0 or typeIndex >= module.types.len.int64: return
  let signature = module.types[int(typeIndex)]
  if signature.results.len != 0: return
  for i in countdown(signature.params.high, 0): result.inputs.add stackTypeTag(signature.params[i])
  result.present = true

proc catchPayload*(module: WasmModule, clause: CatchClause): ExceptionRule =
  ## Payload order on the target label, independent of operand-stack pops.
  if clause.kind in {ckCatch, ckCatchRef}:
    let index = module.tagTypeIndex(clause.tagIdx)
    if index < 0 or index >= module.types.len.int64 or module.types[int(index)].results.len != 0: return
    for value in module.types[int(index)].params: result.inputs.add stackTypeTag(value)
  if clause.kind in {ckCatchRef, ckCatchAllRef}: result.inputs.add 6
  result.present = true
