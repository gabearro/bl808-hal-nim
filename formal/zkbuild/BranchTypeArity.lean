import BranchTypeSemanticSound
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.BranchTypeArity
open OperandEvents BranchTypeState BranchTypeTrace

theorem chosen_equal (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) (i : Nat) (ib : i < rows.length)
    (previous : (state rows ops data i).length = (state rows ops data i).arity) :
    (BranchTypeTrace.chosen rows ops data i).length = (BranchTypeTrace.chosen rows ops data i).arity := by
  have initial : (BranchTypeTrace.ready rows ops data i).length = (BranchTypeTrace.ready rows ops data i).arity := by
    unfold BranchTypeTrace.ready prepare
    split
    · rfl
    · exact previous
  by_cases marked : mark (rows.getD i default).kind (ops.getD i 0) = true
  · have repeated := (guards i ib).repeated marked
    unfold BranchTypeTrace.chosen select
    simp only [marked,ite_true]
    cases sn : (BranchTypeTrace.ready rows ops data i).seen
    · simp only [sn,Bool.false_eq_true,ite_false]
    · simp only [sn,ite_true]
      exact (repeated sn).2.2
  · simpa only [BranchTypeTrace.chosen,select,marked,Bool.false_eq_true,ite_false] using initial

theorem invariant (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) :
    ∀ i, i ≤ rows.length → (state rows ops data i).length = (state rows ops data i).arity := by
  intro i ib
  induction i with
  | zero => rfl
  | succ i ih => exact chosen_equal rows ops data guards i (by omega) (ih (by omega))

theorem persistent (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat)
    (noReset : BranchTypePending.reset (rows.getD i default).kind = false)
    (seen : (state rows ops data i).seen = true) :
    (state rows ops data (i+1)).seen = true ∧ (state rows ops data (i+1)).arity = (state rows ops data i).arity := by
  simp only [state,advance,prepare,noReset,Bool.false_eq_true,ite_false]
  unfold select
  split <;> simp [seen]

theorem interval (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (start count : Nat)
    (noReset : ∀ i, start ≤ i → i < start+count → BranchTypePending.reset (rows.getD i default).kind = false)
    (seen : (state rows ops data start).seen = true) :
    (state rows ops data (start+count)).seen = true ∧
      (state rows ops data (start+count)).arity = (state rows ops data start).arity := by
  induction count with
  | zero => simp only [Nat.add_zero,and_true]; exact seen
  | succ count ih =>
    have prior := ih (by intro i lo hi; exact noReset i lo (by omega))
    have next := persistent rows ops data (start+count) (noReset (start+count) (by omega) (by omega)) prior.1
    exact ⟨next.1,next.2.trans prior.2⟩

theorem marked (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) (i : Nat) (ib : i < rows.length)
    (label : mark (rows.getD i default).kind (ops.getD i 0) = true) :
    (state rows ops data (i+1)).seen = true ∧ (state rows ops data (i+1)).arity = (data i).size.val := by
  have same := invariant rows ops data guards (i+1) (by omega)
  have next : (state rows ops data (i+1)).length = (data i).size.val := by
    simp only [state,advance,select,label,ite_true]
  refine ⟨?_,same.symm.trans next⟩
  simp only [state,advance,select,label,ite_true]

-- Any two target markers in the same instruction have exactly the same
-- authenticated arity, including empty target signatures.
theorem targets_equal (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (guards : BranchTypeSemanticSound.Guards rows ops data) (first last : Nat)
    (span : InstructionSpans.Span rows first last) (a b : Nat)
    (af : first < a) (al : a < last) (bf : first < b) (bl : b < last)
    (am : mark (rows.getD a default).kind (ops.getD a 0) = true)
    (bm : mark (rows.getD b default).kind (ops.getD b 0) = true) : (data a).size = (data b).size := by
  have ordered (a b : Nat) (af : first < a) (ab : a < b) (bl : b < last)
      (am : mark (rows.getD a default).kind (ops.getD a 0) = true)
      (bm : mark (rows.getD b default).kind (ops.getD b 0) = true) : (data a).size.val = (data b).size.val := by
    have initial := marked rows ops data guards a (by have := span.bounded; omega) am
    have later := marked rows ops data guards b (by have := span.bounded; omega) bm
    have distance := interval rows ops data (a+1) (b-a) (by
      intro i lo hi
      have middle := InstructionSpanState.interior rows first last span i (by omega) (by omega)
      simp only [BranchTypePending.reset,middle.1,middle.2.1,or_self,decide_false]) initial.1
    have index : a+1+(b-a) = b+1 := by omega
    rw [index] at distance
    exact initial.2.symm.trans (distance.2.symm.trans later.2)
  apply Fin.ext
  rcases Nat.lt_trichotomy a b with h | h | h
  · exact ordered a b af h bl am bm
  · simp only [h]
  · exact (ordered b a bf h al bm am).symm

#print axioms invariant
#print axioms persistent
#print axioms interval
#print axioms targets_equal
end ZkBuild.BranchTypeArity
