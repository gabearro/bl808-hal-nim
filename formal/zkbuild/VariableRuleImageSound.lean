import VariableSelectorFields
set_option autoImplicit false
namespace ZkBuild.VariableRuleImageSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem types {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : VariableRowCheck.Record) (checked : VariableRowCheck.check matrix r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) (code declared pops : Nat)
    (images : VariableSelectorFields.Images values r code)
    (declaredImage : E values r.declared = (declared : F))
    (firstImage : E values (f r.after 3) = OperandEvents.flag (decide (pops = 0)))
    (secondImage : E values (f r.after 4) = OperandEvents.flag (decide (pops = 1))) :
    E values (f r.after 2) = (VariableRuleFields.outputType code declared : F) ∧
    E values (f r.after 7) = (VariableRuleFields.inputType code declared pops : F) := by
  have all := VariableRowSound.facts matrix r checked values satisfied
  have output := (all (mulGate (f r.selectors 0++f r.selectors 2++f r.selectors 3++f r.selectors 5) r.declared (f r.after 2))
    (by simp [VariableRowCheck.gates])).symm
  have left := (all (mulGate (f r.after 3) (f r.selectors 1++f r.selectors 2++f r.selectors 4++f r.selectors 6) (f r.after 5))
    (by simp [VariableRowCheck.gates])).symm
  have right := (all (mulGate (f r.after 4) (f r.selectors 7++f r.selectors 9) (f r.after 6))
    (by simp [VariableRowCheck.gates])).symm
  have input := (all (mulGate (f r.after 5++f r.after 6) r.declared (f r.after 7))
    (by simp [VariableRowCheck.gates])).symm
  change E values (f r.after 2) = E values (f r.selectors 0++f r.selectors 2++f r.selectors 3++f r.selectors 5)*E values r.declared at output
  change E values (f r.after 5) = E values (f r.after 3)*E values (f r.selectors 1++f r.selectors 2++f r.selectors 4++f r.selectors 6) at left
  change E values (f r.after 6) = E values (f r.after 4)*E values (f r.selectors 7++f r.selectors 9) at right
  change E values (f r.after 7) = E values (f r.after 5++f r.after 6)*E values r.declared at input
  simp only [eval_append] at output left right input
  change E values (f r.after 7) = (E values (f r.after 5)+E values (f r.after 6))*E values r.declared at input
  rw [left,right] at input
  have t0 := images 0 (by decide)
  have t1 := images 1 (by decide)
  have t2 := images 2 (by decide)
  have t3 := images 3 (by decide)
  have t4 := images 4 (by decide)
  have t5 := images 5 (by decide)
  have t6 := images 6 (by decide)
  have t7 := images 7 (by decide)
  have t9 := images 9 (by decide)
  simp only [DynamicSelectors.codes,List.getD_cons_zero,List.getD_cons_succ] at t0 t1 t2 t3 t4 t5 t6 t7 t9
  rw [output,input]
  simp only [t0,t1,t2,t3,t4,t5,t6,t7,t9,declaredImage,firstImage,secondImage]
  by_cases c32 : code = 32
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c33 : code = 33
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c34 : code = 34
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c35 : code = 35
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c36 : code = 36
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c37 : code = 37
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c38 : code = 38
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c271 : code = 271
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  by_cases c273 : code = 273
  · subst code
    by_cases p0 : pops = 0 <;> by_cases p1 : pops = 1 <;> simp [VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero,p0,p1]
  simp [c32,c33,c34,c35,c36,c37,c38,c271,c273,VariableRuleFields.inputType,VariableRuleFields.outputType,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add,Semiring.zero_mul,Semiring.mul_zero,Semiring.one_mul,Semiring.mul_one,Semiring.natCast_zero]

theorem rule_image {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : VariableRowCheck.Record) (checked : VariableRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code declared pops : Nat) (pb : pops < NumericEvents.countBound)
    (rule : StaticTyping.Rule) (signature : VariableTyping.signature code declared = some rule)
    (images : VariableSelectorFields.Images values r code)
    (present : E values (f r.selectors 13) = 1)
    (declaredImage : E values r.declared = (declared : F))
    (popImage : E values (f r.after 0) = (pops : F)) : VariableRowSound.RuleImage values r rule pops := by
  classical
  have all := VariableRowSound.facts matrix r checked values satisfied
  have first := zero_sound values one (f r.after 0) (f r.after 3) (f r.reciprocals 0) (by
    intro g member
    apply all
    simp only [zeroGates,List.mem_cons,List.not_mem_nil,or_false] at member
    rcases member with rfl | rfl <;> simp [VariableRowCheck.gates,zeroGates])
  have second := zero_sound values one (sub (f r.after 0) o) (f r.after 4) (f r.reciprocals 1) (by
    intro g member
    apply all
    simp only [zeroGates,List.mem_cons,List.not_mem_nil,or_false] at member
    rcases member with rfl | rfl <;> simp [VariableRowCheck.gates,zeroGates])
  have zero : (pops : F) = 0 ↔ pops = 0 := by
    constructor
    · intro h
      exact NumericEvents.nat_eq (F := F) _ _ pb (by decide) (by simpa only [Semiring.natCast_zero] using h)
    · intro h; simp [h,Semiring.natCast_zero]
  have oneEq : (pops : F)-1 = 0 ↔ pops = 1 := by
    constructor
    · intro h
      apply NumericEvents.nat_eq (F := F) _ _ pb (by decide)
      simp only [Semiring.natCast_one]
      grind only
    · intro h; simp [h,Semiring.natCast_one,AddCommGroup.sub_self]
  have firstImage : E values (f r.after 3) = OperandEvents.flag (decide (pops = 0)) := by
    simpa only [popImage,zero,OperandEvents.flag,decide_eq_true_eq] using first
  have secondImage : E values (f r.after 4) = OperandEvents.flag (decide (pops = 1)) := by
    simpa only [eval_sub,o,eval_constant values one,Ring.intCast_one,popImage,oneEq,OperandEvents.flag,decide_eq_true_eq] using second
  have fields := VariableRuleFields.fields code declared rule signature
  have arities := VariableSelectorFields.arities values r code images
  have typeImages := types matrix r checked values satisfied code declared pops images declaredImage firstImage secondImage
  exact ⟨present,by simpa only [fields.2.1] using arities.1,
    by simpa only [fields.2.2.1] using arities.2,
    by simpa only [fields.2.2.2.1] using typeImages.1,
    by simpa only [fields.2.2.2.2.1 pops] using typeImages.2⟩

#print axioms rule_image

#print axioms types
end ZkBuild.VariableRuleImageSound
