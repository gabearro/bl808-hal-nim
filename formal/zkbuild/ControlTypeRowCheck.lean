import BranchTypeRowCheck
set_option autoImplicit false
namespace ZkBuild.ControlTypeRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  frame : Fields
  before : Fields
  after : Fields
  reciprocals : Fields
  metadata : ReadOnlyMatrix.Entry
  params : ReadOnlyMatrix.Entry
  member : ReadOnlyMatrix.Entry
  singleton : ReadOnlyMatrix.Entry
  results : ReadOnlyMatrix.Entry
  compare : ReadOnlyMatrix.Entry
  heads : PackedFields.Record
  payload : PackedFields.Record
  comparison : PackedFields.Record
  ranges : List RangeUse.Record
  first : Nat
  last : Nat
  deriving Inhabited

def reset (r : Record) := f r.flags 0++f r.flags 1
def lookup (r : Record) := f r.flags 0++f r.after 0
def parameterInput (r : Record) := f r.frame 17++f r.after 21
def parameterOutput (r : Record) := f r.frame 17++f r.frame 11++f r.after 24
def argument (r : Record) := sub (f r.after 30) (f r.after 31)
def inputOrdinal (r : Record) := f r.after 35
def outputLength (r : Record) := f r.after 27++f r.after 28
def zeros (r : Record) : List (Linear × Nat) :=
  [(sub (f r.frame 1) o,19),(sub (f r.frame 1) (n 2),20),
   (sub (f r.row 4) (n 7),33),(f r.row 4,34),(sub (f r.row 4) r.payload.low,45)]
def multiplies (r : Record) : List (Linear × Linear × Nat) :=
  [(f r.flags 1,f r.frame 20,0),(lookup r,f r.frame 4++f r.frame 5,1),
   (f r.after 1,scale (f r.frame 3) 2++f r.frame 4,2),
   (lookup r,f r.frame 7,3),(f r.after 3,f r.frame 3,4),(lookup r,f r.frame 6,5),
   (f r.frame 4,r.heads.low,6),(lookup r,f r.after 7,9),(lookup r,f r.after 8,10),
   (f r.frame 18,f r.after 19,21),(f r.frame 15,f r.after 19,24),
   (f r.frame 12,sub o (f r.frame 5),25),(f r.frame 15,sub o (f r.after 19),26),
   (parameterOutput r,f r.after 11,27),(f r.after 25++f r.after 26,f r.after 12,28),
   (f r.frame 20,f r.flags 3,30),(f r.after 30,f r.after 18,31),(f r.frame 20,f r.flags 2,32),
   (argument r,f r.after 22,37),(f r.after 32,f r.after 29,38),
   (argument r,f r.after 35,39),(f r.after 32,f r.after 36,40),
   (argument r++f r.after 32,f r.after 37++f r.after 38,41),
   (argument r++f r.after 32,f r.after 39++f r.after 40,42),
   (f r.frame 12,f r.after 20,46),(f r.flags 1,f r.after 46,47),
   (argument r,f r.after 46,48),(f r.after 48,f r.after 7,49),(f r.after 48,f r.after 13,50),
   (f r.frame 20,f r.flags 4,53),(f r.frame 20,f r.flags 5,54),
   (f r.frame 20,f r.flags 6,55),(f r.frame 20,f r.flags 7,62)]
def selects (r : Record) : List (Linear × Linear × Linear × Nat) :=
  [(reset r,f r.after 6,f r.before 0,7),(reset r,r.heads.high++r.singleton.value,f r.before 1,8),
   (reset r,r.params.value,f r.before 2,11),(reset r,r.results.value,f r.before 3,12),
   (reset r,z,f r.before 4,13),(reset r,z,f r.before 5,14),(reset r,z,f r.before 6,15),
   (reset r,z,f r.before 7,16),(reset r,z,f r.before 8,17),
   (reset r,f r.frame 10++f r.frame 15,f r.before 9,18),
   (parameterInput r,f r.after 7,f r.after 8,22),(parameterInput r,f r.after 11,f r.after 12,23),
   (parameterOutput r,f r.after 7,f r.after 8,29),
   (parameterInput r,f r.after 13,sub (sub (f r.after 12) o) (f r.after 13),35),
   (parameterOutput r,sub (sub (f r.after 11) o) (f r.after 14),f r.after 14,36)]
def equalities (r : Record) : List (Linear × Nat) :=
  [(f r.after 13++argument r,56),(f r.after 14++f r.after 32,57),
   (sub (f r.after 18) (f r.after 31),58),(f r.after 15++f r.flags 4,59),
   (f r.after 16++f r.flags 5,60),(f r.after 17++f r.after 55,61)]
def guards (r : Record) : List (Linear × Linear) :=
  [(f r.after 5,f r.frame 3),(f r.after 31,sub (sub o (f r.after 33)) (f r.after 34)),
   (f r.after 30,f r.after 14++f r.after 15++f r.after 16++f r.after 17),
   (argument r,sub (sub o (f r.after 33)) (f r.after 45)),
   (f r.after 32,sub (f r.row 4) r.payload.low),(f r.after 32,sub (f r.after 13) (f r.after 23)),
   (f r.after 32,f r.after 18++f r.after 17),
   (f r.after 32,sub (sub (f r.after 15) (f r.frame 17)) (f r.frame 11)),
   (f r.after 32,sub (f r.after 16) (f r.frame 19)),
   (f r.after 47,sub (f r.after 11) (f r.after 12)),
   (r.compare.active,sub r.comparison.low r.payload.low),
   (f r.after 53++f r.after 54,sub (f r.after 13) (f r.after 23)),
   (f r.after 53++f r.after 54,f r.after 18++f r.after 14++f r.after 17),
   (f r.after 53,f r.after 15),(f r.after 53,sub (f r.after 16) (f r.frame 11)),
   (f r.after 54,f r.after 15++f r.after 16),
   (f r.after 55,sub (sub o (f r.frame 14)) (f r.frame 16)),
   (f r.after 55,sub (f r.after 13) (f r.after 23)),
   (f r.after 55,f r.after 18++f r.after 14++f r.after 15++f r.after 16++f r.after 17),
   (f r.after 62,sub (f r.after 56) (f r.after 23)),(f r.after 62,f r.after 58),
   (f r.after 62,sub (f r.after 57) (outputLength r)),
   (f r.after 62,sub (sub (f r.after 59) (f r.frame 17)) (f r.frame 11)),
   (f r.after 62,sub (f r.after 60) (f r.frame 19)),
   (f r.after 62,sub (sub (f r.after 61) (f r.frame 14)) (f r.frame 16))]
def gates (r : Record) : List Gate :=
  (zeros r).flatMap (fun (input,i) => zeroGates input (f r.after i) (f r.reciprocals i)) ++
  (multiplies r).map (fun (a,b,i) => mulGate a b (f r.after i)) ++
  (selects r).map (fun (test,yes,no,i) => selectGate test yes no (f r.after i)) ++
  (equalities r).map (fun (input,i) => eqGate (f r.after i) input) ++
  (guards r).map (fun (a,b) => gate a b)
def links (r : Record) : Prop :=
  r.row.length=10 ∧ r.flags.length=11 ∧ r.frame.length=22 ∧ r.before.length=10 ∧
  r.after.length=63 ∧ r.reciprocals.length=63 ∧ r.ranges.length=4 ∧
  r.heads.lowWidth=32 ∧ r.heads.highWidth=32 ∧ r.payload.lowWidth=3 ∧ r.payload.highWidth=32 ∧
  r.comparison.lowWidth=3 ∧ r.comparison.highWidth=32 ∧
  ModuleProgram.sameInputs
    [r.metadata.active,r.metadata.address,r.heads.value,r.params.active,r.params.address,
     r.member.active,r.member.address,r.payload.value,r.singleton.active,r.singleton.address,
     r.results.active,r.results.address,r.compare.active,r.compare.address,r.comparison.value]
    [f r.after 1,f r.after 2,r.metadata.value,lookup r,f r.after 9,
     argument r++f r.after 32,scale (f r.after 41) (Int.ofNat (2^32))++f r.after 42,r.member.value,
     f r.after 3,f r.after 4,lookup r,f r.after 10,f r.after 48,
     scale (f r.after 49) (Int.ofNat (2^32))++f r.after 50,r.compare.value]
instance (r : Record) : Decidable (links r) := by unfold links; infer_instance
def check (matrix : Shape) (r : Record) : Bool :=
  decide (links r) && OperandRowCheck.includes matrix r.first r.last (gates r) &&
  PackedFields.check matrix r.heads && PackedFields.check matrix r.payload && PackedFields.check matrix r.comparison &&
  (List.range 4).all (fun i => RangeUse.check matrix (r.ranges.getD i default) (f r.after ([41,42,49,50].getD i 0)) 32)

def op (s : DynamicTypingMatrix.Stage) (i k : Nat) := s.program.base.operations.getD (63*i+k) default
def record (splits : Splits) (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  let outputs := rowAt s.outputs i
  ⟨rowAt s.rows i,rowAt s.flags i,rowAt s.selectors i,
   [7,8,11,12,56,57,59,60,61,58].map (fun k => if i=0 then z else (op s (i-1) k).call.outputs.getD 0 []),
   (List.range 63).map (fun k => (op s i k).call.outputs.getD 0 []),
   (List.range 63).map (fun k => (op s i k).call.outputs.getD 1 []),
   BranchTypeRowCheck.query outputs 0,BranchTypeRowCheck.query outputs 3,BranchTypeRowCheck.query outputs 6,
   BranchTypeRowCheck.query outputs 9,BranchTypeRowCheck.query outputs 12,BranchTypeRowCheck.query outputs 15,
   splits.getD (s.program.blocks.getD (3*i) default).index default,
   splits.getD (s.program.blocks.getD (3*i+1) default).index default,
   splits.getD (s.program.blocks.getD (3*i+2) default).index default,
   [43,44,51,52].map (op s i),
   (op s i 0).call.firstGate,if i+1<s.rows.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩
def checkStage (matrix : Shape) (splits : Splits) (s : DynamicTypingMatrix.Stage) : Bool :=
  decide (s.kind=4 ∧ s.rows.length<2^32 ∧ s.program.base.operations.length=63*s.rows.length ∧
    s.program.blocks.length=3*s.rows.length) &&
  (List.range s.rows.length).all (fun i => check matrix (record splits s i))
end ZkBuild.ControlTypeRowCheck
