import ByteCompileCanonicalRow
import ByteCompileMerge

/- The constructed byte witness supplies the actual decoder inputs in the
   combined matrix. No bridge or final-binding satisfaction is assumed here. -/
namespace ZkBuild.ByteCompileSourceWitness

open Lean.Grind CircuitShape FullMatrix BodySoundness ExactLength ByteCompileComposition
open ByteCompileDecodeTrace ByteCompileConstructionTrace
attribute [local instance] Ring.intCast Semiring.natCast

def source {F : Type} [CommRing F] (wasm : List (Fin 256)) : Nat → F :=
  BodyCompleteness.moduleValues
    (BinaryCompleteness.publicValues wasm.length (BinarySoundness.paddedBytes wasm))
    (BinarySoundness.paddedBytes wasm) (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm))

def body (wasm : List (Fin 256)) : List (Fin 256) := bodySuffix (BinarySoundness.paddedBytes wasm) 0 121
def cfgAt (wasm : List (Fin 256)) (i : Nat) : Configuration := after initial (body wasm) i
def byteAt (wasm : List (Fin 256)) (i : Fin 121) : Fin 256 := bodyByte (BinarySoundness.paddedBytes wasm) i.val

theorem body_length (wasm : List (Fin 256)) : (body wasm).length = 121 := by
  simp [body, body_suffix_length]

theorem body_get (wasm : List (Fin 256)) (i : Fin 121) :
    (body wasm)[i.val]'(by rw [body_length]; exact i.isLt) = byteAt wasm i := by
  simpa only [body, byteAt, Nat.zero_add] using BinarySoundness.body_suffix_get (BinarySoundness.paddedBytes wasm) 121 0 i.val i.isLt

theorem row_step (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (i : Fin 121) :
    advance (cfgAt wasm i.val) (byteAt wasm i) = some (cfgAt wasm (i.val+1)) := by
  have step := after_step (body wasm) initial final i.val (by rw [body_length]; exact i.isLt)
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.1
  rw [body_get] at step
  exact step

theorem row_suffix (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (index : Nat) :
    runDecoder (cfgAt wasm index) ((body wasm).drop index) = some final :=
  after_suffix (body wasm) initial final index (ByteCompileTyping.accepted_decoder wasm final accepted).2.1

theorem row_remaining (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (i : Fin 121) :
    runDecoder (cfgAt wasm i.val) (byteAt wasm i :: (body wasm).drop (i.val+1)) = some final := by
  have tail := row_suffix wasm final accepted i.val
  have bound : i.val < (body wasm).length := by rw [body_length]; exact i.isLt
  rw [List.drop_eq_getElem_cons bound, body_get] at tail
  exact tail

theorem row_range (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (i : Fin 121) : InRange (cfgAt wasm i.val) :=
  after_range (body wasm) initial final (ByteCompileTyping.accepted_decoder wasm final accepted).2.1
    initial_range i.val (by rw [body_length]; omega)

theorem row_fits (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (index : Nat) :
    (cfgAt wasm index).operations.length ≤ 16 :=
  Nat.le_trans (run_length _ _ _ (row_suffix wasm final accepted index))
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.2

theorem decoder_final (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) : cfgAt wasm 121 = final := by
  have ending := after_end (body wasm) initial final (ByteCompileTyping.accepted_decoder wasm final accepted).2.1
  rw [body_length] at ending
  exact ending

theorem source_one {F : Type} [CommRing F] (wasm : List (Fin 256)) : (source (F := F) wasm) 0 = 1 := by
  simp [source, BodyCompleteness.moduleValues]

theorem source_context {F : Type} [CommRing F] (wasm : List (Fin 256)) (slots tail : Nat → F) :
    byteContext (ByteCompileMerge.values (source wasm) slots tail) = BinaryCompleteness.witnessContext wasm := by
  rw [ByteCompileMerge.byte_context (source wasm) slots tail (source_one wasm)]
  rfl

theorem source_holds {F : Type} [CommRing F] (wasm : List (Fin 256))
    (supported : BinarySoundness.SupportedWasmBinary wasm) : Satisfied byteShape (source (F := F) wasm) := by
  apply bounded_satisfied byteShape sources_bounded.1 (BinaryCompleteness.witnessContext wasm).get
    (source wasm) _ (BinaryCompleteness.binary_complete wasm supported).2.2
  intro k bound
  have size : byteShape.wires = 6096 := by native_decide
  exact BodyCompleteness.module_context_entry _ _ _ k (by omega)

theorem decoder_state (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (i : Fin 121) :
    (cfgAt wasm i.val).parser = BodyCompleteness.before
      (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm)) i := by
  have decoded := (ByteCompileTyping.accepted_decoder wasm final accepted).2.1
  simpa only [cfgAt, body, BodyCompleteness.before, BinaryCompleteness.statesFor, ByteCompileDecodeTrace.initial] using
    after_parser (body wasm) initial final i.val decoded

theorem source_before {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots tail : Nat → F) (i : Fin 121) :
    AtState (byteContext (ByteCompileMerge.values (source wasm) slots tail)) i.val (cfgAt wasm i.val).parser := by
  have decoded := (ByteCompileTyping.accepted_decoder wasm final accepted).2.1
  have parsed := ByteCompileTyping.run_parser (body wasm) initial final decoded
  have trace := (BinaryCompleteness.states_for_valid (BinarySoundness.paddedBytes wasm) final.parser parsed).1
  have incoming := (BodyCompleteness.constructed_all_rows
    (BinaryCompleteness.publicValues (F := F) wasm.length (BinarySoundness.paddedBytes wasm))
    (BinarySoundness.paddedBytes wasm) (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm)) trace).2.2 i
  rw [source_context, decoder_state wasm final accepted i]
  simpa only [AtState, i.isLt, dite_true, BinaryCompleteness.witnessContext, BinaryCompleteness.context] using incoming

theorem source_inputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots tail : Nat → F) (i : Fin 121) :
    ∀ k, k < 23 → ByteCompileRow.localValues (ByteCompileMerge.values (source wasm) slots tail) i k =
      (ByteCompileCanonicalRow.inputValue (cfgAt wasm i.val) (byteAt wasm i) k : F) := by
  have supported := (ByteCompileTyping.accepted_decoder wasm final accepted).1
  have holds : Satisfied byteShape (byteContext (ByteCompileMerge.values (source wasm) slots tail)).get := by
    rw [source_context]
    exact (BinaryCompleteness.binary_complete wasm supported).2.2
  have binding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext (ByteCompileMerge.values (source wasm) slots tail)).get (moduleByteIndex i)) =
      ((byteAt wasm i).val : F) := by
    rw [source_context]
    simpa only [BinaryCompleteness.witnessContext, byteAt, bodyByte, i.isLt, dite_true] using
      BinaryCompleteness.bindings (F := F) wasm.length (BinarySoundness.paddedBytes wasm)
        (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm)) (moduleByteIndex i)
  have normalized := ByteCompileDecodeRow.canonical_bridge_inputs_from_bytes
    (ByteCompileMerge.values (source wasm) slots tail) i (cfgAt wasm i.val).parser.1 (cfgAt wasm i.val).parser.2
    (byteAt wasm i) (ByteCompileMerge.one _ _ _) (source_before wasm final accepted slots tail i) binding holds
  intro k bound
  simpa only [ByteCompileCanonicalRow.inputValue, bound, ite_true] using normalized k bound

#print axioms source_before
#print axioms source_inputs

end ZkBuild.ByteCompileSourceWitness
