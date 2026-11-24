## RV32 virt-board test. The addresses are checked against QEMU's emitted DTB.
## This exercises the real verifier and native call path without BL808 MMIO.
import std/volatile
import bl808/[wasm_proof, wasm_verified_native]
import bl808/kernel/alloc
import bl808/enclave/sha256
import cps/zk/[wasm_profile, field, scalar_encoding, scalar_words]
import constantine/named/properties_fields
import zkbuild_word_arithmetic_cases
import zkbuild_fips_cases
import zkbuild_cios_cases

include "../build/zkbuild/scalar-montgomery-vectors.nim"
include "../build/zkbuild/word-arithmetic-vectors.nim"
include "../build/zkbuild/fips-vectors.nim"
include "../build/zkbuild/cios-vectors.nim"

{.emit: """
__asm__(
  ".section .init,\"ax\"\n"
  ".globl _start\n"
  "_start:\n"
  ".option push\n.option norelax\n"
  "la gp, __global_pointer$\n"
  ".option pop\n"
  "la sp, _estack\n"
  "csrw mie, zero\n"
  "li t0, 8\n"
  "csrc mstatus, t0\n"
  "li t0, 0x6000\n"
  "csrs mstatus, t0\n"
  "la t0, zk_qemu_trap\n"
  "csrw mtvec, t0\n"
  "la t0, _sbss\nla t1, _ebss\n"
  "1: bgeu t0, t1, 2f\n"
  "sw zero, 0(t0)\naddi t0, t0, 4\nj 1b\n"
  "2: call zkQemuHeapInit\n"
  "call NimMain\n"
  "call zkQemuMain\n"
  "zk_qemu_trap:\n"
  "li t0, 0x100000\nli t1, 0x3333\nsw t1, 0(t0)\n"
  "3: wfi\nj 3b\n"
  ".text\n"
);
""".}

proc zkQemuHeapInit() {.exportc, cdecl.} = heapInit()

proc putChar(c: char) =
  while (volatileLoad(cast[ptr uint8](0x10000005'u)) and 0x20) == 0: discard
  volatileStore(cast[ptr uint8](0x10000000'u), uint8(c))

proc line(message: string) =
  for c in message: putChar(c)
  putChar('\n')

proc finish(ok: bool) {.noreturn.} =
  volatileStore(cast[ptr uint32](0x100000'u), if ok: 0x5555'u32 else: 0x3333'u32)
  while true: discard

proc check(message: string, ok: bool) =
  line((if ok: "[PASS] " else: "[FAIL] ") & message)
  if not ok: finish(false)

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

proc checkScalarEncoding() =
  var boundariesMatch = true
  var wordsMatch = true
  for position in 0..<32:
    for value in 0..255:
      var encoded = ScalarModulusBE
      encoded[position] = byte(value)
      if isCanonicalScalarEncoding(encoded) != (value < int(ScalarModulusBE[position])):
        boundariesMatch = false
      let packed = scalarWords[BaseType](encoded)
      var original: BigInt[255]
      discard original.unmarshal(encoded, bigEndian)
      for i, word in packed:
        if BaseType(original.limbs[i]) != word: wordsMatch = false
  check("scalar canonical encodings", boundariesMatch)
  var counting: array[32, byte]
  for i in 0..<32: counting[i] = byte(i)
  let packed32 = scalarWords[uint32](counting)
  let packed64 = scalarWords[uint64](counting)
  check("scalar word packing", wordsMatch and packed32[0] == 0x1c1d1e1f'u32 and
    packed32[7] == 0x00010203'u32 and packed64[0] == 0x18191a1b1c1d1e1f'u64 and
    packed64[3] == 0x0001020304050607'u64)
  var empty: array[32, byte]
  var below = ScalarModulusBE
  below[^1] = below[^1] - 1
  var decoded = scalar(42)
  let zeroOk = decodeScalar(empty, decoded) and decoded.zero()
  let belowOk = decodeScalar(below, decoded) and encodeScalar(decoded) == below
  check("scalar decode boundaries", zeroOk and belowOk)
  decoded = scalar(42)
  let modulusRejected = not decodeScalar(ScalarModulusBE, decoded) and decoded.equals(scalar(42))
  var highBit: array[32, byte]
  highBit[0] = 0x80
  let highBitRejected = not decodeScalar(highBit, decoded) and decoded.equals(scalar(42))
  check("scalar reject unchanged", modulusRejected and highBitRejected)

proc checkScalarMontgomery() =
  static: doAssert WordBitWidth == 32
  var r2Bytes, oneBytes: array[32, byte]
  discard r2Bytes.marshal(Scalar.getR2modP(), bigEndian)
  discard oneBytes.marshal(Scalar.getMontyOne(), bigEndian)
  check("scalar Montgomery constants", r2Bytes == ScalarR2Reference and
    oneBytes == ScalarOneReference and uint32(Scalar.getNegInvModWord()) == ScalarNegInverse32)
  var matches = true
  for vector in ScalarMontgomeryVectors:
    var converted: Scalar
    if not decodeScalar(vector[0], converted): matches = false
    var rawBytes: array[32, byte]
    discard rawBytes.marshal(converted.mres, bigEndian)
    if rawBytes != vector[1]: matches = false
    var stored: Scalar
    discard stored.mres.unmarshal(vector[0], bigEndian)
    if encodeScalar(stored) != vector[2]: matches = false
  check("scalar Montgomery residues", matches)

proc zkQemuMain() {.exportc, cdecl.} =
  line("=== RV32 proved native execution ===")
  var ciosMatch = true
  for test in CiosVectors:
    if not checkCiosCase(test): ciosMatch = false
  check("CIOS complete schedule", ciosMatch)
  var fipsMatch = true
  for test in FipsVectors:
    if not checkFipsCase(test): fipsMatch = false
  check("FIPS complete schedule", fipsMatch)
  var wordsMatch = true
  for row in WordArithmeticVectors:
    if not checkWordArithmeticCase(row): wordsMatch = false
  check("word carry arithmetic", wordsMatch)
  checkScalarEncoding()
  checkScalarMontgomery()
  let prepared = prepareWasmKey(sha256(TestKey), TestClaim, TestKey)
  check("native key prepared", prepared.status == wprOk)
  var wasm = TestWasm
  var native = TestNative
  let loaded = loadForTest(prepared.key, wasm, native, TestProof)
  check("native artifact admitted", loaded.status == vnlOk)
  check("native execution", loaded.module.invokeI32([20'i32, 22'i32]) == 294)
  check("native i32 wrap", loaded.module.invokeI32([-1'i32, 1'i32]) == 0 and
    loaded.module.invokeI32([int32.low, 0'i32]) == int32.low)
  wasm[WasmPrefix.len] = 0xff
  native[0] = 0xff
  check("native snapshot isolation", loaded.module.invokeI32([20'i32, 22'i32]) == 294)
  let changed = loadForTest(prepared.key, TestWasm, native, TestProof)
  check("native substitution rejected", changed.status == vnlProofRejected and changed.module.isNil)
  let changedWasm = loadForTest(prepared.key, wasm, TestNative, TestProof)
  check("WASM substitution rejected", changedWasm.status == vnlProofRejected and changedWasm.module.isNil)
  var badProof = TestProof
  badProof[40] = badProof[40] xor 1
  check("proof mutation rejected", loadForTest(prepared.key, TestWasm, TestNative, badProof).module.isNil)
  var wrongKey = sha256(TestKey)
  wrongKey[0] = wrongKey[0] xor 1
  check("wrong key rejected", loadForTest(wrongKey, TestKey, TestWasm, TestNative, TestProof).proofStatus == wprKeyMismatch)
  line("=== RV32 proved native execution complete ===")
  finish(true)
