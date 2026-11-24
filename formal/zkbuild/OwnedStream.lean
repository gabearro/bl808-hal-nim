import BinaryDeclarations
import DeclarationProfile

namespace ZkBuild.OwnedStream

-- Shared-budget coverage uses exact finite cardinality, not random sampling.
-- These are mathematical obligations for the Nim relation, not an extraction
-- theorem connecting arbitrary Nim executions to Lean.
theorem complete_children (counts : List Nat) (children : List (Nat × Nat))
    (unique : children.Nodup) (bounded : children ⊆ BinaryDeclarations.vectorKeys 0 counts)
    (total : children.length = counts.sum) :
    BinaryDeclarations.vectorKeys 0 counts ⊆ children :=
  BinaryDeclarations.complete_vectors counts 0 children unique bounded total

theorem no_missing_positive_parent (count rows : Nat) (positive : 0 < count)
    (complete : rows = count) : 0 < rows := by omega

theorem next_ordinal_unique (previous next : Nat) (step : next = previous+1) :
    next ≠ previous := by omega

theorem no_byte_gap (finish nextStart : Nat) (linked : finish = nextStart) :
    nextStart-finish = 0 := by omega

theorem empty_parent_span (count start finish : Nat) (empty : count = 0)
    (closed : count = 0 → start = finish) : start = finish := closed empty

theorem closed_span_length (start finish length : Nat) (span : finish = start+length) :
    finish-start = length := by omega

theorem owner_key_injective (owner ordinal owner' ordinal' : Nat)
    (a : ordinal < 2^32) (b : ordinal' < 2^32)
    (same : owner*2^32+ordinal = owner'*2^32+ordinal') :
    owner = owner' ∧ ordinal = ordinal' :=
  DeclarationProfile.group_key_injective owner ordinal owner' ordinal' a b same

theorem byte_budget (lengths : List Nat) (capacity : Nat)
    (fits : lengths.sum ≤ capacity) : lengths.sum + (capacity-lengths.sum) = capacity := by omega

theorem name_partition (exports imports customs total : Nat)
    (count : total = exports+2*imports+customs) :
    total-exports-2*imports = customs := by omega

theorem padding_cannot_add_children (count : Nat) (inactive : count = 0)
    (ordinal : Nat) : ¬ ordinal < count := by omega

#print axioms complete_children
#print axioms owner_key_injective
#print axioms empty_parent_span
#print axioms closed_span_length
#print axioms name_partition
#print axioms padding_cannot_add_children

end ZkBuild.OwnedStream
