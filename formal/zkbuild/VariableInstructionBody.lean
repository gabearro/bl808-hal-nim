import StaticInstructionBody
import VariableSignatureTrace
set_option autoImplicit false
namespace ZkBuild.VariableInstructionBody
open Lean.Grind OperandEvents InstructionSpanState

theorem no_label_opcode (code declared : Nat) (rule : StaticTyping.Rule) (signature : VariableTyping.signature code declared = some rule) :
    code ≠ 14 ∧ code ≠ 31 := by
  constructor
  · intro same; subst code
    simp [VariableTyping.signature,VariableTyping.environment] at signature
  · intro same; subst code
    simp [VariableTyping.signature,VariableTyping.environment] at signature

theorem row_spec {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) (i : Nat) (lo : first < i) (hi : i ≤ last) :
    VariableEventSpec.Spec rule (rows.getD i default).kind (rows.getD i default).valueType (InstructionTraceSound.state rows ops i).counts := by
  have code := opcodes values events rows ops schedule first last span i (by omega) hi
  have declared := (state_at rows ops tags first last span (i+1) (by omega) (by omega)).2
  have found : VariableTyping.signature (ops.getD i 0) (EnvironmentTraceSound.state rows tags (i+1)).val = some rule := by
    rw [code,declared]; exact signature
  have typed := variables.typing i (by have := span.bounded; omega) rule found
  rw [before_counts rows ops first last span i lo hi] at typed
  exact typed

theorem kinds {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) (i : Nat) (lo : first < i) (hi : i < last) :
    (rows.getD i default).kind = .pop ∨ (rows.getD i default).kind = .push := by
  have middle := span.middle i lo hi
  have typed := row_spec values events rows ops schedule tables typing tags variables first last span rule signature i lo (by omega)
  have label : (rows.getD i default).kind ≠ .labelCheck := by
    intro kind
    have labels := schedule.labels i (by have := span.bounded; omega) kind
    have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
    rw [code] at labels
    have excluded := no_label_opcode _ _ rule signature
    rcases labels with left | right
    · exact excluded.1 left
    · exact excluded.2 right
  cases kind : (rows.getD i default).kind with
  | functionBegin => exact False.elim (middle.1 kind)
  | instructionBegin => exact False.elim (middle.2.1 kind)
  | instructionEnd => exact False.elim (middle.2.2.1 kind)
  | functionEnd => exact False.elim (middle.2.2.2.1 kind)
  | padding => exact False.elim (middle.2.2.2.2 kind)
  | labelCheck => exact False.elim (label kind)
  | controlPush => exact False.elim (typed.noControl.1 kind)
  | controlPop => exact False.elim (typed.noControl.2.1 kind)
  | pop => exact Or.inl rfl
  | push => exact Or.inr rfl
  | clear => exact False.elim (typed.noControl.2.2 kind)

theorem segment {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) (count : Nat) :
    ∀ i, first < i → i+count = last →
      VariableEvents.Body rule (InstructionTraceSound.state rows ops i).counts.pops
        (InstructionTraceSound.state rows ops i).counts.pushes
        (tokens rows i count) := by
  induction count with
  | zero =>
    intro i lo finish
    have same : i = last := by omega
    subst i
    have typed := row_spec values events rows ops schedule tables typing tags variables first last span rule signature last lo (by omega)
    exact typed.finish span.endKind
  | succ count ih =>
    intro i lo finish
    have hi : i < last := by omega
    have middle := span.middle i lo hi
    have typed := row_spec values events rows ops schedule tables typing tags variables first last span rule signature i lo (by omega)
    have tail := ih (i+1) (by omega) (by omega)
    have label : (rows.getD i default).kind ≠ .labelCheck := by
      intro kind
      have labels := schedule.labels i (by have := span.bounded; omega) kind
      have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
      rw [code] at labels
      have excluded := no_label_opcode _ _ rule signature
      rcases labels with left | right
      · exact excluded.1 left
      · exact excluded.2 right
    cases kind : (rows.getD i default).kind with
    | functionBegin => exact False.elim (middle.1 kind)
    | instructionBegin => exact False.elim (middle.2.1 kind)
    | instructionEnd => exact False.elim (middle.2.2.1 kind)
    | functionEnd => exact False.elim (middle.2.2.2.1 kind)
    | padding => exact False.elim (middle.2.2.2.2 kind)
    | labelCheck => exact False.elim (label kind)
    | controlPush => exact False.elim (typed.noControl.1 kind)
    | controlPop => exact False.elim (typed.noControl.2.1 kind)
    | pop =>
      have facts := typed.pop kind
      simp only [tokens,token,kind,List.singleton_append,VariableEvents.Body]
      refine ⟨facts.2,facts.1,?_⟩
      simpa only [InstructionTraceSound.state,InstructionCounts.next,InstructionCounts.before,kind,reduceCtorEq,or_self,ite_false,ite_true,Nat.add_zero] using tail
    | push =>
      have facts := typed.push kind
      simp only [tokens,token,kind,List.singleton_append,VariableEvents.Body]
      refine ⟨facts.2.2,facts.2.1,facts.1,?_⟩
      simpa only [InstructionTraceSound.state,InstructionCounts.next,InstructionCounts.before,kind,reduceCtorEq,or_self,ite_false,ite_true,Nat.add_zero] using tail
    | clear => exact False.elim (typed.noControl.2.2 kind)

theorem body_sound {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) :
    VariableEvents.Body rule 0 0 (InstructionSpanState.body rows first last) := by
  have result := segment values events rows ops schedule tables typing tags variables first last span rule signature (last-first-1) (first+1) (by omega) (by have := span.ordered; omega)
  simpa only [InstructionSpanState.body,initial_counts rows ops first last span] using result

theorem known_inputs (code declared : Nat) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature code declared = some rule) : ∀ value ∈ rule.inputs, value < 7 := by
  intro value member
  obtain ⟨i,ib,equal⟩ := List.mem_iff_getElem.mp member
  have fields := VariableRuleFields.fields code declared rule signature
  have atIndex : VariableEvents.inputType rule i = value := by
    simp only [VariableEvents.inputType,List.getElem?_eq_getElem ib,Option.getD_some,equal]
  rw [← atIndex,fields.2.2.2.2.1]
  unfold VariableRuleFields.inputType
  split
  · exact fields.1
  · decide

theorem body_shape {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) :
    ∃ inputs : List Nat, inputs.length = rule.inputs.length ∧
      (∀ i (h : i < inputs.length), StaticTyping.popAllowed rule i inputs[i] = true) ∧
      InstructionSpanState.body rows first last = inputs.map StaticEvents.Token.pop ++ rule.output.toList.map StaticEvents.Token.push := by
  exact VariableEvents.body_shape rule _ (VariableRuleFields.fields _ _ rule signature).2.2.2.2.2
    (known_inputs _ _ rule signature) (body_sound values events rows ops schedule tables typing tags variables first last span rule signature)

theorem body_length {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (tables : List ReadOnlyMatrix.Record) (typing : DynamicTypingMatrix.Record) (tags : Nat → Fin 7)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : VariableTyping.signature (ops.getD first 0) (tags first).val = some rule) :
    (InstructionSpanState.body rows first last).length = last-first-1 := by
  apply tokens_length
  intro i lo hi
  have choices := kinds values events rows ops schedule tables typing tags variables first last span rule signature i (by omega) (by omega)
  rcases choices with pop | push <;> simp only [token, *, List.length_singleton]

#print axioms kinds
#print axioms body_length
#print axioms known_inputs
#print axioms body_shape
#print axioms segment
#print axioms body_sound
end ZkBuild.VariableInstructionBody
