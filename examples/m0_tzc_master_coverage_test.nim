## TZC master-coverage audit (F): prove EVERY bus master is correctly grouped.
##
## Cross-master denial of the secure window is already proven for D0 + DMA
## (m0_tzc_enforce_test, m0_dma_tzc_test). This audits COMPLETENESS: after the
## enclave partition is applied + locked, read back the auth group of all 16 bus
## masters and assert the invariant "only M0 is group 0; every other master is
## group 1", so no master is silently left in the secure group by omission.
## (The earlier default set omitted Cci/Lz4/Blai/Codec; partition.nim now grants
## group 1 to every master except M0.)

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/tzc
import bl808/enclave/partition
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 TZC Master Coverage Test ===")

  applyPartition(defaultPartition(lock = true))
  check("partition applied + locked", tzcWindowRegionLocked(tzcWinOcram, 0))

  # Print every master's group, then assert the invariant.
  var m0Group = 9
  var nonM0AllGroup1 = true
  var nonM0Count = 0
  for m in TzcMaster:
    let g = tzcMasterGroup(m)
    discard console.sendString("[TZC] master ")
    console.sendHex32(m.ord.uint32)
    discard console.sendString(" group=")
    console.sendHex32(g.uint32)
    discard console.sendLine("")
    if m == tzcMasterM0:
      m0Group = g
    else:
      inc nonM0Count
      if g != 1: nonM0AllGroup1 = false

  check("M0 is group 0 (secure)", m0Group == 0)
  check("all non-M0 masters are group 1 (untrusted)",
        nonM0AllGroup1 and nonM0Count == 15)
  check("secure OCRAM window locked to group 0",
        tzcWindowRegionLocked(tzcWinOcram, 0))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
