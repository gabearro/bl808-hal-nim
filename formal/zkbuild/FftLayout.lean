import FftStages

namespace ZkBuild.FftLayout

open Lean.Grind FftStages

abbrev Coordinates (blocks half : Nat) := (Fin blocks × Fin half) × Bool

def linearIndex {blocks half : Nat} (c : Coordinates blocks half) : Nat :=
  c.1.1.val * (2*half) + c.1.2.val + if c.2 then 0 else half

def pack {blocks half : Nat} (c : Coordinates blocks half) : Fin (blocks*(2*half)) :=
  ⟨linearIndex c, by
    have block := c.1.1.isLt
    have offset := c.1.2.isLt
    have bound := Nat.mul_le_mul_right (2*half) (Nat.succ_le_of_lt block)
    have high : c.1.1.val*(2*half)+2*half ≤ blocks*(2*half) := by simpa [Nat.succ_mul] using bound
    unfold linearIndex
    cases c.2 <;> simp <;> omega⟩

def unpack {blocks half : Nat} (positive : 0 < half) (i : Fin (blocks*(2*half))) : Coordinates blocks half :=
  ((⟨i.val/(2*half), (Nat.div_lt_iff_lt_mul (by omega)).mpr i.isLt⟩,
    ⟨(i.val%(2*half))%half, Nat.mod_lt _ positive⟩), decide (i.val%(2*half) < half))

theorem unpack_pack {blocks half : Nat} (positive : 0 < half) (c : Coordinates blocks half) :
    unpack positive (pack c) = c := by
  let remainder := c.1.2.val + if c.2 then 0 else half
  have remainderBound : remainder < 2*half := by
    have bound := c.1.2.isLt
    dsimp [remainder]
    cases c.2 <;> simp <;> omega
  have divEq : (linearIndex c)/(2*half) = c.1.1.val := by
    simp only [linearIndex, Nat.add_assoc]
    change (c.1.1.val * (2*half) + remainder)/(2*half) = c.1.1.val
    rw [Nat.add_comm, Nat.add_mul_div_right _ _ (by omega), Nat.div_eq_of_lt remainderBound]
    simp
  have modEq : (linearIndex c)%(2*half) = remainder := by
    simp only [linearIndex, Nat.add_assoc]
    change (c.1.1.val * (2*half) + remainder)%(2*half) = remainder
    rw [Nat.mul_add_mod_self_right, Nat.mod_eq_of_lt remainderBound]
  have offsetEq : remainder%half = c.1.2.val := by
    have bound := c.1.2.isLt
    dsimp [remainder]
    cases c.2 <;> simp [Nat.mod_eq_of_lt bound]
  have sideEq : decide (remainder < half) = c.2 := by
    have bound := c.1.2.isLt
    have general (side : Bool) : decide ((c.1.2.val + if side then 0 else half) < half) = side := by
      cases side <;> simp <;> omega
    exact general c.2
  apply Prod.ext
  · apply Prod.ext <;> apply Fin.ext
    · exact divEq
    · change (linearIndex c % (2*half))%half = c.1.2.val
      rw [modEq, offsetEq]
  · change decide (linearIndex c % (2*half) < half) = c.2
    rw [modEq]
    exact sideEq

theorem pack_unpack {blocks half : Nat} (positive : 0 < half) (i : Fin (blocks*(2*half))) :
    pack (unpack positive i) = i := by
  apply Fin.ext
  have bound : i.val%(2*half) < 2*half := Nat.mod_lt _ (by omega)
  have split := Nat.div_add_mod i.val (2*half)
  change (i.val/(2*half))*(2*half) + (i.val%(2*half))%half +
    (if decide (i.val%(2*half) < half) then 0 else half) = i.val
  by_cases left : i.val%(2*half) < half
  · rw [decide_eq_true left]
    change (i.val/(2*half))*(2*half) + (i.val%(2*half))%half + 0 = i.val
    rw [Nat.add_zero, Nat.mod_eq_of_lt left]
    simpa [Nat.mul_comm] using split
  · have after : half ≤ i.val%(2*half) := by omega
    have small : i.val%(2*half)-half < half := by omega
    rw [decide_eq_false left]
    change (i.val/(2*half))*(2*half) + (i.val%(2*half))%half + half = i.val
    rw [Nat.mod_eq_sub_mod after, Nat.mod_eq_of_lt small]
    have same : i.val%(2*half)-half+half = i.val%(2*half) := by omega
    rw [Nat.add_assoc, same]
    simpa [Nat.mul_comm] using split

def toggle {blocks half : Nat} (c : Coordinates blocks half) : Coordinates blocks half :=
  (c.1, !c.2)

def arrayPairing (blocks half : Nat) (positive : 0 < half) : Pairing (Fin (blocks*(2*half))) where
  partner := fun i => pack (toggle (unpack positive i))
  left := fun i => (unpack positive i).2
  involutive := by
    intro i
    simp only [unpack_pack, toggle, Bool.not_not]
    exact pack_unpack positive i
  opposite := by intro i; simp [unpack_pack, toggle]

def arrayStage {F : Type} [Field F] (blocks half : Nat) (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) : Stage (Fin (blocks*(2*half))) F where
  pairing := arrayPairing blocks half positive
  weight := fun i => root^(unpack positive i).1.2.val
  sameWeight := by intro i; simp [arrayPairing, unpack_pack, toggle]
  nonzero := fun i => powers_nonzero root nonzero _

theorem left_forward {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (block : Fin blocks) (offset : Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    forward (arrayStage blocks half positive root nonzero) a (pack ((block, offset), true)) =
      a (pack ((block, offset), true)) + root^offset.val * a (pack ((block, offset), false)) := by
  simp [forward, arrayStage, arrayPairing, unpack_pack, toggle]

theorem right_forward {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (block : Fin blocks) (offset : Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    forward (arrayStage blocks half positive root nonzero) a (pack ((block, offset), false)) =
      a (pack ((block, offset), true)) - root^offset.val * a (pack ((block, offset), false)) := by
  simp [forward, arrayStage, arrayPairing, unpack_pack, toggle]

theorem left_backward {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (block : Fin blocks) (offset : Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    backward (arrayStage blocks half positive root nonzero) a (pack ((block, offset), true)) =
      a (pack ((block, offset), true)) + a (pack ((block, offset), false)) := by
  simp [backward, arrayStage, arrayPairing, unpack_pack, toggle]

theorem right_backward {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (block : Fin blocks) (offset : Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    backward (arrayStage blocks half positive root nonzero) a (pack ((block, offset), false)) =
      (a (pack ((block, offset), true)) - a (pack ((block, offset), false))) * (root^offset.val)⁻¹ := by
  simp [backward, arrayStage, arrayPairing, unpack_pack, toggle]

def reverseIndex (bits : Nat) (i : Fin (2^bits)) : Fin (2^bits) :=
  (BitVec.ofFin i).reverse.toFin

theorem reverse_index_involutive (bits : Nat) (i : Fin (2^bits)) :
    reverseIndex bits (reverseIndex bits i) = i := by
  simp [reverseIndex, BitVec.reverse_reverse_eq]

theorem left_index {blocks half : Nat} (block : Fin blocks) (offset : Fin half) :
    (pack ((block, offset), true)).val = block.val*(2*half)+offset.val := by simp [pack, linearIndex]

theorem right_index {blocks half : Nat} (block : Fin blocks) (offset : Fin half) :
    (pack ((block, offset), false)).val = block.val*(2*half)+offset.val+half := by simp [pack, linearIndex]

#print axioms unpack_pack
#print axioms pack_unpack
#print axioms reverse_index_involutive

end ZkBuild.FftLayout
