## Generate fixtures with `make zkbuild-compile-demo`, then use the isolated
## zkbuild hardware manifest. This test executes the proof-bound RV32 bytes.
import bl808/[startup, core, glb, gpio, uart, wasm_proof, wasm_verified_native, panicoverride]
import bl808/kernel/[alloc, clock]
import bl808/enclave/sha256
import cps/zk/wasm_profile

func fixture(s: static string): array[s.len, byte] =
  for i in 0..<s.len: result[i] = s[i].byte

when defined(zkbuildByteNativeTest):
  const
    TestKey = fixture(staticRead("../build/zkbuild/compile-bytes.vk"))
    TestWasm = fixture(staticRead("../build/zkbuild/bytes-compiled.wasm"))
    TestProof = fixture(staticRead("../build/zkbuild/compile-bytes.proof"))
    TestNative = fixture(staticRead("../build/zkbuild/bytes-compiled.rv32"))
    TestClaim = pmCompileBytes
else:
  const
    TestKey = fixture(staticRead("../build/zkbuild/compile.vk"))
    TestWasm = fixture(staticRead("../build/zkbuild/slots.wasm"))
    TestProof = fixture(staticRead("../build/zkbuild/compile.proof"))
    TestNative = fixture(staticRead("../build/zkbuild/sample.rv32"))
    TestClaim = pmCompile

proc loadForTest(key: PinnedWasmKey, wasm, native, proof: openArray[byte]): VerifiedNativeLoadResult =
  when defined(zkbuildByteNativeTest): loadVerifiedByteNativeWasm(key, wasm, native, proof)
  else: loadVerifiedNativeWasm(key, wasm, native, proof)

proc loadForTest(digest: Sha256Digest, key, wasm, native, proof: openArray[byte]): VerifiedNativeLoadResult =
  when defined(zkbuildByteNativeTest): loadVerifiedByteNativeWasm(digest, key, wasm, native, proof)
  else: loadVerifiedNativeWasm(digest, key, wasm, native, proof)

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
  discard console.sendLine("=== WASM native proof execution ===")
  let trusted = sha256(TestKey)
  let prepared = prepareWasmKey(trusted, TestClaim, TestKey)
  check("ZK native key prepared", prepared.status == wprOk)
  var wasm = TestWasm
  var native = TestNative
  let start = readTick()
  let loaded = loadForTest(prepared.key, wasm, native, TestProof)
  check("ZK native artifact admitted", loaded.status == vnlOk)
  discard console.sendString("native_admission_ticks=")
  console.sendHex32(uint32(readTick()-start))
  discard console.sendLine("")
  if loaded.status == vnlOk:
    check("ZK native code executes", loaded.module.invokeI32([20'i32, 22'i32]) == 294)
    check("ZK native i32 wraps", loaded.module.invokeI32([-1'i32, 1'i32]) == 0 and
      loaded.module.invokeI32([int32.low, 0'i32]) == int32.low)
    wasm[WasmPrefix.len] = 0xff
    native[0] = 0xff
    check("ZK native snapshot isolated", loaded.module.invokeI32([20'i32, 22'i32]) == 294)
  let badNative = loadForTest(prepared.key, TestWasm, native, TestProof)
  check("ZK changed native rejected", badNative.status == vnlProofRejected and badNative.module.isNil)
  let badWasm = loadForTest(prepared.key, wasm, TestNative, TestProof)
  check("ZK native changed WASM rejected", badWasm.status == vnlProofRejected and badWasm.module.isNil)
  var changedProof = TestProof
  changedProof[40] = changedProof[40] xor 1
  let badProof = loadForTest(prepared.key, TestWasm, TestNative, changedProof)
  check("ZK native changed proof rejected", badProof.status == vnlProofRejected and badProof.module.isNil)
  var wrongKey = trusted
  wrongKey[0] = wrongKey[0] xor 1
  let badKey = loadForTest(wrongKey, TestKey, TestWasm, TestNative, TestProof)
  check("ZK native wrong key rejected", badKey.proofStatus == wprKeyMismatch and badKey.module.isNil)
  discard console.sendLine("=== WASM native proof test complete ===")
  while true: wfi()
