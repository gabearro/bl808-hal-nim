import ScalarPayloadRules
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadCounts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ScalarPayloadMatrix ScalarPayloadRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem count_cons {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1) (r : Row) (rs : List Row) :
    E values (count (r::rs)) = E values r.active+E values (count rs) := by
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  simp only [count,List.flatMap_cons,add,zero]
  grind

theorem bounded_count {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1) (rs : List Row)
    (bits : ∀ r ∈ rs, E values r.active = 0 ∨ E values r.active = 1) :
    ∃ n : Nat, n ≤ rs.length ∧ E values (count rs) = (n : F) := by
  induction rs with
  | nil => exact ⟨0,by simp,by simp [count,z,eval_constant values oneValue]⟩
  | cons r rs ih =>
    obtain ⟨n,nb,ni⟩ := ih (by intro x xm; exact bits x (by simp [xm]))
    have h := bits r (by simp)
    rcases h with zero | one
    · refine ⟨n,by simp; omega,?_⟩
      rw [count_cons values oneValue,zero,ni]
      grind
    · refine ⟨n+1,by simp; omega,?_⟩
      rw [count_cons values oneValue,one,ni,Semiring.natCast_add,Semiring.natCast_one]
      grind

theorem checked_count {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (tokenChecks : body.tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (payload : ScalarPayloadMatrix.Record) (checked : ScalarPayloadMatrix.check matrix body tables splits imports constants payload = true)
    (kind : Nat) (kb : kind < 4) (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n ≤ (getRows payload kind).length ∧ n < 2^32 ∧
      E values (count (getRows payload kind)) = (n : F) ∧ E values (size body kind) = (n : F) := by
  have rowsCheck := (kind_checked matrix body tables splits imports constants payload checked kind kb).1
  have bits : ∀ row ∈ getRows payload kind, E values row.active = 0 ∨ E values row.active = 1 := by
    intro row member
    obtain ⟨i,s,p,rc⟩ := member_check matrix body.tokens splits imports constants kind _ 0 _ o rowsCheck row member
    exact active_boolean matrix body.tokens tokenChecks splits imports constants kind kb row i s p rc values oneValue satisfied
  obtain ⟨n,nb,ni⟩ := bounded_count values oneValue _ bits
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have rowsBound : (getRows payload kind).length < 2^32 := facts.2.2.2.1 ⟨kind,kb⟩
  have closed := (closing matrix body tables splits imports constants payload checked kind kb values oneValue satisfied).2
  exact ⟨n,nb,by omega,ni,closed.symm.trans ni⟩

#print axioms bounded_count
#print axioms checked_count
end ZkBuild.ScalarPayloadCounts
