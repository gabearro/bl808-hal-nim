import RangeConstraints

namespace ZkBuild.RangeReuse

open Lean.Grind R1CS BitPacking RangeConstraints
attribute [local instance] Semiring.natCast

-- The cache stores already constrained bits, keyed by the exact wire and
-- width. It never caches by the current assignment of that wire.
def Certificate {F : Type} [Field F] (width : Nat) (value : F) (bits : List F) : Prop :=
  bits.length = width ∧
  (∀ bit ∈ bits, bit * (bit - 1) = 0) ∧
  weightedValues (bitWeights width) bits = value

theorem certificate_sound {F : Type} [Field F] (width : Nat) (value : F) (bits : List F)
    (valid : Certificate width value bits) :
    ∃ n : Nat, n < 2^width ∧ value = (n : F) :=
  unsigned_sound bits width value valid.1 valid.2.1 valid.2.2

theorem reuse {F : Type} [Field F] (width : Nat) (value : F) (bits : List F)
    (valid : Certificate width value bits) :
    Certificate width value bits ∧ Certificate width value bits := ⟨valid, valid⟩

theorem reuse_same_wire {F : Type} [Field F] (assignment : Nat → F)
    (wire other width otherWidth : Nat) (bits : List F)
    (sameKey : (wire, width) = (other, otherWidth))
    (valid : Certificate width (assignment wire) bits) :
    Certificate otherWidth (assignment other) bits := by
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj sameKey
  exact valid

-- Folded literals are Boolean constants. The builder checks the packed
-- field value against the literal before omitting any range constraints.
theorem literal_certificate {F : Type} [Field F] (bits : List Bool) :
    Certificate bits.length (packBits bits : F) (bits.map (boolValue (F := F))) := by
  refine ⟨by simp, ?_, ?_⟩
  · intro value member
    obtain ⟨bit, _, same⟩ := List.mem_map.mp member
    subst value
    cases bit <;> simp only [boolValue] <;> grind
  · rw [weighted_booleans, binary_weights_encode_bits]

theorem literal_binding {F : Type} [Field F] (bits : List Bool) (value : F)
    (binding : (packBits bits : F) = value) :
    Certificate bits.length value (bits.map (boolValue (F := F))) := by
  rw [← binding]
  exact literal_certificate bits

theorem rejected_literal {F : Type} [Field F] (contradiction : (0 : F) = 1) : False := by
  grind

#print axioms certificate_sound
#print axioms reuse_same_wire
#print axioms literal_certificate
#print axioms rejected_literal

end ZkBuild.RangeReuse
