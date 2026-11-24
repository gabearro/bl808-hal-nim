## Compilation check only. This is not a hardware smoke test.
import bl808/wasm_proof
import bl808/wasm_verified_native
import bl808/enclave/sha256
import cps/zk/wasm_profile
import cps/zk/field
import cps/zk/[wasm_module_verifier, groth16]
import cps/zk/wasm_digest_key

proc zkbuildModuleProofTypecheck*(key: ptr VerificationKey, wasm, proof: openArray[byte],
                                sourceCapacity: int): bool {.exportc.} =
  ## Compile the experimental verifier without enabling kernel admission.
  verifyModuleValidation(key[], wasm, proof, sourceCapacity)

proc zkbuildModuleDigestTypecheck*(key: ptr VerificationKey, wasm,
                                  proof: openArray[byte]): bool {.exportc.} =
  verifyModuleDigest(key[], wasm, proof)

proc zkbuildPinnedModuleDigestTypecheck*(expected: Sha256Digest,
    encodedKey, wasm, proof: openArray[byte]): bool {.exportc.} =
  verifyModuleDigest(prepareModuleDigestKey(expected,encodedKey),wasm,proof)

proc zkbuildScalarTypecheck*(encoded: array[32, byte]): bool {.exportc.} =
  var value: Scalar
  decodeScalar(encoded, value)

proc zkbuildTargetTypecheck*(trusted: Sha256Digest, key, wasm,
                            proof: openArray[byte]): WasmProofResult {.exportc.} =
  verifyWasmProof(trusted, pmValidateBytes, key, wasm, [], proof)

proc zkbuildNativeTypecheck*(trusted: Sha256Digest, key, wasm, native,
                            proof: openArray[byte]): VerifiedNativeLoadStatus {.exportc.} =
  let loaded = loadVerifiedNativeWasm(trusted, key, wasm, native, proof)
  if loaded.status == vnlOk:
    discard loaded.module.invokeI32([20'i32, 22'i32])
  loaded.status

proc zkbuildByteNativeTypecheck*(trusted: Sha256Digest, key, wasm, native,
                                proof: openArray[byte]): VerifiedNativeLoadStatus {.exportc.} =
  let loaded = loadVerifiedByteNativeWasm(trusted, key, wasm, native, proof)
  if loaded.status == vnlOk:
    discard loaded.module.invokeI32([20'i32, 22'i32])
  loaded.status
