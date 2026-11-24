import std/tables
import cps/wasm/types
import cps/zk/[r1cs, read_only_memory, wasm_signature_environment,
  wasm_indexed_signatures, wasm_type_reversals]

const Tags = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc build(signatures: SignatureEnvironment, indexed: IndexedSignatureEnvironment,
    reversals: seq[ReadOnlyEntry], binding = true): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let reverseWires = result.inputs(reversals)
  let sigWires = SignatureEnvironmentWires(signatures: result.inputs(signatures.signatures), nodes: result.inputs(signatures.nodes))
  let indexedWires = IndexedSignatureWires(lengths: result.inputs(indexed.lengths),
    members: result.inputs(indexed.members), singletons: result.inputs(indexed.singletons))
  result.constrainIndexedSignatures(indexedWires, sigWires, buildIndexedSignatureWitness(indexed, signatures))
  if binding: result.constrainTypeReversals(reverseWires, indexedWires, buildTypeReversalWitness(reversals, indexed))

proc main() =
  var vectors: seq[seq[ValType]] = @[@[]]
  var first = 0
  var size = 1
  for length in 1..3:
    let start = vectors.len
    for i in first..<first+size:
      for tag in Tags: vectors.add vectors[i] & @[tag]
    first = start
    size *= 7
  var types: seq[FuncType]
  for vector in vectors: types.add FuncType(params: vector, results: vector)
  let all = buildSignatureEnvironment(WasmModule(types: types), includeSingletons = true, includeReversals = true)
  var nodes: Table[uint64, uint64]
  for node in all.nodes: nodes[node.address] = node.value
  proc values(head: uint64): seq[uint8] =
    var cursor = head
    while cursor != 0:
      result.add uint8(nodes[cursor] and 7)
      cursor = nodes[cursor] shr 3
  for pair in all.reversals:
    let a = values(pair.address)
    let b = values(pair.value)
    require(a.len == b.len, "reversal vector length")
    for i in 0..<a.len: require(a[i] == b[b.high-i], "reversal vector contents")
  require(vectors.len == 400 and all.reversals.len == 400, "exhaustive short vector sharing")
  var matrices, forgeries: int
  var shape: Circuit
  for i, vector in vectors:
    if i mod 17 != 0: continue
    let module = WasmModule(types: @[FuncType(params: vector)])
    let sig = buildSignatureEnvironment(module, 2, 24, includeSingletons = true,
      includeReversals = true, reversalCapacity = 16)
    let indexed = buildIndexedSignatures(sig, 16, 48)
    let circuit = build(sig, indexed, sig.reversals)
    require(circuit.satisfied(), "composed reversal cache")
    if matrices == 0: shape = circuit
    else: require(circuit.sameShape(shape), "reversal cache matrix depends on values")
    inc matrices
  let sig = buildSignatureEnvironment(WasmModule(types: @[FuncType(params: @[vtI32, vtI64])]),
    includeSingletons = true, includeReversals = true)
  let indexed = buildIndexedSignatures(sig)
  for mutation in 0..3:
    var changed: seq[ReadOnlyEntry]
    for entry in sig.reversals: changed.add entry
    var last = changed.high
    while changed[last].address == changed[last].value: dec last
    if mutation == 0: changed[last].value = 0
    elif mutation == 1: changed[last].value = changed[last].address
    elif mutation == 2: changed[last].value = 1'u64 shl 32
    else: inc changed[last].address
    require(build(sig, indexed, changed, false).satisfied(), "forgery preceding indexed relation")
    require(not build(sig, indexed, changed).satisfied(), "false reversal map accepted")
    inc forgeries
  echo "zkbuild type reversals: PASS (400 exhaustive vectors; ", matrices,
    " R1CS shapes; ", forgeries, " coherent reversal forgeries rejected)"

main()
