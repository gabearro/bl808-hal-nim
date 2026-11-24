import cps/zk/[prover_wire, wasm_bytes_circuit]
import cps/wasm/[binary, validate, runtime_int]
import bl808/[wasm_proof, enclave/sha256]
import bl808/wasm_verified_loader

proc check(ok: bool, what: string) =
  if not ok: raise newException(ValueError, what)

proc moduleBytes(code: openArray[byte], name = "run"): seq[byte] =
  if name.len != 3 or code.len > 120: raise newException(ValueError, "test dimensions")
  result = @WasmPrefix
  for i in 0..2: result[25+i] = name[i].byte
  result[31] = byte(code.len+4)
  result[33] = byte(code.len+2)
  result.add code
  result.add 0x0b

let addModule = moduleBytes([0x20'u8, 0, 0x20, 1, 0x6a], "add")
check(encodeByteModule([Operation(kind: opParam0), Operation(kind: opParam1),
  Operation(kind: opAdd)], "add") == addModule, "compact encoder matches raw bytes")
let valid = buildByteCircuit(addModule)
echo "byte validation: constraints=", valid.constraints.len, " wires=", valid.values.len
check(valid.constraints.len <= 8192, "byte profile stays within the 8192-point QAP domain")
check(valid.satisfied(), "ordinary module circuit")
check(checkByteModule(addModule), "ordinary module parser")
let module = decodeModule(addModule)
validateModule(module)
var vm = initIntWasmVM()
let idx = vm.instantiateIntOnly(module)
check(vm.invokeI32(idx, "add", [20'i32,22'i32]) == 42, "ordinary WASM execution")

let goodBodies = @[
  @[0x20'u8, 0],
  @[0x41'u8, 0],
  @[0x41'u8, 0x7f],
  @[0x41'u8, 0xc0, 0],
  @[0x41'u8, 0x80, 0x01],
  @[0x41'u8, 0x0b], # end byte used as an immediate, not an opcode
  @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0x78],
  @[0x41'u8, 0xff, 0xff, 0xff, 0xff, 0x07],
  @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0], # allowed non-minimal signed LEB
]
for body in goodBodies:
  let raw = moduleBytes(body)
  check(checkByteModule(raw), "valid LEB parser")
  let c = buildByteCircuit(raw)
  check(c.satisfied(), "valid LEB circuit")
  check(sameShape(valid, c), "length-independent circuit shape")
  validateModule(decodeModule(raw))

for value in [0'u32, 63, 64, 127, 128, 0x7fffffff'u32, 0x80000000'u32, 0xffffffff'u32]:
  let raw = encodeByteModule([Operation(kind: opConst, immediate: value)])
  check(buildByteCircuit(raw).satisfied(), "minimal constant encoding")
  let parsed = decodeModule(raw)
  validateModule(parsed)
  var constantVm = initIntWasmVM()
  let constantModule = constantVm.instantiateIntOnly(parsed)
  check(cast[uint32](constantVm.invokeI32(constantModule, "run", [0'i32,0'i32])) == value,
    "minimal LEB preserves constant value")

let badBodies = @[
  newSeq[byte](),
  @[0x6a'u8],
  @[0x20'u8, 0, 0x6a, 0x20, 1], # invalid binary input cannot be repaired later
  @[0x20'u8, 2],
  @[0x20'u8, 0x80, 0], # profile forbids multi-byte parameter indices
  @[0x10'u8, 0],
  @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0x08],
  @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0x70],
  @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0x80, 0],
  @[0x20'u8, 0, 0x0b, 0], # bytes after end, with matching section lengths
  @[0x20'u8, 0, 0x20, 1], # wrong final stack height
]
for body in badBodies:
  let raw = moduleBytes(body)
  check(not checkByteModule(raw), "invalid byte parser")
  check(not buildByteCircuit(raw).satisfied(), "invalid bytes cannot satisfy circuit")

for position in [0, 4, 9, 10, 12, 18, 22, 24, 28, 29, 30, 31, 32, 33, 34]:
  var bad = addModule
  bad[position] = bad[position] xor 1
  check(not buildByteCircuit(bad).satisfied(), "header byte bound")
var badName = addModule
badName[25] = 0xff
check(not buildByteCircuit(badName).satisfied(), "export UTF8 profile constraint")
var tooDeep: seq[byte]
for _ in 0..<9: tooDeep.add [0x20'u8,0]
for _ in 0..<8: tooDeep.add 0x6a
check(not buildByteCircuit(moduleBytes(tooDeep)).satisfied(), "stack limit")
var longBody = @[0x20'u8,0]
while longBody.len < 120: longBody.add 1
check(buildByteCircuit(moduleBytes(longBody)).satisfied(), "full byte capacity")

let key = setup(valid)
let proof = encodeProof(prove(key, valid))
check(proof.len == 192, "constant proof size")
let keyBytes = encodeKey(key.verificationKey, pmValidateBytes)
var mutableKey = keyBytes
let prepared = prepareWasmKey(sha256(mutableKey), pmValidateBytes, mutableKey)
check(prepared.status == wprOk and not prepared.key.isNil, "prepare pinned key")
mutableKey[8] = mutableKey[8] xor 1
check(verifyWasmProof(prepared.key, pmValidateBytes, addModule, [], proof) == wprOk,
  "pinned key does not alias caller bytes")
check(verifyWasmProof(prepared.key, pmCompile, addModule, [], proof) == wprWrongClaim,
  "pinned key cannot change its claim")
check(verifyWasmProof(PinnedWasmKey(), pmValidateBytes, addModule, [], proof) == wprInvalidKey,
  "uninitialized key cannot bypass pinning")
check(verifyWasmProof(nil, pmValidateBytes, addModule, [], proof) == wprInvalidKey,
  "nil key is rejected")
let wrongPrepared = prepareWasmKey(default(Sha256Digest), pmValidateBytes, keyBytes)
check(wrongPrepared.status == wprKeyMismatch and wrongPrepared.key.isNil,
  "failed preparation exposes no key")
check(verifyWasmProof(sha256(keyBytes), pmValidateBytes, keyBytes, addModule, [], proof) == wprOk,
  "kernel accepts ordinary WASM proof")
check(verifyWasmProof(sha256(keyBytes), pmValidate, keyBytes, encodeWasm(default(Program)), [], proof) == wprWrongClaim,
  "legacy claim cannot be substituted")
var mutableSource = addModule
let loaded = loadVerifiedWasm(prepared.key, mutableSource, proof)
check(loaded.status == vwlOk and not loaded.module.isNil, "proof-gated loader")
check(loaded.module.invokeI32([20'i32,22'i32]) == 42, "verified module executes")
mutableSource[WasmPrefix.len] = 0xff
check(loaded.module.invokeI32([20'i32,22'i32]) == 42, "loaded bytes do not alias caller memory")
let rejected = loadVerifiedWasm(sha256(keyBytes), keyBytes, mutableSource, proof)
check(rejected.status == vwlProofRejected and rejected.module.isNil, "invalid proof cannot instantiate")
var extended = addModule
extended.add 0
check(not verifyArtifacts(key.verificationKey, pmValidateBytes, extended, [], proof),
  "public length binds zero padding")
for i in 1..valid.publicCount:
  var changed = valid
  changed.values[i] += scalar(1)
  check(not changed.satisfied(), "every byte-profile public limb constrained")
echo "zkbuild ordinary WASM byte validation: PASS"
