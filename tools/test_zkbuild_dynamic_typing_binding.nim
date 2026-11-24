## Coherent decoded type substitutions must disagree with the committed bytes.
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_catch_environment,wasm_declaration_profile,wasm_payload_profile]
import zkbuild_payload_fixture
proc build(module: WasmModule,bytes: seq[byte],flat: bool): Circuit =
  buildModuleValidationCircuit(module,moduleValidationRows(module,128),buildCatchEnvironment(module),
    sourceBytes = bytes,sourceCapacity = 128,sectionCapacity = 8,privateMetadata = true,digestClaim = true,
    instructionCapacity = (if flat: 32 else: 0),
    declarationProfile = (if flat: DeclarationProfile(enabled: true,types: 2,functions: 2,parameters: 2,
      results: 4,localGroups: 1,localRanges: 4) else: DeclarationProfile()),
    payloadProfile = (if flat: PayloadProfile(enabled: true,tables: 1,globals: 1) else: PayloadProfile()))
proc main() =
  var tested,unsatisfied,unconstructible,controls = 0
  for flat in [false,true]:
    for kind in ["local","global","table","direct","indirect","tail-direct","tail-indirect","multi"]:
      let bytes = dynamicTypingFixture(kind)
      let original = decodeModule(bytes,optimize = false)
      validateModule(original)
      doAssert build(original,bytes,flat).satisfied(),kind
      inc controls
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
      of "local":
        forged: candidate.codes[0].locals[0].count = 2
      of "global":
        forged:
          candidate.globals[0].globalType.valType = vtI32
          candidate.globals[0].init.code[0].op = opI32Const
          candidate.codes[0].code.code[0].op = opI32Const
      of "table":
        forged:
          candidate.tables[0].elemType = vtExternRef
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opRefNull: instruction.imm1 = uint32(ord(vtExternRef))
      of "direct","indirect","tail-direct","tail-indirect":
        forged:
          candidate.types[1].params[0] = vtF32
          candidate.codes[0].code.code[0].op = opF32Const
        forged:
          candidate.types[0].results[0] = vtI64
          candidate.types[1].results[0] = vtI64
          candidate.codes[1].code.code[2].op = opI64Const
      of "multi":
        forged:
          candidate.types[1].params[0] = vtF64
          candidate.codes[0].code.code[0].op = opF64Const
        forged:
          candidate.types[0].results[0] = vtI64
          candidate.types[1].results[0] = vtI64
          candidate.codes[1].code.code[4].op = opI64Const
      else: discard
  echo "dynamic typing binding: PASS (",controls," valid controls; ",tested,
    " coherent alternate modules rejected; ",unsatisfied," unsatisfied; ",unconstructible," witness rejections)"
main()
