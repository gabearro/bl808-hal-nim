## Opt-in proof-gated loading through the existing full WASM engine. Verification
## certifies source validity, not the correctness of JIT/optimizer transformations.
## The ordinary API keeps its existing policy; callers enforce admission by
## using only these entry points for untrusted builds.
import api
import ../zk/wasm_digest_key
import ../../bl808/enclave/sha256
export api, wasm_digest_key

type WasmProofError* = object of WasmError

proc loadProvenBytes*(engine: WasmEngine, key: PinnedModuleDigestKey,
    data, proof: openArray[byte]): LoadedModule =
  if engine == nil: raise newException(WasmError,"missing WASM engine")
  if key == nil or data.len < 8 or data.len > key.sourceCapacity or proof.len != 192:
    raise newException(WasmProofError,"module proof rejected")
  # Verification, parsing, validation and instantiation refer to this one owned
  # source snapshot. No caller-owned buffer reaches import/start execution.
  let snapshot = @data
  let certificate = @proof
  if not key.verifyModuleDigest(snapshot,certificate):
    raise newException(WasmProofError,"module proof rejected")
  # Keep the host validator as a backstop until end-to-end Nim refinement is
  # complete. This path deliberately avoids decoder peephole optimization.
  engine.loadValidatedBytes(snapshot)

proc loadProvenBytes*(engine: WasmEngine, trustedKeyDigest: Sha256Digest,
    keyBytes, data, proof: openArray[byte]): LoadedModule =
  engine.loadProvenBytes(prepareModuleDigestKey(trustedKeyDigest,keyBytes),data,proof)
