## Exact finite RAM relation for validation stacks and module tables.
## Every read must follow a write to that address and return its latest value.
## This does not bind accesses to WASM instructions; callers must do that.
import std/algorithm
import r1cs, range_check, permutation

type
  MemoryAccess* = object
    active*, write*: bool
    address*, value*: uint64
  MemoryAccessWires* = object
    active*, write*, address*, value*: Linear
  TimedMemoryAccess* = object
    access*: MemoryAccess
    clock*: uint64
  MemoryWitness* = object
    sorted*: seq[TimedMemoryAccess]
    route*: PermutationRoute
  TimedMemoryWires* = object
    access*: MemoryAccessWires
    clock*: Linear

func clockWidth(capacity: int): int =
  var n = capacity
  while n > 1:
    inc result
    n = n shr 1

proc buildMemoryWitness*(accesses: openArray[MemoryAccess]): MemoryWitness =
  discard routeSwitchCount(accesses.len)
  for i, access in accesses:
    result.sorted.add TimedMemoryAccess(access: access, clock: uint64(i))
  result.sorted.sort(proc(a, b: TimedMemoryAccess): int =
    result = cmp(not a.access.active, not b.access.active)
    if result == 0: result = cmp(a.access.address, b.access.address)
    if result == 0: result = cmp(a.clock, b.clock))
  var order = newSeq[int](accesses.len)
  for i, record in result.sorted: order[i] = int(record.clock)
  result.route = permutationRoute(order)

proc constrainAccess(c: var Circuit, access: MemoryAccessWires,
    addressBits, valueBits: int) =
  when defined(zkbuildMemoryAudit):
    let firstGate = c.constraints.len
  c.constrainBoolean(access.active)
  c.constrainBoolean(access.write)
  discard c.constrainUnsigned(access.address, addressBits)
  when defined(zkbuildMemoryAudit):
    let addressRange = c.latestMemoryRange()
  discard c.constrainUnsigned(access.value, valueBits)
  when defined(zkbuildMemoryAudit):
    let valueRange = c.latestMemoryRange()
  let inactive = constant(1)-access.active
  c.constrain(inactive, access.write, constant(0))
  c.constrain(inactive, access.address, constant(0))
  c.constrain(inactive, access.value, constant(0))
  when defined(zkbuildMemoryAudit):
    c.recordMemoryAccess(firstGate,[access.active,access.write,access.address,access.value],addressRange,valueRange)

proc allocateAccess(c: var Circuit, access: MemoryAccess): MemoryAccessWires =
  result.active = c.allocate(scalar(ord(access.active)))
  result.write = c.allocate(scalar(ord(access.write)))
  result.address = c.allocate(scalar(access.address))
  result.value = c.allocate(scalar(access.value))

proc pack*(access: MemoryAccessWires, clock: Linear, timeBits, valueBits: int): Linear =
  let flags = scalar(2).power(uint64(valueBits))
  let time = flags*scalar(4)
  let address = time*scalar(2).power(uint64(timeBits))
  access.value + access.write.scale(flags) + access.active.scale(flags*scalar(2)) +
    clock.scale(time) + access.address.scale(address)

proc orderKey*(row: TimedMemoryWires, addressBits, timeBits: int): Linear =
  let time = scalar(2).power(uint64(timeBits))
  let inactive = time*scalar(2).power(uint64(addressBits))
  (constant(1)-row.access.active).scale(inactive) + row.access.address.scale(time) + row.clock

proc constrainMemory*(c: var Circuit, input: openArray[MemoryAccessWires],
    witness: MemoryWitness, addressBits, valueBits: int): seq[TimedMemoryWires] =
  ## Dimensions and field widths define the circuit. Sorted records and switch
  ## bits are private witness values and never alter its matrix.
  discard routeSwitchCount(input.len)
  if addressBits < 1 or addressBits > 64 or valueBits < 1 or valueBits > 64 or
      witness.sorted.len != input.len or witness.route.capacity != input.len or
      witness.route.switches.len != routeSwitchCount(input.len):
    raise newException(ValueError, "invalid memory circuit dimensions")
  let timeBits = clockWidth(input.len)
  when defined(zkbuildMemoryAudit):
    var audit = MemoryAudit(addressBits: addressBits,timeBits: timeBits,valueBits: valueBits)
  var packed: seq[Linear]
  for i, access in input:
    c.constrainAccess(access, addressBits, valueBits)
    when defined(zkbuildMemoryAudit):
      audit.inputs.add c.memoryAccessRecords[^1]
    packed.add pack(access, constant(i), timeBits, valueBits)
  let reordered = c.constrainPermutation(packed, witness.route)
  when defined(zkbuildMemoryAudit):
    audit.network = c.permutationRecords[^1]
  for i, record in witness.sorted:
    let row = TimedMemoryWires(access: c.allocateAccess(record.access),
      clock: c.allocate(scalar(record.clock)))
    c.constrainAccess(row.access, addressBits, valueBits)
    when defined(zkbuildMemoryAudit):
      let accessAudit = c.memoryAccessRecords[^1]
    discard c.constrainUnsigned(row.clock, timeBits)
    when defined(zkbuildMemoryAudit):
      var rowAudit = MemoryRowAudit(access: accessAudit,clock: row.clock,clockRange: c.latestMemoryRange(),
        firstWire: c.values.len,firstGate: c.constraints.len)
    c.assertEqual(reordered[i], pack(row.access, row.clock, timeBits, valueBits))
    let read = row.access.active-row.access.write
    if i == 0:
      c.assertEqual(read, constant(0))
    else:
      let previous = result[i-1]
      let delta = orderKey(row, addressBits, timeBits)-
        orderKey(previous, addressBits, timeBits)-constant(1)
      discard c.constrainUnsigned(delta, addressBits+timeBits+1)
      let sameAddress = c.zeroIndicator(row.access.address-previous.access.address)
      c.constrain(read, constant(1)-sameAddress, constant(0))
      c.constrain(read, row.access.value-previous.access.value, constant(0))
    when defined(zkbuildMemoryAudit):
      rowAudit.lastWire = c.values.len
      rowAudit.lastGate = c.constraints.len
      audit.rows.add rowAudit
    result.add row
  when defined(zkbuildMemoryAudit):
    c.memoryRecords.add audit
