import FrameRowSound
set_option autoImplicit false
namespace ZkBuild.FrameRowImages
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem links (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true) : FrameRowCheck.links r := by
  exact of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1

theorem outputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true) (values : Nat → F) :
    r.outputs.map (E values) = (descriptor r++r.after.take 9++
      [opening r,branching r,closing r,opening r++branching r++closing r,f r.after 11]).map (E values) :=
  SourceProgramSound.normalized_inputs values _ _ (links matrix r checked).2.2.2.2.2.2.2.1

theorem interface {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true) (values : Nat → F) :
    [r.read.active,r.read.write,r.read.address,r.read.clock,
      r.write.active,r.write.write,r.write.address,r.write.value,r.write.clock].map (E values) =
    [readActive r,z,f r.after 19++f r.after 17,n (2*r.index),
      f r.flags 4,f r.flags 4,f r.after 44,f r.after 45,n (2*r.index+1)].map (E values) :=
  SourceProgramSound.normalized_inputs values _ _ (links matrix r checked).2.2.2.2.2.2.2.2

theorem range {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < 5) :
    let (value,width) := (rangeInputs r).getD i (z,0)
    RangeReuse.Certificate width (E values value) ((RangeUse.bits (r.ranges.getD i default)).map (E values)) := by
  exact RangeUse.checked_certificate matrix _ _ _
    (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)) values one satisfied

theorem bounded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < 5) :
    let (value,width) := (rangeInputs r).getD i (z,0)
    ∃ n : Nat, n < 2^width ∧ E values value = (n : F) := by
  obtain ⟨n,nb,ni,_⟩ := TokenInteger.certificate_nat values one _ _ _ (range matrix r checked values one satisfied i ib)
  exact ⟨n,nb,ni⟩

#print axioms outputs
#print axioms interface
#print axioms range
#print axioms bounded
end ZkBuild.FrameRowImages
