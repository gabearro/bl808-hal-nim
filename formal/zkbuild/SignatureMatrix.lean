import SourceTypeLists

namespace ZkBuild.SignatureMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix

structure Reference where
  zeroStart : Nat
  query : Entry
  deriving Inhabited

structure MetadataRow where
  firstGate : Nat
  lastGate : Nat
  heads : Nat
  entry : Entry
  typeIndex : Linear
  params : Reference
  results : Reference
  addressRange : RangeUse.Record
  typeIndexRange : RangeUse.Record
  functionEntry : Linear
  origin : Entry
  deriving Inhabited

structure NodeRow where
  firstGate : Nat
  lastGate : Nat
  node : Nat
  tagZero : Nat
  entry : Entry
  delta : Linear
  deltaRange : RangeUse.Record
  reference : Reference
  deriving Inhabited

structure Record where
  tables : List Nat
  extraMetadata : List Entry
  extraOperands : List Entry
  metadata : List MetadataRow
  nodes : List NodeRow
  deriving Inhabited

def referenceGates (enabled id : Linear) (r : Reference) : List Gate :=
  zeroGates id (wire r.zeroStart) (wire (r.zeroStart+1))++
  [mulGate enabled (sub o (wire r.zeroStart)) r.query.active,queryGate r.query.active id r.query]

def parity (r : MetadataRow) : Linear := (RangeUse.bits r.addressRange).getD 0 z
def metadataParts (splits : Splits) (r : MetadataRow) : List (List Gate) :=
  let heads := split splits r.heads
  [splitGates heads,referenceGates r.entry.active heads.low r.params,
   referenceGates r.entry.active heads.high r.results,RangeUse.gates r.addressRange,
   [mulGate r.entry.active (sub o (parity r)) r.functionEntry],RangeUse.gates r.typeIndexRange,
   [gate (sub o r.functionEntry) r.typeIndex,queryGate r.functionEntry (scale r.typeIndex 2++o) r.origin,
    mulGate r.functionEntry r.entry.value r.origin.value]]
def metadataGates (splits : Splits) (r : MetadataRow) := (metadataParts splits r).flatten
def checkMetadata (matrix : Shape) (splits : Splits) (r : MetadataRow) : Bool :=
  decide (r.heads < splits.length ∧ splitMatches (split splits r.heads) r.entry.value 32 32 ∧ r.origin.active = r.functionEntry) &&
  RangeUse.check matrix r.addressRange r.entry.address 33 && RangeUse.check matrix r.typeIndexRange r.typeIndex 32 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (metadataGates splits r)

def nodeParts (splits : Splits) (r : NodeRow) : List (List Gate) :=
  let node := split splits r.node
  [splitGates node,zeroGates (sub node.low (n 7)) (wire r.tagZero) (wire (r.tagZero+1))++[eqGate (wire r.tagZero) z],
   [selectGate r.entry.active (sub (sub r.entry.address node.high) o) z r.delta],RangeUse.gates r.deltaRange,
   referenceGates r.entry.active node.high r.reference]
def nodeGates (splits : Splits) (r : NodeRow) := (nodeParts splits r).flatten
def checkNode (matrix : Shape) (splits : Splits) (r : NodeRow) : Bool :=
  decide (r.node < splits.length ∧ splitMatches (split splits r.node) r.entry.value 3 32) &&
  RangeUse.check matrix r.deltaRange r.delta 32 && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (nodeGates splits r)

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (index : Nat) := tables.getD (r.tables.getD index 0) default
def indexEntry (r : MetadataRow) : Entry := ⟨r.entry.active,r.entry.address,r.typeIndex⟩
def checkLinks (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (r : Record) : Bool :=
  decide (r.tables.length = 2 ∧ (∀ i ∈ r.tables, i < tables.length) ∧
    (table tables r 0).entries = r.metadata.map MetadataRow.entry ∧
    (table tables r 0).queries = r.metadata.map MetadataRow.origin++r.extraMetadata ∧
    (table tables r 1).entries = r.nodes.map NodeRow.entry ∧
    (table tables r 1).queries = r.metadata.flatMap (fun m => [m.params.query,m.results.query])++r.nodes.map (fun n => n.reference.query)++r.extraOperands ∧
    r.metadata.map MetadataRow.entry = indexed.metadata.map IndexedMatrix.MetadataRow.entry ∧
    (table tables r 1).entries = (IndexedMatrix.table tables indexed 3).entries ∧
    (DeclarationMatrix.table tables declaration 5).entries = r.metadata.map indexEntry ∧
    (table tables r 0).memory.addressBits = 33 ∧ (table tables r 0).memory.valueBits = 64 ∧
    (table tables r 1).memory.addressBits = 32 ∧ (table tables r 1).memory.valueBits = 35)

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (r : Record) : Bool :=
  r.metadata.all (checkMetadata matrix splits) && r.nodes.all (checkNode matrix splits) && checkLinks tables declaration indexed r

end ZkBuild.SignatureMatrix
