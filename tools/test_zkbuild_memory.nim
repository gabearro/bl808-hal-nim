import std/[algorithm, random, tables]
import cps/zk/[r1cs, range_check, permutation, memory_consistency]
import cps/zk/prover
import cps/zk/[wasm_validation_witness, wasm_stack_memory]
import cps/wasm/validate

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc access(address, value: uint64, write = false): MemoryAccess =
  MemoryAccess(active: true, write: write, address: address, value: value)

proc build(rows: openArray[MemoryAccess], witness: MemoryWitness,
    addressBits = 64, valueBits = 64): Circuit =
  result = initCircuit()
  var input: seq[MemoryAccessWires]
  for row in rows:
    input.add MemoryAccessWires(active: result.publicInput(scalar(ord(row.active))),
      write: result.publicInput(scalar(ord(row.write))),
      address: result.publicInput(scalar(row.address)),
      value: result.publicInput(scalar(row.value)))
  discard result.constrainMemory(input, witness, addressBits, valueBits)

proc build(rows: openArray[MemoryAccess], addressBits = 64, valueBits = 64): Circuit =
  build(rows, buildMemoryWitness(rows), addressBits, valueBits)

proc valid(rows: openArray[MemoryAccess], addressBits, valueBits: int): bool =
  ## Independent execution-order oracle; no sort or route generation.
  var memory = initTable[uint64, uint64]()
  for row in rows:
    if not row.active:
      if row.write or row.address != 0 or row.value != 0: return false
    else:
      if addressBits < 64 and row.address shr addressBits != 0: return false
      if valueBits < 64 and row.value shr valueBits != 0: return false
      if row.write: memory[row.address] = row.value
      elif not memory.hasKey(row.address) or memory[row.address] != row.value: return false
  true

proc leb(value: int): seq[byte] =
  var n = value
  while true:
    result.add byte(n and 127) or (if n > 127: 128'u8 else: 0'u8)
    n = n shr 7
    if n == 0: break

proc section(bytes: var seq[byte], id: byte, payload: seq[byte]) =
  bytes.add id
  bytes.add leb(payload.len)
  bytes.add payload

proc testWasmStack() =
  var bytes = @[0'u8, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
  bytes.section(1, @[1'u8, 0x60, 0, 1, 0x7e])
  bytes.section(3, @[3'u8, 0, 0, 0])
  let first = @[0'u8, 0x42, 9, 0x0b]
  var second = @[1'u8, 1, 0x7e]
  for _ in 0..<256: second.add 1'u8
  second.add @[0x03'u8, 0x40, 0x41, 0, 0x0d, 0, 0x0b, 0x42, 7, 0x22, 0,
    0x42, 2, 0x7e, 0x10, 0, 0x7c, 0x0b]
  let third = @[0'u8, 0, 0x0b]
  var bodies = @[3'u8]
  for body in [first, second, third]:
    bodies.add leb(body.len)
    bodies.add body
  bytes.section(10, bodies)
  let wasm = buildFullValidationWitness(bytes)
  let operand = buildOperandMemory(wasm.events)
  require(bytes.len > 156 and operand.accesses.len > 8, "WASM stack test size")
  require(build(operand.accesses, operand.memory, 64, 3).satisfied(), "WASM operand memory")
  var changed = @(wasm.events)
  for event in changed.mitems:
    if event.kind == veOperandPop and not event.polymorphic:
      event.valueType = svF32
      break
  let invalid = buildOperandMemory(changed, operand.accesses.len)
  require(not build(invalid.accesses, invalid.memory, 64, 3).satisfied(),
    "WASM stack RAM accepted an altered pop type")
  var empty: seq[ValidationEvent]
  require(buildOperandMemory(empty).accesses.len == 1, "empty operand transcript padding")
  echo "zkbuild operand memory: PASS (", bytes.len, " WASM bytes; ",
    wasm.events.len, " validation events; ", operand.accesses.len, " RAM slots)"

proc main() =
  for width in [0, 1, 3, 32, 64, 128, 248]:
    let limit = scalar(2).power(uint64(width))
    for value in [scalar(0), limit-scalar(1), limit, scalar(-1)]:
      var circuit = initCircuit()
      let input = circuit.publicInput(value)
      discard circuit.constrainUnsigned(input, width)
      let expected = value.zero() or value.equals(limit-scalar(1))
      require(circuit.satisfied() == expected, "unsigned range boundary " & $width)
  for value in [scalar(0), scalar(1), scalar(-1), scalar(2).power(200)]:
    var circuit = initCircuit()
    let input = circuit.publicInput(value)
    let indicator = circuit.zeroIndicator(input)
    require(circuit.satisfied(), "zero indicator")
    require(indicator.evaluate(circuit.values).equals(scalar(ord(value.zero()))), "zero indicator value")
    circuit.values[indicator[0].wire] += scalar(1)
    require(not circuit.satisfied(), "changed zero indicator")

  let example = @[access(7, 9, true), access(2, 3, true), access(7, 9),
    access(7, 11, true), access(2, 3), access(7, 11), MemoryAccess(), MemoryAccess()]
  let reference = build(example, 8, 8)
  require(reference.satisfied(), "interleaved memory operations")
  for i in 1..4*example.len:
    var changed = reference
    # Deep-copy because Circuit.values is a mutable sequence.
    changed.values = @(reference.values)
    changed.values[i] += scalar(1)
    require(not changed.satisfied(), "changed input memory record " & $i)
  let key = setup(reference)
  let encoded = encodeProof(prove(key, reference))
  var publicInputs = reference.values[1..reference.publicCount]
  require(decodeAndVerify(key.verificationKey, encoded, publicInputs), "RAM Groth16 proof")
  publicInputs[3] += scalar(1)
  require(not decodeAndVerify(key.verificationKey, encoded, publicInputs), "RAM proof public substitution")
  var secondExample = @example
  for row in secondExample.mitems:
    if row.active:
      inc row.address
      inc row.value
  let secondCircuit = build(secondExample, 8, 8)
  require(secondCircuit.sameShape(reference), "RAM key reuse shape")
  let secondProof = encodeProof(prove(key, secondCircuit))
  require(decodeAndVerify(key.verificationKey, secondProof,
    secondCircuit.values[1..secondCircuit.publicCount]), "RAM key reuse proof")

  let badCases = @[
    @[access(0, 0), MemoryAccess()],
    @[access(0, 1, true), access(0, 2)],
    @[access(0, 1, true), access(1, 1)],
    @[access(0, 1, true), MemoryAccess(write: true)],
    @[access(0, 1, true), MemoryAccess(address: 1)],
    @[access(0, 1, true), MemoryAccess(value: 1)],
    @[access(256, 1, true), MemoryAccess()],
    @[access(0, 256, true), MemoryAccess()]]
  for rows in badCases:
    let circuit = build(rows, 8, 8)
    require(not valid(rows, 8, 8) and not circuit.satisfied(), "invalid RAM access accepted")
  require(build(@[MemoryAccess()]).satisfied(), "empty one-slot memory")
  require(build(@[access(uint64.high, uint64.high, true)]).satisfied(), "full-width address/value")
  require(not build(@[access(0, 0)]).satisfied(), "uninitialized singleton read")

  var reordered = buildMemoryWitness(example)
  reordered.sorted.reverse()
  var reverseOrder: seq[int]
  for record in reordered.sorted: reverseOrder.add int(record.clock)
  reordered.route = permutationRoute(reverseOrder)
  require(not build(example, reordered, 8, 8).satisfied(), "reverse-sorted witness accepted")
  var duplicateClock = buildMemoryWitness(example)
  duplicateClock.sorted[1].clock = duplicateClock.sorted[0].clock
  require(not build(example, duplicateClock, 8, 8).satisfied(), "duplicate timestamp accepted")
  var wrongRead = buildMemoryWitness(example)
  for record in wrongRead.sorted.mitems:
    if record.access.active and not record.access.write:
      inc record.access.value
      break
  require(not build(example, wrongRead, 8, 8).satisfied(), "altered sorted read accepted")

  var rng = initRand(0x52414d)
  var cases = 0
  for n in [2, 4, 8, 16, 64, 256]:
    let emptyReference = build(newSeq[MemoryAccess](n), 8, 8)
    for sample in 0..<12:
      var rows: seq[MemoryAccess]
      var memory = initTable[uint64, uint64]()
      for i in 0..<n:
        let address = uint64(rng.rand(15))
        if rng.rand(7) == 0:
          rows.add MemoryAccess()
        elif not memory.hasKey(address) or rng.rand(1) == 0:
          let value = uint64(rng.rand(255))
          memory[address] = value
          rows.add access(address, value, true)
        else:
          rows.add access(address, memory[address])
      let circuit = build(rows, 8, 8)
      require(valid(rows, 8, 8) and circuit.satisfied(), "random memory trace")
      require(circuit.sameShape(emptyReference), "witness-dependent RAM circuit")
      inc cases
      # Coherently regenerate route/records for an invalid read. This tests
      # semantics rather than only binding to a stale witness.
      for row in rows.mitems:
        if row.active and not row.write:
          row.value = (row.value+1) and 255
          break
      let changed = build(rows, 8, 8)
      require(changed.satisfied() == valid(rows, 8, 8), "mutated random memory trace")
  echo "zkbuild memory: PASS (", cases, " randomized traces through N=256; range boundaries,",
    " malformed reads, record mutations, timestamps, sorting, and fixed matrices; N=8: ",
    reference.constraints.len, " constraints)"
  echo "zkbuild memory proofs: PASS (two witnesses, one key; ", encoded.len, " bytes each)"
  testWasmStack()

main()
