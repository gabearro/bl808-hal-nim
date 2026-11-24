import BinaryDeclarations
import FlatInstructionSource

namespace ZkBuild.DeclarationProfile

theorem padded_length {α : Type} (rows : List α) (capacity : Nat) (zero : α)
    (fits : rows.length ≤ capacity) :
    (rows ++ List.replicate (capacity-rows.length) zero).length = capacity := by
  simp
  omega

theorem local_group_range (parameters groups ordinal : Nat) (inside : ordinal < groups) :
    parameters ≤ parameters+ordinal ∧ parameters+ordinal < parameters+groups := by omega

theorem local_group_not_parameter (parameters ordinal index : Nat) (before : index < parameters) :
    parameters+ordinal ≠ index := by omega

theorem local_group_index_injective (parameters left right : Nat)
    (same : parameters+left = parameters+right) : left = right := by omega

theorem all_local_groups_consumed (counts : List Nat) (actual : List (Nat × Nat))
    (unique : actual.Nodup) (bounded : actual ⊆ BinaryDeclarations.vectorKeys 0 counts)
    (total : actual.length = counts.sum) :
    BinaryDeclarations.vectorKeys 0 counts ⊆ actual :=
  BinaryDeclarations.complete_vectors counts 0 actual unique bounded total

-- Local group cardinality is independent of the number of variables in each
-- group. A zero-sized group still has an ordinal and source type/count bytes.
def variableCount (groups : List Nat) : Nat := groups.sum
def declarationCount (parameters : Nat) (groups : List Nat) : Nat := parameters+groups.length

theorem zero_group_variable_count (groups : List Nat) : variableCount (groups ++ [0]) = variableCount groups := by
  simp [variableCount]

theorem zero_group_declaration_count (parameters : Nat) (groups : List Nat) :
    declarationCount parameters (groups ++ [0]) = declarationCount parameters groups+1 := by
  simp [declarationCount,Nat.add_assoc]

theorem declaration_total (parameters groups total : Nat) (binding : total = parameters+groups) :
    total-parameters = groups := by omega

theorem closed_local_span (start finish consumed : Nat) (advances : finish = start+consumed) :
    finish-start = consumed := by omega

theorem zero_groups_no_source_gap (start finish : Nat) (closed : start = finish) : finish-start = 0 := by omega

theorem bounded_local_total (start count total : Nat) (last : start+count = total)
    (u32 : total < 2^32) : start < 2^32 ∧ count < 2^32 := by omega

theorem group_key_injective (function ordinal otherFunction otherOrdinal : Nat)
    (left : ordinal < 2^32) (right : otherOrdinal < 2^32)
    (same : function*2^32+ordinal = otherFunction*2^32+otherOrdinal) :
    function = otherFunction ∧ ordinal = otherOrdinal :=
  FlatInstructionSource.owner_key_injective function ordinal otherFunction otherOrdinal left right same

#print axioms padded_length
#print axioms local_group_range
#print axioms local_group_index_injective
#print axioms all_local_groups_consumed
#print axioms zero_group_variable_count
#print axioms zero_group_declaration_count
#print axioms declaration_total
#print axioms closed_local_span
#print axioms bounded_local_total
#print axioms group_key_injective

end ZkBuild.DeclarationProfile
