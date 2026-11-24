## Reuse a key saved before instrumentation to detect any circuit change.
import std/os
import cps/zk/[wasm_proving_key_file,wasm_module_verifier]

if paramCount() != 2: quit("usage: test_audit_key KEY WASM",1)
let loaded = loadModuleProvingKey(paramStr(1))
var bytes: seq[byte]
for ch in readFile(paramStr(2)): bytes.add byte(ch)
let proof = proveModuleValidation(loaded.key,bytes,loaded.profile)
doAssert verifyModuleDigest(loaded.key.verificationKey,bytes,proof)
echo "instrumented prover compatibility PASS: saved key, ",proof.len,"-byte proof"
