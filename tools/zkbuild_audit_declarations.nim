## Complete declaration binding evidence for ordinary and padded modules.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,range_check,gadget_audit,readonly_audit,read_only_memory,
  wasm_module_validation,wasm_module_prover]

when defined(zkbuildEnvelopeAudit):
  import cps/zk/module_tables_audit
when defined(zkbuildDeclarationAudit):
  import cps/zk/declaration_audit
when defined(zkbuildIndexedAudit):
  import cps/zk/indexed_audit
when defined(zkbuildSignatureAudit):
  import cps/zk/signature_audit
when defined(zkbuildImportAudit):
  import cps/zk/import_audit
when defined(zkbuildOwnedAudit):
  import cps/zk/owned_audit
when defined(zkbuildNameFrameAudit):
  import cps/zk/name_frame_audit
when defined(zkbuildNameGraphAudit):
  import cps/zk/name_graph_audit
when defined(zkbuildNameSourceAudit):
  import cps/zk/name_source_audit
when defined(zkbuildConstantSourceAudit):
  import cps/zk/constant_source_audit
when defined(zkbuildRuntimeContextAudit):
  import cps/zk/runtime_context_audit
when defined(zkbuildStructuredControlAudit):
  import cps/zk/structured_control_audit
when defined(zkbuildDynamicTypingAudit):
  import cps/zk/dynamic_typing_audit
when defined(zkbuildValidationEventAudit):
  import cps/zk/validation_event_audit
when defined(zkbuildInstructionSourceAudit):
  import cps/zk/instruction_source_audit
when defined(zkbuildBodySourceAudit):
  import cps/zk/body_source_audit
when defined(zkbuildModuleContextAudit):
  import cps/zk/module_context_audit

when defined(zkbuildSegmentPayloadAudit):
  import cps/zk/segment_payload_audit

when defined(zkbuildScalarPayloadAudit):
  import cps/zk/scalar_payload_audit

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_declarations MODE META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode == "module": buildModuleValidationCircuit(fixture(),eventCapacity = 16,sourceCapacity = 64,
      sectionCapacity = 6,digestClaim = true,instructionCapacity = 3,
      declarationProfile = DeclarationProfile(enabled: true,types: 1,functions: 1,results: 1),
      payloadProfile = PayloadProfile(enabled: true,imports: 1,globals: 1,exports: 1,
        customSections: 1,nameBytes: 8))
    elif mode.startsWith("context-"):
      buildModuleValidationCircuit(runtimeContextFixture(mode[8..^1]),eventCapacity = 128,sourceCapacity = 256,
        sectionCapacity = 10,digestClaim = true,instructionCapacity = 40,branchCapacity = 0,catchCapacity = 0,
        declarationProfile = DeclarationProfile(enabled: true,types: 1,functions: 1),
        payloadProfile = PayloadProfile(enabled: true,memories: 1,tables: 2,elements: 1,elementItems: 1,
          datas: 1,exports: 1,nameBytes: 2))
    elif mode.startsWith("typing-"):
      buildModuleValidationCircuit(dynamicTypingFixture(mode[7..^1]),eventCapacity = (if mode == "typing-table": 128 else: 64),sourceCapacity = 128,
        sectionCapacity = 8,digestClaim = true,instructionCapacity = (if mode == "typing-table": 32 else: 16),branchCapacity = 0,catchCapacity = 0,
        declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,parameters: 2,
          results: 4,localGroups: 1,localRanges: 4),
        payloadProfile = PayloadProfile(enabled: true,tables: 1,globals: 1))
    elif mode.startsWith("instructions-"):
      block:
        let legacy = mode.endsWith("-legacy")
        let kind = mode[13..^(if legacy: 8 else: 1)]
        let data = instructionStreamFixture(kind)
        buildModuleValidationCircuit(data,eventCapacity = 64,sourceCapacity = 128,
          sectionCapacity = 8,digestClaim = true,instructionCapacity = (if legacy: 0 else: 16),
          branchCapacity = (if legacy: 0 else: 4),catchCapacity = (if legacy: 0 else: 4),
          declarationProfile = (if legacy: DeclarationProfile() else:
            DeclarationProfile(enabled: true,types: (if kind == "catch-ref": 3 else: 2),functions: 2,parameters: 2,
              results: (if kind == "catch-ref": 4 else: 2),tags: ord(kind in ["catch","catch-ref","catch-all-ref"]))),
          payloadProfile = (if legacy: PayloadProfile() else: PayloadProfile(enabled: true,memories: 1,datas: 1)))
    elif mode == "body-legacy":
      buildModuleValidationCircuit(fixture(),eventCapacity = 16,sourceCapacity = 64,
        sectionCapacity = 6,digestClaim = true)
    elif mode in ["body-locals","body-locals-nonminimal","body-locals-big","body-locals-legacy","body-locals-big-legacy"]:
      block:
        let data = bodySourceFixture("big" in mode,"nonminimal" in mode)
        if "legacy" in mode:
          buildModuleValidationCircuit(data,eventCapacity = 32,sourceCapacity = 128,
            sectionCapacity = 5,digestClaim = true)
        else:
          buildModuleValidationCircuit(data,eventCapacity = 32,sourceCapacity = 128,
            sectionCapacity = 5,digestClaim = true,instructionCapacity = 4,
            declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,
              parameters: 8,results: 1,localGroups: 6,localRanges: 16),
            payloadProfile = PayloadProfile(enabled: true))
    elif mode in ["segments","segments-legacy"]:
      buildModuleValidationCircuit(segmentPayloadFixture(),eventCapacity = 8,sourceCapacity = 256,
        sectionCapacity = 10,digestClaim = true,instructionCapacity = 1,
        declarationProfile = DeclarationProfile(enabled: true,types: 1),
        payloadProfile = (if mode == "segments": PayloadProfile(enabled: true,imports: 2,tables: 2,
          memories: 2,elements: 10,elementItems: 12,datas: 4,customSections: 3,nameBytes: 8) else: PayloadProfile()))
    elif mode in ["scalar","scalar-nonminimal"]:
      block:
        let data = scalarPayloadFixture(mode == "scalar-nonminimal")
        buildModuleValidationCircuit(data,eventCapacity = 8,sourceCapacity = 128,sectionCapacity = 6,
          digestClaim = true,instructionCapacity = 1,
          declarationProfile = DeclarationProfile(enabled: true),
          payloadProfile = PayloadProfile(enabled: true,tables: 3,memories: 2,globals: 3,exports: 5,nameBytes: 8))
    elif mode.startsWith("constant-"):
      block:
        var data = @[0'u8,97,115,109,1,0,0,0]
        var valueType = 127'u8
        var expression: seq[byte]
        case mode
        of "constant-i32": expression = @[0x41'u8,0xff,0xff,0xff,0xff,0x7f]
        of "constant-i64":
          valueType = 126
          expression = @[0x42'u8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x7f]
        of "constant-f32": valueType = 125; expression = @[0x43'u8,0,0,0xc0,0x7f]
        of "constant-f64": valueType = 124; expression = @[0x44'u8,0,0,0,0,0,0,0xf8,0x7f]
        of "constant-v128":
          valueType = 123; expression = @[0xfd'u8,0x8c,0]
          for i in 0..15: expression.add byte(i)
        of "constant-null-func": valueType = 112; expression = @[0xd0'u8,0x70]
        of "constant-null-extern": valueType = 111; expression = @[0xd0'u8,0x6f]
        of "constant-global":
          data.add @[2'u8,8,1,1,104,1,103,3,127,0]
          expression = @[0x23'u8,0]
        of "constant-function","constant-legacy":
          data.add @[1'u8,4,1,96,0,0,2,7,1,1,104,1,102,0,0]
          valueType = 112; expression = @[0xd2'u8,0]
        else: raise newException(ValueError,"unknown constant audit mode")
        if mode == "constant-legacy": data.add @[9'u8,5,1,1,0,1,0]
        else:
          let body = @[1'u8,valueType,0] & expression & @[0x0b'u8]
          data.add @[6'u8,byte(body.len)]
          data.add body
        buildModuleValidationCircuit(data,eventCapacity = 8,sourceCapacity = 128,sectionCapacity = 5,
          digestClaim = true,instructionCapacity = 1,
          declarationProfile = DeclarationProfile(enabled: true,types: 1),
          payloadProfile = PayloadProfile(enabled: true,imports: 1,globals: 2,elements: 1,elementItems: 1,nameBytes: 4))
    elif mode == "legacy": buildModuleValidationCircuit(fixture(),eventCapacity = 16,sourceCapacity = 64,
      sectionCapacity = 6,digestClaim = true,instructionCapacity = 3,
      declarationProfile = DeclarationProfile(enabled: true,types: 1,functions: 1,results: 1))
    elif mode in ["name-empty","name-unicode","name-long","name-nonminimal","bad-name-overlong","bad-name-surrogate","bad-name-high","bad-name-truncated","bad-name-continuation","bad-name-length","bad-name-uleb-overflow"]:
      block:
        var name = if mode == "name-empty": newSeq[byte]()
          elif mode == "name-unicode": @[0x24'u8,0xc2,0xa2,0xe2,0x82,0xac,0xf0,0x90,0x8d,0x88]
          elif mode == "name-long": newSeq[byte](130)
          elif mode == "bad-name-overlong": @[0xc0'u8,0x80]
          elif mode == "bad-name-surrogate": @[0xed'u8,0xa0,0x80]
          elif mode == "bad-name-high": @[0xf4'u8,0x90,0x80,0x80]
          elif mode == "bad-name-truncated": @[0xe0'u8,0xa0]
          elif mode == "bad-name-continuation": @[0x80'u8]
          else: @[0x78'u8]
        if mode == "name-long":
          for b in name.mitems: b = 97'u8
        var body: seq[byte]
        if mode == "bad-name-length": body.add 2'u8
        elif mode == "bad-name-uleb-overflow": body.add @[0x81'u8,0x80,0x80,0x80,0x10]
        elif mode == "name-nonminimal": body.add @[0x81'u8,0x00]
        elif name.len >= 128: body.add @[byte((name.len and 127) or 128),byte(name.len shr 7)]
        else: body.add byte(name.len)
        body.add name
        var data = @[0'u8,97,115,109,1,0,0,0,0]
        if body.len >= 128: data.add @[byte((body.len and 127) or 128),byte(body.len shr 7)]
        else: data.add byte(body.len)
        data.add body
        buildModuleValidationCircuit(data,eventCapacity = 8,sourceCapacity = 256,sectionCapacity = 2,
          digestClaim = true,instructionCapacity = 1,
          declarationProfile = DeclarationProfile(enabled: true),
          payloadProfile = PayloadProfile(enabled: true,customSections: 2,nameBytes: 144))
    elif mode in ["full","full-legacy"]: buildModuleValidationCircuit(fullPayloadFixture(),eventCapacity = 16,
      sourceCapacity = 1024,sectionCapacity = 20,digestClaim = true,instructionCapacity = 8,
      branchCapacity = 2,catchCapacity = 2,
      declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,
        parameters: 2,results: 2,tags: 1,localGroups: 2,localRanges: 4),
      payloadProfile = (if mode == "full": PayloadProfile(enabled: true,imports: 6,globals: 13,tables: 3,
        memories: 1,exports: 6,elements: 8,elementItems: 16,datas: 3,
        customSections: 3,nameBytes: 80) else: PayloadProfile()))
    elif mode == "padded": buildModuleValidationCircuit(fixture(),eventCapacity = 32,sourceCapacity = 128,
      sectionCapacity = 10,digestClaim = true,instructionCapacity = 8,
      declarationProfile = DeclarationProfile(enabled: true,types: 3,functions: 3,parameters: 5,results: 5,tags: 2,localGroups: 2,localRanges: 4),
      payloadProfile = PayloadProfile(enabled: true,imports: 3,globals: 3,exports: 3,customSections: 3,nameBytes: 20))
    elif mode in ["imports","imports-nonminimal"]:
      block:
        var data = @[0'u8,97,115,109,1,0,0,0,1,11,2,96,0,0,96,2,127,126,2,127,126]
        var imports = @[6'u8,1,120,1,97,0]
        if mode == "imports": imports.add 1'u8
        else: imports.add @[129'u8,0]
        imports.add @[1'u8,120,1,98,3,127,0,1,120,1,99,1,112,0,0,
          1,120,1,100,0,0,1,120,1,101,2,0,0,1,120,1,102,0,1]
        data.add @[2'u8,byte(imports.len)]
        data.add imports
        buildModuleValidationCircuit(data,eventCapacity = 16,sourceCapacity = 128,sectionCapacity = 4,
          digestClaim = true,instructionCapacity = 1,
          declarationProfile = DeclarationProfile(enabled: true,types: 3,functions: 1,parameters: 3,results: 3),
          payloadProfile = PayloadProfile(enabled: true,imports: 8,globals: 2,tables: 2,memories: 2,nameBytes: 16))
    elif mode == "alltypes":
      block:
        # Repeated, shared signatures contain every supported value type,
        # with the result order reversed relative to the parameter order.
        var data = @[0'u8,97,115,109,1,0,0,0,1,38,3]
        for i in 0..2:
          if i == 1: data.add @[96'u8,0,0]
          else: data.add @[96'u8,7,127,126,125,124,123,112,111,7,111,112,123,124,125,126,127]
        buildModuleValidationCircuit(data,eventCapacity = 16,sourceCapacity = 64,sectionCapacity = 3,digestClaim = true,instructionCapacity = 1,
          declarationProfile = DeclarationProfile(enabled: true,types: 4,parameters: 14,results: 14),
          payloadProfile = PayloadProfile(enabled: true))
    elif mode in ["nonminimal","multi","empty","tag"]:
      block:
        var data = @[0'u8,97,115,109,1,0,0,0]
        if mode == "nonminimal":
          data.add @[1'u8,7,1,96,128,0,129,0,127,3,2,1,0,10,6,1,4,0,65,42,11]
        elif mode == "tag":
          data.add @[1'u8,4,1,96,0,0,13,3,1,0,0]
        elif mode == "multi":
          data.add @[1'u8,8,1,96,2,127,126,2,127,126,3,2,1,0,10,8,1,6,0,32,0,32,1,11]
        buildModuleValidationCircuit(data,eventCapacity = 32,sourceCapacity = 64,sectionCapacity = 6,digestClaim = true,instructionCapacity = 8,
          declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,parameters: 4,results: 4,tags: 1,localRanges: 4),
          payloadProfile = PayloadProfile(enabled: true))
    else: raise newException(ValueError,"unknown declaration audit mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-":
    when defined(zkbuildRuntimeContextAudit):
      writeRuntimeContextAudit(paramStr(3),circuit,getEnv("ZKBUILD_CONTEXT_SUFFIX") == "1")
    elif defined(zkbuildStructuredControlAudit):
      writeStructuredControlAudit(paramStr(3),circuit,getEnv("ZKBUILD_STRUCTURED_SUFFIX") == "1")
    elif defined(zkbuildDynamicTypingAudit):
      writeDynamicTypingAudit(paramStr(3),circuit,getEnv("ZKBUILD_TYPING_SUFFIX") == "1")
    elif defined(zkbuildValidationEventAudit):
      writeValidationEventAudit(paramStr(3),circuit)
    elif defined(zkbuildInstructionSourceAudit):
      writeInstructionSourceAudit(paramStr(3),circuit)
    elif defined(zkbuildBodySourceAudit):
      writeBodySourceAudit(paramStr(3),circuit)
    elif defined(zkbuildModuleContextAudit):
      writeModuleContextAudit(paramStr(3),circuit)
    elif defined(zkbuildSegmentPayloadAudit):
      writeSegmentPayloadAudit(paramStr(3),circuit)
    elif defined(zkbuildScalarPayloadAudit):
      writeScalarPayloadAudit(paramStr(3),circuit)
    elif defined(zkbuildConstantSourceAudit):
      writeConstantSourceAudit(paramStr(3),circuit)
    elif defined(zkbuildNameSourceAudit):
      writeNameSourceAudit(paramStr(3),circuit)
    elif defined(zkbuildNameGraphAudit):
      writeNameGraphAudit(paramStr(3),circuit)
    elif defined(zkbuildNameFrameAudit):
      writeNameFrameAudit(paramStr(3),circuit)
    elif defined(zkbuildOwnedAudit):
      writeOwnedAudit(paramStr(3),circuit)
    elif defined(zkbuildImportAudit):
      writeImportAudit(paramStr(3),circuit)
    elif defined(zkbuildSignatureAudit):
      writeSignatureAudit(paramStr(3),circuit)
    elif defined(zkbuildIndexedAudit):
      writeIndexedAudit(paramStr(3),circuit)
    elif defined(zkbuildDeclarationAudit):
      writeDeclarationAudit(paramStr(3),circuit)
    elif defined(zkbuildEnvelopeAudit):
      if mode in ["module","full"]: writeModuleTablesAudit(paramStr(3),circuit)
      else: writeReadOnlyAudit(paramStr(3),circuit)
    else: writeReadOnlyAudit(paramStr(3),circuit)
  echo "declaration audit ",mode," constraints=",circuit.constraints.len

main()
