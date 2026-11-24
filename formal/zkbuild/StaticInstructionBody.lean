import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.StaticInstructionBody
open Lean.Grind OperandEvents InstructionSpanState

theorem no_label_opcode (code : Nat) (rule : StaticTyping.Rule) (signature : StaticTyping.signature code = some rule) :
    code ≠ 14 ∧ code ≠ 31 := by
  constructor
  · intro same; subst code
    have missing : StaticTyping.signature 14 = none := by decide
    rw [missing] at signature; contradiction
  · intro same; subst code
    have missing : StaticTyping.signature 31 = none := by decide
    rw [missing] at signature; contradiction

theorem row_spec {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) (i : Nat) (lo : first < i) (hi : i ≤ last) :
    StaticEventSpec.Spec rule (rows.getD i default).kind (rows.getD i default).valueType (InstructionTraceSound.state rows ops i).counts := by
  have code := opcodes values events rows ops schedule first last span i (by omega) hi
  have found : StaticTyping.signature (ops.getD i 0) = some rule := by rw [code]; exact signature
  have typed := schedule.typing i (by have := span.bounded; omega) rule found
  rw [before_counts rows ops first last span i lo hi] at typed
  exact typed

theorem kinds {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) (i : Nat) (lo : first < i) (hi : i < last) :
    (rows.getD i default).kind = .pop ∨ (rows.getD i default).kind = .push ∨ (rows.getD i default).kind = .clear := by
  have middle := span.middle i lo hi
  have typed := row_spec values events rows ops schedule first last span rule signature i lo (by omega)
  have label : (rows.getD i default).kind ≠ .labelCheck := by
    intro kind
    have labels := schedule.labels i (by have := span.bounded; omega) kind
    have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
    rw [code] at labels
    have excluded := no_label_opcode _ rule signature
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
  | controlPush => exact False.elim (typed.noControlPush kind)
  | controlPop => exact False.elim (typed.noControlPop kind)
  | pop => exact Or.inl rfl
  | push => exact Or.inr (Or.inl rfl)
  | clear => exact Or.inr (Or.inr rfl)

theorem segment {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) (count : Nat) :
    ∀ i, first < i → i+count = last →
      StaticEvents.Body rule (InstructionTraceSound.state rows ops i).counts.pops
        (InstructionTraceSound.state rows ops i).counts.pushes (InstructionTraceSound.state rows ops i).counts.clears
        (tokens rows i count) := by
  induction count with
  | zero =>
    intro i lo finish
    have same : i = last := by omega
    subst i
    have typed := row_spec values events rows ops schedule first last span rule signature last lo (by omega)
    exact typed.finish span.endKind
  | succ count ih =>
    intro i lo finish
    have hi : i < last := by omega
    have middle := span.middle i lo hi
    have typed := row_spec values events rows ops schedule first last span rule signature i lo (by omega)
    have tail := ih (i+1) (by omega) (by omega)
    have label : (rows.getD i default).kind ≠ .labelCheck := by
      intro kind
      have labels := schedule.labels i (by have := span.bounded; omega) kind
      have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
      rw [code] at labels
      have excluded := no_label_opcode _ rule signature
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
    | controlPush => exact False.elim (typed.noControlPush kind)
    | controlPop => exact False.elim (typed.noControlPop kind)
    | pop =>
      have facts := typed.pop kind
      simp only [tokens,token,kind,List.singleton_append,StaticEvents.Body]
      refine ⟨facts.2,facts.1,?_⟩
      simpa only [InstructionTraceSound.state,InstructionCounts.next,InstructionCounts.before,kind,reduceCtorEq,or_self,ite_false,ite_true,Nat.add_zero] using tail
    | push =>
      have facts := typed.push kind
      simp only [tokens,token,kind,List.singleton_append,StaticEvents.Body]
      refine ⟨facts.2.2,facts.2.1,facts.1,?_⟩
      simpa only [InstructionTraceSound.state,InstructionCounts.next,InstructionCounts.before,kind,reduceCtorEq,or_self,ite_false,ite_true,Nat.add_zero] using tail
    | clear =>
      have facts := typed.clear kind
      simp only [tokens,token,kind,List.singleton_append,StaticEvents.Body]
      refine ⟨facts.1,facts.2,?_⟩
      simpa only [InstructionTraceSound.state,InstructionCounts.next,InstructionCounts.before,kind,reduceCtorEq,or_self,ite_false,ite_true,Nat.add_zero] using tail

theorem body_sound {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) :
    StaticEvents.Body rule 0 0 0 (InstructionSpanState.body rows first last) := by
  have result := segment values events rows ops schedule first last span rule signature (last-first-1) (first+1) (by omega) (by have := span.ordered; omega)
  simpa only [InstructionSpanState.body,initial_counts rows ops first last span] using result

def Shape (rule : StaticTyping.Rule) (tokens : List StaticEvents.Token) : Prop :=
  if rule.clears then tokens = [.clear] else ∃ inputs : List Nat,
    inputs.length = rule.inputs.length ∧
    (∀ i (h : i < inputs.length), StaticTyping.popAllowed rule i inputs[i] = true) ∧
    tokens = inputs.map StaticEvents.Token.pop ++ rule.output.toList.map StaticEvents.Token.push

theorem body_shape {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) :
    Shape rule (InstructionSpanState.body rows first last) := by
  have body := body_sound values events rows ops schedule first last span rule signature
  cases clear : rule.clears with
  | false =>
    have result := StaticEvents.body_shape rule _ 0 clear body
    simpa [Shape,clear] using result
  | true =>
    have valid := StaticTypingBounds.valid _ rule signature
    have zero : rule.inputs = [] ∧ rule.output = none := by
      have gate := (Bool.and_eq_true_iff.mp valid).2
      simpa only [clear,Bool.not_true,Bool.false_or,decide_eq_true_eq] using gate
    simpa [Shape,clear] using StaticEvents.clear_body rule _ zero.1 zero.2 clear body

theorem body_length {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (rule : StaticTyping.Rule)
    (signature : StaticTyping.signature (ops.getD first 0) = some rule) :
    (InstructionSpanState.body rows first last).length = last-first-1 := by
  apply tokens_length
  intro i lo hi
  have choices := kinds values events rows ops schedule first last span rule signature i (by omega) (by omega)
  rcases choices with pop | push | clear <;> simp only [token, *, List.length_singleton]

#print axioms kinds
#print axioms body_length
#print axioms body_shape
#print axioms segment
#print axioms body_sound
end ZkBuild.StaticInstructionBody
