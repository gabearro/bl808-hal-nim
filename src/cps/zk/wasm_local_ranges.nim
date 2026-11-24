## Authenticate sparse local-type entries against compressed declarations.
## A count of billions costs one declaration row, rather than billions of ROM
## initializers. Byte/type-declaration provenance remains a separate binding.
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_type_environment, wasm_signature_environment

type LocalRangeWitness* = object
  ranges*, types*: seq[ReadOnlyEntry]
  data*, tags*: MemoryWitness

proc buildLocalRangeWitness*(environment: TypeEnvironment): LocalRangeWitness =
  if environment.localRanges.len != environment.rangeTypes.len:
    raise newException(ValueError, "local range table dimensions differ")
  var activeCount: int
  for entry in environment.localRanges:
    if entry.active: inc activeCount
  for local in environment.locals:
    var data, tag: ReadOnlyEntry
    if local.active:
      let functionIndex = local.address shr 32
      let index = local.address and 0xffffffff'u64
      var low = 0
      var limit = activeCount
      while low < limit:
        let middle = low+(limit-low) div 2
        let entry = environment.localRanges[middle]
        let first = entry.value and 0xffffffff'u64
        let count = entry.value shr 32
        if entry.address shr 32 < functionIndex or
            (entry.address shr 32 == functionIndex and first+count <= index): low = middle+1
        else: limit = middle
      if low < activeCount:
        let entry = environment.localRanges[low]
        let first = entry.value and 0xffffffff'u64
        let count = entry.value shr 32
        if entry.address shr 32 == functionIndex and index >= first and index-first < count:
          data = ReadOnlyEntry(active: true, address: entry.address, value: entry.value)
          tag = ReadOnlyEntry(active: true, address: entry.address, value: environment.rangeTypes[low].value)
    result.ranges.add data
    result.types.add tag
  result.data = buildReadOnlyWitness(environment.localRanges, result.ranges)
  result.tags = buildReadOnlyWitness(environment.rangeTypes, result.types)

proc constrainLocalRanges*(c: var Circuit, environment: TypeEnvironmentWires, witness: LocalRangeWitness) =
  when defined(zkbuildBodySourceAudit):
    let programMarker = c.beginSourceProgram()
    var rangeAudit: LocalRangeAudit
    for row in environment.locals: rangeAudit.locals.add copyAuditExpressions([row.active,row.address,row.value])
    for row in environment.localRanges: rangeAudit.ranges.add copyAuditExpressions([row.active,row.address,row.value])
    for row in environment.rangeTypes: rangeAudit.tags.add copyAuditExpressions([row.active,row.address,row.value])
  if environment.localRanges.len != environment.rangeTypes.len or
      environment.locals.len != witness.ranges.len or environment.locals.len != witness.types.len:
    raise newException(ValueError, "local range circuit dimensions differ")
  var previousFunction, previousOrdinal, previousEnd, previousActive = constant(0)
  for i, entry in environment.localRanges:
    let tag = environment.rangeTypes[i]
    c.assertEqual(entry.active, tag.active)
    c.assertEqual(entry.address, tag.address)
    c.assertEqual(c.zeroIndicator(tag.value-constant(7)), constant(0))
    let key = c.splitSignatureHeads(entry.address)
    let span = c.splitSignatureHeads(entry.value)
    let continuing = c.multiply(previousActive, c.zeroIndicator(key.results-previousFunction))
    let same = c.multiply(entry.active, continuing)
    c.constrain(entry.active-same, key.params, constant(0))
    c.constrain(same, key.params-previousOrdinal-constant(1), constant(0))
    c.constrain(entry.active, span.params-c.multiply(continuing, previousEnd), constant(0))
    discard c.constrainUnsigned(span.params+span.results, 32)
    previousFunction = key.results
    previousOrdinal = key.params
    previousEnd = span.params+span.results
    previousActive = entry.active
  var dataQueries, tagQueries: seq[ReadOnlyWires]
  for i, local in environment.locals:
    let key = c.splitSignatureHeads(local.address)
    let selected = c.allocate(scalar(witness.ranges[i].address))
    when defined(zkbuildBodySourceAudit): rangeAudit.selected.add copyAuditExpressions([selected])[0]
    let declared = c.splitSignatureHeads(selected)
    c.constrain(local.active, declared.results-key.results, constant(0))
    let data = c.allocate(scalar(witness.ranges[i].value))
    let tag = c.allocate(scalar(witness.types[i].value))
    dataQueries.add ReadOnlyWires(active: local.active, address: c.multiply(local.active, selected), value: data)
    tagQueries.add ReadOnlyWires(active: local.active, address: c.multiply(local.active, selected), value: tag)
    let span = c.splitSignatureHeads(data)
    discard c.constrainUnsigned(c.multiply(local.active, key.params-span.params), 32)
    discard c.constrainUnsigned(c.multiply(local.active, span.params+span.results-key.params-constant(1)), 32)
    c.constrain(local.active, local.value-tag, constant(0))
  when defined(zkbuildBodySourceAudit):
    rangeAudit.program = c.endSourceProgram(programMarker)
    rangeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.localRanges, dataQueries, witness.data, 64, 64)
  when defined(zkbuildBodySourceAudit): rangeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.rangeTypes, tagQueries, witness.tags, 64, 3)

  when defined(zkbuildBodySourceAudit): c.localRangeRecords.add rangeAudit
