import VariableInstructionBody
set_option autoImplicit false
namespace ZkBuild.InstructionBodies
open Lean.Grind OperandEvents

structure Properties (rows : List Row) (ops : List Nat) (tags : Nat → Fin 7) (first last : Nat) : Prop where
  span : InstructionSpans.Span rows first last
  uniqueEnd : ∀ other, InstructionSpans.Span rows first other → other = last
  opcode : ∀ i, first ≤ i → i ≤ last → ops.getD i 0 = ops.getD first 0
  declared : ∀ i, first < i → i ≤ last+1 → EnvironmentTraceSound.state rows tags i = tags first
  fixed : ∀ rule : StaticTyping.Rule, StaticTyping.signature (ops.getD first 0) = some rule →
    StaticEvents.Body rule 0 0 0 (InstructionSpanState.body rows first last) ∧
    StaticInstructionBody.Shape rule (InstructionSpanState.body rows first last) ∧
    (InstructionSpanState.body rows first last).length = last-first-1
  variableBody : VariableTyping.environment (ops.getD first 0) ≠ 0 → ∃ rule : StaticTyping.Rule,
    VariableTyping.signature (ops.getD first 0) (tags first).val = some rule ∧
    VariableEvents.Body rule 0 0 (InstructionSpanState.body rows first last) ∧
    (InstructionSpanState.body rows first last).length = last-first-1 ∧
    ∃ inputs : List Nat, inputs.length = rule.inputs.length ∧
      (∀ i (h : i < inputs.length), StaticTyping.popAllowed rule i inputs[i] = true) ∧
      InstructionSpanState.body rows first last = inputs.map StaticEvents.Token.pop ++ rule.output.toList.map StaticEvents.Token.push

def Complete (rows : List Row) (ops : List Nat) (tags : Nat → Fin 7) : Prop :=
  ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin →
    ∃ last, Properties rows ops tags first last

theorem complete {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (instructions : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags) : Complete rows ops tags := by
  intro first fb beginKind
  obtain ⟨last,span⟩ := InstructionSpans.exists_span values events rows ops instructions first fb beginKind
  refine ⟨last,span,?_,?_,?_,?_,?_⟩
  · intro other found
    exact InstructionSpans.unique rows first other last found span
  · exact InstructionSpanState.opcodes values events rows ops instructions first last span
  · intro i lo hi; exact (InstructionSpanState.state_at rows ops tags first last span i lo hi).2
  · intro rule signature
    exact ⟨StaticInstructionBody.body_sound values events rows ops instructions first last span rule signature,
      StaticInstructionBody.body_shape values events rows ops instructions first last span rule signature,
      StaticInstructionBody.body_length values events rows ops instructions first last span rule signature⟩
  · intro active
    obtain ⟨rule,signature,_⟩ := VariableSignatureTrace.complete values tables events typing rows ops tags instructions variables first fb active
    have declared := (InstructionSpanState.state_at rows ops tags first last span (first+1) (by omega) (by have := span.ordered; omega)).2
    rw [declared] at signature
    exact ⟨rule,signature,
      VariableInstructionBody.body_sound values events rows ops instructions tables typing tags variables first last span rule signature,
      VariableInstructionBody.body_length values events rows ops instructions tables typing tags variables first last span rule signature,
      VariableInstructionBody.body_shape values events rows ops instructions tables typing tags variables first last span rule signature⟩

#print axioms complete
end ZkBuild.InstructionBodies
