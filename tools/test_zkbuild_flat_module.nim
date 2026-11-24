import std/os
import cps/wasm/[binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_module_prover,wasm_module_verifier]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

proc leb(value: int): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc section(data: var seq[byte], id: byte, payload: seq[byte]) =
  data.add id
  data.add leb(payload.len)
  data.add payload

proc moduleBytesMany(codes: seq[seq[byte]], imported = false): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  result.section(1,@[1'u8,96,0,0])
  if imported: result.section(2,@[1'u8,1,104,1,102,0,0])
  var functions = leb(codes.len)
  for _ in codes: functions.add 0
  result.section(3,functions)
  result.section(4,@[1'u8,112,0,1])
  result.section(5,@[1'u8,0,1])
  result.section(13,@[1'u8,0,0])
  result.section(7,@[1'u8,3,114,117,110,0,byte(ord(imported))])
  var bodies = leb(codes.len)
  for code in codes:
    let body = @[1'u8,1,127] & code & @[11'u8]
    bodies.add leb(body.len) & body
  result.section(10,bodies)

proc moduleBytes(code: seq[byte]): seq[byte] = moduleBytesMany(@[code])

proc circuit(data: seq[byte]): Circuit =
  buildModuleValidationCircuit(data,eventCapacity = 32,sourceCapacity = 128,sectionCapacity = 12,
    digestClaim = true,instructionCapacity = 8,branchCapacity = 4,catchCapacity = 4)

proc main() =
  var codes = @[
    newSeq[byte](),@[1'u8],@[65'u8,42,26],@[66'u8,42,26],
    @[68'u8,1,2,3,4,5,6,7,8,26],@[2'u8,64,1,11],
    @[2'u8,64,65,0,14,2,0,0,0,11],@[3'u8,64,12,0,11],
    @[65'u8,0,4,64,1,5,1,11],@[31'u8,64,0,1,11],
    @[31'u8,64,1,0,0,0,1,11],@[31'u8,64,2,0,0,0,2,0,1,11],
    @[63'u8,0,26],@[65'u8,0,40,2,0,26],@[208'u8,112,26],
    @[16'u8,0],@[18'u8,0],@[65'u8,0,17,0,0],
    @[65'u8,0,65,0,65,0,252,10,0,0],@[65'u8,0,37,0,26],@[32'u8,0,26]]
  var vector = @[253'u8,12]
  for i in 0..15: vector.add byte(i)
  vector.add 26
  codes.add vector
  var common: Circuit
  for i, code in codes:
    let data = moduleBytes(code)
    validateModule(decodeModule(data,optimize = false))
    let value = circuit(data)
    require(value.satisfied(),"flat typed case " & $i)
    if i == 0: common = value
    else: require(common.sameShape(value),"flat typed matrix changes at case " & $i)
  for imported in [false,true]:
    let a = circuit(moduleBytesMany(@[newSeq[byte](),@[1'u8,1]],imported))
    let b = circuit(moduleBytesMany(@[@[1'u8],newSeq[byte]()],imported))
    require(a.satisfied() and b.satisfied() and a.sameShape(b),"flat stream across multiple functions/imports")
  for test in [(6,1,4,4),(6,8,0,4),(11,8,4,0)]:
    var rejected = false
    try:
      discard buildModuleValidationCircuit(moduleBytes(codes[test[0]]),eventCapacity = 32,
        sourceCapacity = 128,sectionCapacity = 12,digestClaim = true,
        instructionCapacity = test[1],branchCapacity = test[2],catchCapacity = test[3])
    except ValueError: rejected = true
    require(rejected,"flat source capacity overflow must be rejected")
  echo "zkbuild flat module comparisons: PASS (",codes.len," typed bodies; one matrix; ",common.constraints.len," constraints)"
  if paramCount() == 1 and paramStr(1) == "--check-only": return
  let key = setup(common)
  let profile = ModuleValidationProfile(eventCapacity: 32,sourceCapacity: 128,sectionCapacity: 12,
    digestClaim: true,instructionCapacity: 8,branchCapacity: 4,catchCapacity: 4)
  for data in [moduleBytes(codes[0]),moduleBytes(codes[6]),moduleBytes(codes[11])]:
    let proof = proveModuleValidation(key,data,profile)
    require(verifyModuleDigest(key.verificationKey,data,proof),"reusable flat module proof")
  echo "zkbuild flat module proofs: PASS (empty/branch/catch bodies; three 192-byte proofs; one key)"

main()
