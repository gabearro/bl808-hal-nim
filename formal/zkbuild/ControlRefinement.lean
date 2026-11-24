import ControlEvents
import ControlMemory

/- Composition of the control-row relation and ordinary RAM semantics.
   A read authenticates the actual LIFO frame; a derived write preserves the
   representation. FunctionEvents separately keeps the namespace fixed while
   the body is open and changes it only with an empty control stack. -/
namespace ZkBuild.ControlRefinement

open OperandEvents ControlEvents ControlMemory

def view (base : Nat) (memory : Memory) : Memory := fun slot => memory (base+slot)

theorem view_store (base slot value : Nat) (memory : Memory) :
    view base (store memory (base+slot) value) = store (view base memory) slot value := by
  funext address
  simp [view, store, Nat.add_left_cancel_iff]

def applyWrite (memory : Memory) (access : Access) : Memory :=
  if access.active && access.write then store memory access.address access.value else memory

def nextFrames (kind : Kind) (beforeHeight : Nat) (frames : List Frame) : List Frame :=
  match kind with
  | .controlPush => ⟨beforeHeight, false⟩ :: frames
  | .controlPop => frames.tail
  | .clear => match frames with
    | [] => []
    | top :: rest => { top with unreachable := true } :: rest
  | _ => frames

def readEntry (beforeDepth : Nat) (row : Row) : MemoryTrace.Entry :=
  let access := readProject beforeDepth row
  ⟨access.active, false, access.address, access.value, 0⟩

theorem top_from_projected_read (frames : List Frame) (top : Frame) (memory : Memory) (row : Row)
    (matched : Matches (top :: frames) (view (row.functionIndex*bound) memory))
    (read : MemoryTrace.ReadOk memory (readEntry (top :: frames).length row)) :
    row.floor = top.floor ∧ row.unreachable = top.unreachable := by
  have actual : view (row.functionIndex*bound) memory frames.length =
      some (encode ⟨row.floor, row.unreachable⟩) := by
    have observed := read (by simp [readEntry, readProject]) rfl
    simpa [readEntry, readProject, view, encode] using observed
  have same := top_authenticated frames (view (row.functionIndex*bound) memory)
    top ⟨row.floor, row.unreachable⟩ matched actual
  exact ⟨congrArg Frame.floor same, congrArg Frame.unreachable same⟩

theorem empty_or_authenticated (frames : List Frame) (memory : Memory) (row : Row) (afterDepth : Nat)
    (matched : Matches frames (view (row.functionIndex*bound) memory))
    (read : MemoryTrace.ReadOk memory (readEntry frames.length row))
    (step : Spec frames.length afterDepth row) :
    (frames = [] ∧ row.floor = 0 ∧ row.unreachable = false) ∨
    ∃ top rest, frames = top :: rest ∧ row.floor = top.floor ∧ row.unreachable = top.unreachable := by
  cases frames with
  | nil => exact .inl ⟨rfl, step.1 rfl⟩
  | cons top rest => exact .inr ⟨top, rest, rfl, top_from_projected_read rest top memory row matched read⟩

theorem stack_step (frames : List Frame) (memory : Memory) (row : Row) (beforeHeight afterDepth : Nat)
    (matched : Matches frames (view (row.functionIndex*bound) memory))
    (read : MemoryTrace.ReadOk memory (readEntry frames.length row))
    (step : Spec frames.length afterDepth row) :
    (nextFrames row.kind beforeHeight frames).length = afterDepth ∧
      Matches (nextFrames row.kind beforeHeight frames)
        (view (row.functionIndex*bound)
          (applyWrite memory (writeProject frames.length beforeHeight row))) := by
  have depth := step.2.2.1
  cases k : row.kind <;> simp [k] at depth
  case controlPush =>
    constructor
    · simp [nextFrames, k]; omega
    · simpa [nextFrames, applyWrite, writeProject, k, view_store, encode] using
        push_preserves frames (view (row.functionIndex*bound) memory) ⟨beforeHeight, false⟩ matched
  case controlPop =>
    have positive := step.2.1 (by simp [needsTop, k])
    cases frames with
    | nil => simp at positive
    | cons top rest =>
      constructor
      · simp [nextFrames, k]; simp at depth; omega
      · simpa [nextFrames, applyWrite, writeProject, k] using
          pop_preserves rest (view (row.functionIndex*bound) memory) top matched
  case clear =>
    have positive := step.2.1 (by simp [needsTop, k])
    cases frames with
    | nil => simp at positive
    | cons top rest =>
      have authenticated := top_from_projected_read rest top memory row matched read
      constructor
      · simp [nextFrames, k]; simp at depth; omega
      · simpa [nextFrames, applyWrite, writeProject, k, authenticated.1, view_store] using
          unreachable_preserves rest (view (row.functionIndex*bound) memory) top matched
  all_goals
    constructor
    · simp [nextFrames, k]; omega
    · simpa [nextFrames, applyWrite, writeProject, k] using matched

#print axioms empty_or_authenticated
#print axioms stack_step

end ZkBuild.ControlRefinement
