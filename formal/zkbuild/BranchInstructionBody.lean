import BranchTraceSound
import BranchHeadSound
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.BranchInstructionBody
open Lean.Grind OperandEvents BranchStep BranchTraceSound

def labels (rows : List Row) (data : Nat → Data) : Nat → Nat → List Nat
  | _,0 => []
  | i,count+1 => (if (rows.getD i default).kind = .labelCheck then [(data i).depth.val] else []) ++ labels rows data (i+1) count

theorem prepared (rows : List Row) (ops : List Nat) (data : Nat → Data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first < i) (hi : i ≤ last) :
    prepare (rows.getD i default).kind (state rows ops data i) (data i).head = state rows ops data i := by
  have kinds := InstructionSpanState.interior rows first last span i lo hi
  simp only [prepare,kinds.1,kinds.2.1,or_self,ite_false]

theorem segment {F : Type} [Field F] (values : Nat → F) (splits : DeclarationMatrix.Splits)
    (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → Data) (facts : Facts values splits tables s rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ops.getD first 0 = 14)
    (count : Nat) : ∀ i, first < i → i+count = last →
      BranchLists.Consumes (BranchStore.table values (DynamicTypingMatrix.bank tables s 1))
        (state rows ops data i).val (labels rows data i count) (state rows ops data last).val := by
  induction count with
  | zero =>
    intro i lo ending
    have same : i = last := by omega
    subst i
    exact .nil
  | succ count ih =>
    intro i lo ending
    have hi : i < last := by omega
    have ib : i < rows.length := by have := span.bounded; omega
    have code : ops.getD i 0 = 14 := (InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)).trans active
    have ready := prepared rows ops data first last span i lo (by omega)
    have next := ih (i+1) (by omega) (by omega)
    have stateStep : state rows ops data (i+1) = advance (rows.getD i default).kind (ops.getD i 0) (state rows ops data i) (data i).next := by
      change advance _ _ (prepare _ _ _) _ = _
      rw [ready]
    by_cases label : (rows.getD i default).kind = .labelCheck
    · have marked : mark (rows.getD i default).kind (ops.getD i 0) = true := by simp only [mark,label,code,and_self,decide_true]
      have found := (facts i ib).2.2.1 marked
      rw [ready] at found
      have positive := (facts i ib).2.1.positive marked
      rw [ready] at positive
      have step : state rows ops data (i+1) = (data i).next := by rw [stateStep]; simp only [advance,marked,ite_true]
      rw [step] at next
      simpa only [labels,label,ite_true,List.singleton_append] using BranchLists.Consumes.cons positive found next
    · have marked : mark (rows.getD i default).kind (ops.getD i 0) = false := by simp only [mark,label,false_and,decide_false]
      have step : state rows ops data (i+1) = state rows ops data i := by rw [stateStep]; simp only [advance,marked,Bool.false_eq_true,ite_false]
      rw [step] at next
      simpa only [labels,label,ite_false,List.nil_append] using next

theorem consumed {F : Type} [Field F] (values : Nat → F) (splits : DeclarationMatrix.Splits)
    (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → Data) (facts : Facts values splits tables s rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ops.getD first 0 = 14) :
    BranchLists.Consumes (BranchStore.table values (DynamicTypingMatrix.bank tables s 1))
      (data first).head.val (labels rows data (first+1) (last-first-1)) 0 := by
  have walk := segment values splits tables s events rows ops schedule data facts first last span active (last-first-1) (first+1)
    (by omega) (by have := span.ordered; omega)
  have initial : state rows ops data (first+1) = (data first).head := by
    change advance (rows.getD first default).kind _ (prepare (rows.getD first default).kind _ _) _ = _
    rw [span.beginKind]
    simp [prepare,advance,mark]
  have code : ops.getD last 0 = 14 := (InstructionSpanState.opcodes values events rows ops schedule first last span last (by have := span.ordered; omega) (by omega)).trans active
  have ended := (facts last span.bounded).2.1.finish (by simp only [ending,span.endKind,code,and_self,decide_true])
  rw [span.endKind] at ended
  have final : (state rows ops data last).val = 0 := by simpa [advance,prepare,mark] using ended
  rw [initial,final] at walk
  exact walk

theorem complete {F : Type} [Field F] (values : Nat → F) (splits : DeclarationMatrix.Splits)
    (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → Data) (facts : Facts values splits tables s rows ops data)
    (closed : BranchLists.Closed (BranchStore.table values (DynamicTypingMatrix.bank tables s 1)))
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ops.getD first 0 = 14)
    (positive : 0 < (data first).head.val)
    (present : ∃ cell, BranchStore.table values (DynamicTypingMatrix.bank tables s 1) (data first).head.val = some cell) :
    BranchLists.Follows (BranchStore.table values (DynamicTypingMatrix.bank tables s 1))
      (data first).head.val (labels rows data (first+1) (last-first-1)) ∧
      labels rows data (first+1) (last-first-1) ≠ [] := by
  obtain ⟨expected,path⟩ := BranchLists.terminates _ closed _ (Or.inr present)
  have consumed := consumed values splits tables s events rows ops schedule data facts first last span active
  have equal := BranchLists.complete_consumption _ _ expected _ path consumed
  rw [equal]
  exact ⟨path,BranchLists.nonempty _ _ _ path positive⟩

#print axioms segment
#print axioms consumed
#print axioms complete
end ZkBuild.BranchInstructionBody
