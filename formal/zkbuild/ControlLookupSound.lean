import ControlLookupCheck
import ReadOnlyInactive
set_option autoImplicit false
namespace ZkBuild.ControlLookupSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ControlLookupCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem table_checked (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : check matrix tables indexed r=true)
    (family : Nat) (fb : family<6) : ReadOnlyMatrix.check matrix (bank tables indexed r family)=true := by
  have parts := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1
  simp only [BranchLookupCheck.check,Bool.and_eq_true_iff] at parts
  exact (Bool.and_eq_true_iff.mp (List.all_eq_true.mp parts.1.2 (familyBank family)
    (List.mem_range.mpr (family_bound family fb)))).2

theorem query_selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (fb : family<6)
    (active : E values (control r i family).active=1) :
    query tables indexed r i family ∈ (bank tables indexed r family).queries ∧
      DynamicTypingSource.SameEntry values (query tables indexed r i family) (control r i family) := by
  have parts := checked
  simp only [ControlLookupCheck.check,Bool.and_eq_true_iff] at parts
  by_cases small : family<4
  · have merged := parts.1.2
    have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp merged).1
    have inside : i<(StructuredMatrix.stage r 5).rows.length := by
      omega
    have bc := parts.1.1
    simp only [BranchLookupCheck.check,Bool.and_eq_true_iff] at bc
    have rc := _root_.of_decide_eq_true (List.all_eq_true.mp (List.all_eq_true.mp bc.2 i (List.mem_range.mpr inside)) family (List.mem_range.mpr small))
    have mc := List.all_eq_true.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp merged).2 i (List.mem_range.mpr inside)) family (List.mem_range.mpr small)
    have selected := (BranchMergeSound.control_selected matrix _ mc values one satisfied active).1
    have same := DynamicTypingSource.same_entry values _ _ rc.2
    have member : BranchLookupCheck.query tables indexed r i family ∈ (BranchLookupCheck.bank tables indexed r family).queries := by
      unfold BranchLookupCheck.query
      rw [← List.getElem_eq_getD default]
      exact List.getElem_mem rc.1
    simpa only [query,position,bank,family_small family small,small,ite_true,Nat.add_zero,ControlLookupCheck.control,DynamicTypingSource.SameEntry,BranchMergeCheck.record,
      BranchLookupCheck.query] using
      And.intro member (And.intro (same.1.symm.trans selected.1)
        (And.intro (same.2.1.symm.trans selected.2.1) (same.2.2.symm.trans selected.2.2)))
  · have familyEq : family-4+4=family := by omega
    have rc := _root_.of_decide_eq_true (List.all_eq_true.mp
      (List.all_eq_true.mp parts.2 i (List.mem_range.mpr ib)) (family-4) (List.mem_range.mpr (by omega)))
    rw [familyEq] at rc
    have same := DynamicTypingSource.same_entry values _ _ rc.2
    refine ⟨?_,same.1.symm,same.2.1.symm,same.2.2.symm⟩
    unfold query
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem rc.1

theorem origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (fb : family<6)
    (active : E values (control r i family).active=1) :
    ∃ source ∈ (bank tables indexed r family).entries, E values source.active=1 ∧
      E values source.address=E values (control r i family).address ∧
      E values source.value=E values (control r i family).value := by
  have selected := query_selected matrix tables indexed r checked values one satisfied i family ib fb active
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _
    (table_checked matrix tables indexed r checked family fb) values one satisfied
  obtain ⟨source,sm,sa,sk,sv⟩ := membership _ selected.1 (selected.2.1.trans active)
  exact ⟨source,sm,sa,sk.trans selected.2.2.1,sv.trans selected.2.2.2⟩

theorem inactive {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (fb : family<4)
    (inactive : E values (control r i family).active=0) :
    E values (control r i family).address=0 ∧ E values (control r i family).value=0 := by
  have merged := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp merged).1
  have inside : i<(StructuredMatrix.stage r 5).rows.length := by
    omega
  have mc := List.all_eq_true.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp merged).2 i (List.mem_range.mpr inside)) family (List.mem_range.mpr fb)
  exact (BranchMergeSound.meaning matrix _ mc values one satisfied).controlZero inactive

#print axioms table_checked
#print axioms query_selected
#print axioms origin
#print axioms inactive

theorem inactive_direct {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (checked : check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (kind : family=4 ∨ family=5)
    (inactive : E values (control r i family).active=0) :
    E values (control r i family).address=0 ∧ E values (control r i family).value=0 := by
  have parts := (Bool.and_eq_true_iff.mp checked).2
  have familyEq : family-4+4=family := by omega
  have rc := _root_.of_decide_eq_true (List.all_eq_true.mp
    (List.all_eq_true.mp parts i (List.mem_range.mpr ib)) (family-4) (List.mem_range.mpr (by omega)))
  rw [familyEq] at rc
  have same := DynamicTypingSource.same_entry values _ _ rc.2
  have member : query tables indexed r i family ∈ (bank tables indexed r family).queries := by
    unfold query
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem rc.1
  have zero := ReadOnlyInactive.query_zero matrix _ (table_checked matrix tables indexed r checked family (by omega))
    values one satisfied _ member (same.1.symm.trans inactive)
  exact ⟨same.2.1.trans zero.1,same.2.2.trans zero.2⟩

#print axioms inactive_direct
end ZkBuild.ControlLookupSound
