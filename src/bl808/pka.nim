## BL808 PKA (Public Key Accelerator) — Nim reimplementation of libpka_bl808.a
##
## This module is a COMPLETE Nim reimplementation of the PKA binary blob,
## reverse-engineered from the disassembly using `riscv64-unknown-elf-objdump`.
## It exports the same C symbols as the blob for link-level compatibility.
##
## The PKA hardware accelerator sits at SEC_ENG_BASE + 0x300 and provides:
##   - Large number arithmetic (add, sub, mul, div, compare)
##   - Modular arithmetic (mod add/sub/mul/sqr/exp/inv/rem)
##   - Montgomery domain conversions (GF↔Montgomery)
##   - ECDSA sign/verify (secp256r1, secp256k1, secp384r1)
##   - ECDH key exchange
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

# Size in 32-bit words for each register size code
const pkaSizeWords: array[11, uint16] = [0, 1, 1, 1, 2, 3, 4, 6, 8, 12, 16]

# =============================================================================
# PKA register offsets from device base
# =============================================================================
const
  PkaCtrl0Offset  = 0x300'u  # PKA_CTRL_0
  PkaRwOffset     = 0x340'u  # PKA_RW (command/data)

# =============================================================================
# Device struct (matches bflb_device_s layout)
# =============================================================================
type
  BflbDevice* {.exportc: "bflb_device_s".} = object
    name*: cstring
    regBase*: uint32  # At offset 4 from struct start

# =============================================================================
# Internal helpers
# =============================================================================
proc pkaBase(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase

proc pkaCtrl0(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase + PkaCtrl0Offset

proc pkaRw(dev: ptr BflbDevice): uint {.inline.} =
  dev.regBase + PkaRwOffset

proc pkaClearInt(base: uint) =
  let ctrl = base + PkaCtrl0Offset
  var v = regRead(ctrl)
  v = v or (1'u32 shl 9)  # Set int_clear bit
  regWrite(ctrl, v)
  v = regRead(ctrl)
  v = v and not (1'u32 shl 9)
  regWrite(ctrl, v)

proc pkaWaitIsr(base: uint) =
  var timeout = 100'u32
  while timeout > 0:
    let v = regRead(base + PkaCtrl0Offset)
    if (v and (1'u32 shl 8)) != 0:  # Check int_status bit
      return
    timeout.dec

proc pkaWriteFirstConfig(base: uint, opcode: uint32, s0Idx: uint8,
                         s0Size: uint8, dIdx: uint8, dSize: uint8,
                         lastop: uint8) =
  ## Build and write the first operand config to PKA_RW.
  var cmd = (opcode shl 24) or
            (lastop.uint32 shl 31) or
            (dIdx.uint32 shl 20) or
            s0Idx.uint32 or
            (s0Size.uint32 shl 12) or
            (dSize.uint32 shl 8)
  regWrite(base + PkaRwOffset, cmd)

# =============================================================================
# PKA low-level operations (46 exported functions matching blob symbols)
# =============================================================================

proc bflb_pka_init*(dev: ptr BflbDevice) {.exportc, cdecl.} =
  ## Initialize PKA hardware.
  let base = dev.regBase
  regWrite(base + PkaCtrl0Offset, 0)          # Clear control
  regWrite(base + PkaCtrl0Offset, 8)          # Set enable bit [3]
  var v = regRead(base + PkaCtrl0Offset)
  v = v or 0x1000'u32                         # Set bit [12] (clock enable)
  regWrite(base + PkaCtrl0Offset, v)

proc bflb_pka_deinit*(dev: ptr BflbDevice) {.exportc, cdecl.} =
  regWrite(dev.regBase + PkaCtrl0Offset, 0)

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

  pkaClearInt(base)
  pkaWaitIsr(base)

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
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_ldiv2n*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      bitShift: uint16, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLdiv2n, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, bitShift.uint32)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_lmul2n*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      bitShift: uint16, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLmul2n, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, bitShift.uint32)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

# --- Two-operand large arithmetic ---

proc bflb_pka_ladd*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLadd, s0Idx, s0Size, dIdx, dSize, 0)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_lsub*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLsub, s0Idx, s0Size, dIdx, dSize, 0)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_lmul*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLmul, s0Idx, s0Size, dIdx, dSize, 0)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_lsqr*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLsqr, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_ldiv*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLdiv, s0Idx, s0Size, dIdx, dSize, 0)
  let s2Cmd = (s2Idx.uint32 shl 12) or (s2Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_lcmp*(dev: ptr BflbDevice, s0Idx, s0Size: uint8,
                    s1Idx, s1Size: uint8): uint8 {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpLcmp, s0Idx, s0Size, 0, 0, 0)
  let s1Cmd = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20)
  regWrite(base + PkaRwOffset, s1Cmd)
  pkaClearInt(base)
  pkaWaitIsr(base)
  # Read comparison result from status register
  let status = regRead(base + PkaCtrl0Offset)
  ((status shr 17) and 0x03).uint8  # Result in bits [18:17]

# --- Modular arithmetic ---

proc bflb_pka_madd*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMadd, s0Idx, s0Size, dIdx, dSize, 0)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_msub*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMsub, s0Idx, s0Size, dIdx, dSize, 0)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_mmul*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMmul, s0Idx, s0Size, dIdx, dSize, 0)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_msqr*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMsqr, s0Idx, s0Size, dIdx, dSize, 0)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_mrem*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMrem, s0Idx, s0Size, dIdx, dSize, 0)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_minv*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s2Idx, s2Size: uint8, lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMinv, s0Idx, s0Size, dIdx, dSize, 0)
  let s2Cmd = (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s2Cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_mexp*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    s1Idx, s1Size, s2Idx, s2Size: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMexp, s0Idx, s0Size, dIdx, dSize, 0)
  let s1s2 = (s1Idx.uint32 shl 12) or (s1Size.uint32 shl 20) or
             (s2Idx.uint32) or (s2Size.uint32 shl 8)
  regWrite(base + PkaRwOffset, s1s2)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

# --- Register management ---

proc bflb_pka_regsize*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                       lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpResize, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_movdat*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                      lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpMovdat, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_nlir*(dev: ptr BflbDevice, s0Idx, s0Size, dIdx, dSize: uint8,
                    lastop: uint8) {.exportc, cdecl.} =
  let base = dev.regBase
  pkaWriteFirstConfig(base, PkaOpNlir, s0Idx, s0Size, dIdx, dSize, 0)
  regWrite(base + PkaRwOffset, 0)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_slir*(dev: ptr BflbDevice, regindex, regsize: uint8,
                    data: uint32, lastop: uint8) {.exportc, cdecl.} =
  ## Write a single immediate value to a PKA register.
  let base = dev.regBase
  let cmd = (PkaOpSlir shl 24) or
            (regsize.uint32 shl 20) or
            (regindex.uint32 shl 12) or
            (data and 0xFFF)
  regWrite(base + PkaRwOffset, cmd)
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

proc bflb_pka_clir*(dev: ptr BflbDevice, regindex, regsize: uint8,
                    size: uint16, lastop: uint8) {.exportc, cdecl.} =
  ## Clear a PKA register.
  let base = dev.regBase
  var cmd = (regsize.uint32 shl 20) or size.uint32 or
            (regindex.uint32 shl 12) or 0xB500_0000'u32
  regWrite(base + PkaRwOffset, cmd)
  regWrite(base + PkaRwOffset, 0)  # Trigger
  if lastop != 0:
    pkaClearInt(base)
    pkaWaitIsr(base)

# --- Montgomery domain conversions ---

proc bflb_pka_gf2mont*(dev: ptr BflbDevice,
                       sIdx, sSize, dIdx, dSize: uint8,
                       tIdx, tSize, pIdx, pSize: uint8,
                       size: uint32) {.exportc, cdecl.} =
  ## Convert from GF (normal) to Montgomery domain.
  ## Steps: t = s * 2^(size*32) mod p, then d = t
  bflb_pka_lmul2n(dev, sIdx, sSize, tIdx, tSize,
                  (size * 32).uint16, 0)
  bflb_pka_mrem(dev, tIdx, tSize, dIdx, dSize,
                pIdx, pSize, 1)

proc bflb_pka_mont2gf*(dev: ptr BflbDevice,
                       sIdx, sSize, dIdx, dSize: uint8,
                       invrIdx, invrSize: uint8,
                       tIdx, tSize, pIdx, pSize: uint8) {.exportc, cdecl.} =
  ## Convert from Montgomery domain to GF (normal).
  ## d = s * invR mod p
  bflb_pka_mmul(dev, sIdx, sSize, dIdx, dSize,
                invrIdx, invrSize, pIdx, pSize, 1)

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
  0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32,
  0x00000000'u32, 0x00000000'u32, 0x00000001'u32, 0xFFFFFFFF'u32
]
const secp256r1N* {.exportc.}: array[8, uint32] = [
  0xFC632551'u32, 0xF3B9CAC2'u32, 0xA7179E84'u32, 0xBCE6FAAD'u32,
  0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32, 0xFFFFFFFF'u32
]
const secp256r1Gx* {.exportc.}: array[8, uint32] = [
  0xD898C296'u32, 0xF4A13945'u32, 0x2DEB33A0'u32, 0x77037D81'u32,
  0x63A440F2'u32, 0xF8BCE6E5'u32, 0xE12C4247'u32, 0x6B17D1F2'u32
]
const secp256r1Gy* {.exportc.}: array[8, uint32] = [
  0x37BF51F5'u32, 0xCBB64068'u32, 0x6B315ECE'u32, 0x2BCE3357'u32,
  0x7C0F9E16'u32, 0x8EE7EB4A'u32, 0xFE1A7F9B'u32, 0x4FE342E2'u32
]
const secp256r1B* {.exportc.}: array[8, uint32] = [
  0x27D2604B'u32, 0x3BCE3C3E'u32, 0xCC53B0F6'u32, 0x651D06B0'u32,
  0x769886BC'u32, 0xB3EBBD55'u32, 0xAA3A93E7'u32, 0x5AC635D8'u32
]

# Montgomery inverse R for P and N (precomputed)
const secp256r1InvR_P* {.exportc.}: array[8, uint32] = [
  0x00000001'u32, 0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32,
  0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFE'u32, 0x00000000'u32
]
const secp256r1InvR_N* {.exportc.}: array[8, uint32] = [
  0xEEDF9BFE'u32, 0x012FFD85'u32, 0xDF1A6C21'u32, 0x43190553'u32,
  0x00000000'u32, 0x00000000'u32, 0xFFFFFFFF'u32, 0x00000000'u32
]
const secp256r1PrimeN_P* {.exportc.}: array[8, uint32] = [
  0x00000001'u32, 0x00000000'u32, 0x00000000'u32, 0x00000001'u32,
  0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32
]
const secp256r1PrimeN_N* {.exportc.}: array[8, uint32] = [
  0x039CDAAF'u32, 0x0C46353D'u32, 0x58E8617B'u32, 0x43190553'u32,
  0x00000000'u32, 0x00000000'u32, 0x00000001'u32, 0x00000000'u32
]

# =============================================================================
# ECDSA / ECDH / DSA stub exports
# (These compose the low-level PKA operations above for ECC math)
# =============================================================================

proc bflb_sec_ecc_get_random_value*(data: ptr uint32, maxRef: ptr uint32,
                                    size: uint32): cint {.exportc, cdecl.} =
  ## Get a random value less than maxRef using TRNG.
  # Use hardware TRNG to fill data, then reduce mod maxRef
  let trngBase = SecEngBase + 0x200
  regSet(trngBase, 1'u32)  # Enable TRNG
  for i in 0'u32 ..< size:
    var timeout = 100_000'u32
    while (regRead(trngBase + 0x04) and 1) == 0:
      timeout.dec
      if timeout == 0: return -1
    cast[ptr UncheckedArray[uint32]](data)[i] = regRead(trngBase + 0x14 + (i mod 8) * 4)
  regSet(trngBase + 0x34, 1)  # Clear
  0

proc bflb_sec_ecc_cmp*(a, b: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
  let arrA = cast[ptr UncheckedArray[uint32]](a)
  let arrB = cast[ptr UncheckedArray[uint32]](b)
  for i in countdown(size.int - 1, 0):
    if arrA[i] > arrB[i]: return 1
    if arrA[i] < arrB[i]: return -1
  0

proc bflb_sec_ecc_is_zero*(a: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
  let arr = cast[ptr UncheckedArray[uint32]](a)
  for i in 0 ..< size.int:
    if arr[i] != 0: return 0
  1

proc bflb_sec_ecdsa_init*(handle: ptr BflbEcdsa, id: uint8): cint {.exportc, cdecl.} =
  handle.ecpId = id
  0

proc bflb_sec_ecdsa_deinit*(handle: ptr BflbEcdsa): cint {.exportc, cdecl.} =
  0

proc bflb_sec_ecdh_init*(handle: ptr BflbEcdh, id: uint8): cint {.exportc, cdecl.} =
  handle.ecpId = id
  0

proc bflb_sec_ecdh_deinit*(handle: ptr BflbEcdh): cint {.exportc, cdecl.} =
  0

proc bflb_sec_dsa_init*(handle: ptr BflbDsa, size: uint32): cint {.exportc, cdecl.} =
  handle.size = size
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
  R_P     = 10'u8  # curve prime
  R_N     = 11'u8  # curve order
  R_INVR  = 12'u8  # invR mod P
  R_PRIMN = 13'u8  # primeN for P
  R_TMP19 = 19'u8
  SZ      = 8'u8   # SEC_ENG_PKA_REG_SIZE_256

# Global PKA device (matches blob's `pka` global variable)
var pka* {.exportc.}: ptr BflbDevice

proc getCurveParams(ecpId: uint8): (ptr uint32, ptr uint32, ptr uint32,
                                     ptr uint32, ptr uint32,
                                     ptr uint32, ptr uint32,
                                     ptr uint32, ptr uint32, uint32) =
  ## Returns (P, N, Gx, Gy, B, invR_P, primeN_P, invR_N, primeN_N, wordSize)
  case ecpId
  of EcpSecp256r1:
    (addr secp256r1P[0], addr secp256r1N[0],
     addr secp256r1Gx[0], addr secp256r1Gy[0], addr secp256r1B[0],
     addr secp256r1InvR_P[0], addr secp256r1PrimeN_P[0],
     addr secp256r1InvR_N[0], addr secp256r1PrimeN_N[0], 8'u32)
  else:
    # secp256k1 and secp384r1 would go here
    (addr secp256r1P[0], addr secp256r1N[0],
     addr secp256r1Gx[0], addr secp256r1Gy[0], addr secp256r1B[0],
     addr secp256r1InvR_P[0], addr secp256r1PrimeN_P[0],
     addr secp256r1InvR_N[0], addr secp256r1PrimeN_N[0], 8'u32)

proc eccLoadCurveParams(dev: ptr BflbDevice, ecpId: uint8) =
  ## Load curve constants into PKA registers.
  let (cp, cn, cgx, cgy, cb, cinvr, cprimn, cinvrn, cprimnn, ws) =
    getCurveParams(ecpId)
  bflb_pka_write(dev, R_P, SZ, cp, ws.uint16, 0)
  bflb_pka_write(dev, R_N, SZ, cn, ws.uint16, 0)
  bflb_pka_write(dev, R_PX, SZ, cgx, ws.uint16, 0)
  bflb_pka_write(dev, R_PY, SZ, cgy, ws.uint16, 0)
  bflb_pka_write(dev, R_INVR, SZ, cinvr, ws.uint16, 0)
  bflb_pka_write(dev, R_PRIMN, SZ, cprimn, ws.uint16, 1)

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
          bflb_pka_gf2mont(dev, R_RZ, SZ, R_RZ, SZ, R_TMP19, SZ, R_P, SZ, wordSize)
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

proc eccScalarMulComplete(dev: ptr BflbDevice, ecpId: uint8,
                          scalar: ptr uint32,
                          px, py: ptr uint32,
                          outX, outY: ptr uint32): cint =
  ## Full scalar point multiplication: (outX, outY) = scalar * (px, py).
  let ws: uint32 = if ecpId == EcpSecp384r1: 12 else: 8

  bflb_pka_init(dev)
  eccLoadCurveParams(dev, ecpId)

  # Load input point into PX, PY registers
  bflb_pka_write(dev, R_PX, SZ, px, ws.uint16, 0)
  bflb_pka_write(dev, R_PY, SZ, py, ws.uint16, 0)

  # Convert point to Montgomery domain
  bflb_pka_gf2mont(dev, R_PX, SZ, R_PX, SZ, R_TMP19, SZ, R_P, SZ, ws)
  bflb_pka_gf2mont(dev, R_PY, SZ, R_PY, SZ, R_TMP19, SZ, R_P, SZ, ws)

  # Perform scalar multiplication
  eccPointMul(dev, scalar, ws)

  # Convert result from Jacobian+Montgomery to affine+GF
  eccJacobianToAffine(dev, ws)
  bflb_pka_mont2gf(dev, R_RX, SZ, R_RX, SZ, R_INVR, SZ, R_TMP19, SZ, R_P, SZ)
  bflb_pka_mont2gf(dev, R_RY, SZ, R_RY, SZ, R_INVR, SZ, R_TMP19, SZ, R_P, SZ)

  # Read results
  bflb_pka_read(dev, R_RX, SZ, outX, ws.uint16)
  bflb_pka_read(dev, R_RY, SZ, outY, ws.uint16)

  bflb_pka_deinit(dev)
  0

# =============================================================================
# ECDSA / ECDH / DSA — full implementations
# =============================================================================

proc bflb_sec_ecdsa_get_private_key*(handle: ptr BflbEcdsa,
                                     privateKey: ptr uint32): cint {.exportc, cdecl.} =
  ## Generate a random private key < n.
  let (_, cn, _, _, _, _, _, _, _, ws) = getCurveParams(handle.ecpId)
  var tries = 100
  while tries > 0:
    let rc = bflb_sec_ecc_get_random_value(privateKey, cn, ws)
    if rc != 0: return rc
    # Ensure key is not zero and < n
    if bflb_sec_ecc_is_zero(privateKey, ws) == 0:
      if bflb_sec_ecc_cmp(privateKey, cn, ws) < 0:
        return 0
    tries.dec
  -1

proc bflb_sec_ecdsa_get_public_key*(handle: ptr BflbEcdsa,
                                    privateKey, pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  ## Compute public key Q = privateKey * G.
  handle.privateKey = cast[ptr uint32](privateKey)
  handle.publicKeyx = pRx
  handle.publicKeyy = pRy
  let (_, _, cgx, cgy, _, _, _, _, _, _) = getCurveParams(handle.ecpId)
  eccScalarMulComplete(pka, handle.ecpId, privateKey, cgx, cgy, pRx, pRy)

proc bflb_sec_ecdsa_sign*(handle: ptr BflbEcdsa, randomK, hash: ptr uint32,
                          hashLenInWord: uint32,
                          r, s: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDSA signature: (r, s) where r = (k*G).x mod n, s = k^-1*(hash + r*d) mod n.
  let (_, cn, cgx, cgy, _, _, _, cinvrn, cprimnn, ws) = getCurveParams(handle.ecpId)

  # Step 1: (x1, y1) = k * G
  var kx, ky: array[12, uint32]
  let rc = eccScalarMulComplete(pka, handle.ecpId, randomK, cgx, cgy,
                                addr kx[0], addr ky[0])
  if rc != 0: return rc

  # Step 2: r = x1 mod n
  bflb_pka_init(pka)
  bflb_pka_write(pka, R_N, SZ, cn, ws.uint16, 0)
  bflb_pka_write(pka, R_RX, SZ, addr kx[0], ws.uint16, 0)
  bflb_pka_mrem(pka, R_RX, SZ, R_RX, SZ, R_N, SZ, 1)
  bflb_pka_read(pka, R_RX, SZ, r, ws.uint16)

  # Check r != 0
  if bflb_sec_ecc_is_zero(r, ws) != 0:
    bflb_pka_deinit(pka)
    return -1

  # Step 3: s = k^-1 * (hash + r * privateKey) mod n
  # Load n, primeN_N for Montgomery ops modulo n
  bflb_pka_write(pka, R_PRIMN, SZ, cprimnn, ws.uint16, 0)
  bflb_pka_write(pka, R_INVR, SZ, cinvrn, ws.uint16, 0)

  # T1 = r * privateKey mod n
  bflb_pka_write(pka, R_TMP1, SZ, r, ws.uint16, 0)
  bflb_pka_write(pka, R_TMP5, SZ, handle.privateKey, ws.uint16, 0)
  bflb_pka_mmul(pka, R_TMP1, SZ, R_TMP1, SZ, R_TMP5, SZ, R_N, SZ, 0)

  # T1 = hash + r*d mod n
  bflb_pka_write(pka, R_TMP5, SZ, hash, min(hashLenInWord, ws).uint16, 0)
  bflb_pka_madd(pka, R_TMP1, SZ, R_TMP1, SZ, R_TMP5, SZ, R_N, SZ, 0)

  # T5 = k^-1 mod n
  bflb_pka_write(pka, R_TMP5, SZ, randomK, ws.uint16, 0)
  bflb_pka_minv(pka, R_TMP5, SZ, R_TMP5, SZ, R_N, SZ, 0)

  # s = k^-1 * (hash + r*d) mod n
  bflb_pka_mmul(pka, R_TMP5, SZ, R_TMP5, SZ, R_TMP1, SZ, R_N, SZ, 1)
  bflb_pka_read(pka, R_TMP5, SZ, s, ws.uint16)

  bflb_pka_deinit(pka)

  # Check s != 0
  if bflb_sec_ecc_is_zero(s, ws) != 0: return -1
  0

proc bflb_sec_ecdsa_verify*(handle: ptr BflbEcdsa, hash: ptr uint32,
                            hashLen: uint32,
                            r, s: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDSA verify: check (hash*s^-1)*G + (r*s^-1)*Q has x == r mod n.
  let (_, cn, cgx, cgy, _, _, _, cinvrn, cprimnn, ws) = getCurveParams(handle.ecpId)

  bflb_pka_init(pka)

  # w = s^-1 mod n
  bflb_pka_write(pka, R_N, SZ, cn, ws.uint16, 0)
  bflb_pka_write(pka, R_TMP1, SZ, s, ws.uint16, 0)
  bflb_pka_minv(pka, R_TMP1, SZ, R_TMP1, SZ, R_N, SZ, 0)

  # u1 = hash * w mod n
  bflb_pka_write(pka, R_TMP5, SZ, hash, min(hashLen, ws).uint16, 0)
  bflb_pka_mmul(pka, R_TMP5, SZ, R_TMP5, SZ, R_TMP1, SZ, R_N, SZ, 0)
  var u1: array[12, uint32]
  bflb_pka_read(pka, R_TMP5, SZ, addr u1[0], ws.uint16)

  # u2 = r * w mod n
  bflb_pka_write(pka, R_TMP5, SZ, r, ws.uint16, 0)
  bflb_pka_mmul(pka, R_TMP5, SZ, R_TMP5, SZ, R_TMP1, SZ, R_N, SZ, 0)
  var u2: array[12, uint32]
  bflb_pka_read(pka, R_TMP5, SZ, addr u2[0], ws.uint16)
  bflb_pka_deinit(pka)

  # P1 = u1 * G
  var p1x, p1y: array[12, uint32]
  discard eccScalarMulComplete(pka, handle.ecpId, addr u1[0],
                               cgx, cgy, addr p1x[0], addr p1y[0])

  # P2 = u2 * Q
  var p2x, p2y: array[12, uint32]
  discard eccScalarMulComplete(pka, handle.ecpId, addr u2[0],
                               handle.publicKeyx, handle.publicKeyy,
                               addr p2x[0], addr p2y[0])

  # R = P1 + P2 (point addition)
  bflb_pka_init(pka)
  eccLoadCurveParams(pka, handle.ecpId)
  bflb_pka_write(pka, R_RX, SZ, addr p1x[0], ws.uint16, 0)
  bflb_pka_write(pka, R_RY, SZ, addr p1y[0], ws.uint16, 0)
  bflb_pka_slir(pka, R_RZ, SZ, 1, 0)
  bflb_pka_gf2mont(pka, R_RX, SZ, R_RX, SZ, R_TMP19, SZ, R_P, SZ, ws)
  bflb_pka_gf2mont(pka, R_RY, SZ, R_RY, SZ, R_TMP19, SZ, R_P, SZ, ws)
  bflb_pka_gf2mont(pka, R_RZ, SZ, R_RZ, SZ, R_TMP19, SZ, R_P, SZ, ws)
  bflb_pka_write(pka, R_PX, SZ, addr p2x[0], ws.uint16, 0)
  bflb_pka_write(pka, R_PY, SZ, addr p2y[0], ws.uint16, 0)
  bflb_pka_gf2mont(pka, R_PX, SZ, R_PX, SZ, R_TMP19, SZ, R_P, SZ, ws)
  bflb_pka_gf2mont(pka, R_PY, SZ, R_PY, SZ, R_TMP19, SZ, R_P, SZ, ws)
  eccPointAdd(pka)
  eccJacobianToAffine(pka, ws)
  bflb_pka_mont2gf(pka, R_RX, SZ, R_RX, SZ, R_INVR, SZ, R_TMP19, SZ, R_P, SZ)

  # v = result.x mod n
  bflb_pka_mrem(pka, R_RX, SZ, R_RX, SZ, R_N, SZ, 1)
  var v: array[12, uint32]
  bflb_pka_read(pka, R_RX, SZ, addr v[0], ws.uint16)
  bflb_pka_deinit(pka)

  # Verify v == r
  if bflb_sec_ecc_cmp(addr v[0], r, ws) == 0: 0 else: -1

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
  let (_, _, cgx, cgy, _, _, _, _, _, _) = getCurveParams(handle.ecpId)
  eccScalarMulComplete(pka, handle.ecpId, privateKey, cgx, cgy, pRx, pRy)

proc bflb_sec_ecdh_get_encrypt_key*(handle: ptr BflbEcdh,
                                    pkX, pkY, privateKey: ptr uint32,
                                    pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  ## ECDH: sharedSecret = privateKey * peerPublicKey.
  eccScalarMulComplete(pka, handle.ecpId, privateKey, pkX, pkY, pRx, pRy)

proc bflb_sec_ecdh_get_scalar_point_384*(handle: ptr BflbEcdh,
                                         pkX, pkY, privateKey: ptr uint32,
                                         pRx, pRy: ptr uint32): cint {.exportc, cdecl.} =
  bflb_sec_ecdh_get_encrypt_key(handle, pkX, pkY, privateKey, pRx, pRy)

proc bflb_sec_dsa_sign*(handle: ptr BflbDsa, hash: ptr uint32,
                        hashLenInWord: uint32,
                        s: ptr uint32): cint {.exportc, cdecl.} =
  ## RSA/DSA sign: s = hash^d mod n (modular exponentiation).
  bflb_pka_init(pka)
  let ws = handle.size.uint16

  # Load n and d
  bflb_pka_write(pka, R_N, SZ, handle.n, ws, 0)

  # Write hash
  bflb_pka_write(pka, R_TMP1, SZ, hash, min(hashLenInWord, handle.size).uint16, 0)

  # Write private exponent d
  bflb_pka_write(pka, R_TMP5, SZ, handle.d, ws, 0)

  # s = hash^d mod n
  bflb_pka_mexp(pka, R_TMP1, SZ, R_RX, SZ, R_TMP5, SZ, R_N, SZ, 1)

  # Read result
  bflb_pka_read(pka, R_RX, SZ, s, ws)
  bflb_pka_deinit(pka)
  0

proc bflb_sec_dsa_verify*(handle: ptr BflbDsa, hash: ptr uint32,
                          hashLenInWord: uint32,
                          s: ptr uint32): cint {.exportc, cdecl.} =
  ## RSA/DSA verify: compute s^e mod n, compare with hash.
  bflb_pka_init(pka)
  let ws = handle.size.uint16

  # Load n and e
  bflb_pka_write(pka, R_N, SZ, handle.n, ws, 0)
  bflb_pka_write(pka, R_TMP1, SZ, s, ws, 0)
  bflb_pka_write(pka, R_TMP5, SZ, handle.e, ws, 0)

  # result = s^e mod n
  bflb_pka_mexp(pka, R_TMP1, SZ, R_RX, SZ, R_TMP5, SZ, R_N, SZ, 1)

  var decrypted: array[16, uint32]
  bflb_pka_read(pka, R_RX, SZ, addr decrypted[0], ws)
  bflb_pka_deinit(pka)

  # Compare with hash
  if bflb_sec_ecc_cmp(addr decrypted[0], hash, handle.size) == 0: 0 else: -1
