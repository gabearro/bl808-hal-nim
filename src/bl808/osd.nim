## BL808 OSD (On-Screen Display) driver.
##
## OSD_A at 0x30013000 — OSD blend layer A (overlay input)
## OSD_B at 0x30014000 — OSD blend layer B (overlay input)
## OSD_DP at 0x30015000 — OSD Display Pipeline (blending, output)
##
## The OSD subsystem composites multiple layers with alpha blending,
## color keying, and palette lookup for video overlay output.

import mmio, memmap

# =============================================================================
# OSD blend layer registers (OSD_A / OSD_B share the same layout)
# =============================================================================
const
  # Per-layer register offsets
  OsdLayerXConfig*  = 0x00'u  # X min/max
  OsdLayerYConfig*  = 0x04'u  # Y min/max
  OsdMemConfig0*    = 0x08'u  # Force shadow / layer enable
  OsdLayerConfig0*  = 0x14'u  # Pixel format, channel order, global alpha
  OsdLayerConfig1*  = 0x18'u  # Global color
  OsdLayerConfig2*  = 0x1C'u  # Palette color-key range
  OsdLayerConfig3*  = 0x20'u  # Color-key min/max A/R
  OsdLayerConfig4*  = 0x24'u  # Color-key min/max G/B
  OsdLayerConfig5*  = 0x28'u  # Color-key replacement A/R/G/B
  OsdLayerConfig6*  = 0x2C'u  # Color-key enable / palette update
  OsdLayerConfig7*  = 0x30'u  # Palette update color
  OsdLayerConfig8*  = 0x34'u  # 1-bit alpha values
  OsdError*         = 0x40'u  # FIFO drain status/mask
  OsdShadow*        = 0x44'u  # Shadow/preload counter
  OsdMemAddr*       = 0x60'u  # Frame buffer address
  OsdMemConfig2*    = 0x64'u  # Frame width/stride in 8-byte units
  OsdMemConfig3*    = 0x68'u  # Frame height and line fix bits
  OsdDrawOffset*    = 0x400'u # Draw block offset within each OSD block
  OsdDrawBlendEn*   = OsdDrawOffset + 0xF0'u

  # Backward-compatible names for the old simplified layer model.
  OsdConfig*        = OsdMemConfig0
  OsdHsize*         = OsdLayerXConfig
  OsdVsize*         = OsdLayerYConfig
  OsdHpos*          = OsdLayerXConfig
  OsdVpos*          = OsdLayerYConfig
  OsdMemStride*     = OsdMemConfig2
  OsdAlpha*         = OsdLayerConfig0
  OsdColorKey*      = OsdLayerConfig7
  OsdPalette*       = OsdLayerConfig7

# =============================================================================
# OSD blend fields
# =============================================================================
const
  OsdForceShadow*   = 0
  OsdLayerEn*       = 15
  OsdLayerEnMask*   = 1'u32 shl OsdLayerEn
  OsdFmtShift*      = 0
  OsdFmtMask*       = 0x1F'u32 shl OsdFmtShift
  OsdOrderAShift*   = 8
  OsdOrderAMask*    = 0x03'u32 shl OsdOrderAShift
  OsdOrderRvShift*  = 10
  OsdOrderRvMask*   = 0x03'u32 shl OsdOrderRvShift
  OsdOrderGyShift*  = 12
  OsdOrderGyMask*   = 0x03'u32 shl OsdOrderGyShift
  OsdOrderBuShift*  = 14
  OsdOrderBuMask*   = 0x03'u32 shl OsdOrderBuShift
  OsdGlobalAlphaEn* = 16
  OsdGlobalAlphaShift* = 24
  OsdGlobalAlphaMask* = 0xFF'u32 shl OsdGlobalAlphaShift
  OsdCkeyEn*        = 0       # Compatibility alias for OsdKeyColorEn
  OsdKeyColorEn*    = 0
  OsdFrameWidthByteX8Shift* = 0
  OsdFrameWidthByteX8Mask* = 0x3FFF'u32 shl OsdFrameWidthByteX8Shift
  OsdStrideByteX8Shift* = 16
  OsdStrideByteX8Mask* = 0x3FFF'u32 shl OsdStrideByteX8Shift
  OsdFrameHeightShift* = 0
  OsdFrameHeightMask* = 0x3FFF'u32 shl OsdFrameHeightShift

# =============================================================================
# Display pipeline (OSD_DP) registers
# =============================================================================
const
  OsdDpConfig*      = OsdDpBase + 0x00'u  # DP configuration
  OsdDpBgColor*     = OsdDpBase + 0x04'u  # Background color
  OsdDpHsize*       = OsdDpBase + 0x08'u  # Output horizontal size
  OsdDpVsize*       = OsdDpBase + 0x0C'u  # Output vertical size
  OsdDpGamma*       = OsdDpBase + 0x10'u  # Gamma configuration
  OsdDpIntSts*      = OsdDpBase + 0x20'u  # Interrupt status
  OsdDpIntMask*     = OsdDpBase + 0x24'u  # Interrupt mask
  OsdDpIntClr*      = OsdDpBase + 0x28'u  # Interrupt clear

# =============================================================================
# Types
# =============================================================================
type
  OsdLayer* = enum
    osdLayerA
    osdLayerB

  OsdPixelFmt* = enum
    osdArgb8888 = 0
    osdRgb888   = 1
    osdRgb565   = 2
    osdArgb4444 = 3
    osdArgb1555 = 4
    osdIndex8   = 5  # 8-bit palette indexed

proc layerBase(layer: OsdLayer): uint =
  case layer
  of osdLayerA: OsdABase
  of osdLayerB: OsdBBase

proc blendFormat(fmt: OsdPixelFmt): uint32 {.inline.} =
  case fmt
  of osdArgb8888: 0'u32
  of osdRgb888: 0'u32
  of osdRgb565: 6'u32
  of osdArgb4444: 2'u32
  of osdArgb1555: 4'u32
  of osdIndex8: 10'u32

proc bytesPerPixel(fmt: OsdPixelFmt): uint32 {.inline.} =
  case fmt
  of osdArgb8888: 4'u32
  of osdRgb888: 3'u32
  of osdRgb565, osdArgb4444, osdArgb1555: 2'u32
  of osdIndex8: 1'u32

proc enableLayerRegs(base: uint) =
  regSet(base + OsdMemConfig0, 1'u32 shl OsdForceShadow)
  regSet(base + OsdMemConfig0, OsdLayerEnMask)
  regSet(base + OsdDrawBlendEn, 1'u32)

# =============================================================================
# OSD layer operations
# =============================================================================
proc osdConfigureLayer*(layer: OsdLayer, width, height: uint32,
                        posX, posY: uint32, fbAddr: uint32,
                        fmt: OsdPixelFmt = osdRgb565,
                        alpha: uint8 = 255) =
  ## Configure an OSD overlay layer.
  let base = layerBase(layer)

  regClear(base + OsdMemConfig0, OsdLayerEnMask)

  regWrite(base + OsdLayerXConfig, ((posX + width - 1'u32) shl 16) or posX)
  regWrite(base + OsdLayerYConfig, ((posY + height - 1'u32) shl 16) or posY)
  regWrite(base + OsdMemAddr, fbAddr)

  let strideBytes = width * fmt.bytesPerPixel()
  let strideX8 = strideBytes div 8'u32
  regModify(base + OsdMemConfig2,
            OsdFrameWidthByteX8Mask or OsdStrideByteX8Mask,
            (strideX8 shl OsdFrameWidthByteX8Shift) or
            (strideX8 shl OsdStrideByteX8Shift))
  regModify(base + OsdMemConfig3, OsdFrameHeightMask,
            height shl OsdFrameHeightShift)

  var cfg0 = regRead(base + OsdLayerConfig0)
  cfg0 = cfg0 and not (OsdFmtMask or OsdOrderAMask or OsdOrderRvMask or
                       OsdOrderGyMask or OsdOrderBuMask or
                       (1'u32 shl OsdGlobalAlphaEn) or OsdGlobalAlphaMask)
  cfg0 = cfg0 or (fmt.blendFormat() shl OsdFmtShift)
  cfg0 = cfg0 or (3'u32 shl OsdOrderAShift) or (2'u32 shl OsdOrderRvShift) or
                (1'u32 shl OsdOrderGyShift) or (0'u32 shl OsdOrderBuShift)
  cfg0 = cfg0 or (1'u32 shl OsdGlobalAlphaEn) or
                (alpha.uint32 shl OsdGlobalAlphaShift)
  regWrite(base + OsdLayerConfig0, cfg0)

  regWrite(base + OsdShadow, 200)
  regWrite(base + OsdError, 1'u32 shl 1)
  enableLayerRegs(base)

proc osdEnableLayer*(layer: OsdLayer) =
  enableLayerRegs(layerBase(layer))

proc osdDisableLayer*(layer: OsdLayer) =
  regClear(layerBase(layer) + OsdMemConfig0, OsdLayerEnMask)

proc osdSetAlpha*(layer: OsdLayer, alpha: uint8) =
  let base = layerBase(layer)
  regModify(base + OsdLayerConfig0,
            (1'u32 shl OsdGlobalAlphaEn) or OsdGlobalAlphaMask,
            (1'u32 shl OsdGlobalAlphaEn) or
            (alpha.uint32 shl OsdGlobalAlphaShift))

proc osdSetColorKey*(layer: OsdLayer, color: uint32, enable: bool = true) =
  let base = layerBase(layer)
  regWrite(base + OsdLayerConfig7, color)
  if enable:
    regSet(base + OsdLayerConfig6, 1'u32 shl OsdKeyColorEn)
  else:
    regClear(base + OsdLayerConfig6, 1'u32 shl OsdKeyColorEn)

proc osdSetPosition*(layer: OsdLayer, x, y: uint32) =
  let base = layerBase(layer)
  let oldX = regRead(base + OsdLayerXConfig)
  let oldY = regRead(base + OsdLayerYConfig)
  let width = ((oldX shr 16) and 0xFFF'u32) - (oldX and 0xFFF'u32) + 1'u32
  let height = ((oldY shr 16) and 0xFFF'u32) - (oldY and 0xFFF'u32) + 1'u32
  regWrite(base + OsdLayerXConfig, ((x + width - 1'u32) shl 16) or x)
  regWrite(base + OsdLayerYConfig, ((y + height - 1'u32) shl 16) or y)

# =============================================================================
# Display pipeline
# =============================================================================
proc osdDpInit*(width, height: uint32, bgColor: uint32 = 0) =
  ## Initialize the OSD display pipeline.
  regWrite(OsdDpHsize, width)
  regWrite(OsdDpVsize, height)
  regWrite(OsdDpBgColor, bgColor)
  regSet(OsdDpConfig, 1'u32)  # Enable DP
