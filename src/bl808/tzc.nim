## BL808 TrustZone Controller (TZC) register helpers.
##
## BL808 exposes named TZC policy blocks (ROM, OCRAM, WRAM, SF, XRAM, ...)
## rather than a generic linear array of region registers. Many policy fields
## are lock-on-write, so the default HAL API keeps mutation explicit.

import mmio, memmap

# =============================================================================
# TZC register offsets
# =============================================================================
const
  # Secure controller, ROM window
  TzcSecRomCtrl*       = TzcSecBase + 0x040'u
  TzcSecRomAddrMask*   = TzcSecBase + 0x044'u
  TzcSecRomR0*         = TzcSecBase + 0x048'u
  TzcSecRomR1*         = TzcSecBase + 0x04C'u
  TzcSecRomR2*         = TzcSecBase + 0x050'u

  # Secure controller, BMX master/slave grouping
  TzcSecBmxTzmid*      = TzcSecBase + 0x100'u
  TzcSecBmxTzmidLock*  = TzcSecBase + 0x104'u
  TzcSecBmxS0*         = TzcSecBase + 0x108'u
  TzcSecBmxS1*         = TzcSecBase + 0x10C'u
  TzcSecBmxS2*         = TzcSecBase + 0x110'u
  TzcSecBmxSLock*      = TzcSecBase + 0x114'u

  # Secure controller, memory windows
  TzcSecOcramCtrl*     = TzcSecBase + 0x140'u
  TzcSecOcramAddrMask* = TzcSecBase + 0x144'u
  TzcSecOcramR0*       = TzcSecBase + 0x148'u
  TzcSecOcramR1*       = TzcSecBase + 0x14C'u
  TzcSecOcramR2*       = TzcSecBase + 0x150'u
  TzcSecWramCtrl*      = TzcSecBase + 0x180'u
  TzcSecWramAddrMask*  = TzcSecBase + 0x184'u
  TzcSecWramR0*        = TzcSecBase + 0x188'u
  TzcSecWramR1*        = TzcSecBase + 0x18C'u
  TzcSecWramR2*        = TzcSecBase + 0x190'u

  # Secure controller, peripheral grouping
  TzcSecPdmCtrl*       = TzcSecBase + 0x240'u
  TzcSecUartCtrl*      = TzcSecBase + 0x244'u
  TzcSecI2cCtrl*       = TzcSecBase + 0x248'u
  TzcSecTimerCtrl*     = TzcSecBase + 0x24C'u
  TzcSecI2sCtrl*       = TzcSecBase + 0x250'u

  # Secure controller, serial flash windows
  TzcSecSfCtrl*        = TzcSecBase + 0x280'u
  TzcSecSfAddrMask*    = TzcSecBase + 0x284'u
  TzcSecSfR0*          = TzcSecBase + 0x288'u
  TzcSecSfR1*          = TzcSecBase + 0x28C'u
  TzcSecSfR2*          = TzcSecBase + 0x290'u
  TzcSecSfR3*          = TzcSecBase + 0x294'u
  TzcSecSfRMsb*        = TzcSecBase + 0x298'u

  # Secure controller, MM domain windows
  TzcSecMmBmxTzmid*    = TzcSecBase + 0x300'u
  TzcSecMmBmxTzmidLock* = TzcSecBase + 0x304'u
  TzcSecMmBmxS0*       = TzcSecBase + 0x308'u
  TzcSecMmBmxS1*       = TzcSecBase + 0x30C'u
  TzcSecMmBmxS2*       = TzcSecBase + 0x310'u
  TzcSecL2SramCtrl*    = TzcSecBase + 0x340'u
  TzcSecL2SramAddrMask* = TzcSecBase + 0x344'u
  TzcSecL2SramR0*      = TzcSecBase + 0x348'u
  TzcSecL2SramR1*      = TzcSecBase + 0x34C'u
  TzcSecL2SramR2*      = TzcSecBase + 0x350'u
  TzcSecVramCtrl*      = TzcSecBase + 0x360'u
  TzcSecVramAddrMask*  = TzcSecBase + 0x364'u
  TzcSecVramR0*        = TzcSecBase + 0x368'u
  TzcSecVramR1*        = TzcSecBase + 0x36C'u
  TzcSecVramR2*        = TzcSecBase + 0x370'u
  TzcSecPsramACtrl*    = TzcSecBase + 0x380'u
  TzcSecPsramAAddrMask* = TzcSecBase + 0x384'u
  TzcSecPsramAR0*      = TzcSecBase + 0x388'u
  TzcSecPsramAR1*      = TzcSecBase + 0x38C'u
  TzcSecPsramAR2*      = TzcSecBase + 0x390'u
  TzcSecPsramBCtrl*    = TzcSecBase + 0x3A0'u
  TzcSecPsramBAddrMask* = TzcSecBase + 0x3A4'u
  TzcSecPsramBR0*      = TzcSecBase + 0x3A8'u
  TzcSecPsramBR1*      = TzcSecBase + 0x3AC'u
  TzcSecPsramBR2*      = TzcSecBase + 0x3B0'u
  TzcSecXramCtrl*      = TzcSecBase + 0x3C0'u
  TzcSecXramAddrMask*  = TzcSecBase + 0x3C4'u
  TzcSecXramR0*        = TzcSecBase + 0x3C8'u
  TzcSecXramR1*        = TzcSecBase + 0x3CC'u
  TzcSecXramR2*        = TzcSecBase + 0x3D0'u

  # Secure controller, global policy controls
  TzcSecGlbCtrl0*      = TzcSecBase + 0xF00'u
  TzcSecGlbCtrl1*      = TzcSecBase + 0xF04'u
  TzcSecGlbCtrl2*      = TzcSecBase + 0xF08'u
  TzcSecMmCtrl0*       = TzcSecBase + 0xF20'u
  TzcSecMmCtrl1*       = TzcSecBase + 0xF24'u
  TzcSecMmCtrl2*       = TzcSecBase + 0xF28'u
  TzcSecSeCtrl0*       = TzcSecBase + 0xF40'u
  TzcSecSeCtrl1*       = TzcSecBase + 0xF44'u
  TzcSecSeCtrl2*       = TzcSecBase + 0xF48'u

# =============================================================================
# TZC field constants
# =============================================================================
const
  TzcRegionGroupBits*  = 4'u32
  TzcRegionGroupMask*  = 0x0F'u32
  TzcRegionEnableShift* = 16'u32
  TzcRegionLockShift*  = 24'u32
  TzcRomSbootDoneShift* = 28'u32
  TzcRomSbootDoneMask* = 0x0F'u32 shl TzcRomSbootDoneShift
  TzcBusRemapEn*       = 22'u32
  TzcBusRemapLock*     = 23'u32

type
  TzcRegion* = range[0..3]
  TzcRomRegion* = range[0..2]
  TzcAuthGroup* = range[0..3]

  TzcAccess* = enum
    tzcAccessNone      = 0
    tzcAccessRead      = 1
    tzcAccessWrite     = 2
    tzcAccessReadWrite = 3
    tzcAccessExec      = 4
    tzcAccessAll       = 7

const
  ## Non-conflicting compatibility aliases for older examples.
  tzcNone* = tzcAccessNone
  tzcRW*   = tzcAccessReadWrite
  tzcExec* = tzcAccessExec
  tzcAll*  = tzcAccessAll

proc tzcRead*(regAddr: uint): uint32 {.inline.} =
  regRead(regAddr)

proc tzcWrite*(regAddr: uint, value: uint32) {.inline.} =
  regWrite(regAddr, value)

proc tzcRomSbootDone*(ctrl: uint32 = regRead(TzcSecRomCtrl)): uint32 {.inline.} =
  (ctrl and TzcRomSbootDoneMask) shr TzcRomSbootDoneShift

proc tzcPackWindow*(startAddr, length: uint32, granularityShift: uint32): uint32 =
  ## Pack a TZC start/end window. `length` is rounded up to the granularity.
  if length == 0:
    return 0
  let granularity = (1'u32 shl granularityShift) - 1'u32
  let endAddr = (startAddr + length + granularity) and not granularity
  let start = (startAddr shr granularityShift) and 0xFFFF'u32
  let stop = ((endAddr shr granularityShift) - 1'u32) and 0xFFFF'u32
  (start shl 16) or stop

proc tzcConfigureRomRegion*(region: TzcRomRegion, startAddr, length: uint32,
                            group: TzcAuthGroup, lock: bool = false) =
  ## Configure a ROM TZC region. Set `lock` only when policy should persist
  ## until the next reset.
  let r = region.uint32
  let groupMask = TzcRegionGroupMask shl (r * TzcRegionGroupBits)
  let groupBits = (1'u32 shl group.uint32) shl (r * TzcRegionGroupBits)
  regModify(TzcSecRomCtrl, groupMask, groupBits)
  regWrite(TzcSecRomR0 + region.uint * 4'u, tzcPackWindow(startAddr, length, 10))
  var ctrl = regRead(TzcSecRomCtrl) or (1'u32 shl (TzcRegionEnableShift + r))
  if lock:
    ctrl = ctrl or (1'u32 shl (TzcRegionLockShift + r))
  regWrite(TzcSecRomCtrl, ctrl)

proc tzcConfigureRegion*(region: TzcRegion, baseAddr: uint32,
                         sizeLog2: uint32, access: TzcAccess,
                         secure: bool = false) =
  ## Compatibility wrapper for the old generic-region API.
  ##
  ## BL808 does not have a generic TZC region array. This maps regions 0..2 to
  ## ROM windows and leaves region 3 unused.
  discard access
  discard secure
  if region <= 2:
    tzcConfigureRomRegion(region.TzcRomRegion, baseAddr, 1'u32 shl sizeLog2, 0)

proc tzcBypassSecure*(enable: bool) =
  ## Compatibility no-op.
  ##
  ## BL808 TZC_SEC has no standalone bypass register at the old HAL offset.
  ## Bus remap is a separate lockable ROM-control bit and is intentionally not
  ## toggled here.
  discard enable

proc tzcLockRegion*(region: TzcRegion) =
  ## Lock a ROM region configuration until reset.
  if region <= 2:
    regSet(TzcSecRomCtrl, 1'u32 shl (TzcRegionLockShift + region.uint32))
