## BL808 eFuse controller driver.
##
## EF_CTRL at 0x20056000 manages One-Time Programmable (OTP) memory.
## Contains factory-programmed data: MAC addresses, chip ID, security keys,
## trim values, and user-programmable regions.
##
## WARNING: eFuse programming is IRREVERSIBLE. Each bit can only be
## changed from 0 to 1, never back.

import mmio, memmap

# =============================================================================
# eFuse register offsets
# =============================================================================
const
  EfBase*           = EfCtrlBase  # 0x20056000

  EfCtrl0*          = EfBase + 0x800'u  # eFuse control 0
  EfCtrl1*          = EfBase + 0x804'u  # eFuse control 1
  EfPgmCmd*         = EfBase + 0x808'u  # Program command
  EfRdCmd*          = EfBase + 0x80C'u  # Read command
  EfSwCfg*          = EfBase + 0x810'u  # Software config
  EfAnaRegCtrl*     = EfBase + 0x814'u  # Analog register control
  EfProt*           = EfBase + 0x818'u  # Protection / lock

  # eFuse data regions (read after issuing read command)
  EfDataBase*       = EfBase + 0x000'u  # eFuse data word 0
  # Total: 128 words (512 bytes) of eFuse data

# =============================================================================
# EF_CTRL0 fields
# =============================================================================
const
  EfAutoLoadDone*   = 0        # Auto-load done (read-only)
  EfPgmEn*         = 1        # Program enable
  EfCrcEn*         = 2        # CRC check enable
  EfPgmClkDiv*     = 8        # Program clock divider [13:8]
  EfPgmClkDivMask* = 0x3F'u32 shl 8

# =============================================================================
# Types
# =============================================================================
type
  EfuseError* = enum
    efuseOk
    efuseBusy
    efuseTimeout
    efuseProtected

# =============================================================================
# Read operations
# =============================================================================
proc efuseReadWord*(index: uint32): uint32 =
  ## Read a 32-bit word from eFuse data (index 0-127).
  ## Issues a read command first to load eFuse into shadow registers.
  if index >= 128: return 0

  # Issue read command
  regWrite(EfRdCmd, 1'u32)

  # Wait for read to complete
  var timeout = 10_000'u32
  while (regRead(EfRdCmd) and 1) != 0:
    timeout.dec
    if timeout == 0: return 0

  # Read shadow register
  regRead(EfDataBase + index * 4)

proc efuseReadBuffer*(startWord: uint32, buf: var openArray[uint32]) =
  ## Read multiple consecutive eFuse words.
  # Issue read command
  regWrite(EfRdCmd, 1'u32)
  var timeout = 10_000'u32
  while (regRead(EfRdCmd) and 1) != 0:
    timeout.dec
    if timeout == 0: return

  for i in 0 ..< buf.len:
    let idx = startWord + i.uint32
    if idx < 128:
      buf[i] = regRead(EfDataBase + idx * 4)

# =============================================================================
# Common eFuse data locations
# =============================================================================
const
  # MAC address location (6 bytes starting at word offset)
  EfMacAddrWordOffset*   = 0x2C  # Words 0x2C-0x2D contain MAC address
  EfChipIdWordOffset*    = 0x28  # Chip ID
  EfUserDataWordOffset*  = 0x40  # Start of user-programmable data

proc efuseReadMacAddress*(mac: var array[6, uint8]) =
  ## Read the factory-programmed WiFi MAC address.
  let w0 = efuseReadWord(EfMacAddrWordOffset)
  let w1 = efuseReadWord(EfMacAddrWordOffset + 1)
  mac[0] = ((w0 shr 0) and 0xFF).uint8
  mac[1] = ((w0 shr 8) and 0xFF).uint8
  mac[2] = ((w0 shr 16) and 0xFF).uint8
  mac[3] = ((w0 shr 24) and 0xFF).uint8
  mac[4] = ((w1 shr 0) and 0xFF).uint8
  mac[5] = ((w1 shr 8) and 0xFF).uint8

proc efuseReadChipId*(): uint64 =
  ## Read the unique chip ID.
  let w0 = efuseReadWord(EfChipIdWordOffset).uint64
  let w1 = efuseReadWord(EfChipIdWordOffset + 1).uint64
  (w1 shl 32) or w0

# =============================================================================
# Program operations (IRREVERSIBLE!)
# =============================================================================
proc efuseProgramWord*(index: uint32, value: uint32): EfuseError =
  ## Program a 32-bit word into eFuse. IRREVERSIBLE!
  ## Only bits that are 1 in `value` will be programmed (0→1).
  ## Bits already set to 1 cannot be changed back to 0.
  if index >= 128: return efuseProtected

  # Check not busy
  if (regRead(EfCtrl0) and (1'u32 shl EfPgmEn)) != 0:
    return efuseBusy

  # Write value to shadow register
  regWrite(EfDataBase + index * 4, value)

  # Enable programming
  regSet(EfCtrl0, 1'u32 shl EfPgmEn)

  # Issue program command
  regWrite(EfPgmCmd, 1'u32)

  # Wait for completion
  var timeout = 100_000'u32
  while (regRead(EfPgmCmd) and 1) != 0:
    timeout.dec
    if timeout == 0:
      regClear(EfCtrl0, 1'u32 shl EfPgmEn)
      return efuseTimeout

  # Disable programming
  regClear(EfCtrl0, 1'u32 shl EfPgmEn)
  efuseOk

# =============================================================================
# Auto-load check
# =============================================================================
proc efuseAutoLoadDone*(): bool =
  ## Check if the eFuse auto-load at boot completed successfully.
  (regRead(EfCtrl0) and 1) != 0

# =============================================================================
# Security configuration map (ef_data_0)
#
# Word indices are byte-offset / 4. Verified against the vendored
# ef_data_0_reg.h. All accessors are read-only; nothing here programs eFuse.
# =============================================================================
const
  EfWordCfg0*        = 0x00 div 4    # security configuration word
  EfWordDbgPwdLow*   = 0x04 div 4
  EfWordDbgPwdHigh*  = 0x08 div 4
  EfWordKeySlot0*    = 0x1C div 4    # 4 words per slot; slots 1..3 at +4 words
  EfWordKeySlot1*    = 0x2C div 4
  EfWordKeySlot2*    = 0x3C div 4
  EfWordKeySlot3*    = 0x4C div 4
  EfWordSwUsage0*    = 0x5C div 4
  EfWordLock*        = 0x7C div 4    # read/write lock + lifecycle word

  # cfg0 fields
  EfCfgSfAesModeShift* = 0
  EfCfgSfAesModeMask*  = 0x3'u32
  EfCfgSbootEnShift*   = 4
  EfCfgSbootEnMask*    = 0x3'u32 shl 4
  EfCfgSeDbgDis*       = 22
  EfCfgEfuseDbgDis*    = 23
  EfCfgJtag1DisShift*  = 24
  EfCfgJtag1DisMask*   = 0x3'u32 shl 24
  EfCfgJtag0DisShift*  = 26
  EfCfgJtag0DisMask*   = 0x3'u32 shl 26
  EfCfgDbgModeShift*   = 28
  EfCfgDbgModeMask*    = 0xF'u32 shl 28

  # sw_usage_0 fields
  EfSwSbootSignShift*  = 8
  EfSwSbootSignMask*   = 0x3'u32 shl 8

  # lock word bit positions
  EfLockWrDbgPwd*      = 15
  EfLockWrKeySlot0*    = 17    # slots 1..3 at +1
  EfLockWrSwUsage0*    = 21
  EfLockRdDbgPwd*      = 26
  EfLockRdKeySlot0*    = 27    # slots 1..3 at +1

type
  SfAesMode* = enum
    sfAesNone = 0, sfAesM1 = 1, sfAesM2 = 2, sfAesM3 = 3
  SbootSignMode* = enum
    signNone = 0, signRsa = 1, signEccP256 = 2
  DbgMode* = enum
    dbgOpen = 0, dbgPassword = 1, dbgClosed = 4

  EfuseSecState* = object
    sbootEn*: uint32             ## cfg0 [5:4] (nonzero => secure boot enabled)
    sfAesMode*: SfAesMode
    seDbgDisabled*: bool
    efuseDbgDisabled*: bool
    jtag0Disable*, jtag1Disable*: uint32
    dbgModeRaw*: uint32
    signMode*: SbootSignMode
    keySlotReadLocked*: array[4, bool]
    keySlotWriteLocked*: array[4, bool]
    dbgPwdReadLocked*, dbgPwdWriteLocked*: bool

proc efuseDecodeSecState*(cfg0, sw0, lock: uint32): EfuseSecState =
  ## Pure decoder for the three ef_data_0 security words. Split out so the
  ## interpretation of an enforced/provisioned device can be tested against known
  ## words without touching real OTP (the inverse of computeProvisionPlan).
  result.sbootEn = (cfg0 and EfCfgSbootEnMask) shr EfCfgSbootEnShift
  result.sfAesMode = ((cfg0 and EfCfgSfAesModeMask) shr EfCfgSfAesModeShift).SfAesMode
  result.seDbgDisabled = (cfg0 and (1'u32 shl EfCfgSeDbgDis)) != 0
  result.efuseDbgDisabled = (cfg0 and (1'u32 shl EfCfgEfuseDbgDis)) != 0
  result.jtag0Disable = (cfg0 and EfCfgJtag0DisMask) shr EfCfgJtag0DisShift
  result.jtag1Disable = (cfg0 and EfCfgJtag1DisMask) shr EfCfgJtag1DisShift
  result.dbgModeRaw = (cfg0 and EfCfgDbgModeMask) shr EfCfgDbgModeShift
  let sm = (sw0 and EfSwSbootSignMask) shr EfSwSbootSignShift
  result.signMode = (if sm <= 2: sm.SbootSignMode else: signNone)
  for s in 0 ..< 4:
    result.keySlotWriteLocked[s] = (lock and (1'u32 shl (EfLockWrKeySlot0 + s))) != 0
    result.keySlotReadLocked[s]  = (lock and (1'u32 shl (EfLockRdKeySlot0 + s))) != 0
  result.dbgPwdWriteLocked = (lock and (1'u32 shl EfLockWrDbgPwd)) != 0
  result.dbgPwdReadLocked  = (lock and (1'u32 shl EfLockRdDbgPwd)) != 0

proc efuseProductionLocked*(s: EfuseSecState): bool =
  ## True iff this device is fully production-provisioned: secure boot enabled
  ## with a real sign mode AND debug closed (JTAG both halves disabled). This is
  ## the gate the framework uses to decide "trust the BootROM root of trust".
  s.sbootEn != 0 and s.signMode != signNone and
    s.jtag0Disable == 0x3 and s.jtag1Disable == 0x3

proc efuseReadSecState*(): EfuseSecState =
  ## Snapshot this chip's eFuse security configuration (read-only).
  efuseDecodeSecState(efuseReadWord(EfWordCfg0.uint32),
                      efuseReadWord(EfWordSwUsage0.uint32),
                      efuseReadWord(EfWordLock.uint32))

proc efuseKeySlotReadLocked*(slot: range[0..3]): bool =
  ## True if a hardware AES key slot is read-protected (software cannot read
  ## its bytes; the SEC_ENG hardware-key path can still use it).
  let lock = efuseReadWord(EfWordLock.uint32)
  (lock and (1'u32 shl (EfLockRdKeySlot0 + slot))) != 0

# =============================================================================
# Provisioning descriptor (pure — NEVER programs eFuse)
#
# Computes the (word, orMask) writes a production burn WOULD apply, so host
# tooling and documentation can show exactly what provisioning does without
# touching the OTP. eFuse bits only go 0->1, so every write is an OR mask.
# =============================================================================
type
  ProvisionWrite* = object
    word*: uint32      ## eFuse word index
    orMask*: uint32    ## bits to set (0 -> 1)

  ProvisionSpec* = object
    enableSecureBoot*: bool
    signMode*: SbootSignMode
    sfAesMode*: SfAesMode
    disableJtag*: bool          ## set both jtag-disable fields
    disableSeDbg*: bool
    lockKeySlotsRead*: set[range[0..3]]
    lockKeySlotsWrite*: set[range[0..3]]

  ProvisionPlan* = object
    writes*: array[8, ProvisionWrite]
    count*: int

proc add(plan: var ProvisionPlan, word, orMask: uint32) =
  if orMask == 0: return
  # merge into an existing entry for the same word
  for i in 0 ..< plan.count:
    if plan.writes[i].word == word:
      plan.writes[i].orMask = plan.writes[i].orMask or orMask
      return
  if plan.count < plan.writes.len:
    plan.writes[plan.count] = ProvisionWrite(word: word, orMask: orMask)
    inc plan.count

proc computeProvisionPlan*(spec: ProvisionSpec): ProvisionPlan =
  ## Pure function: the eFuse words/bits a production burn would set for this
  ## spec. Never executed against hardware in reversible mode.
  var cfg0 = 0'u32
  if spec.enableSecureBoot:
    cfg0 = cfg0 or (1'u32 shl EfCfgSbootEnShift)   # sboot_en = 1
  cfg0 = cfg0 or ((spec.sfAesMode.uint32 and 0x3) shl EfCfgSfAesModeShift)
  if spec.disableSeDbg:
    cfg0 = cfg0 or (1'u32 shl EfCfgSeDbgDis)
  if spec.disableJtag:
    cfg0 = cfg0 or EfCfgJtag0DisMask or EfCfgJtag1DisMask
    cfg0 = cfg0 or (4'u32 shl EfCfgDbgModeShift)   # dbg_mode = closed
  result.add(EfWordCfg0.uint32, cfg0)

  if spec.signMode != signNone:
    result.add(EfWordSwUsage0.uint32, spec.signMode.uint32 shl EfSwSbootSignShift)

  var lock = 0'u32
  for s in spec.lockKeySlotsRead:  lock = lock or (1'u32 shl (EfLockRdKeySlot0 + s))
  for s in spec.lockKeySlotsWrite: lock = lock or (1'u32 shl (EfLockWrKeySlot0 + s))
  result.add(EfWordLock.uint32, lock)
