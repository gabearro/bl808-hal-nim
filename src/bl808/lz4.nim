## BL808 LZ4 hardware decompressor driver.
##
## LZ4D at 0x2000AD00 — hardware LZ4 block decompression.
## Decompresses LZ4 block format data at hardware speed.

import mmio, memmap

# =============================================================================
# LZ4 register offsets
# =============================================================================
const
  Lz4Config*        = Lz4dBase + 0x00'u   # LZ4 configuration
  Lz4SrcFix*        = Lz4dBase + 0x04'u   # Source address fix bits [25:12]
  Lz4DstFix*        = Lz4dBase + 0x08'u   # Destination address fix bits [25:12]
  Lz4SrcStart*      = Lz4dBase + 0x10'u   # Source start address
  Lz4SrcEnd*        = Lz4dBase + 0x14'u   # Source end address, low 26 bits
  Lz4DstStart*      = Lz4dBase + 0x18'u   # Destination start address
  Lz4DstEnd*        = Lz4dBase + 0x1C'u   # Destination end address, low 26 bits
  Lz4IntEn*         = Lz4dBase + 0x20'u   # Interrupt enable
  Lz4IntSta*        = Lz4dBase + 0x24'u   # Interrupt status
  Lz4Monitor*       = Lz4dBase + 0x28'u   # FSM monitor

  # Compatibility aliases for older code. The BL808 manual names these
  # start/end/status registers, not src-size/dst-size registers.
  Lz4Status*        = Lz4IntSta
  Lz4SrcAddr*       = Lz4SrcStart
  Lz4DstAddr*       = Lz4DstStart
  Lz4DstSize*       = Lz4DstEnd
  Lz4IntSts*        = Lz4IntSta
  Lz4IntMask*       = Lz4IntEn

# =============================================================================
# Config fields
# =============================================================================
const
  Lz4En*            = 0       # Enable / start decompression
  Lz4Suspend*       = 1       # Suspend when FSM is idle
  Lz4Checksum*      = 4       # Block has checksum from frame header
  Lz4SoftReset*     = Lz4Checksum # Deprecated: bit 4 is checksum, not reset

# =============================================================================
# Status fields
# =============================================================================
const
  Lz4StsDone*       = 0       # Decompression done
  Lz4StsError*      = 1       # Error occurred
  Lz4DstIntShift*   = 10
  Lz4DstIntMask*    = 0x3F'u32 shl Lz4DstIntShift
  Lz4AddrLowMask*   = 0x03FF_FFFF'u32

# =============================================================================
# Types
# =============================================================================
type
  Lz4Error* = enum
    lz4Ok
    lz4Timeout
    lz4DataError

# =============================================================================
# LZ4 operations
# =============================================================================
proc lz4Reset*() =
  ## Return LZ4D control registers to an idle, disabled state.
  regClear(Lz4Config, (1'u32 shl Lz4En) or (1'u32 shl Lz4Suspend) or
                       (1'u32 shl Lz4Checksum))
  regWrite(Lz4IntEn, (1'u32 shl Lz4StsDone) or (1'u32 shl Lz4StsError))

proc lz4StartValue*(address: uint32): uint32 {.inline.} =
  ## Pack a BL808 LZ4 start address register value.
  ##
  ## The register stores base bits in [31:26] and a 64 MB window offset in
  ## [25:0], so the full 32-bit physical address can be written directly.
  address

proc lz4EndSize*(startAddr, endReg: uint32): uint32 {.inline.} =
  let startLow = startAddr and Lz4AddrLowMask
  let endLow = endReg and Lz4AddrLowMask
  if endLow >= startLow: endLow - startLow else: endLow

proc lz4Decompress*(srcAddr, srcSize, dstAddr: uint32,
                    timeout: uint32 = 5_000_000): (uint32, Lz4Error) =
  ## Decompress an LZ4 block.
  ## Returns (decompressed_size, error).
  ## `srcSize` is retained for API compatibility; BL808 LZ4D consumes block
  ## framing from memory and reports progress through source/destination end
  ## registers rather than a programmed byte-count register.
  discard srcSize
  lz4Reset()

  regWrite(Lz4SrcStart, lz4StartValue(srcAddr))
  regWrite(Lz4DstStart, lz4StartValue(dstAddr))

  regSet(Lz4Config, 1'u32 shl Lz4En)

  # Wait for completion
  var countdown = timeout
  while countdown > 0:
    let sts = regRead(Lz4IntSta)
    if (sts and (1'u32 shl Lz4StsError)) != 0:
      regClear(Lz4Config, 1'u32 shl Lz4En)
      return (lz4EndSize(dstAddr, regRead(Lz4DstEnd)), lz4DataError)
    if (sts and (1'u32 shl Lz4StsDone)) != 0:
      let decompSize = lz4EndSize(dstAddr, regRead(Lz4DstEnd))
      regClear(Lz4Config, 1'u32 shl Lz4En)
      return (decompSize, lz4Ok)
    countdown.dec

  regClear(Lz4Config, 1'u32 shl Lz4En)
  (0'u32, lz4Timeout)
