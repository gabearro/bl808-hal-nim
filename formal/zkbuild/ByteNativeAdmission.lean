import ByteCompileSoundness
import NativeAdmission

/- Ordinary-byte native admission, conditional on the pinned verifier's
   cryptographic soundness. Memory publication uses the shared owned-image
   model; implementation refinement and cache behavior remain separate. -/
namespace ZkBuild.ByteNativeAdmission

open Lean.Grind CircuitShape NativeAdmission
attribute [local instance] Ring.intCast Semiring.natCast

def admit (verify : Bytes → Bytes → Bytes → Bool) (wasm native proof : Bytes) : Option Image :=
  if wasm.length < 36 ∨ 156 < wasm.length ∨ native.length ≠ 144 ∨ proof.length ≠ 192 then none
  else if verify wasm native proof then
    (Rv32Encoding.loadWords (SlotCompilation.byteVectors native)).map fun words => ⟨wasm, words⟩
  else none

def CompilationRelation {F : Type} [Field F] (wasm native : Bytes) : Prop :=
  ∃ values : Nat → F, values 0 = 1 ∧ ByteCompileComposition.PublicRaw values wasm ∧
    ByteCompileComposition.PublicNative values native ∧ Satisfied ByteCompileShape.shape values

theorem admitted_snapshot (verify : Bytes → Bytes → Bytes → Bool) (wasm native proof : Bytes) (image : Image)
    (accepted : admit verify wasm native proof = some image) :
    36 ≤ wasm.length ∧ wasm.length ≤ 156 ∧ native.length = 144 ∧ proof.length = 192 ∧
      verify wasm native proof = true ∧ image.wasm = wasm ∧
      Rv32Encoding.loadWords (SlotCompilation.byteVectors native) = some image.words ∧
      image.words.flatMap Rv32Encoding.wordBytes = SlotCompilation.byteVectors native := by
  unfold admit at accepted
  split at accepted
  · contradiction
  · rename_i lengths
    split at accepted
    · rename_i verified
      obtain ⟨words, loaded, same⟩ := Option.map_eq_some_iff.mp accepted
      subst image
      exact ⟨by omega, by omega, by omega, by omega, verified, rfl, loaded,
        copied_words_exact _ _ loaded⟩
    · contradiction

theorem admitted_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (verify : Bytes → Bytes → Bytes → Bool)
    (verifierSound : ∀ wasm native proof, verify wasm native proof = true → CompilationRelation (F := F) wasm native)
    (wasm native proof : Bytes) (image : Image)
    (accepted : admit verify wasm native proof = some image) (registers : Rv32Encoding.Registers) :
    ∃ value : Word,
      ByteCompileSoundness.runBinary image.wasm (Rv32Compiler.inputLocals registers) = some [value] ∧
      NativeAdmission.invoke image registers = some value := by
  obtain ⟨lower, upper, nativeLength, _, verified, snapshot, loaded, _⟩ :=
    admitted_snapshot verify wasm native proof image accepted
  obtain ⟨values, one, rawInputs, nativeInputs, holds⟩ := verifierSound wasm native proof verified
  obtain ⟨value, source, target⟩ := ByteCompileSoundness.binary_execution values wasm native
    ⟨lower, upper⟩ nativeLength one rawInputs nativeInputs holds registers
  refine ⟨value, by simpa only [snapshot] using source, ?_⟩
  simpa only [Rv32Encoding.runBytes, loaded, Option.bind_some, NativeAdmission.invoke] using target

#print axioms admitted_execution

end ZkBuild.ByteNativeAdmission
