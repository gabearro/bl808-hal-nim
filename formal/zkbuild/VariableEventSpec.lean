import VariableRuleFields
import InstructionCounts
set_option autoImplicit false
namespace ZkBuild.VariableEventSpec
open Lean.Grind

structure Spec (rule : StaticTyping.Rule) (kind : OperandEvents.Kind) (actual : Fin 8)
    (counts : InstructionCounts.Counts) : Prop where
  pop : kind = .pop → (actual.val = VariableEvents.inputType rule counts.pops ∨ actual.val = 7) ∧ counts.pushes = 0
  push : kind = .push → rule.output = some actual.val ∧ counts.pops = rule.inputs.length ∧ counts.pushes = 0
  finish : kind = .instructionEnd → counts.pops = rule.inputs.length ∧ counts.pushes = StaticEvents.outputCount rule
  noControl : kind ≠ .controlPush ∧ kind ≠ .controlPop ∧ kind ≠ .clear

theorem supported (code declared : Nat) (rule : StaticTyping.Rule)
    (found : VariableTyping.signature code declared = some rule) : VariableTyping.environment code ≠ 0 := by
  by_cases c32 : code = 32
  · simp [c32,VariableTyping.environment]
  by_cases c33 : code = 33
  · simp [c33,VariableTyping.environment]
  by_cases c34 : code = 34
  · simp [c34,VariableTyping.environment]
  by_cases c35 : code = 35
  · simp [c35,VariableTyping.environment]
  by_cases c36 : code = 36
  · simp [c36,VariableTyping.environment]
  by_cases c37 : code = 37
  · simp [c37,VariableTyping.environment]
  by_cases c38 : code = 38
  · simp [c38,VariableTyping.environment]
  by_cases c271 : code = 271
  · simp [c271,VariableTyping.environment]
  by_cases c272 : code = 272
  · simp [c272,VariableTyping.environment]
  by_cases c273 : code = 273
  · simp [c273,VariableTyping.environment]
  simp [c32,c33,c34,c35,c36,c37,c38,c271,c272,c273,VariableTyping.signature,VariableTyping.environment] at found

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (code declared : Nat) (rule : StaticTyping.Rule) (signature : VariableTyping.signature code declared = some rule)
    (kind : OperandEvents.Kind) (actual : Fin 8) (counts : InstructionCounts.Counts)
    (bounds : counts.pops < NumericEvents.countBound ∧ counts.pushes < NumericEvents.countBound)
    (gates : VariableEvents.Gates (F := F) rule kind actual counts.pops counts.pushes) :
    Spec rule kind actual counts := by
  have fields := VariableRuleFields.fields code declared rule signature
  have arity : rule.inputs.length < NumericEvents.countBound := by
    rw [fields.2.1]
    simp only [VariableRuleFields.inputCount]
    split <;> try {exact (by decide)}
    split <;> try {exact (by decide)}
    split <;> decide
  have output : rule.output.getD 0 < NumericEvents.countBound := by
    rw [fields.2.2.2.1]
    unfold VariableRuleFields.outputType
    split
    · have := fields.1; unfold NumericEvents.countBound; omega
    · decide
  have input : VariableEvents.inputType rule counts.pops < 7 := by
    rw [fields.2.2.2.2.1]
    unfold VariableRuleFields.inputType
    split
    · exact fields.1
    · decide
  refine ⟨?_,?_,?_,VariableEvents.no_control rule kind actual counts.pops counts.pushes gates⟩
  · intro h; subst kind
    exact VariableEvents.pop_sound rule actual counts.pops counts.pushes input bounds.2 gates
  · intro h; subst kind
    exact VariableEvents.push_sound rule actual counts.pops counts.pushes arity output bounds.1 bounds.2 gates
  · intro h; subst kind
    exact VariableEvents.end_sound rule actual counts.pops counts.pushes arity bounds.1 bounds.2 gates

#print axioms supported
#print axioms sound
end ZkBuild.VariableEventSpec
