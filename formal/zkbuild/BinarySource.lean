import ReadOnlyMemory

namespace ZkBuild.BinarySource

open BitPacking Lean.Grind
attribute [local instance] Semiring.natCast

def byteDigits (bytes : List (Fin 256)) : List (Nat × Nat) :=
  bytes.map (fun value => (8, value.val))

theorem byte_digits_injective (a b : List (Fin 256)) (same : byteDigits a = byteDigits b) : a = b := by
  induction a generalizing b with
  | nil => cases b <;> simp_all [byteDigits]
  | cons head rest ih =>
    cases b with
    | nil => simp [byteDigits] at same
    | cons other tail =>
      have parts := List.cons.inj same
      have first : head = other := Fin.ext (congrArg Prod.snd parts.1)
      have last : rest = tail := ih tail parts.2
      simp [first, last]

theorem byte_digits_width (bytes : List (Fin 256)) :
    RangeConstraints.Width (byteDigits bytes) = 8*bytes.length := by
  induction bytes with
  | nil => rfl
  | cons head rest ih =>
    change 8 + RangeConstraints.Width (byteDigits rest) = 8*(rest.length+1)
    rw [ih]
    omega

theorem packed_source_limb_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Fin 256)) (lengths : a.length = b.length) (small : a.length ≤ 31)
    (same : (RangeConstraints.packDigits (byteDigits a) : F) =
      (RangeConstraints.packDigits (byteDigits b) : F)) : a = b := by
  have bounded (bytes : List (Fin 256)) : RangeConstraints.Bounded (byteDigits bytes) := by
    intro digit member
    obtain ⟨value, _, rfl⟩ := List.mem_map.mp member
    exact value.isLt
  apply byte_digits_injective
  apply RangeConstraints.packed_field_injective (F := F) _ _ (bounded a) (bounded b) _ _ same
  · simp [byteDigits, List.map_map, Function.comp_def, List.map_const', lengths]
  · rw [byte_digits_width]
    omega

def expandedBit (payload : Nat → Bool) (length : Nat) (sign : Bool) (bit : Nat) : Bool :=
  if bit < 7*length then payload bit else sign

def decodedBits (payload : Nat → Bool) (length width : Nat) (sign : Bool) : List Bool :=
  (List.range width).map (expandedBit payload length sign)

def BitRelation (payload value : Nat → Bool) (length width : Nat) (sign : Bool) : Prop :=
  ∀ bit, bit < width →
    (bit < 7*length → value bit = payload bit) ∧
    (7*length ≤ bit → value bit = sign)

theorem read_bits (payload value : Nat → Bool) (length width : Nat) (sign : Bool)
    (relation : BitRelation payload value length width sign) :
    (List.range width).map value = decodedBits payload length width sign := by
  apply List.map_congr_left
  intro bit member
  have bound := List.mem_range.mp member
  unfold expandedBit
  split
  next inside => exact (relation bit bound).1 inside
  next outside => exact (relation bit bound).2 (by omega)

theorem read_value (payload value : Nat → Bool) (length width : Nat) (sign : Bool)
    (relation : BitRelation payload value length width sign) :
    packBits ((List.range width).map value) = packBits (decodedBits payload length width sign) := by
  rw [read_bits payload value length width sign relation]

theorem same_bytes_same_read (payload a b : Nat → Bool) (length width : Nat) (sign : Bool)
    (left : BitRelation payload a length width sign)
    (right : BitRelation payload b length width sign) :
    packBits ((List.range width).map a) = packBits ((List.range width).map b) := by
  rw [read_bits payload a length width sign left, read_bits payload b length width sign right]

theorem nonminimal_extension (payload : Nat → Bool) (length width : Nat) (sign : Bool) :
    decodedBits (expandedBit payload length sign) (length+1) width sign =
      decodedBits payload length width sign := by
  apply List.map_congr_left
  intro bit _
  unfold expandedBit
  split <;> split <;> simp_all <;> omega

def Continuations (bytes : Nat → Bool) (length : Nat) : Prop :=
  0 < length ∧ ∀ i, i < length → bytes i = decide (i+1 < length)

theorem unique_termination (bytes : Nat → Bool) (a b : Nat)
    (left : Continuations bytes a) (right : Continuations bytes b) : a = b := by
  rcases left with ⟨ap, ah⟩
  rcases right with ⟨bp, bh⟩
  apply Classical.byContradiction
  intro different
  rcases Nat.lt_or_gt_of_ne different with small | large
  · have x := ah (a-1) (by omega)
    have y := bh (a-1) (by omega)
    have zero : ¬ a-1+1 < a := by omega
    have one : a-1+1 < b := by omega
    simp [zero, one] at x y
    simp [x] at y
  · have x := ah (b-1) (by omega)
    have y := bh (b-1) (by omega)
    have zero : ¬ b-1+1 < b := by omega
    have one : b-1+1 < a := by omega
    simp [zero, one] at x y
    simp [y] at x

#print axioms read_bits
#print axioms packed_source_limb_injective
#print axioms read_value
#print axioms same_bytes_same_read
#print axioms nonminimal_extension
#print axioms unique_termination

end ZkBuild.BinarySource
