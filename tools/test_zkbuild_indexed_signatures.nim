import std/tables
import cps/wasm/[types, variable_typing]
import cps/zk/[r1cs, read_only_memory, wasm_signature_environment,
  wasm_indexed_signatures, prover]

const Tags = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc mapping(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc query(address: uint64, entries: openArray[ReadOnlyEntry]): ReadOnlyEntry =
  ReadOnlyEntry(active: true, address: address, value: mapping(entries).getOrDefault(address))

proc allocate(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc build(environment: IndexedSignatureEnvironment, signatures: SignatureEnvironment,
    queries = IndexedSignatureQueries(), binding = true,
    memberParts: seq[tuple[head, ordinal: Scalar]] = @[]): Circuit =
  result = initCircuit()
  let indexWires = IndexedSignatureWires(lengths: result.allocate(environment.lengths),
    members: result.allocate(environment.members), singletons: result.allocate(environment.singletons))
  var signatureWires: SignatureEnvironmentWires
  # This component claims indexing correctness for the supplied head vector.
  # Function/type namespace and origin binding is provided by the call relation.
  for entry in signatures.signatures:
    signatureWires.signatures.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: constant(entry.address), value: result.publicInput(scalar(entry.value)))
  signatureWires.nodes = result.allocate(signatures.nodes)
  let queryWires = IndexedSignatureQueryWires(lengths: result.allocate(queries.lengths),
    members: result.allocate(queries.members), singletons: result.allocate(queries.singletons))
  var parts: seq[tuple[head, ordinal: Linear]]
  for part in memberParts:
    parts.add (result.publicInput(part.head), result.publicInput(part.ordinal))
  if parts.len != 0:
    require(parts.len == queryWires.members.len, "member query parts dimensions")
    for i, part in parts:
      let checked = result.constrainSignatureMemberQuery(queryWires.members[i].active,
        part.head, part.ordinal, queries.members[i].value)
      result.assertEqual(checked.address, queryWires.members[i].address)
      result.assertEqual(checked.value, queryWires.members[i].value)
  if binding:
    result.constrainIndexedSignatures(indexWires, signatureWires,
      buildIndexedSignatureWitness(environment, signatures, queries), queryWires)
  else:
    result.constrainReadOnly(indexWires.members, queryWires.members,
      buildReadOnlyWitness(environment.members, queries.members), 64, 35)

proc pureConformance(): int =
  var signatures = @[FuncType()]
  var start = 0
  var count = 1
  for length in 1..3:
    let previous = start
    start = signatures.len
    for i in 0..<count:
      for tag in Tags:
        var values = signatures[previous+i].params
        values.add tag
        signatures.add FuncType(params: values, results: values)
    count *= 7
  let module = WasmModule(startFunc: -1, dataCount: -1, types: signatures)
  let lists = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(lists)
  let lengths = mapping(indexed.lengths)
  let members = mapping(indexed.members)
  require(lists.nodes.len == 399 and indexed.lengths.len == 400 and indexed.members.len == 1134,
    "indexed signature sharing/linear storage")
  for i, signature in signatures:
    let entry = lists.signatures[i]
    let params = uint32(entry.value and 0xffffffff'u64)
    let results = uint32(entry.value shr 32)
    require(lengths[uint64(params)] == uint64(signature.params.len) and
      lengths[uint64(results)] == uint64(signature.results.len), "indexed signature lengths")
    for ordinal in 0..<signature.params.len:
      let value = members[signatureMemberAddress(params, uint32(ordinal))] and 7
      require(value == uint64(stackTypeTag(signature.params[signature.params.high-ordinal])), "parameter reverse order")
      let forward = members[signatureMemberAddress(results, uint32(ordinal))] and 7
      require(forward == uint64(stackTypeTag(signature.results[ordinal])), "result forward order")
      inc result, 2
  require(result == 2268, "indexed query coverage")

proc main() =
  let conformance = pureConformance()
  let module = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtI32, vtI64, vtFuncRef, vtV128], results: @[vtExternRef, vtF64, vtI32]),
      FuncType(params: @[vtV128, vtI32], results: @[vtExternRef])],
    imports: @[Import(kind: ikFunc, module: "host", name: "callee", funcTypeIdx: 0)])
  let lists = buildSignatureEnvironment(module, 8, 32, includeSingletons = true)
  let indexed = buildIndexedSignatures(lists, 16, 32)
  let head = uint32(lists.signatures[0].value and 0xffffffff'u64)
  var queries = IndexedSignatureQueries(lengths: @[query(uint64(head), indexed.lengths)],
    members: @[query(signatureMemberAddress(head, 0), indexed.members)],
    singletons: @[query(6, indexed.singletons)])
  let reference = build(indexed, lists, queries)
  require(reference.satisfied(), "indexed signature circuit")
  var mutations = 0
  var altered = indexed
  altered.members = @(indexed.members)
  for entry in altered.members.mitems:
    if entry.active and entry.address == signatureMemberAddress(head, 0):
      entry.value = (entry.value and not 7'u64)+(((entry.value and 7)+1) mod 7)
  var changedQueries = queries
  changedQueries.members = @[query(signatureMemberAddress(head, 0), altered.members)]
  require(build(altered, lists, changedQueries, binding = false).satisfied(), "forged cache should pass a bare immutable lookup")
  require(not build(altered, lists, changedQueries).satisfied(), "forged indexed type detached from list")
  inc mutations
  for removePrefix in [false, true]:
    altered = indexed
    altered.members = @(indexed.members)
    altered.lengths = @(indexed.lengths)
    let removed = signatureMemberAddress(head, if removePrefix: 0'u32 else: 3'u32)
    var position = -1
    for i, entry in altered.members:
      if entry.active and entry.address == removed: position = i
    require(position >= 0, "indexed truncation fixture")
    altered.members.delete(position)
    altered.members.add ReadOnlyEntry()
    if removePrefix:
      for entry in altered.members.mitems:
        if entry.active and entry.address shr 32 == uint64(head): dec entry.address
    for entry in altered.lengths.mitems:
      if entry.active and entry.address == uint64(head): dec entry.value
    changedQueries.members = @[query(signatureMemberAddress(head, 0), altered.members)]
    changedQueries.lengths = @[query(uint64(head), altered.lengths)]
    require(build(altered, lists, changedQueries, binding = false).satisfied(), "truncated cache fixture")
    require(not build(altered, lists, changedQueries).satisfied(), "truncated signature cache")
    inc mutations
  altered = indexed
  altered.members = @(indexed.members)
  var first, second = -1
  for i, entry in altered.members:
    if entry.active and entry.address == signatureMemberAddress(head, 1): first = i
    if entry.active and entry.address == signatureMemberAddress(head, 2): second = i
  require(first >= 0 and second >= 0, "indexed link fixture")
  swap(altered.members[first].value, altered.members[second].value)
  require(build(altered, lists, queries, binding = false).satisfied(), "relinked cache fixture")
  require(not build(altered, lists, queries).satisfied(), "relinked signature cache")
  inc mutations
  altered = indexed
  altered.lengths = @(indexed.lengths)
  var lengthPosition = -1
  for i, entry in altered.lengths:
    if entry.active and entry.address == uint64(head): lengthPosition = i
  altered.lengths[lengthPosition].value = 0
  require(not build(altered, lists).satisfied(), "nonzero signature head declared empty")
  inc mutations
  altered = indexed
  altered.lengths = @(indexed.lengths)
  altered.lengths.delete(lengthPosition)
  altered.lengths.add ReadOnlyEntry()
  require(not build(altered, lists).satisfied(), "missing signature length")
  inc mutations
  altered = indexed
  altered.singletons = @(indexed.singletons)
  altered.singletons[3].value = altered.singletons[2].value
  require(not build(altered, lists).satisfied(), "singleton type substitution")
  inc mutations
  var missingHead = lists
  missingHead.signatures = @(lists.signatures)
  missingHead.signatures[3] = ReadOnlyEntry(active: true, address: typeSignatureAddress(2), value: uint64(high(uint32)))
  require(not build(indexed, missingHead).satisfied(), "unused declared head missing from index")
  inc mutations
  for bad in [signatureMemberAddress(head, 4), signatureMemberAddress(0, 0),
      signatureMemberAddress(high(uint32), 0)]:
    let badQuery = IndexedSignatureQueries(members: @[ReadOnlyEntry(active: true, address: bad)])
    require(not build(indexed, lists, badQuery).satisfied(), "out-of-range indexed member")
    inc mutations
  require(not build(indexed, lists, IndexedSignatureQueries(singletons: @[ReadOnlyEntry(active: true, address: 7)])).satisfied(), "invalid singleton tag")
  inc mutations
  require(signatureMemberAddress(high(uint32), high(uint32)) == high(uint64), "indexed address width")
  let alias = IndexedSignatureQueries(members: @[query(signatureMemberAddress(1, 0), indexed.members)])
  require(build(indexed, lists, alias).satisfied(), "ordinal-alias address fixture")
  require(not build(indexed, lists, alias, memberParts = @[(scalar(0), scalar(1'u64 shl 32))]).satisfied(),
    "ordinal overflow aliased another signature head")
  require(build(indexed, lists, alias, memberParts = @[(scalar(1), scalar(0))]).satisfied(), "bounded member query")
  inc mutations

  # Small proof profile: seven singleton lists plus nil. A second witness
  # changes node IDs and metadata, while retaining the same circuit/key.
  let smallModule = WasmModule(startFunc: -1, dataCount: -1)
  let smallLists = buildSignatureEnvironment(smallModule, 1, 8, includeSingletons = true)
  let small = buildIndexedSignatures(smallLists, 8, 8)
  let smallQueries = IndexedSignatureQueries(lengths: @[query(uint64(smallLists.singletons[1]), small.lengths)],
    members: @[query(signatureMemberAddress(smallLists.singletons[1], 0), small.members)],
    singletons: @[query(1, small.singletons)])
  let circuit = build(small, smallLists, smallQueries)
  require(circuit.satisfied(), "small indexed signature proof")
  let otherModule = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType(results: @[vtF64])])
  let otherLists = buildSignatureEnvironment(otherModule, 1, 8, includeSingletons = true)
  let other = buildIndexedSignatures(otherLists, 8, 8)
  let otherQueries = IndexedSignatureQueries(lengths: @[query(uint64(otherLists.singletons[1]), other.lengths)],
    members: @[query(signatureMemberAddress(otherLists.singletons[1], 0), other.members)],
    singletons: @[query(1, other.singletons)])
  let secondCircuit = build(other, otherLists, otherQueries)
  require(secondCircuit.satisfied() and circuit.sameShape(secondCircuit), "node-ID-dependent index matrix")
  let key = setup(circuit)
  let proof = encodeProof(prove(key, circuit))
  require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "indexed signature proof")
  let secondProof = encodeProof(prove(key, secondCircuit))
  require(decodeAndVerify(key.verificationKey, secondProof, secondCircuit.values[1..secondCircuit.publicCount]), "indexed signature key reuse")
  var publicInputs = circuit.values[1..circuit.publicCount]
  publicInputs[^1] += scalar(1)
  require(not decodeAndVerify(key.verificationKey, proof, publicInputs), "indexed signature proof substitution")
  echo "zkbuild indexed signatures: PASS (400 source vectors; ", conformance,
    " forward/reverse queries; ", mutations, " coherent/lookup forgeries rejected; ",
    circuit.constraints.len, " constraints; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
