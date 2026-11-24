import EnvironmentRowCheck
import PackedFields
set_option autoImplicit false
namespace ZkBuild.CallRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  primary : Linear
  secondary : Linear
  before : Fields
  after : Fields
  reciprocals : Fields
  metadata : ReadOnlyMatrix.Entry
  node : ReadOnlyMatrix.Entry
  tableQuery : ReadOnlyMatrix.Entry
  heads : PackedFields.Record
  payload : PackedFields.Record
  primaryRange : RangeUse.Record
  secondaryRange : RangeUse.Record
  first : Nat
  last : Nat
  deriving Inhabited

def call (r : Record) : Linear := f r.after 0++f r.after 1++f r.after 2++f r.after 3
def tail (r : Record) : Linear := f r.after 2++f r.after 3
def indexed (r : Record) : Linear := f r.after 1++f r.after 3
def argument (r : Record) : Linear := sub (f r.after 18) (f r.after 19)

def gates (r : Record) : List Gate :=
  let reset := f r.flags 0++f r.flags 1
  zeroGates (sub (f r.row 8) (n 16)) (f r.after 0) (f r.reciprocals 0) ++
  zeroGates (sub (f r.row 8) (n 17)) (f r.after 1) (f r.reciprocals 1) ++
  zeroGates (sub (f r.row 8) (n 18)) (f r.after 2) (f r.reciprocals 2) ++
  zeroGates (sub (f r.row 8) (n 19)) (f r.after 3) (f r.reciprocals 3) ++
  [mulGate (call r) (f r.flags 1) (f r.after 4),
   mulGate (indexed r) (f r.flags 1) (f r.after 5),
   gate (sub o (f r.flags 1)) r.primary,gate (sub o (f r.flags 1)) r.secondary,
   mulGate (f r.flags 0) (scale (f r.row 1) 2) (f r.after 8),
   mulGate (f r.after 4) (scale r.primary 2++indexed r) (f r.after 9),
   selectGate (f r.flags 0) r.heads.high (f r.before 5) (f r.after 10),
   mulGate (tail r) (f r.flags 1) (f r.after 11),
   gate (f r.after 11) (sub r.heads.high (f r.after 10)),
   selectGate reset r.heads.low (f r.before 0) (f r.after 12),
   selectGate reset r.heads.high (f r.before 1) (f r.after 13),
   selectGate reset (indexed r) (f r.before 2) (f r.after 14),
   selectGate reset z (f r.before 3) (f r.after 15),
   selectGate reset z (f r.before 4) (f r.after 16),
   mulGate (f r.after 5) (scale r.secondary 2++o) (f r.after 17),
   gate (f r.after 5) (sub r.tableQuery.value (n 5)),
   mulGate (call r) (f r.flags 3) (f r.after 18),
   mulGate (f r.after 18) (f r.after 14) (f r.after 19),
   mulGate (call r) (f r.flags 2) (f r.after 20),
   mulGate (call r) (f r.flags 6) (f r.after 21)] ++
  zeroGates (sub (f r.row 4) (n 7)) (f r.after 22) (f r.reciprocals 4) ++
  zeroGates (f r.row 4) (f r.after 23) (f r.reciprocals 5) ++
  [gate (f r.after 19) (sub (sub o (f r.after 22)) (f r.after 23)),
   gate (f r.after 18) (f r.after 15++f r.after 16),
   gate (f r.after 20) (tail r++f r.after 14++f r.after 16),
   gate (f r.after 20) (f r.after 12),
   mulGate (argument r) (f r.after 12) (f r.after 24),
   mulGate (f r.after 20) (f r.after 13) (f r.after 25)] ++
  zeroGates (sub (f r.row 4) r.payload.low) (f r.after 26) (f r.reciprocals 6) ++
  [gate (argument r) (sub (sub o (f r.after 22)) (f r.after 26)),
   gate (f r.after 20) (sub (f r.row 4) r.payload.low),
   selectGate (argument r) r.payload.high (f r.after 12) (f r.after 27),
   selectGate (f r.after 20) r.payload.high (f r.after 13) (f r.after 28),
   eqGate (f r.after 29) (sub (f r.after 14) (f r.after 19)),
   selectGate (f r.after 20) o (f r.after 15) (f r.after 30),
   gate (call r) (f r.flags 4++f r.flags 5),
   gate (f r.after 21) (sub o (tail r)),
   gate (f r.after 21) (f r.after 27++f r.after 29++f r.after 16),
   eqGate (f r.after 31) (f r.after 16++f r.after 21),
   mulGate (call r) (f r.flags 7) (f r.after 32),
   gate (f r.after 32) (f r.after 27),gate (f r.after 32) (f r.after 29),
   gate (f r.after 32) (sub (f r.after 31) (tail r)),
   mulGate (f r.after 0++f r.after 1) (f r.flags 7) (f r.after 33),
   gate (f r.after 33) (f r.after 28)]

def links (r : Record) : Prop :=
  r.row.length = 10 ∧ r.flags.length = 11 ∧ r.before.length = 6 ∧ r.after.length = 34 ∧ r.reciprocals.length = 7 ∧
  r.heads.lowWidth = 32 ∧ r.heads.highWidth = 32 ∧ r.payload.lowWidth = 3 ∧ r.payload.highWidth = 32 ∧
  ModuleProgram.sameInputs [r.metadata.active,r.metadata.address,r.heads.value,r.node.active,r.node.address,r.payload.value,
      r.tableQuery.active,r.tableQuery.address]
    [f r.flags 0++f r.after 4,f r.after 8++f r.after 9,r.metadata.value,argument r++f r.after 20,
      f r.after 24++f r.after 25,r.node.value,f r.after 5,f r.after 17]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance

def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && OperandRowCheck.includes matrix r.first r.last (gates r) &&
  RangeUse.check matrix r.primaryRange r.primary 32 && RangeUse.check matrix r.secondaryRange r.secondary 32 &&
  PackedFields.check matrix r.heads && PackedFields.check matrix r.payload

def op (s : DynamicTypingMatrix.Stage) (i k : Nat) := s.program.base.operations.getD (34*i+k) default

def record (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,f (rowAt s.inputs i) 0,f (rowAt s.inputs i) 1,
    [27,28,29,30,31,10].map (fun k => if i = 0 then z else (op s (i-1) k).call.outputs.getD 0 []),
    (List.range 34).map (fun k => (op s i k).call.outputs.getD 0 []),
    [0,1,2,3,22,23,26].map (fun k => (op s i k).call.outputs.getD 1 []),
    signature.extraMetadata.getD i default,signature.extraOperands.getD i default,
    (DynamicTypingMatrix.bank tables s 0).queries.getD i default,
    splits.getD (s.program.blocks.getD (2*i) default).index default,
    splits.getD (s.program.blocks.getD (2*i+1) default).index default,
    op s i 6,op s i 7,(op s i 0).call.firstGate,
    if i+1 < s.rows.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩

def checkStage (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind = 3 ∧ s.program.base.operations.length = 34*s.rows.length ∧
    s.program.blocks.length = 2*s.rows.length ∧ signature.extraMetadata.length = s.rows.length ∧
    signature.extraOperands.length = s.rows.length ∧ (DynamicTypingMatrix.bank tables s 0).queries.length = s.rows.length) &&
  (List.range s.rows.length).all (fun i => check matrix (record splits tables signature s i))
end ZkBuild.CallRowCheck
