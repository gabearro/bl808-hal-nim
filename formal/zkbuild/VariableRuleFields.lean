import VariableEvents
set_option autoImplicit false
namespace ZkBuild.VariableRuleFields

def inputCount (code : Nat) : Nat :=
  if code = 33 ∨ code = 34 ∨ code = 36 ∨ code = 37 then 1
  else if code = 38 ∨ code = 271 then 2 else if code = 273 then 3 else 0

def outputCount (code : Nat) : Nat :=
  if code = 32 ∨ code = 34 ∨ code = 35 ∨ code = 37 ∨ code = 271 ∨ code = 272 then 1 else 0

def outputType (code declared : Nat) : Nat :=
  if code = 32 ∨ code = 34 ∨ code = 35 ∨ code = 37 then declared else 0

def inputType (code declared index : Nat) : Nat :=
  if (index = 0 ∧ (code = 33 ∨ code = 34 ∨ code = 36 ∨ code = 38)) ∨
     (index = 1 ∧ (code = 271 ∨ code = 273)) then declared else 0

private theorem ite_cases {α : Type} (p : Prop) [Decidable p] (a b c : α) :
    (if p then a else b) = c ↔ (p ∧ a = c) ∨ (¬p ∧ b = c) := by
  by_cases h : p <;> simp [h]

-- Unlike an enumeration below a chosen maximum opcode, this result covers
-- every natural opcode and every pop index, including out-of-arity indices.
theorem fields (code declared : Nat) (rule : StaticTyping.Rule)
    (found : VariableTyping.signature code declared = some rule) :
    declared < 7 ∧ rule.inputs.length = inputCount code ∧
    StaticEvents.outputCount rule = outputCount code ∧ rule.output.getD 0 = outputType code declared ∧
    (∀ index, VariableEvents.inputType rule index = inputType code declared index) ∧ rule.clears = false := by
  unfold VariableTyping.signature StaticTyping.mk at found
  simp only [ite_cases,Option.some.injEq,reduceCtorEq] at found
  rcases found with ⟨_,bad⟩ | ⟨small,found⟩
  · contradiction
  rcases found with ⟨_,bad⟩ | ⟨_,found⟩
  · contradiction
  have declaredBound : declared < 7 := by omega
  repeat' first | (rcases found with ⟨codeEq,found⟩ | ⟨_,found⟩) | (subst rule)
  all_goals try contradiction
  all_goals try rcases codeEq with rfl | rfl
  all_goals try subst code
  all_goals refine ⟨declaredBound,?_,?_,?_,?_,rfl⟩
  all_goals try { simp [inputCount,outputCount,outputType,StaticEvents.outputCount] }
  all_goals intro index
  all_goals cases index with
  | zero => simp [VariableEvents.inputType,inputType]
  | succ index => cases index with
    | zero => simp [VariableEvents.inputType,inputType]
    | succ index => cases index <;> simp [VariableEvents.inputType,inputType,List.getElem?_eq_none]

#print axioms fields
end ZkBuild.VariableRuleFields
