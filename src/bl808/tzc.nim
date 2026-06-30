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
  TzcNsecBmxTzmid*     = TzcNsecBase + 0x100'u
  TzcNsecBmxTzmidLock* = TzcNsecBase + 0x104'u
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
  TzcNsecSfCtrl*       = TzcNsecBase + 0x280'u
  TzcNsecSfR0*         = TzcNsecBase + 0x288'u
  TzcNsecSfRMsb*       = TzcNsecBase + 0x298'u

  # Secure controller, MM domain windows
  TzcSecMmBmxTzmid*    = TzcSecBase + 0x300'u
  TzcSecMmBmxTzmidLock* = TzcSecBase + 0x304'u
  TzcNsecMmBmxTzmid*   = TzcNsecBase + 0x300'u
  TzcNsecMmBmxTzmidLock* = TzcNsecBase + 0x304'u
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
  TzcNsecSeCtrl1*      = TzcNsecBase + 0xF44'u
  TzcNsecSeCtrl2*      = TzcNsecBase + 0xF48'u

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
  TzcSfTzsidCtrlMode*  = 4'u32
  TzcSfTzsidCtrlModeLock* = 18'u32

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
  # ROM uses a 2-bit one-hot group field per region (stride 2), not 4. The
  # field holds a bitmask of allowed groups, so group g -> bit g.
  let groupMask = 0x3'u32 shl (r * 2'u32)
  let groupBits = (1'u32 shl group.uint32) shl (r * 2'u32)
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

# =============================================================================
# Bus masters, slaves, and protected blocks
#
# TZC assigns every bus master to an authorisation group (0 or 1) and every
# protected slave/memory-window to a set of groups allowed to reach it. The
# enclave model puts the secure core (M0) and secure resources in group 0 and
# every untrusted master (DMA, WiFi, USB, D0/LP, ...) in group 1, then locks.
#
# Bit-level behaviour mirrors Bouffalo's bl808_tzc_sec.c. Enum values follow
# TZC_SEC_Master_Type / TZC_SEC_Slave_Type so the split points used by the
# hardware (D0 splits master banks; EMI_MISC/MM split slave banks) stay exact.
# =============================================================================
type
  TzcMaster* = enum
    tzcMasterLp     = 0   ## LP (E902) CPU
    tzcMasterMmBus  = 1   ## MM subsystem bus
    tzcMasterUsb    = 2
    tzcMasterWifi   = 3
    tzcMasterCci    = 4
    tzcMasterSdh    = 5
    tzcMasterEmac   = 6
    tzcMasterM0     = 7   ## M0 (E907) CPU
    tzcMasterDma0   = 8
    tzcMasterDma1   = 9
    tzcMasterLz4    = 10
    tzcMasterD0     = 11  ## C906 CPU (first MM-bank master)
    tzcMasterBlai   = 12
    tzcMasterCodec  = 13
    tzcMaster2dDma  = 14
    tzcMasterDma2   = 15

  TzcSlave* = enum
    tzcSlaveGlb        = 0
    tzcSlaveMix        = 1
    tzcSlaveGpip       = 2
    tzcSlaveDbg        = 3
    tzcSlaveRsvd       = 4
    tzcSlaveTzc1       = 5
    tzcSlaveTzc2       = 6
    tzcSlaveRsvd2      = 7
    tzcSlaveCci        = 8
    tzcSlaveMcuMisc    = 9
    tzcSlavePeripheral = 10
    tzcSlaveEmiMisc    = 16
    tzcSlavePsramA     = 17
    tzcSlavePsramB     = 18
    tzcSlaveUsb        = 19
    tzcSlaveRf2        = 20
    tzcSlaveAudio      = 21
    tzcSlaveEfCtrl     = 22
    tzcSlaveMm         = 32
    tzcSlaveDma0       = 33
    tzcSlaveDma1       = 34
    tzcSlavePwr        = 35

  TzcSeBlock* = enum
    tzcSeSha = 0, tzcSeAes, tzcSeTrng, tzcSePka, tzcSeCdet, tzcSeGmac

  TzcSfCtrlBlock* = enum
    tzcSfCr = 0   ## SF_CTRL control register group
    tzcSfSec      ## SF_CTRL security (XIP AES) register group

  TzcWindow* = enum
    tzcWinRom, tzcWinOcram, tzcWinWram, tzcWinXram, tzcWinSf,
    tzcWinPsramA, tzcWinPsramB

  TzcWindowDesc = object
    ctrl, r0, msb: uint   ## register addresses (msb = 0 when the window has none)
    regions: int          ## number of address regions
    idWidth: uint32       ## group-field width: 2 (one-hot) or 4 (IBUS/DBUS x grp)
    enShift, lockShift: uint32

const TzcWindows: array[TzcWindow, TzcWindowDesc] = [
  tzcWinRom:   TzcWindowDesc(ctrl: TzcSecRomCtrl,   r0: TzcSecRomR0,   msb: 0,
                             regions: 3, idWidth: 2, enShift: 16, lockShift: 24),
  tzcWinOcram: TzcWindowDesc(ctrl: TzcSecOcramCtrl, r0: TzcSecOcramR0, msb: 0,
                             regions: 3, idWidth: 4, enShift: 16, lockShift: 20),
  tzcWinWram:  TzcWindowDesc(ctrl: TzcSecWramCtrl,  r0: TzcSecWramR0,  msb: 0,
                             regions: 3, idWidth: 4, enShift: 16, lockShift: 20),
  tzcWinXram:  TzcWindowDesc(ctrl: TzcSecXramCtrl,  r0: TzcSecXramR0,  msb: 0,
                             regions: 3, idWidth: 2, enShift: 16, lockShift: 24),
  tzcWinSf:    TzcWindowDesc(ctrl: TzcSecSfCtrl,    r0: TzcSecSfR0,    msb: TzcSecSfRMsb,
                             regions: 4, idWidth: 4, enShift: 20, lockShift: 25),
  tzcWinPsramA: TzcWindowDesc(ctrl: TzcSecPsramACtrl, r0: TzcSecPsramAR0, msb: 0,
                              regions: 3, idWidth: 4, enShift: 16, lockShift: 20),
  tzcWinPsramB: TzcWindowDesc(ctrl: TzcSecPsramBCtrl, r0: TzcSecPsramBR0, msb: 0,
                              regions: 3, idWidth: 4, enShift: 16, lockShift: 20),
]

proc tzcGroupField(groups: set[TzcAuthGroup], width: uint32): uint32 =
  ## Encode an allowed-group set into a window's group field.
  ## width 2: one-hot bit per group (bit g = group g allowed).
  ## width 4: per group g, both IBUS and DBUS bits (0b11 shl (2*g)).
  for g in groups:
    if g.uint32 <= 1:
      if width == 2: result = result or (1'u32 shl g.uint32)
      else:          result = result or (0x3'u32 shl (2'u32 * g.uint32))

proc tzcConfigureWindowRegion*(window: TzcWindow, region: int,
                               startAddr, length: uint32,
                               groups: set[TzcAuthGroup], lock = false): bool =
  ## Program one address region of a memory window: which groups may reach
  ## `[startAddr, startAddr+length)`, then enable (and optionally lock) it.
  ## Returns false for an out-of-range region index. 1 KB granularity.
  let d = TzcWindows[window]
  if region < 0 or region >= d.regions:
    return false
  let r = region.uint32
  let field = tzcGroupField(groups, d.idWidth)
  let fmask = ((1'u32 shl d.idWidth) - 1) shl (r * d.idWidth)
  regModify(d.ctrl, fmask, field shl (r * d.idWidth))

  regWrite(d.r0 + region.uint * 4'u, tzcPackWindow(startAddr, length, 10))

  if d.msb != 0:
    # Serial-flash windows extend start/end with 3 high bits each, one byte
    # per region. Clear only this region's byte (the vendor driver keeps the
    # wrong byte here; we preserve the other regions instead).
    let alignEnd = (startAddr + length + 1023'u32) and not 0x3FF'u32
    let ext = ((alignEnd shr 26) and 0x7'u32) or
              (((startAddr shr 26) and 0x7'u32) shl 3)
    let keep = regRead(d.msb) and not (0xFF'u32 shl (8'u32 * r))
    regWrite(d.msb, keep or (ext shl (8'u32 * r)))

  var ctrl = regRead(d.ctrl) or (1'u32 shl (d.enShift + r))
  if lock:
    ctrl = ctrl or (1'u32 shl (d.lockShift + r))
  regWrite(d.ctrl, ctrl)
  true

proc tzcWindowRegionLocked*(window: TzcWindow, region: int): bool =
  ## True if the region's lock bit is set (configuration frozen until reset).
  let d = TzcWindows[window]
  if region < 0 or region >= d.regions:
    return false
  (regRead(d.ctrl) and (1'u32 shl (d.lockShift + region.uint32))) != 0

proc tzcWindowRegionGroupField*(window: TzcWindow, region: int): uint32 =
  ## Read back the group bitmask (`1 shl group`) authorised for a window region.
  ## E.g. 0x1 = group 0 only; 0x3 = both groups. 0xFFFFFFFF for a bad region.
  let d = TzcWindows[window]
  if region < 0 or region >= d.regions:
    return 0xFFFFFFFF'u32
  let r = region.uint32
  let mask = (1'u32 shl d.idWidth) - 1
  (regRead(d.ctrl) shr (r * d.idWidth)) and mask

proc tzcWindowRegionEnabled*(window: TzcWindow, region: int): bool =
  ## True if the region's enable bit is set.
  let d = TzcWindows[window]
  if region < 0 or region >= d.regions:
    return false
  (regRead(d.ctrl) and (1'u32 shl (d.enShift + region.uint32))) != 0

proc tzcSetSfRegionXGroups*(groups: set[TzcAuthGroup], lock = false) =
  ## Configure the serial-flash fallback region (region x). Hardware uses this
  ## policy for SF accesses that do not hit regions 0..3.
  let field = tzcGroupField(groups, 2)
  regModify(TzcSecSfCtrl, 0xF'u32 shl 16, field shl 16)
  var ctrl = regRead(TzcSecSfCtrl) or (1'u32 shl 24)
  if lock:
    ctrl = ctrl or (1'u32 shl 29)
  regWrite(TzcSecSfCtrl, ctrl)

proc tzcConfigureNsecSfRegion*(region: int, startAddr, length: uint32,
                               groups: set[TzcAuthGroup], lock = false): bool =
  ## Program one non-secure serial-flash address region. LP XIP fetches can be
  ## checked by TZC_NSEC after the LP master is moved out of the secure group.
  if region < 0 or region >= 4:
    return false
  let r = region.uint32
  let field = tzcGroupField(groups, 4)
  regModify(TzcNsecSfCtrl, 0xF'u32 shl (r * 4), field shl (r * 4))
  regWrite(TzcNsecSfR0 + region.uint * 4'u, tzcPackWindow(startAddr, length, 10))

  let alignEnd = (startAddr + length + 1023'u32) and not 0x3FF'u32
  let ext = ((alignEnd shr 26) and 0x7'u32) or
            (((startAddr shr 26) and 0x7'u32) shl 3)
  let keep = regRead(TzcNsecSfRMsb) and not (0xFF'u32 shl (8'u32 * r))
  regWrite(TzcNsecSfRMsb, keep or (ext shl (8'u32 * r)))

  var ctrl = regRead(TzcNsecSfCtrl) or (1'u32 shl (20'u32 + r))
  if lock:
    ctrl = ctrl or (1'u32 shl (25'u32 + r))
  regWrite(TzcNsecSfCtrl, ctrl)
  true

proc tzcSetNsecSfRegionXGroups*(groups: set[TzcAuthGroup], lock = false) =
  ## Configure the non-secure serial-flash fallback region.
  let field = tzcGroupField(groups, 2)
  regModify(TzcNsecSfCtrl, 0xF'u32 shl 16, field shl 16)
  var ctrl = regRead(TzcNsecSfCtrl) or (1'u32 shl 24)
  if lock:
    ctrl = ctrl or (1'u32 shl 29)
  regWrite(TzcNsecSfCtrl, ctrl)

proc tzcSetNsecSfCtrlGroups*(blk: TzcSfCtrlBlock, groups: set[TzcAuthGroup],
                             lock = false) =
  ## Allow one or both auth groups to reach a non-secure SF_CTRL register group.
  var field = 0'u32
  for g in groups:
    if g.uint32 <= 1:
      field = field or (1'u32 shl g.uint32)
  let i = blk.ord.uint32
  regModify(TzcNsecSeCtrl1, 0x3'u32 shl (i * 2), field shl (i * 2))
  if lock:
    regSet(TzcNsecSeCtrl2, 1'u32 shl (i + 16))

proc tzcSetNsecSfCtrlModeTzc*(lock = false) =
  ## Route non-secure serial-flash TZSID checks through the TZC policy fields.
  regSet(TzcNsecSeCtrl1, 1'u32 shl TzcSfTzsidCtrlMode)
  if lock:
    regSet(TzcNsecSeCtrl2, 1'u32 shl TzcSfTzsidCtrlModeLock)

proc tzcSetNsecSfCtrlModeArb*(lock = false) =
  ## Route non-secure serial-flash TZSID checks through the SF arbiter source.
  regClear(TzcNsecSeCtrl1, 1'u32 shl TzcSfTzsidCtrlMode)
  if lock:
    regSet(TzcNsecSeCtrl2, 1'u32 shl TzcSfTzsidCtrlModeLock)

proc tzcSetMasterGroup*(master: TzcMaster, group: TzcAuthGroup, lock = false) =
  ## Assign a bus master to auth group 0 or 1. Always sets the per-master
  ## write-confirm bit so the assignment takes effect; locks separately.
  let m = master.ord
  if m < tzcMasterD0.ord:
    let bit = m.uint32
    var v = regRead(TzcSecBmxTzmid)
    if group == 0: v = v and not (1'u32 shl bit)
    else:          v = v or (1'u32 shl bit)
    v = v or (1'u32 shl (bit + 16))
    regWrite(TzcSecBmxTzmid, v)
    if lock: regSet(TzcSecBmxTzmidLock, 1'u32 shl bit)
  else:
    let bit = (m - tzcMasterD0.ord).uint32
    var v = regRead(TzcSecMmBmxTzmid)
    if group == 0: v = v and not (1'u32 shl bit)
    else:          v = v or (1'u32 shl bit)
    v = v or (1'u32 shl (bit + 16))
    regWrite(TzcSecMmBmxTzmid, v)
    if lock: regSet(TzcSecMmBmxTzmidLock, 1'u32 shl bit)

proc tzcSetNsecMasterGroup*(master: TzcMaster, group: TzcAuthGroup,
                            lock = false) =
  ## Assign a bus master in the non-secure TZC bank. Some paths, including LP
  ## XIP fetches, are checked by TZC_NSEC after a core leaves group 0.
  let m = master.ord
  if m < tzcMasterD0.ord:
    let bit = m.uint32
    var v = regRead(TzcNsecBmxTzmid)
    if group == 0: v = v and not (1'u32 shl bit)
    else:          v = v or (1'u32 shl bit)
    v = v or (1'u32 shl (bit + 16))
    regWrite(TzcNsecBmxTzmid, v)
    if lock: regSet(TzcNsecBmxTzmidLock, 1'u32 shl bit)
  else:
    let bit = (m - tzcMasterD0.ord).uint32
    var v = regRead(TzcNsecMmBmxTzmid)
    if group == 0: v = v and not (1'u32 shl bit)
    else:          v = v or (1'u32 shl bit)
    v = v or (1'u32 shl (bit + 16))
    regWrite(TzcNsecMmBmxTzmid, v)
    if lock: regSet(TzcNsecMmBmxTzmidLock, 1'u32 shl bit)

proc tzcSetMasterGroupAll*(master: TzcMaster, group: TzcAuthGroup,
                           lock = false) =
  ## Keep secure and non-secure TZC master tables in step.
  tzcSetMasterGroup(master, group, lock = lock)
  tzcSetNsecMasterGroup(master, group, lock = lock)

proc tzcMasterGroup*(master: TzcMaster): TzcAuthGroup =
  ## Read back a master's current auth group (for verification).
  let m = master.ord
  let (reg, bit) =
    if m < tzcMasterD0.ord: (TzcSecBmxTzmid, m.uint32)
    else: (TzcSecMmBmxTzmid, (m - tzcMasterD0.ord).uint32)
  if (regRead(reg) and (1'u32 shl bit)) != 0: 1.TzcAuthGroup else: 0.TzcAuthGroup

proc tzcSetSlaveGroup*(slave: TzcSlave, group: TzcAuthGroup, lock = false) =
  ## Assign a peripheral/slave to an auth group. The 2-bit field is a one-hot
  ## allowed-group mask; banks and lock placement follow the hardware split.
  let g = 1'u32 shl group.uint32
  let s = slave.ord
  if s >= tzcSlaveMm.ord:
    let idx = (s - tzcSlaveMm.ord).uint32
    regModify(TzcSecBmxS0, 0x3'u32 shl (idx * 2), g shl (idx * 2))
    if lock: regSet(TzcSecBmxS0, 1'u32 shl (idx + 16))
  elif s < tzcSlaveEmiMisc.ord:
    let idx = s.uint32
    regModify(TzcSecBmxS1, 0x3'u32 shl (idx * 2), g shl (idx * 2))
    if lock: regSet(TzcSecBmxSLock, 1'u32 shl idx)
  else:
    let idx = (s - tzcSlaveEmiMisc.ord).uint32
    regModify(TzcSecBmxS2, 0x3'u32 shl (idx * 2), g shl (idx * 2))
    if lock: regSet(TzcSecBmxSLock, 1'u32 shl (idx + 16))

proc tzcSetSlaveGroups*(slave: TzcSlave, groups: set[TzcAuthGroup],
                        lock = false) =
  ## Allow one or both auth groups to reach a peripheral/slave.
  var field = 0'u32
  for g in groups:
    if g.uint32 <= 1:
      field = field or (1'u32 shl g.uint32)
  let s = slave.ord
  if s >= tzcSlaveMm.ord:
    let idx = (s - tzcSlaveMm.ord).uint32
    regModify(TzcSecBmxS0, 0x3'u32 shl (idx * 2), field shl (idx * 2))
    if lock: regSet(TzcSecBmxS0, 1'u32 shl (idx + 16))
  elif s < tzcSlaveEmiMisc.ord:
    let idx = s.uint32
    regModify(TzcSecBmxS1, 0x3'u32 shl (idx * 2), field shl (idx * 2))
    if lock: regSet(TzcSecBmxSLock, 1'u32 shl idx)
  else:
    let idx = (s - tzcSlaveEmiMisc.ord).uint32
    regModify(TzcSecBmxS2, 0x3'u32 shl (idx * 2), field shl (idx * 2))
    if lock: regSet(TzcSecBmxSLock, 1'u32 shl (idx + 16))

proc tzcSlaveGroupField*(slave: TzcSlave): uint32 =
  ## Read back a slave's one-hot allowed-group field.
  let s = slave.ord
  if s >= tzcSlaveMm.ord:
    let idx = (s - tzcSlaveMm.ord).uint32
    (regRead(TzcSecBmxS0) shr (idx * 2)) and 0x3'u32
  elif s < tzcSlaveEmiMisc.ord:
    let idx = s.uint32
    (regRead(TzcSecBmxS1) shr (idx * 2)) and 0x3'u32
  else:
    let idx = (s - tzcSlaveEmiMisc.ord).uint32
    (regRead(TzcSecBmxS2) shr (idx * 2)) and 0x3'u32

proc tzcSetSeBlockGroup*(blk: TzcSeBlock, group: TzcAuthGroup, lock = false) =
  ## Restrict a SEC_ENG block (SHA/AES/TRNG/PKA/CDET/GMAC) to an auth group.
  let i = blk.ord.uint32
  regModify(TzcSecSeCtrl0, 0x3'u32 shl (i * 2), (1'u32 shl group.uint32) shl (i * 2))
  if lock: regSet(TzcSecSeCtrl2, 1'u32 shl i)

proc tzcSeBlockGroupField*(blk: TzcSeBlock): uint32 =
  ## Read back a SEC_ENG block's one-hot allowed-group field.
  let i = blk.ord.uint32
  (regRead(TzcSecSeCtrl0) shr (i * 2)) and 0x3'u32

proc tzcSetSfCtrlGroup*(blk: TzcSfCtrlBlock, group: TzcAuthGroup, lock = false) =
  ## Restrict an SF_CTRL register group to an auth group.
  let i = blk.ord.uint32
  regModify(TzcSecSeCtrl1, 0x3'u32 shl (i * 2), (1'u32 shl group.uint32) shl (i * 2))
  if lock: regSet(TzcSecSeCtrl2, 1'u32 shl (i + 16))

proc tzcSetSfCtrlGroups*(blk: TzcSfCtrlBlock, groups: set[TzcAuthGroup],
                         lock = false) =
  ## Allow one or both auth groups to reach an SF_CTRL register group.
  let i = blk.ord.uint32
  var field = 0'u32
  for g in groups:
    if g.uint32 <= 1:
      field = field or (1'u32 shl g.uint32)
  regModify(TzcSecSeCtrl1, 0x3'u32 shl (i * 2), field shl (i * 2))
  if lock: regSet(TzcSecSeCtrl2, 1'u32 shl (i + 16))

proc tzcSetSfCtrlModeTzc*(lock = false) =
  ## Route secure serial-flash TZSID checks through the TZC policy fields.
  regSet(TzcSecSeCtrl1, 1'u32 shl TzcSfTzsidCtrlMode)
  if lock:
    regSet(TzcSecSeCtrl2, 1'u32 shl TzcSfTzsidCtrlModeLock)

proc tzcSetSfCtrlModeArb*(lock = false) =
  ## Route secure serial-flash TZSID checks through the SF arbiter source.
  regClear(TzcSecSeCtrl1, 1'u32 shl TzcSfTzsidCtrlMode)
  if lock:
    regSet(TzcSecSeCtrl2, 1'u32 shl TzcSfTzsidCtrlModeLock)

proc tzcLockMasterGroups*() =
  ## Freeze all currently-assigned master groups until reset.
  regWrite(TzcSecBmxTzmidLock, 0xFFFF_FFFF'u32)
  regWrite(TzcSecMmBmxTzmidLock, 0xFFFF_FFFF'u32)
  regWrite(TzcNsecBmxTzmidLock, 0xFFFF_FFFF'u32)
  regWrite(TzcNsecMmBmxTzmidLock, 0xFFFF_FFFF'u32)

proc tzcSetSbootDone*() =
  ## Latch secure-boot-done in the ROM control register (4-bit field = 0xF).
  ## After this the boot ROM window policy is frozen.
  regModify(TzcSecRomCtrl, TzcRomSbootDoneMask, TzcRomSbootDoneMask)
