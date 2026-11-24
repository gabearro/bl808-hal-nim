## Deterministic reduced decision DAG for fixed opcode metadata. Its topology
## and payloads are profile constants; no witness selects which gates exist.
import std/tables
import r1cs, range_check

type
  OpcodeNode[N: static[int]] = object
    bit, zero, one: int
    value: array[N, int]
  OpcodeLookup*[N: static[int]] = object
    nodes: seq[OpcodeNode[N]]
    root: int

proc buildOpcodeLookup*[N: static[int]](values: openArray[array[N, int]]): OpcodeLookup[N] =
  if values.len != 65536: raise newException(ValueError, "opcode lookup requires a full 16-bit table")
  let payloads = @values
  var nodes: seq[OpcodeNode[N]]
  var interned: Table[tuple[bit, zero, one: int, value: array[N, int]], int]
  proc intern(node: OpcodeNode[N]): int =
    let key = (node.bit, node.zero, node.one, node.value)
    if interned.hasKey(key): return interned[key]
    result = nodes.len
    nodes.add node
    interned[key] = result
  proc tree(first, span, bit: int): int =
    let value = payloads[first]
    var uniform = true
    for i in first+1..<first+span:
      if payloads[i] != value: uniform = false; break
    if uniform: return intern(OpcodeNode[N](bit: -1, value: value))
    let half = span div 2
    let zero = tree(first, half, bit-1)
    let one = tree(first+half, half, bit-1)
    intern(OpcodeNode[N](bit: bit, zero: zero, one: one))
  result.root = tree(0, 65536, 15)
  result.nodes = nodes
  for i, node in nodes:
    if node.bit >= 0: doAssert node.zero < i and node.one < i

proc lookupBranches*[N: static[int]](table: OpcodeLookup[N]): int =
  for node in table.nodes:
    if node.bit >= 0: inc result

proc lookupValue*[N: static[int]](table: OpcodeLookup[N], code: uint16): array[N, int] =
  var index = table.root
  while table.nodes[index].bit >= 0:
    let node = table.nodes[index]
    index = if (uint32(code) and (1'u32 shl node.bit)) == 0: node.zero else: node.one
  table.nodes[index].value

proc constrainLookup*[N: static[int]](c: var Circuit, table: OpcodeLookup[N],
    opcode: Linear): array[N, Linear] =
  when defined(zkbuildInstructionSourceAudit):
    let helperFirst = c.gadgets.len
    let helperGate = c.constraints.len
  let bits = c.constrainUnsigned(opcode, 16)
  when defined(zkbuildLookupAudit):
    var record = LookupAudit(range: c.snapshotRangeUse(),firstWire: c.values.len,firstGate: c.constraints.len,
      root: table.root,columns: N,input: opcode)
    for node in table.nodes:
      var payload: seq[int]
      for value in node.value: payload.add value
      record.nodes.add LookupNodeAudit(bit: node.bit,zero: node.zero,one: node.one,payload: payload)
  var flow = newSeq[Linear](table.nodes.len)
  flow[table.root] = constant(1)
  var sums: array[N, Linear]
  for i in countdown(table.nodes.high, 0):
    let node = table.nodes[i]
    let active = flow[i]
    if node.bit >= 0:
      let one = c.multiply(active, bits[node.bit])
      flow[node.zero] = flow[node.zero]+active-one
      flow[node.one] = flow[node.one]+one
    else:
      for field in 0..<N:
        if node.value[field] != 0: sums[field] = sums[field]+active.scale(scalar(node.value[field]))
  for field in 0..<N: result[field] = c.materialize(sums[field])
  when defined(zkbuildLookupAudit):
    for value in result: record.outputs.add value
    c.recordLookup(record)

  when defined(zkbuildInstructionSourceAudit):
    if c.sourceProgramActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 2,index: c.lookupRecords.high,
        firstPrimitive: helperFirst,lastPrimitive: c.gadgets.len,firstGate: helperGate,lastGate: c.constraints.len)
