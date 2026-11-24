import SignatureFunctionComplete

set_option autoImplicit false

namespace ZkBuild.ImportMatrix
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix

structure NameUse where
  heads : Nat
  query : Entry
  cursor : Linear
  deriving Inhabited
structure Read where
  token : Nat
  cursor : Linear
  deriving Inhabited
structure Row where
  firstGate : Nat
  lastGate : Nat
  typeZeroStart : Nat
  limitHeads : Nat
  zeroStarts : List Nat
  active : Linear
  kind : Linear
  objectIndex : Linear
  kindRange : RangeUse.Record
  objectRange : RangeUse.Record
  indicators : List Linear
  counts : List Linear
  typeQuery : Entry
  objectQuery : Entry
  limitQueries : List Entry
  names : List NameUse
  reads : List Read
  deriving Inhabited
structure Record where
  closeStart : Nat
  closeEnd : Nat
  tables : List Nat
  exportCount : Linear
  importedFunctions : Linear
  importedTables : Linear
  importedMemories : Linear
  importedGlobals : Linear
  rows : List Row
  deriving Inhabited

def readAt (r : Row) (i : Nat) := r.reads.getD i default
def nameAt (r : Row) (i : Nat) := r.names.getD i default
def limitAt (r : Row) (i : Nat) := r.limitQueries.getD i default

def nameGates (splits : Splits) (r : NameUse) (enabled index cursor : Linear) : List Gate :=
  [queryGate enabled index r.query]++splitGates (split splits r.heads)++
  [gate enabled (sub cursor (split splits r.heads).low), selectGate enabled (split splits r.heads).high cursor r.cursor]
def readGates (tokens : Tokens) (r : Read) (active expected cursor : Linear) : List Gate :=
  let t := token tokens r.token
  [mulGate active expected t.value]++BinaryTokenMatrix.gates t++[eqGate r.cursor (cursor++t.length)]
def indicatorGates (r : Row) (i : Nat) : List Gate :=
  let start := r.zeroStarts.getD i 0
  zeroGates (if i = 0 then r.kind else sub r.kind (n i)) (wire start) (wire (start+1))++[mulGate r.active (wire start) (get r.indicators i)]
def objectTag (r : Row) := sub r.objectQuery.value (scale ((RangeUse.bits r.objectRange).getD 3 z) 8)
def typeByte (r : Row) := sub (sub (n 127) (objectTag r)) (scale (wire r.typeZeroStart++wire (r.typeZeroStart+2)) 10)
def rowParts (tokens : Tokens) (splits : Splits) (exportCount : Linear) (r : Row) (index : Nat)
    (cursor : Linear) (counts : List Linear) (previous : Linear) : List (List Gate) :=
  let f := get r.indicators 0
  let t := get r.indicators 1
  let m := get r.indicators 2
  let g := get r.indicators 3
  let limits := split splits r.limitHeads
  [[boolGate r.active,gate r.active (sub o previous)],
   nameGates splits (nameAt r 0) r.active (exportCount++n (2*index)) cursor,
   nameGates splits (nameAt r 1) r.active (exportCount++n (2*index+1)) (nameAt r 0).cursor,
   RangeUse.gates r.kindRange++[gate (sub o r.active) r.kind]++
     readGates tokens (readAt r 0) r.active r.kind (nameAt r 1).cursor,
   (List.range 4).flatMap (indicatorGates r),
   [queryGate f (scale (get counts 0) 2) r.typeQuery]++readGates tokens (readAt r 1) f r.typeQuery.value (readAt r 0).cursor,
   [selectGate g (get counts 3) (get counts 1) r.objectIndex,
    queryGate (g++t) (scale r.objectIndex 2++t) r.objectQuery]++RangeUse.gates r.objectRange++
     zeroGates (sub (objectTag r) (n 5)) (wire r.typeZeroStart) (wire (r.typeZeroStart+1))++
     zeroGates (sub (objectTag r) (n 6)) (wire (r.typeZeroStart+2)) (wire (r.typeZeroStart+3))++
     readGates tokens (readAt r 2) (g++t) (typeByte r) (readAt r 1).cursor++
     readGates tokens (readAt r 3) g ((RangeUse.bits r.objectRange).getD 3 z) (readAt r 2).cursor,
   [queryGate m (get counts 2) (limitAt r 0),queryGate m (get counts 2) (limitAt r 1),
    queryGate t (get counts 1) (limitAt r 2),queryGate t (get counts 1) (limitAt r 3)]++splitGates limits++
     readGates tokens (readAt r 4) (m++t) ((limitAt r 1).value++(limitAt r 3).value) (readAt r 3).cursor++
     readGates tokens (readAt r 5) (m++t) limits.low (readAt r 4).cursor++
     readGates tokens (readAt r 6) ((limitAt r 1).value++(limitAt r 3).value) limits.high (readAt r 5).cursor,
   [eqGate (get r.counts 0) (get counts 0++f),eqGate (get r.counts 1) (get counts 1++t),
    eqGate (get r.counts 2) (get counts 2++m),eqGate (get r.counts 3) (get counts 3++g)]]
def rowGates (tokens : Tokens) (splits : Splits) (exportCount : Linear) (r : Row) (index : Nat)
    (cursor : Linear) (counts : List Linear) (previous : Linear) :=
  (rowParts tokens splits exportCount r index cursor counts previous).flatten

def nameMatches (splits : Splits) (r : NameUse) (active : Linear) : Prop :=
  r.heads < splits.length ∧ splitMatches (split splits r.heads) r.query.value 32 32 ∧ r.query.active = active
def readMatches (tokens : Tokens) (r : Read) (kind : Nat) (active cursor : Linear) : Prop :=
  r.token < tokens.length ∧ (token tokens r.token).kind = kind ∧
    (token tokens r.token).activeMode = active ∧ (token tokens r.token).position = cursor
instance (splits : Splits) (r : NameUse) (active : Linear) : Decidable (nameMatches splits r active) := by
  unfold nameMatches
  infer_instance
instance (tokens : Tokens) (r : Read) (kind : Nat) (active cursor : Linear) : Decidable (readMatches tokens r kind active cursor) := by
  unfold readMatches
  infer_instance

def shape (tokens : Tokens) (splits : Splits) (r : Row) (cursor : Linear) : Prop :=
  r.names.length = 2 ∧ r.reads.length = 7 ∧ r.zeroStarts.length = 4 ∧ r.indicators.length = 4 ∧ r.counts.length = 4 ∧ r.limitQueries.length = 4 ∧
  nameMatches splits (nameAt r 0) r.active ∧ nameMatches splits (nameAt r 1) r.active ∧
  readMatches tokens (readAt r 0) 0 r.active (nameAt r 1).cursor ∧
  readMatches tokens (readAt r 1) 1 (get r.indicators 0) (readAt r 0).cursor ∧
  readMatches tokens (readAt r 2) 0 (get r.indicators 3++get r.indicators 1) (readAt r 1).cursor ∧
  readMatches tokens (readAt r 3) 0 (get r.indicators 3) (readAt r 2).cursor ∧
  readMatches tokens (readAt r 4) 0 (get r.indicators 2++get r.indicators 1) (readAt r 3).cursor ∧
  readMatches tokens (readAt r 5) 1 (get r.indicators 2++get r.indicators 1) (readAt r 4).cursor ∧
  readMatches tokens (readAt r 6) 1 ((limitAt r 1).value++(limitAt r 3).value) (readAt r 5).cursor ∧
  r.typeQuery.active = get r.indicators 0 ∧ r.objectQuery.active = get r.indicators 3++get r.indicators 1 ∧
  (limitAt r 0).active = get r.indicators 2 ∧ (limitAt r 1).active = get r.indicators 2 ∧
  (limitAt r 2).active = get r.indicators 1 ∧ (limitAt r 3).active = get r.indicators 1 ∧
  r.limitHeads < splits.length ∧ splitMatches (split splits r.limitHeads) ((limitAt r 0).value++(limitAt r 2).value) 32 32
instance (tokens : Tokens) (splits : Splits) (r : Row) (cursor : Linear) : Decidable (shape tokens splits r cursor) := by
  unfold shape
  infer_instance

def checkRow (matrix : Shape) (tokens : Tokens) (splits : Splits) (exportCount : Linear) (r : Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear) : Bool :=
  decide (shape tokens splits r cursor) && RangeUse.check matrix r.kindRange r.kind 2 &&
    RangeUse.check matrix r.objectRange r.objectQuery.value 4 &&
    MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (rowGates tokens splits exportCount r index cursor counts previous)
def checkRows (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) : List Row → Nat → Linear → List Linear → Linear → Bool
  | [],_,_,_,_ => true
  | r::rest,index,cursor,counts,previous => checkRow matrix tokens splits exports r index cursor counts previous &&
      checkRows matrix tokens splits exports rest (index+1) (readAt r 6).cursor r.counts r.active

def final : List Row → Linear → List Linear → Linear × List Linear
  | [],cursor,counts => (cursor,counts)
  | r::rest,_,_ => final rest (readAt r 6).cursor r.counts
def total (rows : List Row) : Linear := z++rows.flatMap Row.active

def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.tables.getD i 0) default
def inTable (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) (q : Entry) : Prop := q ∈ (table tables r i).queries
def links (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record) (r : Record) : Prop :=
  r.tables.length = 7 ∧ (∀ i ∈ r.tables, i < tables.length) ∧
  (table tables r 2).entries = signature.metadata.map SignatureMatrix.indexEntry ∧
  (∀ row ∈ r.rows, (∀ name ∈ row.names, inTable tables r 0 name.query) ∧ inTable tables r 1 row.objectQuery ∧
    inTable tables r 2 row.typeQuery ∧ ∀ i < 4, inTable tables r (3+i) (limitAt row i)) ∧
  ((table tables r 2).memory.addressBits = 33 ∧ (table tables r 2).memory.valueBits = 32)
instance (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record) (r : Record) : Decidable (links tables signature r) := by
  unfold links inTable
  infer_instance

def closeGates (body : ModuleAuditIO.SourceEnvelope) (r : Record) : List Gate :=
    [eqGate (final r.rows (get body.envelope.outputs 10) [z,z,z,z]).1 (get body.envelope.outputs 11),
     eqGate (get (final r.rows (get body.envelope.outputs 10) [z,z,z,z]).2 0) r.importedFunctions,
     eqGate (get (final r.rows (get body.envelope.outputs 10) [z,z,z,z]).2 1) r.importedTables,
     eqGate (get (final r.rows (get body.envelope.outputs 10) [z,z,z,z]).2 2) r.importedMemories,
     eqGate (get (final r.rows (get body.envelope.outputs 10) [z,z,z,z]).2 3) r.importedGlobals,
     eqGate (total r.rows) (get body.envelope.outputs 9)]

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) (r : Record) : Bool :=
  decide (r.rows.length < 2^32 ∧ r.importedFunctions = space.importedFunctions ∧ links tables signature r) &&
  checkRows matrix body.tokens splits r.exportCount r.rows 0 (get body.envelope.outputs 10) [z,z,z,z] o &&
  MemoryEvidence.checkSpan matrix r.closeStart r.closeEnd (closeGates body r)

end ZkBuild.ImportMatrix
