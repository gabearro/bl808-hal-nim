## Authenticated encryption for the enclave: AES-128-CTR + HMAC-SHA256
## (encrypt-then-MAC). Entirely software (reusing the BLE software AES block and
## the enclave SHA-256), so it has no DMA/cache coupling and is bit-for-bit
## reproducible on the host for known-answer testing.
##
## A single 48-byte key is split into a 16-byte AES key and a 32-byte MAC key,
## so callers derive one vault key per AEAD context.

import sha256
import ../blecrypto   # bleAesEncryptBlock (software AES-128)
import cruntime

type
  AeadKey* = object
    enc*: array[16, uint8]   ## AES-128 key
    mac*: array[32, uint8]   ## HMAC-SHA256 key
  AeadTag* = array[32, uint8]

proc ctrCrypt*(key: array[16, uint8], nonce: array[16, uint8],
               data: var openArray[uint8]) =
  ## AES-128-CTR in place (encrypt == decrypt). The 128-bit counter starts at
  ## `nonce` and increments big-endian. Exported so the secure-boot verifier can
  ## decrypt an AES-CTR-encrypted NSB1 payload before the plaintext-hash check.
  var counter = nonce
  var ks: array[16, uint8]
  var i = 0
  var kcopy = key
  while i < data.len:
    bleAesEncryptBlock(addr kcopy[0], addr counter[0], addr ks[0])
    let n = min(16, data.len - i)
    for j in 0 ..< n:
      data[i + j] = data[i + j] xor ks[j]
    var c = 15
    while c >= 0:
      counter[c] = counter[c] + 1
      if counter[c] != 0: break
      dec c
    i += 16

proc le32(n: int): array[4, uint8] {.inline.} =
  let v = n.uint32
  [ (v and 0xFF).uint8, ((v shr 8) and 0xFF).uint8,
    ((v shr 16) and 0xFF).uint8, ((v shr 24) and 0xFF).uint8 ]

proc macTag(key: AeadKey, nonce: array[16, uint8],
            aad, ct: openArray[uint8]): AeadTag =
  ## HMAC-SHA256 over nonce || aadLen || aad || ctLen || ct (length-prefixed so
  ## the aad/ciphertext boundary is unambiguous). Allocation-free incremental
  ## HMAC: the 32-byte MAC key zero-pads to the 64-byte block.
  var ipad, opad: array[64, uint8]
  for i in 0 ..< 64:
    let kb = if i < 32: key.mac[i] else: 0'u8
    ipad[i] = kb xor 0x36'u8
    opad[i] = kb xor 0x5c'u8
  var inner: Sha256Ctx
  sha256Init(inner)
  sha256Update(inner, ipad)
  sha256Update(inner, nonce)
  sha256Update(inner, le32(aad.len)); sha256Update(inner, aad)
  sha256Update(inner, le32(ct.len)); sha256Update(inner, ct)
  let innerDig = sha256Final(inner)
  var outer: Sha256Ctx
  sha256Init(outer)
  sha256Update(outer, opad)
  sha256Update(outer, innerDig)
  AeadTag(sha256Final(outer))

proc aeadSeal*(key: AeadKey, nonce: array[16, uint8],
               aad, plaintext: openArray[uint8],
               ciphertext: var openArray[uint8], tag: var AeadTag): bool =
  ## Encrypt-then-MAC. `ciphertext` must be at least plaintext.len bytes.
  if ciphertext.len < plaintext.len: return false
  for i in 0 ..< plaintext.len: ciphertext[i] = plaintext[i]
  if plaintext.len > 0:
    ctrCrypt(key.enc, nonce, toOpenArray(ciphertext, 0, plaintext.len - 1))
    tag = macTag(key, nonce, aad, toOpenArray(ciphertext, 0, plaintext.len - 1))
  else:
    tag = macTag(key, nonce, aad, [])
  true

proc ctEq(a, b: openArray[uint8]): bool =
  ## Constant-time compare.
  if a.len != b.len: return false
  var diff = 0'u8
  for i in 0 ..< a.len: diff = diff or (a[i] xor b[i])
  diff == 0

proc aeadOpen*(key: AeadKey, nonce: array[16, uint8],
               aad, ciphertext: openArray[uint8], tag: AeadTag,
               plaintext: var openArray[uint8]): bool =
  ## Verify the tag (constant-time), then decrypt. Returns false and writes
  ## nothing if authentication fails.
  if plaintext.len < ciphertext.len: return false
  let expect = macTag(key, nonce, aad, ciphertext)
  if not ctEq(expect, tag): return false
  for i in 0 ..< ciphertext.len: plaintext[i] = ciphertext[i]
  if ciphertext.len > 0:
    ctrCrypt(key.enc, nonce, toOpenArray(plaintext, 0, ciphertext.len - 1))
  true
