import StaticEvents
set_option autoImplicit false
set_option maxRecDepth 4096
set_option maxHeartbeats 2000000
namespace ZkBuild.StaticTypingBounds

private theorem ite_eq_cases {α : Type} (p : Prop) [Decidable p] (a b c : α) :
    (if p then a else b) = c ↔ (p ∧ a = c) ∨ (¬p ∧ b = c) := by
  by_cases h : p <;> simp [h]

private theorem other_valid (code : Nat) (rule : StaticTyping.Rule)
    (found : StaticTyping.other code = some rule) : StaticTyping.validShape rule = true := by
  unfold StaticTyping.other StaticTyping.mk at found
  simp only [ite_eq_cases,Option.some.injEq,reduceCtorEq] at found
  repeat' first | (rcases found with ⟨_,found⟩ | ⟨_,found⟩) | (subst rule)
  all_goals first | decide | contradiction

theorem valid (code : Nat) (rule : StaticTyping.Rule)
    (found : StaticTyping.signature code = some rule) : StaticTyping.validShape rule = true := by
  unfold StaticTyping.signature at found
  cases numeric : WasmNumericTyping.signature code with
  | none => simp only [numeric] at found; exact other_valid code rule found
  | some nr =>
    simp only [numeric,StaticTyping.mk,Option.some.injEq] at found
    subst rule
    unfold WasmNumericTyping.signature at numeric
    split at numeric
    · simp only [Option.some.injEq] at numeric
      subst nr
      have arity := WasmNumericTyping.arity_bound code
      have source := (WasmNumericTyping.sourceType code).isLt
      have target := (WasmNumericTyping.targetType code).isLt
      simp [StaticTyping.validShape,List.all_replicate,List.length_replicate]
      omega
    · contradiction

theorem bounds (code : Nat) (rule : StaticTyping.Rule)
    (found : StaticTyping.signature code = some rule) :
    rule.inputs.length < NumericEvents.countBound ∧ rule.output.getD 0 < NumericEvents.countBound := by
  have shape := valid code rule found
  simp only [StaticTyping.validShape,Bool.and_eq_true_iff,decide_eq_true_eq] at shape
  have arity : rule.inputs.length ≤ 3 := shape.1.1.1
  constructor
  · unfold NumericEvents.countBound; omega
  · cases h : rule.output with
    | none => simp [h,NumericEvents.countBound]
    | some ty =>
      have small : ty < 7 := by simpa [h] using shape.1.2
      simp [h,NumericEvents.countBound]; omega

#print axioms valid
#print axioms bounds
end ZkBuild.StaticTypingBounds
