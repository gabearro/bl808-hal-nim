## BL808 UART driver.
##
## Supports UART0-3. UART0/1/2 are in the MCU subsystem (M0/LP),
## UART3 is in the MM subsystem (D0).
##
## Register layout is identical across all instances.

import mmio, memmap

# =============================================================================
# UART register offsets
# =============================================================================
const
  UartUtxConfig*     = 0x00'u  # TX configuration
  UartUrxConfig*     = 0x04'u  # RX configuration
  UartBitPrd*        = 0x08'u  # Bit period (baud rate)
  UartDataConfig*    = 0x0C'u  # Data configuration
  UartIntSts*        = 0x20'u  # Interrupt status
  UartIntMask*       = 0x24'u  # Interrupt mask
  UartIntClear*      = 0x28'u  # Interrupt clear
  UartIntEn*         = 0x2C'u  # Interrupt enable
  UartStatus*        = 0x30'u  # UART status
  UartFifoConfig0*   = 0x80'u  # FIFO configuration 0
  UartFifoConfig1*   = 0x84'u  # FIFO configuration 1
  UartFifoWdata*     = 0x88'u  # FIFO write data
  UartFifoRdata*     = 0x8C'u  # FIFO read data

# =============================================================================
# UTX_CONFIG fields
# =============================================================================
const
  UtxEn*             = 0       # TX enable
  UtxCtsEn*          = 1       # CTS flow control
  UtxFreerunEn*      = 2       # Free-run mode
  UtxLinEn*          = 3       # LIN mode
  UtxPrtEn*          = 4       # Parity enable
  UtxPrtSel*         = 5       # Parity select (0=even, 1=odd)
  UtxBitCntDShift*   = 8       # Data bits count [10:8]
  UtxBitCntDMask*    = 0x07'u32 shl 8
  UtxBitCntPShift*   = 11      # Parity bits [12:11]
  UtxBitCntBShift*   = 13      # Stop bits [15:13]
  UtxBitCntBMask*    = 0x07'u32 shl 13
  UtxLenShift*       = 16      # TX transfer length [31:16]

# =============================================================================
# URX_CONFIG fields
# =============================================================================
const
  UrxEn*             = 0       # RX enable
  UrxAbrEn*          = 1       # Auto baud rate
  UrxLinEn*          = 3
  UrxPrtEn*          = 4
  UrxPrtSel*         = 5
  UrxBitCntDShift*   = 8
  UrxBitCntDMask*    = 0x07'u32 shl 8

# =============================================================================
# FIFO_CONFIG_0 fields
# =============================================================================
const
  FifoDmaRxEn*       = 0       # DMA RX enable
  FifoDmaTxEn*       = 1       # DMA TX enable
  FifoTxFifoClr*     = 2       # Clear TX FIFO
  FifoRxFifoClr*     = 3       # Clear RX FIFO
  FifoTxFifoOverflow*  = 4     # TX FIFO overflow flag
  FifoTxFifoUnderflow* = 5     # TX FIFO underflow flag
  FifoRxFifoOverflow*  = 6     # RX FIFO overflow flag
  FifoRxFifoUnderflow* = 7     # RX FIFO underflow flag

# =============================================================================
# FIFO_CONFIG_1 fields
# =============================================================================
const
  FifoTxCountShift*  = 0       # TX FIFO count [5:0]
  FifoTxCountMask*   = 0x3F'u32
  FifoRxCountShift*  = 8       # RX FIFO count [13:8]
  FifoRxCountMask*   = 0x3F'u32 shl 8
  FifoTxThreshShift* = 16      # TX FIFO threshold [20:16]
  FifoTxThreshMask*  = 0x1F'u32 shl 16
  FifoRxThreshShift* = 24      # RX FIFO threshold [28:24]
  FifoRxThreshMask*  = 0x1F'u32 shl 24

# =============================================================================
# Interrupt bits
# =============================================================================
const
  IntUtxEnd*         = 0       # TX transfer end
  IntUrxEnd*         = 1       # RX transfer end
  IntUtxFifoReady*   = 2       # TX FIFO ready (below threshold)
  IntUrxFifoReady*   = 3       # RX FIFO ready (above threshold)
  IntUrxRto*         = 4       # RX timeout
  IntUrxPce*         = 5       # RX parity check error
  IntUtxFer*         = 6       # TX framing error
  IntUrxFer*         = 7       # RX framing error
  IntUrxLse*         = 8       # LIN sync error

# =============================================================================
# Status register bits
# =============================================================================
const
  StsUtxBusy*        = 0       # TX busy
  StsUrxBusy*        = 1       # RX busy

# =============================================================================
# UART configuration types
# =============================================================================
type
  UartId* = enum
    uart0
    uart1
    uart2
    uart3

  UartParity* = enum
    parityNone
    parityEven
    parityOdd

  UartStopBits* = enum
    stop1   = 1  # 1 stop bit
    stop15  = 2  # 1.5 stop bits
    stop2   = 3  # 2 stop bits

  UartDataBits* = enum
    data5 = 4
    data6 = 5
    data7 = 6
    data8 = 7

  UartConfig* = object
    baudRate*: uint32
    dataBits*: UartDataBits
    stopBits*: UartStopBits
    parity*: UartParity

  UartError* = enum
    uartOk
    uartTimeout
    uartOverflow
    uartFramingError
    uartParityError

  Uart* = object
    base: uint
    id: UartId

# =============================================================================
# UART base address lookup
# =============================================================================
proc uartBase(id: UartId): uint =
  case id
  of uart0: Uart0Base
  of uart1: Uart1Base
  of uart2: Uart2Base
  of uart3: Uart3Base

# =============================================================================
# Default UART configuration
# =============================================================================
const DefaultUartConfig* = UartConfig(
  baudRate: 2_000_000,
  dataBits: data8,
  stopBits: stop1,
  parity: parityNone,
)

# =============================================================================
# UART initialization
# =============================================================================
proc initUart*(id: UartId, config: UartConfig, uartClkHz: uint32): Uart =
  ## Initialize a UART port. Returns the UART handle.
  ##
  ## `uartClkHz` is the UART peripheral clock frequency in Hz.
  ## On Ox64, UART0 console uses GPIO14(TX)/GPIO15(RX) at 2 Mbps.
  ## D0 console uses UART3 with GPIO16(TX)/GPIO17(RX) at 2 Mbps.
  result.base = uartBase(id)
  result.id = id
  let base = result.base

  # Disable TX and RX during configuration
  regClear(base + UartUtxConfig, 1'u32 shl UtxEn)
  regClear(base + UartUrxConfig, 1'u32 shl UrxEn)

  # Calculate baud rate divisor
  let bitPrd = (uartClkHz div config.baudRate) - 1
  let prdVal = (bitPrd shl 16) or bitPrd  # TX period [31:16], RX period [15:0]
  regWrite(base + UartBitPrd, prdVal)

  # Configure TX
  var txCfg = 0'u32
  txCfg = txCfg or (config.dataBits.uint32 shl UtxBitCntDShift)
  txCfg = txCfg or (config.stopBits.uint32 shl UtxBitCntBShift)
  txCfg = txCfg or (1'u32 shl UtxFreerunEn)  # Free-run mode for byte-at-a-time
  if config.parity != parityNone:
    txCfg = txCfg or (1'u32 shl UtxPrtEn)
    if config.parity == parityOdd:
      txCfg = txCfg or (1'u32 shl UtxPrtSel)
  regWrite(base + UartUtxConfig, txCfg)

  # Configure RX
  var rxCfg = 0'u32
  rxCfg = rxCfg or (config.dataBits.uint32 shl UrxBitCntDShift)
  if config.parity != parityNone:
    rxCfg = rxCfg or (1'u32 shl UrxPrtEn)
    if config.parity == parityOdd:
      rxCfg = rxCfg or (1'u32 shl UrxPrtSel)
  regWrite(base + UartUrxConfig, rxCfg)

  # Clear and reset FIFOs
  regSet(base + UartFifoConfig0,
         (1'u32 shl FifoTxFifoClr) or (1'u32 shl FifoRxFifoClr))

  # Set FIFO thresholds: TX threshold = 16, RX threshold = 16
  var fifoCfg1 = regRead(base + UartFifoConfig1)
  fifoCfg1 = (fifoCfg1 and not FifoTxThreshMask) or (16'u32 shl FifoTxThreshShift)
  fifoCfg1 = (fifoCfg1 and not FifoRxThreshMask) or (16'u32 shl FifoRxThreshShift)
  regWrite(base + UartFifoConfig1, fifoCfg1)

  # Mask all interrupts initially
  regWrite(base + UartIntMask, 0xFFFF_FFFF'u32)

  # Enable TX and RX
  regSet(base + UartUtxConfig, 1'u32 shl UtxEn)
  regSet(base + UartUrxConfig, 1'u32 shl UrxEn)

# =============================================================================
# FIFO status
# =============================================================================
proc txFifoCount*(uart: Uart): uint32 {.inline.} =
  ## Number of bytes currently in the TX FIFO.
  regRead(uart.base + UartFifoConfig1) and FifoTxCountMask

proc rxFifoCount*(uart: Uart): uint32 {.inline.} =
  ## Number of bytes available in the RX FIFO.
  (regRead(uart.base + UartFifoConfig1) and FifoRxCountMask) shr FifoRxCountShift

proc txFifoFull*(uart: Uart): bool {.inline.} =
  uart.txFifoCount() >= 32

proc txFifoEmpty*(uart: Uart): bool {.inline.} =
  uart.txFifoCount() == 0

proc rxAvailable*(uart: Uart): bool {.inline.} =
  uart.rxFifoCount() > 0

proc txBusy*(uart: Uart): bool {.inline.} =
  (regRead(uart.base + UartStatus) and (1'u32 shl StsUtxBusy)) != 0

# =============================================================================
# Blocking send
# =============================================================================
proc sendByte*(uart: Uart, b: uint8): UartError =
  ## Send a single byte, blocking until FIFO has space.
  ## Returns uartOk on success, uartTimeout if stuck.
  var timeout = 100_000'u32
  while uart.txFifoFull():
    timeout.dec
    if timeout == 0: return uartTimeout
  regWrite(uart.base + UartFifoWdata, b.uint32)
  uartOk

proc send*(uart: Uart, data: openArray[uint8]): UartError =
  ## Send a buffer of bytes.
  for b in data:
    let err = uart.sendByte(b)
    if err != uartOk: return err
  uartOk

proc sendString*(uart: Uart, s: string): UartError =
  ## Send a string.
  for c in s:
    let err = uart.sendByte(c.uint8)
    if err != uartOk: return err
  uartOk

proc sendLine*(uart: Uart, s: string): UartError =
  ## Send a string followed by CR+LF.
  result = uart.sendString(s)
  if result != uartOk: return
  result = uart.sendByte(0x0D)
  if result != uartOk: return
  result = uart.sendByte(0x0A)

# =============================================================================
# Blocking receive
# =============================================================================
proc recvByte*(uart: Uart, timeout: uint32 = 1_000_000): (uint8, UartError) =
  ## Receive a single byte, blocking until data arrives or timeout.
  var countdown = timeout
  while not uart.rxAvailable():
    countdown.dec
    if countdown == 0: return (0'u8, uartTimeout)
  let data = regRead(uart.base + UartFifoRdata) and 0xFF
  (data.uint8, uartOk)

proc recv*(uart: Uart, buf: var openArray[uint8], timeout: uint32 = 1_000_000): (int, UartError) =
  ## Receive up to buf.len bytes. Returns number of bytes actually received.
  var count = 0
  for i in 0 ..< buf.len:
    let (b, err) = uart.recvByte(timeout)
    if err != uartOk:
      return (count, if count > 0: uartOk else: err)
    buf[i] = b
    count.inc
  (count, uartOk)

# =============================================================================
# Non-blocking operations
# =============================================================================
proc trySendByte*(uart: Uart, b: uint8): bool {.inline.} =
  ## Try to send a byte. Returns false if FIFO is full.
  if uart.txFifoFull(): return false
  regWrite(uart.base + UartFifoWdata, b.uint32)
  true

proc tryRecvByte*(uart: Uart): (uint8, bool) {.inline.} =
  ## Try to receive a byte. Returns (0, false) if no data available.
  if not uart.rxAvailable(): return (0'u8, false)
  let data = regRead(uart.base + UartFifoRdata) and 0xFF
  (data.uint8, true)

# =============================================================================
# FIFO management
# =============================================================================
proc deinitUart*(uart: Uart) =
  ## Disable UART TX and RX, clear FIFOs.
  regClear(uart.base + UartUtxConfig, 1'u32 shl UtxEn)
  regClear(uart.base + UartUrxConfig, 1'u32 shl UrxEn)
  regSet(uart.base + UartFifoConfig0,
         (1'u32 shl FifoTxFifoClr) or (1'u32 shl FifoRxFifoClr))

proc flushTx*(uart: Uart) =
  ## Wait for TX FIFO to drain completely.
  while uart.txBusy():
    discard

proc clearFifos*(uart: Uart) =
  ## Clear both TX and RX FIFOs.
  regSet(uart.base + UartFifoConfig0,
         (1'u32 shl FifoTxFifoClr) or (1'u32 shl FifoRxFifoClr))

# =============================================================================
# Interrupt configuration
# =============================================================================
proc enableInterrupt*(uart: Uart, intBit: uint32) =
  regClear(uart.base + UartIntMask, 1'u32 shl intBit)

proc disableInterrupt*(uart: Uart, intBit: uint32) =
  regSet(uart.base + UartIntMask, 1'u32 shl intBit)

proc clearInterrupt*(uart: Uart, intBit: uint32) =
  regSet(uart.base + UartIntClear, 1'u32 shl intBit)

proc readInterruptStatus*(uart: Uart): uint32 =
  regRead(uart.base + UartIntSts)

# =============================================================================
# DMA support
# =============================================================================
proc enableDmaTx*(uart: Uart) =
  regSet(uart.base + UartFifoConfig0, 1'u32 shl FifoDmaTxEn)

proc enableDmaRx*(uart: Uart) =
  regSet(uart.base + UartFifoConfig0, 1'u32 shl FifoDmaRxEn)

proc disableDmaTx*(uart: Uart) =
  regClear(uart.base + UartFifoConfig0, 1'u32 shl FifoDmaTxEn)

proc disableDmaRx*(uart: Uart) =
  regClear(uart.base + UartFifoConfig0, 1'u32 shl FifoDmaRxEn)

proc txFifoAddr*(uart: Uart): uint {.inline.} =
  ## Return the TX FIFO data register address (for DMA configuration).
  uart.base + UartFifoWdata

proc rxFifoAddr*(uart: Uart): uint {.inline.} =
  ## Return the RX FIFO data register address (for DMA configuration).
  uart.base + UartFifoRdata

# =============================================================================
# Utility: print hex number
# =============================================================================
proc sendHex32*(uart: Uart, value: uint32) =
  const hexDigits = "0123456789ABCDEF"
  discard uart.sendString("0x")
  for i in countdown(7, 0):
    let nibble = (value shr (i * 4)) and 0xF
    discard uart.sendByte(hexDigits[nibble].uint8)
