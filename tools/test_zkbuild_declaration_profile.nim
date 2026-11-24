import std/os
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_module_prover,wasm_module_verifier,wasm_catch_environment]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

proc leb(value: uint32): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc section(bytes: var seq[byte], id: byte, payload: seq[byte]) =
  bytes.add id
  bytes.add leb(uint32(payload.len))
  bytes.add payload

type Body = tuple[typeIndex: uint32,locals: seq[LocalDecl],code: seq[byte]]

proc fixture(types: seq[FuncType], bodies: seq[Body], tags: seq[uint32] = @[], nonminimal = false, imported = false): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  if types.len != 0:
    var payload = leb(uint32(types.len))
    for signature in types:
      payload.add 96
      payload.add leb(uint32(signature.params.len))
      for tag in signature.params: payload.add byte(ord(tag))
      payload.add leb(uint32(signature.results.len))
      for tag in signature.results: payload.add byte(ord(tag))
    result.section(1,payload)
  if imported: result.section(2,@[1'u8,1,104,1,102,0,0])
  if bodies.len != 0:
    var payload = leb(uint32(bodies.len))
    for body in bodies: payload.add leb(body.typeIndex)
    result.section(3,payload)
  if tags.len != 0:
    var payload = leb(uint32(tags.len))
    for index in tags: payload.add @[0'u8] & leb(index)
    result.section(13,payload)
  if bodies.len != 0:
    var payload = leb(uint32(bodies.len))
    for body in bodies:
      var code = leb(uint32(body.locals.len))
      for local in body.locals:
        var count = leb(local.count)
        if nonminimal and count.len < 5:
          count[^1] = count[^1] or 128
          count.add 0
        code.add count & @[byte(ord(local.valType))]
      code.add body.code & @[11'u8]
      payload.add leb(uint32(code.len)) & code
    result.section(10,payload)

let declarations = DeclarationProfile(enabled: true,types: 3,functions: 2,parameters: 7,
  results: 7,tags: 2,localGroups: 7,localRanges: 8)
let profile = ModuleValidationProfile(eventCapacity: 16,sourceCapacity: 128,sectionCapacity: 10,
  instructionCapacity: 8,branchCapacity: 2,catchCapacity: 2,digestClaim: true,declarations: declarations)

proc circuit(data: seq[byte]): Circuit =
  buildModuleValidationCircuit(data,eventCapacity = profile.eventCapacity,sourceCapacity = profile.sourceCapacity,
    sectionCapacity = profile.sectionCapacity,digestClaim = true,instructionCapacity = profile.instructionCapacity,
    branchCapacity = profile.branchCapacity,catchCapacity = profile.catchCapacity,declarationProfile = declarations)

proc forgedCircuit(module: WasmModule, data: seq[byte]): Circuit =
  buildModuleValidationCircuit(module,moduleValidationRows(module,profile.eventCapacity),buildCatchEnvironment(module),
    sourceBytes = data,sourceCapacity = profile.sourceCapacity,sectionCapacity = profile.sectionCapacity,
    privateMetadata = true,digestClaim = true,instructionCapacity = profile.instructionCapacity,
    branchCapacity = profile.branchCapacity,catchCapacity = profile.catchCapacity,declarationProfile = declarations)

proc main() =
  let allTypes = @[vtI32,vtI64,vtF32,vtF64,vtV128,vtFuncRef,vtExternRef]
  let empty = FuncType()
  let noLocals = newSeq[LocalDecl]()
  let noCode = newSeq[byte]()
  var variants = @[
    fixture(@[],@[]),
    fixture(@[FuncType(params: allTypes,results: allTypes)],@[]),
    fixture(@[empty],@[(0'u32,noLocals,noCode)]),
    fixture(@[empty],@[(0'u32,@[LocalDecl(count: 0,valType: vtI32),LocalDecl(count: 3,valType: vtI64)],noCode)]),
    fixture(@[FuncType(params: @[vtI32],results: @[vtI64])],@[(0'u32,@[LocalDecl(count: 4,valType: vtF32)],@[66'u8,0])]),
    fixture(@[empty,FuncType(params: @[vtExternRef,vtF64],results: @[vtI32])],
      @[(0'u32,noLocals,noCode),(1'u32,@[LocalDecl(count: 1,valType: vtFuncRef)],@[65'u8,0])]),
    fixture(@[FuncType(params: allTypes)],@[],@[0'u32]),
    fixture(@[empty,FuncType(params: @[vtI32,vtFuncRef])],@[],@[0'u32,1]),
    fixture(@[empty],@[(0'u32,@[LocalDecl(count: high(uint32),valType: vtI32)],noCode)]),
    fixture(@[empty,empty],@[(0'u32,noLocals,noCode),(1'u32,noLocals,@[1'u8])]),
    fixture(@[FuncType(params: allTypes,results: allTypes)],@[(0'u32,noLocals,@[0'u8])])]
  var locals: seq[LocalDecl]
  for i, tag in allTypes: locals.add LocalDecl(count: uint32(i),valType: tag)
  variants.add fixture(@[empty],@[(0'u32,locals,noCode)])
  variants.add fixture(@[empty],@[(0'u32,@[LocalDecl(count: 3,valType: vtI32)],noCode)],nonminimal = true)
  var common: Circuit
  for i, data in variants:
    validateModule(decodeModule(data,optimize = false))
    let checked = circuit(data)
    require(checked.satisfied(),"declaration profile fixture " & $i)
    if i == 0: common = checked
    else: require(common.sameShape(checked),"declaration matrix changed at fixture " & $i)
  let importedA = circuit(fixture(@[empty],@[],imported = true))
  let importedB = circuit(fixture(@[empty,FuncType(params: @[vtI32])],
    @[(0'u32,noLocals,noCode),(1'u32,noLocals,noCode)],imported = true))
  require(importedA.satisfied() and importedB.satisfied() and importedA.sameShape(importedB),
    "declaration profile with an imported function offset")
  let bytes = fixture(@[empty,empty,FuncType(params: @[vtI32],results: @[vtF64])],
    @[(0'u32,@[LocalDecl(count: 0,valType: vtI32),LocalDecl(count: 3,valType: vtI64)],noCode),
      (0'u32,noLocals,noCode)],@[0'u32])
  var mutations: int
  template forged(change: untyped) =
    block:
      var candidate {.inject.} = decodeModule(bytes,optimize = false)
      change
      validateModule(candidate)
      var rejected = false
      try: rejected = not forgedCircuit(candidate,bytes).satisfied()
      except ValueError: rejected = true
      require(rejected,astToStr(change))
      inc mutations
  forged: candidate.types[2].params[0] = vtI64
  forged: candidate.types[2].results[0] = vtI32
  forged: candidate.funcTypeIdxs[0] = 1
  forged: candidate.codes[0].locals[0].valType = vtV128
  forged: candidate.codes[0].locals[1].count = 4
  forged: candidate.codes[0].locals.setLen(1)
  forged: candidate.tagDefs[0].typeIdx = 1
  forged: candidate.tagDefs.setLen(0)
  forged: candidate.codes.setLen(1); candidate.funcTypeIdxs.setLen(1)
  for budget in ["types","functions","locals","parameters","tags"]:
    var limits = declarations
    case budget
    of "types": limits.types = 0
    of "functions": limits.functions = 0
    of "locals": limits.localGroups = 0
    of "parameters": limits.parameters = 0
    else: limits.tags = 0
    var rejected = false
    try:
      discard buildModuleValidationCircuit(bytes,eventCapacity = profile.eventCapacity,sourceCapacity = profile.sourceCapacity,
        sectionCapacity = profile.sectionCapacity,digestClaim = true,instructionCapacity = profile.instructionCapacity,
        branchCapacity = profile.branchCapacity,catchCapacity = profile.catchCapacity,declarationProfile = limits)
    except ValueError: rejected = true
    require(rejected,"declaration capacity must not silently truncate " & budget)
  echo "zkbuild declaration profile: PASS (",variants.len," layouts; ",mutations,
    " source/metadata forgeries; ",common.constraints.len," constraints; one matrix)"
  if paramCount() == 1 and paramStr(1) == "--check-only": return
  let key = setup(common)
  for data in [variants[0],variants[5],variants[8]]:
    let proof = proveModuleValidation(key,data,profile)
    require(verifyModuleDigest(key.verificationKey,data,proof),"declaration profile proof")
  echo "zkbuild declaration profile proofs: PASS (empty/multiple-functions/u32-locals; one key; three 192-byte proofs)"

main()
