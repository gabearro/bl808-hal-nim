## IPC demo — Inter-Processor Communication between M0 and D0.
##
## This file contains firmware for BOTH cores. Build each separately:
##   nim c -d:bl808m0 examples/ipc_demo.nim   # M0 firmware
##   nim c -d:bl808d0 examples/ipc_demo.nim   # D0 firmware
##
## M0 sends a "ping" message to D0, D0 responds with "pong".
## Both cores use their respective UARTs for console output.

import bl808

const DefaultClkHz = 32_000_000'u32

when defined(bl808m0):
  # =========================================================================
  # M0 side: sends ping to D0, waits for pong
  # =========================================================================
  const
    MsgTagPing = 0x0001'u16
    MsgTagPong = 0x0002'u16

  proc main() {.exportc, cdecl.} =
    systemInit()

    # Init UART0 console
    enablePeriphClock(periphUart0)
    gpioSetupUart(14, 15)
    let console = initUart(uart0, DefaultUartConfig, DefaultClkHz)

    discard console.sendLine("[M0] IPC Demo starting...")

    # Initialize IPC
    ipcInit()
    discard console.sendLine("[M0] Waiting for D0 to be ready...")

    # Wait for D0 to come up
    if not ipcWaitReady(ipcD0, 50_000_000):
      discard console.sendLine("[M0] ERROR: D0 did not start in time")
      while true: wfi()

    discard console.sendLine("[M0] D0 is ready! Sending ping...")

    # Send a ping message
    var pingData: array[4, uint8] = [0x50'u8, 0x49, 0x4E, 0x47]  # "PING"
    if not ipcSendMessage(ipcD0, MsgTagPing, pingData):
      discard console.sendLine("[M0] ERROR: Failed to send ping")
      while true: wfi()

    discard console.sendLine("[M0] Ping sent! Waiting for pong...")

    # Wait for pong response
    var rxBuf: array[64, uint8]
    var tag: uint16
    var timeout = 10_000_000'u32
    var received = false

    while timeout > 0 and not received:
      let n = ipcRecvMessage(ipcD0, tag, rxBuf)
      if n >= 0:
        discard console.sendString("[M0] Received message: tag=")
        console.sendHex32(tag.uint32)
        discard console.sendString(" len=")
        console.sendHex32(n.uint32)
        discard console.sendLine("")
        if tag == MsgTagPong:
          discard console.sendLine("[M0] Got PONG! IPC working!")
          received = true
      timeout.dec

    if not received:
      discard console.sendLine("[M0] Timeout waiting for pong")

    discard console.sendLine("[M0] Demo complete.")
    while true: wfi()

elif defined(bl808d0):
  # =========================================================================
  # D0 side: waits for ping from M0, responds with pong
  # =========================================================================
  const
    MsgTagPing = 0x0001'u16
    MsgTagPong = 0x0002'u16

  proc main() {.exportc, cdecl.} =
    systemInit()

    # Init UART3 console
    gpioSetFunction(16, funcMmUart)
    gpioSetFunction(17, funcMmUart)
    let txAddr = GpioConfigBase + 16 * 4
    regSet(txAddr, (1'u32 shl 6) or (1'u32 shl 1) or (1'u32 shl 4))
    let rxAddr = GpioConfigBase + 17 * 4
    regSet(rxAddr, (1'u32 shl 0) or (1'u32 shl 1) or (1'u32 shl 4))
    enableMmPeriphClock(4)

    let console = initUart(uart3, DefaultUartConfig, DefaultClkHz)

    discard console.sendLine("[D0] IPC Demo starting...")

    # Initialize IPC (this also marks D0 as ready)
    ipcInit()
    discard console.sendLine("[D0] Ready and waiting for messages...")

    # Message processing loop
    var rxBuf: array[64, uint8]
    var tag: uint16

    while true:
      let n = ipcRecvMessage(ipcM0, tag, rxBuf)
      if n >= 0:
        discard console.sendString("[D0] Received message: tag=")
        console.sendHex32(tag.uint32)
        discard console.sendString(" len=")
        console.sendHex32(n.uint32)
        discard console.sendLine("")

        if tag == MsgTagPing:
          discard console.sendLine("[D0] Got PING! Sending PONG...")
          var pongData: array[4, uint8] = [0x50'u8, 0x4F, 0x4E, 0x47]  # "PONG"
          if ipcSendMessage(ipcM0, MsgTagPong, pongData):
            discard console.sendLine("[D0] PONG sent!")
          else:
            discard console.sendLine("[D0] ERROR: Failed to send pong")
