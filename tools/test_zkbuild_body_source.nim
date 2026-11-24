## Independently valid decoded modules cannot substitute different body/locals
## metadata for the source binary committed by the circuit.
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_catch_environment,wasm_declaration_profile,wasm_payload_profile]
import zkbuild_payload_fixture

proc build(module: WasmModule, bytes: seq[byte], flat: bool): Circuit =
  let rows = moduleValidationRows(module,32)
  if flat:
    buildModuleValidationCircuit(module,rows,buildCatchEnvironment(module),
      sourceBytes = bytes,sourceCapacity = 64,sectionCapacity = 5,privateMetadata = true,digestClaim = true,
      instructionCapacity = 4,
      declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,
        parameters: 8,results: 1,localGroups: 6,localRanges: 16),
      payloadProfile = PayloadProfile(enabled: true))
  else:
    buildModuleValidationCircuit(module,rows,buildCatchEnvironment(module),
      sourceBytes = bytes,sourceCapacity = 64,sectionCapacity = 5,privateMetadata = true,digestClaim = true)
proc main() =
  let bytes = bodySourceFixture()
  var tested,unsatisfied,unconstructible = 0
  for flat in [false,true]:
    let original = decodeModule(bytes,optimize = false)
    validateModule(original)
    doAssert build(original,bytes,flat).satisfied()
    template forged(change: untyped) =
      block:
        var candidate {.inject.} = decodeModule(bytes,optimize = false)
        change
        validateModule(candidate) # A valid alternate module, not a parser error.
        inc tested
        try:
          doAssert not build(candidate,bytes,flat).satisfied(),astToStr(change)
          inc unsatisfied
        except ValueError:
          inc unconstructible
    forged: candidate.codes[0].locals[0].count = 1
    forged: candidate.codes[0].locals[1].count = 6
    forged: candidate.codes[0].locals[2].count = 1
    forged: candidate.codes[0].locals[3].count = 3
    forged: candidate.codes[0].locals[1].valType = vtF64
    forged: candidate.codes[0].locals[3].valType = vtI32
    forged: candidate.codes[0].locals.delete(0)
    forged: candidate.codes[0].locals.insert(LocalDecl(count: 0,valType: vtI32),0)
    forged: swap(candidate.codes[0].locals[0],candidate.codes[0].locals[2])
    forged: candidate.codes[0].code.code[0].imm1 = 12
    forged: candidate.codes[0].code.code.add Instr(op: opNop)
    forged: candidate.codes[0].code.code.setLen(0)
    forged: swap(candidate.types[0].params[0],candidate.types[0].params[1])
  echo "body source binding: PASS (",tested," valid metadata substitutions rejected; ",unsatisfied,
    " unsatisfied circuits; ",unconstructible," rejected witness constructions; both representations)"
main()
