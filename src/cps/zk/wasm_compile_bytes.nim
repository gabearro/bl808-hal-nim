## Bind an ordinary WASM byte stream to the existing certified RV32 emitter.
## A constrained queue retains its last sixteen non-nop operations; overflow
## is forbidden. No hash or unchecked host normalization links the relations.
import compose, wasm_bytes_circuit, wasm_circuit
export wasm_bytes

proc weighted(bits: openArray[Linear]): Linear =
  var weight = scalar(1)
  for bit in bits:
    result = result + bit.scale(weight)
    weight = weight * scalar(2)

proc buildByteCompileCircuit*(wasm, native: openArray[byte], program: Program): Circuit =
  if wasm.len < StreamWasmMinSize or wasm.len > StreamWasmMaxSize or native.len != NativeSize:
    raise newException(ValueError, "artifact size does not match byte compilation profile")
  result = initCircuit()
  var public: seq[Linear]
  for value in publicInputs(pmCompileBytes, wasm, native): public.add result.publicInput(value)

  let parsed = buildByteCircuitDetailed(wasm)
  let bytePublicCount = parsed.circuit.publicCount
  let byteWires = result.appendCircuit(parsed.circuit, public.toOpenArray(0, bytePublicCount-1))
  let canonical = encodeWasm(program)
  let emitted = buildSlotCircuitDetailed(pmCompile, program, canonical, native)
  var emitterPublic: seq[Linear]
  for value in packedInputs(canonical): emitterPublic.add result.allocate(value)
  for i in bytePublicCount ..< public.len: emitterPublic.add public[i]
  let emitterWires = result.appendCircuit(emitted.circuit, emitterPublic)

  var queue: array[SlotCount, Linear]
  for i in 0..<SlotCount: queue[i] = constant(0)
  var immediate = constant(0)
  for rowIndex, row in parsed.rows:
    var bits: array[8, Linear]
    for i in 0..<8: bits[i] = remap(parsed.bits[WasmPrefix.len+rowIndex][i], byteWires)
    let beginConst = remap(row.selected[baConst], byteWires)
    let finishConst = remap(row.finishConst, byteWires)
    let get = remap(row.before.index, byteWires)
    let binary = remap(row.binary, byteWires)
    let event = get + finishConst + binary

    var payload, signExtension: Linear
    for i in 0..<5:
      let phase = remap(row.before.leb[i], byteWires)
      let lastBit = if i == 4: 3 else: 6
      payload = payload + result.multiply(phase, weighted(bits.toOpenArray(0, lastBit))).scale(scalar(1'u64 shl (7*i)))
      if i < 4:
        signExtension = signExtension + phase.scale(scalar((1'u64 shl 32) - (1'u64 shl (7*(i+1)))))
    let negativeEnd = result.multiply(constant(1)-bits[7], bits[6])
    let sign = result.multiply(negativeEnd, signExtension)
    let previous = result.selectWire(beginConst, constant(0), immediate)
    immediate = result.materialize(previous + payload + sign)

    var token = result.multiply(get, constant(1)+bits[0]) +
      result.multiply(finishConst, constant(3)+immediate.scale(scalar(16)))
    for action in baAdd..baXor:
      token = token + remap(row.selected[action], byteWires).scale(scalar(ord(action)+1))
    # A genuine instruction has a nonzero token. No seventeen-instruction
    # suffix can silently overwrite the first operation of the program.
    result.constrain(event, queue[0], constant(0))
    var next: array[SlotCount, Linear]
    for i in 0..<SlotCount:
      next[i] = result.selectWire(event, if i+1 < SlotCount: queue[i+1] else: token, queue[i])
    queue = next

  for i, slot in emitted.slots:
    var kind: Linear
    for op in OpKind:
      kind = kind + remap(slot.selectors[op], emitterWires).scale(scalar(ord(op)))
    var bits: seq[Linear]
    for bit in slot.immediateBits: bits.add remap(bit, emitterWires)
    let value = result.multiply(remap(slot.selectors[opConst], emitterWires), weighted(bits))
    result.assertEqual(queue[i], kind + value.scale(scalar(16)))

proc buildByteCompileCircuit*(wasm, native: openArray[byte]): Circuit =
  var program: Program
  if not decodeByteProgram(wasm, program):
    raise newException(ValueError, "WASM outside byte compilation profile")
  buildByteCompileCircuit(wasm, native, program)
