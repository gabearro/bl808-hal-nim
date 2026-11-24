import VariableRuleFields
import VariableRowSound
set_option autoImplicit false
namespace ZkBuild.VariableSelectorFields
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Images {F : Type} [Field F] (values : Nat → F) (r : VariableRowCheck.Record) (code : Nat) : Prop :=
  ∀ i, i < 10 → E values (f r.selectors i) = OperandEvents.flag (decide (code = DynamicSelectors.codes.getD i 0))

theorem arities {F : Type} [Field F] (values : Nat → F) (r : VariableRowCheck.Record) (code : Nat)
    (images : Images values r code) :
    E values (VariableRowCheck.inputCount r) = (VariableRuleFields.inputCount code : F) ∧
    E values (VariableRowCheck.outputCount r) = (VariableRuleFields.outputCount code : F) := by
  have t0 := images 0 (by decide)
  have t1 := images 1 (by decide)
  have t2 := images 2 (by decide)
  have t3 := images 3 (by decide)
  have t4 := images 4 (by decide)
  have t5 := images 5 (by decide)
  have t6 := images 6 (by decide)
  have t7 := images 7 (by decide)
  have t8 := images 8 (by decide)
  have t9 := images 9 (by decide)
  simp only [DynamicSelectors.codes,List.getD_cons_zero,List.getD_cons_succ] at t0 t1 t2 t3 t4 t5 t6 t7 t8 t9
  simp only [VariableRowCheck.inputCount,VariableRowCheck.outputCount,eval_append,eval_scale,
    t0,t1,t2,t3,t4,t5,t6,t7,t8,t9]
  by_cases c32 : code = 32
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c33 : code = 33
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c34 : code = 34
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c35 : code = 35
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c36 : code = 36
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c37 : code = 37
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c38 : code = 38
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c271 : code = 271
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c272 : code = 272
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  by_cases c273 : code = 273
  · subst code
    simp [VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]
  simp [c32,c33,c34,c35,c36,c37,c38,c271,c272,c273,VariableRuleFields.inputCount,VariableRuleFields.outputCount,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,Semiring.natCast_one,Semiring.natCast_eq_ofNat 2,Semiring.natCast_eq_ofNat 3,Ring.intCast_ofNat 2,Ring.intCast_ofNat 3]

#print axioms arities
end ZkBuild.VariableSelectorFields
