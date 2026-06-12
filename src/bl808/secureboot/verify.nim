## Device-side NSB1 verification: parse the container, confirm the payload
## SHA-256 matches the header, and verify the ECDSA-P256 signature over the
## header's signed region against a trusted public key.
##
## The trusted key is supplied by the caller — in production it is the key
## whose SHA-256 is burned in eFuse; in soft mode it is embedded in the secure
## stage. SHA-256 uses the pure software implementation (no DMA); ECDSA uses the
## PKA via pka.nim.

import container
import ../enclave/sha256
import ../enclave/aead   # ctrCrypt (AES-128-CTR) for encrypted-image decryption
import ../pka
import ../memmap

var pkaReady = false
proc ensurePka() =
  if not pkaReady:
    var dev = BflbDevice(name: nil, regBase: SecEngBase.uint32)
    bflb_pka_init(addr dev)
    pkaReady = true

type
  VerifyResult* = enum
    vrOk, vrBadContainer, vrBadHash, vrBadSignature, vrKeyMismatch

proc bytesToWordsBe(src: openArray[uint8], off: int, dst: var array[8, uint32]) =
  ## Convert a 32-byte big-endian value to PKA words: word order is big-endian
  ## (word[0] = most-significant), but bytes WITHIN each word are little-endian
  ## (the BL808 PKA's native layout — see secp256r1Gx in pka.nim).
  for w in 0 ..< 8:
    dst[w] = src[off+w*4].uint32 or (src[off+w*4+1].uint32 shl 8) or
             (src[off+w*4+2].uint32 shl 16) or (src[off+w*4+3].uint32 shl 24)

proc ecdsaVerify(pubx, puby, hash, r, s: array[8, uint32]): bool =
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

proc verifyNsb1*(raw: openArray[uint8], pubx, puby: array[8, uint32],
                 hdr: var Nsb1Header): VerifyResult =
  ## Verify an NSB1 image (plaintext payload path). Returns vrOk and fills hdr
  ## on success. Encrypted images must be decrypted by the caller before the
  ## payload-hash check (the hash is over plaintext).
  if parseNsb1(raw, hdr) != nsbOk:
    return vrBadContainer
  # Overflow-safe bound: Nsb1HeaderSize + payloadLen must fit in the buffer.
  # Doing this in uint32 wraps for payloadLen near 0xFFFFFFFF and would let the
  # payload-hash read run off the end; compare in uint64 against the real length.
  if Nsb1HeaderSize.uint64 + hdr.payloadLen.uint64 > raw.len.uint64:
    return vrBadContainer

  # 1. payload hash (plaintext payloads only here)
  if not isEncrypted(hdr):
    let payloadDigest = sha256(toOpenArray(raw, Nsb1HeaderSize,
                                           Nsb1HeaderSize + hdr.payloadLen.int - 1))
    for i in 0 ..< 32:
      if payloadDigest[i] != hdr.payloadHash[i]:
        return vrBadHash

  # 2. signature over header[0..159]
  let signedDigest = sha256(toOpenArray(raw, 0, Nsb1SignedLen - 1))
  var hashW, r, s: array[8, uint32]
  bytesToWordsBe(signedDigest, 0, hashW)
  bytesToWordsBe(hdr.signature, 0, r)
  bytesToWordsBe(hdr.signature, 32, s)
  if not ecdsaVerify(pubx, puby, hashW, r, s):
    return vrBadSignature
  vrOk

proc verifyNsb1Encrypted*(raw: openArray[uint8], pubx, puby: array[8, uint32],
                          aesKey: array[16, uint8], hdr: var Nsb1Header,
                          plaintext: var openArray[uint8]): VerifyResult =
  ## Verify an AES-CTR-encrypted NSB1 image: confirm the ECDSA signature over the
  ## header, decrypt the payload (aesKey + header nonce) into `plaintext`, then
  ## confirm the plaintext SHA-256 matches the header's payloadHash. A wrong key
  ## decrypts to garbage and is caught by the hash check (vrBadHash). `plaintext`
  ## must be at least payloadLen bytes. The signing key authenticates the header
  ## (which commits to the plaintext hash), so this is encrypt-then-sign.
  if parseNsb1(raw, hdr) != nsbOk:
    return vrBadContainer
  if not isEncrypted(hdr):
    return vrBadContainer
  if Nsb1HeaderSize.uint64 + hdr.payloadLen.uint64 > raw.len.uint64:
    return vrBadContainer
  if plaintext.len.uint64 < hdr.payloadLen.uint64:
    return vrBadContainer

  # 1. signature over header[0..159]
  let signedDigest = sha256(toOpenArray(raw, 0, Nsb1SignedLen - 1))
  var hashW, r, s: array[8, uint32]
  bytesToWordsBe(signedDigest, 0, hashW)
  bytesToWordsBe(hdr.signature, 0, r)
  bytesToWordsBe(hdr.signature, 32, s)
  if not ecdsaVerify(pubx, puby, hashW, r, s):
    return vrBadSignature

  # 2. decrypt payload, then check the plaintext hash matches the header.
  let pl = hdr.payloadLen.int
  for i in 0 ..< pl:
    plaintext[i] = raw[Nsb1HeaderSize + i]
  ctrCrypt(aesKey, hdr.nonce, toOpenArray(plaintext, 0, pl - 1))
  let dig = sha256(toOpenArray(plaintext, 0, pl - 1))
  for i in 0 ..< 32:
    if dig[i] != hdr.payloadHash[i]:
      return vrBadHash
  vrOk

proc measurement*(hdr: Nsb1Header): array[32, uint8] =
  ## The image's identity for attestation: its plaintext payload hash.
  hdr.payloadHash
