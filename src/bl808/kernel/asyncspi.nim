## DMA-backed CPS SPI transfers. The caller handles chip select via GPIO.
## One transfer can be queued or active per instance. Cancellation releases
## the channels and discards any bytes that have not left the controller.

import ../spi, ../dma, ../dmablock
import ./runtime, ./asyncdma

type AsyncSpi* = ref object
  spi*: Spi
  dma: SpiDmaTransfer
  pending: CpsFuture[SpiError]

proc initAsyncSpi*(id: SpiId; cfg: SpiConfig): AsyncSpi =
  AsyncSpi(spi: initSpi(id, cfg))

proc cancel*(aspi: AsyncSpi) =
  ## Complete a queued or active transfer with spiCancelled.
  if aspi.pending == nil: return
  let pending = move(aspi.pending)
  aspi.dma.cancel()
  complete(pending, spiCancelled)

proc active*(aspi: AsyncSpi): bool {.inline.} =
  aspi.pending != nil

proc startTransfer(aspi: AsyncSpi; tx, rx: ptr UncheckedArray[byte];
                   len: int): CpsFuture[SpiError] =
  aspi.cancel()
  if aspi.active:
    # An owner's completion callback started a replacement transfer.
    return completedLocalFuture(spiCancelled)
  if len <= 0: return completedLocalFuture(spiOk)

  let controller = openCoreDma()
  let channels = if rx == nil: 1 else: 2
  var started = false
  let future = awaitDma(proc(): DmaBlockStatus =
      if not started:
        if not controller.hasFreeChannels(channels): return dmaBlockRunning
        if not aspi.dma.start(aspi.spi, tx, rx, len): return dmaBlockError
        started = true
      aspi.dma.poll(),
    proc(ok: bool) =
      if not ok: aspi.dma.cancel()
      aspi.pending = nil,
    spiOk, spiFifoError)
  if not future.finished: aspi.pending = future
  future

proc transferPtr*(aspi: AsyncSpi, txData: ptr UncheckedArray[uint8],
                  rxBuf: ptr UncheckedArray[uint8],
                  len: int): CpsFuture[SpiError] =
  ## Full-duplex async SPI transfer.
  aspi.startTransfer(txData, rxBuf, len)

proc sendPtr*(aspi: AsyncSpi, data: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Send-only transfer. The input received during transmit is discarded.
  aspi.startTransfer(data, nil, len)

proc recvPtr*(aspi: AsyncSpi, buf: ptr UncheckedArray[uint8],
              len: int): CpsFuture[SpiError] =
  ## Receive-only async SPI transfer (sends 0xFF).
  aspi.startTransfer(nil, buf, len)

# The caller keeps the buffers alive until completion.
proc transfer*(aspi: AsyncSpi, txBuf, rxBuf: var openArray[uint8]): CpsFuture[SpiError] =
  let len = min(txBuf.len, rxBuf.len)
  if len == 0: return aspi.transferPtr(nil, nil, 0)
  transferPtr(aspi,
    cast[ptr UncheckedArray[uint8]](unsafeAddr txBuf[0]),
    cast[ptr UncheckedArray[uint8]](addr rxBuf[0]),
    len)

proc send*(aspi: AsyncSpi, data: openArray[uint8]): CpsFuture[SpiError] =
  if data.len == 0: return aspi.sendPtr(nil, 0)
  sendPtr(aspi,
    cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
    data.len)

proc recv*(aspi: AsyncSpi, buf: var openArray[uint8]): CpsFuture[SpiError] =
  if buf.len == 0: return aspi.recvPtr(nil, 0)
  recvPtr(aspi,
    cast[ptr UncheckedArray[uint8]](addr buf[0]),
    buf.len)
