import ParametricSemanticSound
import ParametricBodyRun
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.ParametricInstructionBody
open Lean.Grind OperandEvents InstructionSpanState ParametricState

theorem ready_interior (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32))
    (first last : Nat) (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first < i) (hi : i ≤ last) :
    ParametricTraceSound.ready rows ops primary i = ParametricTraceSound.state rows ops primary i := by
  have kinds := interior rows first last span i lo hi
  simp only [ParametricTraceSound.ready,prepare,kinds.1,kinds.2.1,or_self,ite_false]

theorem kinds {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (primary : Nat → Fin (2^32)) (trace : ParametricSemanticSound.Trace rows ops primary)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ParametricMode.active (ops.getD first 0) = true)
    (i : Nat) (lo : first < i) (hi : i < last) :
    (rows.getD i default).kind = .pop ∨ (rows.getD i default).kind = .push := by
  have middle := span.middle i lo hi
  have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
  have controls := (trace i (by have := span.bounded; omega)).1.noControl (by rw [code]; exact active)
  cases kind : (rows.getD i default).kind <;> simp_all [InstructionSpans.Middle]

theorem segment {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (primary : Nat → Fin (2^32)) (trace : ParametricSemanticSound.Trace rows ops primary)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ParametricMode.active (ops.getD first 0) = true)
    (count : Nat) : ∀ i, first < i → i+count = last →
      ParametricBodyRun.Run (ops.getD first 0) (ParametricTraceSound.state rows ops primary i) (tokens rows i count) := by
  induction count with
  | zero =>
    intro i lo endAt
    have same : i = last := by omega
    subst i
    have guards := (trace last span.bounded).1
    rw [ready_interior rows ops primary first last span last lo (by omega)] at guards
    have code := opcodes values events rows ops schedule first last span last (by omega) (by omega)
    rw [code] at guards
    have ends := guards.finish active span.endKind
    exact ParametricBodyRun.Run.done ends.1 ends.2
  | succ count ih =>
    intro i lo endAt
    have hi : i < last := by omega
    have ib : i < rows.length := by have := span.bounded; omega
    have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
    have prepared := ready_interior rows ops primary first last span i lo (by omega)
    obtain ⟨counts,types⟩ := trace i ib
    rw [prepared,code] at counts types
    have step : ParametricTraceSound.state rows ops primary (i+1) =
        advance (ParametricTraceSound.state rows ops primary i) (rows.getD i default).kind (ops.getD first 0) (rows.getD i default).valueType := by
      change advance (ParametricTraceSound.ready rows ops primary i) _ _ _ = _
      rw [prepared,code]
    have next := ih (i+1) (by omega) (by omega)
    rw [step] at next
    rcases kinds values events rows ops schedule primary trace first last span active i lo hi with pop | push
    · rw [pop,ParametricBodyRun.advance_pop _ _ _ active] at next
      rw [pop] at counts types
      simpa only [tokens,token,pop,List.singleton_append] using ParametricBodyRun.Run.pop counts types next
    · rw [push,ParametricBodyRun.advance_push _ _ _ active] at next
      rw [push] at counts types
      simpa only [tokens,token,push,List.singleton_append] using ParametricBodyRun.Run.push counts types next

theorem body_sound {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (primary : Nat → Fin (2^32)) (trace : ParametricSemanticSound.Trace rows ops primary)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ParametricMode.active (ops.getD first 0) = true)
    (valid : ParametricBegin.Valid (ops.getD first 0) (primary first).val) :
    ParametricEvents.check (ops.getD first 0) (primary first).val ((body rows first last).map ParametricBodyRun.action) = true := by
  have walk := segment values events rows ops schedule primary trace first last span active (last-first-1) (first+1)
    (by omega) (by have := span.ordered; omega)
  have initial : ParametricTraceSound.state rows ops primary (first+1) = ParametricBodyRun.initial (primary first).val := by
    change advance (prepare _ (rows.getD first default).kind (primary first).val)
      (rows.getD first default).kind _ _ = _
    rw [span.beginKind]
    simp [prepare,advance,popping,pushing,firstPop,secondPop,ParametricBodyRun.initial]
  rw [initial] at walk
  exact ParametricBodyRun.checked _ _ active valid _ walk

theorem body_length {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (primary : Nat → Fin (2^32)) (trace : ParametricSemanticSound.Trace rows ops primary)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : ParametricMode.active (ops.getD first 0) = true) :
    (body rows first last).length = last-first-1 := by
  apply tokens_length
  intro i lo hi
  rcases kinds values events rows ops schedule primary trace first last span active i (by omega) (by omega) with pop | push
  all_goals simp only [token, *, List.length_singleton]

#print axioms segment
#print axioms body_sound
#print axioms body_length
end ZkBuild.ParametricInstructionBody
