import ControlMemory
import SignatureLists
import VariableTyping

namespace ZkBuild.SignatureFrames

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

structure Frame where
  descriptor : Nat
  kind : Fin 4
  deriving DecidableEq

def encode (frame : Frame) : Nat := 4*frame.descriptor+frame.kind.val

theorem encode_injective (a b : Frame) (same : encode a = encode b) : a = b := by
  have split := radix_injective 4 a.kind.val a.descriptor b.kind.val b.descriptor
    a.kind.isLt b.kind.isLt (by simpa [encode, Nat.add_comm] using same)
  cases a; cases b
  simp only [Frame.mk.injEq]
  exact ⟨split.2, Fin.ext split.1⟩

theorem encoded_bound (frame : Frame) (bound : frame.descriptor < 2^34) : encode frame < 2^36 := by
  have := frame.kind.isLt
  simp [encode]
  omega

theorem field_injective {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Frame) (ab : a.descriptor < 2^34) (bb : b.descriptor < 2^34)
    (same : (encode a : F) = (encode b : F)) : a = b := by
  apply encode_injective
  exact NumericEvents.nat_eq (F := F) _ _
    (by have := encoded_bound a ab; simp [NumericEvents.countBound]; omega)
    (by have := encoded_bound b bb; simp [NumericEvents.countBound]; omega) same

abbrev Memory := ControlMemory.Memory

def Matches : List Frame → Memory → Prop
  | [], _ => True
  | top :: rest, memory => memory rest.length = some (encode top) ∧ Matches rest memory

theorem matches_congr (frames : List Frame) (a b : Memory) (matched : Matches frames a)
    (same : ∀ slot, slot < frames.length → a slot = b slot) : Matches frames b := by
  induction frames with
  | nil => trivial
  | cons frame rest ih =>
    constructor
    · rw [← same rest.length (by simp)]; exact matched.1
    · exact ih matched.2 (by intro slot h; exact same slot (by simp; omega))

theorem push_preserves (frames : List Frame) (memory : Memory) (frame : Frame)
    (matched : Matches frames memory) :
    Matches (frame :: frames) (ControlMemory.store memory frames.length (encode frame)) := by
  constructor
  · simp [ControlMemory.store]
  · apply matches_congr frames memory _ matched
    intro slot below
    simp [ControlMemory.store, Nat.ne_of_lt below]

theorem pop_preserves (frames : List Frame) (memory : Memory) (top : Frame)
    (matched : Matches (top :: frames) memory) : Matches frames memory := matched.2

theorem target_value (frames : List Frame) (memory : Memory) (matched : Matches frames memory)
    (depth : Nat) (bound : depth < frames.length) :
    memory (frames.length-1-depth) = some (encode frames[depth]) := by
  induction frames generalizing depth with
  | nil => simp at bound
  | cons top rest ih =>
    cases depth with
    | zero => simpa using matched.1
    | succ depth =>
      have below : depth < rest.length := by simp at bound; omega
      have location : (top :: rest).length-1-(depth+1) = rest.length-1-depth := by simp; omega
      simpa [Nat.sub_sub, Nat.add_comm] using ih matched.2 depth below

theorem target_authenticated (frames : List Frame) (memory : Memory) (matched : Matches frames memory)
    (depth : Nat) (bound : depth < frames.length) (observed : Frame)
    (read : memory (frames.length-1-depth) = some (encode observed)) : observed = frames[depth] := by
  apply encode_injective
  exact Option.some.inj (read.symm.trans (target_value frames memory matched depth bound))

theorem ram_target_authenticated (frames : List Frame) (memory : Memory) (matched : Matches frames memory)
    (depth : Nat) (bound : depth < frames.length) (observed : Frame)
    (read : MemoryTrace.ReadOk memory ⟨true, false, frames.length-1-depth, encode observed, 0⟩) :
    observed = frames[depth] := target_authenticated frames memory matched depth bound observed (read rfl rfl)

theorem target_slot_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (count depth slot : Nat) (cb : count < 2^32) (db : depth < 2^32) (sb : slot < 2^32)
    (gate : (slot : F) = (count : F)-1-(depth : F)) :
    depth < count ∧ slot = count-1-depth := by
  have same : count = slot+depth+1 := NumericEvents.nat_eq (F := F) _ _
    (by simp [NumericEvents.countBound]; omega) (by simp [NumericEvents.countBound]; omega)
    (by simp only [Semiring.natCast_add, Semiring.natCast_one]; grind)
  omega

def root (functionIndex : Nat) : Frame := ⟨4*functionIndex+1, 0⟩
def singleton (tag : Fin 7) (kind : Fin 4) : Frame := ⟨4*tag.val+3, kind⟩
def empty (kind : Fin 4) : Frame := ⟨2, kind⟩
def typed (typeIndex : Nat) (kind : Fin 4) : Frame := ⟨4*typeIndex, kind⟩

theorem root_encoding (functionIndex : Nat) : encode (root functionIndex) = functionIndex*16+4 := by
  simp [root, encode]
  omega

theorem root_bound (functionIndex : Nat) (bound : functionIndex < 2^32) :
    (root functionIndex).descriptor < 2^34 := by simp [root]; omega

theorem else_preserves (frame : Frame) :
    ({frame with kind := 3} : Frame).descriptor = frame.descriptor := rfl

#print axioms encode_injective
#print axioms field_injective
#print axioms push_preserves
#print axioms target_authenticated
#print axioms ram_target_authenticated
#print axioms target_slot_sound
#print axioms root_encoding

end ZkBuild.SignatureFrames
