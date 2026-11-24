import ByteCompileWitness
import ByteCompileCast

/- Refine the executable cached witness to the canonical complete witness.
   Array contents are characterized at every in-range index. -/
namespace ZkBuild.ByteCompileWitnessRefinement

open Lean.Grind CircuitShape FullMatrix ByteCompileWitness ByteCompileSoundness
attribute [local instance] Ring.intCast Semiring.natCast

theorem byte_cache (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) (bound : wire < 6096) :
    ((prepare wasm ops).bytes[wire]?).getD 0 = ByteCompileSourceWitness.source (F := Int) wasm wire := by
  simp [prepare, bound]

theorem slot_cache (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) (bound : wire < 11899) :
    ((prepare wasm ops).slots[wire]?).getD 0 = ByteCompileCompleteness.slots (F := Int) ops wire := by
  simp [prepare, bound, SlotModuleCompleteness.cached_public_eq,
    SlotWitness.cached_values_eq, ByteCompileCompleteness.slots]

theorem row_cache (wasm : List (Fin 256)) (ops : List Op) (i : Fin 121) (j : Fin 27) :
    ((((prepare wasm ops).rows[i.val]?).getD #[])[j.val]?).getD 0 =
      ByteCompileCanonicalRow.values (ByteCompileSourceWitness.cfgAt wasm i.val)
        (ByteCompileSourceWitness.byteAt wasm i) (40+j.val) := by
  simp [prepare, i.isLt, j.isLt]

theorem merge_prefix {F : Type} [CommRing F] (a b c d leftTail rightTail : Nat → F)
    (bytes : ∀ k, k < 6096 → a k = b k) (slots : ∀ k, k < 11899 → c k = d k)
    (wire : Nat) (bound : wire < 17994) :
    ByteCompileMerge.values a c leftTail wire = ByteCompileMerge.values b d rightTail wire := by
  unfold ByteCompileMerge.values
  split
  · rfl
  · split
    · exact bytes _ (by omega)
    · split
      · exact slots _ (by omega)
      · split
        · exact bytes _ (by omega)
        · split
          · exact slots _ (by omega)
          · exact slots _ (by omega)

theorem base_values (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) (bound : wire < 17994) :
    base (prepare wasm ops) wire = ByteCompileCompleteness.values (F := Int) wasm ops wire := by
  exact merge_prefix _ _ _ _ _ _ (byte_cache wasm ops) (slot_cache wasm ops) wire bound

set_option maxRecDepth 100000 in
theorem body_values (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) (bound : wire < 21261) :
    bodyValues (prepare wasm ops) wire = ByteCompileCompleteness.values (F := Int) wasm ops wire := by
  by_cases isBase : wire < 17994
  · rw [bodyValues, ite_eq_left isBase]
    exact base_values wasm ops wire isBase
  · let i : Fin 121 := ⟨(wire-17994)/27, by omega⟩
    let j : Fin 27 := ⟨(wire-17994)%27, by omega⟩
    have index : 17994+i.val*27+j.val = wire := by dsimp [i, j]; omega
    rw [bodyValues, ite_eq_right isBase, ite_eq_left bound]
    have cached := row_cache wasm ops i j
    change ((((prepare wasm ops).rows[(wire-17994)/27]?).getD #[])[(wire-17994)%27]?).getD 0 = _ at cached
    rw [cached]
    have stored := ByteCompileBridgeWitness.stored_row (F := Int) wasm
      (ByteCompileCompleteness.slots ops) (ByteCompileCompleteness.binding ops) i j
    rw [index] at stored
    exact stored.symm

theorem body_cast {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op)
    (wire : Nat) (bound : wire < 21261) :
    (bodyValues (prepare wasm ops) wire : F) = ByteCompileCompleteness.values (F := F) wasm ops wire := by
  rw [body_values wasm ops wire bound]
  exact (ByteCompileCast.witness (F := F) wasm ops wire).symm

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem product_bounds : ∀ i : Fin 16,
    (ByteCompileSlotBinding.booleanLinear i 3 ++ ByteCompileSlotBinding.valueLinear i).all
      (fun term => term.1 < 21261) = true := by native_decide

theorem body_linear {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op)
    (linear : Linear) (bound : linear.all (fun term => term.1 < 21261) = true) :
    evalLinear (ByteCompileCompleteness.values (F := F) wasm ops) linear =
      ((evalLinear (bodyValues (prepare wasm ops)) linear : Int) : F) := by
  rw [← ByteCompileCanonicalRow.linear_cast]
  apply ByteCompileComposition.eval_congr
  intro term member
  exact (body_cast wasm ops term.1 (of_decide_eq_true (List.all_eq_true.mp bound term member))).symm

theorem value_refines {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : ByteCompileDecodeTrace.Configuration)
    (accepted : decodeBinary wasm = some final) (wire : Nat) (bound : wire < 21277) :
    (valueAt (prepare wasm (paddedProgram final.operations)) wire : F) =
      ByteCompileCompleteness.values (F := F) wasm (paddedProgram final.operations) wire := by
  let ops := paddedProgram final.operations
  by_cases bodyWire : wire < 21261
  · rw [valueAt, ite_eq_left bodyWire]
    exact body_cast wasm ops wire bodyWire
  · let i : Fin 16 := ⟨wire-21261, by omega⟩
    have sideBounds : (ByteCompileSlotBinding.booleanLinear i 3).all (fun term => term.1 < 21261) = true ∧
        (ByteCompileSlotBinding.valueLinear i).all (fun term => term.1 < 21261) = true := by
      simpa only [List.all_append, Bool.and_eq_true_iff] using product_bounds i
    have a := body_linear (F := F) wasm ops (ByteCompileSlotBinding.booleanLinear i 3) sideBounds.1
    have b := body_linear (F := F) wasm ops (ByteCompileSlotBinding.valueLinear i) sideBounds.2
    have length : ops.length = 16 := padded_length _ (ByteCompileTyping.accepted_decoder wasm final accepted).2.2
    have checked : checkProgram ops 0 = some 1 := ByteCompileTyping.decoded_program_checked wasm final accepted
    have product := ByteCompileCompleteness.product_wires (F := F) wasm ops length checked i
    have index : 21261+i.val = wire := by dsimp [i]; omega
    rw [index, a, b] at product
    rw [valueAt, ite_eq_right bodyWire, dite_eq_left bound, Ring.intCast_mul]
    exact product.symm

def output (wasm : List (Fin 256)) (final : ByteCompileDecodeTrace.Configuration) : Array Int :=
  Array.ofFn fun i : Fin 21277 => valueAt (prepare wasm (paddedProgram final.operations)) i.val

def fieldValues {F : Type} [CommRing F] (result : Array Int) (wire : Nat) : F :=
  ((result[wire]?.getD 0 : Int) : F)

theorem output_size (wasm : List (Fin 256)) (final : ByteCompileDecodeTrace.Configuration) :
    (output wasm final).size = 21277 := by simp [output]

theorem output_refines {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : ByteCompileDecodeTrace.Configuration)
    (accepted : decodeBinary wasm = some final) (wire : Nat) (bound : wire < 21277) :
    fieldValues (F := F) (output wasm final) wire =
      ByteCompileCompleteness.values (F := F) wasm (paddedProgram final.operations) wire := by
  simpa only [fieldValues, output, Array.getElem?_ofFn, bound, dite_true, Option.getD_some] using
    value_refines (F := F) wasm final accepted wire bound

theorem construct_from_decoded (wasm : List (Fin 256)) (final : ByteCompileDecodeTrace.Configuration)
    (accepted : decodeBinary wasm = some final) : construct wasm = some (output wasm final) := by
  simp [construct, output, accepted]

theorem construct_result (wasm : List (Fin 256)) (result : Array Int)
    (built : construct wasm = some result) :
    ∃ final, decodeBinary wasm = some final ∧ result = output wasm final := by
  cases decoded : decodeBinary wasm with
  | none => simp [construct, decoded] at built
  | some final =>
    have same : output wasm final = result := by simpa [construct, output, decoded] using built
    exact ⟨final, rfl, same.symm⟩

theorem construct_exists_iff (wasm : List (Fin 256)) :
    (∃ result, construct wasm = some result) ↔ (∃ final, decodeBinary wasm = some final) := by
  constructor
  · rintro ⟨result, built⟩
    obtain ⟨final, accepted, _⟩ := construct_result wasm result built
    exact ⟨final, accepted⟩
  · rintro ⟨final, accepted⟩
    exact ⟨output wasm final, construct_from_decoded wasm final accepted⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem matrix_bounds : ByteCompileComposition.bounded ByteCompileShape.shape = true := by native_decide

set_option maxRecDepth 100000 in
theorem construct_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (result : Array Int) (built : construct wasm = some result) :
    ∃ final, decodeBinary wasm = some final ∧ result.size = 21277 ∧
      fieldValues (F := F) result 0 = 1 ∧
      ByteCompileComposition.PublicRaw (fieldValues (F := F) result) wasm ∧
      ByteCompileComposition.PublicNative (fieldValues (F := F) result)
        ((Rv32Compiler.compileBytes (paddedProgram final.operations)).map SlotNativeBinding.asByte) ∧
      Satisfied ByteCompileShape.shape (fieldValues (F := F) result) := by
  obtain ⟨final, accepted, rfl⟩ := construct_result wasm result built
  have complete := ByteCompileCompleteness.binary_complete (F := F) wasm final accepted
  have point := output_refines (F := F) wasm final accepted
  refine ⟨final, accepted, output_size wasm final, (point 0 (by decide)).trans complete.1, ?_, ?_, ?_⟩
  · constructor
    · exact (point 1 (by decide)).trans complete.2.1.1
    · intro i
      exact (point (2+i.val) (by omega)).trans (complete.2.1.2 i)
  · intro i
    exact (point (8+i.val) (by omega)).trans (complete.2.2.1 i)
  · apply ByteCompileComposition.bounded_satisfied ByteCompileShape.shape matrix_bounds _ _ _ complete.2.2.2
    intro wire bound
    have size := ByteCompileShape.dimensions.1
    exact (point wire (by omega)).symm

#print axioms value_refines
#print axioms construct_correct
#print axioms construct_exists_iff

end ZkBuild.ByteCompileWitnessRefinement
