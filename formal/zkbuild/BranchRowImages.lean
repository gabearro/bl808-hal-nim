import BranchRowSound
import CallRowSound
set_option autoImplicit false
namespace ZkBuild.BranchRowImages
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix BranchRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem links (matrix : Shape) (r : BranchRowCheck.Record) (checked : check matrix r = true) : BranchRowCheck.links r := by
  have parts := checked
  simp only [BranchRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  exact parts.1.1.1

theorem interface {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchRowCheck.Record) (checked : check matrix r = true) (values : Nat → F) :
    E values r.bankQuery.active = E values (f r.after 1) ∧
    E values r.bankQuery.address = E values (f r.after 3) ∧
    E values r.nodeQuery.active = E values (f r.flags 9) ∧
    E values r.nodeQuery.address = E values (f r.after 6) ∧
    E values r.payload.value = E values r.nodeQuery.value := by
  have shape := links matrix r checked
  have equal := SourceProgramSound.normalized_inputs values _ _ shape.2.2.2.2.2.2.1
  simpa only [List.map_cons,List.map_nil,List.cons.injEq,and_true] using equal

theorem payload {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ depth next : Fin (2^32), E values r.payload.low = (depth.val : F) ∧
      E values r.payload.high = (next.val : F) ∧ E values r.nodeQuery.value = ((depth.val+2^32*next.val : Nat) : F) := by
  have parts := checked
  simp only [BranchRowCheck.check,Bool.and_eq_true_iff] at parts
  have shape := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.payload parts.2 values one satisfied
  rw [shape.2.2.2.2.1] at lb eq
  rw [shape.2.2.2.2.2.1] at hb
  exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).2.2.2.2.symm.trans (by simpa only [eq] using vi)⟩

theorem primary {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ primary : Fin (2^32), E values r.primary = (primary.val : F) := by
  have parts := checked
  simp only [BranchRowCheck.check,Bool.and_eq_true_iff] at parts
  obtain ⟨p,pb,pi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.primaryRange r.primary 32 parts.1.2 values one satisfied)
  exact ⟨⟨p,pb⟩,pi⟩

theorem outputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchRowCheck.Record) (checked : check matrix r = true) (values : Nat → F) :
    E values (f r.outputs 0) = E values r.payload.low ∧ E values (f r.outputs 1) = E values (f r.after 8) := by
  have same := (links matrix r checked).2.2.2.2.2.2.2
  constructor
  · simpa only [f,DeclarationMatrix.get,List.getD_cons_zero] using VariableSelectorCheck.point values _ _ same 0
  · simpa only [f,DeclarationMatrix.get,List.getD_cons_succ,List.getD_cons_zero] using VariableSelectorCheck.point values _ _ same 1

#print axioms interface
#print axioms payload
#print axioms primary
#print axioms outputs
end ZkBuild.BranchRowImages
