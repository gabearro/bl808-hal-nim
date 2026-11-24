import SlotShape
import BitPacking

namespace ZkBuild.SlotSelection

open Lean.Grind R1CS
attribute [local instance] Semiring.natCast

def oneHot {F : Type} [CommRing F] (size index : Nat) : List F :=
  (List.range size).map fun i => if i = index then 1 else 0

theorem one_hot_list {F : Type} [Field F] [IsCharP F scalarModulus] (values : List F)
    (size : values.length ≤ 10) (bits : ∀ value ∈ values, value*(value-1) = 0)
    (total : sum values = 1) :
    ∃ index : Fin values.length, values = oneHot values.length index.val := by
  have countField : sum values = ((1 : Fin 2).val : F) := by
    simpa only [show (1 : Fin 2).val = 1 by rfl, Semiring.natCast_one] using total
  obtain ⟨decoded, same, count⟩ := selector_count_sound values (1 : Fin 2) size bits countField
  let codes := List.range values.length
  have length : codes.length = decoded.length := by
    have sameLength := congrArg List.length same
    simpa [codes] using sameLength
  have member := selectedCode_one codes decoded length count
  let index := selectedCode codes decoded
  have bound : index < values.length := by simpa [codes, index] using member
  have exactBits := one_selection_unique codes decoded index length
    (by simpa [codes] using (List.nodup_range : (List.range values.length).Nodup)) count rfl
  refine ⟨⟨index, bound⟩, ?_⟩
  change values = oneHot values.length index
  calc
    values = decoded.map boolValue := same
    _ = oneHot values.length index := by rw [exactBits]; simp [oneHot, codes, boolValue, List.map_map]

theorem one_hot_function {F : Type} [Field F] [IsCharP F scalarModulus] {n : Nat}
    (values : Fin n → F) (size : n ≤ 10) (bits : ∀ i, values i * (values i-1) = 0)
    (total : sum ((List.finRange n).map values) = 1) :
    ∃ index : Fin n, ∀ i, values i = if i = index then 1 else 0 := by
  obtain ⟨index, equal⟩ := one_hot_list ((List.finRange n).map values) (by simpa using size)
    (by intro value member; obtain ⟨i, _, rfl⟩ := List.mem_map.mp member; exact bits i) total
  let selected : Fin n := ⟨index.val, by simpa using index.isLt⟩
  refine ⟨selected, ?_⟩
  intro i
  have point := congrArg (fun xs : List F => xs[i.val]?) equal
  simp [oneHot, i.isLt] at point
  simpa [Fin.ext_iff, selected] using point

#print axioms one_hot_list
#print axioms one_hot_function

end ZkBuild.SlotSelection
