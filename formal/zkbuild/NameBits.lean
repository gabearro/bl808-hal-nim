import NameGraphMatrix
set_option autoImplicit false
namespace ZkBuild.NameBits
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem packed_drop (bits : List Bool) (offset : Nat) (bound : offset ≤ bits.length) :
    BitPacking.packBits (bits.drop offset) = BitPacking.packBits bits / 2^offset := by
  have joined := PackedFields.packed_append (bits.take offset) (bits.drop offset)
  have length : (bits.take offset).length = offset := by simp [List.length_take,Nat.min_eq_left bound]
  have small : BitPacking.packBits (bits.take offset) < 2^offset := by simpa [length] using BitPacking.packed_bits_bounded (bits.take offset)
  rw [List.take_append_drop,length] at joined
  rw [joined,Nat.add_mul_div_left _ _ (Nat.two_pow_pos _),Nat.div_eq_of_lt small,Nat.zero_add]

theorem packed_take (bits : List Bool) (width : Nat) (bound : width ≤ bits.length) :
    BitPacking.packBits (bits.take width) = BitPacking.packBits bits % 2^width := by
  have joined := PackedFields.packed_append (bits.take width) (bits.drop width)
  have length : (bits.take width).length = width := by simp [List.length_take,Nat.min_eq_left bound]
  have small : BitPacking.packBits (bits.take width) < 2^width := by simpa [length] using BitPacking.packed_bits_bounded (bits.take width)
  rw [List.take_append_drop,length] at joined
  rw [joined]
  simp [Nat.add_mod,Nat.mod_eq_of_lt small]

theorem packed_image {F : Type} [Field F] (values : Nat → F)
    (bits : List Linear) (decoded : List Bool) (same : bits.map (E values) = decoded.map (R1CS.boolValue (F := F))) :
    E values (pack (BitPacking.bitWeights decoded.length) bits) = (BitPacking.packBits decoded : F) := by
  rw [eval_pack,same,R1CS.weighted_booleans,BitPacking.binary_weights_encode_bits]

theorem slices {F : Type} [Field F] (values : Nat → F) (range : RangeUse.Record) (word : Linear) (width : Nat)
    (certificate : RangeReuse.Certificate width (E values word) ((RangeUse.bits range).map (E values))) :
    ∃ n : Nat, n < 2^width ∧ E values word = (n : F) ∧
      ∀ offset count, offset+count ≤ width → E values (NameGraphMatrix.slice range offset count) = ((n/2^offset%2^count : Nat) : F) := by
  obtain ⟨decoded,same⟩ := R1CS.constrained_bits_are_booleans _ certificate.2.1
  have length : decoded.length = width := by
    have n := congrArg List.length same
    simpa only [List.length_map,certificate.1] using n.symm
  have whole : E values word = (BitPacking.packBits decoded : F) := by
    rw [← certificate.2.2,same,R1CS.weighted_booleans,← length,BitPacking.binary_weights_encode_bits]
  refine ⟨BitPacking.packBits decoded,by simpa [length] using BitPacking.packed_bits_bounded decoded,whole,?_⟩
  intro offset count bound
  have sliced : (((RangeUse.bits range).drop offset).take count).map (E values) =
      ((decoded.drop offset).take count).map (R1CS.boolValue (F := F)) := by
    simpa only [List.map_take,List.map_drop] using congrArg (fun xs => (xs.drop offset).take count) same
  have size : ((decoded.drop offset).take count).length = count := by simp [length]; omega
  have image := packed_image values _ _ sliced
  rw [size] at image
  change E values (pack _ _) = _
  rw [image,packed_take (decoded.drop offset) count (by simp [length]; omega),packed_drop decoded offset (by omega)]

#print axioms slices
end ZkBuild.NameBits
