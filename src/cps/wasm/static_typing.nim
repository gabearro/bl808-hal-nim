## Fixed instruction stack signatures. Inputs are in pop order (top first).
## Environment/immediate validity is separate from these type effects.
import types, numeric_typing

const
  AnyStackType* = 8'u8
  ReferenceStackType* = 9'u8

type StaticRule* = object
  present*: bool
  inputCount*, outputCount*, outputType*, clearCount*: uint8
  inputs*: array[3, uint8]

func makeRule(inputs: openArray[uint8], output = -1, clear = false): StaticRule =
  result.present = true
  result.inputCount = uint8(inputs.len)
  for i, value in inputs: result.inputs[i] = value
  if output >= 0:
    result.outputCount = 1
    result.outputType = uint8(output)
  result.clearCount = uint8(ord(clear))

func staticRuleForCode*(code: uint16): StaticRule =
  let numeric = numericRuleForCode(code)
  if numeric.present:
    result.present = true
    result.inputCount = numeric.inputCount
    result.outputCount = 1
    result.outputType = uint8(127-ord(numeric.outputType))
    for i in 0..<int(numeric.inputCount): result.inputs[i] = uint8(127-ord(numeric.inputType))
    return
  case int(code)
  of 0x00: makeRule([], clear = true)
  of 0x01: makeRule([])
  of 0x1a: makeRule([AnyStackType])
  of 0x28, 0x2c..0x2f: makeRule([0'u8], 0)
  of 0x29, 0x30..0x35: makeRule([0'u8], 1)
  of 0x2a: makeRule([0'u8], 2)
  of 0x2b: makeRule([0'u8], 3)
  of 0x36, 0x3a..0x3b: makeRule([0'u8, 0])
  of 0x37, 0x3c..0x3e: makeRule([1'u8, 0])
  of 0x38: makeRule([2'u8, 0])
  of 0x39: makeRule([3'u8, 0])
  of 0x3f, 0x110: makeRule([], 0)
  of 0x40: makeRule([0'u8], 0)
  of 0xd1: makeRule([ReferenceStackType], 0)
  of 0xd2: makeRule([], 5)
  of 0x108, 0x10a..0x10c, 0x10e: makeRule([0'u8, 0, 0])
  of 0x109, 0x10d: makeRule([])
  of 0x300: makeRule([0'u8], 4)
  of 0x301: makeRule([4'u8, 0])
  of 0x302: makeRule([], 4)
  of 0x303..0x305: makeRule([0'u8], 4)
  of 0x306: makeRule([1'u8], 4)
  of 0x307: makeRule([2'u8], 4)
  of 0x308: makeRule([3'u8], 4)
  of 0x309, 0x318..0x319, 0x31b..0x31c: makeRule([4'u8], 0)
  of 0x30a, 0x31a, 0x31d, 0x332..0x334: makeRule([0'u8, 4], 4)
  of 0x30b: makeRule([4'u8], 2)
  of 0x30c: makeRule([2'u8, 4], 4)
  of 0x30d, 0x323..0x324, 0x32b..0x32c, 0x330..0x331, 0x33b..0x33e:
    makeRule([4'u8], 4)
  of 0x30e..0x317, 0x322, 0x325..0x32a, 0x32d..0x32f, 0x335..0x33a, 0x33f..0x342:
    makeRule([4'u8, 4], 4)
  of 0x31e: makeRule([4'u8], 1)
  of 0x31f: makeRule([1'u8, 4], 4)
  of 0x320: makeRule([4'u8], 3)
  of 0x321: makeRule([3'u8, 4], 4)
  else: StaticRule()

func staticRule*(opcode: Opcode): StaticRule = staticRuleForCode(uint16(ord(opcode)))

func staticPopMatches*(rule: StaticRule, index, actual: int): bool =
  if not rule.present or index < 0 or index >= int(rule.inputCount) or actual < 0 or actual > 7:
    return false
  let expected = rule.inputs[index]
  actual == 7 or expected == AnyStackType or
    (expected == ReferenceStackType and actual in {5, 6}) or actual == int(expected)

func simdLaneCount*(code: uint16): uint32 =
  case int(code)
  of 0x309..0x30c: 4
  of 0x318..0x31a: 16
  of 0x31b..0x31d: 8
  of 0x31e..0x321: 2
  else: 0
