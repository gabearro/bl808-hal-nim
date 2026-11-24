## Bounded, canonical proof/key encodings. No JSON or native object layouts.
import groth16, wasm_profile
export groth16, wasm_profile

type Reader* = object
  data*: seq[byte]
  position*: int

proc take*(r: var Reader, count: int): seq[byte] =
  if count < 0 or count > r.data.len-r.position:
    raise newException(ValueError, "truncated zkbuild encoding")
  result = r.data[r.position ..< r.position+count]
  r.position += count

proc putU32*(outp: var seq[byte], value: uint32) =
  for i in 0 ..< 4: outp.add byte((value shr (8*i)) and 255)

proc getU32*(r: var Reader): uint32 =
  let bytes = r.take(4)
  for i in 0 ..< 4: result = result or (bytes[i].uint32 shl (8*i))

proc put*(outp: var seq[byte], p: Point1) =
  var bytes: array[48, byte]
  discard serialize_g1_compressed(bytes, p)
  outp.add bytes

proc put*(outp: var seq[byte], p: Point2) =
  var bytes: array[96, byte]
  discard serialize_g2_compressed(bytes, p)
  outp.add bytes

proc point1*(r: var Reader, allowInfinity = true): Point1 =
  var bytes: array[48, byte]
  let raw = r.take(48)
  for i in 0 ..< 48: bytes[i] = raw[i]
  let status = deserialize_g1_compressed(result, bytes)
  if status != cttCodecEcc_Success and
      not (allowInfinity and status == cttCodecEcc_PointAtInfinity):
    raise newException(ValueError, "invalid G1 encoding")

proc point2*(r: var Reader, allowInfinity = true): Point2 =
  var bytes: array[96, byte]
  let raw = r.take(96)
  for i in 0 ..< 96: bytes[i] = raw[i]
  let status = deserialize_g2_compressed(result, bytes)
  if status != cttCodecEcc_Success and
      not (allowInfinity and status == cttCodecEcc_PointAtInfinity):
    raise newException(ValueError, "invalid G2 encoding")

func inputCount*(mode: ProofMode): int =
  if mode in {pmValidateBytes, pmCompileBytes}:
    return 1 + (StreamWasmMaxSize+30) div 31 + (if mode == pmCompileBytes: (NativeSize+30) div 31 else: 0)
  (WasmSize+30) div 31 + (if mode == pmCompile: (NativeSize+30) div 31 else: 0)

proc encodeKey*(key: VerificationKey, mode: ProofMode): seq[byte] =
  if key.inputs.len != mode.inputCount+1:
    raise newException(ValueError, "key public-input count differs from profile")
  result = @[0x5a'u8, 0x4b, 0x56, 1, mode.ord.byte, 0, 0, 0]
  result.put key.alpha
  result.put key.beta
  result.put key.gamma
  result.put key.delta
  for p in key.inputs: result.put p

proc decodeKey*(bytes: openArray[byte], key: var VerificationKey,
                mode: var ProofMode): bool =
  if bytes.len < 8 or bytes[0..3] != @[0x5a'u8, 0x4b, 0x56, 1] or
      bytes[4] > high(ProofMode).ord.byte or bytes[5] != 0 or bytes[6] != 0 or bytes[7] != 0:
    return false
  let candidateMode = ProofMode(bytes[4])
  if bytes.len != 8+48+3*96+(candidateMode.inputCount+1)*48: return false
  try:
    var r = Reader(data: @bytes, position: 8)
    var candidate: VerificationKey
    candidate.alpha = r.point1(false)
    candidate.beta = r.point2(false)
    candidate.gamma = r.point2(false)
    candidate.delta = r.point2(false)
    for _ in 0 .. candidateMode.inputCount: candidate.inputs.add r.point1()
    key = candidate
    mode = candidateMode
    true
  except ValueError:
    false

proc verifyArtifacts*(key: VerificationKey, mode: ProofMode,
                      wasm, native, proofBytes: openArray[byte]): bool =
  ## Caller supplies a trusted key. This function does not let a proof choose it.
  if key.inputs.len != mode.inputCount+1: return false
  if mode in {pmValidateBytes, pmCompileBytes}:
    if wasm.len < StreamWasmMinSize or wasm.len > StreamWasmMaxSize: return false
  elif wasm.len != WasmSize: return false
  if mode in {pmCompile, pmCompileBytes} and native.len != NativeSize: return false
  if mode notin {pmCompile, pmCompileBytes} and native.len != 0: return false
  key.decodeAndVerify(proofBytes, publicInputs(mode, wasm, native))
