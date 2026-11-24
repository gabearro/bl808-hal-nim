import SegmentPayloadSpans
set_option autoImplicit false
namespace ZkBuild.SegmentPayloadRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SegmentPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem count_cons {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1) (r : Row) (rs : List Row) :
    E values (sumActive (r::rs)) = E values (f r 0) + E values (sumActive rs) := by
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have nil : E values z = 0 := by simp [z,eval_constant values oneValue]
  simp only [sumActive,List.flatMap_cons,add,nil]
  grind

theorem bounded_count {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1) (rows : List Row)
    (bits : ∀ r ∈ rows, E values (f r 0) = 0 ∨ E values (f r 0) = 1) :
    ∃ n : Nat, n ≤ rows.length ∧ E values (sumActive rows) = (n : F) := by
  induction rows with
  | nil => exact ⟨0,by simp,by simp [sumActive,z,eval_constant values oneValue]⟩
  | cons r rs ih =>
    obtain ⟨n,bound,image⟩ := ih (by intro x xm; exact bits x (by simp [xm]))
    rcases bits r (by simp) with no | yes
    · exact ⟨n,by simp; omega,by rw [count_cons values oneValue,no,image]; grind⟩
    · refine ⟨n+1,by simp; omega,?_⟩
      rw [count_cons values oneValue,yes,image,Semiring.natCast_add,Semiring.natCast_one]
      grind

theorem normalized_fields {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (xs ys : List (List Linear))
    (same : xs.map (List.map normalizeLinear) = ys.map (List.map normalizeLinear)) :
    xs.map (List.map (E values)) = ys.map (List.map (E values)) := by
  have h := congrArg (List.map (List.map (fun l => R1CS.eval values (interpretLinear (F := F) l)))) same
  change xs.map (fun row => row.map (fun l => R1CS.eval values (interpretLinear (F := F) l))) =
    ys.map (fun row => row.map (fun l => R1CS.eval values (interpretLinear (F := F) l)))
  simpa only [List.map_map,Function.comp_def,normalized_linear_same_field] using h

#print axioms bounded_count
#print axioms normalized_fields
end ZkBuild.SegmentPayloadRules
