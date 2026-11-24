import BranchLookupCheck
import ReadOnlyFacts
set_option autoImplicit false
namespace ZkBuild.BranchLookupSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix BranchLookupCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem query_selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : BranchLookupCheck.check matrix tables indexed r = true)
    (merged : BranchMergeCheck.checkStage matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i < (StructuredMatrix.stage r 5).rows.length) (fb : family < 4)
    (active : E values (BranchMergeCheck.record r i family).branch.active = 1) :
    query tables indexed r i family ∈ (bank tables indexed r family).queries ∧
    DynamicTypingSource.SameEntry values (query tables indexed r i family) (BranchMergeCheck.record r i family).branch := by
  have parts := checked
  simp only [BranchLookupCheck.check,Bool.and_eq_true_iff] at parts
  have rc := _root_.of_decide_eq_true (List.all_eq_true.mp (List.all_eq_true.mp parts.2 i (List.mem_range.mpr ib)) family (List.mem_range.mpr fb))
  have mc := List.all_eq_true.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp merged).2 i (List.mem_range.mpr ib)) family (List.mem_range.mpr fb)
  have selected := (BranchMergeSound.branch_selected matrix _ mc values one satisfied active).1
  have same := DynamicTypingSource.same_entry values _ _ rc.2
  refine ⟨?_,same.1.symm.trans selected.1,same.2.1.symm.trans selected.2.1,same.2.2.symm.trans selected.2.2⟩
  unfold query
  rw [← List.getElem_eq_getD default]
  exact List.getElem_mem rc.1

/-- A branch query reaches an actual immutable initializer with the same key
    and value; the inactive control query cannot cancel or shift either. -/
theorem origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : BranchLookupCheck.check matrix tables indexed r = true)
    (merged : BranchMergeCheck.checkStage matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i < (StructuredMatrix.stage r 5).rows.length) (fb : family < 4)
    (active : E values (BranchMergeCheck.record r i family).branch.active = 1) :
    ∃ source ∈ (bank tables indexed r family).entries, E values source.active = 1 ∧
      E values source.address = E values (BranchMergeCheck.record r i family).branch.address ∧
      E values source.value = E values (BranchMergeCheck.record r i family).branch.value := by
  have parts := checked
  simp only [BranchLookupCheck.check,Bool.and_eq_true_iff] at parts
  have bc := (Bool.and_eq_true_iff.mp (List.all_eq_true.mp parts.1.2 family (List.mem_range.mpr fb))).2
  have selected := query_selected matrix tables indexed r checked merged values one satisfied i family ib fb active
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _ bc values one satisfied
  obtain ⟨source,sm,sa,sk,sv⟩ := membership _ selected.1 (selected.2.1.trans active)
  exact ⟨source,sm,sa,sk.trans selected.2.2.1,sv.trans selected.2.2.2⟩

theorem bounded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : BranchLookupCheck.check matrix tables indexed r = true)
    (merged : BranchMergeCheck.checkStage matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i < (StructuredMatrix.stage r 5).rows.length) (fb : family < 4)
    (active : E values (BranchMergeCheck.record r i family).branch.active = 1) :
    ∃ key value : Nat, key < 2^(addressBits family) ∧ value < 2^(valueBits family) ∧
      E values (BranchMergeCheck.record r i family).branch.address = (key : F) ∧
      E values (BranchMergeCheck.record r i family).branch.value = (value : F) := by
  have parts := checked
  simp only [BranchLookupCheck.check,Bool.and_eq_true_iff] at parts
  have bc := Bool.and_eq_true_iff.mp (List.all_eq_true.mp parts.1.2 family (List.mem_range.mpr fb))
  have widths := _root_.of_decide_eq_true bc.1
  obtain ⟨source,sm,_,sk,sv⟩ := origin matrix tables indexed r checked merged values one satisfied i family ib fb active
  obtain ⟨_,key,value,kb,vb,_,ki,vi⟩ := ReadOnlyFacts.entry_fields matrix _ bc.2 values one satisfied source sm
  rw [widths.1] at kb
  rw [widths.2] at vb
  exact ⟨key,value,kb,vb,sk.symm.trans ki,sv.symm.trans vi⟩

#print axioms query_selected
#print axioms origin
#print axioms bounded
end ZkBuild.BranchLookupSound
