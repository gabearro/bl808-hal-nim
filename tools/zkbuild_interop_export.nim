## Export actual Nim-generated proofs and artifacts for independent checkers.
## This tool exports no proving keys or setup trapdoor values.
import std/[os, json, strutils]
import cps/zk/[prover_wire, wasm_circuit, wasm_bytes_circuit, wasm_compile_bytes]

proc hex(bytes: openArray[byte]): string =
  for b in bytes: result.add toHex(b, 2).toLowerAscii()

if paramCount() != 1: quit("usage: zkbuild_interop_export OUTPUT_JSON", 1)
var cases = newJArray()
for mode in ProofMode:
  var baseline: Program
  baseline[0] = Operation(kind: opParam0)
  baseline[1] = Operation(kind: opParam1)
  baseline[2] = Operation(kind: opAdd)
  baseline[3] = Operation(kind: opConst, immediate: 7)
  baseline[4] = Operation(kind: opMul)
  let setupWasm = if mode in {pmValidateBytes, pmCompileBytes}: encodeByteModule(baseline) else: encodeWasm(baseline)
  var setupProgram = baseline
  if mode == pmCompileBytes and not decodeByteProgram(setupWasm, setupProgram): quit("invalid setup sample", 1)
  let setupNative = if mode in {pmCompile, pmCompileBytes}: encodeNative(setupProgram) else: @[]
  let shape = if mode == pmValidateBytes: buildByteCircuit(setupWasm)
    elif mode == pmCompileBytes: buildByteCompileCircuit(setupWasm, setupNative, setupProgram)
    else: buildCircuit(mode, baseline, setupWasm, setupNative)
  let key = setup(shape)
  for variant in 0..1:
    var program = baseline
    if variant == 1:
      program[0] = Operation(kind: opConst, immediate: 0x80000000'u32)
      program[2] = Operation(kind: opXor)
      program[3].immediate = 0xffffffff'u32
      program[4] = Operation(kind: opSub)
    let wasm = if mode in {pmValidateBytes, pmCompileBytes}:
      encodeByteModule(program, if variant == 0: "add" else: "xor") else: encodeWasm(program)
    if mode == pmCompileBytes and not decodeByteProgram(wasm, program): quit("invalid sample", 1)
    let native = if mode in {pmCompile, pmCompileBytes}: encodeNative(program) else: @[]
    let witness = if mode == pmValidateBytes: buildByteCircuit(wasm)
      elif mode == pmCompileBytes: buildByteCompileCircuit(wasm, native, program)
      else: buildCircuit(mode, program, wasm, native)
    let proof = encodeProof(prove(key, witness))
    if not verifyArtifacts(key.verificationKey, mode, wasm, native, proof):
      quit("Nim self-check failed", 1)
    var inputs = newJArray()
    for value in publicInputs(mode, wasm, native): inputs.add %hex(encodeScalar(value))
    cases.add %*{
      "name": $mode & "_" & $variant, "mode": ord(mode),
      "verification_key": hex(encodeKey(key.verificationKey, mode)),
      "proof": hex(proof), "public_inputs": inputs,
      "wasm": hex(wasm), "native": hex(native)
    }
writeFile(paramStr(1), pretty(%*{"format": "zkbuild-interop-v1", "cases": cases}) & "\n")
echo "zkbuild interop export: ", cases.len, " proofs"
