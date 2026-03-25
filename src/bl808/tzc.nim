## BL808 TrustZone Controller (TZC) driver.
##
## TZC_SEC at 0x20005000 — secure TrustZone configuration.
## TZC_NSEC at 0x20006000 — non-secure TrustZone configuration.
##
## Controls memory region access permissions, secure boot,
## and peripheral access isolation between secure/non-secure worlds.

import mmio, memmap

# =============================================================================
# TZC register offsets
# =============================================================================
const
  # Secure controller
  TzcSecCtrl*       = TzcSecBase + 0x00'u   # TZC secure control
  TzcSecRegion0*    = TzcSecBase + 0x40'u   # Region 0 config
  TzcSecRegion1*    = TzcSecBase + 0x44'u   # Region 1 config
  TzcSecRegion2*    = TzcSecBase + 0x48'u   # Region 2 config
  TzcSecRegion3*    = TzcSecBase + 0x4C'u   # Region 3 config
  TzcSecBypass*     = TzcSecBase + 0x80'u   # TZC bypass

  # Non-secure controller
  TzcNsecCtrl*      = TzcNsecBase + 0x00'u  # TZC non-secure control
  TzcNsecRegion0*   = TzcNsecBase + 0x40'u  # Region 0 config
  TzcNsecRegion1*   = TzcNsecBase + 0x44'u  # Region 1 config
  TzcNsecRegion2*   = TzcNsecBase + 0x48'u  # Region 2 config
  TzcNsecRegion3*   = TzcNsecBase + 0x4C'u  # Region 3 config

# =============================================================================
# Region configuration fields
# =============================================================================
const
  TzcRegionEn*      = 0       # Region enable
  TzcRegionLockShift* = 1     # Lock bit
  TzcRegionBaseShift* = 4     # Base address [15:4] (page-aligned)
  TzcRegionBaseMask*  = 0x0FFF'u32 shl 4
  TzcRegionSizeShift* = 16    # Region size [19:16] (log2 encoding)
  TzcRegionSizeMask*  = 0x0F'u32 shl 16
  TzcRegionRd*      = 24      # Read permission
  TzcRegionWr*      = 25      # Write permission
  TzcRegionExe*     = 26      # Execute permission
  TzcRegionSec*     = 28      # Secure access only

# =============================================================================
# Types
# =============================================================================
type
  TzcRegion* = range[0..3]

  TzcAccess* = enum
    tzcNone   = 0
    tzcRead   = 1
    tzcWrite  = 2
    tzcRW     = 3
    tzcExec   = 4
    tzcAll    = 7

# =============================================================================
# TrustZone operations
# =============================================================================
proc tzcConfigureRegion*(region: TzcRegion, baseAddr: uint32,
                         sizeLog2: uint32, access: TzcAccess,
                         secure: bool = false) =
  ## Configure a TZC memory protection region.
  ## `sizeLog2`: log2 of region size (e.g., 12 = 4KB, 20 = 1MB)
  let regAddr = TzcSecRegion0 + region.uint * 4
  var cfg = (1'u32 shl TzcRegionEn)
  cfg = cfg or ((baseAddr shr 12) shl TzcRegionBaseShift)
  cfg = cfg or ((sizeLog2 and 0x0F) shl TzcRegionSizeShift)
  if (access.uint32 and 1) != 0: cfg = cfg or (1'u32 shl TzcRegionRd)
  if (access.uint32 and 2) != 0: cfg = cfg or (1'u32 shl TzcRegionWr)
  if (access.uint32 and 4) != 0: cfg = cfg or (1'u32 shl TzcRegionExe)
  if secure: cfg = cfg or (1'u32 shl TzcRegionSec)
  regWrite(regAddr, cfg)

proc tzcBypassSecure*(enable: bool) =
  ## Bypass TZC checks (debug only — DANGEROUS in production).
  if enable:
    regWrite(TzcSecBypass, 1)
  else:
    regWrite(TzcSecBypass, 0)

proc tzcLockRegion*(region: TzcRegion) =
  ## Lock a region configuration (cannot be changed until reset).
  let regAddr = TzcSecRegion0 + region.uint * 4
  regSet(regAddr, 1'u32 shl TzcRegionLockShift)
