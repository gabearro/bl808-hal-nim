## BL808 DVP (Digital Video Port) camera interface driver.
##
## DVP0-DVP7 at 0x30012000 (8 instances, stride 0x100)
##
## Captures video frames from parallel camera interfaces (DVP) or
## from MIPI CSI-2 receivers, writing frames to memory via AXI DMA.
##
## Register layout from bouffalo_sdk cam_reg.h (BL808).

import mmio, memmap

# =============================================================================
# DVP2AXI register offsets (per instance, stride = 0x100)
# =============================================================================
const
  DvpStride*              = 0x100'u

  # --- Offsets from instance base ---
  Dvp2axiConfigure*       = 0x00'u   # DVP2AXI configuration
  Dvp2axiAddrStart*       = 0x04'u   # Frame buffer start address
  Dvp2axiMemBcnt*         = 0x08'u   # Memory burst count (buffer size)
  DvpStatusAndError*      = 0x0C'u   # Status / error / interrupt enables
  Dvp2axiFrameBcnt*       = 0x10'u   # Frame byte count (read-only)
  DvpFrameFifoPop*        = 0x14'u   # FIFO pop and interrupt clear
  Dvp2axiFrameVld*        = 0x18'u   # Frame N valid
  Dvp2axiFramePeriod*     = 0x1C'u   # Frame period
  Dvp2axiMisc*            = 0x20'u   # Alpha / RGB565 format
  Dvp2axiHsyncCrop*       = 0x30'u   # Hsync crop (start/end)
  Dvp2axiVsyncCrop*       = 0x34'u   # Vsync crop (start/end)
  Dvp2axiFramExm*         = 0x38'u   # Frame examine (total h/v counts)
  Dvp2axiFrameStartAddr0* = 0x40'u   # Frame start address 0
  Dvp2axiFrameStartAddr1* = 0x48'u   # Frame start address 1
  Dvp2axiFrameStartAddr2* = 0x50'u   # Frame start address 2
  Dvp2axiFrameStartAddr3* = 0x58'u   # Frame start address 3

# =============================================================================
# dvp2axi_configue fields (0x00)
# =============================================================================
const
  DvpEn*                  = 0        # DVP enable
  DvpSwMode*              = 1        # Software mode
  DvpFramVldPol*          = 2        # Frame valid polarity
  DvpLineVldPol*          = 3        # Line valid polarity
  DvpXlenShift*           = 4        # Burst length [6:4]
  DvpXlenMask*            = 0x07'u32 shl 4
  DvpModeShift*           = 8        # DVP mode [10:8]
  DvpModeMask*            = 0x07'u32 shl 8
  DvpHwModeFwrap*         = 11       # Hardware mode frame wrap
  DvpDropEn*              = 12       # Frame drop enable
  DvpDropEven*            = 13       # Drop even frames
  DvpQosSwMode*           = 14       # QoS software mode
  DvpQosSw*               = 15       # QoS software value
  DvpDataModeShift*       = 16       # DVP data mode [18:16]
  DvpDataModeMask*        = 0x07'u32 shl 16
  DvpDataBsel*            = 19       # DVP data byte select
  DvpPixClkCg*            = 20       # Pixel clock gate
  DvpVSubsampleEn*        = 22       # Vertical subsample enable
  DvpVSubsamplePol*       = 23       # Vertical subsample polarity
  DvpWaitCycleShift*      = 24       # Wait cycle [31:24]
  DvpWaitCycleMask*       = 0xFF'u32 shl 24

# =============================================================================
# dvp_status_and_error fields (0x0C)
# =============================================================================
const
  DvpFrameCntTrgShift*    = 0        # Frame count trigger [4:0]
  DvpFrameCntTrgMask*     = 0x1F'u32
  DvpIntHcntEn*           = 6        # Hcount interrupt enable
  DvpIntVcntEn*           = 7        # Vcount interrupt enable
  DvpIntNormalEn*         = 8        # Normal interrupt enable
  DvpIntMemEn*            = 9        # Memory interrupt enable
  DvpIntFrameEn*          = 10       # Frame interrupt enable
  DvpIntFifoEn*           = 11       # FIFO interrupt enable
  DvpStsNormalInt*        = 12       # Normal interrupt status (read-only)
  DvpStsMemInt*           = 13       # Memory interrupt status (read-only)
  DvpStsFrameInt*         = 14       # Frame interrupt status (read-only)
  DvpStsFifoInt*          = 15       # FIFO interrupt status (read-only)
  DvpFrameValidCntShift*  = 16       # Frame valid count [20:16] (read-only)
  DvpFrameValidCntMask*   = 0x1F'u32 shl 16
  DvpStsHcntInt*          = 21       # Hcount interrupt status (read-only)
  DvpStsVcntInt*          = 22       # Vcount interrupt status (read-only)
  DvpStBusIdle*           = 24       # Bus idle status
  DvpStDvpIdle*           = 29       # DVP idle status

# =============================================================================
# dvp_frame_fifo_pop fields (0x14)
# =============================================================================
const
  DvpRfifoPop*            = 0        # Read FIFO pop
  DvpIntNormalClr*        = 4        # Clear normal interrupt
  DvpIntMemClr*           = 5        # Clear memory interrupt
  DvpIntFrameClr*         = 6        # Clear frame interrupt
  DvpIntFifoClr*          = 7        # Clear FIFO interrupt
  DvpIntHcntClr*          = 8        # Clear hcount interrupt
  DvpIntVcntClr*          = 9        # Clear vcount interrupt

# =============================================================================
# dvp2axi_hsync_crop fields (0x30)
# =============================================================================
const
  DvpHsyncActEndShift*    = 0        # Hsync active end [15:0]
  DvpHsyncActEndMask*     = 0xFFFF'u32
  DvpHsyncActStartShift*  = 16       # Hsync active start [31:16]
  DvpHsyncActStartMask*   = 0xFFFF'u32 shl 16

# =============================================================================
# dvp2axi_vsync_crop fields (0x34)
# =============================================================================
const
  DvpVsyncActEndShift*    = 0        # Vsync active end [15:0]
  DvpVsyncActEndMask*     = 0xFFFF'u32
  DvpVsyncActStartShift*  = 16       # Vsync active start [31:16]
  DvpVsyncActStartMask*   = 0xFFFF'u32 shl 16

# =============================================================================
# dvp2axi_fram_exm fields (0x38)
# =============================================================================
const
  DvpTotalHcntShift*      = 0        # Total horizontal count [15:0]
  DvpTotalHcntMask*       = 0xFFFF'u32
  DvpTotalVcntShift*      = 16       # Total vertical count [31:16]
  DvpTotalVcntMask*       = 0xFFFF'u32 shl 16

# =============================================================================
# dvp2axi_misc fields (0x20)
# =============================================================================
const
  DvpAlphaShift*          = 0        # Alpha value [7:0]
  DvpAlphaMask*           = 0xFF'u32
  DvpFormat565Shift*      = 8        # RGB565 format [10:8]
  DvpFormat565Mask*       = 0x07'u32 shl 8

# =============================================================================
# dvp2axi_frame_period fields (0x1C)
# =============================================================================
const
  DvpFramePeriodShift*    = 0        # Frame period [4:0]
  DvpFramePeriodMask*     = 0x1F'u32

# =============================================================================
# Types
# =============================================================================
type
  DvpId* = range[0..7]

  DvpBurstLen* = enum
    dvpBurst1  = 0    # Single beat (INCR1)
    dvpBurst4  = 1    # 4-beat burst (INCR4)
    dvpBurst8  = 2    # 8-beat burst (INCR8)
    dvpBurst16 = 3    # 16-beat burst (INCR16)

  DvpMode* = range[0..7]

  DvpDataMode* = range[0..7]

  DvpError* = enum
    dvpOk
    dvpTimeout

  Dvp* = object
    base: uint
    id: DvpId

# =============================================================================
# DVP base address helper
# =============================================================================
proc dvpBase(id: DvpId): uint =
  Dvp0Base + id.uint * DvpStride

# =============================================================================
# DVP initialization
# =============================================================================
proc initDvp*(id: DvpId, frameBuf: uint32, bufSize: uint32,
              burst: DvpBurstLen = dvpBurst8,
              mode: DvpMode = 0,
              dataMode: DvpDataMode = 0): Dvp =
  ## Initialize a DVP instance for frame capture.
  result.base = dvpBase(id)
  result.id = id
  let base = result.base

  # Disable during config
  regClear(base + Dvp2axiConfigure, 1'u32 shl DvpEn)

  # Set frame buffer address and memory burst count
  regWrite(base + Dvp2axiAddrStart, frameBuf)
  regWrite(base + Dvp2axiMemBcnt, bufSize)

  # Configure: burst length, DVP mode, data mode
  var cfg = 0'u32
  cfg = cfg or (burst.uint32 shl DvpXlenShift)
  cfg = cfg or (mode.uint32 shl DvpModeShift)
  cfg = cfg or (dataMode.uint32 shl DvpDataModeShift)
  regWrite(base + Dvp2axiConfigure, cfg)

  # Clear all pending interrupts
  regWrite(base + DvpFrameFifoPop,
    (1'u32 shl DvpIntNormalClr) or (1'u32 shl DvpIntMemClr) or
    (1'u32 shl DvpIntFrameClr) or (1'u32 shl DvpIntFifoClr) or
    (1'u32 shl DvpIntHcntClr) or (1'u32 shl DvpIntVcntClr))

proc enable*(dvp: Dvp) =
  regSet(dvp.base + Dvp2axiConfigure, 1'u32 shl DvpEn)

proc disable*(dvp: Dvp) =
  regClear(dvp.base + Dvp2axiConfigure, 1'u32 shl DvpEn)

# =============================================================================
# Frame buffer management
# =============================================================================
proc setFrameBuffer*(dvp: Dvp, bufAddr: uint32) =
  ## Set the DMA target address.
  regWrite(dvp.base + Dvp2axiAddrStart, bufAddr)

proc setFrameStartAddr*(dvp: Dvp, index: range[0..3], frameAddr: uint32) =
  ## Set one of the four frame start addresses (0x40, 0x48, 0x50, 0x58).
  let offset = Dvp2axiFrameStartAddr0 + index.uint * 8
  regWrite(dvp.base + offset, frameAddr)

# =============================================================================
# Cropping
# =============================================================================
proc setCrop*(dvp: Dvp, hStart, hEnd, vStart, vEnd: uint16) =
  ## Set horizontal and vertical crop windows.
  regWrite(dvp.base + Dvp2axiHsyncCrop,
    hEnd.uint32 or (hStart.uint32 shl DvpHsyncActStartShift))
  regWrite(dvp.base + Dvp2axiVsyncCrop,
    vEnd.uint32 or (vStart.uint32 shl DvpVsyncActStartShift))

# =============================================================================
# Frame size (examine registers)
# =============================================================================
proc setFrameSize*(dvp: Dvp, hCount, vCount: uint16) =
  ## Set the expected total frame size (horizontal and vertical pixel counts).
  regWrite(dvp.base + Dvp2axiFramExm,
    hCount.uint32 or (vCount.uint32 shl DvpTotalVcntShift))

proc getFrameByteCount*(dvp: Dvp): uint32 =
  ## Get the number of bytes captured in the current frame.
  regRead(dvp.base + Dvp2axiFrameBcnt)

# =============================================================================
# Frame period
# =============================================================================
proc setFramePeriod*(dvp: Dvp, period: uint32) =
  ## Set frame period [4:0].
  regModify(dvp.base + Dvp2axiFramePeriod, DvpFramePeriodMask,
            period and DvpFramePeriodMask)

# =============================================================================
# Interrupt status and control
# =============================================================================
proc frameDone*(dvp: Dvp): bool =
  ## Check if a frame capture completed (normal interrupt status).
  (regRead(dvp.base + DvpStatusAndError) and (1'u32 shl DvpStsNormalInt)) != 0

proc clearFrameDone*(dvp: Dvp) =
  regSet(dvp.base + DvpFrameFifoPop, 1'u32 shl DvpIntNormalClr)

proc enableInterrupt*(dvp: Dvp, intBit: uint32) =
  ## Enable an interrupt in dvp_status_and_error (bits 6-11 are enables).
  regSet(dvp.base + DvpStatusAndError, 1'u32 shl intBit)

proc disableInterrupt*(dvp: Dvp, intBit: uint32) =
  ## Disable an interrupt in dvp_status_and_error.
  regClear(dvp.base + DvpStatusAndError, 1'u32 shl intBit)

proc clearInterrupt*(dvp: Dvp, clrBit: uint32) =
  ## Clear an interrupt via dvp_frame_fifo_pop (bits 4-9 are clears).
  regSet(dvp.base + DvpFrameFifoPop, 1'u32 shl clrBit)

# =============================================================================
# FIFO pop
# =============================================================================
proc fifoPopFrame*(dvp: Dvp) =
  ## Pop one frame from the read FIFO.
  regSet(dvp.base + DvpFrameFifoPop, 1'u32 shl DvpRfifoPop)

# =============================================================================
# Flip (achieved via crop manipulation)
# =============================================================================
proc setFlip*(dvp: Dvp, horizontal, vertical: bool) =
  ## Implement flip by swapping crop start/end values.
  ## Caller must have previously configured crop via setCrop.
  if horizontal:
    let hsync = regRead(dvp.base + Dvp2axiHsyncCrop)
    let hEnd = hsync and DvpHsyncActEndMask
    let hStart = (hsync and DvpHsyncActStartMask) shr DvpHsyncActStartShift
    regWrite(dvp.base + Dvp2axiHsyncCrop,
      hStart or (hEnd shl DvpHsyncActStartShift))
  if vertical:
    let vsync = regRead(dvp.base + Dvp2axiVsyncCrop)
    let vEnd = vsync and DvpVsyncActEndMask
    let vStart = (vsync and DvpVsyncActStartMask) shr DvpVsyncActStartShift
    regWrite(dvp.base + Dvp2axiVsyncCrop,
      vStart or (vEnd shl DvpVsyncActStartShift))

# =============================================================================
# Alpha / format
# =============================================================================
proc setAlpha*(dvp: Dvp, alpha: uint8) =
  ## Set the alpha value for output pixel data.
  regModify(dvp.base + Dvp2axiMisc, DvpAlphaMask, alpha.uint32)
