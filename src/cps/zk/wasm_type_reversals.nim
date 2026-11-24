## Exact list orientation cache. Establish reversal once per declared vector,
## then catch clauses compare list heads instead of repeating payload walks.
## Requires the shared indexed-signature relation on these same tables.
import std/tables
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_signature_environment, wasm_indexed_signatures

type TypeReversalWitness* = object
  reverseLengths*, memberReversals*, memberLengths*, reverseMembers*: seq[ReadOnlyEntry]
  reversals*, lengths*, members*: MemoryWitness

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc query(active: bool, address: uint64, values: Table[uint64, uint64]): ReadOnlyEntry =
  if active: ReadOnlyEntry(active: true, address: address, value: values.getOrDefault(address)) else: ReadOnlyEntry()

proc buildTypeReversalWitness*(reversals: openArray[ReadOnlyEntry], indexed: IndexedSignatureEnvironment): TypeReversalWitness =
  let reverse = contents(reversals)
  let lengths = contents(indexed.lengths)
  let members = contents(indexed.members)
  for entry in reversals:
    result.reverseLengths.add query(entry.active, entry.value, lengths)
  for entry in indexed.members:
    let head = entry.address shr 32
    let ordinal = entry.address and 0xffffffff'u64
    let length = lengths.getOrDefault(head)
    let target = reverse.getOrDefault(head)
    let opposite = if length > ordinal: length-1-ordinal else: 0'u64
    result.memberReversals.add query(entry.active, head, reverse)
    result.memberLengths.add query(entry.active, head, lengths)
    result.reverseMembers.add query(entry.active, (target shl 32)+opposite, members)
  var ownLengths: seq[ReadOnlyEntry]
  for entry in reversals: ownLengths.add query(entry.active, entry.address, lengths)
  result.reversals = buildReadOnlyWitness(reversals, result.memberReversals)
  result.lengths = buildReadOnlyWitness(indexed.lengths, ownLengths & result.reverseLengths & result.memberLengths)
  result.members = buildReadOnlyWitness(indexed.members, result.reverseMembers)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainTypeReversals*(c: var Circuit, reversals: openArray[ReadOnlyWires],
    indexed: IndexedSignatureWires, witness: TypeReversalWitness) =
  if reversals.len != witness.reverseLengths.len or indexed.members.len != witness.memberReversals.len or
      indexed.members.len != witness.memberLengths.len or indexed.members.len != witness.reverseMembers.len:
    raise newException(ValueError, "type reversal dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var reverseQueries, ownLengths, oppositeLengths, memberLengths, memberQueries: seq[ReadOnlyWires]
  for i, entry in reversals:
    let length = c.read(entry.active, entry.value, witness.reverseLengths[i].value)
    oppositeLengths.add length
    ownLengths.add ReadOnlyWires(active: entry.active, address: entry.address, value: length.value)
  for i, entry in indexed.members:
    let key = c.splitSignatureHeads(entry.address)
    let reversed = c.read(entry.active, key.results, witness.memberReversals[i].value)
    reverseQueries.add reversed
    let length = c.read(entry.active, key.results, witness.memberLengths[i].value)
    memberLengths.add length
    let opposite = c.constrainSignatureMemberQuery(entry.active, reversed.value,
      length.value-constant(1)-key.params, witness.reverseMembers[i].value)
    memberQueries.add opposite
    let a = c.splitSignatureNode(entry.value)
    let b = c.splitSignatureNode(opposite.value)
    c.constrain(entry.active, a.tag-b.tag, constant(0))
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 8,program: c.endSourceProgram(marker))
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(reversals, reverseQueries, witness.reversals, 32, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.lengths, ownLengths & oppositeLengths & memberLengths, witness.lengths, 32, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.members, memberQueries, witness.members, 64, 35)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
