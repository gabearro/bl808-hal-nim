import FullMatrix
import RangeReuse

/- Canonical matrices for the actual r1cs/range_check primitives. These
   semantics quantify over all field assignments, not sampled witnesses. -/
namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_one Ring.intCast_zero Ring.intCast_natCast
attribute [local simp] Semiring.one_mul Semiring.mul_one Semiring.add_zero AddCommMonoid.zero_add
attribute [local simp] Semiring.zero_mul Semiring.mul_zero

abbrev E {F : Type} [CommRing F] (values : Nat → F) (a : Linear) := evalLinear values a

def wire (i : Nat) : Linear := [(i,1)]
def eqGate (a b : Linear) : Gate := ⟨sub a b,constant 1,constant 0⟩
def boolGate (a : Linear) : Gate := ⟨a,sub a (constant 1),constant 0⟩
def mulGate (a b out : Linear) : Gate := ⟨a,b,out⟩
def zeroGates (a out reciprocal : Linear) : List Gate :=
  [⟨a,out,constant 0⟩,⟨a,reciprocal,sub (constant 1) out⟩]
def selectGate (s yes no out : Linear) : Gate := ⟨s,sub yes no,sub out no⟩

def Holds {F : Type} [CommRing F] (values : Nat → F) (g : Gate) : Prop :=
  R1CS.Holds values (interpretGate g)
def AllHold {F : Type} [CommRing F] (values : Nat → F) (gates : List Gate) : Prop :=
  ∀ g ∈ gates, Holds values g

@[simp] theorem eval_wire {F : Type} [CommRing F] (values : Nat → F) (i : Nat) :
    E values (wire i) = values i := by
  simp [E,evalLinear,wire,interpretLinear,R1CS.eval]

@[simp] theorem eval_constant {F : Type} [CommRing F] (values : Nat → F)
    (one : values 0 = 1) (n : Int) : E values (constant n) = (n : F) := by
  simp [E,evalLinear,constant,interpretLinear,R1CS.eval,one]

@[simp] theorem eval_sub {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    E values (sub a b) = E values a-E values b := by
  simp only [sub,E,FullMatrix.eval_append,FullMatrix.eval_scale]
  grind

theorem equality_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (a b : Linear) (ok : Holds values (eqGate a b)) : E values a = E values b := by
  change E values (sub a b)*E values (constant 1) = E values (constant 0) at ok
  simp [eval_sub,eval_constant values one] at ok
  grind

theorem boolean_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (a : Linear) (ok : Holds values (boolGate a)) : E values a = 0 ∨ E values a = 1 := by
  apply ZkBuild.r1cs_boolean_sound
  change E values a*E values (sub a (constant 1)) = E values (constant 0) at ok
  simpa [eval_sub,eval_constant values one] using ok

theorem multiply_sound {F : Type} [CommRing F] (values : Nat → F)
    (a b out : Linear) (ok : Holds values (mulGate a b out)) : E values out = E values a*E values b := ok.symm

theorem select_sound {F : Type} [CommRing F] (values : Nat → F)
    (s yes no out : Linear) (ok : Holds values (selectGate s yes no out)) :
    E values out = E values no + E values s*(E values yes-E values no) := by
  change E values s*E values (sub yes no) = E values (sub out no) at ok
  simp only [eval_sub] at ok
  grind

theorem select_boolean_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (s yes no out : Linear) (bit : Holds values (boolGate s))
    (ok : Holds values (selectGate s yes no out)) :
    (E values s = 0 ∧ E values out = E values no) ∨
      (E values s = 1 ∧ E values out = E values yes) := by
  have result := select_sound values s yes no out ok
  rcases boolean_sound values one s bit with zero | oneS
  · left; constructor; exact zero; simp [zero] at result; exact result
  · right; constructor; exact oneS; simp [oneS] at result; grind

theorem zero_sound {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (one : values 0 = 1)
    (a out reciprocal : Linear) (ok : AllHold values (zeroGates a out reciprocal)) :
    E values out = if E values a = 0 then 1 else 0 := by
  have first := ok ⟨a,out,constant 0⟩ (by simp [zeroGates])
  have second := ok ⟨a,reciprocal,sub (constant 1) out⟩ (by simp [zeroGates])
  apply RangeConstraints.zero_indicator (E values a) (E values out) (E values reciprocal)
  · change E values a*E values out = E values (constant 0) at first
    simpa [eval_constant values one] using first
  · change E values a*E values reciprocal = E values (sub (constant 1) out) at second
    simpa [eval_sub,eval_constant values one] using second

def rangeBits (start width : Nat) : List Linear := (List.range width).map fun i => wire (start+i)

def pack (weights : List Nat) (bits : List Linear) : Linear :=
  match weights,bits with
  | w::ws,b::bs => scale b (w : Int) ++ pack ws bs
  | _,_ => []

def rangeGates (value : Linear) (start width : Nat) : List Gate :=
  let bits := rangeBits start width
  bits.map boolGate ++ [eqGate value (pack (BitPacking.bitWeights width) bits)]

theorem eval_pack {F : Type} [CommRing F] (values : Nat → F) (weights : List Nat) (bits : List Linear) :
    E values (pack weights bits) = R1CS.weightedValues weights (bits.map (E values)) := by
  induction weights generalizing bits with
  | nil => simp [pack,E,evalLinear,interpretLinear,R1CS.eval,R1CS.weightedValues]
  | cons w ws ih =>
    cases bits with
    | nil => simp [pack,E,evalLinear,interpretLinear,R1CS.eval,R1CS.weightedValues]
    | cons b bs =>
      simp only [pack,E,FullMatrix.eval_append,FullMatrix.eval_scale,List.map_cons,R1CS.weightedValues]
      rw [show evalLinear values (pack ws bs) = R1CS.weightedValues ws (bs.map (E values)) from ih bs]
      simp only [Ring.intCast_natCast]
      rw [CommSemiring.mul_comm]

theorem range_certificate {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (value : Linear) (start width : Nat) (ok : AllHold values (rangeGates value start width)) :
    RangeReuse.Certificate width (E values value) ((rangeBits start width).map (E values)) := by
  refine ⟨by simp [rangeBits], ?_, ?_⟩
  · intro v member
    obtain ⟨b,hb,rfl⟩ := List.mem_map.mp member
    have gate := ok (boolGate b) (by simp only [rangeGates,List.mem_append,List.mem_map]; exact Or.inl ⟨b,hb,rfl⟩)
    change E values b*E values (sub b (constant 1)) = E values (constant 0) at gate
    simpa [eval_sub,eval_constant values one] using gate
  · have gate := ok (eqGate value (pack (BitPacking.bitWeights width) (rangeBits start width))) (by simp [rangeGates])
    have equal := equality_sound values one _ _ gate
    rw [← eval_pack]
    exact equal.symm

theorem range_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (value : Linear) (start width : Nat) (ok : AllHold values (rangeGates value start width)) :
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) :=
  RangeReuse.certificate_sound _ _ _ (range_certificate values one value start width ok)

#print axioms equality_sound
#print axioms boolean_sound
#print axioms multiply_sound
#print axioms select_boolean_sound
#print axioms zero_sound
#print axioms range_sound

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Artifact where
  shape : Shape
  outputs : List Linear

def affine : Linear := wire 1 ++ scale (wire 2) 2 ++ scale (wire 3) (-3)

def literalBits (value width : Nat) : List Bool :=
  (List.range width).map fun i => decide ((value / 2^i)%2 = 1)

def literalOutputs (bits : List Bool) : List Linear :=
  bits.map fun b => constant (if b then 1 else 0)

def literalGates (value width : Nat) : List Gate :=
  if BitPacking.packBits (literalBits value width) = value then []
  else [eqGate (constant 0) (constant 1)]

def artifact (kind width value : Nat) : Artifact := Id.run do
  let x := wire 1; let y := wire 2; let z := wire 3; let out := wire 4
  let mut gates : List Gate := []
  let mut outputs := [out]
  let mut wires := 5
  match kind with
  | 0 => gates := [mulGate affine z out]
  | 1 => gates := [eqGate out affine]
  | 2 => gates := [boolGate out]
  | 3 => gates := [boolGate affine]; outputs := [affine]; wires := 4
  | 4 => gates := zeroGates affine out (wire 5); wires := 6
  | 5 => gates := [selectGate x y z out]
  | 6 => gates := [mulGate x (sub y z) out]; outputs := [z ++ out]
  | 7 | 8 | 9 | 10 | 11 | 12 | 15 | 16 =>
    let input := if kind = 10 || kind = 11 then affine else if kind = 15 then scale x 2 else x
    let bits := rangeBits 4 width
    gates := rangeGates input 4 width
    outputs := bits
    wires := 4+width
    if kind = 8 then outputs := bits ++ bits
    if kind = 9 || kind = 11 || kind = 12 || kind = 15 || kind = 16 then
      let next := if kind = 12 then (width+1)%249 else width
      outputs := bits ++ rangeBits wires next
      gates := gates ++ rangeGates (if kind = 16 then y else input) wires next
      wires := wires+next
  | 13 | 14 =>
    let bits := literalBits value width
    outputs := literalOutputs bits
    wires := 4
    gates := literalGates value width
  | _ => pure ()
  return ⟨{ wires := wires, publicCount := 3, gates := gates.toArray },outputs⟩

-- This is the link from matrix conformance to universal field semantics.
-- It applies to any actual matrix with the same canonical field coefficients.
theorem checked_range_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Shape) (values : Nat → F) (one : values 0 = 1)
    (value : Linear) (start width : Nat)
    (checked : actual.gates.toList.map normalizeGate = (rangeGates value start width).map normalizeGate)
    (satisfied : Satisfied actual values) :
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) := by
  let model : Shape := { gates := (rangeGates value start width).toArray }
  have same : actual.gates.toList.map normalizeGate = model.gates.toList.map normalizeGate := by
    simpa [model] using checked
  have holds := (same_canonical_matrix_same_relation actual model same values).mp satisfied
  exact range_sound values one value start width (by simpa [Satisfied,model,AllHold,Holds] using holds)

theorem impossible_literal_rejected {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (gate : Holds values (eqGate (constant 0) (constant 1))) : False := by
  have equal := equality_sound values one _ _ gate
  simp only [E,FullMatrix.evalLinear,CircuitShape.constant,CircuitShape.interpretLinear,
    List.map_cons,List.map_nil,R1CS.eval,one,Ring.intCast_zero,Ring.intCast_one,
    Semiring.zero_mul,Semiring.one_mul,Semiring.add_zero] at equal
  exact Field.zero_ne_one equal

#print axioms checked_range_sound
#print axioms impossible_literal_rejected

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

-- Width <= 248 turns the field relation into a unique canonical unsigned
-- integer. In particular an out-of-range canonical scalar cannot wrap around.
theorem checked_range_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Shape) (values : Nat → F) (one : values 0 = 1)
    (value : Linear) (start width : Nat) (small : width ≤ 248)
    (checked : actual.gates.toList.map normalizeGate = (rangeGates value start width).map normalizeGate)
    (satisfied : Satisfied actual values) :
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) ∧
      ∀ m : Nat, m < 2^width → E values value = (m : F) → m = n := by
  obtain ⟨n,bound,represented⟩ := checked_range_sound actual values one value start width checked satisfied
  refine ⟨n,bound,represented,?_⟩
  intro m mb image
  have nm := RangeConstraints.power_below_modulus width small
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans mb nm) (Nat.lt_trans bound nm)).mp (image.symm.trans represented)

theorem literal_outputs_evaluate {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (bits : List Bool) :
    (literalOutputs bits).map (E values) = bits.map (R1CS.boolValue (F := F)) := by
  induction bits with
  | nil => rfl
  | cons bit rest ih =>
    cases bit <;> simp [literalOutputs,R1CS.boolValue,eval_constant values one,ih,
      Ring.intCast_zero,Ring.intCast_one]

theorem literal_matrix_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (value width : Nat) (holds : AllHold values (literalGates value width)) :
    RangeReuse.Certificate width (value : F) ((literalOutputs (literalBits value width)).map (E values)) := by
  by_cases same : BitPacking.packBits (literalBits value width) = value
  · rw [literal_outputs_evaluate values one]
    have valid := RangeReuse.literal_certificate (F := F) (literalBits value width)
    rw [same] at valid
    simpa [literalBits] using valid
  · have bad := holds (eqGate (constant 0) (constant 1)) (by simp [literalGates,same])
    exact False.elim (impossible_literal_rejected values one bad)

theorem literal_field_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (value width : Nat) (canonical : value < scalarModulus) (small : width ≤ 248) :
    ((BitPacking.packBits (literalBits value width) : Nat) : F) = (value : F) ↔
      BitPacking.packBits (literalBits value width) = value := by
  have packed := BitPacking.packed_bits_bounded (literalBits value width)
  have length : (literalBits value width).length = width := by simp [literalBits]
  rw [length] at packed
  exact IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans packed (RangeConstraints.power_below_modulus width small)) canonical

theorem checked_literal_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Shape) (values : Nat → F) (one : values 0 = 1) (value width : Nat)
    (checked : actual.gates.toList.map normalizeGate = (literalGates value width).map normalizeGate)
    (satisfied : Satisfied actual values) :
    RangeReuse.Certificate width (value : F) ((literalOutputs (literalBits value width)).map (E values)) := by
  let model : Shape := { gates := (literalGates value width).toArray }
  have same : actual.gates.toList.map normalizeGate = model.gates.toList.map normalizeGate := by
    simpa [model] using checked
  have holds := (same_canonical_matrix_same_relation actual model same values).mp satisfied
  exact literal_matrix_sound values one value width (by simpa [Satisfied,model,AllHold,Holds] using holds)

#print axioms literal_field_guard
#print axioms checked_literal_sound
#print axioms checked_range_unique
#print axioms literal_matrix_sound

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def conforms (actual expected : Artifact) : Bool :=
  actual.shape.wires == expected.shape.wires &&
  actual.shape.publicCount == expected.shape.publicCount &&
  actual.shape.gates.toList.map normalizeGate == expected.shape.gates.toList.map normalizeGate &&
  actual.outputs.map normalizeLinear == expected.outputs.map normalizeLinear

theorem conforms_fields (actual expected : Artifact) (checked : conforms actual expected = true) :
    actual.shape.wires = expected.shape.wires ∧ actual.shape.publicCount = expected.shape.publicCount ∧
    actual.shape.gates.toList.map normalizeGate = expected.shape.gates.toList.map normalizeGate ∧
    actual.outputs.map normalizeLinear = expected.outputs.map normalizeLinear := by
  simpa [conforms,Bool.and_eq_true_iff,and_assoc] using checked

theorem conformance_relation {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (actual expected : Artifact) (checked : conforms actual expected = true) (values : Nat → F) :
    (Satisfied actual.shape values ↔ Satisfied expected.shape values) ∧
      actual.outputs.map (E values) = expected.outputs.map (E values) := by
  have fields := conforms_fields actual expected checked
  refine ⟨same_canonical_matrix_same_relation actual.shape expected.shape fields.2.2.1 values,?_⟩
  have same := congrArg (List.map (fun linear => E values (linear : Linear))) fields.2.2.2
  change actual.outputs.map (fun l => R1CS.eval values (interpretLinear l)) =
    expected.outputs.map (fun l => R1CS.eval values (interpretLinear l))
  simpa only [List.map_map,Function.comp_def,E,FullMatrix.evalLinear,normalized_linear_same_field] using same

theorem conformance_unsigned {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (width : Nat) (small : width ≤ 248)
    (checked : conforms actual (artifact 7 width 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    ∃ n : Nat, n < 2^width ∧ values 1 = (n : F) ∧
      ∀ m : Nat, m < 2^width → values 1 = (m : F) → m = n := by
  have fields := conforms_fields actual (artifact 7 width 0) checked
  have gates : actual.shape.gates.toList.map normalizeGate = (rangeGates (wire 1) 4 width).map normalizeGate := by
    simpa [artifact] using fields.2.2.1
  simpa using checked_range_unique actual.shape values one (wire 1) 4 width small gates satisfied

#print axioms conforms_fields
#print axioms conformance_relation
#print axioms conformance_unsigned

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem conformance_literal {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (value width : Nat)
    (checked : conforms actual (artifact 13 width value) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    RangeReuse.Certificate width (value : F) (actual.outputs.map (E values)) := by
  have transfer := conformance_relation actual (artifact 13 width value) checked values
  rw [transfer.2]
  have model := transfer.1.mp satisfied
  have literal : AllHold values (literalGates value width) := by
    simpa [Satisfied,AllHold,Holds,artifact] using model
  have result := literal_matrix_sound values one value width literal
  simpa [artifact] using result

theorem conformance_cached_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (width : Nat)
    (checked : conforms actual (artifact 8 width 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    ∃ bits : List F, actual.outputs.map (E values) = bits ++ bits ∧
      RangeReuse.Certificate width (values 1) bits := by
  have transfer := conformance_relation actual (artifact 8 width 0) checked values
  refine ⟨(rangeBits 4 width).map (E values),?_,?_⟩
  · simpa [artifact,List.map_append] using transfer.2
  · have model := transfer.1.mp satisfied
    have holds : AllHold values (rangeGates (wire 1) 4 width) := by
      simpa [Satisfied,AllHold,Holds,artifact] using model
    simpa using range_certificate values one (wire 1) 4 width holds

#print axioms conformance_literal
#print axioms conformance_cached_range

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

def requiredRangeCases : List (Nat × Nat × Nat) :=
  (List.range 249).flatMap fun width => [7,8,9].map fun kind => (kind,width,0)

def requiredCases : List (Nat × Nat × Nat) :=
  (List.range 7).map (fun kind => (kind,0,0)) ++ requiredRangeCases ++
  [0,1,3,8,31,32,63,64,127,128,247,248].flatMap (fun width =>
    [10,11,12,15,16].map fun kind => (kind,width,0)) ++
  (List.range 249).flatMap (fun width =>
    [0,1,2^width-1,2^width,ZkBuild.scalarModulus-1].flatMap fun value =>
      [13,14].map fun kind => (kind,width,value))

theorem every_unsigned_width (width : Nat) (bound : width < 249) :
    (7,width,0) ∈ requiredRangeCases ∧ (8,width,0) ∈ requiredRangeCases ∧
      (9,width,0) ∈ requiredRangeCases := by
  have inside : width ∈ List.range 249 := List.mem_range.mpr bound
  have each (kind : Nat) (member : kind ∈ [7,8,9]) : (kind,width,0) ∈ requiredRangeCases := by
    simp only [requiredRangeCases,List.mem_flatMap,List.mem_map]
    exact ⟨width,inside,kind,member,rfl⟩
  exact ⟨each 7 (by simp),each 8 (by simp),each 9 (by simp)⟩

#print axioms every_unsigned_width

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem conformance_canonical_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (width input : Nat) (small : width ≤ 248) (canonical : input < scalarModulus)
    (checked : conforms actual (artifact 7 width 0) = true)
    (values : Nat → F) (one : values 0 = 1) (image : values 1 = (input : F))
    (satisfied : Satisfied actual.shape values) : input < 2^width := by
  obtain ⟨n,bound,represented,_⟩ := conformance_unsigned actual width small checked values one satisfied
  have nb := Nat.lt_trans bound (RangeConstraints.power_below_modulus width small)
  have same := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus canonical nb).mp
    (image.symm.trans represented)
  simpa [same] using bound

#print axioms conformance_canonical_range

end ZkBuild.GadgetShape

namespace ZkBuild.GadgetShape

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem conformance_range_certificate {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (width : Nat) (checked : conforms actual (artifact 7 width 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    RangeReuse.Certificate width (values 1) (actual.outputs.map (E values)) := by
  have transfer := conformance_relation actual (artifact 7 width 0) checked values
  rw [transfer.2]
  have model := transfer.1.mp satisfied
  have gates : AllHold values (rangeGates (wire 1) 4 width) := by
    simpa [Satisfied,AllHold,Holds,artifact] using model
  have result := range_certificate values one (wire 1) 4 width gates
  simpa [artifact] using result

#print axioms conformance_range_certificate

end ZkBuild.GadgetShape
