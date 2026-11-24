import InstructionSource
import ControlMemory

namespace ZkBuild.SourceControl

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

structure Frame where
  pc : Fin (2^32)
  conditional : Bool
  seenElse : Bool
  deriving DecidableEq

def encode (frame : Frame) : Nat :=
  frame.pc.val+2^32*(frame.conditional.toNat+2*frame.seenElse.toNat)

theorem encode_injective (a b : Frame) (same : encode a = encode b) : a = b := by
  have parts := radix_injective (2^32) a.pc.val (a.conditional.toNat+2*a.seenElse.toNat)
    b.pc.val (b.conditional.toNat+2*b.seenElse.toNat) a.pc.isLt b.pc.isLt same
  have flags : a.conditional = b.conditional ∧ a.seenElse = b.seenElse := by
    rcases a with ⟨pa, ca, sa⟩
    rcases b with ⟨pb, cb, sb⟩
    cases ca <;> cases sa <;> cases cb <;> cases sb <;> simp_all
  cases a; cases b
  simp only [Frame.mk.injEq]
  exact ⟨Fin.ext parts.1, flags.1, flags.2⟩

abbrev Memory := ControlMemory.Memory

def Matches : List Frame → Memory → Prop
  | [], _ => True
  | top :: rest, memory => memory rest.length = some (encode top) ∧ Matches rest memory

theorem matches_congr (frames : List Frame) (a b : Memory) (matched : Matches frames a)
    (same : ∀ index, index < frames.length → a index = b index) : Matches frames b := by
  induction frames with
  | nil => trivial
  | cons frame rest ih =>
    constructor
    · rw [← same rest.length (by simp)]; exact matched.1
    · exact ih matched.2 (by intro i h; exact same i (by simp; omega))

theorem push_preserves (frames : List Frame) (memory : Memory) (frame : Frame)
    (matched : Matches frames memory) :
    Matches (frame :: frames) (ControlMemory.store memory frames.length (encode frame)) := by
  constructor
  · simp [ControlMemory.store]
  · apply matches_congr frames memory _ matched
    intro index below
    simp [ControlMemory.store, Nat.ne_of_lt below]

theorem read_top (frame observed : Frame) (rest : List Frame) (memory : Memory)
    (matched : Matches (frame :: rest) memory)
    (read : memory rest.length = some (encode observed)) : observed = frame := by
  apply encode_injective
  exact Option.some.inj (read.symm.trans matched.1)

theorem mark_else (frame : Frame) (unseen : frame.seenElse = false) :
    encode { frame with seenElse := true } = encode frame+2^33 := by
  simp [encode, unseen]
  omega

theorem replace_top (frame replacement : Frame) (rest : List Frame) (memory : Memory)
    (matched : Matches (frame :: rest) memory) :
    Matches (replacement :: rest) (ControlMemory.store memory rest.length (encode replacement)) := by
  constructor
  · simp [ControlMemory.store]
  · apply matches_congr rest memory _ matched.2
    intro index below
    simp [ControlMemory.store, Nat.ne_of_lt below]

theorem pop_preserves (frame : Frame) (rest : List Frame) (memory : Memory)
    (matched : Matches (frame :: rest) memory) : Matches rest memory := matched.2

#print axioms encode_injective
#print axioms push_preserves
#print axioms read_top
#print axioms mark_else
#print axioms replace_top
#print axioms pop_preserves

end ZkBuild.SourceControl
