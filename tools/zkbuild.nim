## Nim-only experimental proof-carrying WASM CLI.
import std/[os, strutils, times, json, jsonutils]
import cps/zk/[prover_wire, wasm_circuit, wasm_bytes_circuit, wasm_compile_bytes]
import cps/zk/[wasm_module_prover, wasm_module_verifier, wasm_digest_key, wasm_digest_claim, wasm_proving_key_file]

when defined(zkbuildByteMemoryAudit):
  import cps/zk/[binary_read_audit,gadget_audit]
when defined(zkbuildTokenAudit):
  import cps/zk/token_audit
when defined(zkbuildEnvelopeAudit):
  import cps/zk/envelope_audit
when defined(zkbuildReadOnlyAudit) and defined(zkbuildEnvelopeAudit) and defined(zkbuildPackedAudit):
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

proc readBytes(path: string): seq[byte] =
  let text = readFile(path)
  result = newSeq[byte](text.len)
  for i, ch in text: result[i] = ch.byte

proc writeBytes(path: string, bytes: openArray[byte]) =
  var text = newString(bytes.len)
  for i, b in bytes: text[i] = b.char
  writeFile(path, text)

proc digestHex(digest: Sha256Digest): string =
  for b in digest: result.add toHex(b,2).toLowerAscii()

proc parseDigest(text: string): Sha256Digest =
  if text.len != 64: raise newException(ValueError,"trusted key digest must have 64 hex characters")
  for i in 0..<32:
    let value = text[2*i..2*i+1]
    for ch in value:
      if ch notin {'0'..'9','a'..'f','A'..'F'}: raise newException(ValueError,"invalid key digest hex")
    result[i] = byte(parseHexInt(value))

proc modeOf(text: string): ProofMode =
  case text
  of "validate": pmValidateBytes
  of "validate-slots": pmValidate
  of "compile": pmCompile
  of "compile-bytes": pmCompileBytes
  else: raise newException(ValueError, "mode must be validate, validate-slots, compile, or compile-bytes")

proc sample(): Program =
  result[0] = Operation(kind: opParam0)
  result[1] = Operation(kind: opParam1)
  result[2] = Operation(kind: opAdd)
  result[3] = Operation(kind: opConst, immediate: 7)
  result[4] = Operation(kind: opMul)

proc usage() =
  echo "Experimental Nim zkbuild (full-runtime WASM validity and bounded native compilation)"
  echo "  zkbuild module-profile INPUT.wasm OUT.json"
  echo "  zkbuild module-audit INPUT.wasm OUT.audit [PROFILE.json]"
  echo "  zkbuild module-audit-key KEY.pk INPUT.wasm OUT.audit"
  echo "  zkbuild module-setup INPUT.wasm OUT.pk OUT.vk [PROFILE.json]"
  echo "  zkbuild module-prove-key KEY.pk INPUT.wasm OUT.proof [INPUT2.wasm OUT2.proof ...]"
  echo "  zkbuild module-prove INPUT.wasm OUT.vk OUT.proof [PROFILE.json]"
  echo "  zkbuild module-verify TRUSTED_KEY_SHA256 KEY.vk INPUT.wasm INPUT.proof"
  echo "  zkbuild sample OUT.wasm"
  echo "  zkbuild sample-slots OUT.wasm"
  echo "  zkbuild setup validate|validate-slots|compile|compile-bytes OUT.pk OUT.vk"
  echo "  zkbuild prove KEY.pk INPUT.wasm OUT.proof [OUT.rv32]"
  echo "  zkbuild verify TRUSTED.vk INPUT.wasm INPUT.proof [INPUT.rv32]"
  echo "Setup is single-party; this is not a production multiparty ceremony."

proc main() =
  let args = commandLineParams()
  if args.len == 0: usage(); return
  let start = epochTime()
  case args[0]
  of "module-profile":
    if args.len != 3: raise newException(ValueError,"module-profile requires WASM and output JSON")
    let profile = inferModuleValidationProfile(readBytes(args[1]))
    writeFile(args[2],pretty(toJson(profile)) & "\n")
    echo "profile=",args[2]
  of "module-audit", "module-audit-key":
    when not defined(zkbuildByteMemoryAudit):
      raise newException(ValueError,"offline byte certification requires the audit CLI: make zkbuild-audit-cli")
    else:
      let savedKey = args[0] == "module-audit-key"
      if (savedKey and args.len != 4) or (not savedKey and args.len notin 3..4):
        raise newException(ValueError,"module-audit requires WASM, audit output and optional profile; module-audit-key requires PK, WASM and audit output")
      let inputIndex = if savedKey: 2 else: 1
      let outputIndex = inputIndex+1
      let output = absolutePath(args[outputIndex])
      for i in 1..<outputIndex:
        if output == absolutePath(args[i]):
          raise newException(ValueError,"audit output must differ from every input")
      if not savedKey and args.len == 4 and output == absolutePath(args[3]):
        raise newException(ValueError,"audit output must differ from the profile")
      let bytes = readBytes(args[inputIndex])
      let profile = if savedKey: readModuleProvingProfile(args[1])
                    elif args.len == 4: jsonTo(parseFile(args[3]),ModuleValidationProfile)
                    else: inferModuleValidationProfile(bytes)
      profile.requireFullProfile()
      let circuit = moduleCircuit(bytes,profile)
      if not circuit.satisfied(): raise newException(ValueError,"unsatisfied module validation relation")
      if savedKey:
        let loaded = loadModuleProvingKey(args[1])
        if not sameShape(loaded.key.shape,circuit):
          raise newException(ValueError,"audit circuit differs from stored proving key")
        let keyBytes = encodeModuleDigestKey(loaded.key.verificationKey,profile.sourceCapacity)
        echo "trusted_key_sha256=",digestHex(sha256(keyBytes))
      when defined(zkbuildRuntimeContextAudit):
        writeRuntimeContextAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-runtime-context"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_event_semantics"
      elif defined(zkbuildStructuredControlAudit):
        writeStructuredControlAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-structured-control"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_structured_control"
      elif defined(zkbuildDynamicTypingAudit):
        writeDynamicTypingAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-dynamic-typing"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_dynamic_typing"
      elif defined(zkbuildValidationEventAudit):
        writeValidationEventAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-validation-events"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_validation_events"
      elif defined(zkbuildInstructionSourceAudit):
        writeInstructionSourceAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-instruction-stream"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_instruction_source"
      elif defined(zkbuildBodySourceAudit):
        writeBodySourceAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-code-bodies"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_body_source"
      elif defined(zkbuildModuleContextAudit):
        writeModuleContextAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-module-context"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_module_context"
      elif defined(zkbuildSegmentPayloadAudit):
        writeSegmentPayloadAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-payload-loops"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_segment_payload"
      elif defined(zkbuildScalarPayloadAudit):
        writeScalarPayloadAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-scalar-payloads"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_scalar_payload ",output
      elif defined(zkbuildConstantSourceAudit):
        writeConstantSourceAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-constant-readers"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_constant_source ",output
      elif defined(zkbuildNameSourceAudit):
        writeNameSourceAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-name-bindings"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_name_source ",output
      elif defined(zkbuildNameGraphAudit):
        writeNameGraphAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-name-graph"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_name_graph ",output
      elif defined(zkbuildNameFrameAudit):
        writeNameFrameAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-name-frames"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_name_frames ",output
      elif defined(zkbuildOwnedAudit):
        writeOwnedAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-owned-streams"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_owned ",output
      elif defined(zkbuildImportAudit):
        writeImportAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-import-origins"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_imports ",output
      elif defined(zkbuildSignatureAudit):
        writeSignatureAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-signature-origins"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_signatures ",output
      elif defined(zkbuildIndexedAudit):
        writeIndexedAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-indexed-signatures"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_indexed ",output
      elif defined(zkbuildDeclarationAudit):
        writeDeclarationAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-declaration-bindings"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_declarations ",output
      elif defined(zkbuildReadOnlyAudit) and defined(zkbuildEnvelopeAudit) and defined(zkbuildPackedAudit):
        writeModuleTablesAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-envelope-table-membership-packed-fields"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_module_tables ",output
      elif defined(zkbuildEnvelopeAudit):
        writeEnvelopeAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-section-envelope"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_envelope ",output
      elif defined(zkbuildTokenAudit):
        writeTokenAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-token-readers"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_tokens ",output
      else:
        writeBinaryReadAudit(output,circuit)
        echo "audit=",output," claim=source-sha256-byte-queries"
        echo "check_with=formal/zkbuild/.lake/build/bin/check_byte_memory ",output
      echo "matrix_sha256=",circuit.fingerprints().matrix
  of "module-setup":
    if args.len notin 4..5: raise newException(ValueError,"module-setup requires WASM, PK, VK and optional profile JSON")
    for pair in [(1,2),(1,3),(2,3)]:
      if absolutePath(args[pair[0]]) == absolutePath(args[pair[1]]):
        raise newException(ValueError,"setup input and output paths must differ")
    let wasm = readBytes(args[1])
    let profile = if args.len == 5: jsonTo(parseFile(args[4]),ModuleValidationProfile)
                  else: inferModuleValidationProfile(wasm)
    profile.requireFullProfile()
    let key = setupModuleValidation(wasm,profile)
    saveModuleProvingKey(args[2],key,profile)
    let encoded = encodeModuleDigestKey(key.verificationKey,profile.sourceCapacity)
    writeBytes(args[3],encoded)
    echo "constraints=",key.shape.constraints.len," proving_key_bytes=",getFileSize(args[2])," key_bytes=",encoded.len
    echo "trusted_key_sha256=",digestHex(sha256(encoded))
  of "module-prove-key":
    if args.len < 4 or (args.len mod 2) != 0:
      raise newException(ValueError,"module-prove-key requires PK and one or more WASM/proof path pairs")
    var inputs = @[absolutePath(args[1])]
    var outputs: seq[string]
    for i in countup(2,args.high,2): inputs.add absolutePath(args[i])
    for i in countup(3,args.high,2):
      let output = absolutePath(args[i])
      if output in inputs or output in outputs:
        raise newException(ValueError,"proof output paths must be distinct from all inputs and one another")
      outputs.add output
    let profile = readModuleProvingProfile(args[1])
    for i in countup(2,args.high,2):
      if not profile.fitsModuleProvingProfile(readBytes(args[i])):
        raise newException(ValueError,"input exceeds stored proof profile: " & args[i])
    let loaded = loadModuleProvingKey(args[1])
    for i in countup(2,args.high,2):
      let wasm = readBytes(args[i])
      let proof = proveModuleValidation(loaded.key,wasm,loaded.profile)
      if not verifyModuleDigest(loaded.key.verificationKey,wasm,proof):
        raise newException(ValueError,"proof generated from stored key failed verification")
      writeBytes(args[i+1],proof)
      echo "proof=",args[i+1]," proof_bytes=",proof.len
    let encoded = encodeModuleDigestKey(loaded.key.verificationKey,loaded.profile.sourceCapacity)
    echo "trusted_key_sha256=",digestHex(sha256(encoded))
  of "module-prove":
    if args.len notin 4..5: raise newException(ValueError,"module-prove requires WASM, VK, proof and optional profile JSON")
    let wasm = readBytes(args[1])
    let profile = if args.len == 5: jsonTo(parseFile(args[4]),ModuleValidationProfile)
                  else: inferModuleValidationProfile(wasm)
    if not profile.digestClaim or not profile.declarations.enabled or not profile.payloads.enabled:
      raise newException(ValueError,"module-prove requires a full digest/declaration/payload profile")
    let key = setupModuleValidation(wasm,profile)
    let proof = proveModuleValidation(key,wasm,profile)
    if not verifyModuleDigest(key.verificationKey,wasm,proof):
      raise newException(ValueError,"generated module proof failed verification")
    let encoded = encodeModuleDigestKey(key.verificationKey,profile.sourceCapacity)
    writeBytes(args[2],encoded)
    writeBytes(args[3],proof)
    echo "constraints=",key.shape.constraints.len," proof_bytes=",proof.len," key_bytes=",encoded.len
    echo "trusted_key_sha256=",digestHex(sha256(encoded))
  of "module-verify":
    if args.len != 5: raise newException(ValueError,"module-verify requires trusted digest, VK, WASM and proof")
    let key = prepareModuleDigestKey(parseDigest(args[1]),readBytes(args[2]))
    if not key.verifyModuleDigest(readBytes(args[3]),readBytes(args[4])):
      raise newException(ValueError,"module proof or pinned key rejected")
    echo "verified claim=full-runtime-wasm-validity"
  of "sample", "sample-slots":
    if args.len != 2: raise newException(ValueError, "sample requires output path")
    let p = sample()
    writeBytes(args[1], if args[0] == "sample": encodeByteModule(p.toOpenArray(0,4)) else: encodeWasm(p))
  of "setup":
    if args.len != 4: raise newException(ValueError, "setup requires mode, PK, VK")
    let mode = modeOf(args[1])
    let program = sample()
    let wasm = if mode == pmCompileBytes: encodeByteModule(program) else: encodeWasm(program)
    var compiled = program
    if mode == pmCompileBytes and not decodeByteProgram(wasm, compiled):
      raise newException(ValueError, "setup sample outside byte compilation profile")
    let circuit = if mode == pmValidateBytes: buildByteCircuit(wasm)
                  elif mode == pmCompileBytes: buildByteCompileCircuit(wasm, encodeNative(compiled), compiled)
                  else: buildCircuit(mode, program, wasm, encodeNative(program))
    echo "constraints=", circuit.constraints.len, " wires=", circuit.values.len
    let key = setup(circuit)
    writeBytes(args[2], encodeProvingKey(key, mode))
    writeBytes(args[3], encodeKey(key.verificationKey, mode))
  of "prove":
    if args.len notin 4..5: raise newException(ValueError, "prove requires PK, WASM, proof, optional RV32")
    var mode: ProofMode
    let key = decodeProvingKey(readBytes(args[1]), mode)
    if (mode in {pmCompile, pmCompileBytes}) != (args.len == 5):
      raise newException(ValueError, "compile mode requires native output; validate mode forbids it")
    let wasm = readBytes(args[2])
    var program: Program
    if mode == pmValidateBytes:
      if not checkByteModule(wasm): raise newException(ValueError, "WASM outside byte-stream profile")
    elif mode == pmCompileBytes:
      if not decodeByteProgram(wasm, program): raise newException(ValueError, "WASM outside byte compilation profile")
    elif not decodeWasm(wasm, program):
      raise newException(ValueError, "WASM outside certified profile")
    let native = if mode in {pmCompile, pmCompileBytes}: encodeNative(program) else: @[]
    let circuit = if mode == pmValidateBytes: buildByteCircuit(wasm)
                  elif mode == pmCompileBytes: buildByteCompileCircuit(wasm, native, program)
                  else: buildCircuit(mode, program, wasm, native)
    let proof = encodeProof(prove(key, circuit))
    if not verifyArtifacts(key.verificationKey, mode, wasm, native, proof):
      raise newException(ValueError, "generated proof failed verification")
    writeBytes(args[3], proof)
    if mode in {pmCompile, pmCompileBytes}: writeBytes(args[4], native)
    echo "proof_bytes=", proof.len
  of "verify":
    if args.len notin 4..5: raise newException(ValueError, "verify requires VK, WASM, proof, optional RV32")
    var mode: ProofMode
    var key: VerificationKey
    if not decodeKey(readBytes(args[1]), key, mode): raise newException(ValueError, "invalid verification key")
    let native = if args.len == 5: readBytes(args[4]) else: @[]
    if not verifyArtifacts(key, mode, readBytes(args[2]), native, readBytes(args[3])):
      raise newException(ValueError, "proof rejected")
    echo "verified claim=", mode
  else: raise newException(ValueError, "unknown command")
  echo "elapsed_seconds=", formatFloat(epochTime()-start, ffDecimal, 3)

when isMainModule:
  try: main()
  except CatchableError as error:
    stderr.writeLine("zkbuild: " & error.msg)
    quit(1)
