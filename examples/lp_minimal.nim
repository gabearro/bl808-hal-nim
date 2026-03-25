## LP core minimal example — basic heartbeat on the low-power E902 core.
##
## Build: nim c -d:bl808lp examples/lp_minimal.nim
##
## The LP (E902) core is a tiny RV32EMC core with no caches.
## It is typically used for low-power background tasks:
##   - Monitoring sensors while M0/D0 sleep
##   - Watchdog supervision
##   - Wake-on-event for the other cores
##
## The LP core shares MCU subsystem peripherals with M0 but has
## its own IPC mailbox (IPC1) and limited interrupt support.

import bl808

const
  HeartbeatPin = 8'u32  # GPIO pin for heartbeat LED (change as needed)
  DefaultClkHz = 32_000_000'u32

proc main() {.exportc, cdecl.} =
  systemInit()

  # Initialize IPC — marks LP as ready so M0 can communicate with us
  ipcInit()

  # Configure a GPIO pin as heartbeat indicator
  gpioInitOutput(HeartbeatPin, drive1)

  # Main loop: toggle heartbeat and check for IPC messages
  var heartbeatCounter = 0'u32
  var rxBuf: array[32, uint8]
  var tag: uint16

  while true:
    # Toggle heartbeat every ~500ms
    heartbeatCounter.inc
    if heartbeatCounter >= 500:
      heartbeatCounter = 0
      gpioToggle(HeartbeatPin)

    # Check for IPC messages from M0
    let n = ipcRecvMessage(ipcM0, tag, rxBuf)
    if n >= 0:
      # Process message based on tag
      case tag
      of 0x0010:  # Request to enter low-power sleep
        gpioClear(HeartbeatPin)
        pdsSleep(1000, {wakeTimer})
        # Wakes up here after sleep
        gpioSet(HeartbeatPin)
      of 0x0020:  # Ping from M0
        # Respond with ack
        var ack: array[1, uint8] = [0x01'u8]
        discard ipcSendMessage(ipcM0, 0x0021, ack)
      else:
        discard

    # Check for messages from D0
    let n2 = ipcRecvMessage(ipcD0, tag, rxBuf)
    if n2 >= 0:
      # Forward to M0 if needed
      discard ipcSendMessage(ipcM0, tag, rxBuf.toOpenArray(0, n2 - 1))

    delayMs(1)
