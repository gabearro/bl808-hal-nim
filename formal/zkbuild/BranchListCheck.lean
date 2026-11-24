import BranchRowCheck
set_option autoImplicit false
namespace ZkBuild.BranchListCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Bank where
  entry : ReadOnlyMatrix.Entry
  query : ReadOnlyMatrix.Entry
  range : RangeUse.Record
  selected : Linear
  reciprocal : Linear
  first : Nat
  last : Nat
  deriving Inhabited

def bankGates (r : Bank) : List Gate :=
  zeroGates r.entry.value r.selected r.reciprocal ++
  [gate r.entry.active r.selected,mulGate r.entry.active r.entry.value r.query.address]
def checkBank (matrix : Shape) (r : Bank) : Bool :=
  decide (ModuleProgram.sameInputs [r.query.active] [r.entry.active]) &&
  RangeUse.check matrix r.range r.entry.value 32 && OperandRowCheck.includes matrix r.first r.last (bankGates r)

structure Node where
  entry : ReadOnlyMatrix.Entry
  query : ReadOnlyMatrix.Entry
  payload : PackedFields.Record
  delta : RangeUse.Record
  after : Fields
  reciprocal : Linear
  first : Nat
  last : Nat
  deriving Inhabited

def nodeGates (r : Node) : List Gate :=
  [selectGate r.entry.active (sub (sub r.entry.address r.payload.high) o) z (f r.after 0)] ++
  zeroGates r.payload.high (f r.after 2) r.reciprocal ++
  [mulGate r.entry.active (sub o (f r.after 2)) (f r.after 3),mulGate (f r.after 3) r.payload.high (f r.after 4)]
def nodeLinks (r : Node) : Prop :=
  r.after.length = 5 ∧ r.payload.lowWidth = 32 ∧ r.payload.highWidth = 32 ∧
  ModuleProgram.sameInputs [r.payload.value,r.query.active,r.query.address] [r.entry.value,f r.after 3,f r.after 4]
instance (r : Node) : Decidable (nodeLinks r) := by unfold nodeLinks; infer_instance

def checkNode (matrix : Shape) (r : Node) : Bool :=
  decide (nodeLinks r) && PackedFields.check matrix r.payload &&
  RangeUse.check matrix r.delta (f r.after 0) 32 && OperandRowCheck.includes matrix r.first r.last (nodeGates r)

def bankRecord (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Bank :=
  let op := fun k => s.program.base.operations.getD (3*i+k) default
  ⟨(DynamicTypingMatrix.bank tables s 0).entries.getD i default,
   (DynamicTypingMatrix.bank tables s 1).queries.getD i default,op 0,
   (op 1).call.outputs.getD 0 [],(op 1).call.outputs.getD 1 [],(op 0).call.firstGate,(op 2).call.lastGate⟩
def nodeRecord (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Node :=
  let count := (DynamicTypingMatrix.bank tables s 0).entries.length
  let op := fun k => s.program.base.operations.getD (3*count+5*i+k) default
  ⟨(DynamicTypingMatrix.bank tables s 1).entries.getD i default,
   (DynamicTypingMatrix.bank tables s 1).queries.getD (count+i) default,
   splits.getD (s.program.blocks.getD i default).index default,op 1,
   (List.range 5).map (fun k => (op k).call.outputs.getD 0 []),(op 2).call.outputs.getD 1 [],
   (op 0).call.firstGate,(op 4).call.lastGate⟩

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  let b := DynamicTypingMatrix.bank tables s 0
  let ns := DynamicTypingMatrix.bank tables s 1
  decide (b.memory.addressBits = 64 ∧ b.memory.valueBits = 32 ∧ ns.memory.addressBits = 32 ∧ ns.memory.valueBits = 64 ∧
    b.entries.length+ns.entries.length ≤ ns.queries.length) &&
  ReadOnlyMatrix.check matrix b && ReadOnlyMatrix.check matrix ns &&
  (List.range b.entries.length).all (fun i => checkBank matrix (bankRecord tables s i)) &&
  (List.range ns.entries.length).all (fun i => checkNode matrix (nodeRecord splits tables s i))
end ZkBuild.BranchListCheck
