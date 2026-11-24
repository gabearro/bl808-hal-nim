import cps/zk/[field, fft, r1cs, prover, wasm_profile, wasm_circuit, prover_wire]
import bl808/[wasm_proof, enclave/sha256]
import bl808/wasm_verified_native
import cps/wasm/[binary, validate, runtime_int]
import zkbuild_test_vm

proc check(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

for n in [1, 2, 4, 8, 32]:
  var a: seq[Scalar]
  for i in 0 ..< n: a.add scalar(i*i + 17)
  let original = a
  a.fft()
  a.fft(invert = true)
  for i in 0 ..< n: check(a[i].equals(original[i]), "FFT roundtrip")

var c = initCircuit()
let outp = c.publicInput(scalar(42))
let a = c.allocate(scalar(6))
let b = c.allocate(scalar(7))
c.assertEqual(c.multiply(a, b), outp)
check(c.satisfied(), "valid R1CS")
let key = setup(c)
let proof = prove(key, c)
check(verify(key.verificationKey, proof, [scalar(42)]), "Groth16 verification")
check(not verify(key.verificationKey, proof, [scalar(43)]), "wrong public input")
let encoded = encodeProof(proof)
var decoded: Proof
check(decodeProof(encoded, decoded), "proof decode")
check(verify(key.verificationKey, decoded, [scalar(42)]), "decoded proof")
# Exercise subgroup rejection through the optimized bytes-to-verification
# path. The G1 point x=0 has order three, checked here with group addition.
var torsionBytes: array[48, byte]
torsionBytes[0] = 0x80
var torsion: Point1
check(deserialize_g1_compressed_unchecked(torsion, torsionBytes) == cttCodecEcc_Success,
  "G1 torsion fixture lies on curve")
check(not bool(torsion.isNeutral()) and bool(torsion.add(torsion).add(torsion).isNeutral()),
  "G1 fixture has order three")
for offset in [0, 144]:
  var invalidProof = encoded
  for i in 0..<48: invalidProof[offset+i] = torsionBytes[i]
  var rejected: Proof
  check(not decodeProof(invalidProof, rejected), "G1 subgroup checked during proof decode")
  check(not decodeAndVerify(key.verificationKey, invalidProof, [scalar(42)]),
    "optimized verification rejects G1 torsion")
var g2FixtureFound = false
for x in 0..255:
  var raw: array[96, byte]
  raw[0] = 0x80
  raw[95] = x.byte
  var point: Point2
  if deserialize_g2_compressed_unchecked(point, raw) != cttCodecEcc_Success: continue
  if validate_g2(point) != cttCodecEcc_PointNotInSubgroup: continue
  var invalidProof = encoded
  for i in 0..<96: invalidProof[48+i] = raw[i]
  var rejected: Proof
  check(not decodeProof(invalidProof, rejected), "G2 subgroup checked during proof decode")
  check(not decodeAndVerify(key.verificationKey, invalidProof, [scalar(42)]),
    "optimized verification rejects G2 torsion")
  g2FixtureFound = true
  break
check(g2FixtureFound, "G2 non-subgroup fixture exercised")
c.values[1] = scalar(43)
check(not c.satisfied(), "invalid R1CS")
var rejectedWitness = false
try: discard prove(key, c)
except ValueError: rejectedWitness = true
check(rejectedWitness, "prover rejects unsatisfied witness before curve operations")
c.values[1] = scalar(42)
var wrongDomainKey = key
wrongDomainKey.domainSize *= 2
var rejectedDomain = false
try: discard prove(wrongDomainKey, c)
except ValueError: rejectedDomain = true
check(rejectedDomain, "prover rejects inconsistent QAP domain")
echo "zkbuild arithmetic and Groth16: PASS"

var program: Program
program[0] = Operation(kind: opParam0)
program[1] = Operation(kind: opParam1)
program[2] = Operation(kind: opAdd)
program[3] = Operation(kind: opConst, immediate: 0xfffff800'u32)
program[4] = Operation(kind: opXor)
let wasm = encodeWasm(program)
let native = encodeNative(program)
check(runRv32(native, 20, 22) == (42'u32 xor 0xfffff800'u32), "independent RV32 execution")
let decodedModule = decodeModule(wasm)
validateModule(decodedModule)
var vm = initIntWasmVM()
let moduleIndex = vm.instantiateIntOnly(decodedModule)
check(vm.invokeI32(moduleIndex, "run", [20'i32, 22'i32]) == cast[int32](42'u32 xor 0xfffff800'u32),
  "existing WASM VM compatibility")
check(wasm.len == WasmSize and native.len == NativeSize, "artifact sizes")
var parsed: Program
check(decodeWasm(wasm, parsed), "canonical WASM decode")
for mode in [pmValidate, pmCompile]:
  let instance = buildCircuit(mode, program, wasm, native)
  echo "mode=", mode, " constraints=", instance.constraints.len, " wires=", instance.values.len
  check(instance.satisfied(), "valid WASM relation")
  var other = program
  other[3].immediate = 0x80000000'u32
  other[0] = Operation(kind: opConst, immediate: 3)
  other[2].kind = opSub
  check(sameShape(instance, buildCircuit(mode, other, encodeWasm(other), encodeNative(other))),
    "witness-independent circuit shape")
  for publicIndex in 1 .. instance.publicCount:
    var mutated = instance
    mutated.values[publicIndex] += scalar(1)
    check(not mutated.satisfied(), "every public limb is constrained")
  var corrupted = wasm
  corrupted[WasmPrefix.len] = 0x41
  check(not buildCircuit(mode, program, corrupted, native).satisfied(), "byte binding")
  let key = setup(instance)
  let encodedKey = encodeKey(key.verificationKey, mode)
  var decodedMode: ProofMode
  let roundtripKey = decodeProvingKey(encodeProvingKey(key, mode), decodedMode)
  check(decodedMode == mode and sameShape(roundtripKey.shape, instance), "proving-key roundtrip")
  let bytes = encodeProof(prove(roundtripKey, instance))
  if mode == pmValidate:
    let weakPolicy = prepareWasmKey(sha256(encodedKey), pmValidate, encodedKey)
    let downgraded = loadVerifiedNativeWasm(weakPolicy.key, wasm, native, bytes)
    check(downgraded.status == vnlProofRejected and downgraded.proofStatus == wprWrongClaim and downgraded.module.isNil,
      "native loader cannot downgrade to a validation proof")
  let modeNative = if mode == pmCompile: native else: @[]
  check(verifyArtifacts(key.verificationKey, mode, wasm, modeNative, bytes), "WASM proof")
  check(verifyWasmProof(sha256(encodedKey), mode, encodedKey, wasm, modeNative, bytes) == wprOk,
    "kernel proof admission")
  var badKeyDigest = sha256(encodedKey)
  badKeyDigest[0] = badKeyDigest[0] xor 1
  check(verifyWasmProof(badKeyDigest, mode, encodedKey, wasm, modeNative, bytes) == wprKeyMismatch,
    "kernel key pin")
  check(not verifyArtifacts(key.verificationKey, mode, corrupted, modeNative, bytes),
    "WASM substitution rejected")
  var badProof = bytes
  badProof[40] = badProof[40] xor 1
  check(not verifyArtifacts(key.verificationKey, mode, wasm, modeNative, badProof),
    "proof mutation rejected")
  if mode == pmCompile:
    var wrongNative = native
    wrongNative[10] = wrongNative[10] xor 1
    check(not verifyArtifacts(key.verificationKey, mode, wasm, wrongNative, bytes),
      "native substitution rejected")
    let nativePolicy = prepareWasmKey(sha256(encodedKey), pmCompile, encodedKey)
    let admitted = loadVerifiedNativeWasm(nativePolicy.key, wasm, native, bytes)
    check(admitted.status == vnlOk and admitted.proofStatus == wprOk and not admitted.module.isNil,
      "native loader admits the compilation proof")
    let badNative = loadVerifiedNativeWasm(nativePolicy.key, wasm, wrongNative, bytes)
    check(badNative.status == vnlProofRejected and badNative.module.isNil,
      "native loader rejects substituted code")
    let badWasm = loadVerifiedNativeWasm(nativePolicy.key, corrupted, native, bytes)
    check(badWasm.status == vnlProofRejected and badWasm.module.isNil,
      "native loader rejects substituted WASM")
    let rejectedProof = loadVerifiedNativeWasm(nativePolicy.key, wasm, native, badProof)
    check(rejectedProof.status == vnlProofRejected and rejectedProof.proofStatus == wprInvalidProof and rejectedProof.module.isNil,
      "native loader rejects a mutated proof")
    let truncatedNative = loadVerifiedNativeWasm(nativePolicy.key, wasm, native[0..<native.high], bytes)
    check(truncatedNative.status == vnlProofRejected and truncatedNative.module.isNil,
      "native loader rejects truncated code")
    let unpinned = loadVerifiedNativeWasm(default(Sha256Digest), encodedKey, wasm, native, bytes)
    check(unpinned.status == vnlProofRejected and unpinned.proofStatus == wprKeyMismatch and unpinned.module.isNil,
      "native loader enforces key pinning")
    if not nativeExecutionSupported():
      var unsupported = false
      try: discard admitted.module.invokeI32([20'i32, 22'i32])
      except ValueError: unsupported = true
      check(unsupported, "native loader does not execute RV32 code on the host architecture")
  check(not verifyArtifacts(key.verificationKey, mode, wasm, modeNative, bytes[0..<191]),
    "truncated proof rejected")
  var extraByte = @bytes
  extraByte.add 0
  check(not verifyArtifacts(key.verificationKey, mode, wasm, modeNative, extraByte),
    "trailing proof data rejected")

for module in [VerifiedNativeWasmModule(nil), VerifiedNativeWasmModule()]:
  var rejected = false
  try: discard module.invokeI32([0'i32, 0'i32])
  except ValueError: rejected = true
  check(rejected, "uninitialized native module cannot execute")

for kind in opAdd .. opXor:
  for immediate in [0'u32, 0x7ff, 0x800, 0x80000000'u32, 0xfffff7ff'u32, 0xfffff800'u32, 0xffffffff'u32]:
    var p: Program
    p[0] = Operation(kind: opParam0)
    p[1] = Operation(kind: opConst, immediate: immediate)
    p[2] = Operation(kind: kind)
    let w = encodeWasm(p)
    let machine = encodeNative(p)
    check(buildCircuit(pmCompile, p, w, machine).satisfied(), "integer edge-case constraints")
    let module = decodeModule(w)
    validateModule(module)
    var interpreter = initIntWasmVM()
    let idx = interpreter.instantiateIntOnly(module)
    for arg in [0'u32, 1'u32, 0x7fffffff'u32, 0x80000000'u32, 0xffffffff'u32]:
      let wasmResult = interpreter.invokeI32(idx, "run", [cast[int32](arg), 0'i32])
      check(runRv32(machine, arg, 0) == cast[uint32](wasmResult), "WASM/RV32 differential execution")

var invalid: Program
invalid[0] = Operation(kind: opAdd)
check(not buildCircuit(pmValidate, invalid, encodeWasm(invalid), @[]).satisfied(), "underflow constraints")
for i in 0 ..< 9: invalid[i] = Operation(kind: opParam0)
check(not buildCircuit(pmValidate, invalid, encodeWasm(invalid), @[]).satisfied(), "overflow constraints")
invalid = default(Program)
check(not buildCircuit(pmValidate, invalid, encodeWasm(invalid), @[]).satisfied(), "empty result constraints")
echo "zkbuild WASM circuits: PASS"
