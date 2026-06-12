## BL808 Security Engine driver.
##
## SEC_ENG at 0x20004000 provides:
##   - AES: 128/192/256-bit encryption/decryption (ECB, CBC, CTR, XTS)
##   - SHA: SHA-256, SHA-224, SHA-1 hashing
##   - TRNG: True Random Number Generator
##   - PKA: Public Key Accelerator (RSA, ECC)

import mmio, memmap

# =============================================================================
# Security engine register base offsets
# =============================================================================
const
  SecBase*          = SecEngBase  # 0x20004000

  # SHA registers
  ShaCfg*           = SecBase + 0x000'u  # SHA configuration/control
  ShaSrcAddr*       = SecBase + 0x004'u  # Source data address
  ShaStatus*        = SecBase + 0x008'u  # SHA status
  ShaEndian*        = SecBase + 0x00C'u  # SHA endian config
  ShaHash0*         = SecBase + 0x010'u  # Hash output low word 0 (8 words)
  ShaHashHigh0*     = SecBase + 0x030'u  # Hash output high word 0 (SHA-384/512)
  ShaLink*          = SecBase + 0x050'u  # SHA link mode config
  ShaCtrlProt*      = SecBase + 0x0FC'u  # SHA access protection

  # AES registers
  AesCfg*           = SecBase + 0x100'u  # AES configuration/control
  AesSrcAddr*       = SecBase + 0x104'u  # Source data address
  AesDstAddr*       = SecBase + 0x108'u  # Destination data address
  AesStatus*        = SecBase + 0x10C'u  # AES status
  AesIv0*           = SecBase + 0x110'u  # AES IV word 0 (4 words, 0x110-0x11C)
  AesKey0*          = SecBase + 0x120'u  # AES key word 0 (8 words, 0x120-0x13C)
  AesKeySel0*       = SecBase + 0x140'u  # Hardware key select 0
  AesKeySel1*       = SecBase + 0x144'u  # Hardware key select 1
  AesEndian*        = SecBase + 0x148'u  # Endian config
  AesSboot*         = SecBase + 0x14C'u  # Secure boot / XTS config
  AesLinkCfg*       = SecBase + 0x150'u  # Link mode config
  AesCtrlProt*      = SecBase + 0x1FC'u  # AES access protection

  # TRNG registers
  TrngCtrl0*        = SecBase + 0x200'u  # TRNG control 0
  TrngStatus*       = SecBase + 0x204'u  # TRNG status
  TrngData0*        = SecBase + 0x208'u  # TRNG output word 0
  TrngData1*        = SecBase + 0x20C'u  # TRNG output word 1
  TrngData2*        = SecBase + 0x210'u  # TRNG output word 2
  TrngData3*        = SecBase + 0x214'u  # TRNG output word 3
  TrngData4*        = SecBase + 0x218'u  # TRNG output word 4
  TrngData5*        = SecBase + 0x21C'u  # TRNG output word 5
  TrngData6*        = SecBase + 0x220'u  # TRNG output word 6
  TrngData7*        = SecBase + 0x224'u  # TRNG output word 7
  TrngTest*         = SecBase + 0x228'u  # TRNG test control
  TrngCtrl1*        = SecBase + 0x22C'u  # TRNG reseed low
  TrngCtrl2*        = SecBase + 0x230'u  # TRNG reseed high
  TrngCtrl3*        = SecBase + 0x234'u  # TRNG health-test control
  TrngCtrlProt*     = SecBase + 0x2FC'u  # TRNG access protection
  SecCtrlProtRead*  = SecBase + 0xF00'u  # Security engine group ownership

  # PKA registers. Status, interrupt, and mask bits are fields in CTRL_0.
  PkaCtrl0*         = SecBase + 0x300'u  # PKA control/status
  PkaRw*            = SecBase + 0x340'u  # PKA command/data FIFO
  PkaRwBurst*       = SecBase + 0x360'u  # PKA burst data FIFO
  PkaStatus*        = PkaCtrl0           # Compatibility alias
  PkaIntSts*        = PkaCtrl0           # Compatibility alias
  PkaIntMask*       = PkaCtrl0           # Compatibility alias

# =============================================================================
# AES configuration fields
# =============================================================================
const
  AesCfgTrigger*   = 1        # Start operation (write 1 pulse)
  AesCfgEn*        = 2        # AES enable
  AesCfgKeySizeShift* = 3     # Key size/mode [4:3]
  AesCfgKeySizeMask*  = 0x03'u32 shl 3
  AesCfgModeShift* = 12       # Block mode [13:12]: 0=ECB, 1=CTR, 2=CBC, 3=XTS
  AesCfgModeMask*  = 0x03'u32 shl 12
  AesCfgDecEn*     = 5        # Decrypt mode (0=encrypt, 1=decrypt)
  AesCfgHwKeyEn*   = 7        # Use eFuse-backed hardware key
  AesCfgIntDone*   = 8        # Done interrupt flag
  AesCfgIntClear*  = 9        # Clear done interrupt (write 1 pulse)
  AesCfgIntMask*   = 11       # Done interrupt mask
  AesCfgIvSel*     = 14       # IV source select
  AesCfgLinkMode*  = 15       # Descriptor link mode
  AesCfgMsgLenShift* = 16     # Message length in 16-byte blocks
  AesCfgMsgLenMask*  = 0xFFFF'u32 shl 16
  AesCfgBusy*      = 0        # Busy (in status register)

# =============================================================================
# SHA configuration fields
# =============================================================================
const
  ShaCfgTrigger*   = 1        # Start operation (write 1 pulse)
  ShaCfgModeShift* = 2        # SHA/CRC mode [4:2]
  ShaCfgModeMask*  = 0x07'u32 shl 2
  ShaCfgEn*        = 5        # SHA enable
  ShaCfgHashSel*   = 6        # Accumulate from existing hash
  ShaCfgIntDone*   = 8        # Done interrupt flag
  ShaCfgIntClear*  = 9        # Clear done interrupt (write 1 pulse)
  ShaCfgIntMask*   = 11       # Done interrupt mask
  ShaCfgModeExtShift* = 12    # Extended mode [13:12]
  ShaCfgModeExtMask*  = 0x03'u32 shl 12
  ShaCfgLinkMode*  = 15       # Descriptor link mode
  ShaCfgMsgLenShift* = 16     # Message length in blocks
  ShaCfgMsgLenMask*  = 0xFFFF'u32 shl 16
  ShaCfgBusy*      = 0        # Busy (in status register)

# =============================================================================
# TRNG control fields
# =============================================================================
const
  TrngBusy*        = 0        # Busy
  TrngTrigger*     = 1        # Start operation (write 1 pulse)
  TrngEn*          = 2        # TRNG enable
  TrngDoutClear*   = 3        # Clear output data (write 1 pulse)
  TrngHealthError* = 4        # Health-test error
  TrngIntDone*     = 8        # Done interrupt flag
  TrngIntClear*    = 9        # Clear done interrupt (write 1 pulse)
  TrngIntMask*     = 11       # Done interrupt mask
  TrngReady*       = 0        # Data ready (in status register)
  TrngRoscEn*      = 31       # Ring oscillator entropy source enable
  TrngOwnerShift*  = 4
  TrngOwnerMask*   = 0x03'u32
  TrngOwnerGroup0* = 0x01'u32
  TrngOwnerFree*   = 0x03'u32
  TrngRequestGroup0* = 0x02'u32
  TrngReleaseAccess* = 0x06'u32

# =============================================================================
# Types
# =============================================================================
type
  AesMode* = enum
    aesEcb = 0
    aesCtr = 1
    aesCbc = 2
    aesXts = 3

  AesKeySize* = enum
    aes128 = 0
    aes192 = 1
    aes256 = 2

  ShaMode* = enum
    sha256 = 0
    sha224 = 1
    sha1   = 2

  SecError* = enum
    secOk
    secBusy
    secTimeout

# =============================================================================
# AES operations
# =============================================================================
proc aesSetKey*(key: openArray[uint32]) =
  ## Load AES key (4 words for 128-bit, 6 for 192, 8 for 256).
  for i in 0 ..< min(key.len, 8):
    regWrite(AesKey0 + i.uint * 4, key[i])

proc aesSetIv*(iv: array[4, uint32]) =
  ## Load AES IV/nonce (4 words = 128 bits).
  for i in 0 ..< 4:
    regWrite(AesIv0 + i.uint * 4, iv[i])

proc aesKeyMode(keySize: AesKeySize): uint32 {.inline.} =
  ## BL808 SEC_ENG encodes AES-256 as mode 1 and AES-192 as mode 2.
  case keySize
  of aes128: 0'u32
  of aes192: 2'u32
  of aes256: 1'u32

proc aesBlocks(length: uint32): uint32 {.inline.} =
  if length == 0: 0'u32 else: (length + 15'u32) div 16'u32

proc aesEncryptBlock*(src, dst: uint32, length: uint32,
                      mode: AesMode, keySize: AesKeySize): SecError =
  ## Encrypt data using AES. `src` and `dst` are memory addresses.
  ## `length` is in bytes (must be multiple of 16 for ECB/CBC).

  # Wait for any previous operation
  var timeout = 100_000'u32
  while (regRead(AesCfg) and (1'u32 shl AesCfgBusy)) != 0:
    timeout.dec
    if timeout == 0: return secBusy

  # Set addresses before triggering the engine.
  regWrite(AesSrcAddr, src)
  regWrite(AesDstAddr, dst)

  var cfg = (1'u32 shl AesCfgEn)
  cfg = cfg or (mode.uint32 shl AesCfgModeShift)
  cfg = cfg or (aesKeyMode(keySize) shl AesCfgKeySizeShift)
  cfg = cfg or ((aesBlocks(length) shl AesCfgMsgLenShift) and AesCfgMsgLenMask)
  # Preserve a hardware-key selection set via aesSetKeySource.
  cfg = cfg or (regRead(AesCfg) and (1'u32 shl AesCfgHwKeyEn))
  cfg = cfg or (1'u32 shl AesCfgTrigger)
  regWrite(AesCfg, cfg)

  # Wait for completion
  timeout = 1_000_000
  while (regRead(AesCfg) and (1'u32 shl AesCfgBusy)) != 0:
    timeout.dec
    if timeout == 0: return secTimeout

  secOk

proc aesDecryptBlock*(src, dst: uint32, length: uint32,
                      mode: AesMode, keySize: AesKeySize): SecError =
  ## Decrypt data using AES.
  var timeout = 100_000'u32
  while (regRead(AesCfg) and (1'u32 shl AesCfgBusy)) != 0:
    timeout.dec
    if timeout == 0: return secBusy

  regWrite(AesSrcAddr, src)
  regWrite(AesDstAddr, dst)

  var cfg = (1'u32 shl AesCfgEn) or (1'u32 shl AesCfgDecEn)
  cfg = cfg or (mode.uint32 shl AesCfgModeShift)
  cfg = cfg or (aesKeyMode(keySize) shl AesCfgKeySizeShift)
  cfg = cfg or ((aesBlocks(length) shl AesCfgMsgLenShift) and AesCfgMsgLenMask)
  cfg = cfg or (regRead(AesCfg) and (1'u32 shl AesCfgHwKeyEn))
  cfg = cfg or (1'u32 shl AesCfgTrigger)
  regWrite(AesCfg, cfg)

  timeout = 1_000_000
  while (regRead(AesCfg) and (1'u32 shl AesCfgBusy)) != 0:
    timeout.dec
    if timeout == 0: return secTimeout

  secOk

# =============================================================================
# SHA operations
# =============================================================================
proc shaStart*(mode: ShaMode) =
  ## Start a SHA hash computation.
  var cfg = (1'u32 shl ShaCfgEn)
  cfg = cfg or (mode.uint32 shl ShaCfgModeShift)
  regWrite(ShaCfg, cfg)

proc shaUpdate*(src: uint32, length: uint32): SecError =
  ## Feed data block into the SHA engine.
  regWrite(ShaSrcAddr, src)

  let blocks = if length == 0: 0'u32 else: (length + 63'u32) div 64'u32
  var cfg = regRead(ShaCfg)
  cfg = cfg and (ShaCfgModeMask or ShaCfgModeExtMask or (1'u32 shl ShaCfgHashSel))
  cfg = cfg or (1'u32 shl ShaCfgEn)
  cfg = cfg or ((blocks shl ShaCfgMsgLenShift) and ShaCfgMsgLenMask)
  cfg = cfg or (1'u32 shl ShaCfgTrigger)
  regWrite(ShaCfg, cfg)

  var timeout = 1_000_000'u32
  while (regRead(ShaCfg) and (1'u32 shl ShaCfgBusy)) != 0:
    timeout.dec
    if timeout == 0: return secTimeout

  secOk

proc shaReadHash*(hash: var array[8, uint32]) =
  ## Read the SHA-256 hash result (8 words = 256 bits).
  ## For SHA-224, use only first 7 words.
  ## For SHA-1, use only first 5 words.
  for i in 0 ..< 8:
    hash[i] = regRead(ShaHash0 + i.uint * 4)

proc shaFinish*() =
  regClear(ShaCfg, 1'u32 shl ShaCfgEn)

# =============================================================================
# TRNG (True Random Number Generator)
# =============================================================================
proc trngClearInt() =
  let mask = 1'u32 shl TrngIntMask
  let clear = 1'u32 shl TrngIntClear
  var v = regRead(TrngCtrl0) or mask
  regWrite(TrngCtrl0, v or clear)
  v = regRead(TrngCtrl0) or mask
  regWrite(TrngCtrl0, v and not clear)

proc trngEnable*() =
  ## Enable the hardware TRNG.
  regSet(TrngCtrl3, 1'u32 shl TrngRoscEn)
  regSet(TrngCtrl0, (1'u32 shl TrngEn) or (1'u32 shl TrngIntMask))
  trngClearInt()

proc trngDisable*() =
  regWrite(TrngCtrl0, (regRead(TrngCtrl0) and not (1'u32 shl TrngEn)) or
                      (1'u32 shl TrngIntMask))

proc trngReady*(): bool =
  (regRead(TrngCtrl0) and (1'u32 shl TrngBusy)) == 0

proc trngOwner(): uint32 {.inline.} =
  (regRead(SecCtrlProtRead) shr TrngOwnerShift) and TrngOwnerMask

proc trngRequestGroup0(releaseWhenDone: var bool): bool =
  releaseWhenDone = false
  case trngOwner()
  of TrngOwnerGroup0:
    true
  of TrngOwnerFree:
    regWrite(TrngCtrlProt, TrngRequestGroup0)
    if trngOwner() == TrngOwnerGroup0:
      releaseWhenDone = true
      true
    else:
      false
  else:
    false

proc trngReleaseGroup0(releaseWhenDone: bool) =
  if releaseWhenDone:
    regWrite(TrngCtrlProt, TrngReleaseAccess)

proc trngWaitIdle(timeout: uint32): SecError =
  var countdown = timeout
  while (regRead(TrngCtrl0) and (1'u32 shl TrngBusy)) != 0:
    if countdown == 0:
      return secTimeout
    countdown.dec
  secOk

proc trngNopDelay() {.inline.} =
  {.emit: """
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
  """.}

proc trngFinish() =
  regWrite(TrngCtrl0, (regRead(TrngCtrl0) and not (1'u32 shl TrngTrigger)) or
                      (1'u32 shl TrngIntMask))
  regSet(TrngCtrl0, (1'u32 shl TrngDoutClear) or (1'u32 shl TrngIntMask))
  regWrite(TrngCtrl0, (regRead(TrngCtrl0) and not (1'u32 shl TrngDoutClear)) or
                      (1'u32 shl TrngIntMask))
  trngDisable()
  trngClearInt()

proc trngReadAll*(output: var array[8, uint32],
                  timeout: uint32 = 100_000): SecError

proc trngRead*(timeout: uint32 = 100_000): (uint32, SecError) =
  ## Read a 32-bit random number from the TRNG.
  var words: array[8, uint32]
  let err = trngReadAll(words, timeout)
  if err != secOk:
    return (0'u32, err)
  (words[0], secOk)

proc trngReadAll*(output: var array[8, uint32], timeout: uint32 = 100_000): SecError =
  ## Read all 8 TRNG output words (256 bits of randomness).
  var releaseTrng = false
  if not trngRequestGroup0(releaseTrng):
    return secBusy

  trngEnable()
  trngClearInt()
  trngNopDelay()
  result = trngWaitIdle(timeout)
  if result != secOk:
    trngFinish()
    trngReleaseGroup0(releaseTrng)
    return

  trngClearInt()
  regSet(TrngCtrl0, (1'u32 shl TrngTrigger) or (1'u32 shl TrngIntMask))
  trngNopDelay()
  result = trngWaitIdle(timeout)
  if result != secOk:
    trngFinish()
    trngReleaseGroup0(releaseTrng)
    return

  var nonZero = false
  for i in 0 ..< 8:
    output[i] = regRead(TrngData0 + i.uint * 4)
    if output[i] != 0'u32:
      nonZero = true
  trngFinish()
  trngReleaseGroup0(releaseTrng)
  result = if nonZero: secOk else: secTimeout

proc trngFillBuffer*(buf: var openArray[uint8]): SecError =
  ## Fill a buffer with random bytes.
  trngEnable()
  var i = 0
  while i < buf.len:
    var words: array[8, uint32]
    let err = trngReadAll(words)
    if err != secOk:
      trngDisable()
      return err
    for w in words:
      for b in 0 ..< 4:
        if i >= buf.len: break
        buf[i] = ((w shr (b * 8)) and 0xFF).uint8
        i.inc
  trngDisable()
  secOk

# =============================================================================
# Per-block group ownership
#
# Each SEC_ENG block carries a CTRL_PROT register that arbitrates access
# between CPU groups. Writing 0x02 claims the block for group 0, 0x06 releases
# it; the owner is read back from SecCtrlProtRead with a 2-bit field per block.
# This generalises the existing TRNG claim/release protocol to every block so
# the enclave can reserve AES/SHA/PKA/GMAC to the secure world.
# =============================================================================
type
  SecBlock* = enum
    secBlkSha = 0, secBlkAes, secBlkTrng, secBlkPka, secBlkCdet, secBlkGmac

const
  SecOwnerGroup0* = 0x01'u32   ## group 0 holds the block
  SecOwnerGroup1* = 0x02'u32
  SecOwnerFree*   = 0x03'u32
  SecReqGroup0*   = 0x02'u32   ## value written to CTRL_PROT to claim group 0
  SecRelease*     = 0x06'u32   ## value written to CTRL_PROT to release

proc secCtrlProtAddr*(blk: SecBlock): uint {.inline.} =
  SecBase + 0xFC'u + blk.ord.uint * 0x100'u

proc secBlockOwner*(blk: SecBlock): uint32 {.inline.} =
  (regRead(SecCtrlProtRead) shr (2 * blk.ord)) and 0x03'u32

proc secClaimGroup0*(blk: SecBlock, release: var bool): bool =
  ## Acquire a SEC_ENG block for group 0. `release` is set true only if this
  ## call performed the claim (so callers know whether to release afterwards).
  release = false
  case secBlockOwner(blk)
  of SecOwnerGroup0:
    true
  of SecOwnerFree:
    regWrite(secCtrlProtAddr(blk), SecReqGroup0)
    if secBlockOwner(blk) == SecOwnerGroup0:
      release = true
      true
    else:
      false
  else:
    false

proc secReleaseGroup0*(blk: SecBlock, release: bool) =
  if release:
    regWrite(secCtrlProtAddr(blk), SecRelease)

# =============================================================================
# AES hardware key source
#
# The AES engine can run from a software key (the AesKey0..7 registers) or from
# an eFuse-backed key slot whose bytes software never sees. Selecting an eFuse
# slot sets HW_KEY_EN; aesEncryptBlock/aesDecryptBlock preserve that bit.
# =============================================================================
type
  AesKeySource* = enum
    aesKeySoft, aesKeyEfuse0, aesKeyEfuse1, aesKeyEfuse2, aesKeyEfuse3

const
  AesCfgDecKeySel* = 6   # AesCfg bit: decrypt uses hardware key slot

proc aesSetKeySource*(src: AesKeySource) =
  ## Select software key or an eFuse hardware key slot (0..3).
  if src == aesKeySoft:
    regClear(AesCfg, 1'u32 shl AesCfgHwKeyEn)
  else:
    let slot = (src.ord - 1).uint32
    regModify(AesKeySel0, 0x3'u32, slot)
    regSet(AesCfg, (1'u32 shl AesCfgHwKeyEn) or (1'u32 shl AesCfgDecKeySel))

proc aesKeySource*(): AesKeySource =
  if (regRead(AesCfg) and (1'u32 shl AesCfgHwKeyEn)) == 0:
    aesKeySoft
  else:
    AesKeySource(1 + (regRead(AesKeySel0) and 0x3'u32).int)

# =============================================================================
# AES-XTS
#
# XTS-AES-128 uses a 256-bit key = key1 || key2. The data path reuses the
# standard block engine with mode field = 3 (XTS) and the XTS_MODE bit in the
# SBOOT register. (XIP-flash XTS lives in sfaes.nim; this is the data-buffer
# path.)
# =============================================================================
const
  AesSbootXtsMode* = 15   # AesSboot bit: enable XTS mode

proc aesSetXtsMode*(enable: bool) =
  if enable: regSet(AesSboot, 1'u32 shl AesSbootXtsMode)
  else:      regClear(AesSboot, 1'u32 shl AesSbootXtsMode)

proc aesXtsSetKeys*(key1, key2: array[4, uint32]) =
  ## Load an XTS-AES-128 key pair as a single 256-bit key (key1 || key2).
  var k: array[8, uint32]
  for i in 0 ..< 4:
    k[i] = key1[i]
    k[i + 4] = key2[i]
  aesSetKey(k)

# =============================================================================
# GMAC (Galois MAC) — link-mode descriptor engine
#
# GMAC always runs from a link descriptor whose address is written to LCA. The
# descriptor (and the message it points at) must live in DMA-visible RAM. The
# result tag is written back into the descriptor.
# =============================================================================
const
  GmacCtrl0*   = SecBase + 0x500'u
  GmacLca*     = SecBase + 0x504'u
  GmacStatus*  = SecBase + 0x508'u
  GmacBusy*    = 0
  GmacTrig*    = 1
  GmacEn*      = 2

type
  GmacLinkDesc* {.packed.} = object
    ctrl*: uint32             ## [31:16] msgLen in 128-bit blocks, [10]intSet [9]intClr
    srcAddr*: uint32
    key*: array[4, uint32]
    result*: array[4, uint32]

proc gmacCompute*(desc: ptr GmacLinkDesc, timeout: uint32 = 1_000_000): SecError =
  ## Run GMAC over a prepared link descriptor. `desc` must reside in
  ## DMA-visible (uncached) RAM with ctrl/srcAddr/key filled in; the tag is
  ## written to desc.result. Claims the GMAC block for group 0 for the run.
  ## NOTE: pending Phase-0 GMAC validation on hardware (endianness/cache).
  var release = false
  if not secClaimGroup0(secBlkGmac, release):
    return secBusy

  var countdown = timeout
  while (regRead(GmacCtrl0) and (1'u32 shl GmacBusy)) != 0:
    if countdown == 0:
      secReleaseGroup0(secBlkGmac, release)
      return secBusy
    countdown.dec

  regWrite(GmacLca, cast[uint32](desc))
  var ctrl = regRead(GmacCtrl0) or (1'u32 shl GmacEn) or (1'u32 shl GmacTrig)
  regWrite(GmacCtrl0, ctrl)

  countdown = timeout
  while (regRead(GmacCtrl0) and (1'u32 shl GmacBusy)) != 0:
    if countdown == 0:
      secReleaseGroup0(secBlkGmac, release)
      return secTimeout
    countdown.dec

  secReleaseGroup0(secBlkGmac, release)
  secOk
