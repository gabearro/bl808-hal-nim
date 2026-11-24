## Preserve 12-byte instructions while retaining every u32 block type index.
import types

const WideBlockPad* = 0xff'u16

func wideBlockIndex*(expression: Expr, pc: int): uint32 =
  var first = 0
  var last = expression.wideBlockTypes.len
  while first < last:
    let middle = first+(last-first) div 2
    if uint64(expression.wideBlockTypes[middle].pc) < uint64(pc): first = middle+1
    else: last = middle
  if first >= expression.wideBlockTypes.len or uint64(expression.wideBlockTypes[first].pc) != uint64(pc):
    raise newException(ValueError, "missing extended block type")
  expression.wideBlockTypes[first].typeIndex

func normalizedBlockPad*(expression: Expr, pc: int): uint64 =
  let instruction = expression.code[pc]
  if instruction.pad == WideBlockPad and instruction.op in {opBlock, opLoop, opIf, opTryTable}:
    uint64(expression.wideBlockIndex(pc))+0x100'u64
  else: uint64(instruction.pad)

func resolveBlockType*(expression: Expr, pc: int): BlockType =
  let pad = expression.normalizedBlockPad(pc)
  if pad == 0: return BlockType(kind: btkEmpty)
  if pad >= 0x100: return BlockType(kind: btkTypeIdx, typeIdx: uint32(pad-0x100))
  const Values = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]
  if pad > 7: raise newException(ValueError, "invalid compact block type")
  BlockType(kind: btkValType, valType: Values[int(pad)-1])
