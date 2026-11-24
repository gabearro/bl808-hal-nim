## Experimental general-WASM verification. The caller must pin a key produced
## for the complete source-bound relation and the same source capacity. This
## module does not decode WASM or reconstruct validation tables/events.
import groth16, wasm_binary_claim
import wasm_digest_claim

proc verifyModuleValidation*(trustedKey: VerificationKey, bytes, proof: openArray[byte],
    sourceCapacity: int): bool =
  if proof.len != 192 or sourceCapacity < bytes.len or sourceCapacity < 8 or
      uint64(sourceCapacity) > uint64(high(uint32)) or bytes.len < 8:
    return false
  if trustedKey.inputs.len != 2+binarySourceLimbCount(sourceCapacity): return false
  trustedKey.decodeAndVerify(proof, binarySourceInputs(bytes, sourceCapacity))

proc verifyModuleDigest*(trustedKey: VerificationKey, bytes, proof: openArray[byte]): bool =
  ## The pinned key determines the SHA-256 relation and its profile capacity.
  ## Only two digest scalars enter the curve verifier, regardless of capacity.
  if proof.len != 192 or bytes.len < 8 or uint64(bytes.len) > uint64(high(uint32)) or
      trustedKey.inputs.len != 3:
    return false
  trustedKey.decodeAndVerify(proof,wasmDigestInputs(bytes))
