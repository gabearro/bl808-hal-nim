import ControlTypeRowSound
import CallRowSound
set_option autoImplicit false
namespace ZkBuild.ControlTypeRowImages
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix ControlTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem links (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true) : ControlTypeRowCheck.links r := by
  have parts := checked
  simp only [ControlTypeRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  exact parts.1.1.1.1.1

structure Interface {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) : Prop where
  metadataActive : E values r.metadata.active=E values (f r.after 1)
  metadataAddress : E values r.metadata.address=E values (f r.after 2)
  heads : E values r.heads.value=E values r.metadata.value
  paramsActive : E values r.params.active=E values (lookup r)
  paramsAddress : E values r.params.address=E values (f r.after 9)
  memberActive : E values r.member.active=E values (argument r++f r.after 32)
  memberAddress : E values r.member.address=E values (scale (f r.after 41) (Int.ofNat (2^32))++f r.after 42)
  payload : E values r.payload.value=E values r.member.value
  singletonActive : E values r.singleton.active=E values (f r.after 3)
  singletonAddress : E values r.singleton.address=E values (f r.after 4)
  resultsActive : E values r.results.active=E values (lookup r)
  resultsAddress : E values r.results.address=E values (f r.after 10)
  compareActive : E values r.compare.active=E values (f r.after 48)
  compareAddress : E values r.compare.address=E values (scale (f r.after 49) (Int.ofNat (2^32))++f r.after 50)
  comparison : E values r.comparison.value=E values r.compare.value

theorem interface {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true) (values : Nat → F) : Interface values r := by
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,shape⟩ := links matrix r checked
  have equal := SourceProgramSound.normalized_inputs values _ _ shape
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at equal
  constructor <;> grind only

theorem heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) :
    ∃ params results : Fin (2^32), E values r.heads.low=(params.val:F) ∧
      E values r.heads.high=(results.val:F) ∧ E values r.metadata.value=((params.val+2^32*results.val:Nat):F) := by
  have parts := checked
  simp only [ControlTypeRowCheck.check,Bool.and_eq_true_iff] at parts
  obtain ⟨_,_,_,_,_,_,_,hl,hh,_,_,_,_,_⟩ := links matrix r checked
  obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.heads parts.1.1.1.2 values one satisfied
  rw [hl] at lb eq
  rw [hh] at hb
  exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).heads.symm.trans (by simpa only [eq] using vi)⟩

def MemberImage {F : Type} [Field F] (values : Nat → F) (entry : ReadOnlyMatrix.Entry) (packed : PackedFields.Record) : Prop :=
  ∃ tag : Fin 8, ∃ next : Fin (2^32), E values packed.low=(tag.val:F) ∧
    E values packed.high=(next.val:F) ∧ E values entry.value=((tag.val+8*next.val:Nat):F)

theorem members {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) :
    MemberImage values r.member r.payload ∧ MemberImage values r.compare r.comparison := by
  have parts := checked
  simp only [ControlTypeRowCheck.check,Bool.and_eq_true_iff] at parts
  obtain ⟨_,_,_,_,_,_,_,_,_,pl,ph,cl,ch,_⟩ := links matrix r checked
  constructor
  · obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.payload parts.1.1.2 values one satisfied
    rw [pl] at lb eq
    rw [ph] at hb
    exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).payload.symm.trans (by simpa only [eq] using vi)⟩
  · obtain ⟨value,low,high,_,lb,hb,vi,li,hi,eq,_,_⟩ := PackedFields.checked_split matrix r.comparison parts.1.2 values one satisfied
    rw [cl] at lb eq
    rw [ch] at hb
    exact ⟨⟨low,lb⟩,⟨high,hb⟩,li,hi,(interface matrix r checked values).comparison.symm.trans (by simpa only [eq] using vi)⟩

theorem ranges {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : ControlTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i<4) : ∃ value : Fin (2^32), E values (f r.after ([41,42,49,50].getD i 0))=(value.val:F) := by
  have accepted := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)
  obtain ⟨v,vb,vi,_⟩ := TokenInteger.certificate_nat values one _ _ _ (RangeUse.checked_certificate matrix _ _ _ accepted values one satisfied)
  exact ⟨⟨v,vb⟩,vi⟩

#print axioms interface
#print axioms heads
#print axioms members
#print axioms ranges
end ZkBuild.ControlTypeRowImages
