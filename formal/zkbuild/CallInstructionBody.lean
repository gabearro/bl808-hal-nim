import CallReadTrace
import CallBodyRun
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.CallInstructionBody
open Lean.Grind OperandEvents InstructionSpanState CallState SignatureLists

def Trace (table : Table) (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs) : Prop :=
  ∀ i, i < rows.length →
    CallGuardSound.Spec (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0)
      (rows.getD i default).valueType (data i).tag ∧
    CallReadSound.Reads table (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i)

theorem ready_interior (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first < i) (hi : i ≤ last) :
    CallTraceSound.ready rows ops data i = CallTraceSound.state rows ops data i := by
  have kinds := interior rows first last span i lo hi
  simp only [CallTraceSound.ready,prepare,kinds.1,kinds.2.1,or_self,ite_false]

theorem kinds {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (table : Table) (data : Nat → CallTraceSound.Inputs) (trace : Trace table rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : CallMode.active (ops.getD first 0) = true)
    (i : Nat) (lo : first < i) (hi : i < last) :
    (rows.getD i default).kind = .pop ∨ (rows.getD i default).kind = .push ∨ (rows.getD i default).kind = .clear := by
  have middle := span.middle i lo hi
  have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
  have guards := (trace i (by have := span.bounded; omega)).1
  have controls := guards.noControl (by rw [code]; exact active)
  have label : (rows.getD i default).kind ≠ .labelCheck := by
    intro same
    have labels := schedule.labels i (by have := span.bounded; omega) same
    rw [code] at labels
    have mode := _root_.of_decide_eq_true active
    rcases labels with eq | eq <;> rw [eq] at mode <;> omega
  cases kind : (rows.getD i default).kind <;> simp_all [InstructionSpans.Middle]

theorem segment {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (table : Table) (data : Nat → CallTraceSound.Inputs) (trace : Trace table rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : CallMode.active (ops.getD first 0) = true)
    (count : Nat) : ∀ i, first < i → i+count = last → ∀ params results,
      Represents table (CallTraceSound.state rows ops data i).params.val params →
      Represents table (CallTraceSound.state rows ops data i).results.val results →
      CallBodyRun.Run params results (CallTraceSound.state rows ops data i).pending
        (CallTraceSound.state rows ops data i).cleared (CallMode.tail (ops.getD first 0)) (tokens rows i count) := by
  induction count with
  | zero =>
    intro i lo endAt params results pr rr
    have same : i = last := by omega
    subst i
    have guards := (trace last span.bounded).1
    rw [ready_interior rows ops data first last span last lo (by omega)] at guards
    have code := opcodes values events rows ops schedule first last span last (by omega) (by omega)
    rw [code] at guards
    have ends := guards.finish (by simp only [finishing,active,span.endKind,decide_true,Bool.and_self])
    have empty := represents_zero table params (by rw [← ends.1]; exact pr)
    subst params
    cases tailEq : CallMode.tail (ops.getD first 0) with
    | false =>
      have er := represents_zero table results (by rw [← ends.2.2.2 tailEq]; exact rr)
      subst results
      simpa only [tokens,ends.2.1,ends.2.2.1,tailEq] using CallBodyRun.Run.done
    | true => simpa only [tokens,ends.2.1,ends.2.2.1,tailEq] using CallBodyRun.Run.returned results
  | succ count ih =>
    intro i lo endAt params results pr rr
    have hi : i < last := by omega
    have ib : i < rows.length := by have := span.bounded; omega
    have code := opcodes values events rows ops schedule first last span i (by omega) (by omega)
    have prepared := ready_interior rows ops data first last span i lo (by omega)
    obtain ⟨guards,reads⟩ := trace i ib
    rw [prepared,code] at guards reads
    have step : CallTraceSound.state rows ops data (i+1) =
        advance (CallTraceSound.state rows ops data i) (rows.getD i default).kind (ops.getD first 0) (data i).next := by
      change advance (CallTraceSound.ready rows ops data i) _ _ _ = _
      rw [prepared,code]
    have next := ih (i+1) (by omega) (by omega)
    rw [step] at next
    rcases kinds values events rows ops schedule table data trace first last span active i lo hi with pop | push | clear
    · have enabled : popping (rows.getD i default).kind (ops.getD first 0) = true := by simp only [popping,pop,active,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false]
      have ordered := guards.popOrder enabled
      cases pending : (CallTraceSound.state rows ops data i).pending with
      | true =>
        have typed := guards.indexType enabled pending
        have remaining := next params results (by simpa only [advance,argument,popping,pushing,pop,active,pending,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using pr)
          (by simpa only [advance,pushing,pop,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using rr)
        have remaining' : CallBodyRun.Run params results false false (CallMode.tail (ops.getD first 0)) (tokens rows (i+1) count) := by
          simpa only [advance,popping,pushing,clearing,pop,active,pending,ordered.2,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using remaining
        simpa only [tokens,token,pop,List.singleton_append,pending,ordered.2] using CallBodyRun.Run.index typed remaining'
      | false =>
        have argumentOn : argument (CallTraceSound.state rows ops data i) (rows.getD i default).kind (ops.getD first 0) = true := by
          simp only [argument,popping,pop,active,pending,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false]
        obtain ⟨rest,same,rep⟩ := reads.1 argumentOn params pr
        subst params
        have typed : CallEvents.InputOk (data i).tag.val (rows.getD i default).valueType.val := by
          rcases guards.argumentType argumentOn with same | unknown
          · exact Or.inl (congrArg Fin.val same)
          · exact Or.inr unknown
        have remaining := next rest results (by simpa only [advance,argument,popping,pop,active,pending,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using rep)
          (by simpa only [advance,pushing,pop,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using rr)
        have remaining' : CallBodyRun.Run rest results false false (CallMode.tail (ops.getD first 0)) (tokens rows (i+1) count) := by
          simpa only [advance,popping,pushing,clearing,pop,active,pending,ordered.2,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using remaining
        simpa only [tokens,token,pop,List.singleton_append,pending,ordered.2] using CallBodyRun.Run.pop typed remaining'
    · have enabled : pushing (rows.getD i default).kind (ops.getD first 0) = true := by simp only [pushing,push,active,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false]
      obtain ⟨tailEq,pending,cleared,empty,typed⟩ := guards.push enabled
      have pe := represents_zero table params (by rw [← empty]; exact pr)
      subst params
      obtain ⟨rest,same,rep⟩ := reads.2 enabled results rr
      subst results
      have remaining := next [] rest (by simpa only [advance,argument,popping,push,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using pr)
        (by simpa only [advance,pushing,push,active,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using rep)
      have remaining' : CallBodyRun.Run [] rest false false false (tokens rows (i+1) count) := by
        simpa only [advance,popping,pushing,clearing,push,active,pending,cleared,tailEq,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using remaining
      simpa only [tokens,token,push,List.singleton_append,pending,cleared,tailEq,typed] using CallBodyRun.Run.push remaining'
    · have enabled : clearing (rows.getD i default).kind (ops.getD first 0) = true := by simp only [clearing,clear,active,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false]
      obtain ⟨tailEq,empty,pending,cleared⟩ := guards.clear enabled
      have pe := represents_zero table params (by rw [← empty]; exact pr)
      subst params
      have remaining := next [] results (by simpa only [advance,argument,popping,clear,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using pr)
        (by simpa only [advance,pushing,clear,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using rr)
      have remaining' : CallBodyRun.Run [] results false true true (tokens rows (i+1) count) := by
        simpa only [advance,popping,pushing,clearing,clear,active,pending,cleared,tailEq,reduceCtorEq,decide_true,decide_false,Bool.and_true,Bool.and_false,Bool.false_and,Bool.true_and,Bool.not_true,Bool.not_false,Bool.or_false,Bool.or_true,ite_true,ite_false] using remaining
      simpa only [tokens,token,clear,List.singleton_append,pending,cleared,tailEq] using CallBodyRun.Run.clear remaining'

theorem body_sound {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (table : Table) (data : Nat → CallTraceSound.Inputs) (trace : Trace table rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : CallMode.active (ops.getD first 0) = true)
    (params results : List Nat) (pr : Represents table (data first).params.val params) (rr : Represents table (data first).results.val results) :
    ∃ indexTokens rest, body rows first last = indexTokens ++ rest ∧
      (if CallMode.indirect (ops.getD first 0) then ∃ actual, CallEvents.InputOk 0 actual ∧ indexTokens = [StaticEvents.Token.pop actual]
       else indexTokens = []) ∧ CallEvents.Body params results (CallMode.tail (ops.getD first 0)) rest := by
  have walk := segment values events rows ops schedule table data trace first last span active (last-first-1) (first+1)
    (by omega) (by have := span.ordered; omega) params results
  simp only [CallTraceSound.state,prepare,advance,argument,popping,pushing,clearing,span.beginKind,reduceCtorEq,
    or_true,ite_true,ite_false,decide_false,Bool.and_false,Bool.or_false,Bool.not_false,Bool.and_true] at walk
  exact CallBodyRun.refinement params results _ _ _ (walk pr rr)

theorem body_length {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (table : Table) (data : Nat → CallTraceSound.Inputs) (trace : Trace table rows ops data)
    (first last : Nat) (span : InstructionSpans.Span rows first last) (active : CallMode.active (ops.getD first 0) = true) :
    (body rows first last).length = last-first-1 := by
  apply tokens_length
  intro i lo hi
  rcases kinds values events rows ops schedule table data trace first last span active i (by omega) (by omega) with pop | push | clear
  all_goals simp only [token, *, List.length_singleton]

#print axioms segment
#print axioms body_sound
#print axioms body_length
end ZkBuild.CallInstructionBody
