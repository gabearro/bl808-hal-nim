import ByteCompileScalarStep
import BinaryCompleteness

/- Lift the exact integer transition through every actual bridge row. This
   rules out alternative field accumulators and proves 32-bit bounds for all
   partial/finished constants throughout a satisfying compilation witness. -/
namespace ZkBuild.ByteCompileAccumulator

open Lean.Grind CircuitShape FullMatrix BodySoundness ByteCompileComposition
open ByteCompileScalarStep
attribute [local instance] Ring.intCast Semiring.natCast

def valueAt {F : Type} [CommRing F] (values : Nat → F) (index : Nat) : F :=
  if index = 0 then 0 else values (17994+(index-1)*27+8)

theorem previous_value {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (i : Fin 121) :
    ByteCompileRow.localValues values i 23 = valueAt values i.val := by
  by_cases first : i.val = 0
  · simp [ByteCompileRow.localValues, ByteCompileRow.rowMap, first, valueAt,
      ByteCompileRow.eval_constant values one, Ring.intCast_zero]
  · simp [ByteCompileRow.localValues, ByteCompileRow.rowMap, first, valueAt,
      ByteCompileRow.eval_wire]

theorem current_value {F : Type} [CommRing F] (values : Nat → F) (i : Fin 121) :
    ByteCompileRow.localValues values i 48 = valueAt values (i.val+1) := by
  simp [ByteCompileRow.localValues, ByteCompileRow.rowMap, valueAt, ByteCompileRow.eval_wire]

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (bytes : Fin 156 → Fin 256) (one : values 0 = 1)
    (bindings : ∀ position, R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get position) = ((bytes position).val : F))
    (holds : Satisfied ByteCompileShape.shape values) :
    ∀ count, count ≤ 121 → ∃ state : ByteStream.State, ∃ previous : Int,
      AtState (byteContext values) count state ∧
      0 ≤ previous ∧ previous < (limit state.1.val : Int) ∧ valueAt values count = (previous : F) := by
  intro count
  induction count with
  | zero =>
    intro _
    refine ⟨(⟨0, by decide⟩, ⟨0, by decide⟩), 0, ?_, by omega, ?_, ?_⟩
    · simpa [AtState] using initial_state (byteContext values) (projected_one values one).1
    · decide
    · simp [valueAt, Ring.intCast_zero]
  | succ count ih =>
    intro bound
    obtain ⟨state, previous, before, nonnegative, limited, value⟩ := ih (by omega)
    have small : count < 121 := by omega
    let i : Fin 121 := ⟨count, small⟩
    let byte := bodyByte bytes count
    have binding : R1CS.weightedValues (BitPacking.bitWeights 8)
        (globalBits (byteContext values).get (moduleByteIndex i)) = (byte.val : F) := by
      simpa [byte, bodyByte, small, i] using bindings (moduleByteIndex i)
    obtain ⟨next, stepped, afterState⟩ := boundary_step (byteContext values) bytes count small state
      (projected_one values one).1 bindings (byte_context_satisfied values holds) before
    have reference := BinaryCompleteness.bound_row_reference state next byte stepped
    have previousField : ByteCompileRow.localValues values i 23 = (previous : F) := by
      rw [previous_value values one i]
      exact value
    have nextField := (ByteCompileTransition.integer_transition values i state.1 state.2 byte previous
      one before binding holds previousField).1
    have bounds := preserves_interval state.1 state.2 byte next.1.val next.2.val previous reference
      ⟨nonnegative, limited⟩
    refine ⟨next, ByteCompileTransition.nextImmediate state.1 byte previous,
      afterState, bounds.1, bounds.2, ?_⟩
    rw [← current_value values i]
    exact nextField

theorem all_accumulators_are_words {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm : List (Fin 256)) (one : values 0 = 1)
    (inputs : PublicRaw values wasm) (holds : Satisfied ByteCompileShape.shape values)
    (count : Nat) (bound : count ≤ 121) :
    ∃ value : Nat, value < 2^32 ∧ valueAt values count = (value : F) := by
  have bindings := PublicBinding.public_bytes_bind_all_bits (byteContext values)
    (BinarySoundness.paddedBytes wasm) (projected_one values one).1
    (projected_raw values wasm inputs).2 (byte_context_satisfied values holds)
  obtain ⟨state, previous, _, nonnegative, limited, fieldValue⟩ := trace values
    (BinarySoundness.paddedBytes wasm) one bindings holds count bound
  have wordBound := limit_word_bound state.1.val
  have upper : previous < (2^32 : Int) := by omega
  refine ⟨previous.toNat, by omega, ?_⟩
  rw [fieldValue, ← Int.toNat_of_nonneg nonnegative]
  exact Ring.intCast_natCast _

#print axioms trace
#print axioms all_accumulators_are_words

end ZkBuild.ByteCompileAccumulator
