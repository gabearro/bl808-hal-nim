## Adversarial witnesses for the shared local-declaration stream. The queried
## environment is held fixed; whole-module tests also validate that environment.
import cps/wasm/binary
import cps/zk/[r1cs,read_only_memory,wasm_declaration_profile,wasm_binary_source,
  wasm_binary_envelope,wasm_binary_code,wasm_type_environment,wasm_signature_environment,
  wasm_indexed_signatures,wasm_local_declarations]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

let data = @[0'u8,97,115,109,1,0,0,0,
  1,9,2,96,2,127,111,0,96,0,0,
  3,3,2,0,1,
  10,13,2,6,2,0,123,2,126,11,4,1,1,125,11]
let profile = DeclarationProfile(enabled: true,types: 2,functions: 3,parameters: 2,
  results: 0,localGroups: 6,localRanges: 8,tags: 0)

proc wires(c: var Circuit, values: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for row in values:
    result.add ReadOnlyWires(active: c.allocate(scalar(ord(row.active))),
      address: c.allocate(scalar(row.address)),value: c.allocate(scalar(row.value)))

proc build(change: proc(code: var CodeSource) {.closure.} = nil): Circuit =
  let module = decodeModule(data,optimize = false)
  var environment = buildTypeEnvironment(module,compressedLocals = true)
  environment.localRanges.padDeclarations(profile.localRanges)
  environment.rangeTypes.padDeclarations(profile.localRanges)
  var signatures = buildSignatureEnvironment(module,includeSingletons = true,includeReversals = true)
  signatures.signatures.padDeclarations(profile.types+profile.functions)
  signatures.typeIndices.padDeclarations(profile.types+profile.functions)
  signatures.nodes.padDeclarations(profile.nodeCapacity())
  signatures.reversals.padDeclarations(profile.headCapacity())
  var indexed = buildIndexedSignatures(signatures)
  indexed.lengths.padDeclarations(profile.headCapacity())
  indexed.members.padDeclarations(profile.memberCapacity())
  let totals = buildLocalDeclarationEnvironment(module,environment,profile.functions)
  let envelope = buildBinaryEnvelope(data,5)
  var code = buildCodeSource(module,data,envelope,profile)
  if change != nil: change(code)
  result = initCircuit(reuseRangeWitnesses = true)
  let claim = result.allocateBinarySourceClaim(data,64)
  let envW = TypeEnvironmentWires(localRanges: result.wires(environment.localRanges),rangeTypes: result.wires(environment.rangeTypes))
  let sigW = SignatureEnvironmentWires(signatures: result.wires(signatures.signatures))
  let indexW = IndexedSignatureWires(lengths: result.wires(indexed.lengths))
  let localW = LocalDeclarationWires(totals: result.wires(totals.totals))
  var envelopeW = result.allocateBinaryEnvelope(envelope)
  var source = result.constrainBinarySource(data,64,claim)
  result.constrainBinaryEnvelope(source,envelopeW,envelope)
  discard result.constrainCodeSource(source,envelopeW,code,constant(0),envW,environment,
    sigW,signatures,indexW,indexed,localW,totals)
  result.finishBinaryReads(source)

require(build().satisfied(),"padded local groups and bodies")
var failures: int
template invalid(change: untyped) =
  block:
    let circuit = build(proc(code {.inject.}: var CodeSource) = change)
    require(not circuit.satisfied(),astToStr(change))
    inc failures
invalid: code.locals[0] = default(FlatSourceLocal)
invalid: code.locals[1].ordinal = 0
invalid: code.locals[0].owner = 1
invalid: inc code.locals[1].local.count
invalid: code.locals[0].local.tag = 0
invalid: inc code.locals[1].local.countRead.position
invalid: code.bodies[1] = default(SourceBody)
invalid: inc code.bodies[0].instructions
echo "zkbuild flat locals: PASS (zero-sized group, parameters, padded bodies; ",failures," malformed witnesses)"
