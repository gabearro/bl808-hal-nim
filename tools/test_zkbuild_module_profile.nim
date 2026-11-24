import std/[json,jsonutils]
import cps/zk/[r1cs,wasm_module_prover,wasm_module_validation]

proc leb(n: int): seq[byte] =
  var value = n
  while true:
    let b = byte(value and 127)
    value = value shr 7
    result.add b or (if value == 0: 0'u8 else: 128'u8)
    if value == 0: return

proc fixture(code: seq[byte]): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,10]
  let body = @[0'u8] & code & @[11'u8]
  let payload = @[1'u8] & leb(body.len) & body
  result.add leb(payload.len) & payload

for pair in [
    (@[2'u8,64,65,0,14,1,0,0,11,2,64,65,0,14,1,0,0,11],4,0),
    (@[31'u8,64,1,2,0,1,11,31,64,1,2,0,1,11],0,2)]:
  let bytes = fixture(pair[0])
  let profile = inferModuleValidationProfile(bytes)
  doAssert profile.branchCapacity == pair[1] and profile.catchCapacity == pair[2],
    "count source clauses even when identical lists share interned nodes"
  let restored = jsonTo(parseJson($toJson(profile)),ModuleValidationProfile)
  doAssert restored == profile
  let circuit = buildModuleValidationCircuit(bytes,profile.eventCapacity,profile.sourceCapacity,
    profile.sectionCapacity,profile.digestClaim,profile.instructionCapacity,
    profile.branchCapacity,profile.catchCapacity,profile.declarations,profile.payloads)
  doAssert circuit.satisfied()
var invalid = PayloadProfile(enabled: true,imports: -1)
var rejected = false
try: invalid.validate()
except ValueError: rejected = true
doAssert rejected
invalid = PayloadProfile(enabled: true,imports: int(high(uint32)))
rejected = false
try: invalid.validate()
except ValueError: rejected = true
doAssert rejected
echo "inferred module profile PASS: duplicate branch/catch lists, zero budgets, JSON, overflow"
