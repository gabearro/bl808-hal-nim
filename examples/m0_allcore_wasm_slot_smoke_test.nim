## M0 launcher for shared flash-slot WASM execution on D0 and LP.

import bl808/startup
import bl808/core, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_store
import bl808/wasm_slot_smoke

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WaitLimit = 100_000
  ExpectedM0CompactCaps =
    (wasmCoreM0.ord.uint32 shl 24) or
    (1'u32 shl 0) or # compact runtime
    (1'u32 shl 1) or # flash-backed VM
    (1'u32 shl 2) or # software f32
    (1'u32 shl 3) or # i32
    (1'u32 shl 4)    # f32
  ExpectedD0CompactCaps =
    (wasmCoreD0.ord.uint32 shl 24) or
    (1'u32 shl 0) or # compact runtime
    (1'u32 shl 1) or # flash-backed VM
    (1'u32 shl 2) or # software f32
    (1'u32 shl 3) or # i32
    (1'u32 shl 4)    # f32
  ExpectedLpCompactCaps =
    (wasmCoreLP.ord.uint32 shl 24) or
    (1'u32 shl 0) or # compact runtime
    (1'u32 shl 1) or # flash-backed VM
    (1'u32 shl 2) or # software f32
    (1'u32 shl 3) or # i32
    (1'u32 shl 4)    # f32

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

proc waitStatus(address: uint, label: string,
                capsAddress: uint, capsLabel: string,
                expectedCaps: uint32): bool =
  for _ in 0 ..< WaitLimit:
    let status = sharedRead32(address)
    if status != 0:
      printHex(label, status)
      let caps = sharedRead32(capsAddress)
      printHex(capsLabel, caps)
      return status == WasmSlotSmokeOk and caps == expectedCaps
    spinDelay()
  printHex(label, sharedRead32(address))
  printHex(capsLabel, sharedRead32(capsAddress))
  false

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WASM Shared Slot Smoke Test ===")

  initWasmProgramStore()

  let installStatus = installWasmSlotSmoke()
  printHex("  wasm_slot_install=", installStatus)
  if installStatus == WasmSlotSmokeOk:
    discard console.sendLine("[PASS] M0 installed shared WASM slot")
  else:
    discard console.sendLine("[FAIL] M0 shared WASM slot install failed")
    while true:
      wfi()

  let m0Caps = wasmRuntimeCapabilityWord()
  printHex("  m0_wasm_slot_caps=", m0Caps)
  let m0RunStatus = runWasmSlotSmoke()
  printHex("  m0_wasm_slot_status=", m0RunStatus)
  let m0Ok = m0RunStatus == WasmSlotSmokeOk and m0Caps == ExpectedM0CompactCaps
  if m0Ok:
    discard console.sendLine("[PASS] M0 WASM slot runtime capabilities match compact profile")
    discard console.sendLine("[PASS] M0 invoked shared WASM slot")
  else:
    discard console.sendLine("[FAIL] M0 shared WASM slot invocation failed")

  regWrite(WasmSlotD0StatusAddr, 0)
  regWrite(WasmSlotD0CapsAddr, 0)
  regWrite(WasmSlotLpStatusAddr, 0)
  regWrite(WasmSlotLpCapsAddr, 0)
  writeWasmSlotInvokeRequest(WasmSlotD0RequestAddr, WasmSlotSmokeSlot,
                             "add", [17'i32, 25'i32], 42'i32)
  writeWasmSlotInvokeRequest(WasmSlotLpRequestAddr, WasmSlotSmokeSlot,
                             "add", [18'i32, 24'i32], 42'i32)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  discard console.sendLine("[M0] Releasing D0 shared WASM slot worker")
  releaseD0()
  let d0Ok = waitStatus(WasmSlotD0StatusAddr, "  d0_wasm_slot_status=",
                        WasmSlotD0CapsAddr, "  d0_wasm_slot_caps=",
                        ExpectedD0CompactCaps)
  if d0Ok:
    discard console.sendLine("[PASS] D0 WASM slot runtime capabilities match compact profile")
    discard console.sendLine("[PASS] D0 invoked shared WASM slot")
  else:
    discard console.sendLine("[FAIL] D0 shared WASM slot invocation failed")

  discard console.sendLine("[M0] Releasing LP shared WASM slot worker")
  releaseLP()
  let lpOk = waitStatus(WasmSlotLpStatusAddr, "  lp_wasm_slot_status=",
                        WasmSlotLpCapsAddr, "  lp_wasm_slot_caps=",
                        ExpectedLpCompactCaps)
  if lpOk:
    discard console.sendLine("[PASS] LP WASM slot runtime capabilities match compact profile")
    discard console.sendLine("[PASS] LP invoked shared WASM slot")
  else:
    discard console.sendLine("[FAIL] LP shared WASM slot invocation failed")

  if m0Ok and d0Ok and lpOk:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")

  while true:
    wfi()
