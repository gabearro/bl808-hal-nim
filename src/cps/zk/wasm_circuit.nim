## Proves membership in the canonical i32 profile, and optionally exact RV32
## compilation. Public inputs bind every byte, not just a host-supplied digest.
import r1cs, wasm_profile
export wasm_profile

type Bits = seq[Linear]

proc sum(items: openArray[Linear]): Linear =
  for item in items: result = result + item

proc pack(bits: openArray[Linear]): Linear =
  var weight = scalar(1)
  for b in bits:
    result = result + b.scale(weight)
    weight = weight * scalar(2)

proc privateBits(c: var Circuit, value: uint32, count: int): Bits =
  for i in 0 ..< count: result.add c.bit(((value shr i) and 1) != 0)

proc bindBytes(c: var Circuit, bytes: seq[Linear], public: openArray[Linear]) =
  var packed: Linear
  var weight = scalar(1)
  var limb = 0
  for i, b in bytes:
    packed = packed + b.scale(weight)
    weight = weight * scalar(256)
    if i mod 31 == 30 or i == bytes.high:
      c.assertEqual(packed, public[limb])
      inc limb
      packed = @[]
      weight = scalar(1)

func constantWord(word: uint32): seq[Linear] =
  for i in 0 ..< 4: result.add constant((word shr (8*i)) and 0xff)

type
  SlotWires* = object
    selectors*: array[OpKind, Linear]
    immediateBits*: seq[Linear]
  SlotCircuitDetails* = object
    circuit*: Circuit
    slots*: array[SlotCount, SlotWires]

proc buildSlotCircuitImpl(mode: ProofMode, program: Program,
                          wasm, native: openArray[byte], retain: static bool): SlotCircuitDetails =
  ## Never branches on private values while constructing constraints.
  if mode notin {pmValidate, pmCompile}:
    raise newException(ValueError, "byte-stream validation requires buildByteCircuit")
  if wasm.len != WasmSize or (mode == pmCompile and native.len != NativeSize):
    raise newException(ValueError, "artifact size does not match profile")
  result.circuit = initCircuit()
  var public: seq[Linear]
  for value in publicInputs(mode, wasm, native): public.add result.circuit.publicInput(value)
  var wasmBytes, nativeBytes: seq[Linear]
  for b in WasmPrefix: wasmBytes.add constant(b)
  nativeBytes.add constantWord(addi(28, 10))
  nativeBytes.add constantWord(addi(29, 11))
  var depths: array[9, Linear]
  depths[0] = constant(1)
  for i in 1 .. 8: depths[i] = constant(0)
  for slotIndex, operation in program:
    var selectors: array[OpKind, Linear]
    for kind in OpKind: selectors[kind] = result.circuit.bit(kind == operation.kind)
    result.circuit.assertEqual(sum(selectors), constant(1))
    let bits = result.circuit.privateBits(operation.immediate, 32)
    when retain:
      result.slots[slotIndex] = SlotWires(selectors: selectors, immediateBits: bits)
    # Canonical signed LEB128, padded to five bytes.
    var constBytes: array[5, Linear]
    for i in 0 ..< 4: constBytes[i] = constant(128) + pack(bits[7*i .. 7*i+6])
    constBytes[4] = pack(bits[28..31]) + bits[31].scale(scalar(112))
    var slot: array[6, Linear]
    for kind in OpKind:
      slot[0] = slot[0] + selectors[kind].scale(scalar(kind.opcode))
      for j in 1 .. 5:
        case kind
        of opConst: slot[j] = slot[j] + result.circuit.multiply(selectors[kind], constBytes[j-1])
        of opParam0:
          if j != 1: slot[j] = slot[j] + selectors[kind]
        else: slot[j] = slot[j] + selectors[kind]
    wasmBytes.add slot
    var next: array[9, Linear]
    var nativeSlot: array[8, Linear]
    var upper: Bits
    if mode == pmCompile:
      upper = result.circuit.privateBits((operation.immediate + 0x800'u32) shr 12, 20)
      let overflow = result.circuit.bit(operation.immediate >= 0xfffff800'u32)
      let remainder = pack(bits[0..10]) + (constant(1)-bits[11]).scale(scalar(2048))
      result.circuit.assertEqual(pack(bits) + constant(2048),
        pack(upper).scale(scalar(4096)) + remainder + overflow.scale(scalar(1'u64 shl 32)))
    for kind in OpKind:
      for depth in 0 .. 8:
        if (kind.pushes and depth == 8) or (kind.binary and depth < 2): continue
        let active = result.circuit.multiply(selectors[kind], depths[depth])
        let nextDepth = if kind.pushes: depth+1 elif kind.binary: depth-1 else: depth
        next[nextDepth] = next[nextDepth] + active
        if mode == pmCompile:
          var words = constantWord(NativeNop) & constantWord(NativeNop)
          if kind.pushes:
            let rd = StackRegisters[depth]
            if kind == opConst:
              words = constantWord((rd shl 7) or 0x37) & constantWord(addi(rd, rd))
              words[1] = words[1] + pack(upper[0..3]).scale(scalar(16))
              words[2] = pack(upper[4..11])
              words[3] = pack(upper[12..19])
              words[6] = words[6] + pack(bits[0..3]).scale(scalar(16))
              words[7] = pack(bits[4..11])
            else:
              words = constantWord(addi(rd, if kind == opParam0: 28'u32 else: 29'u32)) &
                      constantWord(NativeNop)
          elif kind.binary:
            words = constantWord(binaryWord(kind, StackRegisters[depth-2],
              StackRegisters[depth-1])) & constantWord(NativeNop)
          for j in 0 ..< 8:
            nativeSlot[j] = nativeSlot[j] + result.circuit.multiply(active, words[j])
    result.circuit.assertEqual(sum(next), constant(1)) # rejects underflow/overflow
    depths = next
    if mode == pmCompile: nativeBytes.add nativeSlot
  result.circuit.assertEqual(depths[1], constant(1))
  wasmBytes.add constant(0x0b)
  nativeBytes.add constantWord(addi(10, StackRegisters[0]))
  nativeBytes.add constantWord(0x00008067'u32)
  let wasmLimbs = (WasmSize + 30) div 31
  result.circuit.bindBytes(wasmBytes, public.toOpenArray(0, wasmLimbs-1))
  if mode == pmCompile:
    result.circuit.bindBytes(nativeBytes, public.toOpenArray(wasmLimbs, public.high))

proc buildSlotCircuitDetailed*(mode: ProofMode, program: Program,
                               wasm, native: openArray[byte]): SlotCircuitDetails =
  buildSlotCircuitImpl(mode, program, wasm, native, true)

proc buildCircuit*(mode: ProofMode, program: Program,
                   wasm, native: openArray[byte]): Circuit =
  buildSlotCircuitImpl(mode, program, wasm, native, false).circuit
