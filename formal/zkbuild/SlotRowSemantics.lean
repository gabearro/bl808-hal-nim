import SlotRowSchema
import SlotSelection

namespace ZkBuild.SlotRow

open Lean.Grind RowSoundness
attribute [local instance] Ring.intCast Semiring.natCast

def FieldHolds {F : Type} [CommRing F] (values : Nat → F) : Prop :=
  ∀ expression ∈ residuals, evalField values expression = 0

theorem eval_sum {F : Type} [CommRing F] (values : Nat → F) (expressions : List Expr) :
    evalField values (sumExpr expressions) = R1CS.sum (expressions.map (evalField values)) := by
  induction expressions with
  | nil => simp [sumExpr, evalField, R1CS.sum, Ring.intCast_zero]
  | cons expression rest ih => simp [sumExpr, evalField, R1CS.sum, ih]

theorem range_values {F : Type} (n : Nat) (values : Nat → F) :
    (List.range n).map values = (List.finRange n).map (fun i => values i.val) := by
  apply List.ext_getElem
  · simp
  · intro i before after
    simp

theorem bit_constraint {F : Type} [CommRing F] (values : Nat → F) (holds : FieldHolds values)
    (i : Fin 63) : values (9+i.val) * (values (9+i.val)-1) = 0 := by
  have member : (.input (9+i.val) * (.input (9+i.val)-1) : Expr) ∈ residuals := by
    unfold residuals
    apply List.mem_append_left
    exact List.mem_map.mpr ⟨i.val, List.mem_range.mpr i.isLt, rfl⟩
  have equation := holds _ member
  change values (9+i.val) * (values (9+i.val)-((1 : Int) : F)) = 0 at equation
  simpa only [Ring.intCast_one] using equation

theorem selector_sum {F : Type} [CommRing F] (values : Nat → F) (holds : FieldHolds values) :
    R1CS.sum ((List.finRange 10).map fun i => values (9+i.val)) = 1 := by
  have member : sumExpr ((List.range 10).map selected) - 1 ∈ residuals := by
    unfold residuals
    apply List.mem_append_right
    exact List.Mem.head _
  have equation := holds _ member
  change evalField values (sumExpr ((List.range 10).map selected)) - ((1 : Int) : F) = 0 at equation
  rw [Ring.intCast_one] at equation
  rw [eval_sum] at equation
  have expanded : R1CS.sum ((List.range 10).map fun i => values (9+i)) - 1 = 0 := by
    simpa only [List.map_map, Function.comp_def, selected, evalField] using equation
  rw [range_values] at expanded
  grind

theorem selectors_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : FieldHolds values) :
    ∃ kind : Fin 10, ∀ i : Fin 10, values (9+i.val) = if i = kind then 1 else 0 := by
  apply SlotSelection.one_hot_function (fun i : Fin 10 => values (9+i.val)) (by decide)
  · intro i
    exact bit_constraint values holds ⟨i.val, by have := i.isLt; omega⟩
  · exact selector_sum values holds

def specialize (kind : Fin 10) (depth : Fin 9) : Expr → Expr
  | .literal value => .literal value
  | .input i => if i < 9 then .literal (if i = depth.val then 1 else 0)
    else if i < 19 then .literal (if i-9 = kind.val then 1 else 0) else .input i
  | .add a b => .add (specialize kind depth a) (specialize kind depth b)
  | .sub a b => .sub (specialize kind depth a) (specialize kind depth b)
  | .mul a b => .mul (specialize kind depth a) (specialize kind depth b)

def depthValues (kind : Fin 10) (depth : Fin 9) : List Nat :=
  (List.range 9).map fun output =>
    if SlotShape.valid kind.val depth.val && SlotShape.nextDepth kind.val depth.val == output then 1 else 0

def depthExpressions (kind : Fin 10) (depth : Fin 9) : List Expr :=
  (depthValues kind depth).map fun value => .literal (Int.ofNat value)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem depth_certificate : ∀ kind depth,
    RowMatrix.polynomialListEqual (nextDepths.map (specialize kind depth)) (depthExpressions kind depth) = true := by
  native_decide

theorem depth_count : ∀ kind depth, (depthValues kind depth).sum = if SlotShape.valid kind.val depth.val then 1 else 0 := by
  native_decide

theorem specialize_eval {F : Type} [CommRing F] (values : Nat → F) (kind : Fin 10) (depth : Fin 9)
    (priorValues : ∀ i, i < 9 → values i = if i = depth.val then 1 else 0)
    (selectedValues : ∀ i, i < 10 → values (9+i) = if i = kind.val then 1 else 0) (e : Expr) :
    evalField values (specialize kind depth e) = evalField values e := by
  induction e with
  | literal value => rfl
  | input i =>
    by_cases isPrior : i < 9
    · simp only [specialize, isPrior, ite_true, evalField]
      rw [priorValues i isPrior]
      split <;> simp [Ring.intCast_one, Ring.intCast_zero]
    · by_cases isSelected : i < 19
      · have same : 9+(i-9) = i := by omega
        have selection := selectedValues (i-9) (by omega)
        simp only [same] at selection
        simp only [specialize, isPrior, ite_false, isSelected, ite_true, evalField]
        rw [selection]
        split <;> simp [Ring.intCast_one, Ring.intCast_zero]
      · simp [specialize, isPrior, isSelected, evalField]
  | add a b ia ib => simp only [specialize, evalField, ia, ib]
  | sub a b ia ib => simp only [specialize, evalField, ia, ib]
  | mul a b ia ib => simp only [specialize, evalField, ia, ib]

theorem depths_determined {F : Type} [CommRing F] (ctx : Lean.RArray F) (kind : Fin 10) (depth : Fin 9)
    (priorValues : ∀ i, i < 9 → ctx.get i = if i = depth.val then 1 else 0)
    (selectedValues : ∀ i, i < 10 → ctx.get (9+i) = if i = kind.val then 1 else 0) :
    nextDepths.map (evalField ctx.get) = (depthValues kind depth).map (fun value : Nat => (value : F)) := by
  have result := RowMatrix.polynomial_list_sound ctx _ _ (depth_certificate kind depth)
  simpa only [List.map_map, Function.comp_def, specialize_eval ctx.get kind depth priorValues selectedValues,
    depthExpressions, evalField, Int.ofNat_eq_natCast, Ring.intCast_natCast] using result

theorem sum_natCast {F : Type} [CommRing F] (values : List Nat) :
    R1CS.sum (values.map fun value : Nat => (value : F)) = (values.sum : F) := by
  induction values with
  | nil => simp [R1CS.sum, Semiring.natCast_zero]
  | cons value rest ih => simp [R1CS.sum, ih, Semiring.natCast_add]

theorem valid_transition {F : Type} [Field F] (ctx : Lean.RArray F) (kind : Fin 10) (depth : Fin 9)
    (priorValues : ∀ i, i < 9 → ctx.get i = if i = depth.val then 1 else 0)
    (selectedValues : ∀ i, i < 10 → ctx.get (9+i) = if i = kind.val then 1 else 0)
    (holds : FieldHolds ctx.get) : SlotShape.valid kind.val depth.val = true := by
  have member : sumExpr nextDepths - 1 ∈ residuals := by
    unfold residuals
    apply List.mem_append_right
    simp
  have equation := holds _ member
  change evalField ctx.get (sumExpr nextDepths) - ((1 : Int) : F) = 0 at equation
  rw [Ring.intCast_one, eval_sum, depths_determined ctx kind depth priorValues selectedValues,
    sum_natCast, depth_count] at equation
  cases isValid : SlotShape.valid kind.val depth.val
  · simp only [isValid, Bool.false_eq_true, ite_false, Semiring.natCast_zero] at equation
    have impossible : (0 : F) = 1 := by grind
    exact False.elim (Field.zero_ne_one impossible)
  · rfl

#print axioms selectors_determined
#print axioms depths_determined
#print axioms valid_transition

end ZkBuild.SlotRow
