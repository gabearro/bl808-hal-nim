## Exact membership in an immutable, strictly ordered finite table.
## Initialization precedes all queries. Inactive entries and queries are zero.
## Binding the table itself to the module/binary is a separate obligation.
import r1cs, range_check, memory_consistency

type
  ReadOnlyEntry* = object
    active*: bool
    address*, value*: uint64
  ReadOnlyWires* = object
    active*, address*, value*: Linear

proc readOnlyCapacity*(entries, queries: int): int =
  if entries < 0 or queries < 0 or entries > high(int)-queries:
    raise newException(ValueError, "invalid read-only table dimensions")
  result = 1
  while result < entries+queries:
    if result > high(int) div 2:
      raise newException(ValueError, "read-only table capacity overflow")
    result *= 2

proc buildReadOnlyWitness*(entries, queries: openArray[ReadOnlyEntry]): MemoryWitness =
  var accesses = newSeq[MemoryAccess](readOnlyCapacity(entries.len, queries.len))
  for i, entry in entries:
    accesses[i] = MemoryAccess(active: entry.active, write: entry.active,
      address: entry.address, value: entry.value)
  for i, query in queries:
    accesses[entries.len+i] = MemoryAccess(active: query.active,
      address: query.address, value: query.value)
  buildMemoryWitness(accesses)

proc constrainReadOnly*(c: var Circuit, entries, queries: openArray[ReadOnlyWires],
    witness: MemoryWitness, addressBits, valueBits: int) =
  ## All sizes are profile constants. The sorted permutation is private.
  ## Strictly ordered initialization forbids duplicate/overwritten keys;
  ## query records have no write wire that a prover can turn on.
  if addressBits < 1 or addressBits > 64 or valueBits < 1 or valueBits > 64:
    raise newException(ValueError, "invalid read-only field width")
  when defined(zkbuildReadOnlyAudit):
    var audit = ReadOnlyAudit(firstGate: c.constraints.len)
    for entry in entries: audit.entries.add copyAuditExpressions([entry.active,entry.address,entry.value])
    for query in queries: audit.queries.add copyAuditExpressions([query.active,query.address,query.value])
  var accesses: seq[MemoryAccessWires]
  for i, entry in entries:
    if i != 0:
      c.constrain(entry.active, constant(1)-entries[i-1].active, constant(0))
      let delta = c.selectWire(entry.active, entry.address-entries[i-1].address-constant(1), constant(0))
      discard c.constrainUnsigned(delta, addressBits)
      when defined(zkbuildReadOnlyAudit):
        audit.order.add ReadOnlyOrderAudit(delta: copyAuditExpressions([delta])[0],range: c.snapshotRangeUse())
    accesses.add MemoryAccessWires(active: entry.active, write: entry.active,
      address: entry.address, value: entry.value)
  for query in queries:
    accesses.add MemoryAccessWires(active: query.active, write: constant(0),
      address: query.address, value: query.value)
  let capacity = readOnlyCapacity(entries.len, queries.len)
  while accesses.len < capacity:
    accesses.add MemoryAccessWires(active: constant(0), write: constant(0),
      address: constant(0), value: constant(0))
  when defined(zkbuildReadOnlyAudit): audit.preludeEnd = c.constraints.len
  discard c.constrainMemory(accesses, witness, addressBits, valueBits)
  when defined(zkbuildReadOnlyAudit):
    audit.memoryIndex = c.memoryRecords.len-1
    c.readOnlyRecords.add audit
