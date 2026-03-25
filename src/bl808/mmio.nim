## Memory-mapped I/O primitives for BL808.
##
## All peripheral register access goes through these routines,
## which guarantee volatile semantics.

proc regRead*(address: uint): uint32 {.inline.} =
  ## Read a 32-bit memory-mapped register.
  volatileLoad(cast[ptr uint32](address))

proc regWrite*(address: uint, value: uint32) {.inline.} =
  ## Write a 32-bit memory-mapped register.
  volatileStore(cast[ptr uint32](address), value)

proc regSet*(address: uint, mask: uint32) {.inline.} =
  ## Set bits in a register (read-modify-write).
  regWrite(address, regRead(address) or mask)

proc regClear*(address: uint, mask: uint32) {.inline.} =
  ## Clear bits in a register (read-modify-write).
  regWrite(address, regRead(address) and not mask)

proc regModify*(address: uint, mask, value: uint32) {.inline.} =
  ## Modify a bitfield: clears `mask` bits then sets `value` bits.
  regWrite(address, (regRead(address) and not mask) or (value and mask))

proc regWaitSet*(address: uint, mask: uint32, timeout: uint32 = 1_000_000): bool {.inline.} =
  ## Spin until all bits in `mask` are set, or timeout. Returns true on success.
  var countdown = timeout
  while (regRead(address) and mask) != mask:
    countdown.dec
    if countdown == 0: return false
  true

proc regWaitClear*(address: uint, mask: uint32, timeout: uint32 = 1_000_000): bool {.inline.} =
  ## Spin until all bits in `mask` are clear, or timeout. Returns true on success.
  var countdown = timeout
  while (regRead(address) and mask) != 0'u32:
    countdown.dec
    if countdown == 0: return false
  true

template fieldVal*(value: uint32, shift: int, width: int): uint32 =
  ## Extract a bitfield from a register value.
  (value shr shift) and ((1'u32 shl width) - 1)

template fieldMask*(shift: int, width: int): uint32 =
  ## Generate a bitmask for a bitfield.
  ((1'u32 shl width) - 1) shl shift

template fieldSet*(shift: int, value: uint32): uint32 =
  ## Shift a value into position for a bitfield.
  value shl shift
