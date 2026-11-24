import cps/zk/[r1cs, prover, wasm_binary_source, wasm_binary_envelope]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc unsignedLeb(value: uint64): seq[byte] =
  var remaining = value
  while true:
    let payload = byte(remaining and 127)
    remaining = remaining shr 7
    result.add payload or (if remaining == 0: 0'u8 else: 128'u8)
    if remaining == 0: return

proc signedLeb(value: int64): seq[byte] =
  var remaining = cast[uint64](value)
  let negative = value < 0
  while true:
    let payload = byte(remaining and 127)
    remaining = remaining shr 7
    if negative: remaining = remaining or 0xfe00000000000000'u64
    let done = (remaining == 0 and (payload and 64) == 0) or
      (remaining == high(uint64) and (payload and 64) != 0)
    result.add payload or (if done: 0'u8 else: 128'u8)
    if done: return

proc buildRead(bytes: seq[byte], kind: BinaryReadKind, expected: uint64,
    hint: BinaryRead, position = 2'u32): Circuit =
  let data = @[0xa3'u8, 0x51] & bytes & @[0x87'u8]
  result = initCircuit(reuseRangeWitnesses = true)
  let value = result.publicInput(scalar(expected))
  let sourcePosition = result.publicInput(scalar(position))
  let claim = result.allocateBinarySourceClaim(data, 32)
  var source = result.constrainBinarySource(data, 32, claim)
  discard result.constrainBinaryRead(source, kind, constant(1), sourcePosition, value, hint)
  result.finishBinaryReads(source)

proc checked(bytes: seq[byte], kind: BinaryReadKind): Circuit =
  let data = @[0xa3'u8, 0x51] & bytes & @[0x87'u8]
  let hint = readBinaryToken(data, 2, kind)
  buildRead(bytes, kind, hint.value, hint)

proc variant(bytes: seq[byte], kind: BinaryReadKind): Circuit =
  let data = @[0xa3'u8,0x51] & bytes & @[0x87'u8]
  let hint = readBinaryToken(data, 2, kind)
  result = initCircuit(reuseRangeWitnesses = true)
  let mode = result.publicInput(scalar(binaryReadMode(kind)))
  let value = result.publicInput(scalar(hint.value))
  let claim = result.allocateBinarySourceClaim(data, 32)
  var source = result.constrainBinarySource(data, 32, claim)
  discard result.constrainVariantRead(source, mode, constant(2), value, hint)
  result.finishBinaryReads(source)

proc envelopeCircuit(data: seq[byte], hint: BinaryEnvelope): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let claim = result.allocateBinarySourceClaim(data, 96)
  var source = result.constrainBinarySource(data, 96, claim)
  var wires = result.allocateBinaryEnvelope(hint)
  result.constrainBinaryEnvelope(source, wires, hint)
  result.finishBinaryReads(source)

proc main() =
  var cases, forgeries: int
  var variantShape: Circuit
  for kind in BinaryReadKind:
    var shape: Circuit
    var first = true
    var samples: seq[seq[byte]]
    case kind
    of brByte: samples = @[@[0'u8], @[127'u8], @[128'u8], @[255'u8]]
    of brU32:
      for value in [0'u64, 1, 63, 64, 127, 128, 16383, 16384, 0x7fffffff'u64, 0x80000000'u64, 0xffffffff'u64]:
        samples.add unsignedLeb(value)
    of brS32, brS33, brS64:
      for value in [low(int32).int64, -16385'i64, -129, -128, -65, -64, -1, 0, 1, 63, 64, 127, 128, 16383, high(int32).int64]:
        samples.add signedLeb(value)
      if kind != brS32:
        for value in [int64(-4294967296), int64(2147483648), int64(4294967295)]: samples.add signedLeb(value)
      if kind == brS64:
        for value in [low(int64), high(int64)]: samples.add signedLeb(value)
    of brLittle32: samples = @[@[0'u8, 0, 0, 0], @[255'u8, 128, 17, 42]]
    of brLittle64: samples = @[@[0'u8, 0, 0, 0, 0, 0, 0, 0], @[255'u8, 128, 17, 42, 19, 3, 250, 200]]
    let canonical = samples
    if kind in {brU32, brS32, brS33, brS64}:
      for bytes in canonical:
        if bytes.len < readCapacity(kind):
          var extended = @bytes
          let negative = kind != brU32 and (extended[^1] and 64) != 0
          extended[^1] = extended[^1] or 128
          extended.add(if negative: 127'u8 else: 0'u8)
          samples.add extended
    for bytes in samples:
      let circuit = checked(bytes, kind)
      require(circuit.satisfied(), "valid primitive " & $kind & " " & $bytes)
      if first: shape = circuit; first = false
      else: require(circuit.sameShape(shape), "primitive matrix depends on bytes or LEB length")
      let generic = variant(bytes, kind)
      require(generic.satisfied(), "variant reader " & $kind & " " & $bytes)
      if variantShape.constraints.len == 0: variantShape = generic
      else: require(generic.sameShape(variantShape), "variant matrix depends on read kind or encoded length")
      inc cases
  for item in [
      (brU32, @[255'u8,255,255,255,31]),
      (brS32, @[255'u8,255,255,255,15]),
      (brS33, @[255'u8,255,255,255,31]),
      (brS64, @[128'u8,128,128,128,128,128,128,128,128,1]),
      (brU32, @[128'u8,128,128,128,128]),
      (brS64, @[128'u8,128,128,128,128,128,128,128,128,128])]:
    var rejected = false
    try: discard readBinaryToken(item[1], 0, item[0])
    except ValueError: rejected = true
    require(rejected, "overflow/unterminated primitive accepted")
    var forged = BinaryRead(position: 2, length: uint8(item[1].len))
    for i, value in item[1]:
      forged.bytes[i] = value
      forged.value = forged.value or (uint64(value and 127) shl (7*i))
    if readWidth(item[0]) < 64: forged.value = forged.value and ((1'u64 shl readWidth(item[0]))-1)
    require(not buildRead(item[1], item[0], forged.value, forged).satisfied(), "overflow/unterminated primitive witness accepted")
    inc forgeries
  let bytes = @[255'u8,127]
  let hint = readBinaryToken(@[0xa3'u8,0x51] & bytes & @[0x87'u8], 2, brS32)
  require(not buildRead(bytes, brS32, 16383, hint).satisfied(), "sign-extension substitution")
  require(not buildRead(bytes, brS32, hint.value, hint, high(uint32)).satisfied(), "source address wraparound")
  forgeries += 2
  var altered = checked(bytes, brS32)
  for wire in 1..altered.publicCount:
    let original = altered.values[wire]
    altered.values[wire] = original+scalar(1)
    require(not altered.satisfied(), "public source/read substitution")
    altered.values[wire] = original
    inc forgeries
  let header = @[0'u8,97,115,109,1,0,0,0]
  let a = header & @[0'u8,1,0, 1,4,1,96,0,0, 3,2,1,0, 10,4,1,2,0,11]
  let b = header & @[0'u8,1,0, 1,4,1,96,0,0, 3,2,1,0, 10,5,1,3,0,1,11]
  let ca = envelopeCircuit(a, buildBinaryEnvelope(a, 8))
  let cb = envelopeCircuit(b, buildBinaryEnvelope(b, 8))
  require(ca.satisfied() and cb.satisfied() and ca.sameShape(cb), "section envelopes/length-independent matrix")
  var bad = buildBinaryEnvelope(a, 8)
  inc bad.sections[2].firstWord
  require(not envelopeCircuit(a, bad).satisfied(), "forged vector count")
  bad = buildBinaryEnvelope(a, 8)
  inc bad.sections[1].body
  require(not envelopeCircuit(a, bad).satisfied(), "forged section body offset")
  bad = buildBinaryEnvelope(a, 8)
  dec bad.sections[3].finish
  require(not envelopeCircuit(a, bad).satisfied(), "partial source coverage")
  bad = buildBinaryEnvelope(a, 8)
  bad.sections[2].id = 1
  require(not envelopeCircuit(a, bad).satisfied(), "duplicate/relabelled section")
  forgeries += 4
  let key = setup(ca)
  for circuit in [ca, cb]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "source-envelope proof")
  echo "zkbuild binary source: PASS (", cases, " primitive encodings; ", forgeries,
    " forgeries; ", ca.constraints.len, " constraints; two 192-byte envelope proofs)"

main()
