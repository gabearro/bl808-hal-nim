## Independently valid decoded modules must remain bound to their original bytes.
import cps/wasm/[types,binary,validate]
import cps/zk/[r1cs,wasm_module_validation,wasm_catch_environment,wasm_declaration_profile,wasm_payload_profile]
import zkbuild_payload_fixture
proc build(module: WasmModule,bytes: seq[byte],flat: bool): Circuit =
  buildModuleValidationCircuit(module,moduleValidationRows(module,128),buildCatchEnvironment(module),
    sourceBytes = bytes,sourceCapacity = 256,sectionCapacity = 10,privateMetadata = true,digestClaim = true,
    instructionCapacity = (if flat: 40 else: 0),
    declarationProfile = (if flat: DeclarationProfile(enabled: true,types: 1,functions: 1) else: DeclarationProfile()),
    payloadProfile = (if flat: PayloadProfile(enabled: true,memories: 1,tables: 2,elements: 1,elementItems: 1,
      datas: 1,exports: 1,nameBytes: 2) else: PayloadProfile()))
proc main() =
  var tested,unsatisfied,unconstructible,controls = 0
  for flat in [false,true]:
    for kind in ["memory","bulk","reference","lanes"]:
      let bytes = runtimeContextFixture(kind)
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
      of "memory":
        forged: candidate.memories[0].limits.min = 2
        forged:
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opI32Load: instruction.imm2 = 1
        forged:
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opV128Load: instruction.imm1 = 3
      of "bulk":
        forged:
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opTableInit: instruction.imm2 = 0
        forged:
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opTableCopy:
              instruction.imm1 = 0
              instruction.imm2 = 1
        forged: candidate.elements[0].mode = elemDeclarative
      of "reference":
        forged: candidate.exports[0].name = "g"
        forged:
          candidate.tables[0].elemType = vtExternRef
      of "lanes":
        forged:
          for instruction in candidate.codes[0].code.code.mitems:
            if instruction.op == opI8x16ExtractLaneS: instruction.imm1 = 1
        forged: candidate.codes[0].code.v128Consts[0][15] = 255
      else: discard
  echo "runtime context substitution: PASS (",controls," valid controls; ",tested,
    " valid alternate modules rejected; ",unsatisfied," unsatisfied; ",unconstructible," witness rejections)"
main()
