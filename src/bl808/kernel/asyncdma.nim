## Async DMA transfers for the BL808 kernel.
##
## ISR-driven DMA channel management using the ISR bridge.
## Supports M2M, M2P, and P2M transfers with CpsFuture completion.
##
##   let ok = await dmaTransferAsync(dma0, 0, cfg)
##   let ok = await spiDmaTransfer(spi, txBuf, rxBuf, len)

import ../dma, ../spi, ../mmio, ../irq
import ./runtime, ./isrbridge

# =============================================================================
# Per-channel ISR bridge slots
# =============================================================================

const DmaNumChannels = 8

var dmaSlots: array[DmaNumChannels, int]  # -1 = idle
var dmaHandle: Dma  # Pre-initialized, used by ISR

proc dmaIsrHandler() {.cdecl.} =
  let d = dmaHandle
  # Check which channels have transfer-complete
  for ch in 0'u32 ..< DmaNumChannels.uint32:
    if d.tcInterruptPending(ch.DmaChannel):
      d.clearTcInterrupt(ch.DmaChannel)
      if dmaSlots[ch] >= 0:
        completeIsrSlot(dmaSlots[ch])
        dmaSlots[ch] = -1

# =============================================================================
# Initialization
# =============================================================================

var dmaInitialized = false

proc dmaAsyncInit*() =
  ## Initialize async DMA. Call once at boot after enabling the DMA0 clock
  ## through GLB.
  if dmaInitialized: return
  dmaInitialized = true

  for i in 0 ..< DmaNumChannels:
    dmaSlots[i] = -1

  # Initialize DMA controller (enables it + clears interrupts)
  dmaHandle = initDma(dma0)

  # Register ISR
  registerTrapHandler(IrqM0Dma0All, dmaIsrHandler)
  irqEnable(IrqM0Dma0All)
  irqSetLevel(IrqM0Dma0All, 1)

  # Enable machine external interrupt
  {.emit: """
  unsigned long mie;
  asm volatile("csrr %0, mie" : "=r"(mie));
  mie |= (1UL << 11);
  asm volatile("csrw mie, %0" :: "r"(mie));
  """.}

# =============================================================================
# Async DMA transfer
# =============================================================================

proc dmaTransferAsync*(ch: DmaChannel,
                       cfg: DmaTransferConfig): CpsFuture[bool] =
  ## Start a DMA transfer and return a future that completes on TC.
  if not dmaInitialized: dmaAsyncInit()

  let d = dmaHandle
  let fut = newLocalCpsFuture[bool]()
  let voidFut = newLocalCpsVoidFuture()
  voidFut.addCallback proc() = complete(fut, true)

  # Re-enable CLIC
  irqClearPending(IrqM0Dma0All)
  irqEnable(IrqM0Dma0All)

  dmaSlots[ch.int] = registerIsrFuture(voidFut)
  if dmaSlots[ch.int] < 0:
    complete(fut, false)
    return fut
  d.configureChannel(ch, cfg)
  d.startChannel(ch)
  fut

# =============================================================================
# DMA M2M copy
# =============================================================================

proc dmaCopyAsync*(src, dst: pointer, len: int,
                   ch: DmaChannel = 0.DmaChannel): CpsFuture[bool] =
  ## Async memory-to-memory copy via DMA.
  let cfg = DmaTransferConfig(
    srcAddr: cast[uint32](src),
    dstAddr: cast[uint32](dst),
    transferSize: len.uint32,
    srcWidth: width8,
    dstWidth: width8,
    srcBurst: burst1,
    dstBurst: burst1,
    srcIncrement: true,
    dstIncrement: true,
    flow: flowM2M_Dma,
    srcPeriph: 0,
    dstPeriph: 0,
    enableTcInt: true,
  )
  dmaTransferAsync(ch, cfg)

# =============================================================================
# DMA-accelerated SPI transfer
# =============================================================================

proc spiDmaTransfer*(spi: Spi, txBuf, rxBuf: ptr UncheckedArray[uint8],
                     len: int): CpsFuture[bool] =
  ## Full-duplex SPI transfer using DMA channels 2 (TX) and 3 (RX).
  if not dmaInitialized: dmaAsyncInit()

  let d = dmaHandle

  # Enable SPI DMA mode
  spi.enableDmaTx()
  spi.enableDmaRx()

  # Configure TX channel (M2P): memory → SPI TX FIFO
  let txCfg = DmaTransferConfig(
    srcAddr: cast[uint32](txBuf),
    dstAddr: spi.txFifoAddr().uint32,
    transferSize: len.uint32,
    srcWidth: width8,
    dstWidth: width8,
    srcBurst: burst1,
    dstBurst: burst1,
    srcIncrement: true,
    dstIncrement: false,  # FIFO address doesn't increment
    flow: flowM2P_Dma,
    srcPeriph: 0,
    dstPeriph: dmaPeriphSpi0Tx.uint32,
    enableTcInt: false,  # We wait on RX complete, not TX
  )

  # Configure RX channel (P2M): SPI RX FIFO → memory
  let rxCfg = DmaTransferConfig(
    srcAddr: spi.rxFifoAddr().uint32,
    dstAddr: cast[uint32](rxBuf),
    transferSize: len.uint32,
    srcWidth: width8,
    dstWidth: width8,
    srcBurst: burst1,
    dstBurst: burst1,
    srcIncrement: false,
    dstIncrement: true,
    flow: flowP2M_Dma,
    srcPeriph: dmaPeriphSpi0Rx.uint32,
    dstPeriph: 0,
    enableTcInt: true,  # Interrupt when all RX bytes received
  )

  # Enable SPI master
  regSet(spi.baseAddr() + SpiConfigReg, 1'u32 shl SpiMasterEn)

  # Start both channels
  d.configureChannel(2.DmaChannel, txCfg)
  d.configureChannel(3.DmaChannel, rxCfg)

  # Register ISR slot for RX channel (ch3)
  let fut = newLocalCpsFuture[bool]()
  let voidFut = newLocalCpsVoidFuture()
  voidFut.addCallback proc() =
    # Disable SPI DMA mode after transfer
    regClear(spi.baseAddr() + SpiFifoConfig0, (1'u32 shl SpiFifoDmaTxEn) or (1'u32 shl SpiFifoDmaRxEn))
    complete(fut, true)

  irqClearPending(IrqM0Dma0All)
  irqEnable(IrqM0Dma0All)

  dmaSlots[3] = registerIsrFuture(voidFut)
  if dmaSlots[3] < 0:
    complete(fut, false)
    return fut
  d.startChannel(2.DmaChannel)
  d.startChannel(3.DmaChannel)
  fut
