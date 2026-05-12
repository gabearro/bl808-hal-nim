## M0 triple-core test — monitors LP heartbeat via XRAM.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_tricore_test.nim
## Run:
##   qemu-system-riscv64 -M bl808 -nographic \
##     -serial mon:stdio -serial file:/tmp/d0.txt \
##     -device loader,file=examples/d0_kernel_test,cpu-num=1 \
##     -device loader,file=examples/lp_kernel_test,cpu-num=2 \
##     -kernel examples/m0_tricore_test

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/irq
import bl808/kernel/cps

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  LpStatusAddr = 0x40002F00'u
  LpHeartbeatAddr = 0x40002F04'u
  LpAliveMarker = 0xA11CE902'u32

var console: Uart

proc printInt(n: int) =
  if n == 0:
    discard console.sendByte(ord('0').uint8)
    return
  var buf: array[12, uint8]
  var i = 0
  var v = if n < 0: -n else: n
  if n < 0: discard console.sendByte(ord('-').uint8)
  while v > 0 and i < 12:
    buf[i] = (v mod 10).uint8 + ord('0').uint8
    v = v div 10
    inc i
  for j in countdown(i - 1, 0):
    discard console.sendByte(buf[j])

# ---------------------------------------------------------------------------
# Monitor LP heartbeat via XRAM
# ---------------------------------------------------------------------------

proc monitorLP(): CpsVoidFuture {.cps.} =
  discard console.sendLine("[M0] Waiting for LP to come alive...")
  var attempts = 0
  while attempts < 20:
    await sleepMs(500)
    attempts += 1
    let status = regRead(LpStatusAddr)
    let hb = regRead(LpHeartbeatAddr)
    if status == LpAliveMarker:
      discard console.sendString("[M0] LP alive! heartbeat=")
      printInt(hb.int)
      discard console.sendLine("")
      if hb > 0:
        discard console.sendLine("[M0] LP kernel is running! [PASS]")
        return
    elif attempts mod 5 == 0:
      discard console.sendString("[M0] LP status=")
      console.sendHex32(status)
      discard console.sendString(" hb=")
      console.sendHex32(hb)
      discard console.sendLine("")
  discard console.sendLine("[M0] LP did not respond in time [TIMEOUT]")

# ---------------------------------------------------------------------------
# M0 heartbeat
# ---------------------------------------------------------------------------

proc heartbeat(): CpsVoidFuture {.cps.} =
  var count = 0
  while count < 6:
    await sleepMs(1000)
    discard console.sendLine("[M0] heartbeat")
    count += 1

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 Triple-Core Test (M0) ===")

  heapInit()
  schedulerInit()

  discard console.sendLine("[M0] Scheduler initialized")
  discard console.sendLine("")

  discard monitorLP()
  discard heartbeat()

  discard console.sendLine("[M0] Entering scheduler")
  discard console.sendLine("")

  runScheduler()
