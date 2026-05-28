## BL808 PKA (Public Key Accelerator) HAL.
##
## This module provides Nim implementations of the exported PKA low-level
## command bindings and the supported high-level SEC wrappers. Target P-256
## paths drive the BL808 PKA hardware; non-target builds keep pure Nim fallbacks
## for vector tests.
##
## The PKA hardware accelerator sits at SEC_ENG_BASE + 0x300 and provides:
##   - Large number arithmetic (add, sub, mul, div, compare)
##   - Modular arithmetic (mod add/sub/mul/sqr/exp/inv/rem)
##   - Montgomery domain conversions (GF↔Montgomery)
##   - ECDSA sign/verify (secp256r1)
##   - ECDH key exchange (secp256r1)
##   - DSA sign/verify (RSA)
##
## PKA register offsets from device base:
##   0x300 = PKA_CTRL_0 (control/status)
##   0x340 = PKA_RW (command word / data read-write)
##   0x360 = PKA_RW_BURST (burst access)
##
## PKA command word format at PKA_RW (offset 0x340):
##   [31:24] = opcode
##   [23:20] = source0 register index
##   [19:12] = source1/dest register index (depends on op)
##   [11:8]  = register size code
##   [7:0]   = additional params (data count, etc.)

import mmio, memmap
from std/volatile import volatileStore
when defined(bl808m0):
  import irq

# =============================================================================
# PKA opcodes (from bflb_sec_pka.h)
# =============================================================================
const
  PkaOpLmod2n*    = 0x11'u32
  PkaOpLdiv2n*    = 0x12'u32
  PkaOpLmul2n*    = 0x13'u32
  PkaOpLdiv*      = 0x14'u32
  PkaOpLsqr*      = 0x15'u32
  PkaOpLmul*      = 0x16'u32
  PkaOpLsub*      = 0x17'u32
  PkaOpLadd*      = 0x18'u32
  PkaOpLcmp*      = 0x19'u32
  PkaOpMdiv2*     = 0x21'u32
  PkaOpMinv*      = 0x22'u32
  PkaOpMexp*      = 0x23'u32
  PkaOpMsqr*      = 0x24'u32
  PkaOpMmul*      = 0x25'u32
  PkaOpMrem*      = 0x26'u32
  PkaOpMsub*      = 0x27'u32
  PkaOpMadd*      = 0x28'u32
  PkaOpResize*    = 0x31'u32
  PkaOpMovdat*    = 0x32'u32
  PkaOpNlir*      = 0x33'u32
  PkaOpSlir*      = 0x34'u32
  PkaOpClir*      = 0x35'u32
  PkaOpCfliriBuffer* = 0x36'u32
  PkaOpCtliriPld* = 0x37'u32
  PkaOpCflirBuffer* = 0x38'u32
  PkaOpWrite*     = 0x39'u32  # Write data to PKA memory
  PkaOpRead*      = 0xB8'u32  # Read data from PKA memory (bit31 set)

# =============================================================================
# PKA register sizes
# =============================================================================
const
  PkaRegSize8*    = 1'u8
  PkaRegSize16*   = 2'u8
  PkaRegSize32*   = 3'u8
  PkaRegSize64*   = 4'u8
  PkaRegSize96*   = 5'u8
  PkaRegSize128*  = 6'u8
  PkaRegSize192*  = 7'u8
  PkaRegSize256*  = 8'u8
  PkaRegSize384*  = 9'u8
  PkaRegSize512*  = 10'u8

# Size in 32-bit words for each PKA register size code. The SDK names these
# by byte capacity: REG_SIZE_32 is a 32-byte register, not a 32-bit register.
const pkaSizeWords: array[11, uint16] = [0, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128]

# =============================================================================
# PKA register offsets from device base
# =============================================================================
const
  PkaCtrl0Offset  = 0x300'u  # PKA_CTRL_0
  PkaRwOffset     = 0x340'u  # PKA_RW (command/data)
  PkaCtrlDoneStatus = 1'u32 shl 0
  PkaCtrlDoneClear = 1'u32 shl 1
  PkaCtrlEnable   = 1'u32 shl 3
  PkaCtrlIntStatus = 1'u32 shl 8
  PkaCtrlIntClear = 1'u32 shl 9
  PkaCtrlIntMask  = 1'u32 shl 11
  PkaCtrlEndianBig = 1'u32 shl 12

const
  EccTrngCtrl = SecEngBase + 0x200'u
  EccTrngData = SecEngBase + 0x208'u
  EccTrngCtrl3 = SecEngBase + 0x234'u
  EccTrngCtrlProt = SecEngBase + 0x2FC'u
  EccSecCtrlProtRead = SecEngBase + 0xF00'u
  EccTrngBusy = 1'u32 shl 0
  EccTrngTrigger = 1'u32 shl 1
  EccTrngEnable = 1'u32 shl 2
  EccTrngDataClear = 1'u32 shl 3
  EccTrngIntClear = 1'u32 shl 9
  EccTrngIntMask = 1'u32 shl 11
  EccTrngRoscEnable = 1'u32 shl 31
  EccTrngGroupOwnerShift = 4
  EccTrngGroupOwnerMask = 0x03'u32
  EccTrngGroup0Owner = 0x01'u32
  EccTrngReleasedOwner = 0x03'u32
  EccTrngRequestGroup0 = 0x02'u32
  EccTrngReleaseAccess = 0x06'u32
  EccTrngTimeout = 100_000'u32

# =============================================================================
# Device struct (matches bflb_device_s layout)
# =============================================================================
type
  BflbDevice* {.exportc: "bflb_device_s".} = object
    name*: cstring
    regBase*: uint32  # At offset 4 from struct start

when defined(BleDebugCounters) or defined(bl808PkaDebug):
  var nim_pka_debug_stage* {.exportc.}: uint32
  var nim_pka_debug_ctrl* {.exportc.}: uint32

  proc pkaDebugMark(base: uint, stage: uint32) {.inline.} =
    volatileStore(addr nim_pka_debug_stage, stage)
    volatileStore(addr nim_pka_debug_ctrl, regRead(base + PkaCtrl0Offset))
else:
  proc pkaDebugMark(base: uint, stage: uint32) {.inline.} =
    discard base
    discard stage

when defined(bl808PkaDebug):
  var nim_pka_verify_stage* {.exportc.}: uint32
  var nim_pka_verify_xmod* {.exportc.}: array[8, uint32]
  var nim_pka_verify_u1* {.exportc.}: array[8, uint32]
  var nim_pka_verify_u2* {.exportc.}: array[8, uint32]
  var nim_pka_verify_w* {.exportc.}: array[8, uint32]

# =============================================================================
# Internal helpers
# =============================================================================
proc quiesceSecEngPollingIrqs() =
  ## PKA/TRNG operations are polled in this HAL, so their SEC interrupt
  ## sources and shared CLIC lines must be left masked and non-pending.
  when defined(bl808m0):
    irqDisable(IrqM0SecEng1)
    irqDisable(IrqM0SecEng0)
    irqDisable(IrqM0SecEngCdet1)
    irqDisable(IrqM0SecEngCdet0)
    irqClearPending(IrqM0SecEng1)
    irqClearPending(IrqM0SecEng0)
    irqClearPending(IrqM0SecEngCdet1)
    irqClearPending(IrqM0SecEngCdet0)

proc pkaBase(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase

proc pkaCtrl0(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase + PkaCtrl0Offset

proc pkaRw(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase + PkaRwOffset

proc pkaClearInt(base: uint) =
  pkaDebugMark(base, 0x00000010'u32)
  quiesceSecEngPollingIrqs()
  let ctrl = base + PkaCtrl0Offset
  var v = regRead(ctrl)
  v = v or PkaCtrlIntClear
  regWrite(ctrl, v)
  v = regRead(ctrl)
  v = v and not PkaCtrlIntClear
  regWrite(ctrl, v)
  quiesceSecEngPollingIrqs()

proc pkaReadMtimeUs(): uint64 =
  when defined(bl808d0):
    const base = D0ClintMtimeBase
  else:
    const base = ClicMtimeBase
  var hi1 = regRead(base + 4)
  var lo = regRead(base)
  var hi2 = regRead(base + 4)
  while hi1 != hi2:
    hi1 = hi2
    lo = regRead(base)
    hi2 = regRead(base + 4)
  (hi2.uint64 shl 32) or lo.uint64

proc pkaWaitIsr(base: uint) =
  let start = pkaReadMtimeUs()
  while pkaReadMtimeUs() - start <= 100_000'u64:
    let v = regRead(base + PkaCtrl0Offset)
    if (v and PkaCtrlIntStatus) != 0:
      return

proc pkaWaitAndClear(base: uint) =
  pkaDebugMark(base, 0x00000020'u32)
  pkaWaitIsr(base)
  pkaDebugMark(base, 0x00000021'u32)
  pkaClearInt(base)

proc pkaWriteFirstConfig(base: uint, opcode: uint32, s0Idx: uint8,
                         s0Size: uint8, dIdx: uint8, dSize: uint8,
                         lastop: uint8) =
  ## Build and write the first operand config to PKA_RW.
  var cmd = (opcode shl 24) or
            (lastop.uint32 shl 31) or
            (dSize.uint32 shl 20) or
            s0Idx.uint32 or
            (dIdx.uint32 shl 12) or
            (s0Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, cmd)

# =============================================================================
# PKA low-level operations (46 exported functions matching blob symbols)
# =============================================================================

proc bflb_pka_init*(dev: ptr BflbDevice) {.exportc, cdecl.} =
  ## Initialize PKA hardware.
  let base = dev.regBase
  pkaDebugMark(base, 0x00000100'u32)
  regWrite(base + PkaCtrl0Offset, 0)
  regWrite(base + PkaCtrl0Offset, PkaCtrlEnable or PkaCtrlIntMask)
  pkaClearInt(base)
  var v = regRead(base + PkaCtrl0Offset)
  v = v or PkaCtrlEndianBig or PkaCtrlIntMask
  regWrite(base + PkaCtrl0Offset, v)
  pkaDebugMark(base, 0x00000101'u32)

proc bflb_pka_deinit*(dev: ptr BflbDevice) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaClearInt(base)
  regWrite(base + PkaCtrl0Offset, PkaCtrlIntMask)
  pkaClearInt(base)

proc bflb_pka_write*(dev: ptr BflbDevice, regindex: uint8, regsize: uint8,
                     data: ptr uint32, size: uint16, lastop: uint8) {.exportc, cdecl.} =
  ## Write data words to a PKA register.
  let base = dev.regBase
  let sizeCode = if regsize > 0 and regsize <= 10: pkaSizeWords[regsize] else: 0'u16

  # Build write command
  var cmd = (PkaOpWrite shl 24) or
            (regsize.uint32 shl 20) or
            size.uint32 or
            (regindex.uint32 shl 12)
  if lastop != 0:
    cmd = cmd or (1'u32 shl 31)
  regWrite(base + PkaRwOffset, cmd)

  # Write data words
  let rw = base + PkaRwOffset
  let count = min(size, sizeCode)
  for i in 0'u16 ..< count:
    let word = cast[ptr UncheckedArray[uint32]](data)[i]
    regWrite(rw, word)

proc bflb_pka_read*(dev: ptr BflbDevice, regindex: uint8, regsize: uint8,
                    data: ptr uint32, size: uint16) {.exportc, cdecl.} =
  ## Read data words from a PKA register.
  let base = dev.regBase
  let sizeCode = if regsize > 0 and regsize <= 10: pkaSizeWords[regsize] else: 0'u16

  if size > sizeCode: return

  # Build read command
  var cmd = (PkaOpRead shl 24) or
            (regsize.uint32 shl 20) or
            size.uint32 or
            (regindex.uint32 shl 12)
  regWrite(base + PkaRwOffset, cmd)
  regWrite(base + PkaRwOffset, 0)  # Trigger read

  pkaWaitAndClear(base)

  # Read data words
  let rw = base + PkaRwOffset
  let dataArr = cast[ptr UncheckedArray[uint32]](data)
  for i in 0'u16 ..< size:
    dataArr[i] = regRead(rw)

# --- Shift operations ---

proc bflb_pka_lmod2n*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      bitShift: uint16, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLmod2n, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, bitShift.uint32)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_ldiv2n*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      bitShift: uint16, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLdiv2n, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, bitShift.uint32)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_lmul2n*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      bitShift: uint16, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLmul2n, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, bitShift.uint32)
  if lastop != 0:
    pkaWaitAndClear(base)

# --- Two-operand large arithmetic ---

proc bflb_pka_ladd*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLadd, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_lsub*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLsub, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_lmul*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLmul, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_lsqr*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLsqr, s0Idx, s0Size, dIdx, dSize, lastop)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_ldiv*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLdiv, s0Idx, s0Size, dIdx, dSize, lastop)
  let s2Cmd = (s2Idx.uint32 shl 12) or (s2Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_lcmp*(dev: ptr BflbDevice, s0Idx, s0Size: uint8,
                    s1Idx, s1Size: uint8): uint8 {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLcmp, s0Idx, s0Size, 0, 0, 1)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  pkaWaitAndClear(base)
  # Read comparison result from status register
  let status = regRead(base + PkaCtrl0Offset)
  ((status shr 24) and 0x01).uint8

# --- Modular arithmetic ---

proc bflb_pka_madd*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMadd, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_msub*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMsub, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_mmul*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMmul, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_msqr*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMsqr, s0Idx, s0Size, dIdx, dSize, lastop)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_mrem*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMrem, s0Idx, s0Size, dIdx, dSize, lastop)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_minv*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMinv, s0Idx, s0Size, dIdx, dSize, lastop)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_mexp*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMexp, s0Idx, s0Size, dIdx, dSize, lastop)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaWaitAndClear(base)

# --- Register management ---

proc bflb_pka_regsize*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                       lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpResize, s0Idx, s0Size, dIdx, dSize, lastop)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_movdat*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMovdat, s0Idx, s0Size, dIdx, dSize, lastop)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_nlir*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpNlir, s0Idx, s0Size, dIdx, dSize, lastop)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_slir*(dev: ptr BflbDevice, regindex, regsize: uint8,
                    data: uint32, lastop: uint8) {.exportc, cdecl.} =
  ## Write a single immediate value to a PKA register.
  let base = dev.regBase
  let cmd = (PkaOpSlir shl 24) or
            ((if lastop != 0: 1'u32 else: 0'u32) shl 31) or
            (regsize.uint32 shl 20) or
            (regindex.uint32 shl 12)
  regWrite(base + PkaRwOffset, cmd)
  regWrite(base + PkaRwOffset, data)
  if lastop != 0:
    pkaWaitAndClear(base)

proc bflb_pka_clir*(dev: ptr BflbDevice, regindex, regsize: uint8,
                    size: uint16, lastop: uint8) {.exportc, cdecl.} =
  ## Clear a PKA register.
  let base = dev.regBase
  var cmd = (regsize.uint32 shl 20) or size.uint32 or
            (regindex.uint32 shl 12) or 0xB500_0000'u32
  regWrite(base + PkaRwOffset, cmd)
  regWrite(base + PkaRwOffset, 0)  # Trigger
  if lastop != 0:
    pkaWaitAndClear(base)

# --- Montgomery domain conversions ---

proc bflb_pka_gf2mont*(dev: ptr BflbDevice,
                       sIdx, sSize, dIdx, dSize: uint8,
                       tIdx, tSize, pIdx, pSize: uint8,
                       bitShift: uint32) {.exportc, cdecl.} =
  ## Convert from GF (normal) to Montgomery domain.
  ## Steps: t = s * 2^bitShift mod p, then d = t.
  bflb_pka_lmul2n(dev, sIdx, sSize, tIdx, tSize,
                  bitShift.uint16, 0)
  bflb_pka_mrem(dev, tIdx, tSize, dIdx, dSize,
                pIdx, pSize, 1)

proc bflb_pka_mont2gf*(dev: ptr BflbDevice,
                       sIdx, sSize, dIdx, dSize: uint8,
                       invrIdx, invrSize: uint8,
                       tIdx, tSize, pIdx, pSize: uint8) {.exportc, cdecl.} =
  ## Convert from Montgomery domain to GF (normal).
  ## The SDK performs a full-width multiply by R^-1 followed by reduction.
  bflb_pka_lmul(dev, sIdx, sSize, tIdx, tSize, invrIdx, invrSize, 0)
  bflb_pka_mrem(dev, tIdx, tSize, dIdx, dSize, pIdx, pSize, 1)

# =============================================================================
# ECC helper types and constants (for ECDSA/ECDH)
# =============================================================================
type
  BflbEcdsa* {.exportc: "bflb_ecdsa_s".} = object
    ecpId*: uint8
    pad: array[3, uint8]
    privateKey*: ptr uint32
    publicKeyx*: ptr uint32
    publicKeyy*: ptr uint32

  BflbEcdh* {.exportc: "bflb_ecdh_s".} = object
    ecpId*: uint8

  BflbDsaCrt* {.exportc: "bflb_dsa_crt_s".} = object
    dP*, dQ*, qInv*, p*, invRp*, primeNp*: ptr uint32
    q*, invRq*, primeNq*: ptr uint32

  BflbDsa* {.exportc: "bflb_dsa_s".} = object
    size*: uint32
    crtSize*: uint32
    n*, e*, d*: ptr uint32
    crtCfg*: BflbDsaCrt

const
  EcpSecp256r1* = 0'u8
  EcpSecp256k1* = 1'u8
  EcpSecp384r1* = 2'u8

# =============================================================================
# secp256r1 curve constants (NIST P-256)
# =============================================================================
const secp256r1P* {.exportc.}: array[8, uint32] = [
  0xFFFFFFFF'u32, 0x01000000'u32, 0x00000000'u32, 0x00000000'u32,
  0x00000000'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32
]
const secp256r1N* {.exportc.}: array[8, uint32] = [
  0xFFFFFFFF'u32, 0x00000000'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
  0xADFAE6BC'u32, 0x849E17A7'u32, 0xC2CAB9F3'u32, 0x512563FC'u32
]
const secp256r1Gx* {.exportc.}: array[8, uint32] = [
  0xF2D1176B'u32, 0x47422CE1'u32, 0xE5E6BCF8'u32, 0xF240A463'u32,
  0x817D0377'u32, 0xA033EB2D'u32, 0x4539A1F4'u32, 0x96C298D8'u32
]
const secp256r1Gy* {.exportc.}: array[8, uint32] = [
  0xE242E34F'u32, 0x9B7F1AFE'u32, 0x4AEBE78E'u32, 0x169E0F7C'u32,
  0x5733CE2B'u32, 0xCE5E316B'u32, 0x6840B6CB'u32, 0xF551BF37'u32
]
const secp256r1B* {.exportc.}: array[8, uint32] = [
  0xD835C65A'u32, 0xE7933AAA'u32, 0x55BDEBB3'u32, 0xBC869876'u32,
  0xB0061D65'u32, 0xF6B053CC'u32, 0x3E3CCE3B'u32, 0x4B60D227'u32
]

# Montgomery inverse R for P and N (precomputed)
const secp256r1InvR_P* {.exportc.}: array[8, uint32] = [
  0xFEFFFFFF'u32, 0x03000000'u32, 0xFDFFFFFF'u32, 0x02000000'u32,
  0x01000000'u32, 0xFEFFFFFF'u32, 0x03000000'u32, 0x00000000'u32
]
const secp256r1InvR_N* {.exportc.}: array[8, uint32] = [
  0x3366D060'u32, 0xE9C10549'u32, 0x04B6F807'u32, 0x2577601E'u32,
  0xE2F3DEBA'u32, 0xAF6F5643'u32, 0xF7C81BCE'u32, 0x797C199C'u32
]
const secp256r1PrimeN_P* {.exportc.}: array[8, uint32] = [
  0xFFFFFFFF'u32, 0x02000000'u32, 0x00000000'u32, 0x00000000'u32,
  0x01000000'u32, 0x00000000'u32, 0x00000000'u32, 0x01000000'u32
]
const secp256r1PrimeN_N* {.exportc.}: array[8, uint32] = [
  0x3366D060'u32, 0x1C28D6A9'u32, 0xEC77FE50'u32, 0xF6C688C5'u32,
  0x0844C948'u32, 0xE4D2747D'u32, 0xAAC8D1CC'u32, 0x4FBC00EE'u32
]

const
  secp256r1One: array[8, uint32] = [
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x01000000'u32
  ]
  secp256r1Bar2: array[8, uint32] = [
    0x01000000'u32, 0xFDFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFEFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x02000000'u32
  ]
  secp256r1Bar3: array[8, uint32] = [
    0x02000000'u32, 0xFCFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFDFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x03000000'u32
  ]
  secp256r1Bar4: array[8, uint32] = [
    0x03000000'u32, 0xFBFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFCFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x04000000'u32
  ]
  secp256r1Bar8: array[8, uint32] = [
    0x07000000'u32, 0xF7FFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xF8FFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x08000000'u32
  ]
  secp256r1OneP1: array[8, uint32] = [
    0x00000000'u32, 0xFEFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFFFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x02000000'u32
  ]
  secp256r1OneM1: array[8, uint32] = [
    0x00000000'u32, 0xFEFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFFFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32
  ]
  secp256r1ZeroX: array[8, uint32] = [
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32
  ]
  secp256r1ZeroY: array[8, uint32] = [
    0x00000000'u32, 0xFEFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32,
    0xFFFFFFFF'u32, 0x00000000'u32, 0x00000000'u32, 0x01000000'u32
  ]

# =============================================================================
# ECDSA / ECDH / DSA high-level exports
# (These compose the low-level PKA operations above for ECC math)
# =============================================================================

proc eccCmpWords(a, b: ptr uint32, size: uint32): cint =
  let arrA = cast[ptr UncheckedArray[uint32]](a)
  let arrB = cast[ptr UncheckedArray[uint32]](b)
  for i in countdown(size.int - 1, 0):
    if arrA[i] > arrB[i]: return 1
    if arrA[i] < arrB[i]: return -1
  0

proc eccCmpBeBytes(a, b: ptr uint8, len: uint32): cint =
  if a == nil or b == nil:
    return 0
  let aa = cast[ptr UncheckedArray[uint8]](a)
  let bb = cast[ptr UncheckedArray[uint8]](b)
  var i = 0'u32
  while i < len and aa[i] == 0:
    i.inc
  var j = 0'u32
  while j < len and bb[j] == 0:
    j.inc
  if i == len and j == len:
    return 0
  if i > j:
    return -1
  if j > i:
    return 1
  while i < len:
    if aa[i] > bb[i]:
      return 1
    if aa[i] < bb[i]:
      return -1
    i.inc
  0

proc eccIsZeroBytes(a: ptr uint8, len: uint32): bool =
  if a == nil:
    return true
  let bytes = cast[ptr UncheckedArray[uint8]](a)
  for i in 0 ..< len.int:
    if bytes[i] != 0:
      return false
  true

proc copyWords(dst, src: ptr uint32, words: uint32) =
  let dd = cast[ptr UncheckedArray[uint32]](dst)
  let ss = cast[ptr UncheckedArray[uint32]](src)
  for i in 0 ..< words.int:
    dd[i] = ss[i]

proc eccTrngNopDelay() {.inline.} =
  {.emit: """
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
  """.}

proc eccTrngOwner(): uint32 {.inline.} =
  (regRead(EccSecCtrlProtRead) shr EccTrngGroupOwnerShift) and
    EccTrngGroupOwnerMask

proc eccRequestTrngGroup0(releaseWhenDone: var bool): bool =
  releaseWhenDone = false
  case eccTrngOwner()
  of EccTrngGroup0Owner:
    true
  of EccTrngReleasedOwner:
    regWrite(EccTrngCtrlProt, EccTrngRequestGroup0)
    if eccTrngOwner() == EccTrngGroup0Owner:
      releaseWhenDone = true
      true
    else:
      false
  else:
    false

proc eccReleaseTrngGroup0(releaseWhenDone: bool) =
  if releaseWhenDone:
    regWrite(EccTrngCtrlProt, EccTrngReleaseAccess)

proc eccTrngClearInterrupt() =
  quiesceSecEngPollingIrqs()
  var v = regRead(EccTrngCtrl) or EccTrngIntMask
  regWrite(EccTrngCtrl, v or EccTrngIntClear)
  v = regRead(EccTrngCtrl) or EccTrngIntMask
  regWrite(EccTrngCtrl, v and not EccTrngIntClear)
  quiesceSecEngPollingIrqs()

proc eccTrngWaitIdle(): bool =
  var timeout = EccTrngTimeout
  while (regRead(EccTrngCtrl) and EccTrngBusy) != 0'u32:
    if timeout == 0'u32:
      return false
    dec timeout
  true

proc eccTrngDisable() =
  regWrite(EccTrngCtrl, (regRead(EccTrngCtrl) and not EccTrngEnable) or
                        EccTrngIntMask)
  eccTrngClearInterrupt()

proc eccTrngReadBlock(dst: ptr uint8): bool =
  if dst == nil:
    return false

  regWrite(EccTrngCtrl3, regRead(EccTrngCtrl3) or EccTrngRoscEnable)
  regWrite(EccTrngCtrl, regRead(EccTrngCtrl) or EccTrngEnable or
                         EccTrngIntMask)
  eccTrngClearInterrupt()
  eccTrngNopDelay()
  if not eccTrngWaitIdle():
    eccTrngDisable()
    return false

  eccTrngClearInterrupt()
  regWrite(EccTrngCtrl, regRead(EccTrngCtrl) or EccTrngTrigger or
                         EccTrngIntMask)
  eccTrngNopDelay()
  if not eccTrngWaitIdle():
    eccTrngDisable()
    return false

  let outp = cast[ptr UncheckedArray[uint8]](dst)
  var nonZero = false
  for wordIndex in 0 ..< 8:
    let word = regRead(EccTrngData + wordIndex.uint * 4)
    if word != 0'u32:
      nonZero = true
    for byteIndex in 0 ..< 4:
      outp[wordIndex * 4 + byteIndex] =
        uint8((word shr (byteIndex * 8)) and 0xFF'u32)

  regWrite(EccTrngCtrl, (regRead(EccTrngCtrl) and not EccTrngTrigger) or
                        EccTrngIntMask)
  regWrite(EccTrngCtrl, regRead(EccTrngCtrl) or EccTrngDataClear or
                         EccTrngIntMask)
  regWrite(EccTrngCtrl, (regRead(EccTrngCtrl) and not EccTrngDataClear) or
                        EccTrngIntMask)
  eccTrngDisable()
  nonZero

proc bflb_sec_ecc_get_random_value*(data: ptr uint32, maxRef: ptr uint32,
                                    size: uint32): cint {.exportc, cdecl.} =
  ## Get a big-endian byte string less than maxRef using TRNG.
  if data == nil or size == 0:
    return -1

  var releaseTrng = false
  if not eccRequestTrngGroup0(releaseTrng):
    return -1

  let dataBytes = cast[ptr UncheckedArray[uint8]](data)
  var trngBlock: array[32, uint8]
  var tries = 100
  while tries > 0:
    var offset = 0'u32
    while offset < size:
      if not eccTrngReadBlock(addr trngBlock[0]):
        eccReleaseTrngGroup0(releaseTrng)
        return -1
      var blockIndex = 0'u32
      while blockIndex < trngBlock.len.uint32 and offset < size:
        dataBytes[offset] = trngBlock[blockIndex.int]
        offset.inc
        blockIndex.inc

    if maxRef == nil or
        eccCmpBeBytes(cast[ptr uint8](maxRef), cast[ptr uint8](data), size) > 0:
      eccReleaseTrngGroup0(releaseTrng)
      return 0
    tries.dec
  eccReleaseTrngGroup0(releaseTrng)
  -1

proc bflb_sec_ecc_cmp*(a, b: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
  eccCmpWords(a, b, size)

proc bflb_sec_ecc_is_zero*(a: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
  if a == nil:
    return 1
  let arr = cast[ptr UncheckedArray[uint32]](a)
  for i in 0 ..< size.int:
    if arr[i] != 0: return 0
  1

proc pkaRegSizeForBits(bits: uint32): uint8 =
  if bits <= 64: PkaRegSize8
  elif bits <= 128: PkaRegSize16
  elif bits <= 256: PkaRegSize32
  elif bits <= 512: PkaRegSize64
  elif bits <= 768: PkaRegSize96
  elif bits <= 1024: PkaRegSize128
  elif bits <= 1536: PkaRegSize192
  elif bits <= 2048: PkaRegSize256
  elif bits <= 3072: PkaRegSize384
  else: PkaRegSize512

proc wordLenForBits(bits: uint32): uint16 =
  ((bits + 31'u32) shr 5).uint16

proc isSupportedEcpId(ecpId: uint8): bool {.inline.} =
  ecpId == EcpSecp256r1

const DsaMaxWords = 64
type DsaWordArray = array[DsaMaxWords, uint32]

proc dsaLoad(dst: var DsaWordArray, src: ptr uint32, words: uint16) =
  let srcWords = cast[ptr UncheckedArray[uint32]](src)
  for i in 0 ..< words.int:
    dst[i] = srcWords[i]

proc dsaLoadPadded(dst: var DsaWordArray, src: ptr uint32,
                   srcWordsLen: uint32, words: uint16) =
  let srcWords = cast[ptr UncheckedArray[uint32]](src)
  let count = min(srcWordsLen, words.uint32)
  for i in 0 ..< count.int:
    dst[i] = srcWords[i]

proc dsaStore(dst: ptr uint32, src: DsaWordArray, words: uint16) =
  let dstWords = cast[ptr UncheckedArray[uint32]](dst)
  for i in 0 ..< words.int:
    dstWords[i] = src[i]

proc dsaCmp(a, b: DsaWordArray, words: uint16): cint =
  for i in countdown(words.int - 1, 0):
    if a[i] > b[i]: return 1
    if a[i] < b[i]: return -1
  0

proc dsaIsZero(a: DsaWordArray, words: uint16): bool =
  for i in 0 ..< words.int:
    if a[i] != 0:
      return false
  true

proc dsaSubInPlace(a: var DsaWordArray, b: DsaWordArray, words: uint16) =
  var borrow = 0'u64
  for i in 0 ..< words.int:
    let lhs = a[i].uint64
    let rhs = b[i].uint64 + borrow
    if lhs >= rhs:
      a[i] = (lhs - rhs).uint32
      borrow = 0
    else:
      a[i] = ((1'u64 shl 32) + lhs - rhs).uint32
      borrow = 1

proc dsaReduce(a: var DsaWordArray, modulus: DsaWordArray, words: uint16) =
  while dsaCmp(a, modulus, words) >= 0:
    dsaSubInPlace(a, modulus, words)

proc dsaAddMod(dst: var DsaWordArray, a, b, modulus: DsaWordArray, words: uint16) =
  var carry = 0'u64
  for i in 0 ..< words.int:
    let sum = a[i].uint64 + b[i].uint64 + carry
    dst[i] = sum.uint32
    carry = sum shr 32
  if carry != 0 or dsaCmp(dst, modulus, words) >= 0:
    dsaSubInPlace(dst, modulus, words)

proc dsaMulMod(dst: var DsaWordArray, a, b, modulus: DsaWordArray, words: uint16) =
  var accum: DsaWordArray
  var term = a
  dsaReduce(term, modulus, words)
  for bit in 0 ..< (words.int * 32):
    if ((b[bit shr 5] shr (bit and 31)) and 1'u32) != 0:
      dsaAddMod(accum, accum, term, modulus, words)
    dsaAddMod(term, term, term, modulus, words)
  dst = accum

proc dsaExpMod(dst: var DsaWordArray, base, exponent, modulus: DsaWordArray,
               words: uint16) =
  var resultWords: DsaWordArray
  var power = base
  resultWords[0] = 1
  dsaReduce(resultWords, modulus, words)
  dsaReduce(power, modulus, words)
  for bit in 0 ..< (words.int * 32):
    if ((exponent[bit shr 5] shr (bit and 31)) and 1'u32) != 0:
      dsaMulMod(resultWords, resultWords, power, modulus, words)
    dsaMulMod(power, power, power, modulus, words)
  dst = resultWords

proc bflb_sec_ecdsa_init*(handle: ptr BflbEcdsa, id: uint8): cint {.exportc, cdecl.} =
  if handle == nil or not isSupportedEcpId(id):
    return -1
  handle.ecpId = id
  handle.privateKey = nil
  handle.publicKeyx = nil
  handle.publicKeyy = nil
  0

proc bflb_sec_ecdsa_deinit*(handle: ptr BflbEcdsa): cint {.exportc, cdecl.} =
  if handle == nil:
    return -1
  handle.privateKey = nil
  handle.publicKeyx = nil
  handle.publicKeyy = nil
  0

proc bflb_sec_ecdh_init*(handle: ptr BflbEcdh, id: uint8): cint {.exportc, cdecl.} =
  if handle == nil or not isSupportedEcpId(id):
    return -1
  handle.ecpId = id
  0

proc bflb_sec_ecdh_deinit*(handle: ptr BflbEcdh): cint {.exportc, cdecl.} =
  if handle == nil:
    return -1
  0

proc bflb_sec_dsa_init*(handle: ptr BflbDsa, size: uint32): cint {.exportc, cdecl.} =
  if handle == nil or size == 0 or size > DsaMaxWords.uint32 * 32'u32:
    return -1
  handle.size = size
  handle.crtSize = 0
  handle.n = nil
  handle.e = nil
  handle.d = nil
  handle.crtCfg = default(BflbDsaCrt)
  0

# =============================================================================
# ECC point multiplication using PKA hardware
#
# PKA register allocation (from blob disassembly):
#   Reg 0 (size 8): scalar k / temporary
#   Reg 1 (size 8): temporary
#   Reg 2 (size 8): result X / temp (double-size for mul results)
#   Reg 3 (size 8): result Y / temp
#   Reg 4 (size 8): result Z / temp
#   Reg 5-7 (size 8): temporaries
#   Reg 8 (size 8): point Px / Gx
#   Reg 9 (size 8): point Py / Gy
#   Reg 10 (size 8): curve prime p
#   Reg 11 (size 8): curve order n
#   Reg 12 (size 8): invR_P (Montgomery parameter)
#   Reg 13 (size 8): primeN_P (Montgomery parameter)
#   Reg 14 (size 8): invR_N
#   Reg 15 (size 8): primeN_N
#   Reg 19 (size 8): temporary for point ops
#
# All modular operations use p (reg 10) as modulus for point arithmetic,
# and n (reg 11) as modulus for scalar arithmetic.
# =============================================================================

# PKA register indices for ECC
const
  R_K     = 0'u8   # scalar
  R_TMP1  = 1'u8   # temporary
  R_RX    = 2'u8   # result X
  R_RY    = 3'u8   # result Y
  R_RZ    = 4'u8   # result Z (Jacobian)
  R_TMP5  = 5'u8
  R_TMP6  = 6'u8
  R_TMP7  = 7'u8
  R_PX    = 8'u8   # input point X
  R_PY    = 9'u8   # input point Y
  R_P     = 20'u8  # curve prime; PKA expects primeN at modulus + 1
  R_PRIMN = 21'u8  # primeN for P
  R_INVR  = 22'u8  # invR mod P
  R_N     = 23'u8  # curve order; PKA expects primeN_N at modulus + 1
  R_PRIMN_N = 24'u8
  R_INVR_N = 25'u8
  R_TMP19 = 19'u8
  SZ      = PkaRegSize32

# Global PKA device (matches blob's `pka` global variable).
#
# Firmware jumps straight to main(), so Nim module init procs are not run.
# Define the compatible global in C so the pointer is valid in .data before
# high-level wrappers or external C code read it.
{.emit: """
__attribute__((used)) bflb_device_s bl808_hal_default_pka_device = {0, 0x20004000U};
__attribute__((used)) bflb_device_s *pka = &bl808_hal_default_pka_device;
""".}
var pka* {.importc.}: ptr BflbDevice

proc getP256CurveParams(): (ptr uint32, ptr uint32, ptr uint32,
                            ptr uint32, ptr uint32,
                            ptr uint32, ptr uint32,
                            ptr uint32, ptr uint32, uint32) =
  ## Returns (P, N, Gx, Gy, B, invR_P, primeN_P, invR_N, primeN_N, wordSize)
  (addr secp256r1P[0], addr secp256r1N[0],
   addr secp256r1Gx[0], addr secp256r1Gy[0], addr secp256r1B[0],
   addr secp256r1InvR_P[0], addr secp256r1PrimeN_P[0],
   addr secp256r1InvR_N[0], addr secp256r1PrimeN_N[0], 8'u32)

proc eccLoadCurveParams(dev: ptr BflbDevice, ecpId: uint8) =
  ## Load curve constants into PKA registers.
  if not isSupportedEcpId(ecpId):
    return
  let (cp, cn, cgx, cgy, cb, cinvr, cprimn, cinvrn, cprimnn, ws) =
    getP256CurveParams()
  bflb_pka_write(dev, R_P, SZ, cp, ws.uint16, 0)
  bflb_pka_write(dev, R_PRIMN, SZ, cprimn, ws.uint16, 0)
  bflb_pka_write(dev, R_INVR, SZ, cinvr, ws.uint16, 0)
  bflb_pka_write(dev, R_N, SZ, cn, ws.uint16, 0)
  bflb_pka_write(dev, R_PRIMN_N, SZ, cprimnn, ws.uint16, 0)
  bflb_pka_write(dev, R_INVR_N, SZ, cinvrn, ws.uint16, 0)
  bflb_pka_write(dev, R_PX, SZ, cgx, ws.uint16, 0)
  bflb_pka_write(dev, R_PY, SZ, cgy, ws.uint16, 0)

proc eccPointDouble(dev: ptr BflbDevice) =
  ## Point doubling in Jacobian coords: (RX,RY,RZ) = 2*(RX,RY,RZ) mod P.
  ## Uses PKA modular arithmetic with P in reg 10.
  # T1 = RZ^2 mod P
  bflb_pka_msqr(dev, R_RZ, SZ, R_TMP1, SZ, R_P, SZ, 0)
  # T5 = RX - T1 mod P
  bflb_pka_msub(dev, R_RX, SZ, R_TMP5, SZ, R_TMP1, SZ, R_P, SZ, 0)
  # T1 = RX + T1 mod P
  bflb_pka_madd(dev, R_RX, SZ, R_TMP1, SZ, R_TMP1, SZ, R_P, SZ, 0)
  # T5 = T5 * T1 mod P (= X^2 - Z^4)
  bflb_pka_mmul(dev, R_TMP5, SZ, R_TMP5, SZ, R_TMP1, SZ, R_P, SZ, 0)
  # M = 3 * T5 mod P (= 3*(X^2 - Z^4) for a=-3 curves like P-256)
  bflb_pka_madd(dev, R_TMP5, SZ, R_TMP1, SZ, R_TMP5, SZ, R_P, SZ, 0)
  bflb_pka_madd(dev, R_TMP1, SZ, R_TMP1, SZ, R_TMP5, SZ, R_P, SZ, 0)  # M in T1
  # RZ = RY * RZ mod P
  bflb_pka_mmul(dev, R_RY, SZ, R_RZ, SZ, R_RZ, SZ, R_P, SZ, 0)
  # RZ = 2 * RZ mod P (new Z)
  bflb_pka_madd(dev, R_RZ, SZ, R_RZ, SZ, R_RZ, SZ, R_P, SZ, 0)
  # T5 = RY^2 mod P
  bflb_pka_msqr(dev, R_RY, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # T6 = T5^2 mod P (= Y^4)
  bflb_pka_msqr(dev, R_TMP5, SZ, R_TMP6, SZ, R_P, SZ, 0)
  # T5 = RX * T5 mod P (= X * Y^2)
  bflb_pka_mmul(dev, R_RX, SZ, R_TMP5, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # S = 4 * T5 (shift left by 2 would use ladd twice, or use madd)
  bflb_pka_madd(dev, R_TMP5, SZ, R_TMP5, SZ, R_TMP5, SZ, R_P, SZ, 0)  # 2*S
  bflb_pka_madd(dev, R_TMP5, SZ, R_TMP5, SZ, R_TMP5, SZ, R_P, SZ, 0)  # 4*S = S in T5
  # RX = M^2 mod P
  bflb_pka_msqr(dev, R_TMP1, SZ, R_RX, SZ, R_P, SZ, 0)
  # RX = RX - 2*S mod P
  bflb_pka_msub(dev, R_RX, SZ, R_RX, SZ, R_TMP5, SZ, R_P, SZ, 0)
  bflb_pka_msub(dev, R_RX, SZ, R_RX, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # T5 = S - RX mod P
  bflb_pka_msub(dev, R_TMP5, SZ, R_TMP5, SZ, R_RX, SZ, R_P, SZ, 0)
  # T5 = M * T5 mod P
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP5, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # T6 = 8 * T6 mod P (8*Y^4)
  bflb_pka_madd(dev, R_TMP6, SZ, R_TMP6, SZ, R_TMP6, SZ, R_P, SZ, 0)
  bflb_pka_madd(dev, R_TMP6, SZ, R_TMP6, SZ, R_TMP6, SZ, R_P, SZ, 0)
  bflb_pka_madd(dev, R_TMP6, SZ, R_TMP6, SZ, R_TMP6, SZ, R_P, SZ, 0)
  # RY = T5 - T6 mod P
  bflb_pka_msub(dev, R_TMP5, SZ, R_RY, SZ, R_TMP6, SZ, R_P, SZ, 1)

proc eccPointAdd(dev: ptr BflbDevice) =
  ## Point addition: (RX,RY,RZ) = (RX,RY,RZ) + (PX,PY,1) mod P.
  ## Mixed addition (second point affine, Z2=1).
  # U1 = RX (already in Jacobian), U2 = PX * RZ^2
  bflb_pka_msqr(dev, R_RZ, SZ, R_TMP1, SZ, R_P, SZ, 0)    # T1 = Z1^2
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP5, SZ, R_PX, SZ, R_P, SZ, 0)  # T5 = X2*Z1^2 = U2
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP1, SZ, R_RZ, SZ, R_P, SZ, 0)  # T1 = Z1^3
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP6, SZ, R_PY, SZ, R_P, SZ, 0)  # T6 = Y2*Z1^3 = S2
  # H = U2 - U1 = T5 - RX
  bflb_pka_msub(dev, R_TMP5, SZ, R_TMP5, SZ, R_RX, SZ, R_P, SZ, 0)  # H in T5
  # R = S2 - S1 = T6 - RY
  bflb_pka_msub(dev, R_TMP6, SZ, R_TMP6, SZ, R_RY, SZ, R_P, SZ, 0)  # R in T6
  # Z3 = H * Z1
  bflb_pka_mmul(dev, R_TMP5, SZ, R_RZ, SZ, R_RZ, SZ, R_P, SZ, 0)
  # H^2
  bflb_pka_msqr(dev, R_TMP5, SZ, R_TMP1, SZ, R_P, SZ, 0)   # T1 = H^2
  # H^3
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP7, SZ, R_TMP5, SZ, R_P, SZ, 0) # T7 = H^3
  # U1*H^2
  bflb_pka_mmul(dev, R_RX, SZ, R_TMP1, SZ, R_TMP1, SZ, R_P, SZ, 0)   # T1 = U1*H^2
  # X3 = R^2 - H^3 - 2*U1*H^2
  bflb_pka_msqr(dev, R_TMP6, SZ, R_RX, SZ, R_P, SZ, 0)      # RX = R^2
  bflb_pka_msub(dev, R_RX, SZ, R_RX, SZ, R_TMP7, SZ, R_P, SZ, 0)    # RX -= H^3
  bflb_pka_msub(dev, R_RX, SZ, R_RX, SZ, R_TMP1, SZ, R_P, SZ, 0)    # RX -= U1*H^2
  bflb_pka_msub(dev, R_RX, SZ, R_RX, SZ, R_TMP1, SZ, R_P, SZ, 0)    # RX -= U1*H^2 (x2)
  # Y3 = R*(U1*H^2 - X3) - S1*H^3
  bflb_pka_msub(dev, R_TMP1, SZ, R_TMP1, SZ, R_RX, SZ, R_P, SZ, 0)  # T1 = U1*H^2 - X3
  bflb_pka_mmul(dev, R_TMP6, SZ, R_TMP1, SZ, R_TMP1, SZ, R_P, SZ, 0) # T1 = R*(U1*H^2-X3)
  bflb_pka_mmul(dev, R_RY, SZ, R_TMP7, SZ, R_TMP7, SZ, R_P, SZ, 0)  # T7 = S1*H^3
  bflb_pka_msub(dev, R_TMP1, SZ, R_RY, SZ, R_TMP7, SZ, R_P, SZ, 1)  # RY = result

proc eccPointMul(dev: ptr BflbDevice, scalar: ptr uint32, wordSize: uint32) =
  ## Scalar point multiplication using double-and-add.
  ## Input point in (PX, PY) registers, result in (RX, RY, RZ).
  ## Scalar in memory, wordSize = number of 32-bit words.
  let scalarArr = cast[ptr UncheckedArray[uint32]](scalar)

  # Initialize result to point at infinity (Z=0)
  bflb_pka_clir(dev, R_RX, SZ, 0, 0)
  bflb_pka_clir(dev, R_RY, SZ, 0, 0)
  bflb_pka_clir(dev, R_RZ, SZ, 0, 0)

  var firstBit = true

  # Process scalar bits from MSB to LSB
  for w in countdown(wordSize.int - 1, 0):
    let word = scalarArr[w]
    for b in countdown(31, 0):
      if not firstBit:
        # Always double
        eccPointDouble(dev)

      if (word and (1'u32 shl b)) != 0:
        if firstBit:
          # First set bit: R = P (copy input point)
          bflb_pka_movdat(dev, R_PX, SZ, R_RX, SZ, 0)
          bflb_pka_movdat(dev, R_PY, SZ, R_RY, SZ, 0)
          # Z = 1 in Montgomery form = R mod P
          bflb_pka_write(dev, R_RZ, SZ, addr secp256r1InvR_P[0], wordSize.uint16, 0)
          # Actually we need "1" in Montgomery domain. For simplicity, write 1 and convert.
          bflb_pka_slir(dev, R_RZ, SZ, 1, 0)
          bflb_pka_gf2mont(dev, R_RZ, SZ, R_RZ, SZ, R_TMP19, SZ, R_P, SZ,
                            wordSize * 32)
          firstBit = false
        else:
          # R = R + P (mixed addition)
          eccPointAdd(dev)

proc eccJacobianToAffine(dev: ptr BflbDevice, wordSize: uint32) =
  ## Convert Jacobian (X,Y,Z) to affine (x,y) = (X/Z^2, Y/Z^3) mod P.
  # T1 = Z^(-1) mod P
  bflb_pka_minv(dev, R_RZ, SZ, R_TMP1, SZ, R_P, SZ, 0)
  # T5 = T1^2 (= Z^(-2))
  bflb_pka_msqr(dev, R_TMP1, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # RX = X * Z^(-2) mod P
  bflb_pka_mmul(dev, R_RX, SZ, R_RX, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # T5 = T1 * T5 (= Z^(-3))
  bflb_pka_mmul(dev, R_TMP1, SZ, R_TMP5, SZ, R_TMP5, SZ, R_P, SZ, 0)
  # RY = Y * Z^(-3) mod P
  bflb_pka_mmul(dev, R_RY, SZ, R_RY, SZ, R_TMP5, SZ, R_P, SZ, 1)

const
  SdkP256S32 = PkaRegSize32
  SdkP256S64 = PkaRegSize64
  SdkP256Words = 8'u16
  SdkP256Mod = 0'u8
  SdkP256PrimeN = 1'u8
  SdkP256X1 = 2'u8
  SdkP256Y1 = 3'u8
  SdkP256Z1 = 4'u8
  SdkP256X2 = 5'u8
  SdkP256Y2 = 6'u8
  SdkP256Z2 = 7'u8
  SdkP256One = 8'u8
  SdkP256Bar2 = 9'u8
  SdkP256Bar3 = 10'u8
  SdkP256Bar4 = 11'u8
  SdkP256Bar8 = 12'u8
  SdkP256T13 = 13'u8
  SdkP256T14 = 14'u8
  SdkP256T15 = 15'u8
  SdkP256T16 = 16'u8
  SdkP256T17 = 17'u8
  SdkP256T18 = 18'u8
  SdkP256OneP1 = 19'u8
  SdkP256OneM1 = 20'u8

proc sdkP256PointMulInit(dev: ptr BflbDevice) =
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, addr secp256r1P[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, addr secp256r1PrimeN_P[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256One, SdkP256S32, addr secp256r1One[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Bar2, SdkP256S32, addr secp256r1Bar2[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Bar3, SdkP256S32, addr secp256r1Bar3[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Bar4, SdkP256S32, addr secp256r1Bar4[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Bar8, SdkP256S32, addr secp256r1Bar8[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256OneP1, SdkP256S32, addr secp256r1OneP1[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256OneM1, SdkP256S32, addr secp256r1OneM1[0], SdkP256Words, 0)

proc sdkP256ClearWorkingRegs(dev: ptr BflbDevice) =
  const regs = [
    SdkP256X1, SdkP256Y1, SdkP256Z1,
    SdkP256X2, SdkP256Y2, SdkP256Z2,
    SdkP256T13, SdkP256T14, SdkP256T15,
    SdkP256T16, SdkP256T17, SdkP256T18
  ]
  for reg in regs:
    bflb_pka_clir(dev, reg, SdkP256S32, SdkP256Words, 1)
    bflb_pka_clir(dev, reg, SdkP256S64, SdkP256Words, 1)

proc sdkP256PointAddInfCheck(dev: ptr BflbDevice,
                             p1Inf, p2Inf: var uint8) =
  let p1a = bflb_pka_lcmp(dev, SdkP256X1, SdkP256S32, SdkP256One, SdkP256S32)
  let p1b = bflb_pka_lcmp(dev, SdkP256Y1, SdkP256S32, SdkP256OneP1, SdkP256S32)
  let p1c = bflb_pka_lcmp(dev, SdkP256OneM1, SdkP256S32, SdkP256Y1, SdkP256S32)
  let p1d = bflb_pka_lcmp(dev, SdkP256Z1, SdkP256S32, SdkP256One, SdkP256S32)
  p1Inf = p1a and p1b and p1c and p1d

  let p2a = bflb_pka_lcmp(dev, SdkP256X2, SdkP256S32, SdkP256One, SdkP256S32)
  let p2b = bflb_pka_lcmp(dev, SdkP256Y2, SdkP256S32, SdkP256OneP1, SdkP256S32)
  let p2c = bflb_pka_lcmp(dev, SdkP256OneM1, SdkP256S32, SdkP256Y2, SdkP256S32)
  let p2d = bflb_pka_lcmp(dev, SdkP256Z2, SdkP256S32, SdkP256One, SdkP256S32)
  p2Inf = p2a and p2b and p2c and p2d

proc sdkP256CopyX2ToX1(dev: ptr BflbDevice) =
  bflb_pka_movdat(dev, SdkP256X2, SdkP256S32, SdkP256X1, SdkP256S32, 0)
  bflb_pka_movdat(dev, SdkP256Y2, SdkP256S32, SdkP256Y1, SdkP256S32, 0)
  bflb_pka_movdat(dev, SdkP256Z2, SdkP256S32, SdkP256Z1, SdkP256S32, 1)

proc sdkP256PointAdd(dev: ptr BflbDevice) =
  bflb_pka_mmul(dev, SdkP256Y2, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256Z1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y1, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256X2, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Z1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256X1, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T15, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Z1, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T15, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y1, SdkP256S32, SdkP256Z1, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T13, SdkP256S32, SdkP256T17, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T17, SdkP256S32, SdkP256T17, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T17, SdkP256S32, SdkP256T17, SdkP256S32, SdkP256Z1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar2, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T18, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T17, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y1, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Z1, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Z1, SdkP256S32, SdkP256Z1, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T15, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256Y1, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256T18, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T13, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256Y1, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 1)

proc sdkP256PointDouble(dev: ptr BflbDevice) =
  bflb_pka_mmul(dev, SdkP256X2, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Z2, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar3, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y2, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256X2, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T13, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T15, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar8, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256Z2, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar2, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256X2, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar4, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T14, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T15, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T15, SdkP256S32, SdkP256T15, SdkP256S32, SdkP256T13, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar8, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T15, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T14, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256T16, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar8, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Z2, SdkP256S32, SdkP256Mod, SdkP256S32, 1)

proc sdkP256ScalarMulLoop(dev: ptr BflbDevice, scalar: ptr uint32): cint =
  let bytes = cast[ptr UncheckedArray[uint8]](scalar)
  var firstNonZero = 0
  while firstNonZero < 31 and bytes[firstNonZero] == 0:
    firstNonZero.inc

  var resultInf = true
  var i = 31
  while true:
    let current = bytes[i].uint32
    for bit in 0 ..< 8:
      if (current and (1'u32 shl bit)) != 0:
        if resultInf:
          sdkP256CopyX2ToX1(dev)
          resultInf = false
        else:
          sdkP256PointAdd(dev)
      sdkP256PointDouble(dev)
    if i == firstNonZero:
      break
    i.dec
  if resultInf: -1 else: 0

proc sdkP256ScalarMulComplete(dev: ptr BflbDevice,
                              scalar, px, py: ptr uint32,
                              outX, outY: ptr uint32): cint =
  pkaDebugMark(dev.regBase, 0x00000200'u32)
  bflb_pka_init(dev)
  pkaDebugMark(dev.regBase, 0x00000201'u32)
  sdkP256ClearWorkingRegs(dev)
  pkaDebugMark(dev.regBase, 0x00000202'u32)
  sdkP256PointMulInit(dev)
  pkaDebugMark(dev.regBase, 0x00000203'u32)

  bflb_pka_write(dev, SdkP256X1, SdkP256S32, addr secp256r1ZeroX[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, addr secp256r1ZeroY[0], SdkP256Words, 0)
  bflb_pka_movdat(dev, SdkP256X1, SdkP256S32, SdkP256Z1, SdkP256S32, 1)
  bflb_pka_write(dev, SdkP256X2, SdkP256S32, px, SdkP256Words, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, SdkP256Words, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, SdkP256Words, 1)
  bflb_pka_gf2mont(dev, SdkP256X2, SdkP256S32, SdkP256X2, SdkP256S32,
                   SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32,
                   SdkP256Words.uint32 * 32)
  bflb_pka_write(dev, SdkP256Y2, SdkP256S32, py, SdkP256Words, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, SdkP256Words, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, SdkP256Words, 1)
  bflb_pka_gf2mont(dev, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32,
                   SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32,
                   SdkP256Words.uint32 * 32)
  bflb_pka_movdat(dev, SdkP256Y1, SdkP256S32, SdkP256Z2, SdkP256S32, 1)
  bflb_pka_clir(dev, SdkP256Z2, SdkP256S64, SdkP256Words, 1)

  pkaDebugMark(dev.regBase, 0x00000210'u32)
  let rc = sdkP256ScalarMulLoop(dev, scalar)
  if rc != 0:
    bflb_pka_deinit(dev)
    pkaDebugMark(dev.regBase, 0x00000211'u32)
    return rc
  pkaDebugMark(dev.regBase, 0x00000220'u32)

  bflb_pka_minv(dev, SdkP256Z1, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  pkaDebugMark(dev.regBase, 0x00000230'u32)
  bflb_pka_write(dev, SdkP256Y2, SdkP256S32, addr secp256r1InvR_P[0], SdkP256Words, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, SdkP256Words, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, SdkP256Words, 1)
  bflb_pka_mont2gf(dev, SdkP256X2, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_mont2gf(dev, SdkP256X1, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_mont2gf(dev, SdkP256X2, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, addr secp256r1N[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, addr secp256r1PrimeN_N[0], SdkP256Words, 0)
  bflb_pka_mrem(dev, SdkP256X1, SdkP256S32, SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X1, SdkP256S32, outX, SdkP256Words)
  pkaDebugMark(dev.regBase, 0x00000240'u32)

  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, addr secp256r1P[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, addr secp256r1PrimeN_P[0], SdkP256Words, 0)
  bflb_pka_minv(dev, SdkP256Z1, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_write(dev, SdkP256Y2, SdkP256S32, addr secp256r1InvR_P[0], SdkP256Words, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, SdkP256Words, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, SdkP256Words, 1)
  bflb_pka_mont2gf(dev, SdkP256X2, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_mont2gf(dev, SdkP256Y1, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_mont2gf(dev, SdkP256X2, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256Y2, SdkP256S32, SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, addr secp256r1N[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, addr secp256r1PrimeN_N[0], SdkP256Words, 0)
  bflb_pka_mrem(dev, SdkP256Y1, SdkP256S32, SdkP256Y1, SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256Y1, SdkP256S32, outY, SdkP256Words)
  pkaDebugMark(dev.regBase, 0x00000250'u32)

  bflb_pka_deinit(dev)
  pkaDebugMark(dev.regBase, 0x00000260'u32)
  0

proc pkaReduceModN(dev: ptr BflbDevice, value, outValue: ptr uint32): cint =
  if dev == nil or value == nil or outValue == nil:
    return -1
  let (_, cn, _, _, _, _, _, _, cprimnn, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimnn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X1, SdkP256S32, value, ws.uint16, 0)
  bflb_pka_mrem(dev, SdkP256X1, SdkP256S32, SdkP256X1, SdkP256S32,
                SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X1, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaMulModN(dev: ptr BflbDevice, a, b, outValue: ptr uint32): cint =
  if dev == nil or a == nil or b == nil or outValue == nil:
    return -1
  let (_, cn, _, _, _, _, _, _, cprimnn, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimnn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X1, SdkP256S32, a, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, b, ws.uint16, 0)
  bflb_pka_lmul(dev, SdkP256X1, SdkP256S32, SdkP256T13,
                PkaRegSize128, SdkP256Y1, SdkP256S32, 1)
  bflb_pka_mrem(dev, SdkP256T13, PkaRegSize128, SdkP256X1,
                SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X1, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaInvModN(dev: ptr BflbDevice, value, outValue: ptr uint32): cint =
  if dev == nil or value == nil or outValue == nil:
    return -1
  let (_, cn, _, _, _, _, _, cinvrn, cprimnn, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimnn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, cinvrn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X2, SdkP256S32, value, ws.uint16, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, ws.uint16, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, ws.uint16, 1)
  bflb_pka_gf2mont(dev, SdkP256X2, SdkP256S32, SdkP256X2,
                   SdkP256S32, SdkP256Z2, SdkP256S64,
                   SdkP256Mod, SdkP256S32, ws * 32)
  bflb_pka_minv(dev, SdkP256X2, SdkP256S32, SdkP256Y2,
                SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_mont2gf(dev, SdkP256Y2, SdkP256S32, SdkP256X2,
                   SdkP256S32, SdkP256Y1, SdkP256S32,
                   SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_read(dev, SdkP256X2, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaAddModP(dev: ptr BflbDevice, a, b, outValue: ptr uint32): cint =
  if dev == nil or a == nil or b == nil or outValue == nil:
    return -1
  let (cp, _, _, _, _, _, cprimn, _, _, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cp, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X1, SdkP256S32, a, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, b, ws.uint16, 0)
  bflb_pka_madd(dev, SdkP256X1, SdkP256S32, SdkP256X2,
                SdkP256S32, SdkP256Y1, SdkP256S32,
                SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X2, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaSubModP(dev: ptr BflbDevice, a, b, outValue: ptr uint32): cint =
  if dev == nil or a == nil or b == nil or outValue == nil:
    return -1
  let (cp, _, _, _, _, _, cprimn, _, _, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cp, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X1, SdkP256S32, a, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, b, ws.uint16, 0)
  bflb_pka_msub(dev, SdkP256X1, SdkP256S32, SdkP256X2,
                SdkP256S32, SdkP256Y1, SdkP256S32,
                SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X2, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaMulModP(dev: ptr BflbDevice, a, b, outValue: ptr uint32): cint =
  if dev == nil or a == nil or b == nil or outValue == nil:
    return -1
  let (cp, _, _, _, _, _, cprimn, _, _, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cp, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X1, SdkP256S32, a, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, b, ws.uint16, 0)
  bflb_pka_lmul(dev, SdkP256X1, SdkP256S32, SdkP256T13,
                PkaRegSize128, SdkP256Y1, SdkP256S32, 1)
  bflb_pka_mrem(dev, SdkP256T13, PkaRegSize128, SdkP256X2,
                SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_read(dev, SdkP256X2, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc pkaInvModP(dev: ptr BflbDevice, value, outValue: ptr uint32): cint =
  if dev == nil or value == nil or outValue == nil:
    return -1
  let (cp, _, _, _, _, cinvr, cprimn, _, _, ws) = getP256CurveParams()
  bflb_pka_init(dev)
  bflb_pka_write(dev, SdkP256Mod, SdkP256S32, cp, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256PrimeN, SdkP256S32, cprimn, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, cinvr, ws.uint16, 0)
  bflb_pka_write(dev, SdkP256X2, SdkP256S32, value, ws.uint16, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, ws.uint16, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, ws.uint16, 1)
  bflb_pka_gf2mont(dev, SdkP256X2, SdkP256S32, SdkP256X2,
                   SdkP256S32, SdkP256Z2, SdkP256S64,
                   SdkP256Mod, SdkP256S32, ws * 32)
  bflb_pka_minv(dev, SdkP256X2, SdkP256S32, SdkP256Y2,
                SdkP256S32, SdkP256Mod, SdkP256S32, 1)
  bflb_pka_mont2gf(dev, SdkP256Y2, SdkP256S32, SdkP256X2,
                   SdkP256S32, SdkP256Y1, SdkP256S32,
                   SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32)
  bflb_pka_read(dev, SdkP256X2, SdkP256S32, outValue, ws.uint16)
  bflb_pka_deinit(dev)
  0

proc sdkP256MontLoadAffineCoord(dev: ptr BflbDevice, regIdx: uint8,
                                value: ptr uint32) =
  bflb_pka_write(dev, regIdx, SdkP256S32, value, SdkP256Words, 0)
  bflb_pka_clir(dev, SdkP256T13, SdkP256S32, SdkP256Words, 1)
  bflb_pka_clir(dev, SdkP256T14, SdkP256S32, SdkP256Words, 1)
  bflb_pka_gf2mont(dev, regIdx, SdkP256S32, regIdx, SdkP256S32,
                   SdkP256Z2, SdkP256S64, SdkP256Mod, SdkP256S32,
                   SdkP256Words.uint32 * 32)

proc pkaP256AddAffineXModN(dev: ptr BflbDevice, x1, y1, x2, y2,
                           outXModN: ptr uint32): cint =
  if dev == nil or x1 == nil or y1 == nil or x2 == nil or y2 == nil or
      outXModN == nil:
    return -1

  var slopeNum, slopeDen, slopeDenInv: array[8, uint32]
  var lambda, lambda2, x3: array[8, uint32]

  if eccCmpBeBytes(cast[ptr uint8](x1), cast[ptr uint8](x2), 32) == 0:
    if eccCmpBeBytes(cast[ptr uint8](y1), cast[ptr uint8](y2), 32) != 0:
      return -1
    if eccIsZeroBytes(cast[ptr uint8](y1), 32):
      return -1

    var xSquared, twiceXSquared, threeXSquared: array[8, uint32]
    var three = [0'u32, 0, 0, 0, 0, 0, 0, 0x03000000'u32]
    var twiceX: array[8, uint32]
    if pkaMulModP(dev, x1, x1, addr xSquared[0]) != 0:
      return -1
    if pkaAddModP(dev, addr xSquared[0], addr xSquared[0],
                  addr twiceXSquared[0]) != 0:
      return -1
    if pkaAddModP(dev, addr twiceXSquared[0], addr xSquared[0],
                  addr threeXSquared[0]) != 0:
      return -1
    if pkaSubModP(dev, addr threeXSquared[0], addr three[0],
                  addr slopeNum[0]) != 0:
      return -1
    if pkaAddModP(dev, y1, y1, addr slopeDen[0]) != 0:
      return -1
    if pkaInvModP(dev, addr slopeDen[0], addr slopeDenInv[0]) != 0:
      return -1
    if pkaMulModP(dev, addr slopeNum[0], addr slopeDenInv[0],
                  addr lambda[0]) != 0:
      return -1
    if pkaMulModP(dev, addr lambda[0], addr lambda[0], addr lambda2[0]) != 0:
      return -1
    if pkaAddModP(dev, x1, x1, addr twiceX[0]) != 0:
      return -1
    if pkaSubModP(dev, addr lambda2[0], addr twiceX[0], addr x3[0]) != 0:
      return -1
    return pkaReduceModN(dev, addr x3[0], outXModN)

  var tmp: array[8, uint32]
  if pkaSubModP(dev, y2, y1, addr slopeNum[0]) != 0:
    return -1
  if pkaSubModP(dev, x2, x1, addr slopeDen[0]) != 0:
    return -1
  if pkaInvModP(dev, addr slopeDen[0], addr slopeDenInv[0]) != 0:
    return -1
  if pkaMulModP(dev, addr slopeNum[0], addr slopeDenInv[0],
                addr lambda[0]) != 0:
    return -1
  if pkaMulModP(dev, addr lambda[0], addr lambda[0], addr lambda2[0]) != 0:
    return -1
  if pkaSubModP(dev, addr lambda2[0], x1, addr tmp[0]) != 0:
    return -1
  if pkaSubModP(dev, addr tmp[0], x2, addr x3[0]) != 0:
    return -1
  pkaReduceModN(dev, addr x3[0], outXModN)

proc isP256FieldElementBe(value: ptr uint32): bool =
  value != nil and
    eccCmpBeBytes(cast[ptr uint8](value),
                  cast[ptr uint8](unsafeAddr secp256r1P[0]), 32) < 0

proc isP256PublicKeyRangeBe(x, y: ptr uint32): bool =
  x != nil and y != nil and
    not (eccIsZeroBytes(cast[ptr uint8](x), 32) and
         eccIsZeroBytes(cast[ptr uint8](y), 32)) and
    isP256FieldElementBe(x) and isP256FieldElementBe(y)

proc pkaIsValidP256PublicKey(dev: ptr BflbDevice, x, y: ptr uint32): bool =
  if dev == nil or not isP256PublicKeyRangeBe(x, y):
    return false

  bflb_pka_init(dev)
  sdkP256PointMulInit(dev)
  sdkP256MontLoadAffineCoord(dev, SdkP256X1, x)
  sdkP256MontLoadAffineCoord(dev, SdkP256Y1, y)
  sdkP256MontLoadAffineCoord(dev, SdkP256X2, unsafeAddr secp256r1B[0])

  bflb_pka_mmul(dev, SdkP256Y1, SdkP256S32, SdkP256Y2, SdkP256S32,
                SdkP256Y1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256X1, SdkP256S32, SdkP256T13, SdkP256S32,
                SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32,
                SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_mmul(dev, SdkP256Bar3, SdkP256S32, SdkP256T14, SdkP256S32,
                SdkP256X1, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_msub(dev, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32,
                SdkP256T14, SdkP256S32, SdkP256Mod, SdkP256S32, 0)
  bflb_pka_madd(dev, SdkP256T13, SdkP256S32, SdkP256T13, SdkP256S32,
                SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 1)

  let valid = bflb_pka_lcmp(dev, SdkP256Y2, SdkP256S32,
                            SdkP256T13, SdkP256S32) == 0
  bflb_pka_deinit(dev)
  valid

type
  Ec256 = array[8, uint32]

const
  EcP: Ec256 = [
    0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000001'u32, 0xFFFFFFFF'u32
  ]
  EcN: Ec256 = [
    0xFC632551'u32, 0xF3B9CAC2'u32, 0xA7179E84'u32, 0xBCE6FAAD'u32,
    0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  EcGx: Ec256 = [
    0xD898C296'u32, 0xF4A13945'u32, 0x2DEB33A0'u32, 0x77037D81'u32,
    0x63A440F2'u32, 0xF8BCE6E5'u32, 0xE12C4247'u32, 0x6B17D1F2'u32
  ]
  EcGy: Ec256 = [
    0x37BF51F5'u32, 0xCBB64068'u32, 0x6B315ECE'u32, 0x2BCE3357'u32,
    0x7C0F9E16'u32, 0x8EE7EB4A'u32, 0xFE1A7F9B'u32, 0x4FE342E2'u32
  ]
  EcB: Ec256 = [
    0x27D2604B'u32, 0x3BCE3C3E'u32, 0xCC53B0F6'u32, 0x651D06B0'u32,
    0x769886BC'u32, 0xB3EBBD55'u32, 0xAA3A93E7'u32, 0x5AC635D8'u32
  ]

proc ecFromBe(dst: var Ec256, src: ptr uint32) =
  let bytes = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< 8:
    let j = 28 - i * 4
    dst[i] = bytes[j + 3].uint32 or
             (bytes[j + 2].uint32 shl 8) or
             (bytes[j + 1].uint32 shl 16) or
             (bytes[j].uint32 shl 24)

proc ecToBe(dst: ptr uint32, src: Ec256) =
  let bytes = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< 8:
    let w = src[7 - i]
    bytes[i * 4] = (w shr 24).uint8
    bytes[i * 4 + 1] = (w shr 16).uint8
    bytes[i * 4 + 2] = (w shr 8).uint8
    bytes[i * 4 + 3] = w.uint8

proc ecCmp(a, b: Ec256): cint =
  for i in countdown(7, 0):
    if a[i] > b[i]: return 1
    if a[i] < b[i]: return -1
  0

proc ecIsZero(a: Ec256): bool =
  for w in a:
    if w != 0: return false
  true

proc ecGetBit(a: Ec256, bit: int): bool =
  ((a[bit shr 5] shr (bit and 31)) and 1'u32) != 0

proc ecSubRaw(dst: var Ec256, a, b: Ec256) =
  var borrow = 0'u64
  for i in 0 ..< 8:
    let lhs = a[i].uint64
    let rhs = b[i].uint64 + borrow
    if lhs >= rhs:
      dst[i] = (lhs - rhs).uint32
      borrow = 0
    else:
      dst[i] = ((1'u64 shl 32) + lhs - rhs).uint32
      borrow = 1

proc ecAddRaw(dst: var Ec256, a, b: Ec256) =
  var carry = 0'u64
  for i in 0 ..< 8:
    let sum = a[i].uint64 + b[i].uint64 + carry
    dst[i] = sum.uint32
    carry = sum shr 32

proc ecNormalize(a: var Ec256, modulus: Ec256) =
  while ecCmp(a, modulus) >= 0:
    var tmp: Ec256
    ecSubRaw(tmp, a, modulus)
    a = tmp

proc ecAddMod(dst: var Ec256, a, b, modulus: Ec256) =
  var threshold: Ec256
  ecSubRaw(threshold, modulus, b)
  if ecCmp(a, threshold) >= 0:
    ecSubRaw(dst, a, threshold)
  else:
    ecAddRaw(dst, a, b)

proc ecSubMod(dst: var Ec256, a, b, modulus: Ec256) =
  if ecCmp(a, b) >= 0:
    ecSubRaw(dst, a, b)
  else:
    var delta: Ec256
    ecSubRaw(delta, modulus, b)
    ecAddRaw(dst, a, delta)

proc ecMulSmallMod(dst: var Ec256, a: Ec256, k: uint32, modulus: Ec256) =
  var acc: Ec256
  var term = a
  var n = k
  while n != 0:
    if (n and 1) != 0:
      ecAddMod(acc, acc, term, modulus)
    n = n shr 1
    if n != 0:
      ecAddMod(term, term, term, modulus)
  dst = acc

proc ecMulMod(dst: var Ec256, a, b, modulus: Ec256) =
  var acc: Ec256
  var term = a
  ecNormalize(term, modulus)
  for bit in 0 ..< 256:
    if ecGetBit(b, bit):
      ecAddMod(acc, acc, term, modulus)
    ecAddMod(term, term, term, modulus)
  dst = acc

proc ecSubSmall(dst: var Ec256, a: Ec256, value: uint32) =
  dst = a
  var borrow = value.uint64
  var i = 0
  while borrow != 0 and i < 8:
    let lhs = dst[i].uint64
    let sub = borrow and 0xFFFF_FFFF'u64
    if lhs >= sub:
      dst[i] = (lhs - sub).uint32
      borrow = borrow shr 32
    else:
      dst[i] = ((1'u64 shl 32) + lhs - sub).uint32
      borrow = (borrow shr 32) + 1
    i.inc

proc ecInvMod(dst: var Ec256, a, modulus: Ec256) =
  var exp: Ec256
  ecSubSmall(exp, modulus, 2)
  var result: Ec256
  var base = a
  result[0] = 1
  ecNormalize(base, modulus)
  for bit in countdown(255, 0):
    var squared: Ec256
    ecMulMod(squared, result, result, modulus)
    result = squared
    if ecGetBit(exp, bit):
      var product: Ec256
      ecMulMod(product, result, base, modulus)
      result = product
  dst = result

type
  EcPoint = object
    x, y, z: Ec256
    inf: bool

proc ecPointDouble(p: var EcPoint) =
  if p.inf or ecIsZero(p.y):
    p.inf = true
    return

  var delta, gamma, beta, xm, xp, alpha: Ec256
  var tmp, tmp2, x3, y3, z3: Ec256
  ecMulMod(delta, p.z, p.z, EcP)
  ecMulMod(gamma, p.y, p.y, EcP)
  ecMulMod(beta, p.x, gamma, EcP)
  ecSubMod(xm, p.x, delta, EcP)
  ecAddMod(xp, p.x, delta, EcP)
  ecMulMod(alpha, xm, xp, EcP)
  ecMulSmallMod(alpha, alpha, 3, EcP)

  ecMulMod(x3, alpha, alpha, EcP)
  ecMulSmallMod(tmp, beta, 8, EcP)
  ecSubMod(x3, x3, tmp, EcP)

  ecMulSmallMod(tmp, beta, 4, EcP)
  ecSubMod(tmp, tmp, x3, EcP)
  ecMulMod(y3, alpha, tmp, EcP)
  ecMulMod(tmp2, gamma, gamma, EcP)
  ecMulSmallMod(tmp2, tmp2, 8, EcP)
  ecSubMod(y3, y3, tmp2, EcP)

  ecAddMod(tmp, p.y, p.z, EcP)
  ecMulMod(z3, tmp, tmp, EcP)
  ecSubMod(z3, z3, gamma, EcP)
  ecSubMod(z3, z3, delta, EcP)

  p.x = x3
  p.y = y3
  p.z = z3

proc ecPointAddMixed(p: var EcPoint, ax, ay: Ec256) =
  if p.inf:
    p.x = ax
    p.y = ay
    p.z = [1'u32, 0, 0, 0, 0, 0, 0, 0]
    p.inf = false
    return

  var z2, z3v, u2, s2, h, r: Ec256
  ecMulMod(z2, p.z, p.z, EcP)
  ecMulMod(u2, ax, z2, EcP)
  ecMulMod(z3v, z2, p.z, EcP)
  ecMulMod(s2, ay, z3v, EcP)
  ecSubMod(h, u2, p.x, EcP)
  ecSubMod(r, s2, p.y, EcP)

  if ecIsZero(h):
    if ecIsZero(r):
      ecPointDouble(p)
    else:
      p.inf = true
    return

  var hh, hhh, v, x3, y3, tmp: Ec256
  ecMulMod(hh, h, h, EcP)
  ecMulMod(hhh, h, hh, EcP)
  ecMulMod(v, p.x, hh, EcP)
  ecMulMod(x3, r, r, EcP)
  ecSubMod(x3, x3, hhh, EcP)
  ecSubMod(x3, x3, v, EcP)
  ecSubMod(x3, x3, v, EcP)
  ecSubMod(tmp, v, x3, EcP)
  ecMulMod(y3, r, tmp, EcP)
  ecMulMod(tmp, p.y, hhh, EcP)
  ecSubMod(y3, y3, tmp, EcP)
  ecMulMod(p.z, p.z, h, EcP)
  p.x = x3
  p.y = y3

proc ecPointToAffine(p: EcPoint, outX, outY: var Ec256): bool =
  if p.inf or ecIsZero(p.z):
    return false
  var zInv, z2, z3v: Ec256
  ecInvMod(zInv, p.z, EcP)
  ecMulMod(z2, zInv, zInv, EcP)
  ecMulMod(z3v, z2, zInv, EcP)
  ecMulMod(outX, p.x, z2, EcP)
  ecMulMod(outY, p.y, z3v, EcP)
  true

proc ecScalarMulAffine(scalar, px, py: Ec256, outX, outY: var Ec256): cint =
  var p = EcPoint(inf: true)
  for bit in countdown(255, 0):
    if not p.inf:
      ecPointDouble(p)
    if ecGetBit(scalar, bit):
      ecPointAddMixed(p, px, py)
  if ecPointToAffine(p, outX, outY): 0 else: -1

proc ecAffineAdd(x1, y1, x2, y2: Ec256, outX, outY: var Ec256): cint =
  if ecCmp(x1, x2) == 0:
    var ys: Ec256
    ecAddMod(ys, y1, y2, EcP)
    if ecIsZero(ys):
      return -1
    var p = EcPoint(x: x1, y: y1, z: [1'u32, 0, 0, 0, 0, 0, 0, 0], inf: false)
    ecPointDouble(p)
    if ecPointToAffine(p, outX, outY): return 0 else: return -1

  var num, den, inv, lambda, tmp, x3, y3: Ec256
  ecSubMod(num, y2, y1, EcP)
  ecSubMod(den, x2, x1, EcP)
  ecInvMod(inv, den, EcP)
  ecMulMod(lambda, num, inv, EcP)
  ecMulMod(x3, lambda, lambda, EcP)
  ecSubMod(x3, x3, x1, EcP)
  ecSubMod(x3, x3, x2, EcP)
  ecSubMod(tmp, x1, x3, EcP)
  ecMulMod(y3, lambda, tmp, EcP)
  ecSubMod(y3, y3, y1, EcP)
  outX = x3
  outY = y3
  0

proc ecIsValidPublicKey(x, y: Ec256): bool =
  if (ecIsZero(x) and ecIsZero(y)) or ecCmp(x, EcP) >= 0 or ecCmp(y, EcP) >= 0:
    return false

  var y2, x2, rhs, threeX: Ec256
  ecMulMod(y2, y, y, EcP)
  ecMulMod(x2, x, x, EcP)
  ecMulMod(rhs, x2, x, EcP)
  ecMulSmallMod(threeX, x, 3, EcP)
  ecSubMod(rhs, rhs, threeX, EcP)
  ecAddMod(rhs, rhs, EcB, EcP)
  ecCmp(y2, rhs) == 0

proc isValidP256ScalarBe(scalar: ptr uint32): bool =
  if scalar == nil:
    return false
  const byteLen = 32'u32
  not eccIsZeroBytes(cast[ptr uint8](scalar), byteLen) and
    eccCmpBeBytes(cast[ptr uint8](scalar),
                  cast[ptr uint8](unsafeAddr secp256r1N[0]), byteLen) < 0

proc isValidP256PublicKeyBe(x, y: ptr uint32): bool =
  if x == nil or y == nil:
    return false
  var qx, qy: Ec256
  ecFromBe(qx, x)
  ecFromBe(qy, y)
  ecIsValidPublicKey(qx, qy)

proc bflb_sec_p256_is_valid_public_key_be*(x, y: ptr uint32): bool =
  isValidP256PublicKeyBe(x, y)

proc bflb_sec_p256_inverse_field_be*(value, outValue: ptr uint32): cint =
  if value == nil or outValue == nil or
      eccIsZeroBytes(cast[ptr uint8](value), 32) or
      not isP256FieldElementBe(value):
    return -1
  when defined(bl808m0):
    pkaInvModP(pka, value, outValue)
  else:
    var v, inv: Ec256
    ecFromBe(v, value)
    ecInvMod(inv, v, EcP)
    ecToBe(outValue, inv)
    0

proc ecScalarMulMem(scalar: ptr uint32, px, py: ptr uint32,
                    outX, outY: ptr uint32): cint =
  var k, x, y, rx, ry: Ec256
  ecFromBe(k, scalar)
  ecFromBe(x, px)
  ecFromBe(y, py)
  let rc = ecScalarMulAffine(k, x, y, rx, ry)
  if rc == 0:
    ecToBe(outX, rx)
    ecToBe(outY, ry)
  rc

proc eccScalarMulComplete(dev: ptr BflbDevice, ecpId: uint8,
                          scalar: ptr uint32,
                          px, py: ptr uint32,
                          outX, outY: ptr uint32): cint =
  ## Full scalar point multiplication: (outX, outY) = scalar * (px, py).
  if dev == nil or scalar == nil or px == nil or py == nil or outX == nil or
      outY == nil:
    return -1
  case ecpId
  of EcpSecp256r1:
    return sdkP256ScalarMulComplete(dev, scalar, px, py, outX, outY)
  of EcpSecp256k1, EcpSecp384r1:
    return -1
  else:
    return -1

# =============================================================================
# ECDSA / ECDH / DSA — full implementations
# =============================================================================

proc bflb_sec_ecdsa_get_private_key*(handle: ptr BflbEcdsa,
                                     privateKey: ptr uint32): cint {.exportc, cdecl.} =
  ## Generate a random private key < n.
  if handle == nil or privateKey == nil or not isSupportedEcpId(handle.ecpId):
    return -1
  let (_, cn, _, _, _, _, _, _, _, ws) = getP256CurveParams()
  let byteLen = ws * 4
  var tries = 100
  while tries > 0:
    let rc = bflb_sec_ecc_get_random_value(privateKey, cn, byteLen)
    if rc != 0: return rc
    if not eccIsZeroBytes(cast[ptr uint8](privateKey), byteLen):
      return 0
    tries.dec
  -1

proc bflb_sec_ecdsa_get_public_key*(handle: ptr BflbEcdsa,
                                    privateKey, pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  ## Compute public key Q = privateKey * G.
  if handle == nil or privateKey == nil or pRx == nil or pRy == nil or
      not isSupportedEcpId(handle.ecpId) or not isValidP256ScalarBe(privateKey):
    return -1
  handle.privateKey = cast[ptr uint32](privateKey)
  handle.publicKeyx = pRx
  handle.publicKeyy = pRy
  let (_, _, cgx, cgy, _, _, _, _, _, _) = getP256CurveParams()
  eccScalarMulComplete(pka, handle.ecpId, privateKey, cgx, cgy, pRx, pRy)

proc bflb_sec_ecdsa_sign*(handle: ptr BflbEcdsa, randomK, hash: ptr uint32,
                          hashLenInWord: uint32,
                          r, s: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDSA signature: (r, s) where r = (k*G).x mod n, s = k^-1*(hash + r*d) mod n.
  if handle == nil or handle.privateKey == nil or hash == nil or r == nil or
      s == nil or not isSupportedEcpId(handle.ecpId) or
      not isValidP256ScalarBe(handle.privateKey):
    return -1
  let (_, cn, cgx, cgy, _, _, _, cinvrn, cprimnn, ws) = getP256CurveParams()
  let byteLen = ws * 4

  var tries = 100
  while tries > 0:
    var k: array[8, uint32]
    if randomK == nil:
      if bflb_sec_ecc_get_random_value(addr k[0], cn, byteLen) != 0:
        return -1
    else:
      copyWords(addr k[0], randomK, ws)
      tries = 1
    if eccIsZeroBytes(cast[ptr uint8](addr k[0]), byteLen) or
        eccCmpBeBytes(cast[ptr uint8](addr k[0]),
                      cast[ptr uint8](cn), byteLen) >= 0:
      tries.dec
      continue

    var rx, ry: array[8, uint32]
    if eccScalarMulComplete(pka, handle.ecpId, addr k[0], cgx, cgy,
                            addr rx[0], addr ry[0]) != 0:
      tries.dec
      continue
    copyWords(r, addr rx[0], ws)
    if eccIsZeroBytes(cast[ptr uint8](r), byteLen):
      tries.dec
      continue

    bflb_pka_init(pka)
    bflb_pka_write(pka, 0, SZ, cn, ws.uint16, 0)
    bflb_pka_write(pka, 1, SZ, cprimnn, ws.uint16, 0)
    bflb_pka_write(pka, 2, SZ, cinvrn, ws.uint16, 0)

    bflb_pka_write(pka, 5, SZ, addr k[0], ws.uint16, 0)
    bflb_pka_clir(pka, 13, SZ, ws.uint16, 1)
    bflb_pka_clir(pka, 14, SZ, ws.uint16, 1)
    bflb_pka_gf2mont(pka, 5, SZ, 5, SZ, 7, PkaRegSize64, 0, SZ,
                     byteLen * 8)
    bflb_pka_minv(pka, 5, SZ, 6, SZ, 0, SZ, 1)
    bflb_pka_mont2gf(pka, 6, SZ, 5, SZ, 2, SZ, 7, PkaRegSize64, 0, SZ)
    var kInv: array[8, uint32]
    bflb_pka_read(pka, 5, SZ, addr kInv[0], ws.uint16)

    bflb_pka_write(pka, 4, SZ, handle.privateKey, ws.uint16, 0)
    bflb_pka_write(pka, 5, SZ, r, ws.uint16, 0)
    bflb_pka_lmul(pka, 4, SZ, 3, PkaRegSize128, 5, SZ, 1)

    var hashBuf: array[8, uint32]
    copyWords(addr hashBuf[0], hash, min(hashLenInWord, ws))
    bflb_pka_write(pka, 5, SZ, addr hashBuf[0], ws.uint16, 0)
    bflb_pka_ladd(pka, 3, PkaRegSize128, 3, PkaRegSize128, 5, SZ, 1)

    bflb_pka_write(pka, 5, SZ, addr kInv[0], ws.uint16, 0)
    bflb_pka_lmul(pka, 3, PkaRegSize128, 3, PkaRegSize128, 5, SZ, 1)

    bflb_pka_write(pka, 0, SZ, cn, ws.uint16, 0)
    bflb_pka_mrem(pka, 3, PkaRegSize128, 4, SZ, 0, SZ, 1)
    bflb_pka_read(pka, 4, SZ, s, ws.uint16)
    bflb_pka_deinit(pka)

    if not eccIsZeroBytes(cast[ptr uint8](s), byteLen):
      return 0
    tries.dec
  -1

proc bflb_sec_ecdsa_verify*(handle: ptr BflbEcdsa, hash: ptr uint32,
                            hashLen: uint32,
                            r, s: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDSA verify: check (hash*s^-1)*G + (r*s^-1)*Q has x == r mod n.
  if handle == nil or hash == nil or r == nil or s == nil or
      not isSupportedEcpId(handle.ecpId) or
      handle.publicKeyx == nil or handle.publicKeyy == nil:
    return -1

  when defined(bl808m0):
    let (_, _, cgx, cgy, _, _, _, _, _, ws) = getP256CurveParams()
    let byteLen = ws * 4
    if not isValidP256ScalarBe(r) or not isValidP256ScalarBe(s) or
        not isValidP256PublicKeyBe(handle.publicKeyx, handle.publicKeyy):
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x10'u32
      return -1

    var hashBuf, z, w, u1, u2: array[8, uint32]
    copyWords(addr hashBuf[0], hash, min(hashLen, ws))
    if pkaReduceModN(pka, addr hashBuf[0], addr z[0]) != 0:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x20'u32
      return -1
    if pkaInvModN(pka, s, addr w[0]) != 0:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x21'u32
      return -1
    if pkaMulModN(pka, addr z[0], addr w[0], addr u1[0]) != 0:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x22'u32
      return -1
    if pkaMulModN(pka, r, addr w[0], addr u2[0]) != 0:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x23'u32
      return -1
    when defined(bl808PkaDebug):
      for i in 0 ..< 8:
        nim_pka_verify_w[i] = w[i]
        nim_pka_verify_u1[i] = u1[i]
        nim_pka_verify_u2[i] = u2[i]
      nim_pka_verify_stage = 0x30'u32

    var have = false
    var p1x, p1y, p2x, p2y, xMod: array[8, uint32]
    if not eccIsZeroBytes(cast[ptr uint8](addr u1[0]), byteLen):
      if eccScalarMulComplete(pka, handle.ecpId, addr u1[0], cgx, cgy,
                              addr p1x[0], addr p1y[0]) != 0:
        when defined(bl808PkaDebug):
          nim_pka_verify_stage = 0x40'u32
        return -1
      have = true

    if not eccIsZeroBytes(cast[ptr uint8](addr u2[0]), byteLen):
      if eccScalarMulComplete(pka, handle.ecpId, addr u2[0],
                              handle.publicKeyx, handle.publicKeyy,
                              addr p2x[0], addr p2y[0]) != 0:
        when defined(bl808PkaDebug):
          nim_pka_verify_stage = 0x50'u32
        return -1
      if have:
        if pkaP256AddAffineXModN(pka, addr p1x[0], addr p1y[0],
                                 addr p2x[0], addr p2y[0],
                                 addr xMod[0]) != 0:
          when defined(bl808PkaDebug):
            nim_pka_verify_stage = 0x60'u32
          return -1
      else:
        if pkaReduceModN(pka, addr p2x[0], addr xMod[0]) != 0:
          when defined(bl808PkaDebug):
            nim_pka_verify_stage = 0x61'u32
          return -1
        have = true
    elif have:
      if pkaReduceModN(pka, addr p1x[0], addr xMod[0]) != 0:
        when defined(bl808PkaDebug):
          nim_pka_verify_stage = 0x62'u32
        return -1

    if not have:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x63'u32
      return -1
    when defined(bl808PkaDebug):
      for i in 0 ..< 8:
        nim_pka_verify_xmod[i] = xMod[i]
      nim_pka_verify_stage = 0x70'u32
    if eccCmpBeBytes(cast[ptr uint8](addr xMod[0]),
                     cast[ptr uint8](r), byteLen) == 0:
      when defined(bl808PkaDebug):
        nim_pka_verify_stage = 0x71'u32
      return 0
    when defined(bl808PkaDebug):
      nim_pka_verify_stage = 0x72'u32
    return -1
  else:
    var z, rv, sv, w, u1, u2: Ec256
    var qx, qy: Ec256
    var hashBuf: array[8, uint32]
    copyWords(addr hashBuf[0], hash, min(hashLen, 8'u32))
    ecFromBe(z, addr hashBuf[0])
    ecNormalize(z, EcN)
    ecFromBe(rv, r)
    ecFromBe(sv, s)
    if ecIsZero(rv) or ecIsZero(sv) or ecCmp(rv, EcN) >= 0 or ecCmp(sv, EcN) >= 0:
      return -1
    ecFromBe(qx, handle.publicKeyx)
    ecFromBe(qy, handle.publicKeyy)
    if not ecIsValidPublicKey(qx, qy):
      return -1

    ecInvMod(w, sv, EcN)
    ecMulMod(u1, z, w, EcN)
    ecMulMod(u2, rv, w, EcN)

    var have = false
    var rx, ry: Ec256
    if not ecIsZero(u1):
      if ecScalarMulAffine(u1, EcGx, EcGy, rx, ry) != 0:
        return -1
      have = true
    if not ecIsZero(u2):
      var p2x, p2y: Ec256
      if ecScalarMulAffine(u2, qx, qy, p2x, p2y) != 0:
        return -1
      if have:
        if ecAffineAdd(rx, ry, p2x, p2y, rx, ry) != 0:
          return -1
      else:
        rx = p2x
        ry = p2y
        have = true
    if not have:
      return -1

    ecNormalize(rx, EcN)
    if ecCmp(rx, rv) == 0: 0 else: -1

proc bflb_sec_ecdsa_sign_384*(handle: ptr BflbEcdsa, randomK, hash: ptr uint32,
                              hashLenInWord: uint32,
                              r, s: ptr uint32): cint {.exportc, cdecl.} =
  bflb_sec_ecdsa_sign(handle, randomK, hash, hashLenInWord, r, s)

proc bflb_sec_ecdsa_verify_384*(handle: ptr BflbEcdsa, hash: ptr uint32,
                                hashLen: uint32,
                                r, s: ptr uint32): cint {.exportc, cdecl.} =
  bflb_sec_ecdsa_verify(handle, hash, hashLen, r, s)

proc bflb_sec_ecdh_get_public_key*(handle: ptr BflbEcdh,
                                   privateKey, pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDH: publicKey = privateKey * G.
  if handle == nil or privateKey == nil or pRx == nil or pRy == nil or
      not isSupportedEcpId(handle.ecpId) or not isValidP256ScalarBe(privateKey):
    return -1
  let (_, _, cgx, cgy, _, _, _, _, _, _) = getP256CurveParams()
  eccScalarMulComplete(pka, handle.ecpId, privateKey, cgx, cgy, pRx, pRy)

proc bflb_sec_ecdh_get_encrypt_key*(handle: ptr BflbEcdh,
                                    pkX, pkY, privateKey: ptr uint32,
                                    pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDH: sharedSecret = privateKey * peerPublicKey.
  if handle == nil or pkX == nil or pkY == nil or privateKey == nil or
      pRx == nil or pRy == nil or not isSupportedEcpId(handle.ecpId) or
      not isValidP256ScalarBe(privateKey) or not isValidP256PublicKeyBe(pkX, pkY):
    return -1
  eccScalarMulComplete(pka, handle.ecpId, privateKey, pkX, pkY, pRx, pRy)

proc bflb_sec_ecdh_get_scalar_point_384*(handle: ptr BflbEcdh,
                                         pkX, pkY, privateKey: ptr uint32,
                                         pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  bflb_sec_ecdh_get_encrypt_key(handle, pkX, pkY, privateKey, pRx, pRy)

proc bflb_sec_dsa_sign*(handle: ptr BflbDsa, hash: ptr uint32,
                        hashLenInWord: uint32,
                        s: ptr uint32): cint {.exportc, cdecl.} =
  ## RSA/DSA sign: s = hash^d mod n (modular exponentiation).
  if handle == nil or handle.size == 0 or
      handle.size > (DsaMaxWords.uint32 * 32'u32) or
      handle.n == nil or handle.d == nil or hash == nil or s == nil:
    return -1
  let words = wordLenForBits(handle.size)
  var modulus, exponent, base, signature: DsaWordArray
  dsaLoad(modulus, handle.n, words)
  if dsaIsZero(modulus, words):
    return -1
  dsaLoad(exponent, handle.d, words)
  dsaLoadPadded(base, hash, hashLenInWord, words)
  dsaExpMod(signature, base, exponent, modulus, words)
  dsaStore(s, signature, words)
  0

proc bflb_sec_dsa_verify*(handle: ptr BflbDsa, hash: ptr uint32,
                          hashLenInWord: uint32,
                          s: ptr uint32): cint {.exportc, cdecl.} =
  ## RSA/DSA verify: compute s^e mod n, compare with hash.
  if handle == nil or handle.size == 0 or
      handle.size > (DsaMaxWords.uint32 * 32'u32) or
      handle.n == nil or handle.e == nil or hash == nil or s == nil:
    return -1
  let words = wordLenForBits(handle.size)
  var modulus, exponent, signature, decrypted, expected: DsaWordArray
  dsaLoad(modulus, handle.n, words)
  if dsaIsZero(modulus, words):
    return -1
  dsaLoad(exponent, handle.e, words)
  dsaLoad(signature, s, words)
  dsaLoadPadded(expected, hash, hashLenInWord, words)
  dsaReduce(expected, modulus, words)
  dsaExpMod(decrypted, signature, exponent, modulus, words)
  if dsaCmp(decrypted, expected, words) == 0: 0 else: -1
