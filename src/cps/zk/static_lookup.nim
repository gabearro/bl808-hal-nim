## Shared decision DAG for fixed stack signatures and indexed input matching.
## Metadata is emitted at opcode leaves; identical input-match subgraphs are
## pooled. Every node is emitted regardless of witness values.
import std/tables
import r1cs, range_check
import ../wasm/static_typing

type
  Payload = array[6, int] # present, pops, pushes, output tag, clears, allowed
  Key = array[10, int]
  Node = object
    kind, bit, zero, one: int # 0 leaf, 1 branch, 2 emit-and-continue
    value: Payload
  Builder = object
    nodes: seq[Node]
    interned: Table[Key, int]
  StaticRuleWires* = object
    present*, inputCount*, outputCount*, outputType*, clearCount*, allowedInput*, inputIndex*: Linear

proc intern(b: var Builder, node: Node): int =
  var key: Key
  key[0] = node.kind
  key[1] = node.bit
  key[2] = node.zero
  key[3] = node.one
  for i in 0..<6: key[4+i] = node.value[i]
  if b.interned.hasKey(key): return b.interned[key]
  result = b.nodes.len
  b.nodes.add node
  b.interned[key] = result

proc inputTree(b: var Builder, rule: StaticRule, first = 0, span = 32, bit = 4): int =
  let allowed = staticPopMatches(rule, first shr 3, first and 7)
  var uniform = true
  for value in first+1..<first+span:
    if staticPopMatches(rule, value shr 3, value and 7) != allowed:
      uniform = false
      break
  if uniform:
    var value: Payload
    value[5] = ord(allowed)
    return b.intern(Node(kind: 0, value: value))
  let half = span div 2
  let zero = b.inputTree(rule, first, half, bit-1)
  let one = b.inputTree(rule, first+half, half, bit-1)
  b.intern(Node(kind: 1, bit: bit, zero: zero, one: one))

proc opcodeTree(b: var Builder, first = 0, span = 65536, bit = 20): int =
  let rule = staticRuleForCode(uint16(first))
  var uniform = true
  if first <= 0x342:
    for code in first+1..<first+span:
      if staticRuleForCode(uint16(code)) != rule:
        uniform = false
        break
  if uniform:
    let child = b.inputTree(rule)
    let value: Payload = if rule.present:
      [1, int(rule.inputCount), int(rule.outputCount), int(rule.outputType), int(rule.clearCount), 0]
      else: [0, 0, 0, 0, 0, 0]
    return b.intern(Node(kind: 2, zero: child, value: value))
  let half = span div 2
  let zero = b.opcodeTree(first, half, bit-1)
  let one = b.opcodeTree(first+half, half, bit-1)
  b.intern(Node(kind: 1, bit: bit, zero: zero, one: one))

proc buildTable(): tuple[nodes: seq[Node], root: int] =
  var b: Builder
  result.root = b.opcodeTree()
  result.nodes = b.nodes
  for i, node in result.nodes:
    if node.kind != 0:
      doAssert node.zero < i
      if node.kind == 1: doAssert node.one < i

let table = buildTable()

proc staticLookupBranches*(): int =
  for node in table.nodes:
    if node.kind == 1: inc result

proc lookupStaticRuleValue*(code: uint16, index, actual: uint8): array[6, int] =
  ## Exhaustive conformance oracle for the generated DAG; no field arithmetic.
  if index > 3 or actual > 7: raise newException(ValueError, "static lookup input out of range")
  let key = (uint32(code) shl 5) or (uint32(index) shl 3) or uint32(actual)
  var nodeIndex = table.root
  while true:
    let node = table.nodes[nodeIndex]
    if node.kind != 1:
      for i in 0..<6: result[i] += node.value[i]
    case node.kind
    of 0: return
    of 1: nodeIndex = if (key and (1'u32 shl node.bit)) != 0: node.one else: node.zero
    else: nodeIndex = node.zero

proc constrainStaticRule*(c: var Circuit, opcode, inputIndex, actualType: Linear): StaticRuleWires =
  ## Only the low two input-index bits are used by this lookup. The caller
  ## must bind inputIndex to result.inputIndex on an actual fixed-rule pop.
  ## This permits unbounded-arity nonfixed instructions in the same circuit.
  when defined(zkbuildValidationEventAudit):
    let helperFirst = c.gadgets.len
    let helperGate = c.constraints.len
    var audit = StaticRuleAudit(firstGate: helperGate,root: table.root,
      inputs: copyAuditExpressions([opcode,inputIndex,actualType]))
  var bits: array[21, Linear]
  let opcodeBits = c.constrainUnsigned(opcode, 16)
  when defined(zkbuildValidationEventAudit): audit.opcodeRange = c.snapshotRangeUse()
  let typeBits = c.constrainUnsigned(actualType, 3)
  when defined(zkbuildValidationEventAudit): audit.typeRange = c.snapshotRangeUse()
  for i in 0..<16: bits[5+i] = opcodeBits[i]
  for i in 0..<3: bits[i] = typeBits[i]
  let indexBytes = encodeScalar(inputIndex.evaluate(c.values))
  for i in 0..<2:
    bits[3+i] = c.bit((indexBytes[31] and (1'u8 shl i)) != 0)
  result.inputIndex = bits[3]+bits[4].scale(scalar(2))
  when defined(zkbuildValidationEventAudit):
    audit.lowBits = copyAuditExpressions([bits[3],bits[4]])
    audit.firstWire = c.values.len
    for node in table.nodes:
      var payload: seq[int]
      for value in node.value: payload.add value
      audit.nodes.add StaticRuleNodeAudit(kind: node.kind,bit: node.bit,zero: node.zero,one: node.one,payload: payload)
  var flow = newSeq[Linear](table.nodes.len)
  var sums: array[6, Linear]
  flow[table.root] = constant(1)
  for i in countdown(table.nodes.high, 0):
    let node = table.nodes[i]
    let active = flow[i]
    if node.kind == 1:
      let one = c.multiply(active, bits[node.bit])
      flow[node.zero] = flow[node.zero]+active-one
      flow[node.one] = flow[node.one]+one
    else:
      for field in 0..<6:
        if node.value[field] != 0:
          sums[field] = sums[field]+active.scale(scalar(node.value[field]))
      if node.kind == 2: flow[node.zero] = flow[node.zero]+active
  result.present = c.materialize(sums[0])
  result.inputCount = c.materialize(sums[1])
  result.outputCount = c.materialize(sums[2])
  result.outputType = c.materialize(sums[3])
  result.clearCount = c.materialize(sums[4])
  result.allowedInput = c.materialize(sums[5])

  when defined(zkbuildValidationEventAudit):
    audit.lastGate = c.constraints.len
    audit.lastWire = c.values.len
    audit.outputs = copyAuditExpressions([result.present,result.inputCount,result.outputCount,
      result.outputType,result.clearCount,result.allowedInput,result.inputIndex])
    let index = c.staticRuleRecords.len
    c.staticRuleRecords.add audit
    if c.sourceProgramActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 4,index: index,
        firstPrimitive: helperFirst,lastPrimitive: c.gadgets.len,
        firstGate: helperGate,lastGate: c.constraints.len)
