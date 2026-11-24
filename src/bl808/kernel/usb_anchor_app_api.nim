## Versioned C ABI offered by a resident M0 USB UART anchor to a cooperative
## M0 application.  An application receives a pointer to this table at entry;
## it must not take ownership of the USB controller or a registered UART.

const
  UsbAnchorAppMagic* = 0x3150_4155'u32 # "UAP1"
  UsbAnchorAppVersion* = 1'u16
  UsbAnchorVirtualConsole* = 0xFF'u32
  UsbAnchorConsoleChannel* = 3'u8

type
  AnchorRegisterConsole* = proc(uartIndex, baud: uint32): int32 {.cdecl.}
  AnchorUnregisterConsole* = proc(): int32 {.cdecl.}
  AnchorConsoleWrite* = proc(data: pointer, length: uint32): int32 {.cdecl.}
  AnchorConsoleRead* = proc(data: pointer, capacity: uint32): int32 {.cdecl.}
  AnchorRegisterUart* = proc(uartIndex, baud: uint32): int32 {.cdecl.}
  AnchorUnregisterUart* = proc(uartIndex: uint32): int32 {.cdecl.}
  AnchorUartWrite* = proc(uartIndex: uint32, data: pointer,
                          length: uint32): int32 {.cdecl.}
  AnchorUartRead* = proc(uartIndex: uint32, data: pointer,
                         capacity: uint32): int32 {.cdecl.}

  UsbAnchorAppApi* {.bycopy.} = object
    ## Additive ABI: preserve the first `size` bytes and keep version 1 until
    ## a breaking change.  UART0 console shares the anchor's fixed 230400-baud
    ## recovery pins; UART1/2 are configured by the anchor.  Writes may accept
    ## fewer bytes than requested and must be retried by the application.
    magic*: uint32
    version*: uint16
    size*: uint16
    registerConsole*: AnchorRegisterConsole
    unregisterConsole*: AnchorUnregisterConsole
    consoleWrite*: AnchorConsoleWrite
    consoleRead*: AnchorConsoleRead
    registerUart*: AnchorRegisterUart
    unregisterUart*: AnchorUnregisterUart
    uartWrite*: AnchorUartWrite
    uartRead*: AnchorUartRead

  UsbAnchorAppInit* = proc(api: ptr UsbAnchorAppApi): int32 {.cdecl.}
  UsbAnchorAppPoll* = proc() {.cdecl.}

const
  AnchorStatusOk* = 0'i32
  AnchorStatusInvalid* = -1'i32
  AnchorStatusBusy* = -2'i32
  AnchorStatusUnavailable* = -3'i32
