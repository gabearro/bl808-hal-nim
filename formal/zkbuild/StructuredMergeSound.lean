import StructuredMerge
set_option autoImplicit false
namespace ZkBuild.StructuredMergeSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

-- A merged lookup is a selector union: at most one source is active and
-- inactive values are zero. This algebraic result applies to all four query
-- families merged by the matrix replay.
theorem selected_query {F : Type} [Field F] (values : Nat → F)
    (a b : List Linear) (one : values 0 = 1)
    (aBool : E values (f a 0) = 0 ∨ E values (f a 0) = 1)
    (bBool : E values (f b 0) = 0 ∨ E values (f b 0) = 1)
    (disjoint : Holds values (gate (f a 0) (f b 0))) :
    E values (f a 0 ++ f b 0) = 0 ∨ E values (f a 0 ++ f b 0) = 1 := by
  have h := disjoint
  change E values (f a 0) * E values (f b 0) = E values z at h
  simp only [z,E,eval_constant values one,Ring.intCast_zero] at h
  change evalLinear values (f a 0 ++ f b 0) = 0 ∨ evalLinear values (f a 0 ++ f b 0) = 1
  rw [eval_append]
  rcases aBool with h0|h1 <;> rcases bBool with g0|g1 <;> grind

-- Values of the inactive side cannot pollute the authenticated union query.
theorem active_value {F : Type} [Field F] (values : Nat → F)
    (a b : List Linear) (one : values 0 = 1)
    (active : E values (f a 0) = 1)
    (disjoint : Holds values (gate (f a 0) (f b 0)))
    (bZero : Holds values (gate (sub o (f b 0)) (f b 2))) :
    E values (f a 2 ++ f b 2) = E values (f a 2) := by
  have h := disjoint
  change E values (f a 0) * E values (f b 0) = E values z at h
  simp only [z,E,eval_constant values one,Ring.intCast_zero] at h
  have inactive : E values (f b 0) = 0 := by grind
  have empty : E values (f b 2) = 0 := by
    have h := bZero
    change E values (sub o (f b 0)) * E values (f b 2) = E values z at h
    simp only [E,eval_sub,o,z,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] at h
    grind
  change evalLinear values (f a 2 ++ f b 2) = E values (f a 2)
  rw [eval_append]
  change E values (f a 2) + E values (f b 2) = E values (f a 2)
  rw [empty]
  grind

#print axioms selected_query
#print axioms active_value
end ZkBuild.StructuredMergeSound
