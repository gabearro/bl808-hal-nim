## Async SPI driver for the BL808 kernel.
##
## Interrupt-driven full-duplex SPI master using the ISR bridge.
## Chip select is NOT managed — caller handles CS via GPIO.
##
##   var aspi = initAsyncSpi(spi0, SpiConfig(mode: spiMode0, ...))
##   let err = await aspi.transfer(txBuf, rxBuf)  # full-duplex
##   let err = await aspi.send(data)               # TX only
##   let err = await aspi.recv(buf)                 # RX only (sends 0xFF)
##
## One transfer runs at a time. A transfer that will not finish can be
## abandoned: `aspi.cancel()`, cancelling its future (which is what
## `withTimeout` does when the time is up), or starting the next transfer
## all stop it and give its interrupt-bridge slot back.
##
##   try: discard await withTimeout(aspi.send(frame), 50)
##   except TimeoutError: discard   # stopped; the next transfer starts clean

import ../spi, ../mmio, ../irq, ../core
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
    fut: CpsVoidFuture      ## Completed through the bridge when the transfer ends
    res: CpsFuture[SpiError]  ## What the caller awaits
    txData: ptr UncheckedArray[uint8]
    txLen: int
    txPos: int
    rxData: ptr UncheckedArray[uint8]
    rxLen: int
    rxPos: int
    dummyTx: bool           ## true if sending 0xFF (recv-only mode)
    txOnly: bool            ## true if received bytes are not counted (send)

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

const
  IntEnd = 1'u32 shl SpiIntEnd
  IntTxFifo = 1'u32 shl SpiIntTxFifo
  BusyWaitSpins = 100_000

proc feedTx(aspi: AsyncSpi, base: uint) {.inline.} =
  while aspi.txPos < aspi.txLen:
    if aspi.spi.txFifoFree() == 0: break
    if aspi.dummyTx:
      regWrite(base + SpiFifoWdata, 0xFF'u32)
    else:
      regWrite(base + SpiFifoWdata, aspi.txData[aspi.txPos].uint32)
    aspi.txPos.inc

proc finishFromIsr(aspi: AsyncSpi, base: uint) {.inline.} =
  writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask, 0'u32)
  if aspi.slot >= 0:
    completeIsrSlot(aspi.slot)
    aspi.slot = -1

proc txOnlyIsr(aspi: AsyncSpi, base: uint) =
  ## Send without counting what is clocked in: done when everything has been
  ## queued and the bus reports the end of the transfer with the FIFO empty.
  let sts = regRead(base + SpiIntSts) and SpiIntBitsMask
  # Clear what was seen before touching the FIFO, so an end-of-transfer that
  # follows the bytes queued below stays latched and brings the handler back.
  preserveSpiIntSts(base, sts)

  # Every byte sent clocks one in; throw them away to keep the RX FIFO clear.
  while aspi.spi.rxFifoCount() != 0:
    discard regRead(base + SpiFifoRdata)

  if aspi.txPos < aspi.txLen:
    aspi.feedTx(base)
    if aspi.txPos >= aspi.txLen:
      # All queued: only the end of the transfer is still of interest.
      writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask and not IntEnd, 0'u32)
  elif (sts and IntEnd) != 0 and aspi.spi.txFifoCount() == 0:
    # An end latched just before the last byte was queued arrives while that
    # byte is still on the wire: see it out (one byte at most) before
    # reporting the transfer done.
    var spins = BusyWaitSpins
    while aspi.spi.busy() and spins > 0: dec spins
    aspi.finishFromIsr(base)

proc spiIsrCommon(idx: int) =
  let aspi = asyncSpis[idx]
  if aspi == nil: return
  let base = aspi.spi.baseAddr()

  if aspi.txOnly:
    aspi.txOnlyIsr(base)
    return

  var sts = regRead(base + SpiIntSts) and 0x3F'u32

  # Feed TX FIFO
  if (sts and (1'u32 shl SpiIntTxFifo)) != 0:
    aspi.feedTx(base)

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
      aspi.finishFromIsr(base)

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
  csrWriteMie(csrReadMie() or (1'u shl 11))

  # Keep SPI interrupts enabled in the peripheral but masked until a transfer starts.
  writeSpiIntSts(result.spi.baseAddr(), SpiIntBitsMask, SpiIntBitsMask, SpiIntBitsMask)

# =============================================================================
# Abandoning a transfer
# =============================================================================

proc abandon(aspi: AsyncSpi, status: SpiError) =
  ## Stop the transfer in flight, if there is one: silence its interrupts,
  ## give the bridge slot back, empty the FIFOs and finish its future with
  ## `status`. A transfer the interrupt handler has already finished is left
  ## to complete normally.
  let base = aspi.spi.baseAddr()
  var slot = -1
  withInterruptsDisabled:
    slot = aspi.slot
    if slot >= 0:
      aspi.slot = -1
      aspi.txLen = 0   # a handler already pending finds nothing to do
      aspi.rxLen = 0
      writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask, SpiIntBitsMask)
  if slot < 0: return
  releaseIsrSlot(slot)
  aspi.spi.clearFifos()
  let (fut, res) = (aspi.fut, aspi.res)
  aspi.fut = nil
  aspi.res = nil
  complete(res, status)
  complete(fut)   # fires (and so drops) its callbacks; `res` is already set

proc cancel*(aspi: AsyncSpi) =
  ## Abandon the transfer in progress; its future completes with
  ## `spiCancelled`. Bytes already queued may or may not have been sent.
  ## Does nothing when no transfer is running.
  aspi.abandon(spiCancelled)

proc active*(aspi: AsyncSpi): bool {.inline.} =
  ## A transfer is running (started and not yet finished or abandoned).
  aspi.slot >= 0

# =============================================================================
# Internal: start an async transfer
# =============================================================================

proc startAsyncSpi(aspi: AsyncSpi, fut: CpsVoidFuture): bool =
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

  # A send is refilled when half the FIFO has drained, not after every byte.
  aspi.spi.setFifoThresholds(
    (if aspi.txOnly: aspi.spi.fifoDepth() div 2 - 1 else: 0'u32), 0'u32)

  # Enable master
  regSet(base + SpiConfigReg, 1'u32 shl SpiMasterEn)

  # Pre-load the TX FIFO and unmask in one piece: were the preload held up,
  # the bus would report the end of a transfer that is not over yet.
  withInterruptsDisabled:
    aspi.feedTx(base)
    irqClearPending(aspi.irqNum)
    irqEnable(aspi.irqNum)
    if aspi.txOnly:
      # "TX FIFO has room" while there are bytes to queue, then "transfer
      # ended" (which may be raised after every byte, so it stays masked
      # until then). The RX and FIFO-error flags cannot be cleared by a
      # handler that is not reading.
      let wanted = if aspi.txPos < aspi.txLen: IntTxFifo else: IntEnd
      writeSpiIntSts(base, SpiIntBitsMask, SpiIntBitsMask and not wanted, 0'u32)
    else:
      writeSpiIntSts(base, SpiIntBitsMask, 0'u32, 0'u32)
  true

proc startTransfer(aspi: AsyncSpi, txData, rxData: ptr UncheckedArray[uint8],
                   len: int, dummyTx, txOnly: bool): CpsFuture[SpiError] =
  ## Install the transfer state and start it. A transfer still running is
  ## abandoned first (it completes with `spiCancelled`).
  aspi.abandon(spiCancelled)
  if aspi.active:
    # The abandoned transfer's owner started another one from its callback.
    return completedLocalFuture(spiCancelled)
  if len <= 0:
    return completedLocalFuture(spiOk)

  aspi.txData = txData
  aspi.txLen = len
  aspi.txPos = 0
  aspi.rxData = rxData
  aspi.rxLen = if txOnly: 0 else: len
  aspi.rxPos = 0
  aspi.dummyTx = dummyTx
  aspi.txOnly = txOnly

  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[SpiError]()
  voidFut.addCallback proc() =
    if aspi.fut == voidFut:
      aspi.fut = nil
      aspi.res = nil
    complete(typedFut, spiOk)
  # Cancelling the returned future (as `withTimeout` does) stops the transfer.
  typedFut.addCallback proc() =
    if typedFut.isCancelled and aspi.res == typedFut:
      aspi.abandon(spiCancelled)

  aspi.fut = voidFut
  aspi.res = typedFut
  if not startAsyncSpi(aspi, voidFut):
    aspi.fut = nil
    aspi.res = nil
    complete(typedFut, spiFifoError)
    complete(voidFut)
  typedFut

# =============================================================================
# Public async API — ptr-based core procs
# =============================================================================

proc transferPtr*(aspi: AsyncSpi, txData: ptr UncheckedArray[uint8],
                  rxBuf: ptr UncheckedArray[uint8],
                  len: int): CpsFuture[SpiError] =
  ## Full-duplex async SPI transfer.
  aspi.startTransfer(txData, rxBuf, len, dummyTx = false, txOnly = false)

proc sendPtr*(aspi: AsyncSpi, data: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Send-only async SPI transfer. What is clocked in is discarded and not
  ## counted, so this also works with nothing connected to the data input
  ## and when the RX FIFO overran while interrupts were held off.
  aspi.startTransfer(data, nil, len, dummyTx = false, txOnly = true)

proc recvPtr*(aspi: AsyncSpi, buf: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Receive-only async SPI transfer (sends 0xFF).
  aspi.startTransfer(nil, buf, len, dummyTx = true, txOnly = false)

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
