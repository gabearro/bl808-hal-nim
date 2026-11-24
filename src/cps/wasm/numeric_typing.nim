## Fixed stack signatures for core numeric opcodes and saturating conversions.
## This is shared by validation and the prover's transcript relation.
import ./types

type NumericRule* = object
  present*: bool
  inputCount*: uint8
  inputType*, outputType*: ValType

func rule(input, output: ValType, count: uint8 = 1): NumericRule =
  NumericRule(present: true, inputCount: count, inputType: input, outputType: output)

func numericRuleForCode*(code: uint16): NumericRule =
  case int(code)
  of 0x41: rule(vtI32, vtI32, 0)
  of 0x42: rule(vtI64, vtI64, 0)
  of 0x43: rule(vtF32, vtF32, 0)
  of 0x44: rule(vtF64, vtF64, 0)
  of 0x45, 0x67..0x69, 0xc0..0xc1: rule(vtI32, vtI32)
  of 0x46..0x4f, 0x6a..0x78: rule(vtI32, vtI32, 2)
  of 0x50: rule(vtI64, vtI32)
  of 0x51..0x5a: rule(vtI64, vtI32, 2)
  of 0x5b..0x60: rule(vtF32, vtI32, 2)
  of 0x61..0x66: rule(vtF64, vtI32, 2)
  of 0x79..0x7b, 0xc2..0xc4: rule(vtI64, vtI64)
  of 0x7c..0x8a: rule(vtI64, vtI64, 2)
  of 0x8b..0x91: rule(vtF32, vtF32)
  of 0x92..0x98: rule(vtF32, vtF32, 2)
  of 0x99..0x9f: rule(vtF64, vtF64)
  of 0xa0..0xa6: rule(vtF64, vtF64, 2)
  of 0xa7: rule(vtI64, vtI32)
  of 0xa8..0xa9, 0xbc, 0x100..0x101: rule(vtF32, vtI32)
  of 0xaa..0xab, 0x102..0x103: rule(vtF64, vtI32)
  of 0xac..0xad: rule(vtI32, vtI64)
  of 0xae..0xaf, 0x104..0x105: rule(vtF32, vtI64)
  of 0xb0..0xb1, 0xbd, 0x106..0x107: rule(vtF64, vtI64)
  of 0xb2..0xb3, 0xbe: rule(vtI32, vtF32)
  of 0xb4..0xb5: rule(vtI64, vtF32)
  of 0xb6: rule(vtF64, vtF32)
  of 0xb7..0xb8: rule(vtI32, vtF64)
  of 0xb9..0xba, 0xbf: rule(vtI64, vtF64)
  of 0xbb: rule(vtF32, vtF64)
  else: NumericRule()

func numericRule*(opcode: Opcode): NumericRule = numericRuleForCode(uint16(ord(opcode)))
