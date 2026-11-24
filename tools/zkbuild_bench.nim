## Reproducible host microbenchmark. This measures CPU time on the host,
## not BL808 latency. Run `make zkbuild-bench` after preparing sample artifacts.
import std/[os, times, json]
import bl808/[wasm_proof, enclave/sha256]
import cps/zk/wasm_profile

proc bytes(path: string): seq[byte] =
  let input = readFile(path)
  for value in input: result.add value.byte

let directory = if paramCount() == 1: paramStr(1) else: "build/zkbuild"
let key = bytes(directory / "validate.vk")
let wasm = bytes(directory / "sample.wasm")
let proof = bytes(directory / "sample.proof")
let digest = sha256(key)
let prepareStart = cpuTime()
let prepared = prepareWasmKey(digest, pmValidateBytes, key)
let prepareSeconds = cpuTime() - prepareStart
if prepared.status != wprOk: quit("cannot prepare benchmark key", 1)
const Iterations = 50
let fullStart = cpuTime()
for _ in 0..<Iterations:
  if verifyWasmProof(digest, pmValidateBytes, key, wasm, [], proof) != wprOk:
    quit("full benchmark verification failed", 1)
let fullSeconds = (cpuTime() - fullStart) / Iterations.float
let cachedStart = cpuTime()
for _ in 0..<Iterations:
  if verifyWasmProof(prepared.key, pmValidateBytes, wasm, [], proof) != wprOk:
    quit("prepared benchmark verification failed", 1)
let cachedSeconds = (cpuTime() - cachedStart) / Iterations.float
echo %*{
  "platform": "host", "iterations": Iterations, "wasm_bytes": wasm.len,
  "proof_bytes": proof.len, "key_bytes": key.len,
  "key_prepare_seconds": prepareSeconds,
  "full_verify_seconds": fullSeconds, "prepared_verify_seconds": cachedSeconds
}
