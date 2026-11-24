import InstructionRowCheck
import DynamicTypingCheck
set_option autoImplicit false
namespace ZkBuild.VariableRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  selectors : Fields
  declared : Linear
  before : Fields
  after : Fields
  reciprocals : Fields
  first : Nat
  last : Nat
  deriving Inhabited

def inputCount (r : Record) : Linear :=
  f r.selectors 1++f r.selectors 2++f r.selectors 4++f r.selectors 5++
    scale (f r.selectors 6++f r.selectors 7) 2++scale (f r.selectors 9) 3

def outputCount (r : Record) : Linear :=
  f r.selectors 0++f r.selectors 2++f r.selectors 3++f r.selectors 5++f r.selectors 7++f r.selectors 8

def gates (r : Record) : List Gate :=
  let reset := f r.flags 0++f r.flags 1
  let pop := f r.after 10
  let push := f r.after 11
  let finish := f r.after 12
  [selectGate reset z (f r.before 0) (f r.after 0),selectGate reset z (f r.before 1) (f r.after 1),
   mulGate (f r.selectors 0++f r.selectors 2++f r.selectors 3++f r.selectors 5) r.declared (f r.after 2)] ++
  zeroGates (f r.after 0) (f r.after 3) (f r.reciprocals 0) ++
  zeroGates (sub (f r.after 0) o) (f r.after 4) (f r.reciprocals 1) ++
  [mulGate (f r.after 3) (f r.selectors 1++f r.selectors 2++f r.selectors 4++f r.selectors 6) (f r.after 5),
   mulGate (f r.after 4) (f r.selectors 7++f r.selectors 9) (f r.after 6),
   mulGate (f r.after 5++f r.after 6) r.declared (f r.after 7)] ++
  zeroGates (sub (f r.row 4) (f r.after 7)) (f r.after 8) (f r.reciprocals 2) ++
  zeroGates (sub (f r.row 4) (n 7)) (f r.after 9) (f r.reciprocals 3) ++
  [mulGate (f r.selectors 13) (f r.flags 3) pop,mulGate (f r.selectors 13) (f r.flags 2) push,
   gate pop (sub o (f r.after 8++f r.after 9)),gate pop (f r.after 1),
   gate push (sub (f r.row 4) (f r.after 2)),gate push (sub o (outputCount r)),
   gate push (sub (f r.after 0) (inputCount r)),gate push (f r.after 1),
   gate (f r.selectors 13) (f r.flags 4++f r.flags 5++f r.flags 6),
   mulGate (f r.selectors 13) (f r.flags 7) finish,
   gate finish (sub (f r.after 0) (inputCount r)),gate finish (sub (f r.after 1) (outputCount r)),
   eqGate (f r.after 13) (f r.after 0++f r.flags 3),eqGate (f r.after 14) (f r.after 1++f r.flags 2)]

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 10 ∧ r.flags.length = 11 ∧ r.selectors.length = 14 ∧
    r.before.length = 2 ∧ r.after.length = 15 ∧ r.reciprocals.length = 4) &&
  OperandRowCheck.includes matrix r.first r.last (gates r)

def op (s : DynamicTypingMatrix.Stage) (i k : Nat) := s.program.base.operations.getD (15*i+k) default

def record (s : DynamicTypingMatrix.Stage) (i : Nat) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,rowAt s.selectors i,f (rowAt s.inputs i) 0,
   [if i = 0 then z else (op s (i-1) 13).call.outputs.getD 0 [],
    if i = 0 then z else (op s (i-1) 14).call.outputs.getD 0 []],
   (List.range 15).map (fun k => (op s i k).call.outputs.getD 0 []),
   [3,4,8,9].map (fun k => (op s i k).call.outputs.getD 1 []),
   (op s i 0).call.firstGate,(op s i 14).call.lastGate⟩

def checkStage (matrix : Shape) (s : DynamicTypingMatrix.Stage) : Bool :=
  s.kind == 2 && decide (s.rows.length < 2^64) && s.program.base.operations.length == 15*s.rows.length &&
  (List.range s.rows.length).all (fun i => check matrix (record s i))
end ZkBuild.VariableRowCheck
