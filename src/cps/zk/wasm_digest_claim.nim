## Two public 128-bit limbs, in SHA-256 digest byte order. No prover imports.
import field
import ../../bl808/enclave/sha256
export field, sha256

proc digestInputs*(digest: Sha256Digest): array[2,Scalar] =
  for limb in 0..1:
    var encoded: array[32,byte]
    for i in 0..15: encoded[16+i] = digest[16*limb+i]
    if not decodeScalar(encoded,result[limb]):
      raise newException(ValueError,"noncanonical digest limb")

proc wasmDigestInputs*(bytes: openArray[byte]): array[2,Scalar] =
  if uint64(bytes.len) > uint64(high(uint32)):
    raise newException(ValueError,"WASM digest exceeds u32 byte length")
  digestInputs(sha256(bytes))
