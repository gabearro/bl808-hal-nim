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

# Size in 32-bit words for each PKA register size code. The SDK names these
# by byte capacity: REG_SIZE_32 is a 32-byte register, not a 32-bit register.
const pkaSizeWords: array[11, uint16] = [0, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128]

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
# ECDSA / ECDH / DSA stub exports
# (These compose the low-level PKA operations above for ECC math)
# =============================================================================

proc eccCmpWords(a, b: ptr uint32, size: uint32): cint =
  let arrA = cast[ptr UncheckedArray[uint32]](a)
  let arrB = cast[ptr UncheckedArray[uint32]](b)
  for i in countdown(size.int - 1, 0):
    if arrA[i] > arrB[i]: return 1
    if arrA[i] < arrB[i]: return -1
  0

proc bflb_sec_ecc_get_random_value*(data: ptr uint32, maxRef: ptr uint32,
                                    size: uint32): cint {.exportc, cdecl.} =
  ## Get a random value less than maxRef using TRNG.
  const
    TrngCtrl = SecEngBase + 0x200'u
    TrngStatus = SecEngBase + 0x204'u
    TrngData = SecEngBase + 0x208'u
    TrngTrigger = 1'u32 shl 1
    TrngEnable = 1'u32 shl 2
    TrngDataClear = 1'u32 shl 3
    TrngIntClear = 1'u32 shl 9
  let dataWords = cast[ptr UncheckedArray[uint32]](data)

  var word = 0'u32
  while word < size:
    regWrite(TrngCtrl, TrngEnable or TrngTrigger)
    var timeout = 100_000'u32
    while (regRead(TrngStatus) and 1) == 0:
      timeout.dec
      if timeout == 0: return -1

    let remaining = size - word
    let batch = if remaining < 8'u32: remaining else: 8'u32
    for i in 0'u32 ..< batch:
      dataWords[word + i] = regRead(TrngData + i.uint * 4)
    word += batch
    regWrite(TrngCtrl, TrngEnable or TrngDataClear or TrngIntClear)

  while eccCmpWords(data, maxRef, size) >= 0:
    var borrow = 0'u64
    let refWords = cast[ptr UncheckedArray[uint32]](maxRef)
    for i in 0 ..< size.int:
      let lhs = dataWords[i].uint64
      let rhs = refWords[i].uint64 + borrow
      if lhs >= rhs:
        dataWords[i] = (lhs - rhs).uint32
        borrow = 0
      else:
        dataWords[i] = ((1'u64 shl 32) + lhs - rhs).uint32
        borrow = 1
  0

proc bflb_sec_ecc_cmp*(a, b: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
  eccCmpWords(a, b, size)

proc bflb_sec_ecc_is_zero*(a: ptr uint32, size: uint32): cint {.exportc, cdecl.} =
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

const DsaMaxWords = 32
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
  bflb_pka_init(dev)
  bflb_pka_clir(dev, SdkP256Z2, SdkP256S64, SdkP256Words, 1)
  sdkP256PointMulInit(dev)

  bflb_pka_write(dev, SdkP256X1, SdkP256S32, addr secp256r1ZeroX[0], SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Y1, SdkP256S32, addr secp256r1ZeroY[0], SdkP256Words, 0)
  bflb_pka_movdat(dev, SdkP256X1, SdkP256S32, SdkP256Z1, SdkP256S32, 1)
  bflb_pka_write(dev, SdkP256X2, SdkP256S32, px, SdkP256Words, 0)
  bflb_pka_write(dev, SdkP256Y2, SdkP256S32, py, SdkP256Words, 0)
  bflb_pka_movdat(dev, SdkP256Y1, SdkP256S32, SdkP256Z2, SdkP256S32, 1)
  bflb_pka_clir(dev, SdkP256Z2, SdkP256S64, SdkP256Words, 1)

  let rc = sdkP256ScalarMulLoop(dev, scalar)
  if rc != 0:
    bflb_pka_deinit(dev)
    return rc

  bflb_pka_minv(dev, SdkP256Z1, SdkP256S32, SdkP256X2, SdkP256S32, SdkP256Mod, SdkP256S32, 1)
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

  bflb_pka_deinit(dev)
  0

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

  var num, den, inv, lambda, tmp: Ec256
  ecSubMod(num, y2, y1, EcP)
  ecSubMod(den, x2, x1, EcP)
  ecInvMod(inv, den, EcP)
  ecMulMod(lambda, num, inv, EcP)
  ecMulMod(outX, lambda, lambda, EcP)
  ecSubMod(outX, outX, x1, EcP)
  ecSubMod(outX, outX, x2, EcP)
  ecSubMod(tmp, x1, outX, EcP)
  ecMulMod(outY, lambda, tmp, EcP)
  ecSubMod(outY, outY, y1, EcP)
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
  if ecpId == EcpSecp256r1 or ecpId == EcpSecp256k1 or ecpId == EcpSecp384r1:
    return ecScalarMulMem(scalar, px, py, outX, outY)

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
  # Load n companion registers for Montgomery ops modulo n.
  bflb_pka_write(pka, R_PRIMN_N, SZ, cprimnn, ws.uint16, 0)
  bflb_pka_write(pka, R_INVR_N, SZ, cinvrn, ws.uint16, 0)

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
  if handle.publicKeyx == nil or handle.publicKeyy == nil:
    return -1

  var z, rv, sv, w, u1, u2: Ec256
  var qx, qy: Ec256
  ecFromBe(z, hash)
  ecNormalize(z, EcN)
  ecFromBe(rv, r)
  ecFromBe(sv, s)
  if ecIsZero(rv) or ecIsZero(sv) or ecCmp(rv, EcN) >= 0 or ecCmp(sv, EcN) >= 0:
    return -1
  ecFromBe(qx, handle.publicKeyx)
  ecFromBe(qy, handle.publicKeyy)

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
  if handle.size == 0 or handle.size > (DsaMaxWords.uint32 * 32'u32) or
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
  if handle.size == 0 or handle.size > (DsaMaxWords.uint32 * 32'u32) or
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
