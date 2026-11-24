## Experimental full-runtime validation composition over decoded tables/events.
## The raw-byte overload binds all supported sections and keeps derived tables
## and events private. Claims use packed bytes or two SHA-256 limbs.
## Reusable profiles and end-to-end formal refinement remain experimental.
import ../wasm/[types, validate]
import ./[r1cs, range_check, read_only_memory, wasm_operand_events, wasm_control_events,
  wasm_instruction_events, wasm_type_environment, wasm_signature_environment,
  wasm_indexed_signatures, wasm_branch_environment, wasm_memory_metadata, wasm_bulk_context,
  wasm_reference_context, wasm_throw_events, wasm_catch_environment, wasm_catch_validation]
import wasm_module_context
import wasm_local_declarations
import wasm_immediates
import wasm_validation_witness
import wasm_binary_source, wasm_binary_envelope
import wasm_binary_declarations
import wasm_binary_code
import wasm_instruction_source
import wasm_flat_instruction_source
import wasm_payload_source
import wasm_declaration_profile, wasm_payload_profile
import sha256_circuit, wasm_digest_claim

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry], publicInputs: bool): seq[ReadOnlyWires] =
  template input(value: Scalar): Linear =
    if publicInputs: c.publicInput(value) else: c.allocate(value)
  for entry in entries:
    result.add ReadOnlyWires(active: input(scalar(ord(entry.active))),
      address: input(scalar(entry.address)), value: input(scalar(entry.value)))

proc moduleValidationRows*(module: WasmModule, capacity = 0): seq[InstructionEventRow] =
  buildInstructionEventRows(traceModuleValidation(module, labelChecks = true, catchChecks = true), capacity)

proc buildModuleValidationCircuit*(module: WasmModule, rows: seq[InstructionEventRow], catches: CatchEnvironment,
    binding = true, moduleChecks = true, sourceBytes: seq[byte] = @[],
    sourceCapacity = 0, sectionCapacity = 0, privateMetadata = false, digestClaim = false,
    instructionCapacity = 0, branchCapacity = 0, catchCapacity = 0,
    declarationProfile = DeclarationProfile(), payloadProfile = PayloadProfile()): Circuit =
  declarationProfile.validate()
  payloadProfile.validate()
  if payloadProfile.enabled and not declarationProfile.enabled:
    raise newException(ValueError,"payload profiles require a declaration profile")
  if declarationProfile.enabled and (instructionCapacity == 0 or sourceBytes.len == 0):
    raise newException(ValueError,"declaration profiles require the flat source relation")
  if rows.len == 0 or uint64(rows.len) > uint64(high(uint32)) or
      uint64(sourceBytes.len) > uint64(high(uint32)):
    raise newException(ValueError, "module proof profile exceeds the u32 namespace")
  if sourceBytes.len != 0 and (not binding or not moduleChecks):
    raise newException(ValueError, "source headers require the complete module relation")
  if privateMetadata and sourceBytes.len == 0:
    raise newException(ValueError, "private module metadata requires the source-bound relation")
  if digestClaim and not privateMetadata:
    raise newException(ValueError, "digest claims require private source-bound metadata")
  if instructionCapacity < 0 or branchCapacity < 0 or catchCapacity < 0 or
      (instructionCapacity == 0 and (branchCapacity != 0 or catchCapacity != 0)) or
      (instructionCapacity != 0 and sourceBytes.len == 0):
    raise newException(ValueError,"invalid flat instruction profile")
  for capacity in [instructionCapacity,branchCapacity,catchCapacity]:
    if uint64(capacity) > uint64(high(uint32)):
      raise newException(ValueError,"flat instruction profile exceeds u32 namespace")
  var firstFunction = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc firstFunction
  let im = instructionImmediates(module, rows, firstFunction)
  var env = buildTypeEnvironment(module,localCapacity = instructionCapacity,compressedLocals = true,
    maxLocals = (if declarationProfile.enabled: declarationProfile.localRanges else: 1_048_576))
  var sig = buildSignatureEnvironment(module, includeSingletons = true, includeReversals = true,
    maxNodes = (if declarationProfile.enabled: declarationProfile.nodeCapacity() else: 1_048_576))
  if declarationProfile.enabled:
    env.localRanges.padDeclarations(declarationProfile.localRanges)
    env.rangeTypes.padDeclarations(declarationProfile.localRanges)
    let count = uint64(declarationProfile.types)+uint64(declarationProfile.functions)+uint64(if payloadProfile.enabled: payloadProfile.imports else: int(firstFunction))
    if count > uint64(high(int)): raise newException(ValueError,"signature profile size overflow")
    sig.signatures.padDeclarations(int(count))
    sig.typeIndices.padDeclarations(int(count))
    sig.nodes.padDeclarations(declarationProfile.nodeCapacity())
    sig.reversals.padDeclarations(declarationProfile.headCapacity())
  if payloadProfile.enabled:
    env.objects.padDeclarations(payloadProfile.globals+payloadProfile.tables)
  var indexed = buildIndexedSignatures(sig,
    maxMembers = (if declarationProfile.enabled: declarationProfile.memberCapacity() else: 1_048_576))
  if declarationProfile.enabled:
    indexed.lengths.padDeclarations(declarationProfile.headCapacity())
    indexed.members.padDeclarations(declarationProfile.memberCapacity())
  let branches = buildBranchEnvironment(module,bankCapacity = instructionCapacity,nodeCapacity = branchCapacity)
  let sourceCatches = if instructionCapacity == 0: catches
    else: buildCatchEnvironment(module,bankCapacity = instructionCapacity,nodeCapacity = catchCapacity)
  var mem = buildMemoryEnvironment(module)
  if declarationProfile.enabled: mem.vectorCounts.padDeclarations(declarationProfile.functions)
  var bulk = buildBulkEnvironment(module)
  var references = buildReferenceEnvironment(module)
  if payloadProfile.enabled:
    bulk.elements.padDeclarations(payloadProfile.elements)
    references.declarations.padDeclarations(declarationProfile.functions+payloadProfile.imports)
  var tags = buildTagEnvironment(module, sig)
  if declarationProfile.enabled:
    tags.tags.padDeclarations(declarationProfile.tags)
    tags.typeIndices.padDeclarations(declarationProfile.tags)
  let witness = buildCatchValidationWitness(env, sig, indexed, branches, mem, bulk,
    references, tags, sourceCatches, rows, im.p, im.s, im.pads)
  var moduleEnvironment: ModuleEnvironment
  var moduleWitness: ModuleContextWitness
  var localDeclarations: LocalDeclarationEnvironment
  var localWitness: LocalDeclarationWitness
  if moduleChecks:
    moduleEnvironment = buildModuleEnvironment(module,profile = payloadProfile)
    moduleWitness = buildModuleContextWitness(moduleEnvironment, env, sig, references)
    localDeclarations = buildLocalDeclarationEnvironment(module, env)
    if declarationProfile.enabled: localDeclarations.totals.padDeclarations(declarationProfile.functions)
    localWitness = buildLocalDeclarationWitness(localDeclarations, env, sig, indexed)
  result = initCircuit(reuseRangeWitnesses = true)
  let byteCapacity = if sourceCapacity == 0: sourceBytes.len else: sourceCapacity
  var sourceClaim: BinarySourceClaim
  var digestWires: ShaDigestWires
  if digestClaim:
    let digest = wasmDigestInputs(sourceBytes)
    for i in 0..1: digestWires[i] = result.publicInput(digest[i])
  if privateMetadata:
    sourceClaim = result.allocateBinarySourceClaim(sourceBytes, byteCapacity, publicInputs = not digestClaim)
  template metadata(value: Scalar): Linear =
    if privateMetadata: result.allocate(value) else: result.publicInput(value)
  let first = metadata(scalar(firstFunction))
  let envW = TypeEnvironmentWires(locals: result.inputs(env.locals, not privateMetadata), objects: result.inputs(env.objects, not privateMetadata),
    localRanges: result.inputs(env.localRanges, not privateMetadata), rangeTypes: result.inputs(env.rangeTypes, not privateMetadata))
  var sigW: SignatureEnvironmentWires
  for i, entry in sig.signatures:
    sigW.signatures.add ReadOnlyWires(active: metadata(scalar(ord(entry.active))),
      address: metadata(scalar(entry.address)), value: metadata(scalar(entry.value)))
    sigW.typeIndices.add metadata(scalar(sig.typeIndices[i]))
  sigW.nodes = result.inputs(sig.nodes, not privateMetadata)
  let indexW = IndexedSignatureWires(lengths: result.inputs(indexed.lengths, not privateMetadata),
    members: result.inputs(indexed.members, not privateMetadata), singletons: result.inputs(indexed.singletons, not privateMetadata))
  let branchW = BranchEnvironmentWires(banks: result.inputs(branches.banks, not privateMetadata), nodes: result.inputs(branches.nodes, not privateMetadata))
  let memW = MemoryEnvironmentWires(memoryCount: metadata(scalar(mem.memoryCount)), vectorCounts: result.inputs(mem.vectorCounts, not privateMetadata))
  let bulkW = BulkEnvironmentWires(hasDataCount: metadata(scalar(ord(bulk.hasDataCount))),
    dataCount: metadata(scalar(bulk.dataCount)), declaredDataCount: metadata(scalar(bulk.declaredDataCount)),
    elements: result.inputs(bulk.elements, not privateMetadata))
  let refW = ReferenceEnvironmentWires(functionCount: metadata(scalar(references.functionCount)), declarations: result.inputs(references.declarations, not privateMetadata))
  var tagW = TagEnvironmentWires(tags: result.inputs(tags.tags, not privateMetadata))
  for index in tags.typeIndices: tagW.typeIndices.add metadata(scalar(index))
  let catchW = CatchEnvironmentWires(banks: result.inputs(sourceCatches.banks, not privateMetadata), links: result.inputs(sourceCatches.links, not privateMetadata), clauses: result.inputs(sourceCatches.clauses, not privateMetadata))
  let reverseW = result.inputs(sig.reversals, not privateMetadata)
  var wires: seq[InstructionEventWires]
  var primary, secondary, pads: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: metadata(scalar(e.kind)),
      functionIndex: metadata(scalar(e.functionIndex)), height: metadata(scalar(e.height)),
      floor: metadata(scalar(e.floor)), valueType: metadata(scalar(e.valueType)),
      polymorphic: metadata(scalar(ord(e.polymorphic))), unreachable: metadata(scalar(ord(e.unreachable))))
    wires.add InstructionEventWires(control: ControlEventWires(operand: operand,
      depth: metadata(scalar(row.control.depth))), opcode: metadata(scalar(row.opcode)), pc: metadata(scalar(row.pc)))
    primary.add metadata(scalar(im.p[i]))
    secondary.add metadata(scalar(im.s[i]))
    pads.add metadata(scalar(im.pads[i]))
  var moduleWires: ModuleEnvironmentWires
  var localWires: LocalDeclarationWires
  if moduleChecks: moduleWires = result.allocateModuleEnvironment(moduleEnvironment, publicInputs = not privateMetadata)
  if moduleChecks: localWires.totals = result.inputs(localDeclarations.totals, not privateMetadata)
  var envelope: BinaryEnvelope
  var envelopeWires: BinaryEnvelopeWires
  var sourceDeclarations: DeclarationSource
  var declarationWires: DeclarationSourceWires
  var sourceCode: CodeSource
  var sourceInstructions: InstructionSource
  var instructionWires: seq[seq[SourceInstructionWires]]
  var flatInstructions: FlatInstructionSource
  var flatInstructionWires: FlatInstructionWires
  var sourcePayload: ModulePayloadSource
  var payloadWires: ModulePayloadWires
  if sourceBytes.len != 0:
    envelope = buildBinaryEnvelope(sourceBytes, sectionCapacity)
    sourceDeclarations = buildDeclarationSource(module, sourceBytes, envelope,declarationProfile)
    sourceCode = buildCodeSource(module, sourceBytes, envelope,declarationProfile)
    if instructionCapacity == 0:
      sourceInstructions = buildInstructionSource(module, sourceBytes, sourceCode)
    else:
      flatInstructions = buildFlatInstructionSource(module,sourceBytes,sourceCode,
        instructionCapacity,branchCapacity,catchCapacity)
    sourcePayload = buildModulePayloadSource(module, sourceBytes, envelope,payloadProfile)
    if not privateMetadata: sourceClaim = result.allocateBinarySourceClaim(sourceBytes, byteCapacity)
    envelopeWires = result.allocateBinaryEnvelope(envelope)
    declarationWires = result.allocateDeclarationSource(sourceDeclarations)
    if instructionCapacity == 0:
      instructionWires = result.allocateInstructionSource(sourceInstructions)
    else:
      flatInstructionWires = result.allocateFlatInstructionSource(flatInstructions)
    payloadWires = result.allocateModulePayload(sourcePayload)
  when defined(zkbuildValidationEventAudit):
    var trace = ValidationTraceAudit(firstFunction: copyAuditExpressions([first])[0])
    for i,row in wires:
      trace.rows.add copyAuditExpressions([row.control.operand.kind,row.control.operand.functionIndex,
        row.control.operand.height,row.control.operand.floor,row.control.operand.valueType,row.control.operand.polymorphic,
        row.control.operand.unreachable,row.control.depth,row.opcode,row.pc,primary[i],secondary[i],pads[i]])
    result.validationTraceRecords.add trace
  if binding:
    result.constrainCatchValidation(wires, primary, secondary, pads, envW, sigW, indexW, branchW,
      memW, bulkW, refW, tagW, catchW, reverseW, first, witness)
  else:
    discard result.constrainCatchValidationCore(wires, primary, secondary, pads, envW, sigW, indexW, branchW,
      memW, bulkW, refW, tagW, catchW, reverseW, first, witness)
  if moduleChecks:
    result.constrainModuleContext(moduleWires, envW, sigW, memW, bulkW, refW, first, moduleWitness)
    result.constrainLocalDeclarations(localWires, envW, sigW, indexW, first, refW.functionCount, localWitness)
    var validatedBodies = constant(0)
    for row in wires:
      validatedBodies = validatedBodies+result.zeroIndicator(row.control.operand.kind-constant(ord(veFunctionEnd)))
    result.assertEqual(validatedBodies, moduleWires.functions-moduleWires.importedFunctions)
  if sourceBytes.len != 0:
    var source = result.constrainBinarySource(sourceBytes, byteCapacity, sourceClaim)
    result.constrainBinaryEnvelope(source, envelopeWires, envelope)
    let words = envelopeWires.firstWords
    when defined(zkbuildSignatureAudit):
      if result.signatureNamespaceRecords.len != 1:
        raise newException(ValueError,"signature namespace audit requires one module context")
      result.signatureNamespaceRecords[0].typeBindStart = result.constraints.len
    result.assertEqual(words[1], moduleWires.types)
    when defined(zkbuildSignatureAudit): result.signatureNamespaceRecords[0].typeBindEnd = result.constraints.len
    result.assertEqual(words[2], moduleWires.importedFunctions+moduleWires.importedGlobals+
      moduleWires.importedTables+moduleWires.importedMemories)
    when defined(zkbuildSignatureAudit): result.signatureNamespaceRecords[0].functionBindStart = result.constraints.len
    result.assertEqual(words[3], moduleWires.functions-moduleWires.importedFunctions)
    when defined(zkbuildSignatureAudit): result.signatureNamespaceRecords[0].functionBindEnd = result.constraints.len
    result.assertEqual(words[4], moduleWires.tables-moduleWires.importedTables)
    result.assertEqual(words[5], memW.memoryCount-moduleWires.importedMemories)
    result.assertEqual(words[6], moduleWires.globals-moduleWires.importedGlobals)
    var exports, elements, tags = constant(0)
    for row in moduleWires.exports: exports = exports+row.active
    for row in moduleWires.elements: elements = elements+row.active
    for row in tagW.tags: tags = tags+row.active
    result.assertEqual(words[7], exports)
    when defined(zkbuildModuleContextAudit):
      if result.moduleContextRecords.len != 1: raise newException(ValueError,"module context audit requires one context")
      result.moduleContextRecords[0].startBindFirst = result.constraints.len
    result.assertEqual(envelopeWires.present[8], moduleWires.hasStart)
    result.assertEqual(words[8], moduleWires.start)
    when defined(zkbuildModuleContextAudit): result.moduleContextRecords[0].startBindLast = result.constraints.len
    result.assertEqual(words[9], elements)
    result.assertEqual(words[10], moduleWires.functions-moduleWires.importedFunctions)
    result.assertEqual(words[11], bulkW.dataCount)
    when defined(zkbuildRuntimeContextAudit): result.runtimeContextBindingFirst = result.constraints.len
    result.assertEqual(envelopeWires.present[12], bulkW.hasDataCount)
    result.assertEqual(words[12], bulkW.declaredDataCount)
    when defined(zkbuildRuntimeContextAudit): result.runtimeContextBindingLast = result.constraints.len
    result.assertEqual(words[13], tags)
    result.constrainDeclarationSource(source, envelopeWires, declarationWires, sourceDeclarations,
      sigW, sig, indexW, indexed, tagW, first)
    let codeSpans = result.constrainCodeSource(source, envelopeWires, sourceCode, first, envW, env,
      sigW, sig, indexW, indexed, localWires, localDeclarations)
    if instructionCapacity == 0:
      result.constrainInstructionSource(source, codeSpans, instructionWires, sourceInstructions,
        first, branchW, branches, catchW, sourceCatches, memW, mem, wires, rows, primary, secondary, pads)
    else:
      result.constrainFlatInstructionSource(source,codeSpans,flatInstructionWires,flatInstructions,
        first,branchW,branches,catchW,sourceCatches,memW,mem,wires,rows,primary,secondary,pads)
    result.constrainModulePayload(source, envelopeWires, payloadWires, sourcePayload,
      moduleWires, moduleEnvironment, envW, env, sigW, sig, bulkW)
    if digestClaim:
      var byteValues: seq[Linear]
      for entry in source.entries: byteValues.add entry.value
      result.constrainSha256(byteValues,source.length,digestWires)
    result.finishBinaryReads(source)

proc buildModuleValidationCircuit*(module: WasmModule, eventCapacity = 0): Circuit =
  let rows = moduleValidationRows(module, eventCapacity)
  buildModuleValidationCircuit(module, rows, buildCatchEnvironment(module))

proc buildModuleValidationCircuit*(bytes: openArray[byte], eventCapacity = 0,
    sourceCapacity = 0, sectionCapacity = 0, digestClaim = false,
    instructionCapacity = 0, branchCapacity = 0, catchCapacity = 0,
    declarationProfile = DeclarationProfile(), payloadProfile = PayloadProfile()): Circuit =
  ## Decode without peephole optimization and independently replay validation.
  ## Binds every supported section and instruction to the raw source. Custom
  ## and data bytes are opaque payloads with bounded, exact lengths. General
  ## profiles can fix all table dimensions. End-to-end formal refinement is
  ## still a separate obligation; this is not a kernel-admission API.
  let witness = buildFullValidationWitness(bytes, labelChecks = true, catchChecks = true)
  let rows = buildInstructionEventRows(witness.events, eventCapacity)
  buildModuleValidationCircuit(witness.module, rows, buildCatchEnvironment(witness.module),
    sourceBytes = @bytes, sourceCapacity = sourceCapacity, sectionCapacity = sectionCapacity,
    privateMetadata = true, digestClaim = digestClaim,instructionCapacity = instructionCapacity,
    branchCapacity = branchCapacity,catchCapacity = catchCapacity,declarationProfile = declarationProfile,payloadProfile = payloadProfile)
