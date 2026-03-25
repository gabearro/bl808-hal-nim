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
  Lz4Status*        = Lz4dBase + 0x04'u   # LZ4 status
  Lz4SrcAddr*       = Lz4dBase + 0x08'u   # Source (compressed) address
  Lz4SrcSize*       = Lz4dBase + 0x0C'u   # Source data size
  Lz4DstAddr*       = Lz4dBase + 0x10'u   # Destination (decompressed) address
  Lz4DstSize*       = Lz4dBase + 0x14'u   # Decompressed size (output)
  Lz4IntSts*        = Lz4dBase + 0x18'u   # Interrupt status
  Lz4IntMask*       = Lz4dBase + 0x1C'u   # Interrupt mask
  Lz4IntClr*        = Lz4dBase + 0x20'u   # Interrupt clear

# =============================================================================
# Config fields
# =============================================================================
const
  Lz4En*            = 0       # Enable / start decompression
  Lz4SoftReset*     = 4       # Soft reset

# =============================================================================
# Status fields
# =============================================================================
const
  Lz4StsBusy*       = 0       # Busy
  Lz4StsDone*       = 1       # Decompression done
  Lz4StsError*      = 2       # Error occurred

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
  ## Reset the LZ4 decompressor.
  regSet(Lz4Config, 1'u32 shl Lz4SoftReset)
  for i in 0 ..< 100: discard regRead(Lz4Config)
  regClear(Lz4Config, 1'u32 shl Lz4SoftReset)

proc lz4Decompress*(srcAddr, srcSize, dstAddr: uint32,
                    timeout: uint32 = 5_000_000): (uint32, Lz4Error) =
  ## Decompress an LZ4 block.
  ## Returns (decompressed_size, error).
  lz4Reset()

  regWrite(Lz4SrcAddr, srcAddr)
  regWrite(Lz4SrcSize, srcSize)
  regWrite(Lz4DstAddr, dstAddr)

  # Clear interrupts and start
  regWrite(Lz4IntClr, 0xFF)
  regSet(Lz4Config, 1'u32 shl Lz4En)

  # Wait for completion
  var countdown = timeout
  while countdown > 0:
    let sts = regRead(Lz4Status)
    if (sts and (1'u32 shl Lz4StsDone)) != 0:
      let decompSize = regRead(Lz4DstSize)
      regWrite(Lz4IntClr, 0xFF)
      regClear(Lz4Config, 1'u32 shl Lz4En)
      if (sts and (1'u32 shl Lz4StsError)) != 0:
        return (decompSize, lz4DataError)
      return (decompSize, lz4Ok)
    countdown.dec

  regClear(Lz4Config, 1'u32 shl Lz4En)
  (0'u32, lz4Timeout)
