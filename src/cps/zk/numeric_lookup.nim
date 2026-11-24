## Fixed, witness-independent R1CS lookup for WASM numeric type signatures.
## This is one component of full module validation, not an admission proof.
import r1cs
import ../wasm/numeric_typing

type
  Signature = array[4, int] # present, pop count, input tag, output tag
  Node = object
    bit, zero, one: int
    value: Signature
  NumericRuleWires* = object
    present*, inputCount*, inputType*, outputType*: Linear

func signature(code: int): Signature =
  let rule = numericRuleForCode(uint16(code))
  if rule.present:
    [1, int(rule.inputCount), 127-ord(rule.inputType), 127-ord(rule.outputType)]
  else: [0, 0, 0, 0]

proc buildNode(nodes: var seq[Node], first, span, bit: int): int =
  let value = signature(first)
  var uniform = true
  if not (first > 0x107 or first+span <= 0x41 or (first > 0xc4 and first+span <= 0x100)):
    for code in first+1..<first+span:
      if signature(code) != value:
        uniform = false
        break
  if uniform:
    result = nodes.len
    nodes.add Node(bit: -1, zero: -1, one: -1, value: value)
  else:
    let half = span div 2
    let zero = buildNode(nodes, first, half, bit-1)
    let one = buildNode(nodes, first+half, half, bit-1)
    result = nodes.len
    nodes.add Node(bit: bit, zero: zero, one: one)

proc buildTable(): seq[Node] =
  discard buildNode(result, 0, 65536, 15)

let table = buildTable()

proc numericLookupBranches*(): int =
  for node in table:
    if node.bit >= 0: inc result

proc constrainNumericRule*(c: var Circuit, opcode: Linear, value: uint16): NumericRuleWires =
  ## All nodes are emitted on every call, including inactive branches.
  ## The tree and matrix depend only on the fixed opcode table.
  var bits: array[16, Linear]
  var packed: Linear
  var weight = scalar(1)
  for i in 0..<16:
    bits[i] = c.bit((value and (1'u16 shl i)) != 0)
    packed = packed + bits[i].scale(weight)
    weight = weight+weight
  c.assertEqual(opcode, packed)
  var sums: array[4, Linear]
  proc visit(index: int, active: Linear, circuit: var Circuit) =
    let node = table[index]
    if node.bit < 0:
      for i in 0..<4:
        if node.value[i] != 0: sums[i] = sums[i] + active.scale(scalar(node.value[i]))
    else:
      let one = circuit.multiply(active, bits[node.bit])
      visit(node.zero, active-one, circuit)
      visit(node.one, one, circuit)
  visit(table.high, constant(1), c)
  result.present = c.materialize(sums[0])
  result.inputCount = c.materialize(sums[1])
  result.inputType = c.materialize(sums[2])
  result.outputType = c.materialize(sums[3])

proc constrainNumericRule*(c: var Circuit, opcode: Linear): NumericRuleWires =
  ## Extract only a private bit witness. The existing 16-bit binding rejects
  ## noncanonical/high field inputs; the matrix is independent of the value.
  let bytes = encodeScalar(opcode.evaluate(c.values))
  let code = (uint16(bytes[30]) shl 8) or uint16(bytes[31])
  c.constrainNumericRule(opcode, code)
