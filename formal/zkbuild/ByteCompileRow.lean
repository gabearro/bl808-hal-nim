import ByteCompileQueue

/- Each byte-to-operation bridge row is a 28-gate, 27-fresh-wire relation.
   This independent template is substituted into all 121 rows of the actual
   combined matrix. The theorems apply to arbitrary satisfying assignments. -/
namespace ZkBuild.ByteCompileRow

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
attribute [local instance] Ring.intCast Semiring.natCast

def wire (i : Nat) : Linear := [(i, 1)]
def bits (count : Nat) : Linear := weighted ((List.range count).toArray.map fun i => wire (7+i))
def payloadBits (i : Nat) : Linear := bits (if i = 4 then 4 else 7)
def payload : Linear := ((List.range 5).map fun i => scale (wire (40+i)) (Int.ofNat (2^(7*i)))).flatten
def signExtension : Linear := ((List.range 4).map fun i =>
  scale (wire (2+i)) (Int.ofNat (2^32-2^(7*(i+1))))).flatten
def binary : Linear := ((List.range 6).map fun i => wire (17+i)).flatten
def event : Linear := wire 1 ++ wire 16 ++ binary
def binaryToken : Linear := ((List.range 6).map fun i => scale (wire (17+i)) (Int.ofNat (i+4))).flatten
def token : Linear := wire 49 ++ wire 50 ++ binaryToken
def queueYes (i : Nat) : Linear := if i+1 < 16 then wire (25+i) else token

-- Inputs: get(1), five LEB phases(2..6), byte bits(7..14), begin(15),
-- finish(16), six binary selectors(17..22), old immediate(23), queue(24..39).
def gate (i : Nat) : Gate :=
  if i < 5 then ⟨wire (2+i), payloadBits i, wire (40+i)⟩
  else if i = 5 then ⟨sub (constant 1) (wire 14), wire 13, wire 45⟩
  else if i = 6 then ⟨wire 45, signExtension, wire 46⟩
  else if i = 7 then ⟨wire 15, sub (constant 0) (wire 23), sub (wire 47) (wire 23)⟩
  else if i = 8 then ⟨sub (wire 48) (wire 47 ++ payload ++ wire 46), constant 1, constant 0⟩
  else if i = 9 then ⟨wire 1, constant 1 ++ wire 7, wire 49⟩
  else if i = 10 then ⟨wire 16, constant 3 ++ scale (wire 48) 16, wire 50⟩
  else if i = 11 then ⟨event, wire 24, constant 0⟩
  else ⟨event, sub (queueYes (i-12)) (wire (24+(i-12))),
    sub (wire (51+(i-12))) (wire (24+(i-12)))⟩

def sourceRow (i : Fin 121) : RowInfo := byteShape.rows[i.val]!
def source (_i : Fin 121) (linear : Linear) : Linear := substitute byteMap linear

def rowMap (i : Fin 121) (k : Nat) : Linear :=
  if k = 0 then constant 1
  else if k = 1 then source i (lookupLinear (sourceRow i).inputs 1)
  else if k < 7 then source i (lookupLinear (sourceRow i).inputs k)
  else if k < 15 then source i (lookupLinear (sourceRow i).inputs (17+k-7))
  else if k = 15 then source i (wire ((sourceRow i).wireStart+2))
  else if k = 16 then source i (wire ((sourceRow i).wireStart+10))
  else if k < 23 then source i (wire ((sourceRow i).wireStart+3+(k-17)))
  else if k = 23 then
    if i.val = 0 then constant 0 else wire (17994+(i.val-1)*27+8)
  else if k < 40 then
    if i.val = 0 then constant 0 else wire (17994+(i.val-1)*27+11+(k-24))
  else wire (17994+i.val*27+(k-40))

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem all_rows_match : ∀ (i : Fin 121) (j : Fin 28),
    ByteCompileShape.shape.gates[20135+i.val*28+j.val]? = some (substituteGate (rowMap i) (gate j.val)) := by
  native_decide

def localValues {F : Type} [CommRing F] (values : Nat → F) (i : Fin 121) : Nat → F :=
  fun k => evalLinear values (rowMap i k)

def Holds {F : Type} [CommRing F] (values : Nat → F) : Prop :=
  ∀ j : Fin 28, R1CS.Holds values (interpretGate (gate j.val))

theorem all_rows_hold {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied ByteCompileShape.shape values) (i : Fin 121) : Holds (localValues values i) := by
  intro j
  apply gate_substitution_sound values (rowMap i) (gate j.val)
  exact holds _ (by simpa using Array.mem_of_getElem? (all_rows_match i j))

theorem eval_wire {F : Type} [CommRing F] (values : Nat → F) (i : Nat) :
    evalLinear values (wire i) = values i := by
  simp [wire, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]

theorem eval_constant {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (n : Int) :
    evalLinear values (constant n) = (n : F) := by
  simp [constant, evalLinear, interpretLinear, R1CS.eval, one, Semiring.mul_one, Semiring.add_zero]

theorem eval_sub {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    evalLinear values (sub a b) = evalLinear values a - evalLinear values b := by
  rw [sub, eval_append, eval_scale]
  simp only [Ring.intCast_neg, Ring.intCast_one]
  grind

theorem local_one {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (i : Fin 121) :
    localValues values i 0 = 1 := by
  simp only [localValues, rowMap, ite_true, eval_constant values one, Ring.intCast_one]

theorem payload_equations {F : Type} [CommRing F] (values : Nat → F) (holds : Holds values) (j : Fin 5) :
    values (40+j.val) = values (2+j.val) * evalLinear values (payloadBits j.val) := by
  have eq := holds ⟨j.val, by omega⟩
  simp only [gate, j.isLt, ite_true] at eq
  change evalLinear values (wire (2+j.val)) * evalLinear values (payloadBits j.val) =
    evalLinear values (wire (40+j.val)) at eq
  simpa only [eval_wire] using eq.symm

theorem negative_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) : values 45 = (1-values 14)*values 13 := by
  have eq := holds ⟨5, by decide⟩
  change evalLinear values (sub (constant 1) (wire 14)) * evalLinear values (wire 13) =
    evalLinear values (wire 45) at eq
  simpa only [eval_sub, eval_constant values one, Ring.intCast_one, eval_wire] using eq.symm

theorem sign_equation {F : Type} [CommRing F] (values : Nat → F) (holds : Holds values) :
    values 46 = values 45 * evalLinear values signExtension := by
  have eq := holds ⟨6, by decide⟩
  change evalLinear values (wire 45) * evalLinear values signExtension = evalLinear values (wire 46) at eq
  simpa only [eval_wire] using eq.symm

theorem reset_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) : values 47 = (1-values 15)*values 23 := by
  have eq := holds ⟨7, by decide⟩
  change evalLinear values (wire 15) * evalLinear values (sub (constant 0) (wire 23)) =
    evalLinear values (sub (wire 47) (wire 23)) at eq
  simp only [eval_sub, eval_constant values one, Ring.intCast_zero, eval_wire] at eq
  grind

theorem immediate_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) :
    values 48 = values 47 + evalLinear values payload + values 46 := by
  have eq := holds ⟨8, by decide⟩
  change evalLinear values (sub (wire 48) (wire 47 ++ payload ++ wire 46)) *
    evalLinear values (constant 1) = evalLinear values (constant 0) at eq
  simp only [eval_sub, eval_append, eval_constant values one, Ring.intCast_zero,
    Ring.intCast_one, eval_wire] at eq
  grind

theorem get_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) : values 49 = values 1 * (1+values 7) := by
  have eq := holds ⟨9, by decide⟩
  change evalLinear values (wire 1) * evalLinear values (constant 1 ++ wire 7) =
    evalLinear values (wire 49) at eq
  simpa only [eval_append, eval_constant values one, Ring.intCast_one, eval_wire] using eq.symm

theorem constant_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) : values 50 = values 16 * ((3 : Int) + (16 : Int)*values 48) := by
  have eq := holds ⟨10, by decide⟩
  change evalLinear values (wire 16) * evalLinear values (constant 3 ++ scale (wire 48) 16) =
    evalLinear values (wire 50) at eq
  simpa only [eval_append, eval_scale, eval_constant values one, eval_wire] using eq.symm

theorem overflow_equation {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (holds : Holds values) : evalLinear values event * values 24 = 0 := by
  have eq := holds ⟨11, by decide⟩
  change evalLinear values event * evalLinear values (wire 24) = evalLinear values (constant 0) at eq
  simpa only [eval_wire, eval_constant values one, Ring.intCast_zero] using eq

theorem queue_equation {F : Type} [CommRing F] (values : Nat → F) (holds : Holds values) (j : Fin 16) :
    values (51+j.val) = values (24+j.val) + evalLinear values event *
      (evalLinear values (queueYes j.val) - values (24+j.val)) := by
  have eq := holds ⟨12+j.val, by omega⟩
  have notProduct : ¬12+j.val < 5 := by omega
  have not5 : ¬12+j.val = 5 := by omega
  have not6 : ¬12+j.val = 6 := by omega
  have not7 : ¬12+j.val = 7 := by omega
  have not8 : ¬12+j.val = 8 := by omega
  have not9 : ¬12+j.val = 9 := by omega
  have not10 : ¬12+j.val = 10 := by omega
  have not11 : ¬12+j.val = 11 := by omega
  simp only [gate, notProduct, not5, not6, not7, not8, not9, not10, not11,
    ite_false, Nat.add_sub_cancel_left] at eq
  change evalLinear values event * evalLinear values (sub (queueYes j.val) (wire (24+j.val))) =
    evalLinear values (sub (wire (51+j.val)) (wire (24+j.val))) at eq
  simp only [eval_sub, eval_wire] at eq
  grind

#print axioms all_rows_hold
#print axioms immediate_equation
#print axioms queue_equation

end ZkBuild.ByteCompileRow
