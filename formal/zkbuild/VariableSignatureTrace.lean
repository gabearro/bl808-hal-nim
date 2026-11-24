import VariableSemanticSound
set_option autoImplicit false
namespace ZkBuild.VariableSignatureTrace
open Lean.Grind

theorem signature_exists (code : Nat) (declared : Fin 7)
    (active : VariableTyping.environment code ≠ 0)
    (references : VariableTyping.environment code = 3 → declared.val = 5 ∨ declared.val = 6) :
    ∃ rule : StaticTyping.Rule, VariableTyping.signature code declared.val = some rule := by
  have small : ¬declared.val ≥ 7 := by have := declared.isLt; omega
  by_cases c32 : code = 32
  · subst code
    simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small]
  by_cases c33 : code = 33
  · subst code
    simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small]
  by_cases c34 : code = 34
  · subst code
    simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small]
  by_cases c35 : code = 35
  · subst code
    simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small]
  by_cases c36 : code = 36
  · subst code
    simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small]
  by_cases c37 : code = 37
  · subst code
    have typed := references (by decide)
    rcases typed with typed | typed <;> simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small,typed]
  by_cases c38 : code = 38
  · subst code
    have typed := references (by decide)
    rcases typed with typed | typed <;> simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small,typed]
  by_cases c271 : code = 271
  · subst code
    have typed := references (by decide)
    rcases typed with typed | typed <;> simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small,typed]
  by_cases c272 : code = 272
  · subst code
    have typed := references (by decide)
    rcases typed with typed | typed <;> simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small,typed]
  by_cases c273 : code = 273
  · subst code
    have typed := references (by decide)
    rcases typed with typed | typed <;> simp [VariableTyping.signature,VariableTyping.environment,StaticTyping.mk,small,typed]
  simp [c32,c33,c34,c35,c36,c37,c38,c271,c272,c273,VariableTyping.environment] at active

theorem reference_invariant {F : Type} [Field F]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (rows : List OperandEvents.Row) (ops : List Nat) (tags : Nat → Fin 7)
    (instructions : InstructionSemanticSound.Schedule values events rows ops)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags) :
    ∀ i, i ≤ rows.length → VariableTyping.environment (InstructionTraceSound.state rows ops i).opcode = 3 →
      (EnvironmentTraceSound.state rows tags i).val = 5 ∨ (EnvironmentTraceSound.state rows tags i).val = 6 := by
  intro i ib
  induction i with
  | zero => simp [InstructionTraceSound.state,VariableTyping.environment]
  | succ i ih =>
    have rb : i < rows.length := by omega
    obtain ⟨_,_,_,binding⟩ := instructions.binding i rb
    by_cases fn : (rows.getD i default).kind = .functionBegin
    · have code := binding.2.2.1 fn
      have nextOpcode : (InstructionTraceSound.state rows ops (i+1)).opcode = 2 := by
        change InstructionSchedule.chosenOpcode _ _ _ = 2
        simp only [InstructionSchedule.chosenOpcode,fn,true_or,ite_true,code]
      rw [nextOpcode]
      simp [VariableTyping.environment]
    by_cases start : (rows.getD i default).kind = .instructionBegin
    · obtain ⟨mutable,access,_⟩ := variables.access i rb start
      simpa only [InstructionTraceSound.state,InstructionSchedule.chosenOpcode,EnvironmentTraceSound.state,start,or_true,ite_true]
        using (fun h => (access.tableType h).1)
    · have prior := ih (by omega)
      simpa only [InstructionTraceSound.state,InstructionSchedule.chosenOpcode,EnvironmentTraceSound.state,fn,start,or_self,ite_false] using prior

def Complete (typingRows : List OperandEvents.Row) (ops : List Nat) (tags : Nat → Fin 7) : Prop :=
  ∀ i, i < typingRows.length → VariableTyping.environment (ops.getD i 0) ≠ 0 → ∃ rule : StaticTyping.Rule,
    VariableTyping.signature (ops.getD i 0) (EnvironmentTraceSound.state typingRows tags (i+1)).val = some rule ∧
    VariableEventSpec.Spec rule (typingRows.getD i default).kind (typingRows.getD i default).valueType
      (InstructionCounts.before (InstructionTraceSound.state typingRows ops i).counts (typingRows.getD i default).kind)

theorem complete {F : Type} [Field F]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (rows : List OperandEvents.Row) (ops : List Nat) (tags : Nat → Fin 7)
    (instructions : InstructionSemanticSound.Schedule values events rows ops)
    (variables : VariableSemanticSound.Schedule values tables typing rows ops tags) : Complete rows ops tags := by
  intro i ib active
  obtain ⟨_,_,_,binding⟩ := instructions.binding i ib
  have reference : VariableTyping.environment (ops.getD i 0) = 3 →
      (EnvironmentTraceSound.state rows tags (i+1)).val = 5 ∨ (EnvironmentTraceSound.state rows tags (i+1)).val = 6 := by
    have after := reference_invariant values tables events typing rows ops tags instructions variables (i+1) (by omega)
    by_cases padding : (rows.getD i default).kind = .padding
    · have code : ops.getD i 0 = 0 := by simpa only [padding,ite_true] using binding.2.1
      rw [code] at active
      exact False.elim (active rfl)
    · have code : ops.getD i 0 = (InstructionTraceSound.state rows ops (i+1)).opcode := by
        simpa only [padding,ite_false,InstructionTraceSound.state] using binding.2.1
      rw [code]
      exact after
  obtain ⟨rule,signature⟩ := signature_exists _ _ active reference
  exact ⟨rule,signature,variables.typing i ib rule signature⟩

#print axioms signature_exists
#print axioms reference_invariant
#print axioms complete
end ZkBuild.VariableSignatureTrace
