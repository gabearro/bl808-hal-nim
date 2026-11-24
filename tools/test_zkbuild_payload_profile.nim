import std/os
import zkbuild_payload_fixture
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_module_prover,wasm_module_verifier,wasm_catch_environment,wasm_digest_key,wasm_digest_claim]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc leb(value: uint32): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc name(value: string): seq[byte] =
  result = leb(uint32(value.len))
  for ch in value: result.add byte(ch)

proc section(data: var seq[byte], id: byte, content: seq[byte]) =
  data.add id
  data.add leb(uint32(content.len))
  data.add content

proc header(): seq[byte] = @[0'u8,97,115,109,1,0,0,0]



let declarations = DeclarationProfile(enabled: true,types: 2,functions: 2,parameters: 2,
  results: 2,tags: 1,localGroups: 2,localRanges: 4)
let payloads = PayloadProfile(enabled: true,imports: 4,globals: 3,tables: 2,memories: 1,
  exports: 3,elements: 3,elementItems: 4,datas: 3,customSections: 3,nameBytes: 40)
let profile = ModuleValidationProfile(eventCapacity: 16,sourceCapacity: 256,sectionCapacity: 16,
  instructionCapacity: 8,branchCapacity: 2,catchCapacity: 2,digestClaim: true,
  declarations: declarations,payloads: payloads)

proc build(data: seq[byte], p = profile): Circuit =
  buildModuleValidationCircuit(data,eventCapacity = p.eventCapacity,sourceCapacity = p.sourceCapacity,
    sectionCapacity = p.sectionCapacity,digestClaim = p.digestClaim,instructionCapacity = p.instructionCapacity,
    branchCapacity = p.branchCapacity,catchCapacity = p.catchCapacity,
    declarationProfile = p.declarations,payloadProfile = p.payloads)

proc buildForged(m: WasmModule, data: seq[byte], p: ModuleValidationProfile): Circuit =
  buildModuleValidationCircuit(m,moduleValidationRows(m,p.eventCapacity),buildCatchEnvironment(m),
    sourceBytes = data,sourceCapacity = p.sourceCapacity,sectionCapacity = p.sectionCapacity,
    privateMetadata = true,digestClaim = p.digestClaim,instructionCapacity = p.instructionCapacity,
    branchCapacity = p.branchCapacity,catchCapacity = p.catchCapacity,
    declarationProfile = p.declarations,payloadProfile = p.payloads)

proc sample(importKind = -1, definitions = false, variant = 0): seq[byte] =
  result = header()
  result.section(0,name(if variant == 0: "" else: "\xc3\xa9") & @[255'u8,0])
  result.section(1,@[1'u8,96,0,0])
  if importKind >= 0:
    var imports = @[1'u8] & name(if variant == 0: "h" else: "host") & name("") & @[byte(importKind)]
    case importKind
    of 0: imports.add 0
    of 1: imports.add @[112'u8,0,0]
    of 2: imports.add @[0'u8,0]
    else: imports.add @[127'u8,0]
    result.section(2,imports)
  if definitions:
    result.section(3,@[1'u8,0])
    if importKind != 1: result.section(4,@[1'u8,112,0,0])
    if importKind != 2: result.section(5,@[1'u8,0,1])
    result.section(6,@[2'u8,127,0,65,0,11,112,0,210,0,11])
    var exports = @[3'u8] & name("") & @[0'u8,0] & name("g") & @[3'u8,byte(if importKind == 3: 1 else: 0)] & name("m") & @[2'u8,0]
    result.section(7,exports)
    result.section(9,@[3'u8,1,0,2,0,0,5,112,0,4,65,0,11,2,210,0,11,208,112,11])
    result.section(12,@[3'u8])
    result.section(10,@[1'u8,2,0,11])
    result.section(11,@[3'u8,0,65,0,11,0,1,2,0,255,2,0,65,0,11,1,11])
  result.section(0,name("tail"))

proc repack(data: seq[byte], combine = false, redistribute = false): seq[byte] =
  result = header()
  var pos = 8
  while pos < data.len:
    let id = data[pos]
    inc pos
    var size = 0
    var shift = 0
    while true:
      let b = data[pos]
      inc pos
      size = size or (int(b and 127) shl shift)
      if b < 128: break
      shift += 7
    let payload = data[pos..<pos+size]
    pos += size
    if combine and id == 5: continue
    if combine and id == 2:
      var imports = @[4'u8]
      for kind in 0'u8..3'u8:
        imports.add name("h") & name("") & @[kind]
        case kind
        of 0: imports.add 0
        of 1: imports.add @[112'u8,0,0]
        of 2: imports.add @[0'u8,1]
        else: imports.add @[127'u8,0]
      result.section(id,imports)
    elif redistribute and id == 9:
      result.section(id,@[3'u8,1,0,0,5,112,4,210,0,11,208,112,11,210,0,11,208,112,11,4,65,0,11,0])
    else: result.section(id,payload)

proc proofCheck() =
  let data = @[header(),sample(0,true),sample(3,true,1)]
  let key = setupModuleValidation(data[0],profile)
  for i,bytes in data:
    let proof = proveModuleValidation(key,bytes,profile)
    require(proof.len == 192 and verifyModuleDigest(key.verificationKey,bytes,proof),"shared payload key proof")
    require(not verifyModuleDigest(key.verificationKey,data[(i+1) mod data.len],proof),"digest substitution")
    echo "payload proof ",i," PASS bytes=",proof.len
    let directory = getEnv("ZKBUILD_TEST_ARTIFACT_DIR")
    if directory.len != 0:
      createDir(directory)
      proc save(path: string, value: openArray[byte]) =
        var output = newString(value.len)
        for j,b in value: output[j] = char(b)
        writeFile(path,output)
      let encoded = encodeModuleDigestKey(key.verificationKey,profile.sourceCapacity)
      save(directory / "module.vk",encoded)
      save(directory / ("module-" & $i & ".wasm"),bytes)
      save(directory / ("module-" & $i & ".proof"),proof)
      var digest = ""
      const digits = "0123456789abcdef"
      for b in sha256(encoded):
        digest.add digits[int(b shr 4)]
        digest.add digits[int(b and 15)]
      writeFile(directory / "key.sha256",digest)

proc main() =
  if "--proof-only" in commandLineParams():
    proofCheck()
    return
  var variants = @[header()]
  for kind in -1..3:
    for defined in [false,true]:
      for variant in 0..1: variants.add sample(kind,defined,variant)
  variants.add repack(sample(0,true),combine = true)
  variants.add repack(sample(-1,true),redistribute = true)
  variants.add repack(sample(0,true,1),combine = true,redistribute = true)
  var common: Circuit
  for i,data in variants:
    validateModule(decodeModule(data,optimize = false))
    let c = build(data)
    require(c.satisfied(),"payload profile fixture " & $i)
    if i == 0: common = c
    else: require(common.sameShape(c),"payload matrix differs at " & $i)
    echo "profile fixture ",i," PASS ",c.constraints.len
  let bytes = fullPayloadFixture()
  let p = ModuleValidationProfile(eventCapacity: 16,sourceCapacity: 1024,sectionCapacity: 20,
    instructionCapacity: 8,branchCapacity: 2,catchCapacity: 2,digestClaim: true,
    declarations: declarations,payloads: PayloadProfile(enabled: true,imports: 6,globals: 13,
      tables: 3,memories: 1,exports: 6,elements: 8,elementItems: 16,datas: 3,customSections: 3,nameBytes: 80))
  validateModule(decodeModule(bytes,optimize = false))
  var full = build(bytes,p)
  require(full.satisfied(),"all constants, imports, segment modes and UTF8")
  var mutations = 0
  template forged(change: untyped) =
    block:
      var candidate {.inject.} = decodeModule(bytes,optimize = false)
      change
      validateModule(candidate)
      var rejected = false
      try: rejected = not buildForged(candidate,bytes,p).satisfied()
      except ValueError: rejected = true
      require(rejected,astToStr(change))
      inc mutations
  forged: candidate.imports[0].module = "b\xc3\xb4st"
  forged: candidate.imports[1].name = "z"
  forged: candidate.imports[0].funcTypeIdx = 1
  forged: candidate.imports[1].tableType.limits.max = high(uint32)-1
  forged: candidate.imports[2].memType.limits.min = 2
  forged: candidate.imports[2].memType.limits.max = 65535
  forged: candidate.imports[5].globalType.mut = mutConst
  forged: candidate.imports[5].globalType.valType = vtF64
  forged: candidate.tables[1].elemType = vtExternRef
  forged: candidate.tables[1].limits.min = 1
  forged: candidate.tables[1].limits.hasMax = false
  forged: candidate.globals[0].init.code[0].imm1 = 43
  forged: candidate.globals[1].init.code[0].imm1 = 7
  forged:
    candidate.globals[2].globalType.valType = vtI32
    candidate.globals[2].init.code[0].op = opI32Const
  forged: candidate.globals[2].init.code[0].imm1 = 0
  forged: candidate.globals[3].init.code[0].imm1 = 1
  forged: candidate.globals[7].init.code[0].imm1 = 0
  forged: candidate.globals[8].init.code[0].imm1 = 3
  forged: candidate.globals[0].globalType.mut = mutVar; candidate.globals[9].init.code[0].imm1 = 0
  forged: candidate.exports[0].name = "sun"
  forged: candidate.exports[0].idx = 0
  forged: candidate.exports[3].kind = ekGlobal
  forged: candidate.elements[0].init[0].code[0].imm1 = 1
  forged: candidate.elements[0].offset.code[0].imm1 = 1
  forged: candidate.elements[0].mode = elemPassive
  forged: candidate.elements[2].tableIdx = 2
  forged: candidate.elements[1].init.setLen(1)
  forged: candidate.datas[0].offset.code[0].imm1 = 1
  forged: candidate.datas[0].mode = dataPassive
  forged: candidate.customSections[0].name = "\0data"
  forged: candidate.customSections[2].name = "x"
  forged: candidate.customSections.setLen(2)
  forged: candidate.imports.setLen(5); candidate.globals[9].init.code[0].imm1 = 2
  forged: candidate.globals.setLen(9)
  forged: candidate.exports.setLen(5)
  forged: candidate.elements.setLen(7)
  forged: candidate.datas.setLen(2); candidate.dataCount = 2


  for budget in ["imports","globals","tables","memories","exports","elements","elementItems","datas","customSections","nameBytes"]:
    var limited = p
    case budget
    of "imports": limited.payloads.imports = 0
    of "globals": limited.payloads.globals = 0
    of "tables": limited.payloads.tables = 0
    of "memories": limited.payloads.memories = 0
    of "exports": limited.payloads.exports = 0
    of "elements": limited.payloads.elements = 0
    of "elementItems": limited.payloads.elementItems = 0
    of "datas": limited.payloads.datas = 0
    of "customSections": limited.payloads.customSections = 0
    else: limited.payloads.nameBytes = 0
    var rejected = false
    try: discard build(bytes,limited)
    except ValueError: rejected = true
    require(rejected,"must reject insufficient " & budget)
  let inferred = inferModuleValidationProfile(variants[^1])
  require(build(variants[^1],inferred).satisfied(),"exact-fit inferred profile")
  echo "payload profile PASS layouts=",variants.len," forgeries=",mutations," full-constraints=",full.constraints.len
  full = initCircuit()
  common = initCircuit()
  if "--check-only" notin commandLineParams():
    proofCheck()

main()
