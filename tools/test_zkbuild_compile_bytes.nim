import cps/zk/[wasm_compile_bytes, prover_wire, fft]
import bl808/[wasm_proof, enclave/sha256]
import bl808/wasm_verified_native
import cps/wasm/[binary, validate, runtime_int]
import zkbuild_test_vm

proc check(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fromBody(body: openArray[byte]): seq[byte] =
  result = @WasmPrefix
  result[31] = byte(body.len+3)
  result[33] = byte(body.len+1)
  result.add body

let source = [Operation(kind: opParam0), Operation(kind: opParam1),
  Operation(kind: opAdd), Operation(kind: opConst, immediate: 7), Operation(kind: opMul)]
let wasm = encodeByteModule(source)
var program: Program
check(decodeByteProgram(wasm, program), "ordinary byte decoding")
check(program[SlotCount-source.len].kind == opParam0 and program[^1].kind == opMul,
  "canonical program right aligned")
let native = encodeNative(program)
let base = buildByteCompileCircuit(wasm, native, program)
check(base.satisfied(), "ordinary byte compilation relation")
check(base.publicCount == 12 and powerOfTwoCeil(base.constraints.len) == 32768,
  "byte compilation arity and domain budget")
echo "byte compilation constraints=", base.constraints.len, " wires=", base.values.len

var cases = 0
for kind in opAdd..opXor:
  for value in [0'u32, 63, 64, 127, 128, 0x7ff, 0x800, 0x80000000'u32,
      0xfffff7ff'u32, 0xfffff800'u32, 0xffffffbf'u32, 0xffffffff'u32]:
    let input = encodeByteModule([Operation(kind: opParam0),
      Operation(kind: opConst, immediate: value), Operation(kind: kind)], "foo")
    var decoded: Program
    check(decodeByteProgram(input, decoded), "all LEB widths decode")
    check(decoded[^2].immediate == value and decoded[^1].kind == kind,
      "decoded constant and opcode are exact")
    let machine = encodeNative(decoded)
    let c = buildByteCompileCircuit(input, machine, decoded)
    check(c.satisfied() and sameShape(base, c), "length and value independent matrix")
    let module = decodeModule(input)
    validateModule(module)
    var vm = initIntWasmVM()
    let index = vm.instantiateIntOnly(module)
    for argument in [0'i32, -1'i32, int32.low, int32.high]:
      check(runRv32(machine, cast[uint32](argument), 0) ==
        cast[uint32](vm.invokeI32(index, "foo", [argument, 0'i32])), "actual byte/native semantics")
    inc cases

for body in [@[0x41'u8, 0x7f, 0x0b], @[0x41'u8, 0xff, 0x7f, 0x0b],
    @[0x41'u8, 0xff, 0xff, 0x7f, 0x0b], @[0x41'u8, 0xff, 0xff, 0xff, 0x7f, 0x0b],
    @[0x41'u8, 0xff, 0xff, 0xff, 0xff, 0x7f, 0x0b]]:
  let input = fromBody(body)
  var decoded: Program
  check(decodeByteProgram(input, decoded) and decoded[^1].immediate == uint32.high,
    "nonminimal negative signed LEB")
  check(buildByteCompileCircuit(input, encodeNative(decoded), decoded).satisfied(),
    "nonminimal LEB relation")

var nops = newSeq[Operation](119)
nops[57] = Operation(kind: opParam0)
let padded = encodeByteModule(nops)
var decodedNops: Program
check(padded.len == StreamWasmMaxSize and decodeByteProgram(padded, decodedNops),
  "full byte capacity may contain more than sixteen nop instructions")
check(buildByteCompileCircuit(padded, encodeNative(decodedNops), decodedNops).satisfied(),
  "nop elimination is constrained")

var tooMany = @[Operation(kind: opParam0)]
for _ in 0..<8:
  tooMany.add Operation(kind: opConst, immediate: 1)
  tooMany.add Operation(kind: opAdd)
let overflow = encodeByteModule(tooMany)
var rejected: Program
check(checkByteModule(overflow) and not decodeByteProgram(overflow, rejected),
  "seventeen semantic operations exceed native capacity")
check(not buildByteCompileCircuit(overflow, native, program).satisfied(),
  "queue overflow is rejected by constraints independent of host decoder")

var wrong = program
wrong[^1].kind = opSub
check(not buildByteCompileCircuit(wasm, encodeNative(wrong), wrong).satisfied(),
  "different native operation cannot satisfy bridge")
wrong = program
wrong[^2].immediate = 0x80000000'u32
check(not buildByteCompileCircuit(wasm, encodeNative(wrong), wrong).satisfied(),
  "different immediate cannot satisfy bridge")
var corrupted = wasm
corrupted[31] = corrupted[31] xor 1
check(not buildByteCompileCircuit(corrupted, native, program).satisfied(), "header length bound")
for i in 1..base.publicCount:
  var mutated = base
  mutated.values[i] += scalar(1)
  check(not mutated.satisfied(), "all public raw/native limbs are constrained")

let key = setup(base)
var mode: ProofMode
let loadedKey = decodeProvingKey(encodeProvingKey(key, pmCompileBytes), mode)
check(mode == pmCompileBytes and sameShape(loadedKey.shape, base), "new claim proving-key codec")
let proof = encodeProof(prove(loadedKey, base))
let keyBytes = encodeKey(key.verificationKey, pmCompileBytes)
let prepared = prepareWasmKey(sha256(keyBytes), pmCompileBytes, keyBytes)
check(prepared.status == wprOk and proof.len == 192, "byte compilation pinned proof")
check(verifyWasmProof(prepared.key, pmCompileBytes, wasm, native, proof) == wprOk,
  "real byte compilation proof verifies")
let admitted = loadVerifiedByteNativeWasm(prepared.key, wasm, native, proof)
check(admitted.status == vnlOk and not admitted.module.isNil, "byte compilation native admission")
check(loadVerifiedNativeWasm(prepared.key, wasm, native, proof).module.isNil,
  "fixed-slot entry point does not accept an ordinary-byte key")
check(verifyWasmProof(prepared.key, pmCompile, wasm, native, proof) == wprWrongClaim,
  "new claim cannot substitute for fixed-slot compilation")
var changedNative = native
changedNative[0] = changedNative[0] xor 1
check(not verifyArtifacts(key.verificationKey, pmCompileBytes, wasm, changedNative, proof),
  "proof binds native artifact")
var sameMeaning = wasm
sameMeaning[25] = byte('f')
check(not verifyArtifacts(key.verificationKey, pmCompileBytes, sameMeaning, native, proof),
  "proof binds raw input even when semantics are unchanged")
var changedProof = proof
changedProof[40] = changedProof[40] xor 1
check(verifyWasmProof(prepared.key, pmCompileBytes, wasm, native, changedProof) == wprInvalidProof,
  "changed byte compilation proof rejected")
echo "zkbuild ordinary byte compilation: PASS (", cases, " arithmetic/LEB cases, real proof, binding and overflow rejection)"
