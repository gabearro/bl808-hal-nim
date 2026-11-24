import BranchActionLayout
import OperandStackCertificate
set_option autoImplicit false
namespace ZkBuild.BranchFloorInvariant
open OperandEvents

def floors (rows : List Row) (i : Nat) := (ControlLifoTrace.frames rows i).map ControlMemory.Frame.floor

theorem context (frames : List ControlMemory.Frame) (row : Row)
    (valid : ControlLifoTrace.Context frames row) :
    row.floor=(frames.map ControlMemory.Frame.floor).getD 0 0 ∧
      row.unreachable=(frames.getD 0 ⟨0,false⟩).unreachable := by
  rcases valid with ⟨rfl,floor,unreachable⟩ | ⟨top,rest,rfl,floor,unreachable⟩
  · exact ⟨floor,unreachable⟩
  · simpa only [List.map_cons,List.getD_cons_zero] using And.intro floor unreachable

theorem step (rows : List Row) (i : Nat)
    (allowed : BranchActionAlphabet.Allowed (rows.getD i default).kind) : floors rows (i+1)=floors rows i := by
  rcases allowed with pop | push | label | clear
  · simp only [floors,ControlLifoTrace.frames,pop,ControlRefinement.nextFrames]
  · simp only [floors,ControlLifoTrace.frames,push,ControlRefinement.nextFrames]
  · simp only [floors,ControlLifoTrace.frames,label,ControlRefinement.nextFrames]
  · simp only [floors,ControlLifoTrace.frames,clear,ControlRefinement.nextFrames]
    cases ControlLifoTrace.frames rows i <;> rfl

theorem interval (rows : List Row) (start count : Nat)
    (allowed : ∀ i, start≤i → i<start+count → BranchActionAlphabet.Allowed (rows.getD i default).kind) :
    floors rows (start+count)=floors rows start := by
  induction count with
  | zero => rfl
  | succ count ih =>
    have prior := ih (by intro i lo hi; exact allowed i lo (by omega))
    rw [show start+(count+1)=start+count+1 from by omega,step rows (start+count) (allowed _ (by omega) (by omega))]
    exact prior

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∃ floor, (∀ i, first<i → i≤last → (rows.getD i default).floor=floor) ∧
      OperandStackTrace.stack rows last=(OperandStackTrace.stack rows (last-1)).take floor ∧
      (rows.getD last default).unreachable=true

theorem sound (rows : List Row) (ops ds : List Nat) (firstFunction : Nat)
    (trace : EventSemanticLifo.Trace rows ds firstFunction)
    (alphabet : BranchActionAlphabet.Complete rows ops)
    (sequences : BranchActionSequence.Complete rows ops) : Complete rows ops := by
  intro first last span active
  obtain ⟨arity,previous,_,plan⟩ := sequences first last span active
  have layout := BranchActionLayout.sound rows first last arity previous span.ordered plan
  have bounds := BranchConditionTrace.first rows first last arity previous span.ordered plan
  let floor := (rows.getD (first+1) default).floor
  have constant (i : Nat) (lo : first<i) (hi : i≤last) : (rows.getD i default).floor=floor := by
    have same := interval rows (first+1) (i-(first+1)) (by
      intro k lower upper
      exact alphabet first last span active k (by omega) (by omega))
    rw [show first+1+(i-(first+1))=i from by omega] at same
    have ci := (context _ _ (trace.2.2.2 i (by have := span.bounded; omega)).1).1
    have cf := (context _ _ (trace.2.2.2 (first+1) (by have := span.bounded; omega)).1).1
    exact ci.trans ((congrArg (fun xs : List Nat => xs.getD 0 0) same).trans cf.symm)
  refine ⟨floor,constant,?_,?_⟩
  · rw [show last=(last-1)+1 from by omega]
    simp only [OperandStackTrace.stack,OperandStackRefinement.next,layout.clear,Nat.add_sub_cancel]
    rw [constant (last-1) (by omega) (by omega)]
  · have sp := (trace.2.2.2 (last-1) (by have := span.bounded; omega)).2.2
    have positive := sp.2.1 (by simp only [ControlEvents.needsTop,layout.clear,reduceCtorEq,or_true,true_or,decide_true])
    have length := (trace.2.2.1 (last-1) (by have := span.bounded; omega)).1
    have nonempty : ControlLifoTrace.frames rows (last-1)≠[] := by
      intro empty
      rw [empty] at length
      simp only [List.length_nil] at length
      omega
    have ci := (context _ _ (trace.2.2.2 last span.bounded).1).2
    have after : ControlLifoTrace.frames rows last=
        ControlRefinement.nextFrames .clear (ControlLifoTrace.previousHeight rows (last-1)) (ControlLifoTrace.frames rows (last-1)) := by
      rw [show last=(last-1)+1 from by omega]
      change ControlRefinement.nextFrames _ _ _=_
      rw [layout.clear]
      simp only [Nat.add_sub_cancel]
    rw [after] at ci
    cases fs : ControlLifoTrace.frames rows (last-1) with
    | nil => exact False.elim (nonempty fs)
    | cons top rest => simpa only [fs,ControlRefinement.nextFrames,List.getD_cons_zero] using ci

#print axioms context
#print axioms interval
#print axioms sound
end ZkBuild.BranchFloorInvariant
