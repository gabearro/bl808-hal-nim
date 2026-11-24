## Opt-in proof verification for the explicitly bounded zkbuild WASM profile.
## The caller pins the key digest and chooses which claim it requires.
## This is not wired into general module admission until all required profiles
## and the implementation-refinement proof obligations are complete.
import cps/zk/wire
import enclave/sha256

type
  WasmProofResult* = enum
    wprOk, wprKeyMismatch, wprInvalidKey, wprWrongClaim, wprInvalidProof
  PinnedWasmKey* = ref object
    ## Construct through prepareWasmKey. Fields remain private so an admitted
    ## key cannot be substituted or have its claim changed by the caller.
    key: VerificationKey
    mode: ProofMode
    initialized: bool

proc prepareWasmKey*(trustedKeyDigest: Sha256Digest, expectedMode: ProofMode,
                     keyBytes: openArray[byte]): tuple[status: WasmProofResult,
                                                       key: PinnedWasmKey] =
  if keyBytes.len > 4096:
    return (wprKeyMismatch, nil)
  # Pin and deserialize the same owned snapshot, then retain only decoded
  # points. The handle never retains caller-owned key bytes.
  let snapshot = @keyBytes
  if sha256(snapshot) != trustedKeyDigest: return (wprKeyMismatch, nil)
  var key: VerificationKey
  var mode: ProofMode
  if not decodeKey(snapshot, key, mode): return (wprInvalidKey, nil)
  if mode != expectedMode: return (wprWrongClaim, nil)
  (wprOk, PinnedWasmKey(key: key, mode: mode, initialized: true))

proc validArtifactLengths(mode: ProofMode, wasmBytes, nativeBytes,
                          proofBytes: openArray[byte]): bool =
  if proofBytes.len != 192: return false
  if mode in {pmValidateBytes, pmCompileBytes}:
    if wasmBytes.len < StreamWasmMinSize or wasmBytes.len > StreamWasmMaxSize:
      return false
  elif wasmBytes.len != WasmSize: return false
  if mode in {pmCompile, pmCompileBytes}:
    if nativeBytes.len != NativeSize: return false
  elif nativeBytes.len != 0: return false
  true

proc verifyWasmProof*(key: PinnedWasmKey, expectedMode: ProofMode, wasmBytes, nativeBytes,
                      proofBytes: openArray[byte]): WasmProofResult =
  if key.isNil or not key.initialized: return wprInvalidKey
  if key.mode != expectedMode: return wprWrongClaim
  if not validArtifactLengths(key.mode, wasmBytes, nativeBytes, proofBytes):
    return wprInvalidProof
  let wasmSnapshot = @wasmBytes
  let nativeSnapshot = @nativeBytes
  let proofSnapshot = @proofBytes
  if not verifyArtifacts(key.key, key.mode, wasmSnapshot, nativeSnapshot, proofSnapshot):
    return wprInvalidProof
  wprOk

proc verifyWasmProof*(trustedKeyDigest: Sha256Digest, expectedMode: ProofMode,
                      keyBytes, wasmBytes, nativeBytes,
                      proofBytes: openArray[byte]): WasmProofResult =
  if not validArtifactLengths(expectedMode, wasmBytes, nativeBytes, proofBytes):
    return wprInvalidProof
  let prepared = prepareWasmKey(trustedKeyDigest, expectedMode, keyBytes)
  if prepared.status != wprOk: return prepared.status
  verifyWasmProof(prepared.key, expectedMode, wasmBytes, nativeBytes, proofBytes)
