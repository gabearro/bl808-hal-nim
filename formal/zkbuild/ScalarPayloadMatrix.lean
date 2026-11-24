import ConstantSourceSoundness
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadMatrix
open CircuitShape GadgetShape DeclarationMatrix ImportMatrix

structure Row where
  firstGate : Nat
  lastGate : Nat
  typeZeroStart : Nat
  constantIndex : Nat
  limitHeads : Nat
  active : Linear
  objectQuery : Entry
  fields : List Linear
  objectRange : RangeUse.Record
  name : NameUse
  limits : List Entry
  reads : List Read
  deriving Inhabited
structure Record where
  rows : List (List Row)
  closeStarts : List Nat
  closeEnds : List Nat
  deriving Inhabited

def getRows (r : Record) (kind : Nat) := r.rows.getD kind []
def readAt (r : Row) (i : Nat) := r.reads.getD i default
def limitAt (r : Row) (i : Nat) := r.limits.getD i default
def constAt (constants : List ConstantSourceMatrix.Record) (r : Row) := constants.getD r.constantIndex default
def tag (kind : Nat) (r : Row) :=
  if kind = 2 then sub r.objectQuery.value (scale ((RangeUse.bits r.objectRange).getD 3 z) 8) else r.objectQuery.value
def typeByte (kind : Nat) (r : Row) :=
  sub (sub (n 127) (tag kind r)) (scale (wire r.typeZeroStart ++ wire (r.typeZeroStart+2)) 10)
def typeGates (kind : Nat) (r : Row) :=
  zeroGates (sub (tag kind r) (n 5)) (wire r.typeZeroStart) (wire (r.typeZeroStart+1)) ++
  zeroGates (sub (tag kind r) (n 6)) (wire (r.typeZeroStart+2)) (wire (r.typeZeroStart+3))

def limitGates (tokens : Tokens) (splits : Splits) (kind : Nat) (r : Row) (index start : Linear) : List Gate :=
  let m := if kind = 1 then r.active else z
  let t := if kind = 0 then r.active else z
  let mi := if kind = 1 then index else z
  let ti := if kind = 0 then index else z
  let offset := if kind = 0 then 1 else 0
  let maximum := (limitAt r 1).value ++ (limitAt r 3).value
  [queryGate m mi (limitAt r 0),queryGate m mi (limitAt r 1),queryGate t ti (limitAt r 2),queryGate t ti (limitAt r 3)] ++
    splitGates (split splits r.limitHeads) ++
    ImportMatrix.readGates tokens (readAt r offset) r.active maximum start ++
    ImportMatrix.readGates tokens (readAt r (offset+1)) r.active (split splits r.limitHeads).low (readAt r offset).cursor ++
    ImportMatrix.readGates tokens (readAt r (offset+2)) maximum (split splits r.limitHeads).high (readAt r (offset+1)).cursor

def rowGates (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (i : Nat) (start previous : Linear) : List Gate :=
  let index := (if kind = 0 then imports.importedTables else if kind = 1 then imports.importedMemories else imports.importedGlobals) ++ n i
  match kind with
  | 0 => [boolGate r.active,gate r.active (sub o previous),queryGate r.active (scale index 2 ++ o) r.objectQuery] ++
      typeGates kind r ++ ImportMatrix.readGates tokens (readAt r 0) r.active (typeByte kind r) start ++
      limitGates tokens splits kind r index (readAt r 0).cursor
  | 1 => [boolGate r.active,gate r.active (sub o previous)] ++ limitGates tokens splits kind r index start
  | 2 => [queryGate r.active (scale index 2) r.objectQuery] ++ RangeUse.gates r.objectRange ++ typeGates kind r ++
      ImportMatrix.readGates tokens (readAt r 0) r.active (typeByte kind r) start ++
      ImportMatrix.readGates tokens (readAt r 1) r.active ((RangeUse.bits r.objectRange).getD 3 z) (readAt r 0).cursor ++
      ConstantSourceMatrix.gates tokens splits (constAt constants r)
  | _ => ImportMatrix.nameGates splits r.name r.active (n i) start ++
      ImportMatrix.readGates tokens (readAt r 0) r.active (get r.fields 0) r.name.cursor ++
      ImportMatrix.readGates tokens (readAt r 1) r.active (get r.fields 1) (readAt r 0).cursor

def rowEnd (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) :=
  if kind = 0 then (readAt r 3).cursor else if kind = 1 then (readAt r 2).cursor
  else if kind = 2 then (ConstantSourceMatrix.readAt (constAt constants r) 5).cursor else (readAt r 1).cursor

def limitShape (tokens : Tokens) (splits : Splits) (kind : Nat) (r : Row) (start : Linear) : Prop :=
  let offset := if kind = 0 then 1 else 0
  r.limits.length = 4 ∧ r.limitHeads < splits.length ∧
    splitMatches (split splits r.limitHeads) ((limitAt r 0).value ++ (limitAt r 2).value) 32 32 ∧
    ImportMatrix.readMatches tokens (readAt r offset) 0 r.active start ∧
    ImportMatrix.readMatches tokens (readAt r (offset+1)) 1 r.active (readAt r offset).cursor ∧
    ImportMatrix.readMatches tokens (readAt r (offset+2)) 1 ((limitAt r 1).value ++ (limitAt r 3).value) (readAt r (offset+1)).cursor ∧
    (limitAt r 0).active = (if kind = 1 then r.active else z) ∧ (limitAt r 1).active = (if kind = 1 then r.active else z) ∧
    (limitAt r 2).active = (if kind = 0 then r.active else z) ∧ (limitAt r 3).active = (if kind = 0 then r.active else z)
instance (tokens : Tokens) (splits : Splits) (kind : Nat) (r : Row) (start : Linear) : Decidable (limitShape tokens splits kind r start) := by
  unfold limitShape; infer_instance

def shape (tokens : Tokens) (splits : Splits) (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (start : Linear) : Prop :=
  match kind with
  | 0 => r.reads.length = 4 ∧ r.objectQuery.active = r.active ∧
      ImportMatrix.readMatches tokens (readAt r 0) 0 r.active start ∧ limitShape tokens splits kind r (readAt r 0).cursor
  | 1 => r.reads.length = 3 ∧ limitShape tokens splits kind r start
  | 2 => r.reads.length = 2 ∧ r.objectQuery.active = r.active ∧ r.constantIndex < constants.length ∧
      ImportMatrix.readMatches tokens (readAt r 0) 0 r.active start ∧
      ImportMatrix.readMatches tokens (readAt r 1) 0 r.active (readAt r 0).cursor ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants r) 0) r.active ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants r) 1) o ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants r) 2) (readAt r 1).cursor
  | _ => r.reads.length = 2 ∧ r.fields.length = 2 ∧ ImportMatrix.nameMatches splits r.name r.active ∧
      ImportMatrix.readMatches tokens (readAt r 0) 0 r.active r.name.cursor ∧
      ImportMatrix.readMatches tokens (readAt r 1) 1 r.active (readAt r 0).cursor
instance (tokens : Tokens) (splits : Splits) (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (start : Linear) : Decidable (shape tokens splits constants kind r start) := by
  unfold shape; split <;> infer_instance

def checkRow (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (r : Row) (i : Nat) (start previous : Linear) : Bool :=
  decide (shape tokens splits constants kind r start) &&
  (if kind = 2 then RangeUse.check matrix r.objectRange r.objectQuery.value 4 else true) &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (rowGates tokens splits imports constants kind r i start previous)

def checkRows (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) : List Row → Nat → Linear → Linear → Bool
  | [],_,_,_ => true
  | r::rs,i,start,previous => checkRow matrix tokens splits imports constants kind r i start previous &&
      checkRows matrix tokens splits imports constants kind rs (i+1) (rowEnd constants kind r) r.active
def final (constants : List ConstantSourceMatrix.Record) (kind : Nat) : List Row → Linear → Linear
  | [],start => start
  | r::rs,_ => final constants kind rs (rowEnd constants kind r)
def count (rows : List Row) : Linear := z ++ rows.flatMap Row.active
def sectionId (kind : Nat) := kind+4
def start (body : ModuleAuditIO.SourceEnvelope) (kind : Nat) := get body.envelope.outputs (4*(sectionId kind)+2)
def finish (body : ModuleAuditIO.SourceEnvelope) (kind : Nat) := get body.envelope.outputs (4*(sectionId kind)+3)
def size (body : ModuleAuditIO.SourceEnvelope) (kind : Nat) := get body.envelope.outputs (4*(sectionId kind)+1)
def closeGates (body : ModuleAuditIO.SourceEnvelope) (constants : List ConstantSourceMatrix.Record) (r : Record) (kind : Nat) :=
  [eqGate (final constants kind (getRows r kind) (start body kind)) (finish body kind),eqGate (count (getRows r kind)) (size body kind)]

def links (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record) (r : Record) : Prop :=
  r.rows.length = 4 ∧ r.closeStarts.length = 4 ∧ r.closeEnds.length = 4 ∧
  (∀ kind : Fin 4, (getRows r kind.val).length < 2^32) ∧
  ConstantSourceMatrix.same (count (getRows r 3)) imports.exportCount ∧
  (∀ kind : Fin 2, ∀ row ∈ getRows r kind.val, ∀ i : Fin 4,
    limitAt row i.val ∈ (ImportMatrix.table tables imports (3+i.val)).queries) ∧
  (∀ row ∈ getRows r 0 ++ getRows r 2, row.objectQuery ∈ (ImportMatrix.table tables imports 1).queries) ∧
  (∀ row ∈ getRows r 3, row.name.query ∈ (ImportMatrix.table tables imports 0).queries) ∧
  (ImportMatrix.table tables imports 0).memory.addressBits = 32 ∧
  (ImportMatrix.table tables imports 0).memory.valueBits = 64 ∧
  (ImportMatrix.table tables imports 1).memory.addressBits = 33 ∧
  (ImportMatrix.table tables imports 1).memory.valueBits = 4 ∧
  (∀ i : Fin 4, (ImportMatrix.table tables imports (3+i.val)).memory.addressBits = 32 ∧
    (ImportMatrix.table tables imports (3+i.val)).memory.valueBits = (if i.val % 2 = 0 then 64 else 1))
instance (tables : List ReadOnlyMatrix.Record) (imports : ImportMatrix.Record) (r : Record) : Decidable (links tables imports r) := by
  unfold links; infer_instance
def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record) (r : Record) : Bool :=
  decide (links tables imports r) && (List.range 4).all (fun kind =>
    checkRows matrix body.tokens splits imports constants kind (getRows r kind) 0 (start body kind) o &&
    MemoryEvidence.checkSpan matrix (r.closeStarts.getD kind 0) (r.closeEnds.getD kind 0) (closeGates body constants r kind))
end ZkBuild.ScalarPayloadMatrix
