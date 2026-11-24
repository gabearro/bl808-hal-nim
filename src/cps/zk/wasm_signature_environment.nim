## Shared immutable type lists. Zero is nil; each nonzero node stores a known
## type tag and a strictly smaller next-node ID. No probabilistic hash is used.
## Function/type metadata and list cells still require raw WASM byte binding.
import std/[tables, algorithm]
import r1cs, range_check, read_only_memory, memory_consistency, packed_fields
import wasm_instruction_events, wasm_type_environment
import ../wasm/[types, validate, variable_typing]

type
  SignatureEnvironment* = object
    signatures*, nodes*: seq[ReadOnlyEntry]
    typeIndices*: seq[uint32] # function entries only; type/padding entries are zero
    singletons*: array[7, uint32]
    reversals*: seq[ReadOnlyEntry] # Optional exact orientation cache for catch typing.
  SignatureEnvironmentWires* = object
    signatures*, nodes*: seq[ReadOnlyWires]
    typeIndices*: seq[Linear]
  SignatureEnvironmentWitness* = object
    metadataQueries*, operandQueries*, references*, tableQueries*: seq[ReadOnlyEntry]
    metadata*, nodes*, tables*: MemoryWitness

func functionSignatureAddress*(index: uint32): uint64 = uint64(index)*2
func typeSignatureAddress*(index: uint32): uint64 = uint64(index)*2+1
func isCallCode*(code: uint16): bool = code in 0x10'u16..0x13'u16

proc buildSignatureEnvironment*(module: WasmModule, signatureCapacity = 0,
    nodeCapacity = 0, maxNodes = 1_048_576, includeSingletons = false,
    includeReversals = false, reversalCapacity = 0): SignatureEnvironment =
  if signatureCapacity < 0 or nodeCapacity < 0 or maxNodes < 0 or
      reversalCapacity < 0 or module.funcTypeIdxs.len != module.codes.len or uint64(module.types.len) > uint64(high(uint32)):
    raise newException(ValueError, "invalid signature environment dimensions")
  var functionTypes: seq[uint32]
  for item in module.imports:
    if item.kind == ikFunc: functionTypes.add item.funcTypeIdx
  functionTypes.add module.funcTypeIdxs
  if uint64(functionTypes.len) > uint64(high(uint32)):
    raise newException(ValueError, "function signature index overflow")
  var interned: Table[tuple[tag: uint8, next: uint32], uint32]
  template cons(valueType: ValType, cursor: var uint32) =
    let key = (stackTypeTag(valueType), cursor)
    if interned.hasKey(key): cursor = interned[key]
    else:
      if result.nodes.len >= maxNodes or uint64(result.nodes.len) >= uint64(high(uint32)):
        raise newException(ValueError, "signature node capacity exceeded")
      let id = uint32(result.nodes.len+1)
      result.nodes.add ReadOnlyEntry(active: true, address: uint64(id),
        value: uint64(key[0])+(uint64(cursor) shl 3))
      interned[key] = id
      cursor = id
  var metadata: seq[uint64]
  for signature in module.types:
    var params, results: uint32
    # Parameters are consumed top-first; results are produced in source order.
    for valueType in signature.params: cons(valueType, params)
    for i in countdown(signature.results.high, 0): cons(signature.results[i], results)
    metadata.add uint64(params)+(uint64(results) shl 32)
  if includeSingletons:
    for valueType in [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]:
      var singleton = 0'u32
      cons(valueType, singleton)
      result.singletons[int(stackTypeTag(valueType))] = singleton
  if includeReversals:
    var reverse: Table[uint32, uint32]
    reverse[0] = 0
    for i, signature in module.types:
      var params, results: uint32
      for j in countdown(signature.params.high, 0): cons(signature.params[j], params)
      for value in signature.results: cons(value, results)
      let p = uint32(metadata[i] and 0xffffffff'u64)
      let r = uint32(metadata[i] shr 32)
      reverse[p] = params; reverse[params] = p
      reverse[r] = results; reverse[results] = r
    if includeSingletons:
      for head in result.singletons: reverse[head] = head
    var ordered: seq[uint32]
    for head in reverse.keys: ordered.add head
    ordered.sort()
    for head in ordered:
      result.reversals.add ReadOnlyEntry(active: true, address: uint64(head), value: uint64(reverse[head]))
    if reversalCapacity != 0:
      if result.reversals.len > reversalCapacity: raise newException(ValueError, "signature reversal profile overflow")
      result.reversals.setLen(reversalCapacity)
  for i in 0..<max(functionTypes.len, metadata.len):
    if i < functionTypes.len:
      let tid = functionTypes[i]
      if uint64(tid) >= uint64(metadata.len): raise newException(ValueError, "invalid function signature type")
      result.signatures.add ReadOnlyEntry(active: true, address: functionSignatureAddress(uint32(i)), value: metadata[int(tid)])
      result.typeIndices.add tid
    if i < metadata.len:
      result.signatures.add ReadOnlyEntry(active: true, address: typeSignatureAddress(uint32(i)), value: metadata[i])
      result.typeIndices.add 0
  if signatureCapacity != 0:
    if result.signatures.len > signatureCapacity: raise newException(ValueError, "signature table profile overflow")
    result.signatures.setLen(signatureCapacity)
    result.typeIndices.setLen(signatureCapacity)
  if nodeCapacity != 0:
    if result.nodes.len > nodeCapacity: raise newException(ValueError, "signature node profile overflow")
    result.nodes.setLen(nodeCapacity)

proc tableMap(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc referenceQuery(id: uint64, nodes: Table[uint64, uint64]): ReadOnlyEntry =
  if id != 0: result = ReadOnlyEntry(active: true, address: id, value: nodes.getOrDefault(id))

proc buildSignatureWitness*(environment: SignatureEnvironment, objects: openArray[ReadOnlyEntry],
    rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32]): SignatureEnvironmentWitness =
  if rows.len != primary.len or rows.len != secondary.len or
      environment.signatures.len != environment.typeIndices.len:
    raise newException(ValueError, "signature witness dimensions differ")
  let signatures = tableMap(environment.signatures)
  let nodes = tableMap(environment.nodes)
  let objectMap = tableMap(objects)
  var origins: seq[ReadOnlyEntry]
  for i, entry in environment.signatures:
    if entry.active:
      result.references.add referenceQuery(entry.value and 0xffffffff'u64, nodes)
      result.references.add referenceQuery(entry.value shr 32, nodes)
    else:
      result.references.add ReadOnlyEntry()
      result.references.add ReadOnlyEntry()
    origins.add(if entry.active and (entry.address and 1) == 0:
      ReadOnlyEntry(active: true, address: typeSignatureAddress(environment.typeIndices[i]), value: entry.value)
      else: ReadOnlyEntry())
  for entry in environment.nodes:
    result.references.add(if entry.active: referenceQuery(entry.value shr 3, nodes) else: ReadOnlyEntry())
  result.metadataQueries.setLen(rows.len)
  result.operandQueries.setLen(rows.len)
  result.tableQueries.setLen(rows.len)
  var params, results: uint64
  var indexPending = false
  for i, row in rows:
    let kind = row.control.operand.kind
    let call = isCallCode(row.opcode)
    let indirect = row.opcode in [0x11'u16, 0x13]
    if kind in [uint8(ord(veFunctionBegin)), uint8(ord(veInstructionBegin))]:
      params = 0
      results = 0
      indexPending = false
      if kind == uint8(ord(veFunctionBegin)) or call:
        let address = if kind == uint8(ord(veFunctionBegin)):
          functionSignatureAddress(row.control.operand.functionIndex)
          elif indirect: typeSignatureAddress(primary[i]) else: functionSignatureAddress(primary[i])
        let value = signatures.getOrDefault(address)
        result.metadataQueries[i] = ReadOnlyEntry(active: true, address: address, value: value)
        params = value and 0xffffffff'u64
        results = value shr 32
        indexPending = call and indirect
        if call and indirect:
          let tableAddress = tableTypeAddress(secondary[i])
          result.tableQueries[i] = ReadOnlyEntry(active: true, address: tableAddress,
            value: objectMap.getOrDefault(tableAddress))
    elif call and kind == uint8(ord(veOperandPop)):
      if indexPending: indexPending = false
      else:
        result.operandQueries[i] = ReadOnlyEntry(active: true, address: params, value: nodes.getOrDefault(params))
        params = result.operandQueries[i].value shr 3
    elif call and kind == uint8(ord(veOperandPush)):
      result.operandQueries[i] = ReadOnlyEntry(active: true, address: results, value: nodes.getOrDefault(results))
      results = result.operandQueries[i].value shr 3
  result.metadata = buildReadOnlyWitness(environment.signatures, origins & result.metadataQueries)
  result.nodes = buildReadOnlyWitness(environment.nodes, result.references & result.operandQueries)
  result.tables = buildReadOnlyWitness(objects, result.tableQueries)

proc splitSignatureHeads*(c: var Circuit, value: Linear): tuple[params, results: Linear] =
  let fields = c.splitPackedFields(value,32,32)
  (params: fields.low,results: fields.high)

proc splitSignatureNode*(c: var Circuit, value: Linear): tuple[tag, next: Linear] =
  let fields = c.splitPackedFields(value,3,32)
  (tag: fields.low,next: fields.high)

proc constrainReference(c: var Circuit, enabled, id: Linear, value: uint64): ReadOnlyWires =
  result.active = c.multiply(enabled, constant(1)-c.zeroIndicator(id))
  result.address = c.multiply(result.active, id)
  result.value = c.allocate(scalar(value))

proc constrainSignatureEnvironment*(c: var Circuit, environment: SignatureEnvironmentWires,
    metadataQueries, operandQueries: openArray[ReadOnlyWires], witness: SignatureEnvironmentWitness) =
  if environment.signatures.len != environment.typeIndices.len or
      witness.references.len != 2*environment.signatures.len+environment.nodes.len:
    raise newException(ValueError, "signature environment circuit dimensions differ")
  var metadata, references: seq[ReadOnlyWires]
  when defined(zkbuildSignatureAudit):
    var audit = SignatureAudit()
  var position = 0
  for i, entry in environment.signatures:
    when defined(zkbuildSignatureAudit):
      var item = SignatureMetadataAudit(firstGate: c.constraints.len,heads: c.packedRecords.len,
        entry: copyAuditExpressions([entry.active,entry.address,entry.value]),
        typeIndex: copyAuditExpressions([environment.typeIndices[i]])[0])
    let heads = c.splitSignatureHeads(entry.value)
    when defined(zkbuildSignatureAudit):
      var refZero = c.values.len
    references.add c.constrainReference(entry.active, heads.params, witness.references[position].value)
    when defined(zkbuildSignatureAudit):
      let paramRef = references[^1]
      item.references.add SignatureReferenceAudit(zeroStart: refZero,query: copyAuditExpressions([paramRef.active,paramRef.address,paramRef.value]))
      refZero = c.values.len
    references.add c.constrainReference(entry.active, heads.results, witness.references[position+1].value)
    when defined(zkbuildSignatureAudit):
      let resultRef = references[^1]
      item.references.add SignatureReferenceAudit(zeroStart: refZero,query: copyAuditExpressions([resultRef.active,resultRef.address,resultRef.value]))
    position += 2
    let addressBits = c.constrainUnsigned(entry.address, 33)
    when defined(zkbuildSignatureAudit): item.addressRange = c.snapshotRangeUse()
    let functionEntry = c.multiply(entry.active, constant(1)-addressBits[0])
    discard c.constrainUnsigned(environment.typeIndices[i], 32)
    when defined(zkbuildSignatureAudit): item.typeIndexRange = c.snapshotRangeUse()
    c.constrain(constant(1)-functionEntry, environment.typeIndices[i], constant(0))
    metadata.add ReadOnlyWires(active: functionEntry,
      address: c.multiply(functionEntry, environment.typeIndices[i].scale(scalar(2))+constant(1)),
      value: c.multiply(functionEntry, entry.value))
    when defined(zkbuildSignatureAudit):
      let originQuery = metadata[^1]
      item.origin = copyAuditExpressions([originQuery.active,originQuery.address,originQuery.value])
      item.functionEntry = copyAuditExpressions([functionEntry])[0]
      item.lastGate = c.constraints.len
      audit.metadata.add item
  for entry in environment.nodes:
    when defined(zkbuildSignatureAudit):
      var item = SignatureNodeAudit(firstGate: c.constraints.len,node: c.packedRecords.len,
        entry: copyAuditExpressions([entry.active,entry.address,entry.value]))
    let node = c.splitSignatureNode(entry.value)
    when defined(zkbuildSignatureAudit): item.tagZero = c.values.len
    c.assertEqual(c.zeroIndicator(node.tag-constant(7)), constant(0))
    let delta = c.selectWire(entry.active, entry.address-node.next-constant(1), constant(0))
    discard c.constrainUnsigned(delta, 32)
    when defined(zkbuildSignatureAudit):
      item.delta = copyAuditExpressions([delta])[0]
      item.deltaRange = c.snapshotRangeUse()
      item.reference.zeroStart = c.values.len
    references.add c.constrainReference(entry.active, node.next, witness.references[position].value)
    when defined(zkbuildSignatureAudit):
      let q = references[^1]
      item.reference.query = copyAuditExpressions([q.active,q.address,q.value])
      item.lastGate = c.constraints.len
      audit.nodes.add item
    inc position
  metadata.add @metadataQueries
  references.add @operandQueries
  when defined(zkbuildSignatureAudit):
    for q in metadataQueries: audit.extraMetadata.add copyAuditExpressions([q.active,q.address,q.value])
    for q in operandQueries: audit.extraOperands.add copyAuditExpressions([q.active,q.address,q.value])
    audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.signatures, metadata, witness.metadata, 33, 64)
  when defined(zkbuildSignatureAudit): audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.nodes, references, witness.nodes, 32, 35)
  when defined(zkbuildSignatureAudit): c.signatureRecords.add audit
