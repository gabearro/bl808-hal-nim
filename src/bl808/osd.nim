## BL808 OSD (On-Screen Display) driver.
##
## OSD_A at 0x30013000 — OSD layer A (overlay input)
## OSD_B at 0x30014000 — OSD layer B (overlay input)
## OSD_DP at 0x30015000 — OSD Display Pipeline (blending, output)
##
## The OSD subsystem composites multiple layers with alpha blending,
## color keying, and palette lookup for video overlay output.

import mmio, memmap

# =============================================================================
# OSD layer registers (OSD_A / OSD_B share the same layout)
# =============================================================================
const
  # Per-layer register offsets
  OsdConfig*        = 0x00'u  # Layer configuration
  OsdHsize*         = 0x04'u  # Horizontal size
  OsdVsize*         = 0x08'u  # Vertical size
  OsdHpos*          = 0x0C'u  # Horizontal position
  OsdVpos*          = 0x10'u  # Vertical position
  OsdMemAddr*       = 0x14'u  # Frame buffer address
  OsdMemStride*     = 0x18'u  # Memory stride (bytes per line)
  OsdAlpha*         = 0x1C'u  # Alpha value
  OsdColorKey*      = 0x20'u  # Color key value
  OsdPalette*       = 0x100'u # Palette table (256 entries, if indexed mode)

# =============================================================================
# OSD_CONFIG fields
# =============================================================================
const
  OsdLayerEn*       = 0       # Layer enable
  OsdFmtShift*      = 4       # Pixel format [6:4]
  OsdFmtMask*       = 0x07'u32 shl 4
  OsdCkeyEn*        = 8       # Color key enable
  OsdAlphaMode*     = 12      # Alpha mode (0=global, 1=per-pixel)

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

# =============================================================================
# OSD layer operations
# =============================================================================
proc osdConfigureLayer*(layer: OsdLayer, width, height: uint32,
                        posX, posY: uint32, fbAddr: uint32,
                        fmt: OsdPixelFmt = osdRgb565,
                        alpha: uint8 = 255) =
  ## Configure an OSD overlay layer.
  let base = layerBase(layer)

  regWrite(base + OsdHsize, width)
  regWrite(base + OsdVsize, height)
  regWrite(base + OsdHpos, posX)
  regWrite(base + OsdVpos, posY)
  regWrite(base + OsdMemAddr, fbAddr)

  # Calculate stride based on format
  let bytesPerPix = case fmt
    of osdArgb8888: 4'u32
    of osdRgb888: 3'u32
    of osdRgb565, osdArgb4444, osdArgb1555: 2'u32
    of osdIndex8: 1'u32
  regWrite(base + OsdMemStride, width * bytesPerPix)

  regWrite(base + OsdAlpha, alpha.uint32)

  var cfg = (1'u32 shl OsdLayerEn) or (fmt.uint32 shl OsdFmtShift)
  regWrite(base + OsdConfig, cfg)

proc osdEnableLayer*(layer: OsdLayer) =
  regSet(layerBase(layer) + OsdConfig, 1'u32 shl OsdLayerEn)

proc osdDisableLayer*(layer: OsdLayer) =
  regClear(layerBase(layer) + OsdConfig, 1'u32 shl OsdLayerEn)

proc osdSetAlpha*(layer: OsdLayer, alpha: uint8) =
  regWrite(layerBase(layer) + OsdAlpha, alpha.uint32)

proc osdSetColorKey*(layer: OsdLayer, color: uint32, enable: bool = true) =
  let base = layerBase(layer)
  regWrite(base + OsdColorKey, color)
  if enable:
    regSet(base + OsdConfig, 1'u32 shl OsdCkeyEn)
  else:
    regClear(base + OsdConfig, 1'u32 shl OsdCkeyEn)

proc osdSetPosition*(layer: OsdLayer, x, y: uint32) =
  let base = layerBase(layer)
  regWrite(base + OsdHpos, x)
  regWrite(base + OsdVpos, y)

# =============================================================================
# Display pipeline
# =============================================================================
proc osdDpInit*(width, height: uint32, bgColor: uint32 = 0) =
  ## Initialize the OSD display pipeline.
  regWrite(OsdDpHsize, width)
  regWrite(OsdDpVsize, height)
  regWrite(OsdDpBgColor, bgColor)
  regSet(OsdDpConfig, 1'u32)  # Enable DP
