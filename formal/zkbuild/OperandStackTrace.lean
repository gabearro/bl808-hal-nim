import OperandStackRefinement
import EventSemanticLifo
set_option autoImplicit false
namespace ZkBuild.OperandStackTrace
open OperandEvents OperandStackRefinement

abbrev previousHeight := ControlLifoTrace.previousHeight

def stack (rows : List Row) : Nat → List (Fin 8)
  | 0 => []
  | i+1 => next (stack rows i) (rows.getD i default)
def memory (rows : List Row) : Nat → MemoryTrace.Memory
  | 0 => fun _ => none
  | i+1 => MemoryTrace.advance (memory rows i) (OperandMemorySound.entry (rows.getD i default) i)

theorem suffix (rows : List Row) (i : Nat) (ib : i < rows.length) :
    (OperandMemorySound.projected rows).drop i = OperandMemorySound.entry (rows.getD i default) i ::
      (OperandMemorySound.projected rows).drop (i+1) := by
  rw [List.drop_eq_getElem_cons (show i < (OperandMemorySound.projected rows).length by simp [OperandMemorySound.projected]; exact ib)]
  simp [OperandMemorySound.projected,List.getD,ib]

def Invariant (rows : List Row) (first i : Nat) : Prop :=
  (stack rows i).length = previousHeight rows i ∧
  Matches (stack rows i) ((FunctionTraceSound.state rows first i).index*bound) (memory rows i) ∧
  ((FunctionTraceSound.state rows first i).opened = false → stack rows i = []) ∧
  MemoryTrace.Reads (memory rows i) ((OperandMemorySound.projected rows).drop i)

theorem invariant (rows : List Row) (first : Nat)
    (steps : ∀ i, i < rows.length → StepSpec (previousHeight rows i) (rows.getD i default))
    (schedule : ∀ i, i < rows.length → FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (FunctionTraceSound.state rows first i).index))
    (boundaries : ∀ i, i < rows.length → (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .functionEnd → (rows.getD i default).height = 0)
    (reads : MemoryTrace.Reads (fun _ => none) (OperandMemorySound.projected rows)) :
    ∀ i, i ≤ rows.length → Invariant rows first i := by
  intro i ib
  induction i with
  | zero => exact ⟨rfl,by intro j jb; simp [stack] at jb,by simp [stack],by simpa [memory] using reads⟩
  | succ i ih =>
    have rb : i < rows.length := by omega
    obtain ⟨length,matched,closed,tail⟩ := ih (by omega)
    have sc := schedule i rb
    have rowMatch : Matches (stack rows i) ((rows.getD i default).functionIndex*bound) (memory rows i) := by
      by_cases pad : (rows.getD i default).kind = .padding
      · have unopened : (FunctionTraceSound.state rows first i).opened = false := by simpa only [FunctionEvents.ScheduleOk,pad,or_true,ite_true] using sc.1
        rw [closed unopened]
        intro j jb; simp at jb
      · rw [sc.2 pad]; exact matched
    rw [suffix rows i rb] at tail
    have transition := OperandStackRefinement.step (stack rows i) (memory rows i) (rows.getD i default) i rowMatch (by rw [length]; exact steps i rb) tail.1
    have nextLength : (stack rows (i+1)).length = (rows.getD i default).height := transition.2.1
    have nextMatches : Matches (stack rows (i+1)) ((rows.getD i default).functionIndex*bound) (memory rows (i+1)) := transition.2.2
    have boundaryNil (h : (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .functionEnd) : stack rows (i+1) = [] := by
      exact List.length_eq_zero_iff.mp (nextLength.trans (boundaries i rb h))
    refine ⟨by simpa only [previousHeight,ControlLifoTrace.previousHeight,Nat.add_one_ne_zero,ite_false,Nat.add_sub_cancel] using nextLength,?_,?_,tail.2⟩
    · by_cases finish : (rows.getD i default).kind = .functionEnd
      · rw [boundaryNil (Or.inr finish)]; intro j jb; simp at jb
      · by_cases pad : (rows.getD i default).kind = .padding
        · have unopened : (FunctionTraceSound.state rows first i).opened = false := by simpa only [FunctionEvents.ScheduleOk,pad,or_true,ite_true] using sc.1
          have nil : stack rows (i+1) = [] := by
            change next (stack rows i) (rows.getD i default) = []
            simp only [next,pad,closed unopened]
          rw [nil]; intro j jb; simp at jb
        · change Matches (stack rows (i+1)) (FunctionEvents.nextIndex (FunctionTraceSound.state rows first i).index (rows.getD i default).kind*bound) (memory rows (i+1))
          simpa only [FunctionEvents.nextIndex,finish,ite_false,Nat.add_zero,sc.2 pad] using nextMatches
    · intro afterClosed
      change FunctionEvents.nextOpen (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind = false at afterClosed
      by_cases finish : (rows.getD i default).kind = .functionEnd
      · exact boundaryNil (Or.inr finish)
      · by_cases start : (rows.getD i default).kind = .functionBegin
        · simp only [FunctionEvents.nextOpen,start,Bool.true_eq_false] at afterClosed
        · have priorClosed : (FunctionTraceSound.state rows first i).opened = false := by
            cases k : (rows.getD i default).kind <;> simp only [FunctionEvents.nextOpen,k] at afterClosed
            all_goals first | exact afterClosed | exact False.elim (start k) | exact False.elim (finish k)
          have pad : (rows.getD i default).kind = .padding := by
            have mode := sc.1
            simp only [FunctionEvents.ScheduleOk,start,false_or,priorClosed] at mode
            split at mode
            · assumption
            · contradiction
          change next (stack rows i) (rows.getD i default) = []
          simp only [next,pad,closed priorClosed]

theorem authenticated (rows : List Row) (first : Nat)
    (steps : ∀ i, i < rows.length → StepSpec (previousHeight rows i) (rows.getD i default))
    (schedule : ∀ i, i < rows.length → FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (FunctionTraceSound.state rows first i).index))
    (boundaries : ∀ i, i < rows.length → (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .functionEnd → (rows.getD i default).height = 0)
    (reads : MemoryTrace.Reads (fun _ => none) (OperandMemorySound.projected rows)) :
    ∀ i, i < rows.length → PopSpec (stack rows i) (rows.getD i default) := by
  intro i ib
  have inv := invariant rows first steps schedule boundaries reads i (by omega)
  intro pop
  have matchRow : Matches (stack rows i) ((rows.getD i default).functionIndex*bound) (memory rows i) := by
    rw [(schedule i ib).2 (by rw [pop]; decide)]; exact inv.2.1
  have tail := inv.2.2.2
  rw [suffix rows i ib] at tail
  exact (OperandStackRefinement.step (stack rows i) (memory rows i) (rows.getD i default) i matchRow (by rw [inv.1]; exact steps i ib) tail.1).1 pop

#print axioms invariant
#print axioms authenticated
end ZkBuild.OperandStackTrace
