import VariableSelectorFields
set_option autoImplicit false
namespace ZkBuild.VariableSelectorCheck
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def sums (tags : Fields) : Fields :=
  let locals := f tags 0++f tags 1++f tags 2
  let globals := f tags 3++f tags 4
  let tables := f tags 5++f tags 6++f tags 7++f tags 8++f tags 9
  [locals,globals,tables,locals++globals++tables]

def check (selectors : DynamicTypingMatrix.Stage) (r : VariableRowCheck.Record) (i : Nat) : Bool :=
  decide (ModuleProgram.sameInputs r.selectors (rowAt selectors.outputs i) ∧
    ModuleProgram.sameInputs [f r.row 8] [f (DynamicTypingMatrix.eventAt selectors i) 8] ∧
    ModuleProgram.sameInputs (r.selectors.drop 10) (sums r.selectors))

theorem point {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (a b : Fields) (same : ModuleProgram.sameInputs a b) (i : Nat) :
    E values (f a i) = E values (f b i) := by
  have mapped := SourceProgramSound.normalized_inputs values a b same
  have zero : E values z = 0 := by simp [z,E,FullMatrix.evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,AddCommMonoid.zero_add]
  have h := congrArg (fun xs : List F => xs.getD i 0) mapped
  rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at h
  exact h

theorem images {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : DynamicTypingMatrix.Stage) (r : VariableRowCheck.Record) (i : Nat)
    (selectors : DynamicSelectors.check matrix s = true) (checked : check s r i = true) (ib : i < s.rows.length)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code : Nat) (bound : code < 2^16) (image : E values (f r.row 8) = (code : F)) :
    VariableSelectorFields.Images values r code := by
  classical
  have parts := _root_.of_decide_eq_true checked
  have opImage : E values (f (DynamicTypingMatrix.eventAt s i) 8) = (code : F) := by
    have op := point values _ _ parts.2.1 0
    simpa only [f,DeclarationMatrix.get,List.getD_cons_zero] using op.symm.trans image
  intro j jb
  have same := point values _ _ parts.1 j
  have row := DynamicSelectors.rows matrix s selectors values one satisfied i j ib jb
  have cb : DynamicSelectors.codes.getD j 0 < 2^16 := by
    have choices : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3 ∨ j = 4 ∨ j = 5 ∨ j = 6 ∨ j = 7 ∨ j = 8 ∨ j = 9 := by omega
    rcases choices with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  have eq : (code : F) = (DynamicSelectors.codes.getD j 0 : F) ↔ code = DynamicSelectors.codes.getD j 0 :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans bound (by decide))
      (Nat.lt_trans cb (by decide))
  simpa only [same,row,opImage,eq,OperandEvents.flag,decide_eq_true_eq]

def Categories {F : Type} [Field F] (values : Nat → F) (tags : Fields) (code : Nat) : Prop :=
  E values (f tags 10) = OperandEvents.flag (decide (VariableTyping.environment code = 1)) ∧
  E values (f tags 11) = OperandEvents.flag (decide (VariableTyping.environment code = 2)) ∧
  E values (f tags 12) = OperandEvents.flag (decide (VariableTyping.environment code = 3)) ∧
  E values (f tags 13) = OperandEvents.flag (decide (VariableTyping.environment code ≠ 0))

theorem categories {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (s : DynamicTypingMatrix.Stage) (r : VariableRowCheck.Record) (i code : Nat)
    (checked : check s r i = true) (images : VariableSelectorFields.Images values r code) :
    Categories values r.selectors code := by
  have parts := _root_.of_decide_eq_true checked
  have h0 := point values _ _ parts.2.2 0
  have h1 := point values _ _ parts.2.2 1
  have h2 := point values _ _ parts.2.2 2
  have h3 := point values _ _ parts.2.2 3
  simp only [f,DeclarationMatrix.get,List.getD,List.getElem?_drop] at h0 h1 h2 h3
  change E values (f r.selectors 10) = E values (f (sums r.selectors) 0) at h0
  change E values (f r.selectors 11) = E values (f (sums r.selectors) 1) at h1
  change E values (f r.selectors 12) = E values (f (sums r.selectors) 2) at h2
  change E values (f r.selectors 13) = E values (f (sums r.selectors) 3) at h3
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
  unfold Categories
  rw [h0,h1,h2,h3]
  simp only [sums,f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ,eval_append]
  change (E values (f r.selectors 0)+E values (f r.selectors 1)+E values (f r.selectors 2) = _) ∧
    (E values (f r.selectors 3)+E values (f r.selectors 4) = _) ∧
    (E values (f r.selectors 5)+E values (f r.selectors 6)+E values (f r.selectors 7)+E values (f r.selectors 8)+E values (f r.selectors 9) = _) ∧
    ((E values (f r.selectors 0)+E values (f r.selectors 1)+E values (f r.selectors 2))+
      (E values (f r.selectors 3)+E values (f r.selectors 4))+
      (E values (f r.selectors 5)+E values (f r.selectors 6)+E values (f r.selectors 7)+E values (f r.selectors 8)+E values (f r.selectors 9)) = _)
  simp only [t0,t1,t2,t3,t4,t5,t6,t7,t8,t9]
  by_cases c32 : code = 32
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c33 : code = 33
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c34 : code = 34
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c35 : code = 35
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c36 : code = 36
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c37 : code = 37
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c38 : code = 38
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c271 : code = 271
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c272 : code = 272
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c273 : code = 273
  · subst code
    simp [VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  simp [c32,c33,c34,c35,c36,c37,c38,c271,c272,c273,VariableTyping.environment,OperandEvents.flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]

#print axioms images
#print axioms categories
end ZkBuild.VariableSelectorCheck
