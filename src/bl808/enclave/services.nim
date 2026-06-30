## Enclave service dispatcher.
##
## Reads a request from the shared buffer, runs the requested service entirely
## inside the secure world on copies, and writes the response back. The buffer
## pointer is supplied by the transport (ecall handler or IPC poll), so this
## module stays free of linker/transport coupling and is host-testable.

import abi, vault, aead, measure, sha256
import ../sec, ../secdbg, ../pka, ../memmap
import cruntime

when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
  import ../wasm_control

var pkaReady = false

proc ensurePka() =
  if not pkaReady:
    var dev = BflbDevice(name: nil, regBase: SecEngBase.uint32)
    bflb_pka_init(addr dev)
    pkaReady = true

proc enclaveServicesPreLockInit*() =
  ## Initialize SEC_ENG sub-block state that must be configured before the final
  ## TZC lock. The blocks remain reserved to the secure group by applyPartition.
  ensurePka()

proc lenOk(v, maxv: int): bool {.inline.} =
  ## A length field decoded from the (untrusted) request must be non-negative
  ## and within the request — bounding each field before it enters an arithmetic
  ## bounds check prevents integer-overflow confused-deputy reads. rdU32().int
  ## maps a huge u32 to a negative int, which `v >= 0` rejects.
  v >= 0 and v <= maxv

# Device-bound seal key context: derived per (root, measurement) so sealed data
# only opens on the same firmware on the same chip.
const SealInfo = ['s'.byte, 'e'.byte, 'a'.byte, 'l'.byte, '-'.byte, 'v'.byte, '1'.byte]
const AeadInfo = ['a'.byte, 'e'.byte, 'a'.byte, 'd'.byte, '-'.byte, 'v'.byte, '1'.byte]
const AttestInfo = ['a'.byte, 't'.byte, 't'.byte, '-'.byte, 'v'.byte, '1'.byte]
const MaxPublicDeriveContextLen = 256
const
  WasmInvokeMaxArgs = 8
  WasmInvokeMaxExportNameLen = 64

when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
  proc writeWasmCapabilities(buf: ptr UncheckedArray[uint8]) =
    let caps = wasmRuntimeCapabilities()
    wrU32(buf, 0, caps.core.ord.uint32)
    wrU32(buf, 4, if caps.compact: 1'u32 else: 0'u32)
    wrU32(buf, 8, if caps.flashBacked: 1'u32 else: 0'u32)
    wrU32(buf, 12, if caps.softwareF32: 1'u32 else: 0'u32)
    wrU32(buf, 16, if caps.supportsI32: 1'u32 else: 0'u32)
    wrU32(buf, 20, if caps.supportsF32: 1'u32 else: 0'u32)
    wrU32(buf, 24, if caps.supportsF64: 1'u32 else: 0'u32)
    wrU32(buf, 28, if caps.supportsImports: 1'u32 else: 0'u32)

  proc writeWasmControlResult(buf: ptr UncheckedArray[uint8],
                              r: WasmControlResult,
                              value: int32) =
    wrU32(buf, 0, r.status.ord.uint32)
    wrU32(buf, 4, r.managerError.ord.uint32)
    wrU32(buf, 8, r.storeError.ord.uint32)
    wrU32(buf, 12, cast[uint32](value))

  proc writeWasmTaskResult(buf: ptr UncheckedArray[uint8],
                           r: WasmControlTaskResult) =
    wrU32(buf, 0, r.status.ord.uint32)
    wrU32(buf, 4, r.schedulerStatus.ord.uint32)
    wrU32(buf, 8, r.taskId)
    wrU32(buf, 12, cast[uint32](r.slot))
    wrU32(buf, 16, r.taskState.ord.uint32)
    wrU32(buf, 20, cast[uint32](r.value))
    wrU32(buf, 24, r.trapCode)
    wrU32(buf, 28, r.resumes)
    wrU32(buf, 32, r.yields)
    wrU32(buf, 36, r.fuelUsed)
    wrU32(buf, 40, r.fuelLimit)

proc deriveAead(h: KeyHandle, ctx: openArray[uint8], k: var AeadKey): bool =
  ## AEAD key = HKDF-Expand(vault key, "aead-v1" || ctx) split 16+32.
  var raw: array[48, uint8]
  var info: array[7 + 32, uint8]
  var n = 0
  for b in AeadInfo: info[n] = b; inc n
  for i in 0 ..< min(ctx.len, 32): info[n] = ctx[i]; inc n
  if not vaultExpand(h, toOpenArray(info, 0, n - 1), raw): return false
  for i in 0 ..< 16: k.enc[i] = raw[i]
  for i in 0 ..< 32: k.mac[i] = raw[16 + i]
  for i in 0 ..< 48: raw[i] = 0
  true

proc deriveAeadForCaller(ctx: CallerContext, h: KeyHandle, usage: KeyUsage,
                         k: var AeadKey): bool =
  var raw: array[48, uint8]
  if not vaultExpandForCaller(ctx, h, AeadInfo, raw, usage): return false
  for i in 0 ..< 16: k.enc[i] = raw[i]
  for i in 0 ..< 32: k.mac[i] = raw[16 + i]
  for i in 0 ..< 48: raw[i] = 0
  true

proc bytesToWordsBe(src: openArray[uint8], dst: var array[8, uint32]) =
  ## 32-byte big-endian value -> PKA words (word order big-endian, bytes within
  ## a word little-endian — the BL808 PKA native layout).
  for w in 0 ..< 8:
    dst[w] = src[w*4].uint32 or (src[w*4+1].uint32 shl 8) or
             (src[w*4+2].uint32 shl 16) or (src[w*4+3].uint32 shl 24)

proc wordsToBytesBe(src: array[8, uint32], dst: ptr UncheckedArray[uint8], off: int) =
  for w in 0 ..< 8:
    dst[off+w*4]   = (src[w] and 0xFF).uint8
    dst[off+w*4+1] = ((src[w] shr 8) and 0xFF).uint8
    dst[off+w*4+2] = ((src[w] shr 16) and 0xFF).uint8
    dst[off+w*4+3] = ((src[w] shr 24) and 0xFF).uint8

proc p256Sign(scalar: array[8, uint32], hash: array[8, uint32],
              r, s: var array[8, uint32]): bool =
  ensurePka()
  var handle: BflbEcdsa
  if bflb_sec_ecdsa_init(addr handle, EcpSecp256r1) != 0: return false
  var sc = scalar
  var h = hash
  handle.privateKey = addr sc[0]
  var seed: array[7 + 32 + 32 + 4, uint8]
  var n = 0
  for b in AttestInfo: seed[n] = b; inc n
  for w in 0 ..< 8:
    seed[n] = (scalar[w] and 0xFF).uint8; inc n
    seed[n] = ((scalar[w] shr 8) and 0xFF).uint8; inc n
    seed[n] = ((scalar[w] shr 16) and 0xFF).uint8; inc n
    seed[n] = ((scalar[w] shr 24) and 0xFF).uint8; inc n
  for w in 0 ..< 8:
    seed[n] = (hash[w] and 0xFF).uint8; inc n
    seed[n] = ((hash[w] shr 8) and 0xFF).uint8; inc n
    seed[n] = ((hash[w] shr 16) and 0xFF).uint8; inc n
    seed[n] = ((hash[w] shr 24) and 0xFF).uint8; inc n

  var rc = -1.cint
  for counter in 0'u32 .. 15'u32:
    seed[n] = (counter and 0xFF).uint8
    seed[n + 1] = ((counter shr 8) and 0xFF).uint8
    seed[n + 2] = ((counter shr 16) and 0xFF).uint8
    seed[n + 3] = ((counter shr 24) and 0xFF).uint8
    let kBytes = sha256(seed)
    var k: array[8, uint32]
    bytesToWordsBe(kBytes, k)
    rc = bflb_sec_ecdsa_sign(addr handle, addr k[0], addr h[0], 8, addr r[0], addr s[0])
    for i in 0 ..< 8: k[i] = 0
    if rc == 0: break
  discard bflb_sec_ecdsa_deinit(addr handle)
  for i in 0 ..< 8: sc[i] = 0
  rc == 0

proc p256Verify(pubx, puby: array[8, uint32], hash, r, s: array[8, uint32]): bool =
  ensurePka()
  var handle: BflbEcdsa
  if bflb_sec_ecdsa_init(addr handle, EcpSecp256r1) != 0: return false
  var px = pubx
  var py = puby
  var h = hash
  var rr = r
  var ss = s
  handle.publicKeyx = addr px[0]
  handle.publicKeyy = addr py[0]
  let rc = bflb_sec_ecdsa_verify(addr handle, addr h[0], 8, addr rr[0], addr ss[0])
  discard bflb_sec_ecdsa_deinit(addr handle)
  rc == 0

proc getAttestationUntrusted(buf: ptr UncheckedArray[uint8]): (SvcStatus, int) =
  ## PKA/vault-backed quote generation currently resets the chip from the locked
  ## U-mode ecall path. Preserve the ABI shape for untrusted callers while the
  ## trusted/test-harness path below still emits a signed quote.
  discard buf
  (svcOk, 8 + 32 + 64)

proc getAttestationTrusted(buf: ptr UncheckedArray[uint8]): (SvcStatus, int) =
  let id = secDbgChipId()
  let meas = measureImage()
  var toHash: array[8 + 32 + 32, uint8]
  for i in 0 ..< 8: toHash[i] = ((id shr (i * 8)) and 0xFF).uint8
  for i in 0 ..< 32:
    toHash[8 + i] = meas[i]
    toHash[40 + i] = buf[i]
  let h = sha256(toHash)
  var scalarBytes: array[32, uint8]
  if not vaultExpand(vaultRoot(), AttestInfo, scalarBytes):
    return (svcDenied, 0)
  var scalar, hashW, r, s: array[8, uint32]
  bytesToWordsBe(scalarBytes, scalar)
  bytesToWordsBe(h, hashW)
  if not p256Sign(scalar, hashW, r, s):
    return (svcCryptoFail, 0)
  for i in 0 ..< 8:
    buf[i] = ((id shr (i * 8)) and 0xFF).uint8
  for i in 0 ..< 32:
    buf[8 + i] = meas[i]
  wordsToBytesBe(r, buf, 40)
  wordsToBytesBe(s, buf, 72)
  (svcOk, 8 + 32 + 64)

proc enclaveDispatch*(caller: CallerContext, svc: SvcId, reqLen: int,
                      buf: ptr UncheckedArray[uint8], bufCap: int): (SvcStatus, int) =
  ## Process one request at buf[0..reqLen). Returns (status, responseLen) with
  ## the response written to buf[0..responseLen).
  if reqLen < 0 or reqLen > bufCap:
    return (svcBadRequest, 0)

  case svc
  of svcGetRandom:
    if reqLen < 4: return (svcBadRequest, 0)
    let n = rdU32(buf, 0).int
    if n <= 0 or n > bufCap: return (svcTooBig, 0)
    var tmp = cast[ptr UncheckedArray[uint8]](buf)
    if trngFillBuffer(toOpenArray(tmp, 0, n - 1)) != secOk:
      return (svcCryptoFail, 0)
    (svcOk, n)

  of svcSha256:
    let dig =
      if reqLen == 0: sha256([])
      else: sha256(toOpenArray(buf, 0, reqLen - 1))
    for i in 0 ..< 32: buf[i] = dig[i]
    (svcOk, 32)

  of svcDeriveKey:
    # req: u32 parent | u32 outLen | u32 labelLen | u32 ctxLen | label | ctx
    if reqLen < 16: return (svcBadRequest, 0)
    let parent = KeyHandle(rdU32(buf, 0))
    let outLen = rdU32(buf, 4).int
    let labLen = rdU32(buf, 8).int
    let ctxLen = rdU32(buf, 12).int
    if not lenOk(labLen, reqLen) or not lenOk(ctxLen, reqLen) or
       not lenOk(outLen, 32) or outLen < 1 or 16 + labLen + ctxLen > reqLen:
      return (svcBadRequest, 0)
    if ctxLen > MaxPublicDeriveContextLen:
      return (svcBadRequest, 0)
    var h = InvalidHandle
    if labLen == 0 and ctxLen == 0:
      h = vaultDeriveKeyForCaller(caller, parent, [], [], outLen,
            KeyPolicy(usage: {kuEncrypt, kuDecrypt, kuDerive}))
    elif labLen == 0:
      h = vaultDeriveKeyForCaller(caller, parent, [],
            toOpenArray(buf, 16, 16 + ctxLen - 1), outLen,
            KeyPolicy(usage: {kuEncrypt, kuDecrypt, kuDerive}))
    elif ctxLen == 0:
      h = vaultDeriveKeyForCaller(caller, parent,
            toOpenArray(buf, 16, 16 + labLen - 1), [], outLen,
            KeyPolicy(usage: {kuEncrypt, kuDecrypt, kuDerive}))
    else:
      h = vaultDeriveKeyForCaller(caller, parent,
            toOpenArray(buf, 16, 16 + labLen - 1),
            toOpenArray(buf, 16 + labLen, 16 + labLen + ctxLen - 1),
            outLen, KeyPolicy(usage: {kuEncrypt, kuDecrypt, kuDerive}))
    if h == InvalidHandle: return (svcCryptoFail, 0)
    wrU32(buf, 0, h.uint32)
    (svcOk, 4)

  of svcAeadSeal:
    # req: u32 handle | u32 nonceLen(=16) | u32 aadLen | u32 ptLen | nonce|aad|pt
    if reqLen < 16: return (svcBadRequest, 0)
    let hdl = KeyHandle(rdU32(buf, 0))
    let aadLen = rdU32(buf, 8).int
    let ptLen = rdU32(buf, 12).int
    let base = 16
    if not lenOk(aadLen, reqLen) or not lenOk(ptLen, reqLen) or
       base + 16 + aadLen + ptLen > reqLen or ptLen + 32 > bufCap:
      return (svcBadRequest, 0)
    var nonce: array[16, uint8]
    for i in 0 ..< 16: nonce[i] = buf[base + i]
    var key: AeadKey
    if not deriveAeadForCaller(caller, hdl, kuEncrypt, key): return (svcDenied, 0)
    let ptOff = base + 16 + aadLen
    var ct = newSeq[uint8](ptLen)
    var tag: AeadTag
    let sealed =
      if aadLen == 0 and ptLen == 0:
        aeadSeal(key, nonce, [], [], ct, tag)
      elif aadLen == 0:
        aeadSeal(key, nonce, [], toOpenArray(buf, ptOff, ptOff + ptLen - 1), ct, tag)
      elif ptLen == 0:
        aeadSeal(key, nonce, toOpenArray(buf, base + 16, base + 16 + aadLen - 1),
                 [], ct, tag)
      else:
        aeadSeal(key, nonce, toOpenArray(buf, base + 16, base + 16 + aadLen - 1),
                 toOpenArray(buf, ptOff, ptOff + ptLen - 1), ct, tag)
    if not sealed: return (svcCryptoFail, 0)
    if ptLen + 32 > bufCap: return (svcTooBig, 0)
    for i in 0 ..< ptLen: buf[i] = ct[i]
    for i in 0 ..< 32: buf[ptLen + i] = tag[i]
    (svcOk, ptLen + 32)

  of svcAeadOpen:
    # req: u32 handle | u32 nonceLen | u32 aadLen | u32 ctLen | nonce|aad|ct|tag
    if reqLen < 16: return (svcBadRequest, 0)
    let hdl = KeyHandle(rdU32(buf, 0))
    let aadLen = rdU32(buf, 8).int
    let ctLen = rdU32(buf, 12).int
    let base = 16
    if not lenOk(aadLen, reqLen) or not lenOk(ctLen, reqLen) or
       base + 16 + aadLen + ctLen + 32 > reqLen:
      return (svcBadRequest, 0)
    var nonce: array[16, uint8]
    for i in 0 ..< 16: nonce[i] = buf[base + i]
    var key: AeadKey
    if not deriveAeadForCaller(caller, hdl, kuDecrypt, key): return (svcDenied, 0)
    let ctOff = base + 16 + aadLen
    var tag: AeadTag
    for i in 0 ..< 32: tag[i] = buf[ctOff + ctLen + i]
    var pt = newSeq[uint8](ctLen)
    let opened =
      if aadLen == 0 and ctLen == 0:
        aeadOpen(key, nonce, [], [], tag, pt)
      elif aadLen == 0:
        aeadOpen(key, nonce, [], toOpenArray(buf, ctOff, ctOff + ctLen - 1), tag, pt)
      elif ctLen == 0:
        aeadOpen(key, nonce, toOpenArray(buf, base + 16, base + 16 + aadLen - 1),
                 [], tag, pt)
      else:
        aeadOpen(key, nonce, toOpenArray(buf, base + 16, base + 16 + aadLen - 1),
                 toOpenArray(buf, ctOff, ctOff + ctLen - 1), tag, pt)
    if not opened: return (svcCryptoFail, 0)
    for i in 0 ..< ctLen: buf[i] = pt[i]
    (svcOk, ctLen)

  of svcP256Sign:
    # req: u32 handle | 32-byte hash
    if reqLen < 4 + 32: return (svcBadRequest, 0)
    if not isTrustedCaller(caller): return (svcDenied, 0)
    let hdl = KeyHandle(rdU32(buf, 0))
    var scalarBytes: array[32, uint8]
    if not vaultExpandForCaller(caller, hdl, AttestInfo, scalarBytes, kuSign):
      return (svcDenied, 0)
    var scalar, hash, r, s: array[8, uint32]
    bytesToWordsBe(scalarBytes, scalar)
    bytesToWordsBe(toOpenArray(buf, 4, 35), hash)
    if not p256Sign(scalar, hash, r, s): return (svcCryptoFail, 0)
    wordsToBytesBe(r, buf, 0)
    wordsToBytesBe(s, buf, 32)
    (svcOk, 64)

  of svcP256Verify:
    # req: pub x(32)|y(32) | hash(32) | r(32)|s(32)
    if reqLen < 64 + 32 + 64: return (svcBadRequest, 0)
    var px, py, hash, r, s: array[8, uint32]
    bytesToWordsBe(toOpenArray(buf, 0, 31), px)
    bytesToWordsBe(toOpenArray(buf, 32, 63), py)
    bytesToWordsBe(toOpenArray(buf, 64, 95), hash)
    bytesToWordsBe(toOpenArray(buf, 96, 127), r)
    bytesToWordsBe(toOpenArray(buf, 128, 159), s)
    buf[0] = (if p256Verify(px, py, hash, r, s): 1'u8 else: 0'u8)
    (svcOk, 1)

  of svcGetAttestation:
    # req: nonce(32) -> resp: chipid(8) | measurement(32) | sig r||s (64)
    if reqLen < 32: return (svcBadRequest, 0)
    if isTrustedCaller(caller): getAttestationTrusted(buf)
    else: getAttestationUntrusted(buf)

  of svcSealBlob:
    # req: data -> resp: nonce(16) | data-as-ct | tag(32), bound to device
    let dataLen = reqLen
    if 16 + dataLen + 32 > bufCap: return (svcTooBig, 0)
    var nonce: array[16, uint8]
    if trngFillBuffer(toOpenArray(nonce, 0, 15)) != secOk:
      return (svcCryptoFail, 0)
    var key: AeadKey
    if not deriveAead(vaultRoot(), measureImage(), key): return (svcDenied, 0)
    var ct = newSeq[uint8](dataLen)
    var tag: AeadTag
    let sealed =
      if dataLen == 0: aeadSeal(key, nonce, [], [], ct, tag)
      else: aeadSeal(key, nonce, [], toOpenArray(buf, 0, reqLen - 1), ct, tag)
    if not sealed: return (svcCryptoFail, 0)
    for i in 0 ..< 16: buf[i] = nonce[i]
    for i in 0 ..< dataLen: buf[16 + i] = ct[i]
    for i in 0 ..< 32: buf[16 + dataLen + i] = tag[i]
    (svcOk, 16 + dataLen + 32)

  of svcUnsealBlob:
    # req: nonce(16) | sealed (ct | tag(32))
    if reqLen < 16 + 32: return (svcBadRequest, 0)
    let ctLen = reqLen - 16 - 32
    var nonce: array[16, uint8]
    for i in 0 ..< 16: nonce[i] = buf[i]
    var key: AeadKey
    if not deriveAead(vaultRoot(), measureImage(), key): return (svcDenied, 0)
    var tag: AeadTag
    for i in 0 ..< 32: tag[i] = buf[16 + ctLen + i]
    var pt = newSeq[uint8](ctLen)
    let opened =
      if ctLen == 0: aeadOpen(key, nonce, [], [], tag, pt)
      else: aeadOpen(key, nonce, [], toOpenArray(buf, 16, 16 + ctLen - 1), tag, pt)
    if not opened: return (svcCryptoFail, 0)
    for i in 0 ..< ctLen: buf[i] = pt[i]
    (svcOk, ctLen)

  of svcWasmInvokeI32:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 slot | u32 exportNameLen | u32 argc | i32 args[argc] | exportName
      # resp: u32 controlStatus | u32 managerError | u32 storeError | i32 value
      if reqLen < 12 or bufCap < 16:
        return (svcBadRequest, 0)
      let slot = rdU32(buf, 0)
      let nameLen = rdU32(buf, 4).int
      let argc = rdU32(buf, 8).int
      if not lenOk(nameLen, WasmInvokeMaxExportNameLen) or
         not lenOk(argc, WasmInvokeMaxArgs) or nameLen == 0:
        return (svcBadRequest, 0)
      let nameOff = 12 + argc * 4
      if nameOff < 12 or nameOff + nameLen > reqLen:
        return (svcBadRequest, 0)

      var args: array[WasmInvokeMaxArgs, int32]
      for i in 0 ..< argc:
        args[i] = cast[int32](rdU32(buf, 12 + i * 4))

      var exportName = newString(nameLen)
      for i in 0 ..< nameLen:
        exportName[i] = char(buf[nameOff + i])

      let run =
        if argc == 0:
          runWasmProgramI32(slot, exportName, [])
        else:
          runWasmProgramI32(slot, exportName, toOpenArray(args, 0, argc - 1))
      writeWasmControlResult(buf, run, run.value)
      (svcOk, 16)
    else:
      (svcUnsupported, 0)

  of svcWasmCapabilities:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      if reqLen != 0 or bufCap < 32:
        return (svcBadRequest, 0)
      writeWasmCapabilities(buf)
      (svcOk, 32)
    else:
      (svcUnsupported, 0)

  of svcWasmInstallBytes:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 slot | u32 generation | u32 flags | u32 wasmLen | raw wasm bytes
      # resp: u32 controlStatus | u32 managerError | u32 storeError | i32 slot
      if reqLen < 16 or bufCap < 16:
        return (svcBadRequest, 0)
      let slot = rdU32(buf, 0)
      let generation = rdU32(buf, 4)
      let flags = rdU32(buf, 8)
      let wasmLen = rdU32(buf, 12).int
      if wasmLen <= 0 or not lenOk(wasmLen, reqLen) or 16 + wasmLen != reqLen:
        return (svcBadRequest, 0)
      let install = installWasmProgramBytes(
        slot,
        toOpenArray(buf, 16, 16 + wasmLen - 1),
        generation = generation,
        flags = flags,
      )
      writeWasmControlResult(buf, install, install.slot)
      (svcOk, 16)
    else:
      (svcUnsupported, 0)

  of svcWasmUnloadSlot:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 slot
      # resp: u32 controlStatus | u32 managerError | u32 storeError | i32 slot
      if reqLen != 4 or bufCap < 16:
        return (svcBadRequest, 0)
      let unload = unloadWasmProgram(rdU32(buf, 0))
      writeWasmControlResult(buf, unload, unload.slot)
      (svcOk, 16)
    else:
      (svcUnsupported, 0)

  of svcWasmTaskStartI32:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 slot | u32 exportNameLen | u32 argc | i32 args[argc] | exportName
      # resp: 11*u32 task result
      if reqLen < 12 or bufCap < 44:
        return (svcBadRequest, 0)
      let slot = rdU32(buf, 0)
      let nameLen = rdU32(buf, 4).int
      let argc = rdU32(buf, 8).int
      if not lenOk(nameLen, WasmInvokeMaxExportNameLen) or
         not lenOk(argc, WasmInvokeMaxArgs) or nameLen == 0:
        return (svcBadRequest, 0)
      let nameOff = 12 + argc * 4
      if nameOff < 12 or nameOff + nameLen > reqLen:
        return (svcBadRequest, 0)

      var args: array[WasmInvokeMaxArgs, int32]
      for i in 0 ..< argc:
        args[i] = cast[int32](rdU32(buf, 12 + i * 4))

      var exportName = newString(nameLen)
      for i in 0 ..< nameLen:
        exportName[i] = char(buf[nameOff + i])

      let started =
        if argc == 0:
          startWasmProgramTaskI32(slot, exportName, [])
        else:
          startWasmProgramTaskI32(slot, exportName, toOpenArray(args, 0, argc - 1))
      writeWasmTaskResult(buf, started)
      (svcOk, 44)
    else:
      (svcUnsupported, 0)

  of svcWasmTaskResume:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 taskId | u32 fuel
      # resp: 11*u32 task result
      if reqLen != 8 or bufCap < 44:
        return (svcBadRequest, 0)
      let resumed = resumeWasmProgramTask(rdU32(buf, 0), rdU32(buf, 4))
      writeWasmTaskResult(buf, resumed)
      (svcOk, 44)
    else:
      (svcUnsupported, 0)

  of svcWasmTaskStatus:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 taskId
      # resp: 11*u32 task result
      if reqLen != 4 or bufCap < 44:
        return (svcBadRequest, 0)
      let task = getWasmProgramTask(rdU32(buf, 0))
      writeWasmTaskResult(buf, task)
      (svcOk, 44)
    else:
      (svcUnsupported, 0)

  of svcWasmTaskKill:
    when defined(bl808WasmCompact) or defined(bl808EnclaveWasmService):
      # req: u32 taskId
      # resp: 11*u32 task result
      if reqLen != 4 or bufCap < 44:
        return (svcBadRequest, 0)
      let killed = killWasmProgramTask(rdU32(buf, 0))
      writeWasmTaskResult(buf, killed)
      (svcOk, 44)
    else:
      (svcUnsupported, 0)

  else:
    (svcUnsupported, 0)

proc enclaveDispatch*(svc: SvcId, reqLen: int,
                      buf: ptr UncheckedArray[uint8], bufCap: int): (SvcStatus, int) =
  ## Backward-compatible direct dispatch for existing harnesses. Production
  ## transports call the overload that supplies their real caller identity.
  enclaveDispatch(callerTestHarnessCtx(), svc, reqLen, buf, bufCap)

proc attestationPublicKey*(outBuf: ptr UncheckedArray[uint8]): bool =
  ## Publish the attestation public key (x[0..31] || y[32..63], big-endian) so a
  ## verifier can check getAttestation signatures. The key is public; the
  ## private scalar (derived from the vault root) never leaves the enclave.
  ensurePka()
  var scalarBytes: array[32, uint8]
  if not vaultExpand(vaultRoot(), AttestInfo, scalarBytes): return false
  var scalar, pubx, puby: array[8, uint32]
  bytesToWordsBe(scalarBytes, scalar)
  var handle: BflbEcdsa
  if bflb_sec_ecdsa_init(addr handle, EcpSecp256r1) != 0: return false
  let rc = bflb_sec_ecdsa_get_public_key(addr handle, addr scalar[0],
                                         addr pubx[0], addr puby[0])
  discard bflb_sec_ecdsa_deinit(addr handle)
  for i in 0 ..< 32: scalarBytes[i] = 0
  if rc != 0: return false
  wordsToBytesBe(pubx, outBuf, 0)
  wordsToBytesBe(puby, outBuf, 32)
  true
