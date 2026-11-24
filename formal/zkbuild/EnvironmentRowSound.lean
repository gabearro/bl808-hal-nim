import EnvironmentRowCheck
import VariableRowSound
set_option autoImplicit false
namespace ZkBuild.EnvironmentRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Tags {F : Type} [Field F] (values : Nat → F) (r : EnvironmentRowCheck.Record) (kind : OperandEvents.Kind) : Prop :=
  InstructionRowSound.Tags values ⟨[],r.flags,[],[],default,default,0,0,0,0⟩ kind

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : EnvironmentRowCheck.Record) (checked : EnvironmentRowCheck.check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (EnvironmentRowCheck.gates r) :=
  OperandRowSound.includes_sound matrix _ _ _ (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).2 values satisfied

theorem packed {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : EnvironmentRowCheck.Record) (checked : EnvironmentRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (declared : Fin 7) (mutable : Bool),
      E values (EnvironmentRowCheck.tag r) = (declared.val : F) ∧
      E values (f (RangeUse.bits r.packedRange) 3) = OperandEvents.flag mutable ∧
      E values r.localQuery.value + E values r.objectQuery.value = (VariableTyping.globalValue declared.val mutable : F) := by
  have certificate := RangeUse.checked_certificate matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values one satisfied
  obtain ⟨packed,pb,pi,bits⟩ := TokenInteger.certificate_nat values one _ _ _ certificate
  have b0 := bits 0
  have b1 := bits 1
  have b2 := bits 2
  have b3 := bits 3
  change E values (f (RangeUse.bits r.packedRange) 0) = _ at b0
  change E values (f (RangeUse.bits r.packedRange) 1) = _ at b1
  change E values (f (RangeUse.bits r.packedRange) 2) = _ at b2
  change E values (f (RangeUse.bits r.packedRange) 3) = _ at b3
  have ti : E values (EnvironmentRowCheck.tag r) = ((packed%8 : Nat) : F) := by
    simp only [EnvironmentRowCheck.tag,eval_append,eval_scale,b0,b1,b2,Ring.intCast_ofNat 2,Ring.intCast_ofNat 4]
    have cases : packed = 0 ∨ packed = 1 ∨ packed = 2 ∨ packed = 3 ∨ packed = 4 ∨ packed = 5 ∨ packed = 6 ∨ packed = 7 ∨ packed = 8 ∨ packed = 9 ∨ packed = 10 ∨ packed = 11 ∨ packed = 12 ∨ packed = 13 ∨ packed = 14 ∨ packed = 15 := by omega
    rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp <;> grind
  have all := facts matrix r checked values satisfied
  have invalid := equality_sound values one (f r.after 7) z (all _ (by simp [EnvironmentRowCheck.gates]))
  simp only [z,eval_constant values one,Ring.intCast_zero] at invalid
  have inverse := all (mulGate (sub (EnvironmentRowCheck.tag r) (n 7)) r.reciprocal (sub o (f r.after 7)))
    (by simp [EnvironmentRowCheck.gates,zeroGates,mulGate,o])
  change E values (sub (EnvironmentRowCheck.tag r) (n 7))*E values r.reciprocal = E values (sub o (f r.after 7)) at inverse
  simp only [eval_sub,ti,invalid,n,o,eval_constant values one,Ring.intCast_one,show ((Int.ofNat 7 : Int) : F) = 7 from Ring.intCast_ofNat 7] at inverse
  have small : packed%8 < 7 := by
    have bound : packed%8 < 8 := Nat.mod_lt _ (by decide)
    by_cases good : packed%8 < 7
    · exact good
    have bad := good
    have same : packed%8 = 7 := by omega
    simp only [same,Semiring.natCast_eq_ofNat 7] at inverse
    have impossible : (0 : F) = 1 := by grind only
    exact False.elim (Field.zero_ne_one impossible)
  refine ⟨⟨packed%8,small⟩,packed.testBit 3,ti,b3,?_⟩
  have encoding : VariableTyping.globalValue (packed%8) (packed.testBit 3) = packed := by
    have cases : packed = 0 ∨ packed = 1 ∨ packed = 2 ∨ packed = 3 ∨ packed = 4 ∨ packed = 5 ∨ packed = 6 ∨ packed = 7 ∨ packed = 8 ∨ packed = 9 ∨ packed = 10 ∨ packed = 11 ∨ packed = 12 ∨ packed = 13 ∨ packed = 14 ∨ packed = 15 := by omega
    rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  simpa only [encoding,eval_append] using pi

theorem transition {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : EnvironmentRowCheck.Record) (checked : EnvironmentRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind) :
    E values (f r.after 11) = if kind = .functionBegin ∨ kind = .instructionBegin then
      E values (EnvironmentRowCheck.tag r) else E values r.before := by
  have all := facts matrix r checked values satisfied
  obtain ⟨t0,t1,_,_,_,_,_,_,_,_,_⟩ := InstructionRowSound.selectors values _ kind tags
  have selected := select_sound values (f r.flags 0++f r.flags 1) (EnvironmentRowCheck.tag r) r.before (f r.after 11)
    (all _ (by simp [EnvironmentRowCheck.gates]))
  change E values (f r.flags 0) = _ at t0
  change E values (f r.flags 1) = _ at t1
  simp only [eval_append,t0,t1] at selected
  cases kind <;> simp [ControlEvents.selected,OperandEvents.flag] at selected ⊢ <;> grind only

#print axioms packed
#print axioms transition
end ZkBuild.EnvironmentRowSound
