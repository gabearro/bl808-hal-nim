import ParametricMode
set_option autoImplicit false
namespace ZkBuild.ParametricBegin
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

def Valid (code primary : Nat) : Prop :=
  (code = 27 → primary = 0) ∧
  (code = 28 → ∃ tag, ParametricEvents.typeForCode primary = some tag) ∧
  (code = 208 → ∃ tag, ParametricEvents.referenceForCode primary = some tag)

theorem immediate {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ParametricRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ primary : Fin (2^32), E values r.primary = (primary.val : F) := by
  obtain ⟨value,bound,image,_⟩ := TokenInteger.certificate_nat values one _ _ _
    (RangeUse.checked_certificate matrix r.primaryRange r.primary 32 (Bool.and_eq_true_iff.mp checked).2 values one satisfied)
  exact ⟨⟨value,bound⟩,image⟩

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record)
    (meaning : ParametricRowSound.Meaning values r) (tags : ParametricRowSound.Tags values r .instructionBegin)
    (code : Nat) (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (primary : Fin (2^32)) (image : E values r.primary = (primary.val : F)) : Valid code primary.val := by
  have mode := ParametricMode.images values one r meaning code cb ci
  have types := ParametricMode.type_images values one r meaning primary image
  have t1 := (InstructionRowSound.selectors values _ .instructionBegin tags).2.1
  change E values (f r.flags 1) = _ at t1
  have a := meaning.multiply (f r.flags 1) (f r.after 0) 13 (by simp [multiplies])
  have b := meaning.multiply (f r.flags 1) (f r.after 1) 11 (by simp [multiplies])
  have c := meaning.multiply (f r.flags 1) (f r.after 2) 12 (by simp [multiplies])
  simp only [t1,ControlEvents.selected,decide_true,flag,ite_true,Semiring.one_mul,mode.1,mode.2.1,mode.2.2.1] at a b c
  have ga := meaning.guard _ _ (by simp [guards] : (f r.after 13,r.primary) ∈ guards r)
  have gb := meaning.guard _ _ (by simp [guards] : (f r.after 11,sub o (validType r)) ∈ guards r)
  have gc := meaning.guard _ _ (by simp [guards] : (f r.after 12,sub o (f r.after 9++f r.after 10)) ∈ guards r)
  simp only [a,b,c,image,eval_sub,o,eval_constant values one,Ring.intCast_one,types.2.1,types.2.2] at ga gb gc
  refine ⟨?_,?_,?_⟩
  · intro eq; subst code
    simp only [flag,decide_true,ite_true,Semiring.one_mul] at ga
    exact NumericEvents.nat_eq (F := F) primary.val 0 (by have := primary.isLt; simp [NumericEvents.countBound]; omega)
      (by decide) (by simpa only [Semiring.natCast_zero] using ga)
  · intro eq; subst code
    simp only [flag,decide_true,ite_true,Semiring.one_mul] at gb
    cases result : ParametricEvents.typeForCode primary.val with
    | none =>
      simp only [result,Option.isSome_none,flag,Bool.false_eq_true,ite_false] at gb
      have bad : (1 : F) = 0 := by grind only
      exact False.elim (Field.zero_ne_one bad.symm)
    | some tag => exact ⟨tag,rfl⟩
  · intro eq; subst code
    simp only [flag,decide_true,ite_true,Semiring.one_mul] at gc
    cases result : ParametricEvents.referenceForCode primary.val with
    | none =>
      simp only [result,Option.isSome_none,flag,Bool.false_eq_true,ite_false] at gc
      have bad : (1 : F) = 0 := by grind only
      exact False.elim (Field.zero_ne_one bad.symm)
    | some tag => exact ⟨tag,rfl⟩

#print axioms immediate
#print axioms sound
end ZkBuild.ParametricBegin
