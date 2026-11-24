import ControlDepthTrace
set_option autoImplicit false
namespace ZkBuild.FrameTokenStack
open OperandEvents MemoryTrace

def Matches : List Nat → Memory → Prop
  | [], _ => True
  | top::rest, memory => memory rest.length = some top ∧ Matches rest memory

def next (kind : Kind) (token : Nat) (frames : List Nat) : List Nat :=
  match kind with
  | .controlPush => token::frames
  | .controlPop => frames.tail
  | _ => frames

def entry (entries : List Entry) (i : Nat) := entries.getD i MemoryPriorWrite.zero

def frames (rows : List Row) (entries : List Entry) : Nat → List Nat
  | 0 => []
  | i+1 => next (rows.getD i default).kind (entry entries (2*i+1)).value (frames rows entries i)

def memory (entries : List Entry) : Nat → Memory
  | 0 => fun _ => none
  | i+1 => advance (advance (memory entries i) (entry entries (2*i))) (entry entries (2*i+1))

def Projection (rows : List Row) (entries : List Entry) : Prop :=
  ∀ i, i < rows.length →
    (entry entries (2*i)).write = false ∧
    (entry entries (2*i+1)).active = decide ((rows.getD i default).kind = .controlPush) ∧
    (entry entries (2*i+1)).write = decide ((rows.getD i default).kind = .controlPush) ∧
    ((rows.getD i default).kind = .controlPush →
      (entry entries (2*i+1)).address = (rows.getD i default).functionIndex*bound+ControlDepthTrace.depth rows i)

theorem congruent (fs : List Nat) (a b : Memory) (matched : Matches fs a)
    (same : ∀ slot, slot < fs.length → a slot = b slot) : Matches fs b := by
  induction fs with
  | nil => trivial
  | cons top rest ih =>
    exact ⟨(same rest.length (by simp)).symm.trans matched.1,
      ih matched.2 (fun slot sb => same slot (by simp; omega))⟩

theorem pushed (fs : List Nat) (m : Memory) (token : Nat) (matched : Matches fs m) :
    Matches (token::fs) (ControlMemory.store m fs.length token) := by
  constructor
  · simp [ControlMemory.store]
  · exact congruent fs m _ matched (by intro slot sb; simp [ControlMemory.store,Nat.ne_of_lt sb])

theorem pair_step (fs : List Nat) (m : Memory) (row : Row) (after : Nat) (read write : Entry)
    (matched : Matches fs (ControlRefinement.view (row.functionIndex*bound) m))
    (spec : ControlEvents.Spec fs.length after row)
    (readOnly : read.write = false)
    (wa : write.active = decide (row.kind = .controlPush))
    (ww : write.write = decide (row.kind = .controlPush))
    (addr : row.kind = .controlPush → write.address = row.functionIndex*bound+fs.length) :
    (next row.kind write.value fs).length = after ∧
    Matches (next row.kind write.value fs)
      (ControlRefinement.view (row.functionIndex*bound) (advance (advance m read) write)) := by
  have readEffect : advance m read = m := by simp [advance,readOnly]
  rw [readEffect]
  have depth := spec.2.2.1
  cases k : row.kind <;> simp only [k] at depth
  case controlPush =>
    refine ⟨by simp [next]; omega,?_⟩
    have effect : advance m write = ControlMemory.store m (row.functionIndex*bound+fs.length) write.value := by
      funext address
      simp only [advance,wa,ww,k,decide_true,Bool.true_and,ite_true,addr k,ControlMemory.store]
    rw [effect,ControlRefinement.view_store]
    exact pushed fs _ _ matched
  case controlPop =>
    have positive := spec.2.1 (by simp [ControlEvents.needsTop,k])
    cases fs with
    | nil => simp at positive
    | cons top rest =>
      refine ⟨by simp [next]; simp at depth; omega,?_⟩
      simpa [next,advance,wa,ww,k] using matched.2
  all_goals
    refine ⟨by simpa [next] using depth.symm,?_⟩
    simpa [next,advance,wa,ww,k] using matched

theorem namespace_step (opened : Bool) (index : Nat) (row : Row) (after : Nat)
    (fs : List Nat) (m : Memory) (length : fs.length=after)
    (matched : Matches fs (ControlRefinement.view (row.functionIndex*bound) m))
    (schedule : FunctionEvents.ScheduleOk opened row.kind)
    (same : row.kind ≠ .padding → row.functionIndex=index)
    (boundary : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding → after=0) :
    Matches fs (ControlRefinement.view (FunctionEvents.nextIndex index row.kind*bound) m) ∧
      (FunctionEvents.nextOpen opened row.kind=false → fs=[]) := by
  have nil (h : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding) : fs=[] := by
    have zero := length.trans (boundary h)
    simpa using zero
  by_cases bk : row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding
  · rw [nil bk]
    exact ⟨trivial,by simp⟩
  · have nb : row.kind ≠ .functionBegin := by intro h; exact bk (Or.inl h)
    have ne : row.kind ≠ .functionEnd := by intro h; exact bk (Or.inr (Or.inl h))
    have np : row.kind ≠ .padding := by intro h; exact bk (Or.inr (Or.inr h))
    have openedTrue : opened=true := by simpa only [FunctionEvents.ScheduleOk,nb,np,or_false,ite_false] using schedule
    constructor
    · simpa only [FunctionEvents.nextIndex,ne,ite_false,Nat.add_zero,same np] using matched
    · cases k : row.kind <;> simp_all [FunctionEvents.nextOpen]

def Invariant (rows : List Row) (entries : List Entry) (first i : Nat) : Prop :=
  (frames rows entries i).length = ControlDepthTrace.depth rows i ∧
  Matches (frames rows entries i) (ControlRefinement.view ((FunctionTraceSound.state rows first i).index*bound) (memory entries i)) ∧
  ((FunctionTraceSound.state rows first i).opened=false → frames rows entries i=[]) ∧
  Reads (memory entries i) (entries.drop (2*i))

theorem pair_suffix (entries : List Entry) (count i : Nat) (size : entries.length=2*count) (ib : i<count) :
    entries.drop (2*i) = entry entries (2*i)::entry entries (2*i+1)::entries.drop (2*(i+1)) := by
  have left : 2*i<entries.length := by omega
  have right : 2*i+1<entries.length := by omega
  rw [List.drop_eq_getElem_cons left,List.drop_eq_getElem_cons right]
  simp only [entry,← List.getElem_eq_getD (h:=left) MemoryPriorWrite.zero,← List.getElem_eq_getD (h:=right) MemoryPriorWrite.zero]
  congr 2

theorem invariant (rows : List Row) (entries : List Entry) (first : Nat)
    (size : entries.length=2*rows.length) (projection : Projection rows entries)
    (steps : ∀ i, i<rows.length → ControlEvents.Spec (ControlDepthTrace.depth rows i) (ControlDepthTrace.depth rows (i+1)) (rows.getD i default))
    (schedule : ∀ i, i<rows.length →
      FunctionEvents.ScheduleOk (FunctionTraceSound.state rows first i).opened (rows.getD i default).kind ∧
      ((rows.getD i default).kind≠.padding → (rows.getD i default).functionIndex=(FunctionTraceSound.state rows first i).index))
    (reads : Reads (fun _ => none) entries) :
    ∀ i, i≤rows.length → Invariant rows entries first i := by
  intro i ib
  induction i with
  | zero => exact ⟨rfl,trivial,by simp [frames],by simpa [memory] using reads⟩
  | succ i ih =>
    have inside : i<rows.length := by omega
    obtain ⟨length,matched,closed,tail⟩ := ih (by omega)
    have sc := schedule i inside
    have sp := steps i inside
    have image := projection i inside
    have rowMatch : Matches (frames rows entries i)
        (ControlRefinement.view ((rows.getD i default).functionIndex*bound) (memory entries i)) := by
      by_cases padding : (rows.getD i default).kind=.padding
      · have unopened : (FunctionTraceSound.state rows first i).opened=false := by
          simpa only [FunctionEvents.ScheduleOk,padding,or_true,ite_true] using sc.1
        rw [closed unopened]; trivial
      · rw [sc.2 padding]; exact matched
    rw [pair_suffix entries rows.length i size inside] at tail
    have transition := pair_step (frames rows entries i) (memory entries i) (rows.getD i default)
      (ControlDepthTrace.depth rows (i+1)) _ _ rowMatch (by simpa only [length] using sp)
      image.1 image.2.1 image.2.2.1 (by simpa only [length] using image.2.2.2)
    have ns := namespace_step (FunctionTraceSound.state rows first i).opened (FunctionTraceSound.state rows first i).index
      (rows.getD i default) _ _ _ transition.1 transition.2 sc.1 sc.2 sp.2.2.2.2
    exact ⟨transition.1,ns.1,ns.2,tail.2.2⟩

theorem target_value (fs : List Nat) (m : Memory) (matched : Matches fs m) (depth : Nat) (db : depth<fs.length) :
    m (fs.length-1-depth)=some fs[depth] := by
  induction fs generalizing depth with
  | nil => simp at db
  | cons top rest ih =>
    cases depth with
    | zero => simpa using matched.1
    | succ depth =>
      have below : depth<rest.length := by simp at db; omega
      simpa [Nat.sub_sub,Nat.add_comm] using ih matched.2 depth below

#print axioms pair_step
#print axioms namespace_step
#print axioms invariant
#print axioms target_value
end ZkBuild.FrameTokenStack
