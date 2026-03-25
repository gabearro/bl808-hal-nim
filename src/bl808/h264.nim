## BL808 H.264 video encoder driver.
##
## H264 encoder at 0x30022000 — hardware H.264 baseline profile encoder.
## Encodes YUV420 frames into H.264 elementary stream.

import mmio, memmap

# =============================================================================
# H.264 encoder register offsets
# =============================================================================
const
  H264Ctrl*         = H264Base + 0x00'u   # Encoder control
  H264FrameSize*    = H264Base + 0x04'u   # Frame size (width x height)
  H264Qp*           = H264Base + 0x08'u   # Quantization parameter
  H264BitrateCfg*   = H264Base + 0x0C'u   # Bitrate control config
  H264SrcYAddr*     = H264Base + 0x10'u   # Y plane source address
  H264SrcUvAddr*    = H264Base + 0x14'u   # UV plane source address
  H264SrcStride*    = H264Base + 0x18'u   # Source stride
  H264DstAddr*      = H264Base + 0x1C'u   # Output bitstream address
  H264DstBufSize*   = H264Base + 0x20'u   # Output buffer size
  H264GopSize*      = H264Base + 0x24'u   # GOP (Group of Pictures) size
  H264RefAddr*      = H264Base + 0x28'u   # Reference frame address
  H264ReconAddr*    = H264Base + 0x2C'u   # Reconstructed frame address
  H264IntSts*       = H264Base + 0x30'u   # Interrupt status
  H264IntMask*      = H264Base + 0x34'u   # Interrupt mask
  H264IntClr*       = H264Base + 0x38'u   # Interrupt clear
  H264FrameCount*   = H264Base + 0x3C'u   # Encoded frame count
  H264BsSize*       = H264Base + 0x40'u   # Encoded bitstream size
  H264HeaderSize*   = H264Base + 0x44'u   # Header size
  H264SrcCfg*       = H264Base + 0x48'u   # Source configuration
  H264Padding*      = H264Base + 0x4C'u   # Padding configuration

# =============================================================================
# Control fields
# =============================================================================
const
  H264En*           = 0       # Encoder enable
  H264ModeShift*    = 1       # Encode mode [2:1]: 0=I only, 1=IP
  H264ModeMask*     = 0x03'u32 shl 1
  H264SwRun*        = 4       # Software trigger
  H264ForceI*       = 8       # Force I-frame

# =============================================================================
# Types
# =============================================================================
type
  H264EncMode* = enum
    h264IOnly = 0  # I-frames only
    h264IP    = 1  # I and P frames

  H264Error* = enum
    h264Ok
    h264Timeout
    h264BufFull

# =============================================================================
# H.264 encoder operations
# =============================================================================
proc h264Init*(width, height: uint32, qp: uint32 = 28, gopSize: uint32 = 30,
               srcYAddr, srcUvAddr: uint32, dstAddr, dstBufSize: uint32,
               refAddr, reconAddr: uint32) =
  ## Initialize H.264 encoder.
  regClear(H264Ctrl, 1'u32 shl H264En)

  regWrite(H264FrameSize, (width and 0xFFFF) or ((height and 0xFFFF) shl 16))
  regWrite(H264Qp, qp and 0x3F)
  regWrite(H264GopSize, gopSize)
  regWrite(H264SrcYAddr, srcYAddr)
  regWrite(H264SrcUvAddr, srcUvAddr)
  regWrite(H264SrcStride, width)
  regWrite(H264DstAddr, dstAddr)
  regWrite(H264DstBufSize, dstBufSize)
  regWrite(H264RefAddr, refAddr)
  regWrite(H264ReconAddr, reconAddr)

  regWrite(H264IntClr, 0xFF)

proc h264Start*(mode: H264EncMode = h264IP) =
  regModify(H264Ctrl, H264ModeMask, mode.uint32 shl H264ModeShift)
  regSet(H264Ctrl, 1'u32 shl H264En)

proc h264Stop*() =
  regClear(H264Ctrl, 1'u32 shl H264En)

proc h264EncodeFrame*(): H264Error =
  ## Trigger encoding of one frame and wait for completion.
  regSet(H264Ctrl, 1'u32 shl H264SwRun)
  var timeout = 5_000_000'u32
  while (regRead(H264IntSts) and 1) == 0:
    timeout.dec
    if timeout == 0: return h264Timeout
  regWrite(H264IntClr, 1)
  h264Ok

proc h264ForceIFrame*() =
  regSet(H264Ctrl, 1'u32 shl H264ForceI)

proc h264GetBitstreamSize*(): uint32 =
  regRead(H264BsSize)

proc h264GetFrameCount*(): uint32 =
  regRead(H264FrameCount)
