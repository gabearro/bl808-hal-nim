## Canonical, caller-pinned keys for the experimental SHA-256 module claim.
## A key is trusted only after its entire encoding matches the caller's digest.
import wire, wasm_digest_claim, wasm_module_verifier

const ModuleDigestKeySize* = 8+48+3*96+3*48

type PinnedModuleDigestKey* = ref object
  key: VerificationKey
  capacity: int

proc encodeModuleDigestKey*(key: VerificationKey, sourceCapacity: int): seq[byte] =
  if sourceCapacity < 8 or uint64(sourceCapacity) > uint64(high(uint32)) or key.inputs.len != 3:
    raise newException(ValueError,"invalid module digest key profile")
  result = @[0x5a'u8,0x4d,0x44,1]
  result.putU32(uint32(sourceCapacity))
  result.put key.alpha
  result.put key.beta
  result.put key.gamma
  result.put key.delta
  for point in key.inputs: result.put point

proc prepareModuleDigestKey*(trustedDigest: Sha256Digest,
    encoded: openArray[byte]): PinnedModuleDigestKey =
  if encoded.len != ModuleDigestKeySize: return nil
  # Hash and decode the same owned snapshot, even if caller memory changes.
  let snapshot = @encoded
  if sha256(snapshot) != trustedDigest: return nil
  if snapshot[0..3] != [0x5a'u8,0x4d,0x44,1]: return nil
  try:
    var reader = Reader(data: snapshot,position: 4)
    let capacity = reader.getU32()
    if capacity < 8 or uint64(capacity) > uint64(high(int)): return nil
    var key: VerificationKey
    key.alpha = reader.point1(false)
    key.beta = reader.point2(false)
    key.gamma = reader.point2(false)
    key.delta = reader.point2(false)
    for _ in 0..2: key.inputs.add reader.point1()
    if reader.position != encoded.len: return nil
    PinnedModuleDigestKey(key: key,capacity: int(capacity))
  except ValueError:
    nil

proc sourceCapacity*(key: PinnedModuleDigestKey): int =
  if key == nil: 0 else: key.capacity

proc verifyModuleDigest*(key: PinnedModuleDigestKey, bytes, proof: openArray[byte]): bool =
  if key == nil or bytes.len > key.capacity: return false
  verifyModuleDigest(key.key,bytes,proof)
