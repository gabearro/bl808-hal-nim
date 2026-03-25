## M0 UART hello world — prints to the Ox64 serial console.
##
## Build: nim c -d:bl808m0 examples/m0_uart_hello.nim
##
## Ox64 M0 console: UART0, GPIO14 (TX), GPIO15 (RX), 2 Mbps.
## Connect a USB-serial adapter at 2000000 baud.

import bl808

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud = 2_000_000'u32
  DefaultClkHz = 32_000_000'u32  # RC32M boot clock

proc main() {.exportc, cdecl.} =
  systemInit()

  # Enable UART0 peripheral clock
  enablePeriphClock(periphUart0)

  # Configure UART pins
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)

  # Initialize UART
  let console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), DefaultClkHz)

  # Print hello
  discard console.sendLine("BL808 M0 HAL - Hello from Nim!")
  discard console.sendString("Core ID: ")
  console.sendHex32(regRead(CoreIdAddr))
  discard console.sendLine("")

  # Echo loop
  discard console.sendLine("UART echo ready. Type something...")
  while true:
    let (b, ok) = console.tryRecvByte()
    if ok:
      discard console.sendByte(b)
