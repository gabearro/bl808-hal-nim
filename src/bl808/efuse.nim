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
