import ScalarPayloadRead
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadLimits
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ScalarPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem split_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits)
    (splitChecks : splits.all (PackedFields.check matrix) = true) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kindLimit : kind = 0 ∨ kind = 1) (r : Row) (start : Linear)
    (shape : ScalarPayloadMatrix.shape tokens splits constants kind r start)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ lo hi : Nat, lo < 2^32 ∧ hi < 2^32 ∧ E values (split splits r.limitHeads).low = (lo : F) ∧
      E values (split splits r.limitHeads).high = (hi : F) ∧
      E values ((limitAt r 0).value ++ (limitAt r 2).value) = ((lo+2^32*hi : Nat) : F) := by
  have sh : r.limitHeads < splits.length ∧
      splitMatches (split splits r.limitHeads) ((limitAt r 0).value ++ (limitAt r 2).value) 32 32 := by
    rcases kindLimit with rfl | rfl <;> simp only [ScalarPayloadMatrix.shape,limitShape] at shape <;> grind only
  have sm : split splits r.limitHeads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]
    exact List.getElem_mem sh.1
  obtain ⟨word,lo,hi,_,lb,hb,wi,li,hiI,packed,_,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ sm) values oneValue satisfied
  have fields := sh.2
  refine ⟨lo,hi,by simpa only [fields.2.1] using lb,by simpa only [fields.2.2] using hb,li,hiI,?_⟩
  rw [← fields.1,wi,packed,fields.2.1]

/-- The mutually exclusive bank queries and one-bit flag memories force the
    source flag to zero or one, even for a hostile satisfying assignment. -/
theorem flag_boolean {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kindLimit : kind = 0 ∨ kind = 1) (r : Row) (start : Linear)
    (shape : ScalarPayloadMatrix.shape tokens splits constants kind r start)
    (members : ∀ i : Fin 4, limitAt r i.val ∈ (ImportMatrix.table tables imports (3+i.val)).queries)
    (banks : ∀ i : Fin 4, ReadOnlyMatrix.check matrix (ImportMatrix.table tables imports (3+i.val)) = true)
    (widths : ∀ i : Fin 4, (ImportMatrix.table tables imports (3+i.val)).memory.valueBits = (if i.val % 2 = 0 then 64 else 1))
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values ((limitAt r 1).value ++ (limitAt r 3).value) = 0 ∨
      E values ((limitAt r 1).value ++ (limitAt r 3).value) = 1 := by
  have add : E values ((limitAt r 1).value ++ (limitAt r 3).value) =
      E values (limitAt r 1).value + E values (limitAt r 3).value := eval_append values _ _
  rcases kindLimit with rfl | rfl
  · have off : (limitAt r 1).active = z := by
      simp only [ScalarPayloadMatrix.shape,limitShape] at shape
      grind only
    have zero := (ReadOnlyInactive.query_zero matrix _ (banks ⟨1,by decide⟩) values oneValue satisfied _ (members ⟨1,by decide⟩)
      (by rw [off]; simp [z,eval_constant values oneValue])).2
    obtain ⟨flag,bound,image⟩ := ReadOnlyFacts.query_value matrix _ (banks ⟨3,by decide⟩) values oneValue satisfied _ (members ⟨3,by decide⟩)
    have width : (ImportMatrix.table tables imports 6).memory.valueBits = 1 := by simpa using widths ⟨3,by decide⟩
    have fb : flag < 2 := by simpa only [width] using bound
    have f : flag = 0 ∨ flag = 1 := by omega
    rcases f with rfl | rfl <;> simp only [add,zero,image,Semiring.natCast_zero,Semiring.natCast_one] <;> grind
  · have off : (limitAt r 3).active = z := by
      simp only [ScalarPayloadMatrix.shape,limitShape] at shape
      grind only
    have zero := (ReadOnlyInactive.query_zero matrix _ (banks ⟨3,by decide⟩) values oneValue satisfied _ (members ⟨3,by decide⟩)
      (by rw [off]; simp [z,eval_constant values oneValue])).2
    obtain ⟨flag,bound,image⟩ := ReadOnlyFacts.query_value matrix _ (banks ⟨1,by decide⟩) values oneValue satisfied _ (members ⟨1,by decide⟩)
    have width : (ImportMatrix.table tables imports 4).memory.valueBits = 1 := by simpa using widths ⟨1,by decide⟩
    have fb : flag < 2 := by simpa only [width] using bound
    have f : flag = 0 ∨ flag = 1 := by omega
    rcases f with rfl | rfl <;> simp only [add,zero,image,Semiring.natCast_zero,Semiring.natCast_one] <;> grind

#print axioms split_values
#print axioms flag_boolean
end ZkBuild.ScalarPayloadLimits
