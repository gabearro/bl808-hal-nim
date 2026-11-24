import VariableSelectorCheck
import StructuredCheck
set_option autoImplicit false
namespace ZkBuild.BranchRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  primary : Linear
  before : Linear
  after : Fields
  reciprocals : Fields
  bankQuery : ReadOnlyMatrix.Entry
  nodeQuery : ReadOnlyMatrix.Entry
  payload : PackedFields.Record
  primaryRange : RangeUse.Record
  outputs : Fields
  first : Nat
  last : Nat
  deriving Inhabited

def zeros (r : Record) : List (Linear × Nat) :=
  [(sub (f r.row 8) (n 14),0),(f r.after 4,5),(r.payload.high,7)]
def multiplies (r : Record) : List (Linear × Linear × Nat) :=
  [(f r.flags 1,f r.after 0,1),
   (f r.after 1,scale (f r.row 1) (Int.ofNat (2^32))++r.primary,3),
   (f r.flags 9,f r.after 4,6),(f r.flags 9,f r.after 7,8),(f r.flags 7,f r.after 0,10)]
def selects (r : Record) : List (Linear × Linear × Linear × Nat) :=
  [(f r.flags 0++f r.flags 1,r.bankQuery.value,r.before,4),
   (f r.flags 9,r.payload.high,f r.after 4,9)]
def equalities (_r : Record) : List (Linear × Nat) := []
def guards (r : Record) : List (Linear × Linear) :=
  [(f r.flags 9,sub o (f r.after 0)),(f r.flags 9,f r.after 5),(f r.after 10,f r.after 9)]
def gates (r : Record) : List Gate :=
  (zeros r).flatMap (fun (input,i) => zeroGates input (f r.after i) (f r.reciprocals i)) ++
  (multiplies r).map (fun (a,b,i) => mulGate a b (f r.after i)) ++
  (selects r).map (fun (test,yes,no,i) => selectGate test yes no (f r.after i)) ++
  (equalities r).map (fun (input,i) => eqGate (f r.after i) input) ++
  (guards r).map (fun (a,b) => gate a b)

def links (r : Record) : Prop :=
  r.row.length = 10 ∧ r.flags.length = 11 ∧ r.after.length = 11 ∧ r.reciprocals.length = 11 ∧
  r.payload.lowWidth = 32 ∧ r.payload.highWidth = 32 ∧
  ModuleProgram.sameInputs [r.bankQuery.active,r.bankQuery.address,r.nodeQuery.active,r.nodeQuery.address,r.payload.value]
    [f r.after 1,f r.after 3,f r.flags 9,f r.after 6,r.nodeQuery.value] ∧
  ModuleProgram.sameInputs r.outputs [r.payload.low,f r.after 8]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance

def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && OperandRowCheck.includes matrix r.first r.last (gates r) &&
  RangeUse.check matrix r.primaryRange r.primary 32 && PackedFields.check matrix r.payload

def offset (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) :=
  3*(DynamicTypingMatrix.bank tables s 0).entries.length+5*(DynamicTypingMatrix.bank tables s 1).entries.length

def op (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i k : Nat) :=
  s.program.base.operations.getD (offset tables s+11*i+k) default

def record (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  let ns := DynamicTypingMatrix.bank tables s 1
  let queryOffset := (DynamicTypingMatrix.bank tables s 0).entries.length+ns.entries.length
  ⟨rowAt s.rows i,rowAt s.flags i,f (rowAt s.inputs i) 0,
   if i = 0 then z else (op tables s (i-1) 9).call.outputs.getD 0 [],
   (List.range 11).map (fun k => (op tables s i k).call.outputs.getD 0 []),
   (List.range 11).map (fun k => (op tables s i k).call.outputs.getD 1 []),
   (DynamicTypingMatrix.bank tables s 0).queries.getD i default,ns.queries.getD (queryOffset+i) default,
   splits.getD (s.program.blocks.getD (ns.entries.length+i) default).index default,
   op tables s i 2,rowAt s.outputs i,(op tables s i 0).call.firstGate,
   if i+1 < s.rows.length then (op tables s (i+1) 0).call.firstGate else s.program.base.lastGate⟩

def checkStage (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind = 2 ∧ s.program.base.operations.length = offset tables s+11*s.rows.length+1 ∧
    s.program.blocks.length = (DynamicTypingMatrix.bank tables s 1).entries.length+s.rows.length ∧
    (DynamicTypingMatrix.bank tables s 0).queries.length = s.rows.length ∧
    (DynamicTypingMatrix.bank tables s 1).queries.length = (DynamicTypingMatrix.bank tables s 0).entries.length+
      (DynamicTypingMatrix.bank tables s 1).entries.length+s.rows.length) &&
  (List.range s.rows.length).all (fun i => check matrix (record splits tables s i))
end ZkBuild.BranchRowCheck
