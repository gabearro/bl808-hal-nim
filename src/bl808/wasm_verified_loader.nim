## Opt-in loader for the bounded byte-stream proof profile. This does not
## change existing loader policy or claim general WASM compiler verification.
import wasm_proof
import enclave/sha256
import cps/zk/wasm_profile
import cps/wasm/[binary, validate, runtime_int]

type
  VerifiedWasmModule* = ref object
    vm: IntWasmVM
    moduleIndex: int
    exportName: string
    initialized: bool
  VerifiedWasmLoadStatus* = enum
    vwlOk, vwlProofRejected, vwlRuntimeRejected
  VerifiedWasmLoadResult* = object
    status*: VerifiedWasmLoadStatus
    proofStatus*: WasmProofResult
    module*: VerifiedWasmModule

proc loadVerifiedWasm*(key: PinnedWasmKey,
                       wasmBytes, proofBytes: openArray[byte]): VerifiedWasmLoadResult =
  result.status = vwlProofRejected
  if wasmBytes.len < StreamWasmMinSize or wasmBytes.len > StreamWasmMaxSize:
    result.proofStatus = wprInvalidProof
    return
  # Verification and instantiation use the same owned snapshot. Do not retain
  # a pointer into caller memory or a writable flash/DMA buffer.
  let snapshot = @wasmBytes
  result.proofStatus = verifyWasmProof(key, pmValidateBytes, snapshot, [], proofBytes)
  if result.proofStatus != wprOk: return
  try:
    let parsed = decodeModule(snapshot)
    # Retained as a consistency backstop while circuit/decoder refinement and
    # the complete profile proof remain in progress.
    validateModule(parsed)
    let loaded = VerifiedWasmModule(vm: initIntWasmVM())
    loaded.moduleIndex = loaded.vm.instantiateIntOnly(parsed)
    for i in 25..27: loaded.exportName.add snapshot[i].char
    loaded.initialized = true
    result.module = loaded
    result.status = vwlOk
  except CatchableError:
    result.status = vwlRuntimeRejected

proc loadVerifiedWasm*(trustedKeyDigest: Sha256Digest,
                       keyBytes, wasmBytes, proofBytes: openArray[byte]): VerifiedWasmLoadResult =
  let prepared = prepareWasmKey(trustedKeyDigest, pmValidateBytes, keyBytes)
  if prepared.status != wprOk:
    return VerifiedWasmLoadResult(status: vwlProofRejected, proofStatus: prepared.status)
  loadVerifiedWasm(prepared.key, wasmBytes, proofBytes)

proc invokeI32*(module: VerifiedWasmModule, arguments: array[2, int32]): int32 =
  if module.isNil or not module.initialized:
    raise newException(ValueError, "verified WASM module is not loaded")
  module.vm.invokeI32(module.moduleIndex, module.exportName, arguments)
