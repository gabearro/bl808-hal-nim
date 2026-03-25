## BL808 DVP (Digital Video Port) and camera interface driver.
##
## DVP0-DVP7 at 0x30012000 (8 instances, stride 0x100)
## DVP_TSRC0 at 0x30012800, DVP_TSRC1 at 0x30012900
##
## Captures video frames from parallel camera interfaces (DVP) or
## from MIPI CSI-2 receivers, writing frames to memory via DMA.

import mmio, memmap

# =============================================================================
# DVP2AXI register offsets (per instance, stride = 0x100)
# =============================================================================
const
  DvpStride*        = 0x100'u

  DvpConfig*        = 0x00'u  # DVP configuration
  DvpFrameAddr0*    = 0x04'u  # Frame buffer 0 address
  DvpFrameAddr1*    = 0x08'u  # Frame buffer 1 address
  DvpFrameSize*     = 0x0C'u  # Frame size (hcount, vcount)
  DvpFramePeriod*   = 0x10'u  # Frame period
  DvpPixDataCtrl*   = 0x14'u  # Pixel data control
  DvpFifoThreshold* = 0x18'u  # FIFO threshold
  DvpIntSts*        = 0x20'u  # Interrupt status
  DvpIntMask*       = 0x24'u  # Interrupt mask
  DvpIntClr*        = 0x28'u  # Interrupt clear

  # DVP_TSRC registers (timing source)
  DvpTsrcStride*    = 0x100'u
  DvpTsrcConfig*    = 0x00'u  # TSRC configuration
  DvpTsrcFrameSize* = 0x04'u  # TSRC frame size
  DvpTsrcTotalSize* = 0x08'u  # TSRC total size (with blanking)
  DvpTsrcPix0*      = 0x0C'u  # TSRC pixel output 0
  DvpTsrcPix1*      = 0x10'u  # TSRC pixel output 1

# =============================================================================
# DVP_CONFIG fields
# =============================================================================
const
  DvpEn*            = 0       # DVP enable
  DvpSwMode*        = 1       # Software mode (vs hardware trigger)
  DvpFlipV*         = 4       # Vertical flip
  DvpFlipH*         = 5       # Horizontal flip
  DvpDropEn*        = 6       # Frame drop enable
  DvpDropPeriodShift* = 8     # Frame drop period [12:8]
  DvpDropPeriodMask*  = 0x1F'u32 shl 8
  DvpBurstShift*    = 16      # Burst length [17:16]
  DvpBurstMask*     = 0x03'u32 shl 16
  DvpDblBuf*        = 20      # Double buffer enable
  DvpFifoMode*      = 24      # FIFO mode

# =============================================================================
# DVP_FRAME_SIZE fields
# =============================================================================
const
  DvpHcountShift*   = 0       # Horizontal pixel count [12:0]
  DvpHcountMask*    = 0x1FFF'u32
  DvpVcountShift*   = 16      # Vertical line count [28:16]
  DvpVcountMask*    = 0x1FFF'u32 shl 16

# =============================================================================
# Interrupt bits
# =============================================================================
const
  DvpIntFrameDone*  = 0       # Frame capture done
  DvpIntFifoOver*   = 4       # FIFO overflow
  DvpIntHsync*      = 6       # HSYNC (line done)
  DvpIntVsync*      = 7       # VSYNC (frame start)

# =============================================================================
# Types
# =============================================================================
type
  DvpId* = range[0..7]

  DvpBurstLen* = enum
    dvpBurst1  = 0   # Single beat
    dvpBurst4  = 1   # 4-beat burst
    dvpBurst8  = 2   # 8-beat burst
    dvpBurst16 = 3   # 16-beat burst

  Dvp* = object
    base: uint
    id: DvpId

# =============================================================================
# DVP base address
# =============================================================================
proc dvpBase(id: DvpId): uint =
  Dvp0Base + id.uint * DvpStride

# =============================================================================
# DVP initialization
# =============================================================================
proc initDvp*(id: DvpId, width, height: uint32,
              frameBuf0, frameBuf1: uint32,
              burst: DvpBurstLen = dvpBurst8): Dvp =
  ## Initialize a DVP instance for frame capture.
  result.base = dvpBase(id)
  result.id = id
  let base = result.base

  # Disable during config
  regClear(base + DvpConfig, 1'u32 shl DvpEn)

  # Set frame size
  let frameSize = (width and 0x1FFF) or ((height and 0x1FFF) shl DvpVcountShift)
  regWrite(base + DvpFrameSize, frameSize)

  # Set frame buffer addresses
  regWrite(base + DvpFrameAddr0, frameBuf0)
  regWrite(base + DvpFrameAddr1, frameBuf1)

  # Configure
  var cfg = 0'u32
  cfg = cfg or (burst.uint32 shl DvpBurstShift)
  cfg = cfg or (1'u32 shl DvpDblBuf)  # Enable double buffering
  regWrite(base + DvpConfig, cfg)

  # Clear interrupts
  regWrite(base + DvpIntClr, 0xFF'u32)

proc enable*(dvp: Dvp) =
  regSet(dvp.base + DvpConfig, 1'u32 shl DvpEn)

proc disable*(dvp: Dvp) =
  regClear(dvp.base + DvpConfig, 1'u32 shl DvpEn)

proc setFlip*(dvp: Dvp, horizontal, vertical: bool) =
  let base = dvp.base + DvpConfig
  if horizontal: regSet(base, 1'u32 shl DvpFlipH)
  else: regClear(base, 1'u32 shl DvpFlipH)
  if vertical: regSet(base, 1'u32 shl DvpFlipV)
  else: regClear(base, 1'u32 shl DvpFlipV)

proc frameDone*(dvp: Dvp): bool =
  (regRead(dvp.base + DvpIntSts) and (1'u32 shl DvpIntFrameDone)) != 0

proc clearFrameDone*(dvp: Dvp) =
  regWrite(dvp.base + DvpIntClr, 1'u32 shl DvpIntFrameDone)

proc enableInterrupt*(dvp: Dvp, intBit: uint32) =
  regClear(dvp.base + DvpIntMask, 1'u32 shl intBit)

proc disableInterrupt*(dvp: Dvp, intBit: uint32) =
  regSet(dvp.base + DvpIntMask, 1'u32 shl intBit)
