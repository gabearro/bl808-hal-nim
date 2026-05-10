## D0 UART hello world — prints to the Ox64 D0 serial console.
##
## Build: nim c -d:bl808d0 examples/d0_uart_hello.nim
##
## Ox64 D0 console: UART3, GPIO16 (TX), GPIO17 (RX), 230400 baud by default.
## Note: The D0 firmware must be loaded by M0 (via bootloader or IPC).

import bl808

const
  ConsoleUartTxPin = 16'u32
  ConsoleUartRxPin = 17'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32  # Boot clock

proc main() {.exportc, cdecl.} =
  systemInit()

  # Configure UART3 pins (MM UART function)
  gpioSetFunction(ConsoleUartTxPin, funcMmUart)
  gpioSetFunction(ConsoleUartRxPin, funcMmUart)

  # Set up pin electrical properties
  let txAddr = GpioConfigBase + ConsoleUartTxPin * 4
  regSet(txAddr, (1'u32 shl 6) or (1'u32 shl 1) or (1'u32 shl 4))  # OE, SMT, PU

  let rxAddr = GpioConfigBase + ConsoleUartRxPin * 4
  regSet(rxAddr, (1'u32 shl 0) or (1'u32 shl 1) or (1'u32 shl 4))  # IE, SMT, PU

  # MM UART3 is controlled through MM_GLB UART0 clock/reset fields.
  resetMmUart3()
  enableMmUart3Clock()

  # Initialize UART3
  let console = initUart(uart3, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("BL808 D0 HAL - Hello from Nim!")
  discard console.sendString("Core ID: ")
  console.sendHex32(regRead(CoreIdAddr))
  discard console.sendLine("")
  discard console.sendLine("D0 (C906) running at RV64IMAFDC")

  # Echo loop
  while true:
    let (b, ok) = console.tryRecvByte()
    if ok:
      discard console.sendByte(b)
