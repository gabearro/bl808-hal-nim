## Proof-gated execution of the fixed-slot and ordinary-byte RV32 profiles.
## The owned code buffer is never exposed. General WASM/JIT admission is separate.
import wasm_proof
import enclave/sha256
import cps/zk/wasm_profile

when defined(bl808m0) or defined(zkbuildRv32Ram):
  when not defined(riscv32) or cpuEndian != littleEndian:
    {.error: "verified native execution requires a little-endian RV32 target".}
when defined(bl808m0):
  import core

type
  VerifiedNativeWasmModule* = ref object
    code: array[NativeSize div 4, uint32]
    initialized: bool
  VerifiedNativeLoadStatus* = enum
    vnlOk, vnlProofRejected
  VerifiedNativeLoadResult* = object
    status*: VerifiedNativeLoadStatus
    proofStatus*: WasmProofResult
    module*: VerifiedNativeWasmModule

func nativeExecutionSupported*(): bool =
  ## zkbuildRv32Ram is an explicit bare-metal platform contract: coherent,
  ## executable RAM and an RV32IM-compatible CPU. It does not relax verification.
  defined(bl808m0) or defined(zkbuildRv32Ram)

proc publishCode(module: VerifiedNativeWasmModule) =
  when defined(bl808m0):
    dcacheCleanRange(cast[uint](addr module.code[0]), NativeSize.uint)
    core.fence()
    icacheInvalidateAll()
    fenceI()
  elif defined(zkbuildRv32Ram):
    # Standard FENCE.I encoding, independent of assembler extension spelling.
    {.emit: "__asm__ volatile (\".word 0x0000100f\" ::: \"memory\");".}
  else:
    discard module

proc loadNativeWasm(key: PinnedWasmKey, mode: ProofMode, wasmBytes, nativeBytes,
                    proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  result.status = vnlProofRejected
  result.proofStatus = wprInvalidProof
  let validWasmLength = if mode == pmCompile: wasmBytes.len == WasmSize
                       else: wasmBytes.len >= StreamWasmMinSize and wasmBytes.len <= StreamWasmMaxSize
  if not validWasmLength or nativeBytes.len != NativeSize or proofBytes.len != 192:
    return
  # Pin verification and publication to the same owned snapshots. Copying the
  # final words cannot race subsequent changes to caller-owned input buffers.
  let wasm = @wasmBytes
  let native = @nativeBytes
  let proof = @proofBytes
  result.proofStatus = verifyWasmProof(key, mode, wasm, native, proof)
  if result.proofStatus != wprOk: return
  let module = VerifiedNativeWasmModule()
  for i in 0..<module.code.len:
    let offset = i*4
    module.code[i] = uint32(native[offset]) or (uint32(native[offset+1]) shl 8) or
      (uint32(native[offset+2]) shl 16) or (uint32(native[offset+3]) shl 24)
  module.publishCode()
  module.initialized = true
  result.module = module
  result.status = vnlOk

proc loadNativeWasm(trustedKeyDigest: Sha256Digest, mode: ProofMode, keyBytes, wasmBytes,
                    nativeBytes, proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  let validWasmLength = if mode == pmCompile: wasmBytes.len == WasmSize
                       else: wasmBytes.len >= StreamWasmMinSize and wasmBytes.len <= StreamWasmMaxSize
  if not validWasmLength or nativeBytes.len != NativeSize or proofBytes.len != 192:
    return VerifiedNativeLoadResult(status: vnlProofRejected, proofStatus: wprInvalidProof)
  let prepared = prepareWasmKey(trustedKeyDigest, mode, keyBytes)
  if prepared.status != wprOk:
    return VerifiedNativeLoadResult(status: vnlProofRejected, proofStatus: prepared.status)
  loadNativeWasm(prepared.key, mode, wasmBytes, nativeBytes, proofBytes)

proc loadVerifiedNativeWasm*(key: PinnedWasmKey, wasmBytes, nativeBytes,
                             proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  loadNativeWasm(key, pmCompile, wasmBytes, nativeBytes, proofBytes)

proc loadVerifiedNativeWasm*(trustedKeyDigest: Sha256Digest, keyBytes, wasmBytes,
                             nativeBytes, proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  loadNativeWasm(trustedKeyDigest, pmCompile, keyBytes, wasmBytes, nativeBytes, proofBytes)

proc loadVerifiedByteNativeWasm*(key: PinnedWasmKey, wasmBytes, nativeBytes,
                                 proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  ## Opt-in ordinary-byte compilation claim, separate from fixed-slot keys.
  loadNativeWasm(key, pmCompileBytes, wasmBytes, nativeBytes, proofBytes)

proc loadVerifiedByteNativeWasm*(trustedKeyDigest: Sha256Digest, keyBytes, wasmBytes,
                                 nativeBytes, proofBytes: openArray[byte]): VerifiedNativeLoadResult =
  loadNativeWasm(trustedKeyDigest, pmCompileBytes, keyBytes, wasmBytes, nativeBytes, proofBytes)

proc invokeI32*(module: VerifiedNativeWasmModule, arguments: array[2, int32]): int32 =
  if module.isNil or not module.initialized:
    raise newException(ValueError, "verified native WASM module is not loaded")
  when defined(bl808m0) or defined(zkbuildRv32Ram):
    type Entry = proc(a, b: int32): int32 {.cdecl, raises: [].}
    let entry = cast[Entry](addr module.code[0])
    entry(arguments[0], arguments[1])
  else:
    raise newException(ValueError, "verified native WASM execution requires an RV32 executable-RAM target")
