## M0 launcher for the D0 WebAssembly VM smoke image.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wasm_runtime
import bl808/wasm_smoke
import bl808/wasm_task_smoke

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  D0WasmStatusAddr = XramBase + 0x3E80'u
  D0WasmCapsAddr = XramBase + 0x3E84'u
  D0WasmTaskStatusAddr = XramBase + 0x3E88'u
  D0WasmMmuStatusAddr = XramBase + 0x3E8C'u
  D0WasmMmuExpected = (1'u32 shl 0) or (1'u32 shl 1) or (1'u32 shl 2)
  JtagD0StatusAddr = XramBase + 0x3E00'u
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  WaitLimit = 80_000
  ExpectedD0WasmCaps =
    (wasmCoreD0.ord.uint32 shl 24) or
    (1'u32 shl 1) or # flash-backed VM is available
    (1'u32 shl 3) or # i32
    (1'u32 shl 4) or # f32
    (1'u32 shl 5) or # f64
    (1'u32 shl 6)    # imports/full runtime

var console: Uart

proc switchJtagMuxToD0() =
  const
    jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
  regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 20_000:
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

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(JtagD0StatusAddr) == JtagD0RunMagic:
      regWrite(JtagD0StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      discard console.sendLine("[M0] D0 JTAG run magic observed")
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WASM D0 Smoke Helper (M0) ===")
  discard console.sendLine("[M0] Releasing D0 WASM smoke")

  regWrite(D0WasmStatusAddr, 0)
  regWrite(D0WasmCapsAddr, 0)
  regWrite(D0WasmTaskStatusAddr, 0)
  when defined(bl808D0MmuOs):
    regWrite(D0WasmMmuStatusAddr, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  when defined(bl808jtagram):
    releaseD0(forceLoad = false)
    discard console.sendLine("[M0] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[M0] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  var ok = false
  var printedStatus = false
  var printedTaskStatus = false
  for _ in 0 ..< WaitLimit:
    let status = sharedRead32(D0WasmStatusAddr)
    if status != 0:
      let caps = sharedRead32(D0WasmCapsAddr)
      let taskStatus = sharedRead32(D0WasmTaskStatusAddr)
      when defined(bl808D0MmuOs):
        let mmuStatus = sharedRead32(D0WasmMmuStatusAddr)
      if not printedStatus:
        printHex("  d0_wasm_status=", status)
        printHex("  d0_wasm_caps=", caps)
        when defined(bl808D0MmuOs):
          printHex("  d0_wasm_mmu_status=", mmuStatus)
        printedStatus = true
      if taskStatus != 0 and not printedTaskStatus:
        printHex("  d0_wasm_task_status=", taskStatus)
        printedTaskStatus = true
      if status == WasmSmokeOk and caps == ExpectedD0WasmCaps and
          taskStatus == WasmTaskSmokeOk:
        when defined(bl808D0MmuOs):
          if (mmuStatus and D0WasmMmuExpected) != D0WasmMmuExpected:
            spinDelay()
            continue
        ok = true
        break
    spinDelay()

  if ok:
    when defined(bl808D0MmuOs):
      discard console.sendLine("[PASS] D0 WASM OS entered S-mode with Sv39 enabled")
    discard console.sendLine("[PASS] D0 WASM runtime capabilities match D0 profile")
    discard console.sendLine("[PASS] D0 WASM i32/f32/memory smoke passed")
    discard console.sendLine("[PASS] D0 WASM task context switching smoke passed")
  else:
    if not printedStatus:
      printHex("  d0_wasm_status=", sharedRead32(D0WasmStatusAddr))
      printHex("  d0_wasm_caps=", sharedRead32(D0WasmCapsAddr))
      when defined(bl808D0MmuOs):
        printHex("  d0_wasm_mmu_status=", sharedRead32(D0WasmMmuStatusAddr))
    if not printedTaskStatus:
      printHex("  d0_wasm_task_status=", sharedRead32(D0WasmTaskStatusAddr))
    discard console.sendLine("[FAIL] D0 WASM smoke did not pass")

  while true:
    wfi()
