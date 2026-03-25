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

  # AES registers
  AesCfg*           = SecBase + 0x000'u  # AES configuration
  AesMsk*           = SecBase + 0x004'u  # AES mask
  AesStatus*        = SecBase + 0x008'u  # AES status
  AesIntSts*        = SecBase + 0x00C'u  # AES interrupt status
  AesKey0*          = SecBase + 0x010'u  # AES key word 0 (8 words, 0x010-0x02C)
  AesIv0*           = SecBase + 0x030'u  # AES IV word 0 (4 words, 0x030-0x03C)
  AesSrcAddr*       = SecBase + 0x040'u  # Source data address
  AesDstAddr*       = SecBase + 0x044'u  # Destination data address
  AesMsgLen*        = SecBase + 0x048'u  # Message length
  AesEndian*        = SecBase + 0x04C'u  # Endian config
  AesLinkCfg*       = SecBase + 0x050'u  # Link mode config

  # SHA registers
  ShaCfg*           = SecBase + 0x100'u  # SHA configuration
  ShaStatus*        = SecBase + 0x104'u  # SHA status
  ShaIntSts*        = SecBase + 0x108'u  # SHA interrupt status
  ShaSrcAddr*       = SecBase + 0x10C'u  # Source data address
  ShaMsgLen*        = SecBase + 0x110'u  # Message length
  ShaHash0*         = SecBase + 0x114'u  # Hash output word 0 (8 words)
  ShaLink*          = SecBase + 0x134'u  # SHA link mode config
  ShaEndian*        = SecBase + 0x13C'u  # SHA endian

  # TRNG registers
  TrngCtrl0*        = SecBase + 0x200'u  # TRNG control 0
  TrngCtrl1*        = SecBase + 0x204'u  # TRNG control 1
  TrngCtrl2*        = SecBase + 0x208'u  # TRNG control 2
  TrngCtrl3*        = SecBase + 0x20C'u  # TRNG control 3
  TrngStatus*       = SecBase + 0x210'u  # TRNG status
  TrngData0*        = SecBase + 0x214'u  # TRNG output word 0
  TrngData1*        = SecBase + 0x218'u  # TRNG output word 1
  TrngData2*        = SecBase + 0x21C'u  # TRNG output word 2
  TrngData3*        = SecBase + 0x220'u  # TRNG output word 3
  TrngData4*        = SecBase + 0x224'u  # TRNG output word 4
  TrngData5*        = SecBase + 0x228'u  # TRNG output word 5
  TrngData6*        = SecBase + 0x22C'u  # TRNG output word 6
  TrngData7*        = SecBase + 0x230'u  # TRNG output word 7
  TrngIntSts*       = SecBase + 0x234'u  # TRNG interrupt status
  TrngIntMask*      = SecBase + 0x238'u  # TRNG interrupt mask

  # PKA registers
  PkaCtrl0*         = SecBase + 0x300'u  # PKA control 0
  PkaStatus*        = SecBase + 0x360'u  # PKA status
  PkaIntSts*        = SecBase + 0x364'u  # PKA interrupt status
  PkaIntMask*       = SecBase + 0x368'u  # PKA interrupt mask

# =============================================================================
# AES configuration fields
# =============================================================================
const
  AesCfgEn*        = 0        # AES enable
  AesCfgModeShift* = 1        # AES mode [2:1]: 0=ECB, 1=CTR, 2=CBC
  AesCfgModeMask*  = 0x03'u32 shl 1
  AesCfgDecEn*     = 3        # Decrypt mode (0=encrypt, 1=decrypt)
  AesCfgKeySizeShift* = 4     # Key size [5:4]: 0=128, 1=192, 2=256
  AesCfgKeySizeMask*  = 0x03'u32 shl 4
  AesCfgDmaEn*     = 6        # DMA mode enable
  AesCfgMsgLenEn*  = 7        # Message length enable
  AesCfgIntDone*   = 8        # Interrupt on done
  AesCfgBusy*      = 0        # Busy (in status register)

# =============================================================================
# SHA configuration fields
# =============================================================================
const
  ShaCfgEn*        = 0        # SHA enable
  ShaCfgModeShift* = 1        # SHA mode [3:1]: 0=SHA256, 1=SHA224, 2=SHA1, 3=SHA1
  ShaCfgModeMask*  = 0x07'u32 shl 1
  ShaCfgHashSel*   = 4        # Hash select
  ShaCfgIntDone*   = 8        # Interrupt on done
  ShaCfgBusy*      = 0        # Busy (in status register)

# =============================================================================
# TRNG control fields
# =============================================================================
const
  TrngEn*          = 0        # TRNG enable
  TrngIntEn*       = 1        # Interrupt enable
  TrngReady*       = 0        # Data ready (in status register)

# =============================================================================
# Types
# =============================================================================
type
  AesMode* = enum
    aesEcb = 0
    aesCtr = 1
    aesCbc = 2

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

proc aesEncryptBlock*(src, dst: uint32, length: uint32,
                      mode: AesMode, keySize: AesKeySize): SecError =
  ## Encrypt data using AES. `src` and `dst` are memory addresses.
  ## `length` is in bytes (must be multiple of 16 for ECB/CBC).

  # Wait for any previous operation
  var timeout = 100_000'u32
  while (regRead(AesStatus) and 1) != 0:
    timeout.dec
    if timeout == 0: return secBusy

  # Configure
  var cfg = (1'u32 shl AesCfgEn)
  cfg = cfg or (mode.uint32 shl AesCfgModeShift)
  cfg = cfg or (keySize.uint32 shl AesCfgKeySizeShift)
  cfg = cfg or (1'u32 shl AesCfgMsgLenEn)
  regWrite(AesCfg, cfg)

  # Set addresses and length
  regWrite(AesSrcAddr, src)
  regWrite(AesDstAddr, dst)
  regWrite(AesMsgLen, length)

  # Start
  regSet(AesCfg, 1'u32 shl AesCfgDmaEn)

  # Wait for completion
  timeout = 1_000_000
  while (regRead(AesStatus) and 1) != 0:
    timeout.dec
    if timeout == 0: return secTimeout

  secOk

proc aesDecryptBlock*(src, dst: uint32, length: uint32,
                      mode: AesMode, keySize: AesKeySize): SecError =
  ## Decrypt data using AES.
  var timeout = 100_000'u32
  while (regRead(AesStatus) and 1) != 0:
    timeout.dec
    if timeout == 0: return secBusy

  var cfg = (1'u32 shl AesCfgEn) or (1'u32 shl AesCfgDecEn)
  cfg = cfg or (mode.uint32 shl AesCfgModeShift)
  cfg = cfg or (keySize.uint32 shl AesCfgKeySizeShift)
  cfg = cfg or (1'u32 shl AesCfgMsgLenEn)
  regWrite(AesCfg, cfg)

  regWrite(AesSrcAddr, src)
  regWrite(AesDstAddr, dst)
  regWrite(AesMsgLen, length)

  regSet(AesCfg, 1'u32 shl AesCfgDmaEn)

  timeout = 1_000_000
  while (regRead(AesStatus) and 1) != 0:
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
  regWrite(ShaMsgLen, length)

  # Trigger processing
  regSet(ShaCfg, 1'u32 shl ShaCfgHashSel)

  var timeout = 1_000_000'u32
  while (regRead(ShaStatus) and 1) != 0:
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
proc trngEnable*() =
  ## Enable the hardware TRNG.
  regSet(TrngCtrl0, 1'u32 shl TrngEn)

proc trngDisable*() =
  regClear(TrngCtrl0, 1'u32 shl TrngEn)

proc trngReady*(): bool =
  (regRead(TrngStatus) and 1) != 0

proc trngRead*(timeout: uint32 = 100_000): (uint32, SecError) =
  ## Read a 32-bit random number from the TRNG.
  var countdown = timeout
  while not trngReady():
    countdown.dec
    if countdown == 0: return (0'u32, secTimeout)

  let value = regRead(TrngData0)
  # Acknowledge (some implementations need a status clear)
  regSet(TrngIntSts, 1'u32)
  (value, secOk)

proc trngReadAll*(output: var array[8, uint32], timeout: uint32 = 100_000): SecError =
  ## Read all 8 TRNG output words (256 bits of randomness).
  var countdown = timeout
  while not trngReady():
    countdown.dec
    if countdown == 0: return secTimeout

  for i in 0 ..< 8:
    output[i] = regRead(TrngData0 + i.uint * 4)
  regSet(TrngIntSts, 1'u32)
  secOk

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
