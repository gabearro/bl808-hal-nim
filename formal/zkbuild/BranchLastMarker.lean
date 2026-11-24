import BranchInstructionBody
set_option autoImplicit false
namespace ZkBuild.BranchLastMarker
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
open BranchStep BranchTraceSound BranchInstructionBody
attribute [local instance] Ring.intCast Semiring.natCast

theorem zero_iff_empty (store : BranchLists.Store) (cursor : Nat) (xs : List Nat)
    (consumed : BranchLists.Consumes store cursor xs 0) : cursor = 0 ↔ xs = [] := by
  cases consumed with
  | nil => simp
  | cons positive found rest =>
    constructor
    · intro zero; omega
    · intro empty; contradiction

def Markers {F : Type} [Field F] (values : Nat → F) (s : DynamicTypingMatrix.Stage)
    (rows : List Row) (ops : List Nat) (data : Nat → Data) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0 = 14 →
    ∀ i, first < i → i < last → (rows.getD i default).kind = .labelCheck →
      E values (f (rowAt s.outputs i) 1) = flag (decide (labels rows data (i+1) (last-i-1) = []))

/-- The terminal output marks exactly the last label event in each complete
    br_table body. Earlier zero-arity labels cannot masquerade as the default. -/
theorem sound {F : Type} [Field F] (values : Nat → F) (splits : Splits)
    (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → Data) (facts : Facts values splits tables s rows ops data) : Markers values s rows ops data := by
  intro first last span active i lo hi label
  have ib : i < rows.length := by have := span.bounded; omega
  have code : ops.getD i 0 = 14 :=
    (InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)).trans active
  have marked : mark (rows.getD i default).kind (ops.getD i 0) = true := by
    simp only [mark,label,code,and_self,decide_true]
  have after : state rows ops data (i+1) = (data i).next := by
    change advance (rows.getD i default).kind (ops.getD i 0) _ _ = _
    simp only [advance,marked,ite_true]
  have endCode : ops.getD last 0 = 14 :=
    (InstructionSpanState.opcodes values events rows ops schedule first last span last (by have := span.ordered; omega) (by omega)).trans active
  have ended := (facts last span.bounded).2.1.finish (by simp only [ending,span.endKind,endCode,and_self,decide_true])
  rw [span.endKind] at ended
  have final : (state rows ops data last).val = 0 := by simpa [advance,prepare,mark] using ended
  have suffix := segment values splits tables s events rows ops schedule data facts first last span active
    (last-i-1) (i+1) (by omega) (by omega)
  rw [after,final] at suffix
  have terminal := zero_iff_empty _ _ _ suffix
  simpa only [marked,Bool.true_and,terminal] using (facts i ib).2.2.2.2

#print axioms zero_iff_empty
#print axioms sound
end ZkBuild.BranchLastMarker
