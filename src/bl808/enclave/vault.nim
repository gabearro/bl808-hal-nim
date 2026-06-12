## Enclave key vault.
##
## Holds key material in secure OCRAM (the .bss of an enclave build lands in
## the group-0 / PMP-protected window). Keys are referenced by opaque handles;
## raw bytes never leave the vault. Derivation is HKDF-SHA256; the root key can
## come from a dev seed, an eFuse hardware slot (bytes never read), or a future
## PUF source.

import std/volatile
import sha256
import ../sec
import cruntime  # freestanding mem* for bare-metal struct/array copies

type
  KeyHandle* = distinct uint32

  KeyUsage* = enum
    kuEncrypt, kuDecrypt, kuSign, kuDerive, kuWrap
  KeyUsages* = set[KeyUsage]

  KeyPolicy* = object
    usage*: KeyUsages
    exportable*: bool   ## always false for derived/root material

  RootKeySource* = enum
    rkSoftDev      ## developer seed (NOT for production)
    rkEfuseHwKey   ## eFuse slot; bytes never read by software
    rkPufDerived   ## SRAM-PUF derived (filled by the PUF module)

  KeyMaterial = object
    bytes: array[32, uint8]
    len: int
    policy: KeyPolicy
    source: RootKeySource
    efuseSlot: AesKeySource
    inUse: bool

const
  MaxKeys* = 16
  InvalidHandle* = KeyHandle(0)

var
  keyTable: array[MaxKeys, KeyMaterial]   # secure OCRAM (.bss)
  rootHandle: KeyHandle = InvalidHandle

proc `==`*(a, b: KeyHandle): bool {.borrow.}

proc volatileWipe(p: var array[32, uint8]) =
  ## Zero key bytes with a barrier the optimiser cannot drop.
  for i in 0 ..< p.len:
    volatileStore(addr p[i], 0'u8)
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}

proc allocSlot(): int =
  for i in 0 ..< MaxKeys:
    if not keyTable[i].inUse:
      return i
  -1

proc handleToIndex(h: KeyHandle): int {.inline.} =
  let v = h.uint32
  if v == 0 or v.int > MaxKeys: -1 else: v.int - 1

proc vaultZeroize*(h: KeyHandle) =
  let idx = handleToIndex(h)
  if idx < 0: return
  volatileWipe(keyTable[idx].bytes)
  keyTable[idx].len = 0
  keyTable[idx].inUse = false

proc vaultZeroizeAll*() =
  ## Wipe every key (call on fault / shutdown).
  for i in 0 ..< MaxKeys:
    volatileWipe(keyTable[i].bytes)
    keyTable[i].len = 0
    keyTable[i].inUse = false
  rootHandle = InvalidHandle

proc storeKey(bytes: openArray[uint8], policy: KeyPolicy,
              source: RootKeySource): KeyHandle =
  let idx = allocSlot()
  if idx < 0: return InvalidHandle
  let n = min(bytes.len, 32)
  for i in 0 ..< n: keyTable[idx].bytes[i] = bytes[i]
  keyTable[idx].len = n
  keyTable[idx].policy = policy
  keyTable[idx].source = source
  keyTable[idx].inUse = true
  KeyHandle((idx + 1).uint32)

proc vaultImportSoftRoot*(seed: openArray[uint8]): KeyHandle =
  ## Dev-only: import a software root key from a seed. Marked non-exportable,
  ## derive-only.
  result = storeKey(seed, KeyPolicy(usage: {kuDerive}, exportable: false), rkSoftDev)
  rootHandle = result

proc vaultSetEfuseRoot*(slot: AesKeySource): KeyHandle =
  ## Register an eFuse hardware-key root. No bytes are stored; the slot is used
  ## directly by the AES engine via aesSetKeySource.
  let idx = allocSlot()
  if idx < 0: return InvalidHandle
  keyTable[idx].len = 0
  keyTable[idx].policy = KeyPolicy(usage: {kuEncrypt, kuDecrypt, kuDerive}, exportable: false)
  keyTable[idx].source = rkEfuseHwKey
  keyTable[idx].efuseSlot = slot
  keyTable[idx].inUse = true
  rootHandle = KeyHandle((idx + 1).uint32)
  rootHandle

proc vaultRoot*(): KeyHandle = rootHandle

proc vaultTableAddr*(): uint = cast[uint](addr keyTable)
proc vaultTableSize*(): int = sizeof(keyTable)
  ## Span of the key store in secure RAM — for a coverage audit that the secret
  ## material physically lands inside the locked group-0 window.

proc vaultInit*(src: RootKeySource): bool =
  ## Reset the vault. For rkSoftDev a random root is seeded from the TRNG so an
  ## un-provisioned dev build still has a unique root per boot.
  vaultZeroizeAll()
  case src
  of rkSoftDev:
    var seed: array[32, uint8]
    if trngFillBuffer(seed) != secOk:
      return false
    rootHandle = vaultImportSoftRoot(seed)
    volatileWipe(seed)
    rootHandle != InvalidHandle
  of rkEfuseHwKey:
    vaultSetEfuseRoot(aesKeyEfuse0) != InvalidHandle
  of rkPufDerived:
    false   # PUF root is installed separately by the PUF module

proc vaultInstallPufRoot*(rootBytes: array[32, uint8]): KeyHandle =
  ## Install a PUF-reconstructed 32-byte root (called by the PUF module).
  result = storeKey(rootBytes, KeyPolicy(usage: {kuDerive}, exportable: false),
                    rkPufDerived)
  rootHandle = result

proc vaultDeriveKey*(parent: KeyHandle, label, context: openArray[uint8],
                     outLen: int, policy: KeyPolicy): KeyHandle =
  ## HKDF-SHA256 derive a child key. The parent must be a soft/PUF key whose
  ## bytes are present (eFuse-only roots derive via the AES KDF path instead).
  let idx = handleToIndex(parent)
  if idx < 0 or not keyTable[idx].inUse or keyTable[idx].len == 0:
    return InvalidHandle
  if outLen <= 0 or outLen > 32:
    return InvalidHandle
  var okm: array[32, uint8]
  let prk = hkdfExtract(label, toOpenArray(keyTable[idx].bytes, 0, keyTable[idx].len - 1))
  hkdfExpand(prk, context, outLen, okm)
  result = storeKey(toOpenArray(okm, 0, outLen - 1), policy, keyTable[idx].source)
  volatileWipe(okm)

proc vaultUseForAes*(h: KeyHandle): bool =
  ## Load a key into the AES engine: soft/PUF keys go into the key registers;
  ## eFuse-root keys select the hardware slot (bytes stay invisible).
  let idx = handleToIndex(h)
  if idx < 0 or not keyTable[idx].inUse: return false
  if keyTable[idx].source == rkEfuseHwKey:
    aesSetKeySource(keyTable[idx].efuseSlot)
    return true
  aesSetKeySource(aesKeySoft)
  var words: array[8, uint32]
  let n = keyTable[idx].len
  for w in 0 ..< (n + 3) div 4:
    var v = 0'u32
    for b in 0 ..< 4:
      let bi = w * 4 + b
      if bi < n:
        v = v or (keyTable[idx].bytes[bi].uint32 shl (24 - b * 8))
    words[w] = v
  aesSetKey(words)
  for i in 0 ..< 8: words[i] = 0
  true

proc vaultExpand*(h: KeyHandle, info: openArray[uint8],
                  output: var openArray[uint8]): bool =
  ## HKDF-Expand a vault key into purpose-separated material for in-enclave use
  ## (e.g. an AEAD key or an ECDSA scalar). Trusted callers only; the bytes
  ## never cross the enclave boundary.
  let idx = handleToIndex(h)
  if idx < 0 or not keyTable[idx].inUse or keyTable[idx].len == 0: return false
  if output.len > 255 * 32: return false
  let prk = hkdfExtract([], toOpenArray(keyTable[idx].bytes, 0, keyTable[idx].len - 1))
  hkdfExpand(prk, info, output.len, output)
  true

proc vaultKeyDigest*(h: KeyHandle, dig: var Sha256Digest): bool =
  ## Public, non-secret identifier for a key: SHA-256 of its bytes. Lets callers
  ## reference a key without exposing it (e.g. for attestation).
  let idx = handleToIndex(h)
  if idx < 0 or not keyTable[idx].inUse or keyTable[idx].len == 0: return false
  dig = sha256(toOpenArray(keyTable[idx].bytes, 0, keyTable[idx].len - 1))
  true
