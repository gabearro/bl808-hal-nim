## Full supported payload grammar, independently valid metadata substitutions,
## and malformed source framing. Does not rely on the host parser rejecting a
## forged module: the source relation itself must reject those substitutions.
import std/os
import cps/wasm/[types, binary, validate]
import cps/zk/[r1cs, prover, read_only_memory, wasm_binary_source,
  wasm_binary_envelope, wasm_payload_source, wasm_module_context,
  wasm_type_environment, wasm_signature_environment, wasm_bulk_context,
  wasm_module_validation, wasm_binary_claim, wasm_module_verifier]

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

proc fixture(value = 42'u8): seq[byte] =
  result = header()
  result.section(0, name("\0meta") & @[255'u8,0,11])
  result.section(1, @[2'u8,96,0,0,96,0,0])
  var imports = @[6'u8]
  imports.add name("h\xc3\xb4st") & name("f") & @[0'u8,0]
  imports.add name("h") & name("t") & @[1'u8,112,1,0] & leb(high(uint32))
  imports.add name("h") & name("m") & @[2'u8,1,1] & leb(65536)
  imports.add name("h") & name("g") & @[3'u8,127,0]
  imports.add name("h") & name("e") & @[3'u8,111,0]
  imports.add name("h") & name("v") & @[3'u8,126,1]
  result.section(2, imports)
  result.section(3, @[1'u8,0])
  result.section(4, @[2'u8,111,0,0,112,1,0,5])
  result.section(13, @[1'u8,0,0])
  var globals = @[10'u8,
    127,0,65,value,11,                         # i32
    126,0,66,255,255,255,255,255,255,255,255,255,0,11, # i64 positive 2^63-1
    125,0,67,0,0,192,127,11,                  # f32 NaN bits
    124,0,68,0,0,0,0,0,0,248,127,11,         # f64 NaN bits
    123,0,253,12]                              # v128
  globals.add @[0'u8,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,11]
  globals.add @[112'u8,0,208,112,11,           # null funcref
    111,0,208,111,11,                          # null externref
    112,0,210,1,11,                            # defined function reference
    127,0,35,0,11,                             # imported immutable global
    127,0,35,3,11]                             # earlier defined immutable global
  result.section(6, globals)
  var exports = @[6'u8]
  for item in [("run",0'u8,1'u8),("t\xc3\xa9",1'u8,0'u8),("ext",1'u8,1'u8),
               ("memory",2'u8,0'u8),("g\0",3'u8,3'u8),("\xf4\x8f\xbf\xbf",3'u8,4'u8)]:
    exports.add name(item[0]) & @[item[1], item[2]]
  result.section(7, exports)
  result.section(8, @[1'u8])
  result.section(0, name("middle") & @[192'u8,0])
  var elements = @[8'u8]
  for flags in 0'u8..7'u8:
    elements.add flags
    if (flags and 1) == 0:
      if (flags and 2) != 0: elements.add(if flags == 6: 1'u8 else: 0'u8)
      elements.add @[65'u8,0,11]
    if (flags and 3) != 0: elements.add(if flags < 4: 0'u8 elif flags in [5'u8,6]: 111'u8 else: 112'u8)
    elements.add 2
    if flags < 4: elements.add @[0'u8,1]
    elif flags in [5'u8,6]: elements.add @[208'u8,111,11,35,1,11]
    else: elements.add @[210'u8,1,11,208,112,11]
  result.section(9, elements)
  result.section(12, @[3'u8])
  result.section(10, @[1'u8,3,0,1,11])
  result.section(11, @[3'u8,0,65,0,11,3,0,255,11,1,0,2,0,35,0,11,2,192,128])
  result.section(0, name("") & @[255'u8])

proc inputs(c: var Circuit, values: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for value in values:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(value.active))),
      address: c.publicInput(scalar(value.address)), value: c.publicInput(scalar(value.value)))

proc build(module: WasmModule, data: seq[byte]): Circuit =
  let envelope = buildBinaryEnvelope(data, 20)
  let payload = buildModulePayloadSource(module, data, envelope)
  let context = buildModuleEnvironment(module)
  let environment = buildTypeEnvironment(module, compressedLocals = true)
  let signatures = buildSignatureEnvironment(module)
  let bulk = buildBulkEnvironment(module)
  result = initCircuit(reuseRangeWitnesses = true)
  let claim = result.allocateBinarySourceClaim(data, 1024)
  let contextW = result.allocateModuleEnvironment(context, publicInputs = true)
  let envW = TypeEnvironmentWires(objects: result.inputs(environment.objects))
  var sigW = SignatureEnvironmentWires(signatures: result.inputs(signatures.signatures))
  for value in signatures.typeIndices: sigW.typeIndices.add result.publicInput(scalar(value))
  let bulkW = BulkEnvironmentWires(elements: result.inputs(bulk.elements))
  var envelopeW = result.allocateBinaryEnvelope(envelope)
  let payloadW = result.allocateModulePayload(payload)
  var source = result.constrainBinarySource(data, 1024, claim)
  result.constrainBinaryEnvelope(source, envelopeW, envelope)
  result.constrainModulePayload(source, envelopeW, payloadW, payload, contextW, context,
    envW, environment, sigW, signatures, bulkW)
  result.finishBinaryReads(source)

proc rejected(module: WasmModule, data: seq[byte]): bool =
  try: not build(module, data).satisfied()
  except ValueError: true

proc main() =
  let bytes = fixture()
  let module = decodeModule(bytes, optimize = false)
  validateModule(module)
  let a = build(module, bytes)
  require(a.satisfied(), "all import kinds, constant kinds, element flags and data modes")
  let secondBytes = fixture(43)
  let secondModule = decodeModule(secondBytes, optimize = false)
  let b = build(secondModule, secondBytes)
  require(b.satisfied() and a.sameShape(b), "payload proof profile is independent of scalar values")
  var mutations = 0
  template forged(change: untyped) =
    block:
      var candidate {.inject.} = decodeModule(bytes, optimize = false)
      change
      try: validateModule(candidate)
      except CatchableError as error:
        raise newException(ValueError, "invalid forgery fixture: " & astToStr(change) & ": " & error.msg)
      require(rejected(candidate, bytes), astToStr(change))
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

  # Defined memory is separate because the runtime admits at most one memory.
  var memory = header()
  memory.section(5, @[1'u8,0,1])
  let memoryModule = decodeModule(memory, optimize = false)
  require(build(memoryModule, memory).satisfied(), "defined memory without maximum")
  var changedMemory = decodeModule(memory, optimize = false)
  changedMemory.memories[0].limits.min = 2
  require(rejected(changedMemory, memory), "defined-memory bound source binding")
  inc mutations
  changedMemory = decodeModule(memory, optimize = false)
  changedMemory.memories[0].limits = Limits(min: 1, max: 3, hasMax: true)
  require(rejected(changedMemory, memory), "defined-memory maximum source binding")
  inc mutations

  # The host parse of the honest metadata is held fixed while a complete,
  # correctly framed but invalid payload is supplied to the relation.
  var malformed = 0
  template badSource(source: seq[byte], metadata: WasmModule) =
    require(rejected(metadata, source), astToStr(source))
    inc malformed
  var trailing = header()
  trailing.section(8, @[0'u8,0])
  badSource(trailing, WasmModule(startFunc: 0, dataCount: -1))
  trailing = header()
  trailing.section(12, @[0'u8,0])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: 0))
  trailing = header()
  trailing.section(0, @[])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: -1,
    customSections: @[(name: "", data: newSeq[byte]())]))
  trailing = header()
  trailing.section(0, @[2'u8,97])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: -1,
    customSections: @[(name: "a", data: newSeq[byte]())]))
  for id in [2'u8,4,5,6,7,9,11]:
    trailing = header()
    trailing.section(id, @[0'u8,0])
    badSource(trailing, WasmModule(startFunc: -1, dataCount: -1))
  trailing = header()
  trailing.section(5, @[1'u8,2,0])
  badSource(trailing, memoryModule)
  trailing = header()
  trailing.section(11, @[1'u8,1,2,0])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: -1,
    datas: @[DataSegment(mode: dataPassive, data: @[0'u8])]))
  trailing = header()
  trailing.section(11, @[1'u8,3,0])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: -1,
    datas: @[DataSegment(mode: dataPassive)]))
  trailing = header()
  trailing.section(9, @[1'u8,8,0])
  badSource(trailing, WasmModule(startFunc: -1, dataCount: -1,
    elements: @[ElemSegment(mode: elemPassive, elemType: vtFuncRef)]))

  # Keep the honest decoded constant fixed while changing its actual source.
  # These exercise the initializer reader itself, including the second SIMD
  # word; rejecting only malformed module metadata would not cover this path.
  var scalarSource = header()
  scalarSource.section(6, @[1'u8,127,0,65,42,11])
  let scalarModule = decodeModule(scalarSource, optimize = false)
  require(build(scalarModule,scalarSource).satisfied(), "scalar source fixture")
  for body in [@[1'u8,127,0,65,42,12], @[1'u8,127,0,66,42,11],
      @[1'u8,127,0,65,43,11], @[1'u8,127,0,65,42,1,11],
      @[1'u8,127,0,65,255,255,255,255,15,11]]:
    var source = header()
    source.section(6,body)
    badSource(source,scalarModule)
  var vectorBody = @[1'u8,123,0,253,12]
  for i in 0..15: vectorBody.add byte(i)
  vectorBody.add 11
  var vectorSource = header()
  vectorSource.section(6,vectorBody)
  let vectorModule = decodeModule(vectorSource, optimize = false)
  require(build(vectorModule,vectorSource).satisfied(), "vector source fixture")
  var changedVector = vectorBody
  changedVector[4] = 11
  var source = header()
  source.section(6,changedVector)
  badSource(source,vectorModule)
  changedVector = vectorBody
  changedVector[20] = 99
  source = header()
  source.section(6,changedVector)
  badSource(source,vectorModule)

  let full = buildModuleValidationCircuit(bytes, 16, 1024, 20)
  require(full.satisfied(), "full payload + instruction + module validation composition")
  let publicInputs = binarySourceInputs(bytes, 1024)
  require(full.publicCount == publicInputs.len, "derived tables/events must remain private")
  for i, value in publicInputs:
    require(value.equals(full.values[i+1]), "verifier-only claim matches source circuit")
  if paramCount() == 0 or paramStr(1) != "--check-only":
    let key = setup(a)
    for circuit in [a,b]:
      let proof = encodeProof(prove(key, circuit))
      require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
        circuit.values[1..circuit.publicCount]), "payload proof round trip")
    # An independent verifier that sees no decoded module or validation trace.
    let small = header()
    let privateCircuit = buildModuleValidationCircuit(small, 1, 32, 1)
    let privateKey = setup(privateCircuit)
    let proof = encodeProof(prove(privateKey, privateCircuit))
    require(verifyModuleValidation(privateKey.verificationKey, small, proof, 32), "source-only verifier")
    var changed = small
    changed[7] = 1
    require(not verifyModuleValidation(privateKey.verificationKey, changed, proof, 32), "changed source rejected")
    require(not verifyModuleValidation(privateKey.verificationKey, small, proof, 31), "changed capacity rejected")
  echo "zkbuild payload source: PASS (all 4 imports; all 8 constant kinds; all 8 element flags; all 3 data modes; ",
    mutations, " coherent forgeries; ", malformed, " malformed payloads; ", a.constraints.len,
    " payload constraints; ", full.constraints.len, " full constraints)"

main()
