## BL808 DMA2D (2D DMA) driver.
##
## DMA2D at 0x30006000 — 2D block transfer engine.
## Supports rectangular memory copies with source/destination strides,
## used for framebuffer operations, image scaling regions, etc.

import mmio, memmap

# =============================================================================
# DMA2D register offsets
# =============================================================================
const
  Dma2dCtrl*        = Dma2dBase + 0x00'u  # Control
  Dma2dIntSts*      = Dma2dBase + 0x04'u  # Interrupt status
  Dma2dIntMask*     = Dma2dBase + 0x08'u  # Interrupt mask
  Dma2dIntClr*      = Dma2dBase + 0x0C'u  # Interrupt clear
  Dma2dSrcAddr*     = Dma2dBase + 0x10'u  # Source address
  Dma2dSrcStride*   = Dma2dBase + 0x14'u  # Source stride (bytes per line)
  Dma2dDstAddr*     = Dma2dBase + 0x18'u  # Destination address
  Dma2dDstStride*   = Dma2dBase + 0x1C'u  # Destination stride
  Dma2dXCount*      = Dma2dBase + 0x20'u  # X (horizontal) byte count
  Dma2dYCount*      = Dma2dBase + 0x24'u  # Y (vertical) line count
  Dma2dStatus*      = Dma2dBase + 0x28'u  # Status

# =============================================================================
# Control fields
# =============================================================================
const
  Dma2dEn*          = 0       # Enable / start transfer
  Dma2dSoftReset*   = 4       # Soft reset

# =============================================================================
# Types
# =============================================================================
type
  Dma2dError* = enum
    dma2dOk
    dma2dTimeout

# =============================================================================
# DMA2D operations
# =============================================================================
proc dma2dTransfer*(srcAddr, srcStride: uint32,
                    dstAddr, dstStride: uint32,
                    widthBytes, height: uint32,
                    timeout: uint32 = 1_000_000): Dma2dError =
  ## Perform a 2D block copy.
  ## `widthBytes`: number of bytes per row to copy
  ## `height`: number of rows
  ## `srcStride`/`dstStride`: bytes per row in source/dest (including padding)

  regWrite(Dma2dSrcAddr, srcAddr)
  regWrite(Dma2dSrcStride, srcStride)
  regWrite(Dma2dDstAddr, dstAddr)
  regWrite(Dma2dDstStride, dstStride)
  regWrite(Dma2dXCount, widthBytes)
  regWrite(Dma2dYCount, height)

  # Clear interrupts and start
  regWrite(Dma2dIntClr, 0xFF)
  regSet(Dma2dCtrl, 1'u32 shl Dma2dEn)

  # Wait for completion
  var countdown = timeout
  while countdown > 0:
    if (regRead(Dma2dIntSts) and 1) != 0:
      regWrite(Dma2dIntClr, 1)
      regClear(Dma2dCtrl, 1'u32 shl Dma2dEn)
      return dma2dOk
    countdown.dec

  regClear(Dma2dCtrl, 1'u32 shl Dma2dEn)
  dma2dTimeout

proc dma2dFillRect*(dstAddr, dstStride: uint32,
                    widthBytes, height: uint32,
                    patternAddr: uint32,
                    timeout: uint32 = 1_000_000): Dma2dError =
  ## Fill a rectangular region by repeating one row from `patternAddr`.
  ## Write `widthBytes` of fill pattern at `patternAddr` first, then
  ## call this to replicate it across `height` rows.
  ## Source stride = 0 means re-read the same row for every output row.
  regWrite(Dma2dSrcAddr, patternAddr)
  regWrite(Dma2dSrcStride, 0)      # Re-read same row each time
  regWrite(Dma2dDstAddr, dstAddr)
  regWrite(Dma2dDstStride, dstStride)
  regWrite(Dma2dXCount, widthBytes)
  regWrite(Dma2dYCount, height)

  regWrite(Dma2dIntClr, 0xFF)
  regSet(Dma2dCtrl, 1'u32 shl Dma2dEn)

  var countdown = timeout
  while countdown > 0:
    if (regRead(Dma2dIntSts) and 1) != 0:
      regWrite(Dma2dIntClr, 1)
      regClear(Dma2dCtrl, 1'u32 shl Dma2dEn)
      return dma2dOk
    countdown.dec

  regClear(Dma2dCtrl, 1'u32 shl Dma2dEn)
  dma2dTimeout
