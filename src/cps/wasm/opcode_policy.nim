## Closed opcode set for unfused binary-validation proofs.
import static_typing, variable_typing

func admittedOpcode*(code: uint16): bool =
  if staticRuleForCode(code).present or typeEnvironmentKind(code) != tekNone: return true
  code in [2'u16, 3, 4, 5, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    0x1b, 0x1c, 0x1f, 0xd0]
