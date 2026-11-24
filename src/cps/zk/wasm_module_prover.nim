## Off-device general-WASM proving entry points. Full declaration/payload
## profiles fix every metadata dimension; prove checks the complete matrix.
import prover, wasm_module_validation
import wasm_declaration_profile, wasm_payload_profile
import ../wasm/types
import wasm_validation_witness, wasm_binary_envelope, wasm_binary_code
import wasm_instruction_source
export prover
export wasm_declaration_profile, wasm_payload_profile

type ModuleValidationProfile* = object
  eventCapacity*, sourceCapacity*, sectionCapacity*: int
  digestClaim*: bool
  ## Zero preserves the original per-body source layout. A positive budget
  ## selects the flat source stream, including one root end per function.
  ## Auxiliary budgets count all branch labels (including defaults) and all
  ## catch clauses across the module, not a maximum per instruction.
  instructionCapacity*, branchCapacity*, catchCapacity*: int
  declarations*: DeclarationProfile
  payloads*: PayloadProfile

proc moduleCircuit*(bytes: openArray[byte], profile: ModuleValidationProfile): Circuit =
  ## Exact shared builder used by setup, proving, and offline matrix certification.
  if profile.eventCapacity < 0 or profile.sourceCapacity < 8 or profile.sectionCapacity < 0:
    raise newException(ValueError, "invalid module validation profile")
  if profile.instructionCapacity > 0 and (profile.eventCapacity == 0 or profile.sectionCapacity == 0):
    raise newException(ValueError,"flat proving profiles require fixed event and section capacities")
  buildModuleValidationCircuit(bytes, profile.eventCapacity, profile.sourceCapacity,
    profile.sectionCapacity, profile.digestClaim,profile.instructionCapacity,
    profile.branchCapacity,profile.catchCapacity,profile.declarations,profile.payloads)

proc setupModuleValidation*(bytes: openArray[byte], profile: ModuleValidationProfile): ProvingKey =
  let circuit = moduleCircuit(bytes, profile)
  if not circuit.satisfied(): raise newException(ValueError, "unsatisfied module validation relation")
  setup(circuit)

proc proveModuleValidation*(key: ProvingKey, bytes: openArray[byte],
    profile: ModuleValidationProfile): seq[byte] =
  let circuit = moduleCircuit(bytes, profile)
  # prove checks the complete matrix, public/private split and all assignments.
  let encoded = encodeProof(prove(key, circuit))
  @encoded

proc inferModuleValidationProfile*(bytes: openArray[byte]): ModuleValidationProfile =
  ## Exact-fit starting point. Increase budgets before setup to share a key
  ## with other modules; zero payload/declaration budgets remain exact zero.
  let witness = buildFullValidationWitness(bytes,labelChecks = true,catchChecks = true)
  let module = witness.module
  result.digestClaim = true
  result.sourceCapacity = bytes.len
  let envelope = buildBinaryEnvelope(bytes)
  result.sectionCapacity = max(1,envelope.sections.len)
  result.eventCapacity = max(1,moduleValidationRows(module).len)
  result.instructionCapacity = 1
  var instructions = 0
  let code = buildCodeSource(module,bytes,envelope)
  let source = buildInstructionSource(module,bytes,code)
  for body in source.bodies:
    instructions += body.len
    for row in body:
      result.branchCapacity += row.labels.len
      result.catchCapacity += row.catches.len
  result.instructionCapacity = max(1,instructions)
  result.declarations = DeclarationProfile(enabled: true,types: module.types.len,
    functions: module.codes.len,tags: module.tagDefs.len)
  for signature in module.types:
    result.declarations.parameters += signature.params.len
    result.declarations.results += signature.results.len
  for i, body in module.codes:
    result.declarations.localGroups += body.locals.len
    result.declarations.localRanges += body.locals.len+module.types[int(module.funcTypeIdxs[i])].params.len
  result.payloads = PayloadProfile(enabled: true,imports: module.imports.len,
    globals: module.globals.len,tables: module.tables.len,memories: module.memories.len,
    exports: module.exports.len,elements: module.elements.len,datas: module.datas.len,
    customSections: module.customSections.len)
  for item in module.imports:
    result.payloads.nameBytes += item.module.len+item.name.len
    case item.kind
    of ikGlobal: inc result.payloads.globals
    of ikTable: inc result.payloads.tables
    of ikMemory: inc result.payloads.memories
    else: discard
  for item in module.exports: result.payloads.nameBytes += item.name.len
  for item in module.customSections: result.payloads.nameBytes += item.name.len
  for item in module.elements: result.payloads.elementItems += item.init.len
  result.declarations.validate()
  result.payloads.validate()
