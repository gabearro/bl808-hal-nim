## Valid alternate decoded programs must not replace SHA-bound instruction metadata.
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_catch_environment,wasm_declaration_profile,wasm_payload_profile]
import zkbuild_payload_fixture
proc build(module: WasmModule, bytes: seq[byte], flat: bool): Circuit =
  buildModuleValidationCircuit(module,moduleValidationRows(module,64),buildCatchEnvironment(module),
    sourceBytes = bytes,sourceCapacity = 128,sectionCapacity = 8,privateMetadata = true,digestClaim = true,
    instructionCapacity = (if flat: 16 else: 0),branchCapacity = (if flat: 4 else: 0),catchCapacity = (if flat: 4 else: 0),
    declarationProfile = (if flat: DeclarationProfile(enabled: true,types: 3,functions: 2,parameters: 4,results: 6,tags: 2) else: DeclarationProfile()),
    payloadProfile = (if flat: PayloadProfile(enabled: true,memories: 1,datas: 1) else: PayloadProfile()))
proc main() =
  var tested,unsatisfied,unconstructible = 0
  for flat in [false,true]:
    for kind in ["control","branch","catch","values","simd","bulk"]:
      let bytes = instructionStreamFixture(kind)
      let original = decodeModule(bytes,optimize = false)
      validateModule(original)
      doAssert build(original,bytes,flat).satisfied(),kind
      template forged(change: untyped) =
        block:
          var candidate {.inject.} = decodeModule(bytes,optimize = false)
          change
          validateModule(candidate)
          inc tested
          try:
            doAssert not build(candidate,bytes,flat).satisfied(),astToStr(change)
            inc unsatisfied
          except ValueError: inc unconstructible
      case kind
      of "control":
        forged: candidate.codes[0].code.code[0].imm1 = 0
        forged: candidate.codes[0].code.code[2].imm1 = 4
      of "branch":
        forged: candidate.codes[0].code.brTables[0].labels[0] = 1
        forged: candidate.codes[0].code.brTables[0].defaultLabel = 1
      of "catch":
        forged: candidate.codes[0].code.catchTables[0][0].labelDepth = 1
        forged: candidate.codes[0].code.catchTables[0].add candidate.codes[0].code.catchTables[0][0]
      of "values":
        forged: candidate.codes[0].code.code[0].imm1 = 123
        forged: candidate.codes[0].code.code[2].imm2 = 42
        forged: candidate.codes[0].code.code[4].imm1 = 0
        forged: candidate.codes[0].code.code[6].imm2 = 0
      of "simd":
        forged: candidate.codes[0].code.v128Consts[0][0] = 255
        forged: candidate.codes[0].code.v128Consts[0][8] = 255
        forged: candidate.codes[0].code.v128Consts[0][15] = 255
        forged: candidate.codes[0].code.code[1].imm1 = 7
      of "bulk":
        forged: candidate.codes[0].code.code[5].imm1 = 4
        forged: candidate.codes[0].code.code[5].imm2 = 1
      else: discard
  echo "instruction metadata binding: PASS (",tested," valid alternate programs rejected; ",unsatisfied,
    " unsatisfied circuits; ",unconstructible," rejected witness constructions; both representations)"
main()
