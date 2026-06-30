## Measured hibernation resume.
##
## On a normal cold boot the enclave DEFANGS the BootROM warm-boot fast path
## (`pds.hbnClearWarmBootMagic`) because an unmeasured fast-path jump skips the
## secure stage (verify / measure / TZC lock). This module is the trusted
## alternative: the enclave can arm the fast path to jump into its OWN measured
## resume. Before sleep it MACs a resume descriptor (resume entry, app resume PC,
## boot measurement, fresh nonce) with a key derived from the vault root and
## stores it in HBN retention RAM. On wake the secure resume path re-establishes
## the locked posture, re-derives the key, and resumes the app ONLY if the
## descriptor's MAC verifies — otherwise it wipes keys and refuses.
##
## The MAC key derives from the vault root, so a measured resume is sound only
## when the root is REPRODUCIBLE across sleep/wake without storing any secret:
## `rkPufDerived` (the SRAM-PUF root, reconstructed on wake — see reconstruct.nim)
## or `rkEfuseHwKey`. `rkSoftDev` reseeds per boot from the TRNG, so its tag will
## not validate across a real sleep unless the seed is persisted; use it only for
## logic tests within a single boot.

import std/volatile
import ../mmio, ../memmap, ../pds, ../core
import sha256, measure, vault, ../sec

const
  HbnResumeMagic* = 0x52455348'u32       ## "HSER" — HBN Secure rEsume marker
  HbnResumeVersion* = 1'u32
  HbnResumeSlot* = HbnRamBase + 0x800'u  ## 0x20010800, clear of ClkCfg @+0xE00
  ResumeKeyInfo = ['h'.byte, 'b'.byte, 'n'.byte, '-'.byte, 'r'.byte, 'e'.byte,
                   's'.byte, 'u'.byte, 'm'.byte, 'e'.byte, '-'.byte, 'v'.byte,
                   '1'.byte]
  ResumeMsgLen = 4 + 4 + 4 + 4 + 16 + 32 ## magic|ver|entry|pc|nonce|bootMeas = 64

type
  HbnResumeDescriptor* = object
    magic*: uint32
    version*: uint32
    resumeEntry*: uint32     ## trusted secure resume stub the BootROM jumps to
    appResumePc*: uint32     ## where to resume the U-mode app after re-lock
    nonce*: array[16, uint8]
    bootMeas*: array[32, uint8]
    tag*: array[32, uint8]   ## HMAC-SHA256 over the fields above

# --- pure MAC core (sha256-only; reproducible on host) ----------------------

proc putU32(buf: var array[ResumeMsgLen, uint8], off: int, v: uint32) {.inline.} =
  buf[off + 0] = uint8(v and 0xFF)
  buf[off + 1] = uint8((v shr 8) and 0xFF)
  buf[off + 2] = uint8((v shr 16) and 0xFF)
  buf[off + 3] = uint8((v shr 24) and 0xFF)

proc hbnResumeMessage*(d: HbnResumeDescriptor): array[ResumeMsgLen, uint8] =
  ## Canonical, padding-free serialization of the MAC'd fields (tag excluded).
  putU32(result, 0, d.magic)
  putU32(result, 4, d.version)
  putU32(result, 8, d.resumeEntry)
  putU32(result, 12, d.appResumePc)
  for i in 0 ..< 16: result[16 + i] = d.nonce[i]
  for i in 0 ..< 32: result[32 + i] = d.bootMeas[i]

proc hbnResumeTag*(key: openArray[uint8], d: HbnResumeDescriptor): Sha256Digest =
  ## The resume MAC = HMAC-SHA256(key, message(d)).
  hmacSha256(key, hbnResumeMessage(d))

proc ctEqual*(a, b: openArray[uint8]): bool =
  ## Constant-time equality so a tampered tag can't be probed byte-by-byte.
  if a.len != b.len: return false
  var diff = 0'u8
  for i in 0 ..< a.len: diff = diff or (a[i] xor b[i])
  diff == 0

proc wipeKey(p: var array[32, uint8]) =
  ## Zero a transient key with a barrier the optimiser cannot drop.
  for i in 0 ..< p.len: volatileStore(addr p[i], 0'u8)
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}

# --- device arm / validate --------------------------------------------------

proc deriveResumeKey(key: var array[32, uint8]): bool =
  ## Derive the resume MAC key from the (reproducible) vault root.
  vaultExpand(vaultRoot(), ResumeKeyInfo, key)

proc resumeSlot(): ptr HbnResumeDescriptor {.inline.} =
  cast[ptr HbnResumeDescriptor](HbnResumeSlot)

proc enclaveArmHbnResume*(resumeEntry, appResumePc: uint32): bool =
  ## Before HBN sleep: build a MAC'd resume descriptor in HBN retention RAM and
  ## arm the BootROM warm-boot fast path to jump to `resumeEntry` on wake.
  ## Returns false if no reproducible root/key is available (caller must then
  ## fall back to a full cold boot rather than an unmeasured resume).
  var key: array[32, uint8]
  if not deriveResumeKey(key):
    return false
  var d: HbnResumeDescriptor
  d.magic = HbnResumeMagic
  d.version = HbnResumeVersion
  d.resumeEntry = resumeEntry
  d.appResumePc = appResumePc
  if trngFillBuffer(d.nonce) != secOk:
    wipeKey(key)
    return false
  d.bootMeas = measureImage()
  d.tag = hbnResumeTag(key, d)
  wipeKey(key)
  resumeSlot()[] = d
  fenceIo()
  # Arm the fast path: HbnRsv0 magic + HbnRsv1 = trusted resume entry.
  regWrite(HbnRsv1, resumeEntry)
  regWrite(HbnRsv0, HbnWarmBootMagicEhbn)
  fenceIo()
  true

proc enclaveHbnResumeArmed*(): bool =
  ## True iff a valid-looking resume descriptor is present and the fast path is
  ## armed (does NOT verify the MAC — that is enclaveValidateHbnResume's job).
  hbnWarmBootMagicArmed() and resumeSlot().magic == HbnResumeMagic and
    resumeSlot().version == HbnResumeVersion

proc enclaveClearHbnResume*()

proc enclaveValidateHbnResume*(appResumePc: var uint32): bool =
  ## On wake (after re-deriving the vault root and re-applying the partition):
  ## recompute the descriptor MAC and accept the resume ONLY if it matches. On
  ## success `appResumePc` is the verified PC to resume the app at.
  if not enclaveHbnResumeArmed():
    return false
  var key: array[32, uint8]
  if not deriveResumeKey(key):
    enclaveClearHbnResume()
    return false
  let d = resumeSlot()[]
  let expect = hbnResumeTag(key, d)
  wipeKey(key)
  if not ctEqual(expect, d.tag) or d.bootMeas != measureImage() or
     regRead(HbnRsv1) != d.resumeEntry:
    enclaveClearHbnResume()
    return false
  appResumePc = d.appResumePc
  enclaveClearHbnResume()
  true

proc enclaveClearHbnResume*() =
  ## Invalidate any stored resume descriptor and disarm the fast path.
  let d = resumeSlot()
  for i in 0 ..< sizeof(HbnResumeDescriptor) div 4:
    volatileStore(cast[ptr uint32](cast[uint](d) + i.uint * 4), 0'u32)
  hbnClearWarmBootMagic()
  fenceIo()
