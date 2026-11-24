import ControlRefinementBridge
import FunctionTraceSound
set_option autoImplicit false
namespace ZkBuild.ControlLifoTrace
open OperandEvents ControlEvents ControlMemory

abbrev previousDepth (ds : List Nat) (i : Nat) := if i = 0 then 0 else ds.getD (i-1) 0
abbrev previousHeight (rows : List Row) (i : Nat) := if i = 0 then 0 else (rows.getD (i-1) default).height

def frames (rows : List Row) : Nat → List Frame
  | 0 => []
  | i+1 => ControlRefinement.nextFrames (rows.getD i default).kind (previousHeight rows i) (frames rows i)

def memory (rows : List Row) (ds : List Nat) : Nat → Memory
  | 0 => fun _ => none
  | i+1 => MemoryTrace.advance
      (MemoryTrace.advance (memory rows ds i) (ControlMemorySound.rowAt rows ds (2*i)))
      (ControlMemorySound.rowAt rows ds (2*i+1))

def Context (frames : List Frame) (row : Row) : Prop :=
  (frames = [] ∧ row.floor = 0 ∧ row.unreachable = false) ∨
    ∃ top rest, frames = top::rest ∧ row.floor = top.floor ∧ row.unreachable = top.unreachable

theorem read_image (rows : List Row) (ds : List Nat) (i : Nat) :
    ControlRefinementBridge.sameAccess (readProject (previousDepth ds i) (rows.getD i default))
      (ControlMemorySound.rowAt rows ds (2*i)) := by
  simp [ControlRefinementBridge.sameAccess,ControlMemorySound.rowAt,ControlMemorySound.entry,previousDepth]

theorem write_image (rows : List Row) (ds : List Nat) (i : Nat) :
    ControlRefinementBridge.sameAccess (writeProject (previousDepth ds i) (previousHeight rows i) (rows.getD i default))
      (ControlMemorySound.rowAt rows ds (2*i+1)) := by
  have quotient : (2*i+1)/2 = i := by omega
  have remainder : (2*i+1)%2 ≠ 0 := by omega
  simp only [ControlMemorySound.rowAt,quotient,remainder,ite_false,ControlMemorySound.entry,
    ControlRefinementBridge.sameAccess,previousDepth,previousHeight]
  exact ⟨True.intro,True.intro,True.intro,True.intro⟩

theorem pair_suffix (rows : List Row) (ds : List Nat) (i : Nat) (ib : i < rows.length) :
    (ControlMemorySound.projected rows ds).drop (2*i) =
      ControlMemorySound.rowAt rows ds (2*i) :: ControlMemorySound.rowAt rows ds (2*i+1) ::
        (ControlMemorySound.projected rows ds).drop (2*(i+1)) := by
  let xs := ControlMemorySound.projected rows ds
  have left : 2*i < xs.length := by simp [xs,ControlMemorySound.projected]; omega
  have right : 2*i+1 < xs.length := by simp [xs,ControlMemorySound.projected]; omega
  rw [List.drop_eq_getElem_cons left,List.drop_eq_getElem_cons right]
  simp [xs,ControlMemorySound.projected,Nat.mul_add]

theorem namespace_step (opened : Bool) (index : Nat) (row : Row) (afterDepth : Nat)
    (fs : List Frame) (mem : Memory) (length : fs.length = afterDepth)
    (matched : Matches fs (ControlRefinement.view (row.functionIndex*bound) mem))
    (schedule : FunctionEvents.ScheduleOk opened row.kind)
    (same : row.kind ≠ .padding → row.functionIndex = index)
    (boundary : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding → afterDepth = 0) :
    Matches fs (ControlRefinement.view (FunctionEvents.nextIndex index row.kind*bound) mem) ∧
      (FunctionEvents.nextOpen opened row.kind = false → fs = []) := by
  have nil (b : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding) : fs = [] := by
    have zero := length.trans (boundary b)
    simpa using zero
  by_cases boundaryKind : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding
  · rw [nil boundaryKind]
    exact ⟨trivial,by simp⟩
  · have noBegin : row.kind ≠ .functionBegin := by intro h; exact boundaryKind (Or.inl h)
    have noEnd : row.kind ≠ .functionEnd := by intro h; exact boundaryKind (Or.inr (Or.inl h))
    have noPadding : row.kind ≠ .padding := by intro h; exact boundaryKind (Or.inr (Or.inr h))
    have fn := same noPadding
    have openedTrue : opened = true := by simpa only [FunctionEvents.ScheduleOk,noBegin,noPadding,or_false,ite_false] using schedule
    constructor
    · simpa only [FunctionEvents.nextIndex,noEnd,ite_false,Nat.add_zero,fn] using matched
    · cases k : row.kind <;> simp_all [FunctionEvents.nextOpen]

-- The invariant names the function scheduler's namespace. It can change only
-- when the abstract frame stack is empty, including the padding namespace.
def Invariant (rows : List Row) (ds : List Nat) (first i : Nat) : Prop :=
  (frames rows i).length = previousDepth ds i ∧
  Matches (frames rows i) (ControlRefinement.view ((FunctionTraceSound.state rows first i).index*bound) (memory rows ds i)) ∧
  ((FunctionTraceSound.state rows first i).opened = false → frames rows i = []) ∧
  MemoryTrace.Reads (memory rows ds i) ((ControlMemorySound.projected rows ds).drop (2*i))

theorem invariant (rows : List Row) (ds : List Nat) (first : Nat)
    (steps : ∀ i, i < rows.length → Spec (previousDepth ds i) (ds.getD i 0) (rows.getD i default))
    (schedule : ∀ i, i < rows.length →
      FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (FunctionTraceSound.state rows first i).index))
    (reads : MemoryTrace.Reads (fun _ => none) (ControlMemorySound.projected rows ds)) :
    ∀ i, i ≤ rows.length → Invariant rows ds first i := by
  intro i iBound
  induction i with
  | zero => exact ⟨rfl,trivial,by simp [frames],by simpa [memory] using reads⟩
  | succ i ih =>
    have ib : i < rows.length := by omega
    obtain ⟨length,matched,closed,tail⟩ := ih (by omega)
    have sc := schedule i ib
    have sp := steps i ib
    have rowMatch : Matches (frames rows i)
        (ControlRefinement.view ((rows.getD i default).functionIndex*bound) (memory rows ds i)) := by
      by_cases padding : (rows.getD i default).kind = .padding
      · have unopened : (FunctionTraceSound.state rows first i).opened = false := by
          simpa only [FunctionEvents.ScheduleOk,padding,or_true,ite_true] using sc.1
        rw [closed unopened]
        trivial
      · rw [sc.2 padding]
        exact matched
    rw [pair_suffix rows ds i ib] at tail
    have pair : MemoryTrace.Reads (memory rows ds i)
        [ControlMemorySound.rowAt rows ds (2*i),ControlMemorySound.rowAt rows ds (2*i+1)] :=
      ⟨tail.1,tail.2.1,True.intro⟩
    have transition := ControlRefinementBridge.pair_step (frames rows i) (memory rows ds i) (rows.getD i default)
      (previousHeight rows i) (ds.getD i 0) _ _ rowMatch pair
      (by simpa [length] using read_image rows ds i) (by simpa [length] using write_image rows ds i)
      (by simpa [length] using sp)
    have nextLength : (frames rows (i+1)).length = ds.getD i 0 := transition.2.1
    have nextMatch : Matches (frames rows (i+1))
        (ControlRefinement.view ((rows.getD i default).functionIndex*bound) (memory rows ds (i+1))) := transition.2.2
    have ns := namespace_step (FunctionTraceSound.state rows first i).opened (FunctionTraceSound.state rows first i).index
      (rows.getD i default) _ (frames rows (i+1)) (memory rows ds (i+1)) nextLength nextMatch sc.1 sc.2 sp.2.2.2.2
    exact ⟨by simpa [previousDepth] using nextLength,ns.1,ns.2,tail.2.2⟩

theorem authenticated (rows : List Row) (ds : List Nat) (first : Nat)
    (steps : ∀ i, i < rows.length → Spec (previousDepth ds i) (ds.getD i 0) (rows.getD i default))
    (schedule : ∀ i, i < rows.length →
      FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (FunctionTraceSound.state rows first i).index))
    (reads : MemoryTrace.Reads (fun _ => none) (ControlMemorySound.projected rows ds)) :
    ∀ i, i < rows.length → Context (frames rows i) (rows.getD i default) := by
  intro i ib
  obtain ⟨length,matched,closed,tail⟩ := invariant rows ds first steps schedule reads i (by omega)
  have sc := schedule i ib
  have rowMatch : Matches (frames rows i)
      (ControlRefinement.view ((rows.getD i default).functionIndex*bound) (memory rows ds i)) := by
    by_cases padding : (rows.getD i default).kind = .padding
    · have unopened : (FunctionTraceSound.state rows first i).opened = false := by simpa only [FunctionEvents.ScheduleOk,padding,or_true,ite_true] using sc.1
      rw [closed unopened]; trivial
    · rw [sc.2 padding]; exact matched
  rw [pair_suffix rows ds i ib] at tail
  exact (ControlRefinementBridge.pair_step (frames rows i) (memory rows ds i) (rows.getD i default)
    (previousHeight rows i) (ds.getD i 0) _ _ rowMatch ⟨tail.1,tail.2.1,True.intro⟩
    (by simpa [length] using read_image rows ds i) (by simpa [length] using write_image rows ds i)
    (by simpa [length] using steps i ib)).1

#print axioms invariant
#print axioms authenticated
end ZkBuild.ControlLifoTrace
