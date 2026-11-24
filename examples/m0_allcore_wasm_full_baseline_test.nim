## M0 launcher for the same full interpreter guest corpus on all three cores.
## Use with examples/wasm_full_baseline_test.nim built for D0 and LP.

import bl808/[startup, core, mmio, glb, gpio, uart, wasm_runtime,
  wasm_full_baseline, memmap]
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WaitLimit = 100_000
  D0StatusAddr = XramBase + 0x3F20'u
  LpStatusAddr = 0x40002E90'u
  BusyStatus = 0x57464D7F'u32
  ExpectedM0Caps = (wasmCoreM0.ord.uint32 shl 24) or 0x7A'u32
  ExpectedD0Caps = (wasmCoreD0.ord.uint32 shl 24) or 0x7A'u32
  ExpectedLpCaps = (wasmCoreLP.ord.uint32 shl 24) or 0x7E'u32

var console: Uart

proc spinDelay() =
  for _ in 0 ..< 1_000:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc waitCore(address: uint, label: string,
              expectedCaps: uint32): bool =
  for _ in 0 ..< WaitLimit:
    let status = sharedRead32(address)
    if status != 0 and status != BusyStatus:
      printHex(label & "_status=", status)
      let caps = sharedRead32(address + 4'u)
      printHex(label & "_caps=", caps)
      printHex(label & "_heap_peak=", sharedRead32(address + 8'u))
      printHex(label & "_instance_bytes=", sharedRead32(address + 12'u))
      return status == WasmFullBaselineOk and caps == expectedCaps
    spinDelay()
  printHex(label & "_status=", sharedRead32(address))
  false

proc main() {.exportc, cdecl, noreturn.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone), ConsoleClkHz)

  discard console.sendLine("=== BL808 All-Core Full WASM Baseline ===")
  let m0Caps = wasmRuntimeCapabilities()
  let m0Word = wasmRuntimeCapabilityWord(m0Caps)
  var memory: WasmFullBaselineMemory
  let m0Status = runWasmFullBaseline(addr memory)
  printHex("  m0_full_status=", m0Status)
  printHex("  m0_full_caps=", m0Word)
  printHex("  m0_full_heap_peak=", memory.peakBytes)
  printHex("  m0_full_instance_bytes=", memory.instanceBytes)
  let m0Ok = m0Caps.fullInterpreter and
    m0Status == WasmFullBaselineOk and m0Word == ExpectedM0Caps
  discard console.sendLine(if m0Ok:
    "[PASS] M0 full interpreter corpus" else:
    "[FAIL] M0 full interpreter corpus")

  regWrite(D0StatusAddr, 0)
  regWrite(LpStatusAddr, 0)
  dcacheFlushAll()
  fenceIo()
  mmPowerOn()
  releaseD0()
  let d0Ok = waitCore(D0StatusAddr, "  d0_full", ExpectedD0Caps)
  discard console.sendLine(if d0Ok:
    "[PASS] D0 full interpreter corpus" else:
    "[FAIL] D0 full interpreter corpus")
  releaseLP()
  let lpOk = waitCore(LpStatusAddr, "  lp_full", ExpectedLpCaps)
  discard console.sendLine(if lpOk:
    "[PASS] LP full interpreter corpus" else:
    "[FAIL] LP full interpreter corpus")
  discard console.sendLine(if m0Ok and d0Ok and lpOk:
    "=== Test Complete ===" else: "=== Test Failed ===")
  while true: wfi()
