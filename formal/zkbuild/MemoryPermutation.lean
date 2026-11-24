import MemoryPacking
import PermutationEmbedded
import ReadOnlyMemory

namespace ZkBuild.MemoryPermutation

open Lean.Grind CircuitShape FullMatrix GadgetShape MemoryTrace MemoryConstraints
attribute [local instance] Ring.intCast Semiring.natCast

theorem field_bounds (addressBits timeBits valueBits : Nat)
    (small : valueBits+2+timeBits+addressBits ≤ 248) :
    4*(2^addressBits*2^timeBits) < scalarModulus ∧
      2^addressBits < scalarModulus ∧ 2^valueBits < scalarModulus := by
  have sumBound := RangeConstraints.power_below_modulus (addressBits+timeBits+2) (by omega)
  have expanded : 2^(addressBits+timeBits+2) = 4*(2^addressBits*2^timeBits) := by
    simp [Nat.pow_add,Nat.mul_assoc,Nat.mul_comm]
  exact ⟨by simpa only [expanded] using sumBound,
    RangeConstraints.power_below_modulus addressBits (by omega),
    RangeConstraints.power_below_modulus valueBits (by omega)⟩

theorem chronological_order (rows : List Entry)
    (times : rows.map Entry.time = List.range rows.length) : PerCellOrder rows := by
  have increasing : (rows.map Entry.time).Pairwise (· < ·) := by
    rw [times]
    exact List.pairwise_lt_range
  have pairs : rows.Pairwise (fun a b => a.time < b.time) := by
    simpa only [List.pairwise_map] using increasing
  exact pairs.imp (by intro a b ordered _ _ _; exact ordered)

theorem checked_records {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (network : PermutationEmbedded.Record) (accepted : PermutationEmbedded.check matrix network = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (addressBits timeBits valueBits : Nat) (small : valueBits+2+timeBits+addressBits ≤ 248)
    (chronological sorted : List Entry)
    (chronoBounds : ∀ row ∈ chronological, Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (sortedBounds : ∀ row ∈ sorted, Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (inputImage : network.inputs.map (E values) = chronological.map
      (fun row => (MemoryPacking.encode addressBits timeBits valueBits row : F)))
    (outputImage : network.outputs.map (E values) = sorted.map
      (fun row => (MemoryPacking.encode addressBits timeBits valueBits row : F))) : chronological.Perm sorted := by
  have permuted := PermutationEmbedded.checked_permutation matrix network accepted values one satisfied
  rw [inputImage,outputImage] at permuted
  exact (MemoryPacking.records_perm addressBits timeBits valueBits small sorted chronological sortedBounds chronoBounds permuted).symm

theorem checked_reads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (network : PermutationEmbedded.Record) (accepted : PermutationEmbedded.check matrix network = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (addressBits timeBits valueBits : Nat) (small : valueBits+2+timeBits+addressBits ≤ 248)
    (chronological sorted : List Entry)
    (chronoBounds : ∀ row ∈ chronological, Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (sortedBounds : ∀ row ∈ sorted, Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (times : chronological.map Entry.time = List.range chronological.length)
    (inputImage : network.inputs.map (E values) = chronological.map
      (fun row => (MemoryPacking.encode addressBits timeBits valueBits row : F)))
    (outputImage : network.outputs.map (E values) = sorted.map
      (fun row => (MemoryPacking.encode addressBits timeBits valueBits row : F)))
    (rowGates : Gates (F := F) (2^addressBits) (2^timeBits) none sorted) :
    Reads (fun _ => none) chronological := by
  have bounds := field_bounds addressBits timeBits valueBits small
  have permutation := checked_records matrix network accepted values one satisfied addressBits timeBits valueBits small
    chronological sorted chronoBounds sortedBounds inputImage outputImage
  apply cells_implies_reads
  exact memory_sound (2^addressBits) (2^timeBits) (2^valueBits) chronological sorted permutation
    (chronological_order chronological times) sortedBounds bounds.1 bounds.2.1 bounds.2.2 rowGates

#print axioms checked_records
#print axioms checked_reads

end ZkBuild.MemoryPermutation
