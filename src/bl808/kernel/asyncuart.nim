## DMA-backed UART byte and block transfers for the CPS scheduler.
## TX and RX can run concurrently. Keep buffers alive until completion.

import ../uart, ../dma, ../dmablock
import ./runtime, ./asyncdma

type AsyncUart* = ref object
  uart*: Uart
  irqNum*: uint32
  receiving, transmitting: bool

proc initAsyncUart*(uartObj: Uart; irqNum: uint32; index: range[0..3]): AsyncUart =
  ## Retain the port and its IRQ number. DMA completion is polled by the scheduler.
  AsyncUart(uart: uartObj, irqNum: irqNum)

proc transferBlock(au: AsyncUart; data: ptr UncheckedArray[byte]; len: int;
                   receiving: bool): CpsFuture[UartError] =
  if len == 0: return completedLocalFuture(uartOk)
  if data == nil or len < 0: return completedLocalFuture(uartOverflow)
  if (receiving and au.receiving) or (not receiving and au.transmitting):
    return failedLocalFuture[UartError](newException(IOError, "UART direction is busy"))
  if receiving: au.receiving = true
  else: au.transmitting = true

  let controller = openCoreDma()
  var transfer: UartDmaTransfer
  var started = false
  awaitDma(proc(): DmaBlockStatus =
      if not started:
        if not controller.hasFreeChannels(1): return dmaBlockRunning
        if not transfer.start(au.uart, data, len, receiving): return dmaBlockError
        started = true
      transfer.status(),
    proc(ok: bool) =
      transfer.release(ok)
      if receiving: au.receiving = false
      else: au.transmitting = false,
    uartOk, uartOverflow)

proc recv*(au: AsyncUart): CpsFuture[uint8] =
  ## Receive one byte. Cancelling the returned future stops DMA.
  let data = new(uint8)
  let receive = au.transferBlock(cast[ptr UncheckedArray[byte]](addr data[]), 1, receiving = true)
  let byteFuture = newLocalCpsFuture[uint8]()
  byteFuture.addCallback proc() =
    if byteFuture.isCancelled: cancel(receive)
  receive.addCallback proc() =
    if byteFuture.finished: return
    if receive.isCancelled:
      cancel(byteFuture)
    elif receive.hasError:
      fail(byteFuture, receive.getError())
    elif receive.read() != uartOk:
      fail(byteFuture, newException(IOError, "UART DMA receive failed"))
    else:
      complete(byteFuture, data[])
  byteFuture

proc recvByte*(au: AsyncUart): CpsFuture[uint8] =
  au.recv()

proc sendAsyncPtr*(au: AsyncUart; data: ptr UncheckedArray[byte];
                   len: int): CpsFuture[UartError] =
  ## Bulk TX. Keep data alive and use this UART's TX only after completion.
  au.transferBlock(data, len, receiving = false)

proc recvIntoPtr*(au: AsyncUart; data: ptr UncheckedArray[byte];
                  len: int): CpsFuture[UartError] =
  ## Receive exactly len bytes. Use withTimeout when the peer may stop early.
  au.transferBlock(data, len, receiving = true)

proc sendAsync*(au: AsyncUart; data: openArray[byte]): CpsFuture[UartError] =
  sendAsyncPtr(au,
    (if data.len == 0: nil else: cast[ptr UncheckedArray[byte]](unsafeAddr data[0])), data.len)

proc recvInto*(au: AsyncUart; data: var openArray[byte]): CpsFuture[UartError] =
  recvIntoPtr(au,
    (if data.len == 0: nil else: cast[ptr UncheckedArray[byte]](addr data[0])), data.len)

# =============================================================================
# Synchronous send
# =============================================================================

proc send*(au: AsyncUart, data: openArray[uint8]) =
  discard au.uart.send(data)

proc sendByte*(au: AsyncUart, b: uint8) =
  au.send([b])

proc sendString*(au: AsyncUart, s: string) =
  if s.len != 0:
    let bytes = cast[ptr UncheckedArray[byte]](unsafeAddr s[0])
    au.send(bytes.toOpenArray(0, s.high))

proc sendLine*(au: AsyncUart, s: string) =
  au.sendString(s)
  au.send([0x0D'u8, 0x0A])
