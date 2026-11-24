import std/os
import cps/wasm/[proven,types]
import cps/zk/wasm_digest_claim

proc readBytes(path: string): seq[byte] =
  for ch in readFile(path): result.add byte(ch)

proc startModule(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,1,4,1,96,0,0,
    2,7,1,1,104,1,103,0,0,8,1,0]

proc sample(value: byte): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,
    7,7,1,3,114,117,110,0,0,10,6,1,4,0,65,value,11]

proc main() =
  let directory = if paramCount() == 0: "build/zkbuild/persistent-module" else: paramStr(1)
  if paramCount() > 1 and paramStr(2) == "--write-start":
    var text = ""
    for b in startModule(): text.add char(b)
    writeFile(directory / "module-3.wasm",text)
    return
  let encoded = readBytes(directory / "module.vk")
  let key = prepareModuleDigestKey(sha256(encoded),encoded)
  doAssert key != nil
  var bytes = readBytes(directory / "module-1.wasm")
  var proof = readBytes(directory / "module-1.proof")
  let engine = newWasmEngine(jit = false)
  defer: engine.destroy()
  let prior = engine.loadValidatedBytes(sample(7))
  doAssert prior.callI32("run") == 7
  let loaded = engine.loadProvenBytes(key,bytes,proof)
  doAssert loaded.callI32("run") == 42
  bytes[^2] = 43
  proof[^1] = proof[^1] xor 1
  doAssert loaded.callI32("run") == 42,"caller buffers must not mutate the loaded module"
  var rejected = false
  try: discard engine.loadProvenBytes(key,bytes,proof)
  except WasmProofError: rejected = true
  doAssert rejected
  var count = 0
  engine.addHostFunc("h","g",FuncType(),proc(args: openArray[WasmValue]): seq[WasmValue] =
    inc count
    @[])
  let startup = startModule()
  rejected = false
  try: discard engine.loadProvenBytes(key,startup,readBytes(directory / "module-1.proof"))
  except WasmProofError: rejected = true
  doAssert rejected and count == 0,"failed proof ran a host start function"
  let startProof = readBytes(directory / "module-3.proof")
  discard engine.loadProvenBytes(key,startup,startProof)
  doAssert count == 1,"verified start function must run once"
  var wrongPin = sha256(encoded)
  wrongPin[0] = wrongPin[0] xor 1
  rejected = false
  try: discard engine.loadProvenBytes(wrongPin,encoded,startup,startProof)
  except WasmProofError: rejected = true
  doAssert rejected and count == 1
  doAssert loaded.callI32("run") == 42
  echo "proven loader PASS: owned bytes, shared-store exports, pinned key, proof before host start"

main()
