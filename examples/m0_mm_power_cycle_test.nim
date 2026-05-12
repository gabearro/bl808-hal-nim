## M0-side MM power-cycle regression.
##
## Verifies that PDS_CTL2 really stops and restarts the MM/D0 domain:
##   1. Power on MM and wait for a D0 heartbeat in shared XRAM.
##   2. Power MM off and confirm the heartbeat stops.
##   3. Power MM back on and confirm D0 boots again.
##
## Build:
##   nim c -d:bl808m0 examples/m0_mm_power_cycle_test.nim
##   nim c -d:bl808d0 examples/d0_mm_power_cycle_test.nim
##
## Run:
##   timeout 30s qemu-system-riscv64 -M bl808,\
##       d0-firmware=examples/d0_mm_power_cycle_test \
##       -nographic -serial mon:stdio \
##       -kernel examples/m0_mm_power_cycle_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds
import bl808/mmio, bl808/memmap

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  SharedBootCount = XramBase + 0x3FE0'u
  SharedHeartbeat = XramBase + 0x3FE4'u

var console: Uart

proc logHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc waitForHeartbeatChange(previous: uint32, timeoutMs: uint32): bool =
  var waited = 0'u32

  while waited < timeoutMs:
    if regRead(SharedHeartbeat) != previous:
      return true
    delayMs(10)
    waited += 10
  false

proc waitForBootIncrement(previous: uint32, timeoutMs: uint32): bool =
  var waited = 0'u32

  while waited < timeoutMs:
    if regRead(SharedBootCount) > previous:
      return true
    delayMs(10)
    waited += 10
  false

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 MM Power Cycle Test (M0) ===")
  discard console.sendLine("[M0] Powering on MM domain")
  pdsPowerOnMmSystem()
  releaseD0()

  let initialHeartbeat = regRead(SharedHeartbeat)
  if not waitForHeartbeatChange(initialHeartbeat, 2000):
    discard console.sendLine("[FAIL] D0 heartbeat did not start after MM power-on")
    return

  let bootBefore = regRead(SharedBootCount)
  let heartbeatBefore = regRead(SharedHeartbeat)
  delayMs(250)
  let heartbeatRunning = regRead(SharedHeartbeat)

  logHex("[M0] D0 boot count before cycle: ", bootBefore)
  logHex("[M0] D0 heartbeat before cycle: ", heartbeatRunning)

  if heartbeatRunning == heartbeatBefore:
    discard console.sendLine("[FAIL] D0 heartbeat was not advancing before MM power-off")
    return

  discard console.sendLine("[M0] Powering off MM domain")
  pdsPowerOffMmSystem()
  delayMs(300)
  let heartbeatOff0 = regRead(SharedHeartbeat)
  delayMs(300)
  let heartbeatOff1 = regRead(SharedHeartbeat)

  logHex("[M0] D0 heartbeat during MM off: ", heartbeatOff1)
  if heartbeatOff0 != heartbeatOff1:
    discard console.sendLine("[FAIL] D0 heartbeat kept advancing while MM was powered off")
    return

  discard console.sendLine("[M0] Powering MM domain back on")
  pdsPowerOnMmSystem()
  releaseD0()
  if not waitForBootIncrement(bootBefore, 3000):
    discard console.sendLine("[FAIL] D0 did not reboot after MM power-on")
    return

  let bootAfter = regRead(SharedBootCount)
  let heartbeatOn0 = regRead(SharedHeartbeat)
  delayMs(250)
  let heartbeatOn1 = regRead(SharedHeartbeat)

  logHex("[M0] D0 boot count after cycle: ", bootAfter)
  logHex("[M0] D0 heartbeat after cycle: ", heartbeatOn1)

  if bootAfter == bootBefore + 1'u32 and heartbeatOn0 != heartbeatOn1:
    discard console.sendLine("[PASS] MM power cycle stopped and restarted D0")
  else:
    discard console.sendLine("[FAIL] Unexpected MM power-cycle behavior")
