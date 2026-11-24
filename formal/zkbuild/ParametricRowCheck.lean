import VariableSelectorCheck
import ParametricEvents
set_option autoImplicit false
namespace ZkBuild.ParametricRowCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  row : Fields
  flags : Fields
  primary : Linear
  before : Fields
  after : Fields
  reciprocals : Fields
  primaryRange : RangeUse.Record
  first : Nat
  last : Nat
  deriving Inhabited

def codes : List Nat := [127,126,125,124,123,112,111]
def selectOp (r : Record) := f r.after 0++f r.after 1
def present (r : Record) := selectOp r++f r.after 2
def validType (r : Record) := (List.range 7).flatMap (fun i => f r.after (4+i))
def tag (r : Record) := (List.range 7).flatMap (fun i => scale (f r.after (4+i)) (Int.ofNat i))
def valuePop (r : Record) := sub (f r.after 19) (f r.after 24)

def zeros (r : Record) : List (Linear × Nat) :=
  [(sub (f r.row 8) (n 27),0),(sub (f r.row 8) (n 28),1),(sub (f r.row 8) (n 208),2)] ++
  (List.range 7).map (fun i => (sub r.primary (n (codes.getD i 0)),4+i)) ++
  [(f r.after 15,21),(sub (f r.after 15) o,22),(sub (f r.after 15) (n 2),23),
   (sub (f r.row 4) (n 7),25),(f r.row 4,26),(sub (f r.row 4) (n 5),30),
   (sub (f r.row 4) (n 6),31),(sub (f r.after 34) (n 7),36)]

def multiplies (r : Record) : List (Linear × Linear × Nat) :=
  [(f r.flags 1,f r.after 1,11),(f r.flags 1,f r.after 2,12),(f r.flags 1,f r.after 0,13),
   (present r,f r.flags 3,19),(present r,f r.flags 2,20),(f r.after 19,f r.after 21,24),
   (f r.after 1,valuePop r,27),(f r.after 27,sub o (f r.after 25),28),
   (f r.after 0,valuePop r,29),(f r.after 19,f r.after 22,32),(f r.after 19,f r.after 23,33),
   (sub o (f r.after 36),sub o (f r.after 25),37),(f r.after 0,f r.after 33,38),
   (f r.after 38,f r.after 37,39),(f r.after 0,f r.after 40,41),
   (f r.after 1++f r.after 2,f r.after 14,42),(present r,f r.flags 7,45)]

def selects (r : Record) : List (Linear × Linear × Linear × Nat) :=
  let reset := f r.flags 0++f r.flags 1
  [(reset,tag r,f r.before 0,14),(reset,z,f r.before 1,15),(reset,z,f r.before 2,16),
   (reset,z,f r.before 3,17),(reset,z,f r.before 4,18),
   (f r.after 32,f r.row 4,f r.after 17,34),(f r.after 33,f r.row 4,f r.after 18,35),
   (f r.after 36,f r.after 35,f r.after 34,40)]

def equalities (r : Record) : List (Linear × Nat) :=
  [(f r.after 15++f r.after 19,43),(f r.after 16++f r.after 20,44)]

def guards (r : Record) : List (Linear × Linear) :=
  [(sub o (f r.flags 1),r.primary),
   (f r.after 11,sub o (validType r)),(f r.after 12,sub o (f r.after 9++f r.after 10)),(f r.after 13,r.primary),
   (f r.after 19,sub o (selectOp r)),(f r.after 19,sub (sub (sub o (f r.after 21)) (f r.after 22)) (f r.after 23)),
   (f r.after 19,f r.after 16),(f r.after 24,sub (sub o (f r.after 25)) (f r.after 26)),
   (f r.after 28,sub (f r.row 4) (f r.after 14)),(f r.after 29,f r.after 30++f r.after 31),
   (f r.after 39,sub (f r.after 34) (f r.row 4)),(f r.after 20,sub (f r.row 4) (f r.after 41++f r.after 42)),
   (f r.after 20,sub (f r.after 15) (scale (selectOp r) 3)),(f r.after 20,f r.after 16),
   (present r,f r.flags 4++f r.flags 5++f r.flags 6++f r.flags 9),
   (f r.after 45,sub (f r.after 43) (scale (selectOp r) 3)),(f r.after 45,sub (f r.after 44) o)]

def gates (r : Record) : List Gate :=
  (zeros r).flatMap (fun (input,i) => zeroGates input (f r.after i) (f r.reciprocals i)) ++
  (multiplies r).map (fun (a,b,i) => mulGate a b (f r.after i)) ++
  (selects r).map (fun (test,yes,no,i) => selectGate test yes no (f r.after i)) ++
  (equalities r).map (fun (input,i) => eqGate (f r.after i) input) ++
  (guards r).map (fun (a,b) => gate a b)

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.row.length = 10 ∧ r.flags.length = 11 ∧ r.before.length = 5 ∧ r.after.length = 46 ∧ r.reciprocals.length = 46) &&
  OperandRowCheck.includes matrix r.first r.last (gates r) && RangeUse.check matrix r.primaryRange r.primary 32

def op (s : Stage) (i k : Nat) := s.program.base.operations.getD (46*i+k) default

def record (s : Stage) (i : Nat) : Record :=
  ⟨rowAt s.rows i,rowAt s.flags i,f (rowAt s.inputs i) 0,
   [14,43,44,34,35].map (fun k => if i = 0 then z else (op s (i-1) k).call.outputs.getD 0 []),
   (List.range 46).map (fun k => (op s i k).call.outputs.getD 0 []),
   (List.range 46).map (fun k => (op s i k).call.outputs.getD 1 []),op s i 3,
   (op s i 0).call.firstGate,if i+1 < s.rows.length then (op s (i+1) 0).call.firstGate else s.program.base.lastGate⟩

def checkStage (matrix : Shape) (s : Stage) : Bool :=
  s.kind == 4 && decide (s.rows.length < 2^64) && s.program.base.operations.length == 46*s.rows.length &&
  (List.range s.rows.length).all (fun i => check matrix (record s i))
end ZkBuild.ParametricRowCheck
