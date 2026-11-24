import ParametricTransition
set_option autoImplicit false
namespace ZkBuild.ParametricGuardCounts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricRowCheck ParametricState
attribute [local instance] Ring.intCast Semiring.natCast

def arity (code : Nat) : Nat := if ParametricMode.selecting code then 3 else 0

structure Spec (s : State) (kind : Kind) (code : Nat) (actual : Fin 8) : Prop where
  pop : popping kind code = true → ParametricMode.selecting code = true ∧ s.pops < 3 ∧ s.pushes = 0
  condition : popping kind code = true → s.pops = 0 → CallEvents.InputOk 0 actual.val
  push : pushing kind code = true → s.pops = arity code ∧ s.pushes = 0
  finish : ParametricMode.active code = true → kind = .instructionEnd → s.pops = arity code ∧ s.pushes = 1
  noControl : ParametricMode.active code = true → kind ≠ .controlPush ∧ kind ≠ .controlPop ∧ kind ≠ .clear ∧ kind ≠ .labelCheck

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record) (meaning : ParametricRowSound.Meaning values r)
    (kind : Kind) (tags : ParametricRowSound.Tags values r kind) (code : Nat) (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (actual : Fin 8) (ai : E values (f r.row 4) = (actual.val : F))
    (s : State) (image : Image values (ready r) s) (pb : s.pops < 2^64) (qb : s.pushes < 2^64)
    (masks : ParametricTransition.Masks values r s kind code actual) : Spec s kind code actual := by
  have mode := ParametricMode.images values one r meaning code cb ci
  have pi : E values (f r.after 15) = (s.pops : F) := image.2.1
  have qi : E values (f r.after 16) = (s.pushes : F) := image.2.2.1
  have arityImage : E values (scale (selectOp r) 3) = (arity code : F) := by
    simp only [eval_scale,mode.2.2.2.1]
    cases h : ParametricMode.selecting code <;> simp [arity,h,flag] <;> grind only
  have arityBound : arity code < NumericEvents.countBound := by cases h : ParametricMode.selecting code <;> simp [arity,h,NumericEvents.countBound]
  have popMode := meaning.guard _ _ (by simp [guards] : (f r.after 19,sub o (selectOp r)) ∈ guards r)
  have popCount := meaning.guard _ _ (by simp [guards] : (f r.after 19,sub (sub (sub o (f r.after 21)) (f r.after 22)) (f r.after 23)) ∈ guards r)
  have popOrder := meaning.guard _ _ (by simp [guards] : (f r.after 19,f r.after 16) ∈ guards r)
  have condition := meaning.guard _ _ (by simp [guards] : (f r.after 24,sub (sub o (f r.after 25)) (f r.after 26)) ∈ guards r)
  have pushCount := meaning.guard _ _ (by simp [guards] : (f r.after 20,sub (f r.after 15) (scale (selectOp r) 3)) ∈ guards r)
  have pushOrder := meaning.guard _ _ (by simp [guards] : (f r.after 20,f r.after 16) ∈ guards r)
  simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,mode.2.2.2.1,masks.pop,masks.push,
    masks.zero,masks.one,masks.two,masks.condition,masks.unknown,masks.actualZero,pi,qi,arityImage] at popMode popCount popOrder condition pushCount pushOrder
  constructor
  · intro enabled
    simp only [enabled,flag,ite_true,Semiring.one_mul] at popMode popCount popOrder
    have selecting : ParametricMode.selecting code = true := by
      cases h : ParametricMode.selecting code
      · simp only [h,Bool.false_eq_true,ite_false] at popMode
        have bad : (1 : F) = 0 := by grind only
        exact False.elim (Field.zero_ne_one bad.symm)
      · rfl
    refine ⟨selecting,ParametricEvents.pop_index (F := F) s.pops popCount,?_⟩
    exact NumericEvents.nat_eq (F := F) s.pushes 0 qb (by decide) (by simpa only [Semiring.natCast_zero] using popOrder)
  · intro enabled zero
    simp only [enabled,zero,decide_true,Bool.and_self,flag,ite_true,Semiring.one_mul] at condition
    by_cases unknown : actual.val = 7
    · exact Or.inr unknown
    by_cases isZero : actual.val = 0
    · exact Or.inl isZero
    simp only [unknown,isZero,decide_false,Bool.false_eq_true,ite_false] at condition
    have bad : (1 : F) = 0 := by grind only
    exact False.elim (Field.zero_ne_one bad.symm)
  · intro enabled
    simp only [enabled,flag,ite_true,Semiring.one_mul] at pushCount pushOrder
    exact ⟨NumericEvents.nat_eq (F := F) s.pops (arity code) pb arityBound (by grind only),
      NumericEvents.nat_eq (F := F) s.pushes 0 qb (by decide) (by simpa only [Semiring.natCast_zero] using pushOrder)⟩
  · intro active ended
    have after := ParametricTransition.image values r meaning kind code actual ai s image masks
    have pEnd : E values (f r.after 43) = (s.pops : F) := by simpa [ParametricState.after,f,DeclarationMatrix.get,advance,popping,ended] using after.2.1
    have qEnd : E values (f r.after 44) = (s.pushes : F) := by simpa [ParametricState.after,f,DeclarationMatrix.get,advance,pushing,ended] using after.2.2.1
    have pGuard := meaning.guard _ _ (by simp [guards] : (f r.after 45,sub (f r.after 43) (scale (selectOp r) 3)) ∈ guards r)
    have qGuard := meaning.guard _ _ (by simp [guards] : (f r.after 45,sub (f r.after 44) o) ∈ guards r)
    simp only [masks.finish,active,ended,decide_true,Bool.and_self,flag,ite_true,Semiring.one_mul,
      eval_sub,pEnd,qEnd,arityImage,o,eval_constant values one,Ring.intCast_one] at pGuard qGuard
    exact ⟨NumericEvents.nat_eq (F := F) s.pops (arity code) pb arityBound (by grind only),
      NumericEvents.nat_eq (F := F) s.pushes 1 qb (by decide) (by simpa only [Semiring.natCast_one] using (show (s.pushes : F) = 1 from by grind only))⟩
  · intro active
    have guard := meaning.guard _ _ (by simp [guards] : (present r,f r.flags 4++f r.flags 5++f r.flags 6++f r.flags 9) ∈ guards r)
    obtain ⟨_,_,_,_,t4,t5,t6,_,_,t9,_⟩ := InstructionRowSound.selectors values _ kind tags
    change E values (f r.flags 4) = _ at t4
    change E values (f r.flags 5) = _ at t5
    change E values (f r.flags 6) = _ at t6
    change E values (f r.flags 9) = _ at t9
    simp only [mode.2.2.2.2,active,flag,ite_true,Semiring.one_mul,eval_append,t4,t5,t6,t9] at guard
    cases kind <;> simp [ControlEvents.selected,flag] at guard ⊢ <;> grind only

#print axioms sound
end ZkBuild.ParametricGuardCounts
