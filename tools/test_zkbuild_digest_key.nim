import cps/zk/[wasm_digest_key,wasm_digest_claim,prover]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

let bytes = @[0'u8,97,115,109,1,0,0,0]
let digest = wasmDigestInputs(bytes)
var circuit = initCircuit()
for value in digest:
  let input = circuit.publicInput(value)
  circuit.assertEqual(input,@[Term(wire: 0,coefficient: value)])
let key = setup(circuit)
let encoded = encodeModuleDigestKey(key.verificationKey,16)
require(encoded.len == ModuleDigestKeySize,"key size")
let pinned = prepareModuleDigestKey(sha256(encoded),encoded)
require(pinned != nil and pinned.sourceCapacity == 16,"prepared key")
let proof = encodeProof(prove(key,circuit))
require(verifyModuleDigest(pinned,bytes,proof),"pinned-key verifier dispatch")
var callerBuffer = @encoded
let owned = prepareModuleDigestKey(sha256(callerBuffer),callerBuffer)
callerBuffer[8] = callerBuffer[8] xor 127
require(verifyModuleDigest(owned,bytes,proof),"decoded handle owns its key after caller buffer changes")
require(not verifyModuleDigest(PinnedModuleDigestKey(nil),bytes,proof),"nil key")
require(not verifyModuleDigest(pinned,bytes & bytes & @[0'u8],proof),"capacity checked before hashing")
var wrongPin = sha256(encoded)
wrongPin[0] = wrongPin[0] xor 1
require(prepareModuleDigestKey(wrongPin,encoded) == nil,"wrong caller pin")
require(prepareModuleDigestKey(sha256(encoded & @[0'u8]),encoded & @[0'u8]) == nil,"trailing key")
require(prepareModuleDigestKey(sha256(encoded[0..encoded.high-1]),encoded[0..encoded.high-1]) == nil,"short key")
var mutations = 0
template invalid(change: untyped) =
  block:
    var bad {.inject.} = @encoded
    change
    require(prepareModuleDigestKey(sha256(bad),bad) == nil,astToStr(change))
    inc mutations
invalid: bad[0] = 0
invalid: bad[3] = 2
invalid: bad[4] = 7
invalid:
  for i in 8..55: bad[i] = 255
invalid:
  for i in 56..151: bad[i] = 0
  bad[56] = 0xc0
echo "zkbuild digest key: PASS (488-byte canonical key; pinned verification; ",mutations," codec mutations; pin/length/capacity rejection)"
