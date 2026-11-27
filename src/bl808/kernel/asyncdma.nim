## CPS completion for linked DMA transfers. A pending transfer can be
## cancelled through its future, including by withTimeout.

import ../core, ../dma, ../dmablock, ../dmafifo, ../spi
import ./runtime, ./sched

proc awaitDma*[T](check: proc(): DmaBlockStatus {.closure.};
                  stop: proc(success: bool) {.closure.};
                  success, failure: T): CpsFuture[T] =
  ## Park the caller between status checks. Start promptly for short
  ## transfers, and back off while a long transfer is still in progress.
  let future = newLocalCpsFuture[T]()
  var timer: TimerId
  var delay = 100'u64
  proc poll() =
    timer = 0
    case check()
    of dmaBlockRunning:
      timer = addTimerUs(delay, poll)
      delay = min(delay * 2, 1000'u64)
    of dmaBlockDone:
      stop(true)
      complete(future, success)
    of dmaBlockError, dmaBlockIdle:
      stop(false)
      complete(future, failure)
  future.addCallback proc() =
    if timer != 0: cancelTimer(timer)
    if future.isCancelled:
      stop(false)
  poll()
  future

proc dmaAsyncInit*() =
  ## Pre-enable the core's controller without disturbing existing channels.
  discard openCoreDma()

proc dmaTransferAsync*(controller: Dma; cfg: DmaTransferConfig;
                       channel = -1): CpsFuture[bool] =
  ## Start a linked transfer. The caller controls peripheral requests and
  ## cache maintenance for cfg's buffers.
  if cfg.transferSize == 0: return completedLocalFuture(true)
  let transfer = new DmaBlock
  if not transfer[].prepare(controller, cfg, channel):
    return completedLocalFuture(false)
  transfer[].start()
  awaitDma(proc(): DmaBlockStatus = transfer[].status(),
           proc(ok: bool) = transfer[].release(), true, false)

proc dmaTransferAsync*(ch: DmaChannel;
                       cfg: DmaTransferConfig): CpsFuture[bool] =
  dmaTransferAsync(openCoreDma(), cfg, ch.int)

proc fifoTransferAsync*(endpoint: DmaFifoEndpoint; data: pointer;
                        len: int): CpsFuture[bool] =
  ## Pump len bytes through a configured peripheral FIFO. The caller owns
  ## the peripheral and keeps the data buffer alive until completion.
  if len == 0: return completedLocalFuture(true)
  let transfer = new DmaFifoTransfer
  if not transfer[].prepare(endpoint, data, len): return completedLocalFuture(false)
  if not transfer[].start():
    transfer[].release()
    return completedLocalFuture(false)
  awaitDma(proc(): DmaBlockStatus = transfer[].status(),
           proc(ok: bool) = transfer[].release(ok), true, false)

proc fifoTransferAsync*(endpoint: DmaFifoEndpoint;
                        words: var openArray[uint32]): CpsFuture[bool] =
  if words.len == 0: return completedLocalFuture(true)
  if endpoint.width != width32: return completedLocalFuture(false)
  fifoTransferAsync(endpoint, addr words[0], words.len * sizeof(uint32))

proc dmaCopyAsync*(src, dst: pointer; len: int;
                   ch = -1): CpsFuture[bool] =
  ## Copy between RAM buffers. Source and destination must not overlap.
  ## Omitting ch lets the controller choose an available channel.
  if len == 0: return completedLocalFuture(true)
  let source = cast[uint](src)
  let dest = cast[uint](dst)
  if not dmaBufferInRam(source, len) or not dmaBufferInRam(dest, len) or
      (dest < source + len.uint and source < dest + len.uint):
    return completedLocalFuture(false)

  let transfer = new DmaBlock
  let receive = new DmaReceiveBuffer
  receive[].prepare(dst, len)
  let cfg = DmaTransferConfig(
    srcAddr: source.uint32, dstAddr: receive.address.uint32,
    transferSize: len.uint32, srcWidth: width8, dstWidth: width8,
    srcIncrement: true, dstIncrement: true, flow: flowM2M_Dma)
  if not transfer[].prepare(openCoreDma(), cfg, ch):
    receive[].finish(false)
    return completedLocalFuture(false)

  dcacheCleanRange(source, len.uint)
  transfer[].start()
  awaitDma(proc(): DmaBlockStatus = transfer[].status(),
    proc(ok: bool) =
      transfer[].release()
      receive[].finish(ok),
    true, false)

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  proc spiDmaTransfer*(spi: Spi; txBuf, rxBuf: ptr UncheckedArray[uint8];
                       len: int): CpsFuture[bool] =
    ## Full-duplex SPI. Completion includes the last bit leaving the bus.
    if len == 0: return completedLocalFuture(true)
    let transfer = new SpiDmaTransfer
    if not transfer[].start(spi, txBuf, rxBuf, len):
      return completedLocalFuture(false)
    awaitDma(proc(): DmaBlockStatus = transfer[].poll(),
      proc(ok: bool) =
        if not ok: transfer[].cancel(),
      true, false)
