## Async SPI driver for the BL808 kernel.
##
## Interrupt-driven full-duplex SPI master using the ISR bridge.
## Chip select is NOT managed — caller handles CS via GPIO.
##
##   var aspi = initAsyncSpi(spi0, SpiConfig(mode: spiMode0, ...))
##   let err = await aspi.transfer(txBuf, rxBuf)  # full-duplex
##   let err = await aspi.send(data)               # TX only
##   let err = await aspi.recv(buf)                 # RX only (sends 0xFF)

import ../spi, ../mmio, ../irq
import ./runtime, ./isrbridge

# =============================================================================
# Types
# =============================================================================

type
  AsyncSpi* = ref object
    spi*: Spi
    irqNum: uint32
    index: int
    slot: int               ## ISR bridge slot (-1 = idle)
    txData: ptr UncheckedArray[uint8]
    txLen: int
    txPos: int
    rxData: ptr UncheckedArray[uint8]
    rxLen: int
    rxPos: int
    dummyTx: bool           ## true if sending 0xFF (recv-only mode)

# =============================================================================
# ISR dispatch
# =============================================================================

var asyncSpis: array[2, AsyncSpi]

proc writeSpiIntSts(base: uint, enableBits, maskBits, clearBits: uint32) {.inline.} =
  regWrite(base + SpiIntSts,
           ((enableBits and SpiIntBitsMask) shl SpiIntEnableOffset) or
           ((maskBits and SpiIntBitsMask) shl SpiIntMaskOffset) or
           ((clearBits and SpiIntBitsMask) shl SpiIntClearOffset))

proc preserveSpiIntSts(base: uint, clearBits: uint32 = 0'u32) {.inline.} =
  let cur = regRead(base + SpiIntSts)
  regWrite(base + SpiIntSts,
           (cur and ((SpiIntBitsMask shl SpiIntEnableOffset) or
                     (SpiIntBitsMask shl SpiIntMaskOffset))) or
           ((clearBits and SpiIntBitsMask) shl SpiIntClearOffset))

proc spiIsrCommon(idx: int) =
  let aspi = asyncSpis[idx]
  if aspi == nil: return
  let base = aspi.spi.baseAddr()

  var sts = regRead(base + SpiIntSts) and 0x3F'u32

  # Feed TX FIFO
  if (sts and (1'u32 shl SpiIntTxFifo)) != 0:
    while aspi.txPos < aspi.txLen:
      if aspi.spi.txFifoFree() == 0: break
      if aspi.dummyTx:
        regWrite(base + SpiFifoWdata, 0xFF'u32)
      else:
        regWrite(base + SpiFifoWdata, aspi.txData[aspi.txPos].uint32)
      aspi.txPos.inc

  # Drain RX FIFO
  if (sts and (1'u32 shl SpiIntRxFifo)) != 0:
    while aspi.rxPos < aspi.rxLen:
      let rxCount = (regRead(base + SpiFifoConfig1) and SpiFifoRxCountMask) shr SpiFifoRxCountShift
      if rxCount == 0: break
      let byte = (regRead(base + SpiFifoRdata) and 0xFF).uint8
      if aspi.rxData != nil:
        aspi.rxData[aspi.rxPos] = byte
      aspi.rxPos.inc

  # Re-read status after FIFO operations
  sts = regRead(base + SpiIntSts) and 0x3F'u32

  # Transfer end
  if (sts and (1'u32 shl SpiIntEnd)) != 0:
    # Drain any remaining RX bytes
    while aspi.rxPos < aspi.rxLen:
      let rxCount = (regRead(base + SpiFifoConfig1) and SpiFifoRxCountMask) shr SpiFifoRxCountShift
      if rxCount == 0: break
      let byte = (regRead(base + SpiFifoRdata) and 0xFF).uint8
      if aspi.rxData != nil:
        aspi.rxData[aspi.rxPos] = byte
      aspi.rxPos.inc

    if aspi.txPos >= aspi.txLen and aspi.rxPos >= aspi.rxLen:
      # Mask all SPI interrupts
      writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask, 0'u32)
      if aspi.slot >= 0:
        completeIsrSlot(aspi.slot)
        aspi.slot = -1

  # Clear handled interrupt flags
  preserveSpiIntSts(base, sts)

proc spi0Isr() {.cdecl.} = spiIsrCommon(0)
proc spi1Isr() {.cdecl.} = spiIsrCommon(1)

const spiIsrs: array[2, proc() {.cdecl.}] = [spi0Isr, spi1Isr]

const spiIrqNums: array[2, uint32] = [
  IrqM0Spi0.uint32,
  IrqD0Spi1.uint32,
]

# =============================================================================
# Initialization
# =============================================================================

proc initAsyncSpi*(id: SpiId, cfg: SpiConfig): AsyncSpi =
  ## Initialize an async SPI instance.
  let idx = id.int
  let irqNum = spiIrqNums[idx]

  result = AsyncSpi(
    spi: initSpi(id, cfg),
    irqNum: irqNum,
    index: idx,
    slot: -1,
  )
  asyncSpis[idx] = result

  # Register ISR
  registerTrapHandler(irqNum, spiIsrs[idx])
  irqEnable(irqNum)
  irqSetLevel(irqNum, 1)

  # Enable machine external interrupt
  {.emit: """
  unsigned long mie;
  asm volatile("csrr %0, mie" : "=r"(mie));
  mie |= (1UL << 11);
  asm volatile("csrw mie, %0" :: "r"(mie));
  """.}

  # Keep SPI interrupts enabled in the peripheral but masked until a transfer starts.
  writeSpiIntSts(result.spi.baseAddr(), SpiIntBitsMask, SpiIntBitsMask, SpiIntBitsMask)

# =============================================================================
# Internal: start an async transfer
# =============================================================================

proc startAsyncSpi(aspi: AsyncSpi, len: int, fut: CpsVoidFuture): bool =
  let base = aspi.spi.baseAddr()

  # Clear FIFOs
  regSet(base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

  # Mask interrupts while transfer state is being installed, then clear stale flags.
  writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask, SpiIntBitsMask)

  # Register ISR slot before starting hardware so completion cannot race it.
  aspi.slot = registerIsrFuture(fut)
  if aspi.slot < 0:
    return false

  # Enable master
  regSet(base + SpiConfigReg, 1'u32 shl SpiMasterEn)

  # Pre-load TX FIFO
  var preload = 0
  while preload < aspi.txLen and aspi.spi.txFifoFree() > 0:
    if aspi.dummyTx:
      regWrite(base + SpiFifoWdata, 0xFF'u32)
    else:
      regWrite(base + SpiFifoWdata, aspi.txData[preload].uint32)
    preload.inc
  aspi.txPos = preload

  # Re-enable CLIC and unmask peripheral interrupts after the FIFO is primed.
  irqClearPending(aspi.irqNum)
  irqEnable(aspi.irqNum)
  writeSpiIntSts(base, SpiIntBitsMask, 0'u32, 0'u32)
  true

# =============================================================================
# Public async API — ptr-based core procs
# =============================================================================

proc transferPtr*(aspi: AsyncSpi, txData: ptr UncheckedArray[uint8],
                  rxBuf: ptr UncheckedArray[uint8],
                  len: int): CpsFuture[SpiError] =
  ## Full-duplex async SPI transfer.
  aspi.txData = txData
  aspi.txLen = len
  aspi.txPos = 0
  aspi.rxData = rxBuf
  aspi.rxLen = len
  aspi.rxPos = 0
  aspi.dummyTx = false

  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[SpiError]()
  voidFut.addCallback proc() = complete(typedFut, spiOk)

  if not startAsyncSpi(aspi, len, voidFut):
    complete(typedFut, spiFifoError)
  typedFut

proc sendPtr*(aspi: AsyncSpi, data: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Send-only async SPI transfer (received data discarded).
  aspi.txData = data
  aspi.txLen = len
  aspi.txPos = 0
  aspi.rxData = nil
  aspi.rxLen = len  # Still count RX to track transfer progress
  aspi.rxPos = 0
  aspi.dummyTx = false

  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[SpiError]()
  voidFut.addCallback proc() = complete(typedFut, spiOk)

  if not startAsyncSpi(aspi, len, voidFut):
    complete(typedFut, spiFifoError)
  typedFut

proc recvPtr*(aspi: AsyncSpi, buf: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Receive-only async SPI transfer (sends 0xFF).
  aspi.txData = nil
  aspi.txLen = len
  aspi.txPos = 0
  aspi.rxData = buf
  aspi.rxLen = len
  aspi.rxPos = 0
  aspi.dummyTx = true

  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[SpiError]()
  voidFut.addCallback proc() = complete(typedFut, spiOk)

  if not startAsyncSpi(aspi, len, voidFut):
    complete(typedFut, spiFifoError)
  typedFut

# Template wrappers for openArray usage in CPS procs
template transfer*(aspi: AsyncSpi, txBuf, rxBuf: var openArray[uint8]): CpsFuture[SpiError] =
  transferPtr(aspi,
    cast[ptr UncheckedArray[uint8]](unsafeAddr txBuf[0]),
    cast[ptr UncheckedArray[uint8]](addr rxBuf[0]),
    min(txBuf.len, rxBuf.len))

template send*(aspi: AsyncSpi, data: openArray[uint8]): CpsFuture[SpiError] =
  sendPtr(aspi,
    cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
    data.len)

template recv*(aspi: AsyncSpi, buf: var openArray[uint8]): CpsFuture[SpiError] =
  recvPtr(aspi,
    cast[ptr UncheckedArray[uint8]](addr buf[0]),
    buf.len)
