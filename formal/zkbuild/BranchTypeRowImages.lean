import BranchTypeRowSound
import CallRowSound
set_option autoImplicit false
namespace ZkBuild.BranchTypeRowImages
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix BranchTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem links (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true) : BranchTypeRowCheck.links r := by
  have parts := checked
  simp only [BranchTypeRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  exact parts.1.1.1.1.1.1

structure Interface {F : Type} [Field F] (values : Nat → F) (r : BranchTypeRowCheck.Record) : Prop where
  metadataActive : E values r.metadata.active = E values (f r.after 14)
  metadataAddress : E values r.metadata.address = E values (f r.after 15)
  heads : E values r.heads.value = E values r.metadata.value
  sizeActive : E values r.size.active = E values (f r.flags 9)
  sizeAddress : E values r.size.address = E values (f r.after 22)
  memberActive : E values r.member.active = E values (argument r)
  memberAddress : E values r.member.address = E values (scale (f r.after 39) (Int.ofNat (2^32))++f r.after 40)
  payload : E values r.payload.value = E values r.member.value
  singletonActive : E values r.singleton.active = E values (f r.after 16)
  singletonAddress : E values r.singleton.address = E values (f r.after 17)
  scratchActive : E values r.scratch.active = E values (argument r++f r.after 34)
  scratchWrite : E values r.scratch.write = E values (argument r)
  scratchAddress : E values r.scratch.address = E values (scale (argument r) (Int.ofNat r.index)++f r.after 46)
  scratchValue : E values r.scratch.value = E values (f r.after 47)
  scratchClock : E values r.scratch.clock = E values (n r.index)

theorem interface {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true) (values : Nat → F) :
    Interface values r := by
  have shape := links matrix r checked
  have equal := SourceProgramSound.normalized_inputs values _ _ shape.2.2.2.2.2.2.2.2.2.2
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at equal
  constructor <;> grind only

theorem heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ params results : Fin (2^32), E values r.heads.low = (params.val : F) ∧
      E values r.heads.high = (results.val : F) ∧ E values r.metadata.value = ((params.val+2^32*results.val : Nat) : F) := by
  have parts := checked
  simp only [BranchTypeRowCheck.check,Bool.and_eq_true_iff] at parts
  have shape := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.heads parts.1.1.1.1.2 values one satisfied
  rw [shape.2.2.2.2.2.2.1] at lb eq
  rw [shape.2.2.2.2.2.2.2.1] at hb
  exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).heads.symm.trans (by simpa only [eq] using vi)⟩

theorem payload {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ tag : Fin 8, ∃ next : Fin (2^32), E values r.payload.low = (tag.val : F) ∧
      E values r.payload.high = (next.val : F) ∧ E values r.member.value = ((tag.val+8*next.val : Nat) : F) := by
  have parts := checked
  simp only [BranchTypeRowCheck.check,Bool.and_eq_true_iff] at parts
  have shape := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.payload parts.1.1.1.2 values one satisfied
  rw [shape.2.2.2.2.2.2.2.2.1] at lb eq
  rw [shape.2.2.2.2.2.2.2.2.2.1] at hb
  exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).payload.symm.trans (by simpa only [eq] using vi)⟩

theorem ranges {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ head ordinal restore : Fin (2^32), E values (f r.after 39) = (head.val : F) ∧
      E values (f r.after 40) = (ordinal.val : F) ∧ E values (f r.after 44) = (restore.val : F) := by
  have parts := checked
  simp only [BranchTypeRowCheck.check,Bool.and_eq_true_iff] at parts
  obtain ⟨h,hb,hi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.headRange (f r.after 39) 32 parts.1.1.2 values one satisfied)
  obtain ⟨q,qb,qi,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.ordinalRange (f r.after 40) 32 parts.1.2 values one satisfied)
  obtain ⟨k,kb,ki,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.restoreRange (f r.after 44) 32 parts.2 values one satisfied)
  exact ⟨⟨h,hb⟩,⟨q,qb⟩,⟨k,kb⟩,hi,qi,ki⟩

#print axioms interface
#print axioms heads
#print axioms payload
#print axioms ranges
end ZkBuild.BranchTypeRowImages
