import MemoryTrace

/- Refinement from authenticated slot memory to a real LIFO control stack.
   Slot numbers are local to a function namespace. The function-schedule
   constraints keep that namespace fixed throughout a function body. -/
namespace ZkBuild.ControlMemory

structure Frame where
  floor : Nat
  unreachable : Bool
  deriving DecidableEq

def encode (frame : Frame) : Nat := 2*frame.floor+frame.unreachable.toNat

theorem encode_injective (a b : Frame) (same : encode a = encode b) : a = b := by
  obtain ⟨af, ar⟩ := a
  obtain ⟨bf, br⟩ := b
  cases ar <;> cases br <;> simp [encode, Bool.toNat] at same <;> congr <;> omega

abbrev Memory := Nat → Option Nat

def store (memory : Memory) (slot value : Nat) : Memory :=
  fun address => if address = slot then some value else memory address

-- The list is top-first. A frame above n other frames occupies slot n.
def Matches : List Frame → Memory → Prop
  | [], _ => True
  | frame :: rest, memory => memory rest.length = some (encode frame) ∧ Matches rest memory

theorem matches_congr (frames : List Frame) (a b : Memory) (matched : Matches frames a)
    (agree : ∀ slot, slot < frames.length → a slot = b slot) : Matches frames b := by
  induction frames with
  | nil => trivial
  | cons frame rest ih =>
    constructor
    · rw [← agree rest.length (by simp)]
      exact matched.1
    · exact ih matched.2 (by intro slot bound; exact agree slot (by simp; omega))

theorem push_preserves (frames : List Frame) (memory : Memory) (frame : Frame)
    (matched : Matches frames memory) :
    Matches (frame :: frames) (store memory frames.length (encode frame)) := by
  constructor
  · simp [store]
  · apply matches_congr frames memory _ matched
    intro slot below
    simp [store, Nat.ne_of_lt below]

theorem pop_preserves (frames : List Frame) (memory : Memory) (top : Frame)
    (matched : Matches (top :: frames) memory) : Matches frames memory := matched.2

theorem unreachable_preserves (frames : List Frame) (memory : Memory) (top : Frame)
    (matched : Matches (top :: frames) memory) :
    Matches ({ top with unreachable := true } :: frames)
      (store memory frames.length (2*top.floor+1)) := by
  exact push_preserves frames memory { top with unreachable := true } matched.2

theorem top_authenticated (frames : List Frame) (memory : Memory) (top observed : Frame)
    (matched : Matches (top :: frames) memory)
    (read : memory frames.length = some (encode observed)) : observed = top := by
  apply encode_injective
  exact Option.some.inj (read.symm.trans matched.1)

theorem ram_read_authenticates (frames : List Frame) (memory : Memory) (top observed : Frame)
    (matched : Matches (top :: frames) memory)
    (read : MemoryTrace.ReadOk memory
      ⟨true, false, frames.length, encode observed, 0⟩) :
    observed.floor = top.floor ∧ observed.unreachable = top.unreachable := by
  have equal := top_authenticated frames memory top observed matched (read rfl rfl)
  simp [equal]

#print axioms encode_injective
#print axioms push_preserves
#print axioms unreachable_preserves
#print axioms ram_read_authenticates

end ZkBuild.ControlMemory
