import ControlMemorySound
import ControlRefinement
set_option autoImplicit false
namespace ZkBuild.ControlRefinementBridge
open OperandEvents ControlEvents ControlMemory

-- An authenticated pair of frame-memory operations has the same observable
-- behavior as the abstract LIFO update. This is independent of field encoding.
def sameAccess (a : Access) (b : MemoryTrace.Entry) : Prop :=
  b.active = a.active ∧ b.write = a.write ∧ b.address = a.address ∧ b.value = a.value

theorem pair_step (frames : List Frame) (memory : Memory) (row : Row)
    (beforeHeight afterDepth : Nat) (read write : MemoryTrace.Entry)
    (matched : Matches frames (ControlRefinement.view (row.functionIndex*bound) memory))
    (reads : MemoryTrace.Reads memory [read,write])
    (readImage : sameAccess (readProject frames.length row) read)
    (writeImage : sameAccess (writeProject frames.length beforeHeight row) write)
    (step : Spec frames.length afterDepth row) :
    (frames = [] ∧ row.floor = 0 ∧ row.unreachable = false ∨
      ∃ top rest, frames = top::rest ∧ row.floor = top.floor ∧ row.unreachable = top.unreachable) ∧
    (ControlRefinement.nextFrames row.kind beforeHeight frames).length = afterDepth ∧
    Matches (ControlRefinement.nextFrames row.kind beforeHeight frames)
      (ControlRefinement.view (row.functionIndex*bound)
        (MemoryTrace.advance (MemoryTrace.advance memory read) write)) := by
  have readWrite : read.write = false := by
    have image := readImage.2.1
    unfold readProject at image
    split at image <;> exact image
  have readOnly : MemoryTrace.advance memory read = memory := by simp [MemoryTrace.advance,readWrite]
  have authentic : MemoryTrace.ReadOk memory (ControlRefinement.readEntry frames.length row) := by
    intro active _
    have a : read.active = true := readImage.1.trans active
    have value := reads.1 a readWrite
    simpa [readImage.2.2.1,readImage.2.2.2,ControlRefinement.readEntry] using value
  have writeEffect : MemoryTrace.advance memory write =
      ControlRefinement.applyWrite memory (writeProject frames.length beforeHeight row) := by
    funext address
    simp [MemoryTrace.advance,ControlRefinement.applyWrite,
      writeImage.1,writeImage.2.1,writeImage.2.2.1,writeImage.2.2.2]
    split <;> rfl
  have result := ControlRefinement.stack_step frames memory row beforeHeight afterDepth matched authentic step
  exact ⟨ControlRefinement.empty_or_authenticated frames memory row afterDepth matched authentic step,
    result.1,by rw [readOnly,writeEffect]; exact result.2⟩

#print axioms pair_step
end ZkBuild.ControlRefinementBridge
