## Exact, shared UTF-8 strings. Canonical byte/tail cells make head equality
## equivalent to string equality; export uniqueness needs no hash collision
## assumption and no pairwise string comparisons. Binary provenance is separate.
import std/[tables, algorithm]
import r1cs, range_check, read_only_memory, memory_consistency, opcode_lookup

type
  NameEnvironment* = object
    nodes*, canonical*: seq[ReadOnlyEntry]
    heads*: seq[uint32]
  NameEnvironmentWires* = object
    nodes*, canonical*: seq[ReadOnlyWires]
    heads*: seq[Linear]
  NameWitness* = object
    tails*, roots*: seq[ReadOnlyEntry]
    nodes*, canonical*: MemoryWitness

func utf8Suffix*(value, tailState, tailHigh: int): int =
  ## -1 is invalid; 0 is a complete scalar suffix; 1..3 are leading
  ## continuation bytes waiting for their scalar's lead byte.
  if value < 128 and tailState == 0: return 0
  if value in 128..191 and tailState < 3: return tailState+1
  if value in 194..223 and tailState == 1: return 0
  if value in 224..239 and tailState == 2 and
      (value != 224 or tailHigh >= 10) and (value != 237 or tailHigh < 10): return 0
  if value in 240..244 and tailState == 3 and
      (value != 240 or tailHigh >= 9) and (value != 244 or tailHigh < 9): return 0
  -1

proc suffixTable(): OpcodeLookup[2] =
  var values = newSeq[array[2, int]](65536)
  for code in 0..<16384:
    let state = utf8Suffix(code and 255, (code shr 8) and 3, (code shr 10) and 15)
    if state >= 0: values[code] = [1, state]
  buildOpcodeLookup(values)

let suffixes = suffixTable()

proc buildNameEnvironment*(names: openArray[string], nodeCapacity = 0): NameEnvironment =
  if nodeCapacity < 0: raise newException(ValueError, "invalid name capacity")
  var interned: Table[uint64, uint32]
  for name in names:
    var head = 0'u32
    var state, tailHigh: int
    for i in countdown(name.high, 0):
      let value = int(uint8(name[i]))
      let key = uint64(value)+(uint64(head) shl 8)
      if interned.hasKey(key):
        head = interned[key]
        state = int(result.nodes[int(head)-1].value shr 40)
      else:
        state = utf8Suffix(value, state, tailHigh)
        if state < 0: raise newException(ValueError, "invalid UTF-8 name suffix")
        if uint64(result.nodes.len) >= uint64(high(uint32)):
          raise newException(ValueError, "name node index overflow")
        let id = uint32(result.nodes.len+1)
        result.nodes.add ReadOnlyEntry(active: true, address: uint64(id), value: key+(uint64(state) shl 40))
        interned[key] = id
        head = id
      tailHigh = value shr 4
    if state != 0: raise newException(ValueError, "incomplete UTF-8 name")
    result.heads.add head
  for key, id in interned: result.canonical.add ReadOnlyEntry(active: true, address: key, value: uint64(id))
  result.canonical.sort(proc(a, b: ReadOnlyEntry): int = cmp(a.address, b.address))
  if nodeCapacity != 0:
    if result.nodes.len > nodeCapacity: raise newException(ValueError, "name profile overflow")
    result.nodes.setLen(nodeCapacity)
    result.canonical.setLen(nodeCapacity)

proc buildNameWitness*(environment: NameEnvironment): NameWitness =
  var nodes: Table[uint64, uint64]
  for entry in environment.nodes:
    if entry.active: nodes[entry.address] = entry.value
  var canonical: seq[ReadOnlyEntry]
  for entry in environment.nodes:
    let tail = (entry.value shr 8) and 0xffffffff'u64
    result.tails.add(if entry.active and tail != 0:
      ReadOnlyEntry(active: true, address: tail, value: nodes.getOrDefault(tail)) else: ReadOnlyEntry())
    canonical.add(if entry.active: ReadOnlyEntry(active: true,
      address: entry.value and 0xffffffffff'u64, value: entry.address) else: ReadOnlyEntry())
  for head in environment.heads:
    result.roots.add(if head != 0: ReadOnlyEntry(active: true,
      address: uint64(head), value: nodes.getOrDefault(uint64(head))) else: ReadOnlyEntry())
  result.nodes = buildReadOnlyWitness(environment.nodes, result.tails & result.roots)
  result.canonical = buildReadOnlyWitness(environment.canonical, canonical)

proc allocateNames*(c: var Circuit, environment: NameEnvironment, publicInputs = false): NameEnvironmentWires =
  template input(number: uint64): Linear =
    (if publicInputs: c.publicInput(scalar(number)) else: c.allocate(scalar(number)))
  for entry in environment.nodes:
    result.nodes.add ReadOnlyWires(active: input(uint64(ord(entry.active))),
      address: input(entry.address), value: input(entry.value))
  for entry in environment.canonical:
    result.canonical.add ReadOnlyWires(active: input(uint64(ord(entry.active))),
      address: input(entry.address), value: input(entry.value))
  for head in environment.heads: result.heads.add input(uint64(head))

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var sum: Linear
  for i, bit in bits: sum = sum+bit.scale(scalar(1'u64 shl i))
  c.materialize(sum)

proc constrainNames*(c: var Circuit, environment: NameEnvironmentWires, witness: NameWitness) =
  if environment.nodes.len != witness.tails.len or environment.heads.len != witness.roots.len:
    raise newException(ValueError, "name circuit dimensions differ")
  when defined(zkbuildNameGraphAudit):
    var graph: NameGraphAudit
  var queries, canonical: seq[ReadOnlyWires]
  for i, entry in environment.nodes:
    when defined(zkbuildNameGraphAudit):
      var record = NameNodeAudit(firstGate: c.constraints.len,
        entry: copyAuditExpressions([entry.active,entry.address,entry.value]))
    c.constrain(entry.active, entry.address-constant(i+1), constant(0))
    let bits = c.constrainUnsigned(entry.value, 42)
    when defined(zkbuildNameGraphAudit): record.ranges.add c.snapshotRangeUse()
    let value = c.pack(bits[0..7])
    let tail = c.pack(bits[8..39])
    let state = c.pack(bits[40..41])
    when defined(zkbuildNameGraphAudit): record.zeroStart = c.values.len
    let nonempty = c.multiply(entry.active, constant(1)-c.zeroIndicator(tail))
    let next = c.allocate(scalar(witness.tails[i].value))
    queries.add ReadOnlyWires(active: nonempty, address: c.multiply(nonempty, tail), value: next)
    let nextBits = c.constrainUnsigned(next, 42)
    when defined(zkbuildNameGraphAudit): record.ranges.add c.snapshotRangeUse()
    let nextState = c.pack(nextBits[40..41])
    let nextHigh = c.pack(nextBits[4..7])
    let lookup = c.constrainLookup(suffixes, value+nextState.scale(scalar(256))+nextHigh.scale(scalar(1024)))
    when defined(zkbuildNameGraphAudit): record.lookup = c.lookupRecords[^1]
    c.constrain(entry.active, lookup[0]-constant(1), constant(0))
    c.constrain(entry.active, state-lookup[1], constant(0))
    let delta = c.multiply(entry.active, entry.address-tail-constant(1))
    discard c.constrainUnsigned(delta, 32)
    when defined(zkbuildNameGraphAudit): record.ranges.add c.snapshotRangeUse()
    canonical.add ReadOnlyWires(active: entry.active,
      address: c.multiply(entry.active, value+tail.scale(scalar(256))), value: entry.address)
    when defined(zkbuildNameGraphAudit):
      record.fields = copyAuditExpressions([value,tail,state,nonempty,nextState,nextHigh,delta])
      record.query = copyAuditExpressions([queries[^1].active,queries[^1].address,queries[^1].value])
      record.canonical = copyAuditExpressions([canonical[^1].active,canonical[^1].address,canonical[^1].value])
      record.lastGate = c.constraints.len
      graph.nodes.add record
  for i, head in environment.heads:
    when defined(zkbuildNameGraphAudit):
      var record = NameRootAudit(firstGate: c.constraints.len,head: copyAuditExpressions([head])[0])
    discard c.constrainUnsigned(head, 32)
    when defined(zkbuildNameGraphAudit):
      record.ranges.add c.snapshotRangeUse()
      record.zeroStart = c.values.len
    let active = constant(1)-c.zeroIndicator(head)
    let value = c.allocate(scalar(witness.roots[i].value))
    queries.add ReadOnlyWires(active: active, address: head, value: value)
    let bits = c.constrainUnsigned(value, 42)
    when defined(zkbuildNameGraphAudit): record.ranges.add c.snapshotRangeUse()
    let state = c.pack(bits[40..41])
    c.assertEqual(state, constant(0))
    when defined(zkbuildNameGraphAudit):
      record.state = copyAuditExpressions([state])[0]
      record.query = copyAuditExpressions([queries[^1].active,queries[^1].address,queries[^1].value])
      record.lastGate = c.constraints.len
      graph.roots.add record
  when defined(zkbuildNameGraphAudit): graph.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.nodes, queries, witness.nodes, 32, 42)
  when defined(zkbuildNameGraphAudit): graph.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.canonical, canonical, witness.canonical, 40, 32)
  when defined(zkbuildNameGraphAudit): c.nameGraphRecords.add graph
