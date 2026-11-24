## A deterministic, sparse R1CS builder. Wire 0 is the constant one.
## Constraint generation must depend on the profile, never on witness values.
import field
import std/tables
export field

type
  Term* = object
    wire*: int
    coefficient*: Scalar
  Linear* = seq[Term]
  R1Constraint* = object
    a*, b*, c*: Linear
  GadgetKind* = enum
    gkEquality, gkMultiply, gkMaterialize, gkBit, gkBoolean, gkSelect, gkSelectWire,
    gkZero, gkUnsigned, gkReusedUnsigned, gkLiteralUnsigned
  GadgetRecord* = object
    kind*: GadgetKind
    firstWire*, lastWire*, firstGate*, lastGate*, width*, reference*: int
    inputs*, outputs*: seq[Linear]
  GadgetMarker* = object
    wires*, gates*, records*: int
  Sha256Record* = object
    firstWire*, lastWire*, firstGate*, lastGate*: int
    length*: Linear
    source*, digest*: seq[Linear]
    lengthRange*: GadgetRecord
  BinarySourceRecord* = object
    firstWire*, lastWire*, firstGate*, lastGate*, capacity*: int
    length*: Linear
    limbs*, outputs*: seq[Linear]
    lengthRange*: GadgetRecord
  PermutationRecord* = object
    firstWire*, lastWire*, firstGate*, lastGate*, capacity*: int
    inputs*, outputs*: seq[Linear]
  MemoryRangeAudit* = object
    kind*, firstWire*, lastWire*, firstGate*, lastGate*: int
  MemoryAccessAudit* = object
    firstGate*, lastGate*: int
    fields*: seq[Linear]
    address*, value*: MemoryRangeAudit
  MemoryRowAudit* = object
    access*: MemoryAccessAudit
    clock*: Linear
    clockRange*: MemoryRangeAudit
    firstWire*, lastWire*, firstGate*, lastGate*: int
  MemoryAudit* = object
    addressBits*, timeBits*, valueBits*: int
    inputs*: seq[MemoryAccessAudit]
    rows*: seq[MemoryRowAudit]
    network*: PermutationRecord
  BinaryReadMemoryAudit* = object
    sourceIndex*, memoryIndex*: int
    queries*: seq[Linear]
  RangeUseAudit* = object
    call*, source*: GadgetRecord
    hasSource*: bool
  TokenRowAudit* = object
    value*, address*, remaining*, next*: Linear
    byteRange*, remainingRange*: RangeUseAudit
    extrasStart*: int
  TokenAudit* = object
    kind*, sourceIndex*, queryStart*: int
    firstWire*, lastWire*, firstGate*, lastGate*: int
    selectorStart*, choiceStart*, signStart*: int
    activeMode*, position*, expected*, length*, sourceLength*: Linear
    positionRange*, valueRange*, lengthRange*: RangeUseAudit
    rows*: seq[TokenRowAudit]
  LookupNodeAudit* = object
    bit*, zero*, one*: int
    payload*: seq[int]
  LookupAudit* = object
    range*: RangeUseAudit
    firstWire*, lastWire*, firstGate*, lastGate*, root*, columns*: int
    input*: Linear
    outputs*: seq[Linear]
    nodes*: seq[LookupNodeAudit]
  PackedFieldsAudit* = object
    lowWidth*, highWidth*, firstGate*, lastGate*: int
    input*, low*, high*: Linear
    range*: RangeUseAudit
  ReadOnlyOrderAudit* = object
    delta*: Linear
    range*: RangeUseAudit
  ReadOnlyAudit* = object
    firstGate*, preludeEnd*, memoryIndex*: int
    entries*, queries*: seq[Linear] # active/address/value triples
    order*: seq[ReadOnlyOrderAudit]
  DeclarationTypeAudit* = object
    firstGate*, lastGate*: int
    fields*, counts*: seq[Linear]
    ranges*: seq[RangeUseAudit]
    headerToken*, paramToken*, resultToken*, heads*: int
    paramPosition*, resultPosition*, remaining*: Linear
    remainingRange*: RangeUseAudit
    metadata*, paramLength*, resultLength*: seq[Linear]
  DeclarationVectorAudit* = object
    firstGate*, lastGate*, tagZero*, extendedZero*, keySplit*, spanSplit*, heads*, node*, token*: int
    fields*, location*, metadata*, member*: seq[Linear]
    addressRange*, valueRange*, orderRange*, withinRange*: RangeUseAudit
    hasOrder*: bool
    orderDelta*, within*, code*, position*, memberKey*, count*: Linear
  DeclarationFunctionAudit* = object
    firstGate*, lastGate*, token*: int
    active*, cursor*, count*: Linear
    query*: seq[Linear]
  DeclarationTagAudit* = object
    firstGate*, lastGate*, attributeToken*, indexToken*: int
    active*, typeIndex*, position*, cursor*: Linear
  DeclarationAudit* = object
    firstFunction*: Linear
    typeStart*, typeEnd*, typeCount*, functionStart*, functionEnd*, functionCount*, tagStart*, tagEnd*: Linear
    types*: seq[DeclarationTypeAudit]
    params*, results*: seq[DeclarationVectorAudit]
    functions*: seq[DeclarationFunctionAudit]
    tags*: seq[DeclarationTagAudit]
    tables*: seq[int]
    typeCloseStart*, typeCloseEnd*, paramCloseStart*, paramCloseEnd*, resultCloseStart*, resultCloseEnd*: int
    functionCloseStart*, functionCloseEnd*, tagCloseStart*, tagCloseEnd*: int
    paramTotal*, resultTotal*: Linear
    paramTotalRange*, resultTotalRange*: RangeUseAudit
  IndexedLengthAudit* = object
    firstGate*, lastGate*, headZero*, lengthZero*: int
    fields*, firstMember*: seq[Linear]
    nonempty*: Linear
  IndexedMemberAudit* = object
    firstGate*, lastGate*, addressSplit*, cellSplit*, nodeSplit*: int
    headZero*, cursorZero*, tagZero*, continuationZero*: int
    fields*, nodeQuery*, lengthQuery*: seq[Linear]
    continuing*: Linear
  IndexedCloseAudit* = object
    firstGate*, lastGate*: int
  IndexedMetadataAudit* = object
    firstGate*, lastGate*, heads*: int
    fields*, params*, results*: seq[Linear]
  IndexedSingletonAudit* = object
    firstGate*, lastGate*: int
    fields*, nodeQuery*: seq[Linear]
  IndexedAudit* = object
    nilStart*, nilEnd*: int
    lengths*: seq[IndexedLengthAudit]
    members*: seq[IndexedMemberAudit]
    closing*: seq[IndexedCloseAudit]
    metadata*: seq[IndexedMetadataAudit]
    singletons*: seq[IndexedSingletonAudit]
    extraLengths*, extraMembers*, extraSingletons*: seq[Linear]
    tables*: seq[int]
  SignatureReferenceAudit* = object
    zeroStart*: int
    query*: seq[Linear]
  SignatureMetadataAudit* = object
    firstGate*, lastGate*, heads*: int
    entry*: seq[Linear]
    typeIndex*, functionEntry*: Linear
    addressRange*, typeIndexRange*: RangeUseAudit
    references*: seq[SignatureReferenceAudit]
    origin*: seq[Linear]
  SignatureNodeAudit* = object
    firstGate*, lastGate*, node*, tagZero*: int
    entry*: seq[Linear]
    delta*: Linear
    deltaRange*: RangeUseAudit
    reference*: SignatureReferenceAudit
  SignatureAudit* = object
    metadata*: seq[SignatureMetadataAudit]
    nodes*: seq[SignatureNodeAudit]
    extraMetadata*, extraOperands*: seq[Linear]
    tables*: seq[int]
  SignatureNamespaceRowAudit* = object
    firstGate*, lastGate*: int
    entry*: seq[Linear]
    addressRange*: RangeUseAudit
    typeEntry*, index*, functions*, types*: Linear
  SignatureNamespaceAudit* = object
    rows*: seq[SignatureNamespaceRowAudit]
    functions*, types*, importedFunctions*, firstFunction*: Linear
    importedRange*: RangeUseAudit
    firstAliasStart*, firstAliasEnd*, closeStart*, closeEnd*: int
    typeBindStart*, typeBindEnd*, functionBindStart*, functionBindEnd*: int
  ImportNameAudit* = object
    query*: seq[Linear]
    heads*: int
    cursor*: Linear
  ImportReadAudit* = object
    token*: int
    cursor*: Linear
  ImportRowAudit* = object
    firstGate*, lastGate*: int
    active*, kind*, objectIndex*: Linear
    kindRange*, objectRange*: RangeUseAudit
    names*: seq[ImportNameAudit]
    reads*: seq[ImportReadAudit]
    zeroStarts*: seq[int]
    indicators*, typeQuery*, objectQuery*, limitQueries*, counts*: seq[Linear]
    typeZeroStart*, limitHeads*: int
  ImportAudit* = object
    rows*: seq[ImportRowAudit]
    exportCount*, importedFunctions*, importedTables*, importedMemories*, importedGlobals*: Linear
    closeStart*, closeEnd*: int
    tables*: seq[int]
  OwnedParentAudit* = object
    firstGate*, lastGate*, zeroStart*: int
    fields*: seq[Linear] # active/count/start/finish
    ranges*: seq[RangeUseAudit]
  OwnedChildAudit* = object
    firstGate*, lastGate*, heads*, priorZero*, nextZero*: int
    fields*: seq[Linear] # active/owner/ordinal/start/finish
    ranges*: seq[RangeUseAudit]
    countQuery*, spanQuery*: seq[Linear]
    within*, order*, same*, continues*: Linear
    withinRange*, orderRange*: RangeUseAudit
  OwnedAudit* = object
    parents*: seq[OwnedParentAudit]
    children*: seq[OwnedChildAudit]
    closeStart*, closeEnd*: int
    tables*: seq[int]
  NameFrameHeaderAudit* = object
    firstGate*, lastGate*, token*, byteStart*, byteCount*, closeGate*: int
    fields*: seq[Linear] # active/count/header start/body start/finish
    ranges*: seq[RangeUseAudit]
  NameFrameByteAudit* = object
    firstGate*, lastGate*, token*: int
    fields*: seq[Linear] # active/owner/ordinal/start/finish
  NameFrameAudit* = object
    flat*: bool
    owned*: int
    headers*: seq[NameFrameHeaderAudit]
    bytes*: seq[NameFrameByteAudit]
  NameNodeAudit* = object
    firstGate*, lastGate*, zeroStart*: int
    entry*, query*, canonical*: seq[Linear]
    fields*: seq[Linear] # byte/tail/state/nonempty/nextState/nextHigh/delta
    ranges*: seq[RangeUseAudit] # node word/next word/order delta
    lookup*: LookupAudit
  NameRootAudit* = object
    firstGate*, lastGate*, zeroStart*: int
    head*, state*: Linear
    query*: seq[Linear]
    ranges*: seq[RangeUseAudit] # head/node word
  NameGraphAudit* = object
    nodes*: seq[NameNodeAudit]
    roots*: seq[NameRootAudit]
    tables*: seq[int]
  NameSourceHeaderAudit* = object
    firstGate*, lastGate*, zeroStart*, nilGate*: int
    head*, finalHead*: Linear
  NameSourceByteAudit* = object
    firstGate*, lastGate*, zeroStart*, tailGate*: int
    nodeQuery*, rootQuery*, fields*: seq[Linear] # fields: byte/tail/same
    range*: RangeUseAudit
  NameSourceEndAudit* = object
    firstGate*, lastGate*, zeroStart*: int
    tail*, selector*: Linear
    countQuery*: seq[Linear]
    range*: RangeUseAudit
  NameSourceAudit* = object
    headers*: seq[NameSourceHeaderAudit]
    bytes*: seq[NameSourceByteAudit]
    ends*: seq[NameSourceEndAudit]
    tables*: seq[int]
  ConstantReadAudit* = object
    token*: int
    cursor*: Linear
  ConstantSourceAudit* = object
    firstGate*, lastGate*, heads*: int
    zeroStarts*: seq[int]
    fields*, selectors*: seq[Linear]
    reads*: seq[ConstantReadAudit]
  ScalarPayloadRowAudit* = object
    firstGate*, lastGate*, typeZeroStart*, constantIndex*, limitHeads*: int
    active*: Linear
    objectQuery*, fields*: seq[Linear]
    objectRange*: RangeUseAudit
    name*: ImportNameAudit
    limitQueries*: seq[seq[Linear]]
    reads*: seq[ImportReadAudit]
  ScalarPayloadAudit* = object
    rows*: array[4, seq[ScalarPayloadRowAudit]] # table, memory, global, export
    closeStarts*, closeEnds*: array[4, int]
  SegmentPayloadRowAudit* = object
    firstGate*, lastGate*, heads*: int
    fields*: seq[Linear]
    zeroStarts*, constants*: seq[int]
    ranges*: seq[RangeUseAudit]
    queries*: seq[seq[Linear]]
    reads*: seq[ImportReadAudit]
  SegmentPayloadAudit* = object
    flat*: bool
    elements*, items*, datas*, customs*: seq[SegmentPayloadRowAudit]
    tail*: SegmentPayloadRowAudit
    ownedIndex*, modeTable*: int
    closeStarts*, closeEnds*: array[3, int] # elements, data, singleton headers
  ModuleContextElementAudit* = object
    fields*, offset*: seq[Linear]
    items*: seq[seq[Linear]]
  ModuleContextProgramAudit* = object
    firstGate*, lastGate*: int
    primitives*: seq[RangeUseAudit]
  SourceProgramMarker* = object
    firstGate*, firstPrimitive*, firstBlock*: int
    parentActive*: bool
  SourceBlockAudit* = object
    kind*, index*, firstPrimitive*, lastPrimitive*, firstGate*, lastGate*: int
  SourceProgramAudit* = object
    program*: ModuleContextProgramAudit
    blocks*: seq[SourceBlockAudit]
  CodeBodyAudit* = object
    fields*: seq[Linear] # active, size, local count, locals start, instructions, end
    locals*: seq[seq[Linear]] # count, type tag (legacy representation)
  CodeSourceAudit* = object
    flat*: bool
    firstFunction*: Linear
    bodies*: seq[CodeBodyAudit]
    locals*, spans*: seq[seq[Linear]]
    banks*: seq[int]
    program*: SourceProgramAudit
  LocalRangeAudit* = object
    locals*, ranges*, tags*: seq[seq[Linear]]
    selected*: seq[Linear]
    banks*: seq[int]
    program*: SourceProgramAudit
  LocalDeclarationAudit* = object
    firstFunction*, functionCount*: Linear
    ranges*, tags*, totals*: seq[seq[Linear]]
    banks*: seq[int]
    program*: SourceProgramAudit
  InstructionDecodeAudit* = object
    inputs*, auxiliary*, outputs*: seq[Linear]
    program*: SourceProgramAudit
  InstructionRowAudit* = object
    fields*: seq[Linear] # active, function, pc, opcode, primary, secondary, pad, start, end
    decode*, labelCount*, catchCount*: int
    frame*: Linear
  InstructionSourceAudit* = object
    flat*: bool
    firstFunction*: Linear
    spans*, functions*, labels*, catches*, events*: seq[seq[Linear]]
    bodySizes*: seq[int]
    rows*: seq[InstructionRowAudit]
    banks*: seq[int]
    frameMemoryIndex*: int
    program*: SourceProgramAudit
  StaticRuleNodeAudit* = object
    kind*, bit*, zero*, one*: int
    payload*: seq[int]
  StaticRuleAudit* = object
    firstGate*, firstWire*, lastWire*, lastGate*, root*: int
    opcodeRange*, typeRange*: RangeUseAudit
    inputs*, lowBits*, outputs*: seq[Linear]
    nodes*: seq[StaticRuleNodeAudit]
  ValidationStageAudit* = object
    kind*: int
    firstFunction*: Linear
    rows*, flags*, inputs*, outputs*: seq[seq[Linear]]
    program*: SourceProgramAudit
  ValidationTraceAudit* = object
    firstFunction*: Linear
    rows*: seq[seq[Linear]]
    memories*: seq[int]
  DynamicTypingStageAudit* = object
    kind*: int
    rows*, flags*, selectors*, inputs*, outputs*, auxiliary*: seq[seq[Linear]]
    banks*: seq[int]
    program*: SourceProgramAudit
  ModuleContextAudit* = object
    flat*: bool
    counts*, heads*: seq[Linear]
    memories*, tables*, globals*, items*, datas*, exports*, unique*, bodies*, bulk*: seq[seq[Linear]]
    elements*: seq[ModuleContextElementAudit]
    programs*: seq[ModuleContextProgramAudit]
    banks*: seq[int]
    ownedIndex*, elementBank*: int
    startBindFirst*, startBindLast*: int
  EnvelopeRowAudit* = object
    fields*: seq[Linear]
    ranges*: seq[RangeUseAudit]
    idToken*, sizeToken*, wordToken*: int
    sizePosition*, remaining*, standard*, rankGap*, nextRank*, wordGap*, cursor*: Linear
    remainingRange*, rankGapRange*, wordGapRange*: RangeUseAudit
    lookup*: LookupAudit
    standardStart*, aggregateStart*: int
  EnvelopeAudit* = object
    sourceIndex*, firstWire*, lastWire*, firstGate*, lastGate*: int
    headerTokens*: seq[int]
    sourceLength*: Linear
    rows*: seq[EnvelopeRowAudit]
    outputs*: seq[Linear]
  Circuit* = object
    publicCount*: int
    values*: seq[Scalar]
    constraints*: seq[R1Constraint]
    reuseRangeWitnesses*: bool
    # Builder metadata only. It never forms part of a proof or key encoding.
    # Only range_check may populate this with previously constrained bits.
    rangeWitnesses*: Table[tuple[wire, width: int], seq[Linear]]
    when defined(zkbuildGadgetAudit):
      gadgets*: seq[GadgetRecord]
      auditRangeSources*: Table[tuple[wire, width: int], int]
    when defined(zkbuildShaAudit):
      sha256Records*: seq[Sha256Record]
    when defined(zkbuildSourceAudit):
      binarySourceRecords*: seq[BinarySourceRecord]
    when defined(zkbuildPermutationAudit):
      permutationRecords*: seq[PermutationRecord]
    when defined(zkbuildMemoryAudit):
      memoryAccessRecords*: seq[MemoryAccessAudit]
      memoryRecords*: seq[MemoryAudit]
    when defined(zkbuildByteMemoryAudit):
      binaryReadMemoryRecords*: seq[BinaryReadMemoryAudit]
    when defined(zkbuildTokenAudit):
      tokenRecords*: seq[TokenAudit]
    when defined(zkbuildLookupAudit):
      lookupRecords*: seq[LookupAudit]
    when defined(zkbuildEnvelopeAudit):
      envelopeRecords*: seq[EnvelopeAudit]
    when defined(zkbuildReadOnlyAudit):
      readOnlyRecords*: seq[ReadOnlyAudit]
    when defined(zkbuildPackedAudit):
      packedRecords*: seq[PackedFieldsAudit]
    when defined(zkbuildDeclarationAudit):
      declarationRecords*: seq[DeclarationAudit]
    when defined(zkbuildIndexedAudit):
      indexedRecords*: seq[IndexedAudit]
    when defined(zkbuildSignatureAudit):
      signatureRecords*: seq[SignatureAudit]
      signatureNamespaceRecords*: seq[SignatureNamespaceAudit]
    when defined(zkbuildImportAudit):
      importRecords*: seq[ImportAudit]
    when defined(zkbuildOwnedAudit):
      ownedRecords*: seq[OwnedAudit]
    when defined(zkbuildNameFrameAudit):
      nameFrameRecords*: seq[NameFrameAudit]
    when defined(zkbuildNameGraphAudit):
      nameGraphRecords*: seq[NameGraphAudit]
    when defined(zkbuildNameSourceAudit):
      nameSourceRecords*: seq[NameSourceAudit]
    when defined(zkbuildConstantSourceAudit):
      constantSourceRecords*: seq[ConstantSourceAudit]
    when defined(zkbuildScalarPayloadAudit):
      scalarPayloadRecords*: seq[ScalarPayloadAudit]
    when defined(zkbuildSegmentPayloadAudit):
      segmentPayloadRecords*: seq[SegmentPayloadAudit]
    when defined(zkbuildModuleContextAudit):
      moduleContextRecords*: seq[ModuleContextAudit]
    when defined(zkbuildBodySourceAudit):
      sourceProgramActive*: bool
      sourceProgramBlocks*: seq[SourceBlockAudit]
      codeSourceRecords*: seq[CodeSourceAudit]
      localDeclarationRecords*: seq[LocalDeclarationAudit]
      localRangeRecords*: seq[LocalRangeAudit]
    when defined(zkbuildInstructionSourceAudit):
      instructionDecodeRecords*: seq[InstructionDecodeAudit]
      instructionSourceRecords*: seq[InstructionSourceAudit]
    when defined(zkbuildValidationEventAudit):
      staticRuleRecords*: seq[StaticRuleAudit]
      validationStageRecords*: seq[ValidationStageAudit]
      validationTraceRecords*: seq[ValidationTraceAudit]
    when defined(zkbuildDynamicTypingAudit):
      dynamicTypingRecords*: seq[DynamicTypingStageAudit]
    when defined(zkbuildStructuredControlAudit):
      structuredControlRecords*: seq[DynamicTypingStageAudit]
      structuredControlMemories*: seq[int]
    when defined(zkbuildRuntimeContextAudit):
      runtimeContextRecords*: seq[DynamicTypingStageAudit]
      runtimeContextBindingFirst*, runtimeContextBindingLast*: int

when defined(zkbuildRuntimeContextAudit) and not defined(zkbuildStructuredControlAudit):
  {.error: "zkbuildRuntimeContextAudit requires zkbuildStructuredControlAudit".}

when defined(zkbuildShaAudit) and not defined(zkbuildGadgetAudit):
  {.error: "zkbuildShaAudit requires zkbuildGadgetAudit for range provenance".}
when defined(zkbuildSourceAudit) and not defined(zkbuildGadgetAudit):
  {.error: "zkbuildSourceAudit requires zkbuildGadgetAudit for range provenance".}
when defined(zkbuildMemoryAudit) and not (defined(zkbuildGadgetAudit) and defined(zkbuildPermutationAudit)):
  {.error: "zkbuildMemoryAudit requires zkbuildGadgetAudit and zkbuildPermutationAudit".}

when defined(zkbuildByteMemoryAudit) and not (defined(zkbuildSourceAudit) and defined(zkbuildShaAudit) and defined(zkbuildMemoryAudit)):
  {.error: "zkbuildByteMemoryAudit requires source, SHA, memory, gadget, and permutation audits".}

when defined(zkbuildTokenAudit) and not defined(zkbuildByteMemoryAudit):
  {.error: "zkbuildTokenAudit requires zkbuildByteMemoryAudit and its audit dependencies".}

when defined(zkbuildLookupAudit) and not defined(zkbuildTokenAudit):
  {.error: "zkbuildLookupAudit requires zkbuildTokenAudit and its audit dependencies".}

when defined(zkbuildDeclarationAudit) and not (defined(zkbuildEnvelopeAudit) and defined(zkbuildPackedAudit) and defined(zkbuildReadOnlyAudit)):
  {.error: "zkbuildDeclarationAudit requires envelope, packed-field and read-only audit flags".}

when defined(zkbuildIndexedAudit) and not defined(zkbuildDeclarationAudit):
  {.error: "zkbuildIndexedAudit requires zkbuildDeclarationAudit and its audit dependencies".}

when defined(zkbuildSignatureAudit) and not defined(zkbuildIndexedAudit):
  {.error: "zkbuildSignatureAudit requires zkbuildIndexedAudit and its audit dependencies".}
when defined(zkbuildImportAudit) and not defined(zkbuildSignatureAudit):
  {.error: "zkbuildImportAudit requires zkbuildSignatureAudit and its audit dependencies".}
when defined(zkbuildOwnedAudit) and (not defined(zkbuildPackedAudit) or not defined(zkbuildReadOnlyAudit)):
  {.error: "zkbuildOwnedAudit requires packed and immutable-table audit dependencies".}
when defined(zkbuildNameSourceAudit) and not defined(zkbuildNameGraphAudit):
  {.error: "zkbuildNameSourceAudit requires name graph audit dependencies".}
when defined(zkbuildConstantSourceAudit) and not defined(zkbuildNameSourceAudit):
  {.error: "zkbuildConstantSourceAudit requires name source audit dependencies".}
when defined(zkbuildScalarPayloadAudit) and not defined(zkbuildConstantSourceAudit):
  {.error: "zkbuildScalarPayloadAudit requires constant source audit dependencies".}

when defined(zkbuildNameGraphAudit) and not (defined(zkbuildNameFrameAudit) and defined(zkbuildLookupAudit)):
  {.error: "zkbuildNameGraphAudit requires name framing and lookup audit dependencies".}

when defined(zkbuildNameFrameAudit) and not defined(zkbuildOwnedAudit):
  {.error: "zkbuildNameFrameAudit requires zkbuildOwnedAudit".}

when defined(zkbuildPackedAudit) and not defined(zkbuildTokenAudit):
  {.error: "zkbuildPackedAudit requires zkbuildTokenAudit and its audit dependencies".}

when defined(zkbuildReadOnlyAudit) and not defined(zkbuildTokenAudit):
  {.error: "zkbuildReadOnlyAudit requires zkbuildTokenAudit and its audit dependencies".}

when defined(zkbuildEnvelopeAudit) and not defined(zkbuildLookupAudit):
  {.error: "zkbuildEnvelopeAudit requires zkbuildLookupAudit and its audit dependencies".}

when defined(zkbuildGadgetAudit) or defined(zkbuildPermutationAudit):
  proc copyAuditExpressions*(values: openArray[Linear]): seq[Linear] =
    for value in values:
      var copy: Linear
      for term in value: copy.add term
      result.add copy

when defined(zkbuildGadgetAudit):
  proc beginGadget(c: Circuit): GadgetMarker =
    GadgetMarker(wires: c.values.len,gates: c.constraints.len,records: c.gadgets.len)

  proc finishGadget(c: var Circuit, marker: GadgetMarker, kind: GadgetKind,
      inputs, outputs: openArray[Linear], width, reference: int): int =
    # An outer contract replaces its nested primitive records. The exact gate
    # interval still includes every nested constraint and must match the model.
    c.gadgets.setLen(marker.records)
    result = c.gadgets.len
    c.gadgets.add GadgetRecord(kind: kind,firstWire: marker.wires,lastWire: c.values.len,
      firstGate: marker.gates,lastGate: c.constraints.len,width: width,reference: reference,
      inputs: copyAuditExpressions(inputs),outputs: copyAuditExpressions(outputs))

template auditBegin*(c: Circuit): untyped =
  when defined(zkbuildGadgetAudit): beginGadget(c)
  else: 0

template auditFinish*(c: var Circuit, marker, kind, inputs, outputs: untyped,
    width = 0, reference = -1): untyped =
  when defined(zkbuildGadgetAudit):
    finishGadget(c,marker,kind,inputs,outputs,width,reference)
  else: -1

when defined(zkbuildShaAudit) or defined(zkbuildSourceAudit):
  proc auditRangeSource*(c: Circuit, length: Linear, width: int): GadgetRecord =
    if length.len != 1 or length[0].wire <= 0 or
        not length[0].coefficient.equals(scalar(1)):
      raise newException(ValueError,"range audit requires a unit-wire input")
    let key = (wire: length[0].wire,width: width)
    if not c.auditRangeSources.hasKey(key):
      raise newException(ValueError,"range audit is missing the original range source")
    result = c.gadgets[c.auditRangeSources[key]]
    result.inputs = copyAuditExpressions(result.inputs)
    result.outputs = copyAuditExpressions(result.outputs)

when defined(zkbuildShaAudit):
  proc recordSha256*(c: var Circuit, firstWire, firstGate: int,
      source: openArray[Linear], length: Linear, digest: openArray[Linear],
      lengthRange: GadgetRecord) =
    c.sha256Records.add Sha256Record(firstWire: firstWire,lastWire: c.values.len,
      firstGate: firstGate,lastGate: c.constraints.len,length: copyAuditExpressions([length])[0],
      source: copyAuditExpressions(source),digest: copyAuditExpressions(digest),lengthRange: lengthRange)

when defined(zkbuildSourceAudit):
  proc recordBinarySource*(c: var Circuit, firstWire, firstGate, capacity: int,
      length: Linear, limbs, outputs: openArray[Linear], lengthRange: GadgetRecord) =
    c.binarySourceRecords.add BinarySourceRecord(firstWire: firstWire,lastWire: c.values.len,
      firstGate: firstGate,lastGate: c.constraints.len,capacity: capacity,
      length: copyAuditExpressions([length])[0],limbs: copyAuditExpressions(limbs),
      outputs: copyAuditExpressions(outputs),lengthRange: lengthRange)

when defined(zkbuildPermutationAudit):
  proc recordPermutation*(c: var Circuit, firstWire, firstGate: int,
      inputs, outputs: openArray[Linear]) =
    c.permutationRecords.add PermutationRecord(firstWire: firstWire,lastWire: c.values.len,
      firstGate: firstGate,lastGate: c.constraints.len,capacity: inputs.len,
      inputs: copyAuditExpressions(inputs),outputs: copyAuditExpressions(outputs))

when defined(zkbuildTokenAudit):
  proc snapshotRangeUse*(c: Circuit): RangeUseAudit =
    proc copyRecord(record: GadgetRecord): GadgetRecord =
      result = record
      result.inputs = copyAuditExpressions(record.inputs)
      result.outputs = copyAuditExpressions(record.outputs)
    result.call = copyRecord(c.gadgets[^1])
    if result.call.kind == gkReusedUnsigned:
      result.hasSource = true
      result.source = copyRecord(c.gadgets[result.call.reference])
  proc recordToken*(c: var Circuit, token: TokenAudit) =
    var saved = token
    saved.lastWire = c.values.len
    saved.lastGate = c.constraints.len
    let fields = copyAuditExpressions([token.activeMode,token.position,token.expected,token.length,token.sourceLength])
    saved.activeMode = fields[0]
    saved.position = fields[1]
    saved.expected = fields[2]
    saved.length = fields[3]
    saved.sourceLength = fields[4]
    c.tokenRecords.add saved

when defined(zkbuildLookupAudit):
  proc recordLookup*(c: var Circuit, record: LookupAudit) =
    var saved = record
    saved.lastWire = c.values.len
    saved.lastGate = c.constraints.len
    saved.input = copyAuditExpressions([record.input])[0]
    saved.outputs = copyAuditExpressions(record.outputs)
    c.lookupRecords.add saved

when defined(zkbuildByteMemoryAudit):
  proc recordBinaryReadMemory*(c: var Circuit, sourceIndex, memoryIndex: int, queries: openArray[Linear]) =
    c.binaryReadMemoryRecords.add BinaryReadMemoryAudit(sourceIndex: sourceIndex,memoryIndex: memoryIndex,
      queries: copyAuditExpressions(queries))

when defined(zkbuildMemoryAudit):
  proc latestMemoryRange*(c: Circuit): MemoryRangeAudit =
    var source = c.gadgets[^1]
    if source.kind == gkReusedUnsigned: source = c.gadgets[source.reference]
    if source.kind notin {gkUnsigned,gkLiteralUnsigned}:
      raise newException(ValueError,"memory audit requires a range certificate")
    MemoryRangeAudit(kind: ord(source.kind),firstWire: source.firstWire,lastWire: source.lastWire,
      firstGate: source.firstGate,lastGate: source.lastGate)

  proc recordMemoryAccess*(c: var Circuit, firstGate: int, fields: openArray[Linear],
      address, value: MemoryRangeAudit) =
    c.memoryAccessRecords.add MemoryAccessAudit(firstGate: firstGate,lastGate: c.constraints.len,
      fields: copyAuditExpressions(fields),address: address,value: value)

proc initCircuit*(reuseRangeWitnesses = false): Circuit =
  Circuit(values: @[scalar(1)], reuseRangeWitnesses: reuseRangeWitnesses)
func constant*(x: SomeInteger): Linear = @[Term(wire: 0, coefficient: scalar(x))]
func wire*(index: int): Linear = @[Term(wire: index, coefficient: scalar(1))]
func `+`*(a, b: Linear): Linear = a & b
func scale*(a: Linear, coefficient: Scalar): Linear =
  for t in a: result.add Term(wire: t.wire, coefficient: t.coefficient * coefficient)
func `-`*(a, b: Linear): Linear = a + b.scale(scalar(-1))
func evaluate*(a: Linear, values: openArray[Scalar]): Scalar =
  for t in a: result += t.coefficient * values[t.wire]

proc allocate*(c: var Circuit, value: Scalar): Linear =
  result = wire(c.values.len)
  c.values.add value

proc publicInput*(c: var Circuit, value: Scalar): Linear =
  if c.values.len != c.publicCount + 1:
    raise newException(ValueError, "public inputs must precede private wires")
  inc c.publicCount
  c.allocate(value)

proc constrain*(c: var Circuit, a, b, value: Linear) =
  c.constraints.add R1Constraint(a: a, b: b, c: value)

proc assertEqual*(c: var Circuit, a, b: Linear) =
  let audit = c.auditBegin()
  c.constrain(a - b, constant(1), constant(0))
  discard c.auditFinish(audit,gkEquality,[a,b],[])

proc multiply*(c: var Circuit, a, b: Linear): Linear =
  let audit = c.auditBegin()
  result = c.allocate(a.evaluate(c.values) * b.evaluate(c.values))
  c.constrain(a, b, result)
  discard c.auditFinish(audit,gkMultiply,[a,b],[result])

proc materialize*(c: var Circuit, expression: Linear): Linear =
  ## Keep running accumulators linear in size without depending on values.
  let audit = c.auditBegin()
  result = c.allocate(expression.evaluate(c.values))
  c.assertEqual(result, expression)
  discard c.auditFinish(audit,gkMaterialize,[expression],[result])

proc bit*(c: var Circuit, value: bool): Linear =
  let audit = c.auditBegin()
  result = c.allocate(scalar(ord(value)))
  c.constrain(result, result - constant(1), constant(0))
  discard c.auditFinish(audit,gkBit,[],[result])

proc select*(c: var Circuit, selector, yes, no: Linear): Linear =
  ## selector must already be constrained Boolean.
  let audit = c.auditBegin()
  let product = c.multiply(selector, yes - no)
  result = no + product
  discard c.auditFinish(audit,gkSelect,[selector,yes,no],[result,product])

proc selectWire*(c: var Circuit, selector, yes, no: Linear): Linear =
  ## A fresh output keeps repeated selections from growing linear expressions.
  ## The selector must already be constrained Boolean.
  let audit = c.auditBegin()
  result = c.allocate(no.evaluate(c.values) + selector.evaluate(c.values) *
    (yes.evaluate(c.values) - no.evaluate(c.values)))
  c.constrain(selector, yes - no, result - no)
  discard c.auditFinish(audit,gkSelectWire,[selector,yes,no],[result])

proc satisfied*(c: Circuit): bool =
  if c.values.len == 0 or not c.values[0].equals(scalar(1)): return false
  for gate in c.constraints:
    for side in [gate.a, gate.b, gate.c]:
      for t in side:
        if t.wire < 0 or t.wire >= c.values.len: return false
    if not (gate.a.evaluate(c.values) * gate.b.evaluate(c.values)).equals(
        gate.c.evaluate(c.values)):
      return false
  true

func sameShape*(a, b: Circuit): bool =
  if a.publicCount != b.publicCount or a.values.len != b.values.len or
      a.constraints.len != b.constraints.len: return false
  for i in 0 ..< a.constraints.len:
    for pair in [(a.constraints[i].a, b.constraints[i].a),
                 (a.constraints[i].b, b.constraints[i].b),
                 (a.constraints[i].c, b.constraints[i].c)]:
      if pair[0].len != pair[1].len: return false
      for j in 0 ..< pair[0].len:
        if pair[0][j].wire != pair[1][j].wire or
            not pair[0][j].coefficient.equals(pair[1][j].coefficient): return false
  true

when defined(zkbuildSegmentPayloadAudit) and not defined(zkbuildScalarPayloadAudit):
  {.error: "zkbuildSegmentPayloadAudit requires scalar payload audit dependencies".}

when defined(zkbuildModuleContextAudit) and not defined(zkbuildSegmentPayloadAudit):
  {.error: "zkbuildModuleContextAudit requires segment payload audit dependencies".}

when defined(zkbuildBodySourceAudit) and not defined(zkbuildModuleContextAudit):
  {.error: "zkbuildBodySourceAudit requires module context audit dependencies".}

when defined(zkbuildBodySourceAudit):
  proc beginSourceProgram*(c: var Circuit): SourceProgramMarker =
    result = SourceProgramMarker(firstGate: c.constraints.len,firstPrimitive: c.gadgets.len,
      firstBlock: c.sourceProgramBlocks.len,parentActive: c.sourceProgramActive)
    c.sourceProgramActive = true
  proc endSourceProgram*(c: var Circuit, marker: SourceProgramMarker): SourceProgramAudit =
    if not c.sourceProgramActive: raise newException(ValueError,"missing source audit program")
    c.sourceProgramActive = marker.parentActive
    result.program.firstGate = marker.firstGate
    result.program.lastGate = c.constraints.len
    # Certified helpers are atomic: retain only primitives outside their
    # spans, rather than serializing their already-certified internals again.
    var i = marker.firstPrimitive
    var blockIndex = marker.firstBlock
    while i < c.gadgets.len:
      if blockIndex < c.sourceProgramBlocks.len and c.sourceProgramBlocks[blockIndex].firstPrimitive == i:
        var value = c.sourceProgramBlocks[blockIndex]
        if value.lastPrimitive <= i: raise newException(ValueError,"empty source helper")
        i = value.lastPrimitive
        value.firstPrimitive = result.program.primitives.len
        value.lastPrimitive = value.firstPrimitive
        result.blocks.add value
        inc blockIndex
      else:
        var use = RangeUseAudit(call: c.gadgets[i])
        use.call.inputs = copyAuditExpressions(use.call.inputs)
        use.call.outputs = copyAuditExpressions(use.call.outputs)
        if use.call.kind == gkReusedUnsigned:
          use.hasSource = true
          use.source = c.gadgets[use.call.reference]
          use.source.inputs = copyAuditExpressions(use.source.inputs)
          use.source.outputs = copyAuditExpressions(use.source.outputs)
        result.program.primitives.add use
        inc i
    if blockIndex != c.sourceProgramBlocks.len:
      raise newException(ValueError,"source helper spans overlap or extend past their program")
    if marker.parentActive: c.sourceProgramBlocks.setLen(marker.firstBlock)

when defined(zkbuildInstructionSourceAudit) and not defined(zkbuildBodySourceAudit):
  {.error: "zkbuildInstructionSourceAudit requires body-source audit dependencies".}

when defined(zkbuildValidationEventAudit) and not defined(zkbuildInstructionSourceAudit):
  {.error: "zkbuildValidationEventAudit requires instruction-source audit dependencies".}

when defined(zkbuildDynamicTypingAudit) and not defined(zkbuildValidationEventAudit):
  {.error: "zkbuildDynamicTypingAudit requires validation-event audit dependencies".}

when defined(zkbuildStructuredControlAudit) and not defined(zkbuildDynamicTypingAudit):
  {.error: "zkbuildStructuredControlAudit requires dynamic-typing audit dependencies".}

when defined(zkbuildStructuredControlAudit):
  proc captureFrames*[T](frames: T): seq[seq[Linear]] =
    for i,r in frames.source:
      let f = frames.flags[i]
      result.add copyAuditExpressions([r.token,r.kind,r.descriptor,r.index,r.isType,r.isFunction,r.isEmpty,r.isValue,
        f.blockOp,f.loopOp,f.ifOp,f.elseOp,f.endOp,f.tryOp,f.brOp,f.brIfOp,f.returnOp,
        f.opening,f.branching,f.closing,f.control,frames.rootPush[i]])
  proc captureTypingQueries*[T](queries: T,branch = false): seq[seq[Linear]] =
    for i,m in queries.metadata:
      let a = queries.indexed.lengths[if branch: i else: 2*i]
      let b = queries.indexed.members[if branch: i else: 2*i]
      let s = queries.indexed.singletons[i]
      var row = copyAuditExpressions([m.active,m.address,m.value,a.active,a.address,a.value,b.active,b.address,b.value,
        s.active,s.address,s.value])
      if not branch:
        let l = queries.indexed.lengths[2*i+1]
        let n = queries.indexed.members[2*i+1]
        row.add copyAuditExpressions([l.active,l.address,l.value,n.active,n.address,n.value])
      result.add row

when defined(zkbuildDynamicTypingAudit):
  proc captureVariableSelectors*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows:
      result.add copyAuditExpressions([r.localGet,r.localSet,r.localTee,r.globalGet,r.globalSet,
        r.tableGet,r.tableSet,r.tableGrow,r.tableSize,r.tableFill,r.local,r.global,r.table,r.present])

when defined(zkbuildValidationEventAudit):
  proc captureOperandRows*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows:
      result.add copyAuditExpressions([r.kind,r.functionIndex,r.height,r.floor,r.valueType,r.polymorphic,r.unreachable])
  proc captureControlRows*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows:
      result.add copyAuditExpressions([r.operand.kind,r.operand.functionIndex,r.operand.height,r.operand.floor,
        r.operand.valueType,r.operand.polymorphic,r.operand.unreachable,r.depth])
  proc captureInstructionRows*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows:
      result.add copyAuditExpressions([r.control.operand.kind,r.control.operand.functionIndex,r.control.operand.height,
        r.control.operand.floor,r.control.operand.valueType,r.control.operand.polymorphic,r.control.operand.unreachable,
        r.control.depth,r.opcode,r.pc])
  proc captureEventFlags*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows:
      result.add copyAuditExpressions([r.functionBegin,r.instructionBegin,r.operandPush,r.operandPop,r.controlPush,
        r.controlPop,r.clear,r.instructionEnd,r.functionEnd,r.labelCheck,r.padding])
  proc captureEventAccesses*[T](rows: openArray[T]): seq[seq[Linear]] =
    for r in rows: result.add copyAuditExpressions([r.active,r.write,r.address,r.value])
