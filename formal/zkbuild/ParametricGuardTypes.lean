import ParametricTransition
set_option autoImplicit false
namespace ZkBuild.ParametricGuardTypes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricRowCheck ParametricState
attribute [local instance] Ring.intCast Semiring.natCast

def output (s : State) (code : Nat) : Nat :=
  if code = 27 then (if s.first.val = 7 then s.second.val else s.first.val) else s.declared

structure Spec (s : State) (kind : Kind) (code : Nat) (actual : Fin 8) : Prop where
  typed : popping kind code = true → s.pops ≠ 0 → code = 28 → CallEvents.InputOk s.declared actual.val
  inferred : popping kind code = true → s.pops ≠ 0 → code = 27 →
    actual.val ≠ 5 ∧ actual.val ≠ 6 ∧ (s.pops = 2 → s.first.val = actual.val ∨ s.first.val = 7 ∨ actual.val = 7)
  push : pushing kind code = true → actual.val = output s code

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ParametricRowCheck.Record) (meaning : ParametricRowSound.Meaning values r)
    (kind : Kind) (code : Nat) (cb : code < 2^16) (ci : E values (f r.row 8) = (code : F))
    (actual : Fin 8) (ai : E values (f r.row 4) = (actual.val : F))
    (s : State) (image : Image values (ready r) s) (db : s.declared < 7)
    (masks : ParametricTransition.Masks values r s kind code actual) : Spec s kind code actual := by
  have mode := ParametricMode.images values one r meaning code cb ci
  have di : E values (f r.after 14) = (s.declared : F) := image.1
  have result := ParametricTransition.image values r meaning kind code actual ai s image masks
  have aImage : E values (f r.after 34) = ((advance s kind code actual).first.val : F) := result.2.2.2.1
  have bImage : E values (f r.after 35) = ((advance s kind code actual).second.val : F) := result.2.2.2.2
  have untypedPop := meaning.multiply (f r.after 0) (valuePop r) 29 (by simp [multiplies])
  have typedPop := meaning.multiply (f r.after 1) (valuePop r) 27 (by simp [multiplies])
  have known := meaning.multiply (f r.after 27) (sub o (f r.after 25)) 28 (by simp [multiplies])
  have x5 := ParametricMode.indicator values one r meaning _ actual.val 5 30 (by have := actual.isLt; omega) (by decide) ai (by simp [zeros])
  have x6 := ParametricMode.indicator values one r meaning _ actual.val 6 31 (by have := actual.isLt; omega) (by decide) ai (by simp [zeros])
  have typedGuard := meaning.guard _ _ (by simp [guards] : (f r.after 28,sub (f r.row 4) (f r.after 14)) ∈ guards r)
  have refGuard := meaning.guard _ _ (by simp [guards] : (f r.after 29,f r.after 30++f r.after 31) ∈ guards r)
  simp only [mode.1,mode.2.1,valuePop,eval_sub,masks.pop,masks.condition] at typedPop untypedPop
  constructor
  · intro enabled value typed
    subst code
    simp only [enabled,value,decide_false,Bool.true_and,flag,decide_true,ite_true,Bool.false_eq_true,ite_false] at typedPop
    have popEq : E values (f r.after 27) = 1 := by grind only
    simp only [popEq,eval_sub,o,eval_constant values one,Ring.intCast_one,masks.unknown] at known
    simp only [known,eval_sub,ai,di,Semiring.one_mul] at typedGuard
    exact ParametricEvents.input_guard (F := F) actual ⟨s.declared,by omega⟩ typedGuard
  · intro enabled value untyped
    subst code
    simp only [enabled,value,decide_false,Bool.true_and,flag,decide_true,ite_true,Bool.false_eq_true,ite_false] at untypedPop
    have popEq : E values (f r.after 29) = 1 := by grind only
    simp only [popEq,Semiring.one_mul,eval_append,x5,x6] at refGuard
    have exclusion := ParametricEvents.reference_exclusion (F := F) actual.val refGuard
    refine ⟨exclusion.1,exclusion.2,?_⟩
    intro second
    have a : E values (f r.after 34) = (s.first.val : F) := by simpa [advance,firstPop,second] using aImage
    have unknown := ParametricMode.indicator values one r meaning _ s.first.val 7 36 (by have := s.first.isLt; omega) (by decide) a (by simp [zeros])
    have both := meaning.multiply (sub o (f r.after 36)) (sub o (f r.after 25)) 37 (by simp [multiplies])
    have activeSecond := meaning.multiply (f r.after 0) (f r.after 33) 38 (by simp [multiplies])
    have selected := meaning.multiply (f r.after 38) (f r.after 37) 39 (by simp [multiplies])
    have matched := meaning.guard _ _ (by simp [guards] : (f r.after 39,sub (f r.after 34) (f r.row 4)) ∈ guards r)
    simp only [mode.1,masks.second,secondPop,enabled,second,decide_true,Bool.and_self,flag,ite_true] at activeSecond
    have selection : E values (f r.after 38) = 1 := by grind only
    simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,unknown,masks.unknown] at both
    simp only [selection,Semiring.one_mul,both] at selected
    simp only [selected,eval_sub,a,ai] at matched
    exact ParametricEvents.match_guard (F := F) s.first actual matched
  · intro enabled
    have parts := Bool.and_eq_true_iff.mp enabled
    have kindEq : kind = .push := of_decide_eq_true parts.2
    have a : E values (f r.after 34) = (s.first.val : F) := by simpa [advance,firstPop,popping,kindEq] using aImage
    have b : E values (f r.after 35) = (s.second.val : F) := by simpa [advance,secondPop,popping,kindEq] using bImage
    have unknown := ParametricMode.indicator values one r meaning _ s.first.val 7 36 (by have := s.first.isLt; omega) (by decide) a (by simp [zeros])
    have inferred := meaning.select (f r.after 36) (f r.after 35) (f r.after 34) 40 (by simp [selects])
    have left := meaning.multiply (f r.after 0) (f r.after 40) 41 (by simp [multiplies])
    have right := meaning.multiply (f r.after 1++f r.after 2) (f r.after 14) 42 (by simp [multiplies])
    have guard := meaning.guard _ _ (by simp [guards] : (f r.after 20,sub (f r.row 4) (f r.after 41++f r.after 42)) ∈ guards r)
    simp only [unknown,a,b] at inferred
    simp only [mode.1,inferred] at left
    simp only [eval_append,mode.2.1,mode.2.2.1,di] at right
    simp only [masks.push,enabled,flag,ite_true,Semiring.one_mul,eval_sub,eval_append,ai,left,right] at guard
    have codes : code = 27 ∨ code = 28 ∨ code = 208 := of_decide_eq_true parts.1
    rcases codes with rfl | rfl | rfl
    · by_cases unknown : s.first.val = 7
      · simp [flag,unknown,output] at guard ⊢
        apply NumericEvents.nat_eq (F := F) actual.val s.second.val (by have := actual.isLt; simp [NumericEvents.countBound]; omega) (by have := s.second.isLt; simp [NumericEvents.countBound]; omega)
        grind only
      · simp [flag,unknown,output] at guard ⊢
        apply NumericEvents.nat_eq (F := F) actual.val s.first.val (by have := actual.isLt; simp [NumericEvents.countBound]; omega) (by have := s.first.isLt; simp [NumericEvents.countBound]; omega)
        grind only
    all_goals
      simp [flag,output] at guard ⊢
      apply NumericEvents.nat_eq (F := F) actual.val s.declared (by have := actual.isLt; simp [NumericEvents.countBound]; omega) (by simp [NumericEvents.countBound]; omega)
      grind only

#print axioms sound
end ZkBuild.ParametricGuardTypes
