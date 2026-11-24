import InstructionSpans
import EnvironmentTraceSound
set_option autoImplicit false
namespace ZkBuild.InstructionSpanState
open Lean.Grind OperandEvents

theorem interior (rows : List Row) (first last : Nat) (span : InstructionSpans.Span rows first last)
    (i : Nat) (lo : first < i) (hi : i ≤ last) :
    (rows.getD i default).kind ≠ .functionBegin ∧ (rows.getD i default).kind ≠ .instructionBegin ∧
    (rows.getD i default).kind ≠ .padding := by
  by_cases ending : i = last
  · rw [ending,span.endKind]
    decide
  · have h := span.middle i lo (by omega)
    exact ⟨h.1,h.2.1,h.2.2.2.2⟩

theorem state_constant (rows : List Row) (ops : List Nat) (tags : Nat → Fin 7) (first last : Nat)
    (span : InstructionSpans.Span rows first last) (distance : Nat) (bound : first+1+distance ≤ last+1) :
    (InstructionTraceSound.state rows ops (first+1+distance)).opcode = ops.getD first 0 ∧
    EnvironmentTraceSound.state rows tags (first+1+distance) = tags first := by
  induction distance with
  | zero => simp only [Nat.add_zero,InstructionTraceSound.state,EnvironmentTraceSound.state,InstructionSchedule.chosenOpcode,span.beginKind,reduceCtorEq,or_true,ite_true,and_self]
  | succ distance ih =>
    have prior := ih (by omega)
    have kinds := interior rows first last span (first+1+distance) (by omega) (by omega)
    have stepIndex : first+1+(distance+1) = (first+1+distance)+1 := by omega
    rw [stepIndex]
    constructor
    · change InstructionSchedule.chosenOpcode _ _ _ = _
      simpa only [InstructionSchedule.chosenOpcode,kinds.1,kinds.2.1,or_self,ite_false] using prior.1
    · change (if (rows.getD (first+1+distance) default).kind = .functionBegin ∨
        (rows.getD (first+1+distance) default).kind = .instructionBegin then tags _ else EnvironmentTraceSound.state rows tags _) = _
      simpa only [kinds.1,kinds.2.1,or_self,ite_false] using prior.2

theorem state_at (rows : List Row) (ops : List Nat) (tags : Nat → Fin 7) (first last : Nat)
    (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first < i) (hi : i ≤ last+1) :
    (InstructionTraceSound.state rows ops i).opcode = ops.getD first 0 ∧ EnvironmentTraceSound.state rows tags i = tags first := by
  have same : first+1+(i-(first+1)) = i := by omega
  simpa only [same] using state_constant rows ops tags first last span (i-(first+1)) (by omega)

theorem opcodes {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first ≤ i) (hi : i ≤ last) :
    ops.getD i 0 = ops.getD first 0 := by
  by_cases same : i = first
  · simp only [same]
  have kinds := interior rows first last span i (by omega) hi
  obtain ⟨_,_,_,binding⟩ := schedule.binding i (by have := span.bounded; omega)
  have code : ops.getD i 0 = (InstructionTraceSound.state rows ops i).opcode := by
    simpa only [InstructionSchedule.chosenOpcode,kinds.1,kinds.2.1,kinds.2.2,or_self,ite_false] using binding.2.1
  exact code.trans (state_at rows ops (fun _ => ⟨0,by decide⟩) first last span i (by omega) (by omega)).1

theorem initial_counts (rows : List Row) (ops : List Nat) (first last : Nat) (span : InstructionSpans.Span rows first last) :
    (InstructionTraceSound.state rows ops (first+1)).counts = {} := by
  change InstructionCounts.next _ (rows.getD first default).kind = {}
  rw [span.beginKind]
  rfl

theorem before_counts (rows : List Row) (ops : List Nat) (first last : Nat) (span : InstructionSpans.Span rows first last)
    (i : Nat) (lo : first < i) (hi : i ≤ last) :
    InstructionCounts.before (InstructionTraceSound.state rows ops i).counts (rows.getD i default).kind =
      (InstructionTraceSound.state rows ops i).counts := by
  have kinds := interior rows first last span i lo hi
  simp only [InstructionCounts.before,kinds.1,kinds.2.1,or_self,ite_false]

def token (row : Row) : List StaticEvents.Token := match row.kind with
  | .pop => [.pop row.valueType.val]
  | .push => [.push row.valueType.val]
  | .clear => [.clear]
  | _ => []

def tokens (rows : List Row) : Nat → Nat → List StaticEvents.Token
  | _,0 => []
  | start,count+1 => token (rows.getD start default) ++ tokens rows (start+1) count

def body (rows : List Row) (first last : Nat) := tokens rows (first+1) (last-first-1)

theorem tokens_length (rows : List Row) (count : Nat) : ∀ start,
    (∀ i, start ≤ i → i < start+count → (token (rows.getD i default)).length = 1) →
    (tokens rows start count).length = count := by
  induction count with
  | zero => intro start _; rfl
  | succ count ih =>
    intro start lengths
    have head := lengths start (by omega) (by omega)
    have tail := ih (start+1) (fun i lo hi => lengths i (by omega) (by omega))
    simp only [tokens,List.length_append,head,tail]
    omega

#print axioms state_constant
#print axioms opcodes
#print axioms initial_counts
#print axioms before_counts
end ZkBuild.InstructionSpanState
