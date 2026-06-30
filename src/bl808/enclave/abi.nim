## Enclave service ABI — the stable contract between the untrusted world
## (U-mode app via ecall, or D0/LP via the XRAM mailbox) and the enclave.
##
## Requests and responses are byte buffers placed at offset 0 of the shared
## copy buffer; no pointers ever cross the boundary. The transport carries only
## a service id and a length:
##   ecall:  a0 = SvcId, a1 = request length  ->  a0 = SvcStatus, a1 = response length
##   IPC:    mailbox tag = SvcId, payload = request           -> reply payload = response
##
## Each service defines a fixed request/response layout below. Multi-byte
## integers are little-endian.

type
  SvcId* = enum
    svcNop          = 0
    svcGetRandom    = 1   ## req: u32 nbytes              -> resp: nbytes random
    svcSha256       = 2   ## req: data                    -> resp: 32-byte digest
    svcDeriveKey    = 3   ## req: hdr+label+context       -> resp: u32 handle
    svcAeadSeal     = 4   ## req: hdr+nonce+aad+pt         -> resp: ct || tag(32)
    svcAeadOpen     = 5   ## req: hdr+nonce+aad+ct+tag     -> resp: pt
    svcP256Sign     = 6   ## req: u32 handle + 32-byte hash-> resp: r(32)||s(32)
    svcP256Verify   = 7   ## req: pub(64)+hash(32)+sig(64) -> resp: u8 ok
    svcGetAttestation = 8 ## req: nonce(32)               -> resp: id(8)+meas(32)+sig(64)
    svcSealBlob     = 9   ## req: data                    -> resp: nonce(16)+ct+tag(32)
    svcUnsealBlob   = 10  ## req: nonce(16)+ct+tag(32)     -> resp: data
    svcWasmInvokeI32 = 11 ## req: slot/name/args          -> resp: status+errors+i32
    svcWasmCapabilities = 12 ## req: empty                 -> resp: 8*u32 runtime caps
    svcWasmInstallBytes = 13 ## req: slot/gen/flags/len/wasm -> resp: status+errors+slot
    svcWasmUnloadSlot = 14 ## req: u32 slot                -> resp: status+errors+slot
    svcWasmTaskStartI32 = 15 ## req: slot/name/args         -> resp: task status/result
    svcWasmTaskResume = 16 ## req: u32 task | u32 fuel      -> resp: task status/result
    svcWasmTaskStatus = 17 ## req: u32 task                 -> resp: task status/result
    svcWasmTaskKill = 18 ## req: u32 task                   -> resp: task status/result

  SvcStatus* = enum
    svcOk          = 0
    svcBadRequest  = 1
    svcDenied      = 2
    svcBusy        = 3
    svcCryptoFail  = 4
    svcUnsupported = 5
    svcTooBig      = 6

  CallerKind* = enum
    callerUmodeApp,          ## M0 U-mode ecall through enclaveEcall
    callerPeerD0,            ## D0 IPC request
    callerPeerLP,            ## LP IPC request
    callerTrustedEnclave,    ## trusted M0/M-mode enclave-internal call
    callerTestHarness        ## direct validation harness setup/dispatch

  CallerContext* = object
    ## Internal caller identity. This is deliberately not part of the wire ABI.
    ## If the enclave grows multi-principal support, add a principal/enclave id
    ## here rather than merging trusted and U-mode M0 code.
    kind*: CallerKind

const
  SvcMaxPayload* = 4096   ## shared buffer size (matches bl808_m0_enclave.ld)
  SvcIpcTagBase* = 0xE000'u16   ## IPC mailbox tag base for enclave services

proc toSvcId*(v: uint32): SvcId {.inline.} =
  if v <= svcWasmTaskKill.uint32: v.SvcId else: svcNop

proc callerUmodeAppCtx*(): CallerContext {.inline.} =
  CallerContext(kind: callerUmodeApp)

proc callerPeerD0Ctx*(): CallerContext {.inline.} =
  CallerContext(kind: callerPeerD0)

proc callerPeerLPCtx*(): CallerContext {.inline.} =
  CallerContext(kind: callerPeerLP)

proc callerTrustedEnclaveCtx*(): CallerContext {.inline.} =
  CallerContext(kind: callerTrustedEnclave)

proc callerTestHarnessCtx*(): CallerContext {.inline.} =
  CallerContext(kind: callerTestHarness)

proc isTrustedCaller*(ctx: CallerContext): bool {.inline.} =
  ctx.kind == callerTrustedEnclave or ctx.kind == callerTestHarness

proc sameCaller*(a, b: CallerContext): bool {.inline.} =
  a.kind == b.kind

proc rdU32*(buf: ptr UncheckedArray[uint8], off: int): uint32 {.inline.} =
  buf[off].uint32 or (buf[off+1].uint32 shl 8) or
  (buf[off+2].uint32 shl 16) or (buf[off+3].uint32 shl 24)

proc wrU32*(buf: ptr UncheckedArray[uint8], off: int, v: uint32) {.inline.} =
  buf[off]   = (v and 0xFF).uint8
  buf[off+1] = ((v shr 8) and 0xFF).uint8
  buf[off+2] = ((v shr 16) and 0xFF).uint8
  buf[off+3] = ((v shr 24) and 0xFF).uint8
