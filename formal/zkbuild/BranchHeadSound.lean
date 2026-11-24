import BranchStore
set_option autoImplicit false
namespace ZkBuild.BranchHeadSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- A selected bank head is nonempty and is present in the authenticated node store. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage)
    (checked : BranchListCheck.check matrix splits tables s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (q : ReadOnlyMatrix.Entry) (member : q ∈ (DynamicTypingMatrix.bank tables s 0).queries)
    (active : E values q.active = 1) (head : Fin (2^32)) (image : E values q.value = (head.val : F)) :
    0 < head.val ∧ ∃ cell, BranchStore.table values (DynamicTypingMatrix.bank tables s 1) head.val = some cell := by
  have parts := checked
  simp only [BranchListCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _ parts.1.1.1.2 values one satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership q member active
  obtain ⟨i,ib,same⟩ := BranchStore.member_index _ entry em
  have row := List.all_eq_true.mp parts.1.2 i (List.mem_range.mpr ib)
  have activeEntry : E values (BranchListCheck.bankRecord tables s i).entry.active = 1 := by
    change E values ((DynamicTypingMatrix.bank tables s 0).entries.getD i default).active = _
    rw [same]; exact ea
  obtain ⟨actual,positive,value,enabled,address⟩ := BranchListSound.bank matrix _ row values one satisfied activeEntry
  have vi : E values (BranchListCheck.bankRecord tables s i).entry.value = (head.val : F) := by
    change E values ((DynamicTypingMatrix.bank tables s 0).entries.getD i default).value = _
    rw [same]; exact ev.trans image
  have equal := DeclarationLocations.natural_equal (F := F) actual.val head.val (by have := actual.isLt; omega)
    (by have := head.isLt; omega) (value.symm.trans vi)
  have queryMember : (BranchListCheck.bankRecord tables s i).query ∈ (DynamicTypingMatrix.bank tables s 1).queries := by
    change (DynamicTypingMatrix.bank tables s 1).queries.getD i default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by have := parts.1.1.1.1.2.2.2.2; omega)
  obtain ⟨cell,found⟩ := BranchStore.query matrix _ parts.1.1.2 parts.1.1.1.1.2.2.2.1 values one satisfied actual _ queryMember enabled address
  exact ⟨by rw [← equal]; exact positive,cell,by simpa only [equal] using found⟩

#print axioms selected
end ZkBuild.BranchHeadSound
