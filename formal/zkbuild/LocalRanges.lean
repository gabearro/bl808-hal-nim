import SignatureLists

namespace ZkBuild.LocalRanges

open Lean.Grind
attribute [local instance] Semiring.natCast

structure Span where
  first : Nat
  count : Nat
  tag : Fin 7

def Covers (span : Span) (index : Nat) : Prop :=
  span.first ≤ index ∧ index < span.first+span.count

theorem coverage_gaps (span : Span) (index lower upper : Nat)
    (low : index = span.first+lower)
    (high : span.first+span.count = index+1+upper) : Covers span index := by
  constructor <;> omega

theorem coverage_gaps_complete (span : Span) (index : Nat) (covers : Covers span index) :
    ∃ lower upper, index = span.first+lower ∧ span.first+span.count = index+1+upper := by
  exact ⟨index-span.first, span.first+span.count-index-1, by have := covers.1; omega,
    by have := covers.2; omega⟩

theorem adjacent_disjoint (a b : Span) (adjacent : a.first+a.count ≤ b.first)
    (index : Nat) (left : Covers a index) : ¬ Covers b index := by
  intro right
  have := left.2
  have := right.1
  omega

theorem namespace_injective (f i g j : Nat) (ib : i < 2^32) (jb : j < 2^32)
    (same : i+2^32*f = j+2^32*g) : i = j ∧ f = g :=
  RangeConstraints.radix_injective (2^32) i f j g ib jb same

theorem parameter_flag (ordinal length low high : Nat) (lowBound : low < 2^32)
    (boolean : high = 0 ∨ high = 1)
    (difference : low+2^32*high+length = ordinal+2^32) :
    (high = 0 ↔ ordinal < length) := by
  rcases boolean with zero | one <;> subst high <;> simp_all <;> omega

theorem parameter_member_ordinal (ordinal length : Nat) (parameter : ordinal < length) :
    length-1-ordinal < length ∧ length-1-(length-1-ordinal) = ordinal := by omega

theorem coverage_gate {F : Type} [Field F] [IsCharP F scalarModulus]
    (span : Span) (index lower upper : Nat)
    (fb : span.first < 2^32) (cb : span.count < 2^32) (ib : index < 2^32)
    (lb : lower < 2^32) (ub : upper < 2^32)
    (low : (index : F)-(span.first : F) = (lower : F))
    (high : (span.first : F)+(span.count : F)-(index : F)-1 = (upper : F)) : Covers span index := by
  have first : index = span.first+lower := by
    apply NumericEvents.nat_eq (F := F) index (span.first+lower)
    · simp [NumericEvents.countBound]; omega
    · simp [NumericEvents.countBound]; omega
    · push_cast; grind
  have last : span.first+span.count = index+1+upper := by
    apply NumericEvents.nat_eq (F := F) (span.first+span.count) (index+1+upper)
    · simp [NumericEvents.countBound]; omega
    · simp [NumericEvents.countBound]; omega
    · push_cast; grind
  exact coverage_gaps span index lower upper first last

#print axioms coverage_gaps
#print axioms coverage_gaps_complete
#print axioms adjacent_disjoint
#print axioms namespace_injective
#print axioms parameter_flag
#print axioms parameter_member_ordinal
#print axioms coverage_gate

end ZkBuild.LocalRanges
