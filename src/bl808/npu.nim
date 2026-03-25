## BL808 BLAI (Bouffalo Lab AI) NPU driver.
##
## BLAI/CNN at 0x30024000 — neural network inference accelerator.
## Supports basic CNN operations: convolution, pooling, activation.
## Model weights and layer configs are loaded into memory and the
## NPU processes them layer by layer.

import mmio, memmap

# =============================================================================
# NPU register offsets
# =============================================================================
const
  NpuCtrl*          = BlaiBase + 0x00'u   # NPU control
  NpuStatus*        = BlaiBase + 0x04'u   # NPU status
  NpuIntSts*        = BlaiBase + 0x08'u   # Interrupt status
  NpuIntMask*       = BlaiBase + 0x0C'u   # Interrupt mask
  NpuIntClr*        = BlaiBase + 0x10'u   # Interrupt clear
  NpuLayerCfg0*     = BlaiBase + 0x20'u   # Layer config 0
  NpuLayerCfg1*     = BlaiBase + 0x24'u   # Layer config 1
  NpuInputAddr*     = BlaiBase + 0x30'u   # Input data address
  NpuInputSize*     = BlaiBase + 0x34'u   # Input dimensions
  NpuOutputAddr*    = BlaiBase + 0x38'u   # Output data address
  NpuOutputSize*    = BlaiBase + 0x3C'u   # Output dimensions
  NpuWeightAddr*    = BlaiBase + 0x40'u   # Weight data address
  NpuBiasAddr*      = BlaiBase + 0x44'u   # Bias data address
  NpuKernelSize*    = BlaiBase + 0x48'u   # Kernel dimensions
  NpuStridepad*     = BlaiBase + 0x4C'u   # Stride and padding
  NpuActCfg*        = BlaiBase + 0x50'u   # Activation config
  NpuPoolCfg*       = BlaiBase + 0x54'u   # Pooling config
  NpuQuantCfg*      = BlaiBase + 0x58'u   # Quantization config

# =============================================================================
# NPU control fields
# =============================================================================
const
  NpuEn*            = 0       # NPU enable
  NpuLayerStart*    = 1       # Start processing current layer
  NpuSoftReset*     = 4       # Soft reset

# =============================================================================
# NPU status fields
# =============================================================================
const
  NpuBusy*          = 0       # NPU busy
  NpuLayerDone*     = 1       # Layer processing done

# =============================================================================
# Layer configuration
# =============================================================================
const
  # Layer type in LayerCfg0
  NpuLayerTypeShift* = 0      # Layer type [3:0]
  NpuLayerTypeMask*  = 0x0F'u32
  NpuLayerConv*     = 0       # Convolution
  NpuLayerPool*     = 1       # Pooling
  NpuLayerFC*       = 2       # Fully connected
  NpuLayerEltwise*  = 3       # Element-wise

  # Activation type in ActCfg
  NpuActTypeShift*  = 0       # Activation type [3:0]
  NpuActTypeMask*   = 0x0F'u32
  NpuActNone*       = 0
  NpuActRelu*       = 1
  NpuActRelu6*      = 2
  NpuActSigmoid*    = 3

  # Pooling type in PoolCfg
  NpuPoolTypeShift* = 0       # Pool type [1:0]
  NpuPoolTypeMask*  = 0x03'u32
  NpuPoolMax*       = 0
  NpuPoolAvg*       = 1

# =============================================================================
# Types
# =============================================================================
type
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

# =============================================================================
# NPU operations
# =============================================================================
proc npuInit*() =
  ## Initialize the NPU.
  # Soft reset
  regSet(NpuCtrl, 1'u32 shl NpuSoftReset)
  for i in 0 ..< 100: discard regRead(NpuCtrl)
  regClear(NpuCtrl, 1'u32 shl NpuSoftReset)

  # Clear interrupts
  regWrite(NpuIntClr, 0xFF)

  # Enable
  regSet(NpuCtrl, 1'u32 shl NpuEn)

proc npuConfigureConvLayer*(inputAddr, outputAddr, weightAddr, biasAddr: uint32,
                            inputW, inputH, inputC: uint32,
                            outputC: uint32,
                            kernelW, kernelH: uint32,
                            strideW, strideH: uint32,
                            padW, padH: uint32,
                            activation: NpuActivation = npuActRelu) =
  ## Configure a convolution layer.
  regWrite(NpuInputAddr, inputAddr)
  regWrite(NpuOutputAddr, outputAddr)
  regWrite(NpuWeightAddr, weightAddr)
  regWrite(NpuBiasAddr, biasAddr)

  # Input dimensions: W | H<<16 | C in a separate config word
  regWrite(NpuInputSize, (inputW and 0xFFF) or ((inputH and 0xFFF) shl 12) or
                         ((inputC and 0xFF) shl 24))

  # Output channels
  regWrite(NpuOutputSize, outputC and 0xFFFF)

  # Kernel size
  regWrite(NpuKernelSize, (kernelW and 0x0F) or ((kernelH and 0x0F) shl 4))

  # Stride and padding
  regWrite(NpuStridepad, (strideW and 0x0F) or ((strideH and 0x0F) shl 4) or
                         ((padW and 0x0F) shl 8) or ((padH and 0x0F) shl 12))

  # Layer type = convolution
  regModify(NpuLayerCfg0, NpuLayerTypeMask, NpuLayerConv.uint32)

  # Activation
  regModify(NpuActCfg, NpuActTypeMask, activation.uint32)

proc npuRunLayer*(timeout: uint32 = 5_000_000): NpuError =
  ## Start processing the configured layer and wait for completion.
  regWrite(NpuIntClr, 0xFF)
  regSet(NpuCtrl, 1'u32 shl NpuLayerStart)

  var countdown = timeout
  while countdown > 0:
    let sts = regRead(NpuStatus)
    if (sts and (1'u32 shl NpuLayerDone)) != 0:
      regWrite(NpuIntClr, 0xFF)
      return npuOk
    countdown.dec

  npuTimeout

proc npuIsBusy*(): bool =
  (regRead(NpuStatus) and (1'u32 shl NpuBusy)) != 0
