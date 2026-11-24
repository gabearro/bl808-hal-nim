import BranchMergeCheck
import DynamicTypingSource
set_option autoImplicit false
namespace ZkBuild.BranchMergeSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix BranchMergeCheck
attribute [local instance] Ring.intCast Semiring.natCast

structure Interface {F : Type} [Field F] (values : Nat → F) (r : BranchMergeCheck.Record) : Prop where
  active : E values r.merged.active = E values r.control.active+E values r.branch.active
  address : E values r.merged.address = E values r.control.address+E values r.branch.address
  value : E values r.merged.value = E values r.control.value+E values r.branch.value
  controlActive : E values r.controlAddress.active = E values r.control.active
  controlAddress : E values r.controlAddress.address = E values r.control.address
  branchActive : E values r.branchAddress.active = E values r.branch.active
  branchAddress : E values r.branchAddress.address = E values r.branch.address

theorem interface {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchMergeCheck.Record) (checked : BranchMergeCheck.check matrix r = true) (values : Nat → F) : Interface values r := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1
  have same := SourceProgramSound.normalized_inputs values _ _ shape
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true,eval_append] at same
  constructor <;> grind only

structure Meaning {F : Type} [Field F] (values : Nat → F) (r : BranchMergeCheck.Record) : Prop where
  disjoint : E values r.control.active*E values r.branch.active = 0
  controlZero : E values r.control.active = 0 → E values r.control.address = 0 ∧ E values r.control.value = 0
  branchZero : E values r.branch.active = 0 → E values r.branch.address = 0 ∧ E values r.branch.value = 0

theorem meaning {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchMergeCheck.Record) (checked : BranchMergeCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Meaning values r := by
  have parts := checked
  simp only [BranchMergeCheck.check,Bool.and_eq_true_iff] at parts
  have all := MemoryEvidence.span_sound matrix _ _ _ parts.1.1.2 values satisfied
  have raw (a b : Linear) (member : gate a b ∈ gates r) : E values a*E values b = 0 := by
    have h := all _ member
    change E values a*E values b = E values z at h
    simpa only [z,eval_constant values one,Ring.intCast_zero] using h
  have faces := interface matrix r checked values
  constructor
  · exact raw _ _ (by simp [gates])
  · intro inactive
    have address := InactiveAddress.sound matrix _ parts.1.2 values satisfied (faces.controlActive.trans inactive)
    have value := raw (sub o r.control.active) r.control.value (by simp [gates])
    simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,inactive] at value
    exact ⟨faces.controlAddress.symm.trans address,by grind only⟩
  · intro inactive
    have address := InactiveAddress.sound matrix _ parts.2 values satisfied (faces.branchActive.trans inactive)
    have value := raw (sub o r.branch.active) r.branch.value (by simp [gates])
    simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,inactive] at value
    exact ⟨faces.branchAddress.symm.trans address,by grind only⟩

theorem branch_selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchMergeCheck.Record) (checked : BranchMergeCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.branch.active = 1) :
    DynamicTypingSource.SameEntry values r.merged r.branch ∧ E values r.control.active = 0 := by
  have m := meaning matrix r checked values one satisfied
  have faces := interface matrix r checked values
  have inactive : E values r.control.active = 0 := by have := m.disjoint; rw [active] at this; grind only
  have zero := m.controlZero inactive
  refine ⟨⟨?_,?_,?_⟩,inactive⟩
  · rw [faces.active,inactive]; grind only
  · rw [faces.address,zero.1]; grind only
  · rw [faces.value,zero.2]; grind only

theorem control_selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchMergeCheck.Record) (checked : BranchMergeCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.control.active = 1) :
    DynamicTypingSource.SameEntry values r.merged r.control ∧ E values r.branch.active = 0 := by
  have m := meaning matrix r checked values one satisfied
  have faces := interface matrix r checked values
  have inactive : E values r.branch.active = 0 := by have := m.disjoint; rw [active] at this; grind only
  have zero := m.branchZero inactive
  refine ⟨⟨?_,?_,?_⟩,inactive⟩
  · rw [faces.active,inactive]; grind only
  · rw [faces.address,zero.1]; grind only
  · rw [faces.value,zero.2]; grind only

#print axioms interface
#print axioms meaning
#print axioms branch_selected
#print axioms control_selected
end ZkBuild.BranchMergeSound
