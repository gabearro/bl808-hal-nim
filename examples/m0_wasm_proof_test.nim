## Run `make zkbuild-demo` first, then use tools/zkbuild_hardware_validation.json.
## Define bl808ZkLoaderTest for the flash-layout integration variant.
## General loader admission is unchanged.
import bl808/[startup, core, glb, gpio, uart, wasm_proof, panicoverride]
when defined(bl808ZkLoaderTest):
  import bl808/wasm_verified_loader
import bl808/kernel/[alloc, clock]
import bl808/enclave/sha256
import cps/zk/wasm_profile

func fixture(s: static string): array[s.len, byte] =
  for i in 0 ..< s.len: result[i] = s[i].byte

const
  TestKey = fixture(staticRead("../build/zkbuild/validate.vk"))
  TestWasm = fixture(staticRead("../build/zkbuild/sample.wasm"))
  TestProof = fixture(staticRead("../build/zkbuild/sample.proof"))

var console: Uart

proc check(message: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(message)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(baudRate: 230400, dataBits: data8,
    stopBits: stop1, parity: parityNone), 40_000_000)
  discard console.sendLine("=== WASM proof verification ===")
  let trusted = sha256(TestKey)
  let keyStart = readTick()
  let prepared = prepareWasmKey(trusted, pmValidateBytes, TestKey)
  check("ZK key prepared", prepared.status == wprOk)
  discard console.sendString("key_prepare_ticks=")
  console.sendHex32(uint32(readTick()-keyStart))
  discard console.sendLine("")
  let start = readTick()
  check("ZK valid proof", verifyWasmProof(prepared.key, pmValidateBytes,
    TestWasm, [], TestProof) == wprOk)
  discard console.sendString("verify_ticks=")
  console.sendHex32(uint32(readTick()-start))
  discard console.sendLine("")
  var changed = TestWasm
  changed[WasmPrefix.len] = changed[WasmPrefix.len] xor 1
  check("ZK changed module rejected", verifyWasmProof(prepared.key, pmValidateBytes,
    changed, [], TestProof) == wprInvalidProof)
  var changedProof = TestProof
  changedProof[40] = changedProof[40] xor 1
  check("ZK changed proof rejected", verifyWasmProof(prepared.key, pmValidateBytes,
    TestWasm, [], changedProof) == wprInvalidProof)
  var wrongKey = trusted
  wrongKey[0] = wrongKey[0] xor 1
  check("ZK wrong key rejected", verifyWasmProof(wrongKey, pmValidateBytes,
    TestKey, TestWasm, [], TestProof) == wprKeyMismatch)
  when defined(bl808ZkLoaderTest):
    var mutableImage = TestWasm
    let loaded = loadVerifiedWasm(prepared.key, mutableImage, TestProof)
    check("ZK verified module executes", loaded.status == vwlOk and
      loaded.module.invokeI32([20'i32,22'i32]) == 294)
    mutableImage[WasmPrefix.len] = 0xff
    check("ZK loaded snapshot isolated", loaded.status == vwlOk and
      loaded.module.invokeI32([20'i32,22'i32]) == 294)
  discard console.sendLine("=== WASM proof test complete ===")
  while true: wfi()
