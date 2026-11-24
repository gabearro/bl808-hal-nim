import std/[algorithm, random, tables]
import cps/zk/[r1cs, read_only_memory, memory_consistency, permutation, prover]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc entry(address, value: uint64): ReadOnlyEntry =
  ReadOnlyEntry(active: true, address: address, value: value)

proc build(entries, queries: openArray[ReadOnlyEntry], witness: MemoryWitness,
    addressBits = 64, valueBits = 64): Circuit =
  result = initCircuit()
  var tableWires, queryWires: seq[ReadOnlyWires]
  for item in entries:
    tableWires.add ReadOnlyWires(active: result.publicInput(scalar(ord(item.active))),
      address: result.publicInput(scalar(item.address)), value: result.publicInput(scalar(item.value)))
  for item in queries:
    queryWires.add ReadOnlyWires(active: result.publicInput(scalar(ord(item.active))),
      address: result.publicInput(scalar(item.address)), value: result.publicInput(scalar(item.value)))
  result.constrainReadOnly(tableWires, queryWires, witness, addressBits, valueBits)

proc build(entries, queries: openArray[ReadOnlyEntry], addressBits = 64, valueBits = 64): Circuit =
  build(entries, queries, buildReadOnlyWitness(entries, queries), addressBits, valueBits)

proc valid(entries, queries: openArray[ReadOnlyEntry], addressBits, valueBits: int): bool =
  var contents = initTable[uint64, uint64]()
  var inactive = false
  var last: uint64
  for i, item in entries:
    if not item.active:
      if item.address != 0 or item.value != 0: return false
      inactive = true
    else:
      if inactive or (i != 0 and item.address <= last): return false
      if addressBits < 64 and item.address shr addressBits != 0: return false
      if valueBits < 64 and item.value shr valueBits != 0: return false
      contents[item.address] = item.value
      last = item.address
  for item in queries:
    if not item.active:
      if item.address != 0 or item.value != 0: return false
    elif not contents.hasKey(item.address) or contents[item.address] != item.value:
      return false
  true

proc main() =
  let example = @[entry(0, 7), entry(4, 11), entry(9, 255), ReadOnlyEntry()]
  let reads = @[entry(9, 255), entry(0, 7), entry(9, 255), ReadOnlyEntry()]
  let reference = build(example, reads, 8, 8)
  require(reference.satisfied(), "read-only example")
  for i in 1..reference.publicCount:
    var changed = reference
    changed.values = @(reference.values)
    changed.values[i] += scalar(1)
    require(not changed.satisfied(), "public table/query substitution " & $i)

  var exhaustive = 0
  for mask in 0..<16:
    var entries: seq[ReadOnlyEntry]
    for address in 0..<4:
      if (mask and (1 shl address)) != 0: entries.add entry(uint64(address), uint64(address+1))
    while entries.len < 4: entries.add ReadOnlyEntry()
    for address in 0..<5:
      for value in 0..<6:
        let queries = @[entry(uint64(address), uint64(value))]
        require(build(entries, queries, 3, 3).satisfied() == valid(entries, queries, 3, 3),
          "exhaustive read-only membership")
        inc exhaustive
  let badTables = @[
    @[entry(4, 1), entry(4, 2)], # coherent last-write forgery
    @[entry(4, 1), entry(3, 2)],
    @[ReadOnlyEntry(), entry(4, 2)],
    @[entry(4, 1), ReadOnlyEntry(address: 1)],
    @[entry(4, 1), ReadOnlyEntry(value: 1)],
    @[entry(256, 1), ReadOnlyEntry()],
    @[entry(4, 256), ReadOnlyEntry()]]
  for entries in badTables:
    let queries = @[ReadOnlyEntry()]
    require(not build(entries, queries, 8, 8).satisfied(), "invalid read-only initializer")
  let overwritten = @[MemoryAccess(active: true, write: true, address: 4, value: 1),
    MemoryAccess(active: true, write: true, address: 4, value: 2),
    MemoryAccess(active: true, address: 4, value: 2), MemoryAccess()]
  # Demonstrate why ordinary RAM alone cannot certify a unique immutable table.
  var ordinary = initCircuit()
  var accesses: seq[MemoryAccessWires]
  for item in overwritten:
    accesses.add MemoryAccessWires(active: constant(ord(item.active)), write: constant(ord(item.write)),
      address: constant(item.address), value: constant(item.value))
  discard ordinary.constrainMemory(accesses, buildMemoryWitness(overwritten), 8, 8)
  require(ordinary.satisfied(), "ordinary RAM overwrite fixture")
  require(not build(@[entry(4, 1), entry(4, 2)], @[entry(4, 2)], 8, 8).satisfied(),
    "read-only relation accepted coherent overwrite")

  var reordered = buildReadOnlyWitness(example, reads)
  reordered.sorted.reverse()
  var order: seq[int]
  for row in reordered.sorted: order.add int(row.clock)
  reordered.route = permutationRoute(order)
  require(not build(example, reads, reordered, 8, 8).satisfied(), "reverse order witness")
  var badWitness = buildReadOnlyWitness(example, reads)
  for row in badWitness.sorted.mitems:
    if row.access.active and not row.access.write:
      row.access.write = true
      inc row.access.value
      break
  require(not build(example, reads, badWitness, 8, 8).satisfied(), "query write forgery")
  require(build(@[entry(uint64.high, uint64.high)], @[entry(uint64.high, uint64.high)]).satisfied(),
    "full-width lookup")
  require(not build(@[entry(0, 9)], @[entry(1'u64 shl 32, 9)]).satisfied(), "namespace high-bit alias")
  require(build(newSeq[ReadOnlyEntry](0), newSeq[ReadOnlyEntry](0)).satisfied(), "empty table")
  require(not build(newSeq[ReadOnlyEntry](0), @[entry(0, 0)]).satisfied(), "empty table read")
  require(build(@[entry(0, 1)], newSeq[ReadOnlyEntry](0)).satisfied(), "unused table")

  var rng = initRand(0x524f4d)
  for count in [0, 1, 3, 8, 17]:
    let empty = build(newSeq[ReadOnlyEntry](count), newSeq[ReadOnlyEntry](19), 16, 16)
    for _ in 0..<4:
      var entries, queries: seq[ReadOnlyEntry]
      for i in 0..<count: entries.add entry(uint64(2*i), uint64(rng.rand(65535)))
      for i in 0..<19:
        queries.add(if count == 0 or rng.rand(3) == 0: ReadOnlyEntry() else: entries[rng.rand(count-1)])
      let circuit = build(entries, queries, 16, 16)
      require(circuit.satisfied() and circuit.sameShape(empty), "read-only key shape/repeated queries")

  let key = setup(reference)
  let proof = encodeProof(prove(key, reference))
  require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
    reference.values[1..reference.publicCount]), "read-only Groth16 proof")
  var changedReads = reads
  changedReads[0] = entry(4, 11)
  let second = build(example, changedReads, 8, 8)
  require(second.sameShape(reference), "read-only proof key reuse")
  let secondProof = encodeProof(prove(key, second))
  require(decodeAndVerify(key.verificationKey, secondProof, second.values[1..second.publicCount]),
    "read-only second proof")
  echo "zkbuild read-only memory: PASS (", exhaustive, " exhaustive membership cases; ",
    reference.constraints.len, " constraints/8 accesses; two 192-byte proofs; coherent overwrite rejected)"

main()
