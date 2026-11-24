## Core section order is not numeric: tags precede globals and data count
## precedes code. Zero is a custom section; negative means an unknown ID.
func binarySectionOrder*(id: int): int =
  case id
  of 0: 0
  of 1..5: id
  of 13: 6
  of 6..9: id+1
  of 12: 11
  of 10: 12
  of 11: 13
  else: -1
