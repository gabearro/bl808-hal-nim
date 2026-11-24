import std/os
import cps/wasm/[types,binary,opcode_encoding]
import cps/zk/[r1cs,prover,read_only_memory,wasm_binary_source,wasm_binary_envelope,
  wasm_binary_code,wasm_instruction_source,wasm_flat_instruction_source,
  wasm_branch_environment,wasm_catch_environment,wasm_memory_metadata]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

proc leb(value: uint32): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc expression(code: uint16): seq[byte] =
  if code == 11: return @[11'u8]
  if code == 5: return @[4'u8,64,5,11,11]
  let encoding = opcodeEncoding(code)
  result.add encoding.prefix
  if encoding.prefixed: result.add leb(encoding.subopcode)
  case encoding.form
  of efNone: discard
  of efU32: result.add leb(128)
  of efPair: result.add @[1'u8,2]
  of efBlock: result.add 64
  of efBranchTable: result.add @[2'u8,0,1,2]
  of efTryTable: result.add @[64'u8,4,0,0,0,1,1,1,2,2,3,3]
  of efTypedSelect: result.add @[1'u8,126]
  of efS32, efS64: result.add 42
  of efLittle32: result.add @[1'u8,2,3,4]
  of efLittle64: result.add @[1'u8,2,3,4,5,6,7,8]
  of efReferenceType: result.add 111
  of efLane: result.add 0
  of efVector16:
    for value in 0..15: result.add byte(value)
  if encoding.form in {efBlock,efTryTable}: result.add 11
  result.add 11

proc moduleBytes(code: seq[byte]): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,10]
  let body = @[0'u8] & code
  let section = @[1'u8] & leb(uint32(body.len)) & body
  result.add leb(uint32(section.len))
  result.add section

proc inputs(c: var Circuit, values: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for value in values:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(value.active))),
      address: c.publicInput(scalar(value.address)),value: c.publicInput(scalar(value.value)))

proc build(module: WasmModule, data: seq[byte], change: proc(value: var FlatInstructionSource) {.closure.} = nil): Circuit =
  let envelope = buildBinaryEnvelope(data)
  let code = buildCodeSource(module,data,envelope)
  var flat = buildFlatInstructionSource(module,data,code,8,8,8)
  if change != nil: change(flat)
  let branches = buildBranchEnvironment(module,8,8)
  let catches = buildCatchEnvironment(module,8,8)
  let memory = buildMemoryEnvironment(module)
  result = initCircuit(reuseRangeWitnesses = true)
  let claim = result.allocateBinarySourceClaim(data,128)
  let branchW = BranchEnvironmentWires(banks: result.inputs(branches.banks),nodes: result.inputs(branches.nodes))
  let catchW = CatchEnvironmentWires(banks: result.inputs(catches.banks),links: result.inputs(catches.links),clauses: result.inputs(catches.clauses))
  let memoryW = MemoryEnvironmentWires(vectorCounts: result.inputs(memory.vectorCounts))
  var spans: CodeSpans
  for i, body in code.bodies:
    spans.instructions.add ReadOnlyWires(active: result.publicInput(scalar(1)),address: result.publicInput(scalar(i)),
      value: result.publicInput(scalar(uint64(body.instructions)+(uint64(body.finish) shl 32))))
  var source = result.constrainBinarySource(data,128,claim)
  let wires = result.allocateFlatInstructionSource(flat)
  result.constrainFlatInstructionSource(source,spans,wires,flat,constant(0),branchW,branches,
    catchW,catches,memoryW,memory,[],[],[],[],[])
  result.finishBinaryReads(source)

proc main() =
  var count: int
  var common: Circuit
  if paramCount() == 0 or paramStr(1) != "--mutations-only":
    for number in 0..65535:
      let code = uint16(number)
      if not opcodeEncoding(code).present: continue
      let bytes = moduleBytes(expression(code))
      let circuit = build(decodeModule(bytes,optimize = false),bytes)
      require(circuit.satisfied(),"flat opcode " & $code)
      if count == 0: common = circuit
      else: require(circuit.sameShape(common),"flat source matrix changed for opcode " & $code)
      inc count
    for index in [65536'u32,high(uint32)]:
      let bytes = moduleBytes(@[2'u8] & leb(index) & @[11'u8,11])
      let circuit = build(decodeModule(bytes,optimize = false),bytes)
      require(circuit.satisfied() and circuit.sameShape(common),"flat full-u32 block index")
      inc count
  var mutations = 0
  template forged(op: uint16, change: untyped) =
    block:
      let bytes = moduleBytes(expression(op))
      var module {.inject.} = decodeModule(bytes,optimize = false)
      change
      require(not build(module,bytes).satisfied(),astToStr(change))
      inc mutations
  forged(0x41): module.codes[0].code.code[0].imm1 += 1
  forged(0x44): module.codes[0].code.code[0].imm2 += 1
  forged(0x6a): module.codes[0].code.code[0].op = opI32Sub
  forged(2): module.codes[0].code.code[0].imm1 = 0
  forged(14): module.codes[0].code.brTables[0].defaultLabel = 3
  forged(31): module.codes[0].code.catchTables[0][0].tagIdx = 1
  forged(1): module.codes[0].code.code.setLen(0)
  forged(14): module.codes[0].code.brTables.add module.codes[0].code.brTables[0]
  forged(31): module.codes[0].code.catchTables.add module.codes[0].code.catchTables[0]
  template badFlat(op: uint16, change: untyped) =
    block:
      let bytes = moduleBytes(expression(op))
      let module = decodeModule(bytes,optimize = false)
      let altered = build(module,bytes,proc(flat {.inject.}: var FlatInstructionSource) = change)
      require(not altered.satisfied(),astToStr(change))
      inc mutations
  badFlat(14): flat.labels[1].ordinal = 0
  badFlat(14): flat.labels[2] = default(FlatAuxRow)
  badFlat(14): flat.labels[0].owner = 1
  badFlat(14): inc flat.labels[1].position
  badFlat(14): flat.labels[0].node = flat.labels[1].node
  badFlat(31): flat.catches[3] = default(FlatAuxRow)
  badFlat(31): flat.catches[1].ordinal = 0
  badFlat(31): inc flat.catches[1].position
  badFlat(1): flat.rows[1] = default(FlatSourceRow)
  badFlat(1): inc flat.functions[0].pc
  badFlat(14): inc flat.functions[0].branches
  badFlat(31): inc flat.functions[0].catches
  if paramCount() == 1 and paramStr(1) in ["--check-only","--mutations-only"]:
    if count == 0: echo "zkbuild flat source mutations: PASS (",mutations," forgeries)"
    else: echo "zkbuild flat source: PASS (",count," layouts share one matrix; ",mutations," forgeries; ",common.constraints.len," constraints)"
    return
  let aBytes = moduleBytes(@[1'u8,11])
  let bBytes = moduleBytes(@[2'u8,64,65,1,14,1,0,0,11,11])
  let a = build(decodeModule(aBytes,optimize = false),aBytes)
  let b = build(decodeModule(bBytes,optimize = false),bBytes)
  require(a.sameShape(b),"different body and branch arity share key")
  let key = setup(a)
  for circuit in [a,b]:
    let proof = encodeProof(prove(key,circuit))
    require(decodeAndVerify(key.verificationKey,proof,circuit.values[1..circuit.publicCount]),"flat source proof")
  echo "zkbuild flat source proofs: PASS (two 192-byte proofs with one key)"

main()
