import BranchRowCheck
set_option autoImplicit false
namespace ZkBuild.BranchTypeRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  index : Nat
  row : Fields
  flags : Fields
  frame : Fields
  terminal : Linear
  before : Fields
  after : Fields
  reciprocals : Fields
  metadata : ReadOnlyMatrix.Entry
  size : ReadOnlyMatrix.Entry
  member : ReadOnlyMatrix.Entry
  singleton : ReadOnlyMatrix.Entry
  heads : PackedFields.Record
  payload : PackedFields.Record
  headRange : RangeUse.Record
  ordinalRange : RangeUse.Record
  restoreRange : RangeUse.Record
  scratch : MemoryPacking.Access
  first : Nat
  last : Nat
  deriving Inhabited

def argument (r : Record) := sub (f r.after 32) (f r.after 33)
def zeros (r : Record) : List (Linear × Nat) :=
  [(sub (f r.row 8) (n 14),0),(sub (f r.frame 1) o,19),
   (sub (f r.row 4) (n 7),36),(f r.row 4,37),(sub (f r.row 4) r.payload.low,43)]
def multiplies (r : Record) : List (Linear × Linear × Nat) :=
  [(f r.flags 1,f r.after 0,6),(f r.flags 9,f r.after 8,12),(sub o (f r.after 9),f r.after 2,13),
   (f r.flags 9,f r.frame 4++f r.frame 5,14),(f r.after 14,scale (f r.frame 3) 2++f r.frame 4,15),
   (f r.flags 9,f r.frame 7,16),(f r.after 16,f r.frame 3,17),(f r.flags 9,f r.frame 6,18),
   (f r.frame 4,r.heads.low,20),(f r.flags 9,f r.after 21,22),(f r.flags 9,sub o (f r.after 8),23),
   (f r.after 0,f r.flags 3,32),(f r.after 32,f r.after 7,33),(f r.after 0,f r.flags 2,34),
   (f r.after 0,f r.flags 6,35),(argument r,f r.after 25,39),(argument r,f r.after 38,40),
   (f r.after 34,sub (sub (f r.after 26) o) (f r.after 28),44),
   (f r.after 34,f r.after 29++f r.after 44,46),(argument r++f r.after 34,f r.row 4,47),
   (f r.after 0,f r.flags 7,52)]
def selects (r : Record) : List (Linear × Linear × Linear × Nat) :=
  let reset := f r.flags 0++f r.flags 1
  [(reset,z,f r.before 0,1),(reset,z,f r.before 1,2),(reset,z,f r.before 2,3),
   (reset,z,f r.before 3,4),(reset,z,f r.before 4,5),(reset,f r.after 6,f r.before 5,7),
   (reset,z,f r.before 6,8),(reset,z,f r.before 7,9),(reset,z,f r.before 8,10),(reset,z,f r.before 9,11),
   (f r.after 19,f r.after 20,r.heads.high++r.singleton.value,21),
   (f r.after 23,r.size.value,f r.after 3,24),(f r.flags 9,f r.after 21,f r.after 1,25),
   (f r.flags 9,r.size.value,f r.after 2,26),(f r.flags 9,z,f r.after 4,27),
   (f r.flags 9,z,f r.after 5,28),(f r.flags 9,n (r.index+1),f r.after 11,29),
   (f r.flags 9,o,f r.after 8,30),(f r.flags 9,r.terminal,f r.after 9,31),
   (f r.after 19,f r.after 27,sub (sub (f r.after 26) o) (f r.after 27),38)]
def equalities (r : Record) : List (Linear × Nat) :=
  [(f r.after 27++argument r,48),(f r.after 28++f r.after 34,49),
   (sub (f r.after 7) (f r.after 33),50),(f r.after 10++f r.after 35,51)]
def guards (r : Record) : List (Linear × Linear) :=
  [(f r.flags 9,sub o (f r.after 0)),(f r.flags 9,f r.after 7++f r.after 9++f r.after 10),
   (f r.after 12,sub (f r.after 4) (f r.after 2)),(f r.after 12,sub (f r.after 5) (f r.after 13)),
   (f r.after 18,f r.frame 3),(f r.after 12,sub r.size.value (f r.after 3)),
   (f r.after 33,sub (sub o (f r.after 36)) (f r.after 37)),
   (argument r++f r.after 34++f r.after 35,sub o (f r.after 30)),
   (argument r,f r.after 7++f r.after 28++f r.after 10),
   (argument r,sub (sub (n r.index) (f r.after 29)) (f r.after 27)),
   (argument r,sub (sub o (f r.after 36)) (f r.after 43)),
   (f r.after 34,f r.after 7++f r.after 31++f r.after 10),(f r.after 34,sub (f r.after 27) (f r.after 26)),
   (f r.after 35,sub o (f r.after 31)),(f r.after 35,f r.after 7++f r.after 28++f r.after 10),
   (f r.after 35,sub (f r.after 27) (f r.after 26)),
   (f r.after 52,sub o (f r.after 30)),(f r.after 52,sub o (f r.after 31)),
   (f r.after 52,f r.after 50++f r.after 49),(f r.after 52,sub (f r.after 48) (f r.after 26)),
   (f r.after 52,sub (f r.after 51) o)]
def gates (r : Record) : List Gate :=
  (zeros r).flatMap (fun (input,i) => zeroGates input (f r.after i) (f r.reciprocals i)) ++
  (multiplies r).map (fun (a,b,i) => mulGate a b (f r.after i)) ++
  (selects r).map (fun (test,yes,no,i) => selectGate test yes no (f r.after i)) ++
  (equalities r).map (fun (input,i) => eqGate (f r.after i) input) ++
  (guards r).map (fun (a,b) => gate a b)

def links (r : Record) : Prop :=
  r.row.length = 10 ∧ r.flags.length = 11 ∧ r.frame.length = 22 ∧ r.before.length = 10 ∧
  r.after.length = 53 ∧ r.reciprocals.length = 53 ∧
  r.heads.lowWidth = 32 ∧ r.heads.highWidth = 32 ∧ r.payload.lowWidth = 3 ∧ r.payload.highWidth = 32 ∧
  ModuleProgram.sameInputs
    [r.metadata.active,r.metadata.address,r.heads.value,r.size.active,r.size.address,
     r.member.active,r.member.address,r.payload.value,r.singleton.active,r.singleton.address,
     r.scratch.active,r.scratch.write,r.scratch.address,r.scratch.value,r.scratch.clock]
    [f r.after 14,f r.after 15,r.metadata.value,f r.flags 9,f r.after 22,
     argument r,scale (f r.after 39) (Int.ofNat (2^32))++f r.after 40,r.member.value,f r.after 16,f r.after 17,
     argument r++f r.after 34,argument r,scale (argument r) (Int.ofNat r.index)++f r.after 46,f r.after 47,n r.index]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance
def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && OperandRowCheck.includes matrix r.first r.last (gates r) &&
  PackedFields.check matrix r.heads && PackedFields.check matrix r.payload &&
  RangeUse.check matrix r.headRange (f r.after 39) 32 &&
  RangeUse.check matrix r.ordinalRange (f r.after 40) 32 &&
  RangeUse.check matrix r.restoreRange (f r.after 44) 32

def op (s : DynamicTypingMatrix.Stage) (i k : Nat) := s.program.base.operations.getD (53*i+k) default
def query (outputs : Fields) (offset : Nat) : ReadOnlyMatrix.Entry := ⟨f outputs offset,f outputs (offset+1),f outputs (offset+2)⟩
def record (splits : Splits) (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  let outputs := rowAt s.outputs i
  ⟨i,rowAt s.rows i,rowAt s.flags i,rowAt s.selectors i,f (rowAt s.inputs i) 0,
   [25,26,24,48,49,50,30,31,51,29].map (fun k => if i = 0 then z else (op s (i-1) k).call.outputs.getD 0 []),
   (List.range 53).map (fun k => (op s i k).call.outputs.getD 0 []),
   (List.range 53).map (fun k => (op s i k).call.outputs.getD 1 []),
   query outputs 0,query outputs 3,query outputs 6,query outputs 9,
   splits.getD (s.program.blocks.getD (2*i) default).index default,
   splits.getD (s.program.blocks.getD (2*i+1) default).index default,
   op s i 41,op s i 42,op s i 45,(memory.inputs.getD i default).fields,
   (op s i 0).call.firstGate,if i+1 < s.rows.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩
def checkStage (matrix : Shape) (splits : Splits) (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind = 5 ∧ s.rows.length < 2^32 ∧ s.program.base.operations.length = 53*s.rows.length ∧
    s.program.blocks.length = 2*s.rows.length ∧ memory.inputs.length = s.rows.length ∧
    memory.addressBits = 32 ∧ memory.valueBits = 3) && MemoryEmbedded.check matrix memory &&
  (List.range s.rows.length).all (fun i => check matrix (record splits memory s i))
end ZkBuild.BranchTypeRowCheck
