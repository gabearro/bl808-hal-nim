import VariableRowCheck
set_option autoImplicit false
namespace ZkBuild.EnvironmentRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  selectors : Fields
  immediate : Linear
  localQuery : ReadOnlyMatrix.Entry
  objectQuery : ReadOnlyMatrix.Entry
  before : Linear
  after : Fields
  reciprocal : Linear
  immediateRange : RangeUse.Record
  packedRange : RangeUse.Record
  first : Nat
  last : Nat
  deriving Inhabited

def tag (r : Record) : Linear :=
  f (RangeUse.bits r.packedRange) 0 ++ scale (f (RangeUse.bits r.packedRange) 1) 2 ++
    scale (f (RangeUse.bits r.packedRange) 2) 4

def gates (r : Record) : List Gate :=
  [gate (sub o (f r.flags 1)) r.immediate,
   mulGate (f r.flags 1) (f r.selectors 10) (f r.after 1),
   mulGate (f r.flags 1) (f r.selectors 11++f r.selectors 12) (f r.after 2),
   mulGate (f r.flags 1) (f r.selectors 12) (f r.after 3),
   mulGate (f r.after 1) (scale (f r.row 1) (Int.ofNat (2^32))++r.immediate) (f r.after 4),
   mulGate (f r.after 2) (scale r.immediate 2++f r.selectors 12) (f r.after 5)] ++
  zeroGates (sub (tag r) (n 7)) (f r.after 7) r.reciprocal ++
  [eqGate (f r.after 7) z,
   gate (f r.after 1++f r.after 3) (f (RangeUse.bits r.packedRange) 3),
   mulGate (f r.flags 1) (f r.selectors 4) (f r.after 9),
   gate (f r.after 9) (sub o (f (RangeUse.bits r.packedRange) 3)),
   mulGate (sub (tag r) (n 5)) (sub (tag r) (n 6)) (f r.after 10),
   gate (f r.after 3) (f r.after 10),
   selectGate (f r.flags 0++f r.flags 1) (tag r) r.before (f r.after 11)]

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 10 ∧ r.flags.length = 11 ∧ r.selectors.length = 14 ∧ r.after.length = 12 ∧
    ModuleProgram.sameInputs [r.localQuery.active,r.localQuery.address,r.objectQuery.active,r.objectQuery.address]
      [f r.after 1,f r.after 4,f r.after 2,f r.after 5]) &&
  OperandRowCheck.includes matrix r.first r.last (gates r) &&
  RangeUse.check matrix r.immediateRange r.immediate 32 &&
  RangeUse.check matrix r.packedRange (r.localQuery.value++r.objectQuery.value) 4

def offset (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) :=
  2*(DynamicTypingMatrix.bank tables s 0).entries.length+7*(DynamicTypingMatrix.bank tables s 1).entries.length

def op (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i k : Nat) :=
  s.program.base.operations.getD (offset tables s+12*i+k) default

def record (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,rowAt s.selectors i,f (rowAt s.inputs i) 0,
   (DynamicTypingMatrix.bank tables s 0).queries.getD i default,
   (DynamicTypingMatrix.bank tables s 1).queries.getD i default,
   if i = 0 then z else (op tables s (i-1) 11).call.outputs.getD 0 [],
   (List.range 12).map (fun k => (op tables s i k).call.outputs.getD 0 []),
   (op tables s i 7).call.outputs.getD 1 [],op tables s i 0,op tables s i 6,
   (op tables s i 0).call.firstGate,(op tables s i 11).call.lastGate⟩

def checkStage (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind = 1 ∧ s.program.base.operations.length = offset tables s+12*s.rows.length ∧
    (DynamicTypingMatrix.bank tables s 0).queries.length = s.rows.length ∧
    (DynamicTypingMatrix.bank tables s 1).queries.length = s.rows.length) &&
  (List.range s.rows.length).all (fun i => check matrix (record tables s i))
end ZkBuild.EnvironmentRowCheck
