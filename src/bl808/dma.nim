## BL808 DMA controller driver.
##
## DMA0 at 0x2000C000 — 8 channels, MCU subsystem (M0/LP)
## DMA1 at 0x20071000 — 8 channels, MCU subsystem
## DMA2 at 0x30001000 — 8 channels, MM subsystem (D0)
##
## All share the same register layout. Each channel can do:
## - Memory-to-memory
## - Memory-to-peripheral
## - Peripheral-to-memory
## - Linked list (scatter-gather) transfers

import mmio, memmap

# =============================================================================
# Global DMA register offsets
# =============================================================================
const
  DmaIntStatus*     = 0x00'u  # Combined interrupt status
  DmaIntTcStatus*   = 0x04'u  # Transfer complete interrupt status
  DmaIntTcClear*    = 0x08'u  # TC interrupt clear
  DmaIntErrStatus*  = 0x0C'u  # Error interrupt status
  DmaIntErrClear*   = 0x10'u  # Error interrupt clear
  DmaRawIntTc*      = 0x14'u  # Raw TC interrupt status
  DmaRawIntErr*     = 0x18'u  # Raw error interrupt status
  DmaEnabledChns*   = 0x1C'u  # Enabled channels
  DmaSoftBReq*      = 0x20'u  # Software burst request
  DmaSoftSReq*      = 0x24'u  # Software single request
  DmaSoftLBReq*     = 0x28'u  # Software last burst request
  DmaSoftLSReq*     = 0x2C'u  # Software last single request
  DmaTopConfig*     = 0x30'u  # DMA enable/config
  DmaSync*          = 0x34'u  # DMA synchronization

# =============================================================================
# Per-channel register offsets (channel N at base + 0x100 + N * 0x100)
# =============================================================================
const
  DmaChSrcAddr*     = 0x00'u  # Source address
  DmaChDstAddr*     = 0x04'u  # Destination address
  DmaChLli*         = 0x08'u  # Linked list item pointer
  DmaChControl*     = 0x0C'u  # Channel control
  DmaChConfig*      = 0x10'u  # Channel configuration

proc channelBase(dmaBase: uint, ch: uint32): uint {.inline.} =
  dmaBase + 0x100 + ch * 0x100

# =============================================================================
# Channel control register fields
# =============================================================================
const
  CtrlTransferSizeMask* = 0xFFF'u32    # Transfer size [11:0]
  CtrlSBSizeShift*      = 12           # Source burst size [13:12]
  CtrlSBSizeMask*       = 0x03'u32 shl 12
  CtrlDBSizeShift*      = 15           # Dest burst size [16:15]
  CtrlDBSizeMask*       = 0x03'u32 shl 15
  CtrlSWidthShift*      = 18           # Source transfer width [19:18]
  CtrlSWidthMask*       = 0x03'u32 shl 18
  CtrlDWidthShift*      = 21           # Dest transfer width [22:21]
  CtrlDWidthMask*       = 0x03'u32 shl 21
  CtrlSrcIncr*          = 26           # Source address increment
  CtrlDstIncr*          = 27           # Dest address increment
  CtrlTcIntEnable*      = 31           # TC interrupt enable

# =============================================================================
# Channel config register fields
# =============================================================================
const
  CfgEnable*            = 0            # Channel enable
  CfgSrcPeriphShift*    = 1            # Source peripheral [5:1]
  CfgSrcPeriphMask*     = 0x1F'u32 shl 1
  CfgDstPeriphShift*    = 6            # Dest peripheral [10:6]
  CfgDstPeriphMask*     = 0x1F'u32 shl 6
  CfgFlowCntrlShift*    = 11           # Flow control [13:11]
  CfgFlowCntrlMask*     = 0x07'u32 shl 11
  CfgIntErrMask*        = 14           # Error interrupt mask
  CfgIntTcMask*         = 15           # TC interrupt mask
  CfgLock*              = 16           # Locked transfer
  CfgActive*            = 17           # Channel active (read-only)
  CfgHalt*              = 18           # Channel halt

# =============================================================================
# Types
# =============================================================================
type
  DmaId* = enum
    dma0
    dma1
    dma2

  DmaChannel* = range[0..7]

  DmaBurstSize* = enum
    burst1   = 0
    burst4   = 1
    burst8   = 2
    burst16  = 3

  DmaWidth* = enum
    width8   = 0   # Byte
    width16  = 1   # Half-word
    width32  = 2   # Word

  DmaFlowControl* = enum
    flowM2M_Dma     = 0  # Memory to memory, DMA controlled
    flowM2P_Dma     = 1  # Memory to peripheral, DMA controlled
    flowP2M_Dma     = 2  # Peripheral to memory, DMA controlled
    flowP2P_Dma     = 3  # Peripheral to peripheral, DMA controlled
    flowP2P_DstCtrl = 4  # P2P, destination controlled
    flowM2P_PeriCtrl = 5 # M2P, peripheral controlled
    flowP2M_PeriCtrl = 6 # P2M, peripheral controlled
    flowP2P_SrcCtrl = 7  # P2P, source controlled

  DmaPeriphId* = enum
    ## Peripheral request IDs for DMA0/DMA1
    dmaPeriphUart0Rx  = 0
    dmaPeriphUart0Tx  = 1
    dmaPeriphUart1Rx  = 2
    dmaPeriphUart1Tx  = 3
    dmaPeriphUart2Rx  = 4
    dmaPeriphUart2Tx  = 5
    dmaPeriphI2c0Rx   = 6
    dmaPeriphI2c0Tx   = 7
    dmaPeriphSpi0Rx   = 10
    dmaPeriphSpi0Tx   = 11
    dmaPeriphI2c1Rx   = 14
    dmaPeriphI2c1Tx   = 15
    dmaPeriphI2sRx    = 16
    dmaPeriphI2sTx    = 17

  DmaTransferConfig* = object
    srcAddr*: uint32
    dstAddr*: uint32
    transferSize*: uint32       ## Number of transfers (max 4095)
    srcWidth*: DmaWidth
    dstWidth*: DmaWidth
    srcBurst*: DmaBurstSize
    dstBurst*: DmaBurstSize
    srcIncrement*: bool         ## Auto-increment source address
    dstIncrement*: bool         ## Auto-increment destination address
    flow*: DmaFlowControl
    srcPeriph*: uint32          ## Source peripheral ID (for P2M/P2P)
    dstPeriph*: uint32          ## Dest peripheral ID (for M2P/P2P)
    enableTcInt*: bool          ## Enable TC interrupt

  DmaLli* {.packed.} = object
    ## Linked List Item for scatter-gather DMA.
    srcAddr*: uint32
    dstAddr*: uint32
    nextLli*: uint32  ## Address of next LLI (0 = end of chain)
    control*: uint32

  Dma* = object
    base: uint
    id: DmaId

# =============================================================================
# DMA base address
# =============================================================================
proc dmaBase(id: DmaId): uint =
  case id
  of dma0: Dma0Base
  of dma1: Dma1Base
  of dma2: Dma2Base

# =============================================================================
# DMA controller initialization
# =============================================================================
proc initDma*(id: DmaId): Dma =
  ## Initialize a DMA controller: enable it and clear all interrupts.
  result.base = dmaBase(id)
  result.id = id
  let base = result.base

  # Enable the DMA controller
  regSet(base + DmaTopConfig, 1'u32)

  # Clear all TC and error interrupts
  regWrite(base + DmaIntTcClear, 0xFF'u32)
  regWrite(base + DmaIntErrClear, 0xFF'u32)

# =============================================================================
# Channel operations
# =============================================================================
proc configureChannel*(dma: Dma, ch: DmaChannel, config: DmaTransferConfig) =
  ## Configure a DMA channel for a transfer. Does not start it.
  let chBase = channelBase(dma.base, ch.uint32)

  # Set addresses
  regWrite(chBase + DmaChSrcAddr, config.srcAddr)
  regWrite(chBase + DmaChDstAddr, config.dstAddr)

  # No linked list
  regWrite(chBase + DmaChLli, 0)

  # Build control register
  var ctrl = config.transferSize and CtrlTransferSizeMask
  ctrl = ctrl or (config.srcBurst.uint32 shl CtrlSBSizeShift)
  ctrl = ctrl or (config.dstBurst.uint32 shl CtrlDBSizeShift)
  ctrl = ctrl or (config.srcWidth.uint32 shl CtrlSWidthShift)
  ctrl = ctrl or (config.dstWidth.uint32 shl CtrlDWidthShift)
  if config.srcIncrement:
    ctrl = ctrl or (1'u32 shl CtrlSrcIncr)
  if config.dstIncrement:
    ctrl = ctrl or (1'u32 shl CtrlDstIncr)
  if config.enableTcInt:
    ctrl = ctrl or (1'u32 shl CtrlTcIntEnable)
  regWrite(chBase + DmaChControl, ctrl)

  # Build config register
  var cfg = 0'u32
  cfg = cfg or ((config.srcPeriph and 0x1F) shl CfgSrcPeriphShift)
  cfg = cfg or ((config.dstPeriph and 0x1F) shl CfgDstPeriphShift)
  cfg = cfg or (config.flow.uint32 shl CfgFlowCntrlShift)
  if config.enableTcInt:
    cfg = cfg or (1'u32 shl CfgIntTcMask)
    cfg = cfg or (1'u32 shl CfgIntErrMask)
  regWrite(chBase + DmaChConfig, cfg)

proc configureChannelLli*(dma: Dma, ch: DmaChannel, firstLli: ptr DmaLli,
                          config: DmaTransferConfig) =
  ## Configure a DMA channel with a linked list.
  let chBase = channelBase(dma.base, ch.uint32)

  # Load first LLI
  regWrite(chBase + DmaChSrcAddr, firstLli.srcAddr)
  regWrite(chBase + DmaChDstAddr, firstLli.dstAddr)
  regWrite(chBase + DmaChLli, firstLli.nextLli)
  regWrite(chBase + DmaChControl, firstLli.control)

  # Config register
  var cfg = 0'u32
  cfg = cfg or ((config.srcPeriph and 0x1F) shl CfgSrcPeriphShift)
  cfg = cfg or ((config.dstPeriph and 0x1F) shl CfgDstPeriphShift)
  cfg = cfg or (config.flow.uint32 shl CfgFlowCntrlShift)
  if config.enableTcInt:
    cfg = cfg or (1'u32 shl CfgIntTcMask)
    cfg = cfg or (1'u32 shl CfgIntErrMask)
  regWrite(chBase + DmaChConfig, cfg)

proc startChannel*(dma: Dma, ch: DmaChannel) =
  ## Start (enable) a DMA channel.
  let chBase = channelBase(dma.base, ch.uint32)
  regSet(chBase + DmaChConfig, 1'u32 shl CfgEnable)

proc stopChannel*(dma: Dma, ch: DmaChannel) =
  ## Stop (disable) a DMA channel.
  let chBase = channelBase(dma.base, ch.uint32)
  regClear(chBase + DmaChConfig, 1'u32 shl CfgEnable)

proc channelActive*(dma: Dma, ch: DmaChannel): bool =
  let chBase = channelBase(dma.base, ch.uint32)
  (regRead(chBase + DmaChConfig) and (1'u32 shl CfgActive)) != 0

proc channelEnabled*(dma: Dma, ch: DmaChannel): bool =
  (regRead(dma.base + DmaEnabledChns) and (1'u32 shl ch.uint32)) != 0

# =============================================================================
# Interrupt handling
# =============================================================================
proc tcInterruptPending*(dma: Dma, ch: DmaChannel): bool =
  (regRead(dma.base + DmaIntTcStatus) and (1'u32 shl ch.uint32)) != 0

proc errInterruptPending*(dma: Dma, ch: DmaChannel): bool =
  (regRead(dma.base + DmaIntErrStatus) and (1'u32 shl ch.uint32)) != 0

proc clearTcInterrupt*(dma: Dma, ch: DmaChannel) =
  regWrite(dma.base + DmaIntTcClear, 1'u32 shl ch.uint32)

proc clearErrInterrupt*(dma: Dma, ch: DmaChannel) =
  regWrite(dma.base + DmaIntErrClear, 1'u32 shl ch.uint32)

proc clearAllInterrupts*(dma: Dma) =
  regWrite(dma.base + DmaIntTcClear, 0xFF'u32)
  regWrite(dma.base + DmaIntErrClear, 0xFF'u32)

# =============================================================================
# Convenience: blocking memory-to-memory transfer
# =============================================================================
proc memcopy*(dma: Dma, ch: DmaChannel, dst, src: uint32, sizeBytes: uint32): bool =
  ## Blocking memory-to-memory copy using DMA. Returns true on success.
  ## Max 4095 * 4 = 16380 bytes per transfer.
  let wordCount = (sizeBytes + 3) div 4  # Round up to words
  if wordCount > 4095: return false

  let config = DmaTransferConfig(
    srcAddr: src,
    dstAddr: dst,
    transferSize: wordCount,
    srcWidth: width32,
    dstWidth: width32,
    srcBurst: burst4,
    dstBurst: burst4,
    srcIncrement: true,
    dstIncrement: true,
    flow: flowM2M_Dma,
    enableTcInt: false,
  )

  configureChannel(dma, ch, config)
  startChannel(dma, ch)

  # Wait for completion
  var timeout = 1_000_000'u32
  while channelActive(dma, ch):
    timeout.dec
    if timeout == 0:
      stopChannel(dma, ch)
      return false

  clearTcInterrupt(dma, ch)
  true

# =============================================================================
# LLI builder helper
# =============================================================================
proc buildLli*(srcAddr, dstAddr: uint32, transferSize: uint32,
               srcWidth: DmaWidth = width32, dstWidth: DmaWidth = width32,
               srcIncr: bool = true, dstIncr: bool = true,
               nextLli: uint32 = 0, tcInt: bool = false): DmaLli =
  result.srcAddr = srcAddr
  result.dstAddr = dstAddr
  result.nextLli = nextLli
  var ctrl = transferSize and CtrlTransferSizeMask
  ctrl = ctrl or (burst4.uint32 shl CtrlSBSizeShift)
  ctrl = ctrl or (burst4.uint32 shl CtrlDBSizeShift)
  ctrl = ctrl or (srcWidth.uint32 shl CtrlSWidthShift)
  ctrl = ctrl or (dstWidth.uint32 shl CtrlDWidthShift)
  if srcIncr: ctrl = ctrl or (1'u32 shl CtrlSrcIncr)
  if dstIncr: ctrl = ctrl or (1'u32 shl CtrlDstIncr)
  if tcInt:   ctrl = ctrl or (1'u32 shl CtrlTcIntEnable)
  result.control = ctrl
