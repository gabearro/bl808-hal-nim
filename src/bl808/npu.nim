## BL808 BLAI/CNN NPU integration helpers.
##
## The public BL808 SDK exposes BLAI through MM clock/reset control, SRAM
## ownership, and codec bus/QoS registers. The neural-network layer programming
## path is instruction-stream based, so this module avoids pretending that the
## BLAI aperture contains simple convolution layer dimension registers.

import mmio, memmap

# =============================================================================
# SDK-documented BLAI integration registers
# =============================================================================
const
  MmCnnClock*       = MmGlbBase + 0x04'u  # MM_GLB_MM_CLK_CPU
  MmCnnReset*       = MmGlbBase + 0x4C'u  # MM_GLB_SW_RESET_CODEC_SUB
  MmVramCtrl*       = MmMiscBase + 0x50'u # MM_MISC_VRAM_CTRL

  CodecBusCtrl*     = CodecMiscBase + 0x00'u
  CodecQosCtrl*     = CodecMiscBase + 0x04'u
  CodecBusThreshold* = CodecMiscBase + 0x08'u
  BlaiLimiterRead*  = CodecMiscBase + 0x20'u
  BlaiLimiterWrite* = CodecMiscBase + 0x24'u

# =============================================================================
# BLAI aperture registers observed on hardware
# =============================================================================
const
  BlaiCoreCfg0*     = BlaiBase + 0x00'u
  BlaiCoreCfg1*     = BlaiBase + 0x04'u
  BlaiCoreCfg2*     = BlaiBase + 0x08'u
  BlaiIntClear*     = BlaiBase + 0x10'u

  # Legacy aliases retained for code that only needs raw register access.
  NpuCtrl*          = BlaiCoreCfg0
  NpuStatus*        = BlaiCoreCfg1
  NpuIntSts*        = BlaiCoreCfg2
  NpuIntClr*        = BlaiIntClear

# =============================================================================
# MM_GLB/MM_MISC/Codec bit fields
# =============================================================================
const
  CnnClkDivEn*      = 8
  CnnClkSelShift*   = 9
  CnnClkDivShift*   = 12
  CnnClkDivEnMask*  = 1'u32 shl CnnClkDivEn
  CnnClkSelMask*    = 0x03'u32 shl CnnClkSelShift
  CnnClkDivMask*    = 0x07'u32 shl CnnClkDivShift

  CnnReset*         = 4
  CnnResetMask*     = 1'u32 shl CnnReset

  SysramSet*        = 0
  BlaiSramRel*      = 7
  BlaiSramSel*      = 15
  SysramSetMask*    = 1'u32 shl SysramSet
  BlaiSramRelMask*  = 1'u32 shl BlaiSramRel
  BlaiSramSelMask*  = 1'u32 shl BlaiSramSel

  CnnAwqos*         = 10
  CnnArqos*         = 11
  CnnAwqosMask*     = 1'u32 shl CnnAwqos
  CnnArqosMask*     = 1'u32 shl CnnArqos

  BlaiLimiterCountMask* = 0x0000_FFFF'u32
  BlaiLimiterMode*      = 31
  BlaiLimiterModeMask*  = 1'u32 shl BlaiLimiterMode

# =============================================================================
# Compatibility types
# =============================================================================
type
  NpuClockSource* = enum
    npuClk160M = 0
    npuClk240M = 1
    npuClk320M = 2

  NpuLayerType* = enum
    npuConv     = 0
    npuPool     = 1
    npuFC       = 2
    npuEltwise  = 3

  NpuActivation* = enum
    npuActNone    = 0
    npuActRelu    = 1
    npuActRelu6   = 2
    npuActSigmoid = 3

  NpuPoolType* = enum
    npuMaxPool = 0
    npuAvgPool = 1

  NpuError* = enum
    npuOk
    npuTimeout
    npuBusy
    npuUnsupported

# =============================================================================
# NPU integration operations
# =============================================================================
proc npuSetClock*(enable: bool = true,
                  source: NpuClockSource = npuClk160M,
                  divider: uint32 = 0) =
  ## Configure the SDK-documented CNN clock selector/divider.
  var value = ((source.uint32 and 0x03'u32) shl CnnClkSelShift) or
              ((divider and 0x07'u32) shl CnnClkDivShift)
  if enable:
    value = value or CnnClkDivEnMask
  regModify(MmCnnClock, CnnClkDivEnMask or CnnClkSelMask or CnnClkDivMask, value)

proc npuClockEnabled*(): bool =
  (regRead(MmCnnClock) and CnnClkDivEnMask) != 0

proc npuHoldReset*() =
  ## Assert the CNN reset bit in MM_GLB_SW_RESET_CODEC_SUB.
  regSet(MmCnnReset, CnnResetMask)

proc npuReleaseReset*() =
  ## Deassert the CNN reset bit in MM_GLB_SW_RESET_CODEC_SUB.
  regClear(MmCnnReset, CnnResetMask)

proc npuReset*() =
  npuHoldReset()
  for _ in 0 ..< 64:
    discard regRead(MmCnnReset)
  npuReleaseReset()

proc npuReleaseSram*() =
  ## Make the BLAI SRAM banks available and latch the SYSRAM_SET update.
  var value = regRead(MmVramCtrl) or BlaiSramRelMask
  regWrite(MmVramCtrl, value)
  regWrite(MmVramCtrl, value or SysramSetMask)

proc npuSramReleased*(): bool =
  (regRead(MmVramCtrl) and BlaiSramRelMask) != 0

proc npuSetCodecQos*(aw: bool = true, ar: bool = true) =
  var value = 0'u32
  if aw:
    value = value or CnnAwqosMask
  if ar:
    value = value or CnnArqosMask
  regModify(CodecQosCtrl, CnnAwqosMask or CnnArqosMask, value)

proc npuSetBusLimiters*(readCount, writeCount: uint32,
                        readMode: bool = true,
                        writeMode: bool = true) =
  var rd = readCount and BlaiLimiterCountMask
  var wr = writeCount and BlaiLimiterCountMask
  if readMode:
    rd = rd or BlaiLimiterModeMask
  if writeMode:
    wr = wr or BlaiLimiterModeMask
  regWrite(BlaiLimiterRead, rd)
  regWrite(BlaiLimiterWrite, wr)

proc npuInit*() =
  ## Bring the BLAI/CNN integration block into a usable reset/clock state.
  npuSetClock(enable = true, source = npuClk160M, divider = 0)
  npuReset()
  npuReleaseSram()

proc npuConfigureConvLayer*(inputAddr, outputAddr, weightAddr, biasAddr: uint32,
                            inputW, inputH, inputC: uint32,
                            outputC: uint32,
                            kernelW, kernelH: uint32,
                            strideW, strideH: uint32,
                            padW, padH: uint32,
                            activation: NpuActivation = npuActRelu) =
  ## Compatibility stub.
  ##
  ## BL808 BLAI layer execution is driven by encoded instruction streams. The
  ## simple layer-dimension registers previously used here do not retain writes
  ## on hardware, so this proc intentionally performs no MMIO.
  discard inputAddr
  discard outputAddr
  discard weightAddr
  discard biasAddr
  discard inputW
  discard inputH
  discard inputC
  discard outputC
  discard kernelW
  discard kernelH
  discard strideW
  discard strideH
  discard padW
  discard padH
  discard activation

proc npuRunLayer*(timeout: uint32 = 5_000_000): NpuError =
  ## Direct layer launch is not exposed by the hardware register map we have.
  discard timeout
  npuUnsupported

proc npuIsBusy*(): bool =
  false
