## BL808 MJPEG encoder/decoder driver.
##
## MJPEG Encoder at 0x30021000 — hardware JPEG compression.
## MJPEG Decoder at 0x30023000 — hardware JPEG decompression.
##
## Can capture JPEG-compressed video frames from the DVP/CSI pipeline.

import mmio, memmap

# =============================================================================
# MJPEG Encoder register offsets
# =============================================================================
const
  MjpegControl*     = MjpegBase + 0x00'u   # MJPEG control
  MjpegHeader*      = MjpegBase + 0x04'u   # JPEG header config
  MjpegYuvMode*     = MjpegBase + 0x08'u   # YUV mode config
  MjpegQuality*     = MjpegBase + 0x0C'u   # Quality factor
  MjpegYAddr*       = MjpegBase + 0x10'u   # Y plane source address
  MjpegUvAddr*      = MjpegBase + 0x14'u   # UV plane source address
  MjpegYStride*     = MjpegBase + 0x18'u   # Y plane stride
  MjpegUvStride*    = MjpegBase + 0x1C'u   # UV plane stride
  MjpegDstAddr*     = MjpegBase + 0x20'u   # JPEG output destination address
  MjpegDstBufSize*  = MjpegBase + 0x24'u   # Destination buffer size
  MjpegFrameSize*   = MjpegBase + 0x28'u   # Frame size (width x height)
  MjpegSwMode*      = MjpegBase + 0x2C'u   # Software mode
  MjpegIntSts*      = MjpegBase + 0x30'u   # Interrupt status
  MjpegIntMask*     = MjpegBase + 0x34'u   # Interrupt mask
  MjpegIntClr*      = MjpegBase + 0x38'u   # Interrupt clear
  MjpegFrameCount*  = MjpegBase + 0x3C'u   # Encoded frame count
  MjpegJpegSize*    = MjpegBase + 0x40'u   # Encoded JPEG size (bytes)
  MjpegStartAddr*   = MjpegBase + 0x44'u   # Frame start address in output
  MjpegSwRun*       = MjpegBase + 0x48'u   # Software trigger

  # Quantization tables (64 entries each)
  MjpegQTableY*     = MjpegBase + 0x400'u  # Y quantization table (64 x 8-bit)
  MjpegQTableUv*    = MjpegBase + 0x500'u  # UV quantization table

# =============================================================================
# MJPEG Decoder register offsets
# =============================================================================
const
  MjpegDecCtrl*     = MjpegDecBase + 0x00'u  # Decoder control
  MjpegDecSrcAddr*  = MjpegDecBase + 0x04'u  # Source JPEG data address
  MjpegDecSrcSize*  = MjpegDecBase + 0x08'u  # Source data size
  MjpegDecDstYAddr* = MjpegDecBase + 0x0C'u  # Y plane output address
  MjpegDecDstUvAddr* = MjpegDecBase + 0x10'u # UV plane output address
  MjpegDecDstStride* = MjpegDecBase + 0x14'u # Output stride
  MjpegDecFrameSize* = MjpegDecBase + 0x18'u # Decoded frame size
  MjpegDecIntSts*   = MjpegDecBase + 0x20'u  # Interrupt status
  MjpegDecIntMask*  = MjpegDecBase + 0x24'u  # Interrupt mask
  MjpegDecIntClr*   = MjpegDecBase + 0x28'u  # Interrupt clear

# =============================================================================
# MJPEG control fields
# =============================================================================
const
  MjpegEn*          = 0       # MJPEG enable
  MjpegModeShift*   = 1       # Mode [2:1]: 0=snapshot, 1=continuous
  MjpegModeMask*    = 0x03'u32 shl 1
  MjpegOrderUvSwap* = 4       # UV swap (NV12 vs NV21)

# =============================================================================
# Interrupt bits
# =============================================================================
const
  MjpegIntFrameDone* = 0      # Frame encode complete
  MjpegIntFifoOver*  = 1      # FIFO overflow
  MjpegIntBufFull*   = 2      # Output buffer full

# =============================================================================
# Types
# =============================================================================
type
  MjpegMode* = enum
    mjpegSnapshot   = 0   # Single frame
    mjpegContinuous = 1   # Continuous encoding

  MjpegYuvFormat* = enum
    mjpegYuv420sp = 0  # NV12/NV21
    mjpegYuv422sp = 1  # NV16

  MjpegError* = enum
    mjpegOk
    mjpegTimeout
    mjpegBufFull

# =============================================================================
# MJPEG Encoder operations
# =============================================================================
proc mjpegInit*(width, height: uint32, quality: uint32 = 50,
                yAddr, uvAddr, dstAddr: uint32, dstBufSize: uint32) =
  ## Initialize MJPEG encoder.
  ## `quality`: 1-100 (higher = better quality, larger files)

  # Disable during config
  regClear(MjpegControl, 1'u32 shl MjpegEn)

  # Set frame size
  regWrite(MjpegFrameSize, (width and 0xFFFF) or ((height and 0xFFFF) shl 16))

  # Set source addresses
  regWrite(MjpegYAddr, yAddr)
  regWrite(MjpegUvAddr, uvAddr)
  regWrite(MjpegYStride, width)
  regWrite(MjpegUvStride, width)

  # Set destination
  regWrite(MjpegDstAddr, dstAddr)
  regWrite(MjpegDstBufSize, dstBufSize)

  # Set quality (simplified: the actual Q tables would need proper JPEG quantization)
  regWrite(MjpegQuality, quality and 0xFF)

  # Clear interrupts
  regWrite(MjpegIntClr, 0xFF)

proc mjpegStart*(mode: MjpegMode = mjpegSnapshot) =
  regModify(MjpegControl, MjpegModeMask, mode.uint32 shl MjpegModeShift)
  regSet(MjpegControl, 1'u32 shl MjpegEn)

proc mjpegStop*() =
  regClear(MjpegControl, 1'u32 shl MjpegEn)

proc mjpegTrigger*() =
  ## Software trigger one frame (for snapshot mode).
  regWrite(MjpegSwRun, 1)

proc mjpegFrameDone*(): bool =
  (regRead(MjpegIntSts) and (1'u32 shl MjpegIntFrameDone)) != 0

proc mjpegClearFrameDone*() =
  regWrite(MjpegIntClr, 1'u32 shl MjpegIntFrameDone)

proc mjpegGetFrameSize*(): uint32 =
  ## Get the size of the last encoded JPEG frame in bytes.
  regRead(MjpegJpegSize)

proc mjpegGetFrameCount*(): uint32 =
  regRead(MjpegFrameCount)

proc mjpegWaitFrame*(timeout: uint32 = 1_000_000): MjpegError =
  ## Wait for a frame encode to complete.
  var countdown = timeout
  while not mjpegFrameDone():
    countdown.dec
    if countdown == 0: return mjpegTimeout
  mjpegClearFrameDone()
  mjpegOk

# =============================================================================
# MJPEG Decoder operations
# =============================================================================
proc mjpegDecDecode*(srcAddr, srcSize: uint32,
                     dstYAddr, dstUvAddr: uint32,
                     dstStride: uint32): MjpegError =
  ## Decode a JPEG frame.
  regWrite(MjpegDecSrcAddr, srcAddr)
  regWrite(MjpegDecSrcSize, srcSize)
  regWrite(MjpegDecDstYAddr, dstYAddr)
  regWrite(MjpegDecDstUvAddr, dstUvAddr)
  regWrite(MjpegDecDstStride, dstStride)

  # Clear and start
  regWrite(MjpegDecIntClr, 0xFF)
  regSet(MjpegDecCtrl, 1'u32)

  # Wait for completion
  var timeout = 5_000_000'u32
  while (regRead(MjpegDecIntSts) and 1) == 0:
    timeout.dec
    if timeout == 0: return mjpegTimeout

  regWrite(MjpegDecIntClr, 1)
  regClear(MjpegDecCtrl, 1)
  mjpegOk

proc mjpegDecGetFrameSize*(): (uint32, uint32) =
  ## Get the decoded frame dimensions (width, height).
  let size = regRead(MjpegDecFrameSize)
  (size and 0xFFFF, (size shr 16) and 0xFFFF)
