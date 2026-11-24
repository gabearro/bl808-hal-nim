import BinaryEnvelope
import LocalRanges

namespace ZkBuild.BinaryDeclarations

def vectorKeys (start : Nat) : List Nat → List (Nat × Nat)
  | [] => []
  | count :: rest => (List.range count).map (fun ordinal => (start, ordinal)) ++ vectorKeys (start+1) rest

theorem vector_key_count (counts : List Nat) (start : Nat) :
    (vectorKeys start counts).length = counts.sum := by
  induction counts generalizing start with
  | nil => rfl
  | cons count rest ih => simp [vectorKeys, ih]

theorem complete_membership {α : Type} (actual allowed : List α)
    (unique : actual.Nodup) (bounded : actual ⊆ allowed)
    (count : actual.length = allowed.length) : allowed ⊆ actual := by
  intro value member
  apply Classical.byContradiction
  intro missing
  have larger : (value :: actual).Nodup := List.nodup_cons.mpr ⟨missing, unique⟩
  have subset : value :: actual ⊆ allowed := by
    intro x present
    rcases List.mem_cons.mp present with rfl | rest
    · exact member
    · exact bounded rest
  have impossible := larger.length_le_of_subset subset
  simp only [List.length_cons] at impossible
  omega

theorem complete_vectors (counts : List Nat) (start : Nat) (actual : List (Nat × Nat))
    (unique : actual.Nodup) (bounded : actual ⊆ vectorKeys start counts)
    (count : actual.length = counts.sum) : vectorKeys start counts ⊆ actual := by
  apply complete_membership actual (vectorKeys start counts) unique bounded
  simpa [vector_key_count] using count

def encodedType (tag : Fin 7) : Nat := if tag.val < 5 then 127-tag.val else 117-tag.val

theorem encoded_type_injective (a b : Fin 7) (same : encodedType a = encodedType b) : a = b := by
  have ab := a.isLt
  have bb := b.isLt
  unfold encodedType at same
  apply Fin.ext
  split at same <;> split at same <;> omega

#print axioms vector_key_count
#print axioms complete_membership
#print axioms complete_vectors
#print axioms encoded_type_injective

end ZkBuild.BinaryDeclarations
