## Async UART driver for the BL808 kernel.
##
## Provides interrupt-driven UART receive as CPS futures:
##
##   let au = initAsyncUart(uart0, IrqM0Uart0)
##   let ch: uint8 = await au.recv()       # single byte
##   let n: int = await au.recvInto(buf)    # fill buffer
##
## TX remains synchronous (FIFO is large enough for typical writes).
##
## The driver uses the ISR bridge for zero-allocation interrupt handling:
##   1. `recv()` registers an ISR slot and enables UART RX interrupt
##   2. When data arrives, the ISR reads the FIFO and signals the slot
##   3. The scheduler drains the completion ring and completes the future
##   4. The CPS task resumes with the received data

import ../uart, ../irq, ../core
import ./runtime, ./isrbridge

# =============================================================================
# Async UART state
# =============================================================================

type
  AsyncUart* = ref object
    uart*: Uart                 ## Underlying HAL UART
    irqNum*: uint32             ## CLIC IRQ number for this UART
    ## RX state for the current pending receive
    rxSlot: int                 ## ISR bridge slot index (-1 = no pending recv)
    rxByte: uint8               ## Byte read by ISR
    rxGotData: bool             ## Set by ISR when data is available
    rxFuture: CpsVoidFuture     ## Future to complete when data arrives

# =============================================================================
# Per-instance ISR handler
#
# We support up to 4 async UARTs. Each has its own ISR that reads from
# the FIFO and signals the completion ring.
# =============================================================================

var asyncUarts: array[4, AsyncUart]

proc uartIsrCommon(idx: int) {.cdecl.} =
  ## Common UART ISR body. Reads one byte from the FIFO, stores it,
  ## and signals the ISR bridge slot.
  let au = asyncUarts[idx]
  if au == nil:
    return

  let status = au.uart.readInterruptStatus()

  # RX FIFO ready interrupt (bit 3)
  if (status and (1'u32 shl IntUrxFifoReady)) != 0:
    if au.rxSlot >= 0:
      # Read one byte from FIFO
      let (b, ok) = au.uart.tryRecvByte()
      if ok:
        au.rxByte = b
        au.rxGotData = true
        # Signal the ISR bridge (zero allocation)
        completeIsrSlot(au.rxSlot)
        au.rxSlot = -1
    # Disable RX interrupt until next recv() call
    au.uart.disableInterrupt(IntUrxFifoReady)
    au.uart.clearInterrupt(IntUrxFifoReady)

  # TX end interrupt (bit 0) — clear it, we don't use async TX yet
  if (status and (1'u32 shl IntUtxEnd)) != 0:
    au.uart.clearInterrupt(IntUtxEnd)

  # RX timeout interrupt (bit 4)
  if (status and (1'u32 shl IntUrxRto)) != 0:
    au.uart.clearInterrupt(IntUrxRto)

proc uart0Isr() {.cdecl.} = uartIsrCommon(0)
proc uart1Isr() {.cdecl.} = uartIsrCommon(1)
proc uart2Isr() {.cdecl.} = uartIsrCommon(2)
proc uart3Isr() {.cdecl.} = uartIsrCommon(3)

const uartIsrs = [uart0Isr, uart1Isr, uart2Isr, uart3Isr]

# =============================================================================
# Initialization
# =============================================================================

proc initAsyncUart*(uartObj: Uart, irqNum: uint32, index: range[0..3]): AsyncUart =
  ## Create an async UART driver.
  ##
  ## `uartObj`: an already-initialized HAL Uart (from initUart)
  ## `irqNum`: CLIC IRQ number (e.g., IrqM0Uart0 = 44)
  ## `index`:  UART index (0-3) for ISR dispatch
  result = AsyncUart(
    uart: uartObj,
    irqNum: irqNum,
    rxSlot: -1,
    rxByte: 0,
    rxGotData: false,
    rxFuture: nil,
  )

  # Store for ISR dispatch
  asyncUarts[index] = result

  # Register the ISR and enable the CLIC interrupt line
  registerTrapHandler(irqNum, uartIsrs[index])
  when defined(bl808m0) or defined(bl808lp):
    irqClearPending(irqNum)
    irqSetLevel(irqNum, 1)
    irqEnable(irqNum)

  # Enable the machine external interrupt in mie (bit 11)
  let mie = csrReadMie()
  csrWriteMie(mie or (1'u shl 11))

  # Enable all relevant UART interrupts in the enable register (0x2C),
  # but mask them (0x24) until recv() is called.
  # QEMU model: IRQ fires when (int_sts & int_en & ~int_mask) != 0
  result.uart.setInterruptEnable(
    (1'u32 shl IntUrxFifoReady) or
    (1'u32 shl IntUtxEnd) or
    (1'u32 shl IntUrxRto))
  # Mask all interrupts initially — recv() unmasks as needed
  result.uart.disableInterrupt(IntUrxFifoReady)
  result.uart.disableInterrupt(IntUtxEnd)
  result.uart.disableInterrupt(IntUrxRto)

# =============================================================================
# Async receive — single byte
# =============================================================================

proc recv*(au: AsyncUart): CpsFuture[uint8] =
  ## Return a future that completes when one byte is received.
  ##
  ## If the RX FIFO already has data, returns a pre-completed future.
  ## Otherwise, enables the RX interrupt and waits for data.

  # Fast path: data already in FIFO
  let (b, ok) = au.uart.tryRecvByte()
  if ok:
    return completedFuture[uint8](b)

  # Slow path: wait for interrupt
  let fut = newLocalCpsVoidFuture()
  let slot = registerIsrFuture(fut)
  if slot < 0:
    # No slots available — return error future
    return failedFuture[uint8](newException(IOError, "ISR bridge full"))

  au.rxSlot = slot
  au.rxGotData = false
  au.rxFuture = fut

  # Set RX FIFO threshold to 0 so interrupt fires on first byte
  au.uart.setRxFifoThreshold(0)

  # Enable RX FIFO ready interrupt
  au.uart.clearInterrupt(IntUrxFifoReady)
  au.uart.enableInterrupt(IntUrxFifoReady)

  # Return a typed future that extracts the byte after the void future completes
  let typedFut = newLocalCpsFuture[uint8]()
  addCallback(fut, proc() =
    if au.rxGotData:
      complete(typedFut, au.rxByte)
    else:
      complete(typedFut, 0'u8)
  )
  typedFut

# =============================================================================
# Async receive — into buffer
# =============================================================================

proc recvByte*(au: AsyncUart): CpsFuture[uint8] =
  ## Alias for recv — receive a single byte.
  au.recv()

# =============================================================================
# Synchronous send (TX FIFO is fast enough for typical use)
# =============================================================================

proc send*(au: AsyncUart, data: openArray[uint8]) =
  ## Send data synchronously via the UART TX FIFO.
  for b in data:
    discard au.uart.sendByte(b)

proc sendByte*(au: AsyncUart, b: uint8) =
  discard au.uart.sendByte(b)

proc sendString*(au: AsyncUart, s: string) =
  for ch in s:
    discard au.uart.sendByte(ch.uint8)

proc sendLine*(au: AsyncUart, s: string) =
  au.sendString(s)
  discard au.uart.sendByte(0x0D)
  discard au.uart.sendByte(0x0A)
