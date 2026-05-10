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
  MjpegControl*     = MjpegBase + 0x00'u   # MJPEG_CONTROL_1
  MjpegControl2*    = MjpegBase + 0x04'u   # MJPEG_CONTROL_2
  MjpegYAddr*       = MjpegBase + 0x08'u   # Y plane source address
  MjpegUvAddr*      = MjpegBase + 0x0C'u   # UV plane source address
  MjpegYuvMem*      = MjpegBase + 0x10'u   # Y/UV memory block counts
  MjpegDstAddr*     = MjpegBase + 0x14'u   # JPEG output destination address
  MjpegDstBufSize*  = MjpegBase + 0x18'u   # Destination buffer size in 128-byte bursts
  MjpegControl3*    = MjpegBase + 0x1C'u   # Interrupt/status control
  MjpegFrameFifoPop* = MjpegBase + 0x20'u  # FIFO pop and interrupt clear
  MjpegFrameSize*   = MjpegBase + 0x24'u   # Frame size in image blocks
  MjpegHeader*      = MjpegBase + 0x28'u   # JPEG header config
  MjpegSwapMode*    = MjpegBase + 0x30'u   # Swap mode
  MjpegSwapBitCnt*  = MjpegBase + 0x34'u   # Swap end bit count
  MjpegYuvMemSw*    = MjpegBase + 0x38'u   # Kick-mode block count
  MjpegYReadStatus1* = MjpegBase + 0x40'u
  MjpegYReadStatus2* = MjpegBase + 0x44'u
  MjpegYWriteStatus* = MjpegBase + 0x48'u
  MjpegUvReadStatus1* = MjpegBase + 0x4C'u
  MjpegUvReadStatus2* = MjpegBase + 0x50'u
  MjpegUvWriteStatus* = MjpegBase + 0x54'u
  MjpegFrameWblkStatus* = MjpegBase + 0x58'u
  MjpegStartAddr*   = MjpegBase + 0x80'u   # Frame 0 start address in output
  MjpegJpegSize*    = MjpegBase + 0x84'u   # Frame 0 encoded bit count
  MjpegStartAddr1*  = MjpegBase + 0x88'u
  MjpegJpegSize1*   = MjpegBase + 0x8C'u
  MjpegStartAddr2*  = MjpegBase + 0x90'u
  MjpegJpegSize2*   = MjpegBase + 0x94'u
  MjpegStartAddr3*  = MjpegBase + 0x98'u
  MjpegJpegSize3*   = MjpegBase + 0x9C'u
  MjpegQEnc*        = MjpegBase + 0x100'u  # Quantization SRAM control
  MjpegFrameId10*   = MjpegBase + 0x110'u
  MjpegFrameId32*   = MjpegBase + 0x114'u
  MjpegDebug*       = MjpegBase + 0x1F0'u
  MjpegDummy*       = MjpegBase + 0x1FC'u

  # Quantization tables (64 entries each)
  MjpegQTableY*     = MjpegBase + 0x400'u  # Y quantization table (64 x 8-bit)
  MjpegQTableUv*    = MjpegBase + 0x480'u  # UV quantization table

  # Backward-compatible aliases for the former simplified layout.
  MjpegQuality*     = MjpegQEnc
  MjpegYuvMode*     = MjpegControl
  MjpegYStride*     = MjpegYuvMem
  MjpegUvStride*    = MjpegYuvMem
  MjpegSwMode*      = MjpegControl2
  MjpegIntSts*      = MjpegControl3
  MjpegIntMask*     = MjpegControl3
  MjpegIntClr*      = MjpegFrameFifoPop
  MjpegFrameCount*  = MjpegControl3
  MjpegSwRun*       = MjpegControl2

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
  MjpegBitOrder*    = 1
  MjpegOrderUEven*  = 2
  MjpegLastHfWblkDmy* = 4
  MjpegLastHfHblkDmy* = 5
  MjpegReadFwrap*   = 7
  MjpegWXlenShift*  = 8
  MjpegWXlenMask*   = 0x07'u32 shl MjpegWXlenShift
  MjpegYuvModeShift* = 12
  MjpegYuvModeMask* = 0x03'u32 shl MjpegYuvModeShift
  MjpegModeShift*   = 0       # Compatibility: hardware mode is in CONTROL_2.
  MjpegModeMask*    = 0'u32
  MjpegOrderUvSwap* = MjpegOrderUEven

  MjpegSwFrameShift* = 0
  MjpegSwFrameMask* = 0x1F'u32 shl MjpegSwFrameShift
  MjpegSwKick*      = 6
  MjpegSwKickMode*  = 7
  MjpegSwModeBit*   = 8
  MjpegSwRunBit*    = 9
  MjpegWaitCycleShift* = 16
  MjpegWaitCycleMask* = 0xFFFF'u32 shl MjpegWaitCycleShift

  MjpegFrameWblkShift* = 0
  MjpegFrameWblkMask* = 0x0FFF'u32 shl MjpegFrameWblkShift
  MjpegFrameHblkShift* = 16
  MjpegFrameHblkMask* = 0x0FFF'u32 shl MjpegFrameHblkShift
  MjpegFrameCntTriggerShift* = 16
  MjpegFrameCntTriggerMask* = 0x1F'u32 shl MjpegFrameCntTriggerShift

# =============================================================================
# Interrupt bits
# =============================================================================
const
  MjpegIntFrameDone* = 4      # Normal frame-count interrupt status
  MjpegIntFifoOver*  = 5      # Camera overflow interrupt status
  MjpegIntBufFull*   = 6      # Output memory interrupt status
  MjpegIntNormalClr* = 8
  MjpegIntCamClr*    = 9
  MjpegIntMemClr*    = 10
  MjpegIntFrameClr*  = 11

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
  discard quality

  # Disable during config
  regClear(MjpegControl, 1'u32 shl MjpegEn)

  # The BL808 frame-size register stores image block counts, not pixels.
  let wBlocks = (width + 15'u32) div 16'u32
  let hBlocks = (height + 15'u32) div 16'u32
  regWrite(MjpegFrameSize, (wBlocks shl MjpegFrameWblkShift) or
                         (hBlocks shl MjpegFrameHblkShift))

  var ctrl1 = (3'u32 shl MjpegWXlenShift) or (1'u32 shl MjpegReadFwrap) or
              (1'u32 shl MjpegBitOrder) or (1'u32 shl MjpegOrderUEven)
  if (width mod 16'u32) != 0:
    ctrl1 = ctrl1 or (1'u32 shl MjpegLastHfWblkDmy)
  regWrite(MjpegControl, ctrl1)

  # Set source addresses
  regWrite(MjpegYAddr, yAddr)
  regWrite(MjpegUvAddr, uvAddr)
  let rowBlocks = (height + 7'u32) div 8'u32
  regWrite(MjpegYuvMem, rowBlocks or ((rowBlocks div 2'u32) shl 16))

  # Set destination
  regWrite(MjpegDstAddr, dstAddr)
  regWrite(MjpegDstBufSize, dstBufSize div 128'u32)

  # Trigger the normal interrupt after one frame if interrupts are enabled.
  regModify(MjpegControl3, MjpegFrameCntTriggerMask, 1'u32 shl MjpegFrameCntTriggerShift)
  regModify(MjpegHeader, 0x0001_FFFF'u32, 0'u32)

  # Clear interrupts
  regWrite(MjpegFrameFifoPop, 0x3F00'u32)

proc mjpegStart*(mode: MjpegMode = mjpegSnapshot) =
  case mode
  of mjpegSnapshot:
    regModify(MjpegControl3, MjpegFrameCntTriggerMask, 1'u32 shl MjpegFrameCntTriggerShift)
  of mjpegContinuous:
    discard
  regSet(MjpegControl, 1'u32 shl MjpegEn)

proc mjpegStop*() =
  regClear(MjpegControl, 1'u32 shl MjpegEn)

proc mjpegTrigger*() =
  ## Software trigger one frame (for snapshot mode).
  regSet(MjpegControl2, 1'u32 shl MjpegSwRunBit)
  regClear(MjpegControl2, 1'u32 shl MjpegSwRunBit)

proc mjpegFrameDone*(): bool =
  (regRead(MjpegIntSts) and (1'u32 shl MjpegIntFrameDone)) != 0

proc mjpegClearFrameDone*() =
  regWrite(MjpegFrameFifoPop, 1'u32 shl MjpegIntNormalClr)

proc mjpegGetFrameSize*(): uint32 =
  ## Get the size of the last encoded JPEG frame in bytes.
  regRead(MjpegJpegSize)

proc mjpegGetFrameCount*(): uint32 =
  (regRead(MjpegControl3) shr 24) and 0x1F'u32

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
