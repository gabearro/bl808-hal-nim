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
    svcSealBlob     = 9   ## req: nonce(16)+data           -> resp: sealed (data||tag)
    svcUnsealBlob   = 10  ## req: nonce(16)+sealed         -> resp: data

  SvcStatus* = enum
    svcOk          = 0
    svcBadRequest  = 1
    svcDenied      = 2
    svcBusy        = 3
    svcCryptoFail  = 4
    svcUnsupported = 5
    svcTooBig      = 6

const
  SvcMaxPayload* = 4096   ## shared buffer size (matches bl808_m0_enclave.ld)
  SvcIpcTagBase* = 0xE000'u16   ## IPC mailbox tag base for enclave services

proc toSvcId*(v: uint32): SvcId {.inline.} =
  if v <= svcUnsealBlob.uint32: v.SvcId else: svcNop

proc rdU32*(buf: ptr UncheckedArray[uint8], off: int): uint32 {.inline.} =
  buf[off].uint32 or (buf[off+1].uint32 shl 8) or
  (buf[off+2].uint32 shl 16) or (buf[off+3].uint32 shl 24)

proc wrU32*(buf: ptr UncheckedArray[uint8], off: int, v: uint32) {.inline.} =
  buf[off]   = (v and 0xFF).uint8
  buf[off+1] = ((v shr 8) and 0xFF).uint8
  buf[off+2] = ((v shr 16) and 0xFF).uint8
  buf[off+3] = ((v shr 24) and 0xFF).uint8
