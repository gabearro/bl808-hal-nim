import SlotCompilation

/- The native loader's owned-snapshot and little-endian publication model.
   `verify` denotes the pinned pmCompile verifier. Its cryptographic soundness
   is an explicit hypothesis, not an axiom asserting that the Nim code is sound.
   Cache coherence and machine execution are platform refinement obligations. -/
namespace ZkBuild.NativeAdmission

open Lean.Grind Rv32Encoding SlotCompilation SlotNativeBinding CircuitShape

abbrev Bytes := List (Fin 256)

structure Image where
  wasm : Bytes
  words : List Word
  deriving DecidableEq

def admit (verify : Bytes → Bytes → Bytes → Bool)
    (wasm native proof : Bytes) : Option Image :=
  if wasm.length ≠ 132 ∨ native.length ≠ 144 ∨ proof.length ≠ 192 then none
  else if verify wasm native proof then
    (loadWords (byteVectors native)).map fun words => ⟨wasm, words⟩
  else none

def invoke (image : Image) (registers : Registers) : Option Word :=
  runEncoded image.words registers

theorem word_bytes_load (a b c d : BitVec 8) :
    wordBytes (loadWord a b c d) = [a, b, c, d] := by
  have first : (loadWord a b c d).extractLsb' 0 8 = a := by
    unfold loadWord
    bv_decide
  have second : (loadWord a b c d).extractLsb' 8 8 = b := by
    unfold loadWord
    bv_decide
  have third : (loadWord a b c d).extractLsb' 16 8 = c := by
    unfold loadWord
    bv_decide
  have fourth : (loadWord a b c d).extractLsb' 24 8 = d := by
    unfold loadWord
    bv_decide
  simp only [wordBytes, first, second, third, fourth]

theorem copied_words_exact (bytes : List (BitVec 8)) (words : List Word)
    (loaded : loadWords bytes = some words) : words.flatMap wordBytes = bytes := by
  induction bytes using loadWords.induct generalizing words with
  | case1 =>
    simp only [loadWords, Option.some.injEq] at loaded
    subst words
    rfl
  | case2 a b c d rest ih =>
    simp only [loadWords, Option.map_eq_some_iff] at loaded
    obtain ⟨tail, tailLoaded, rfl⟩ := loaded
    simp only [List.flatMap_cons, word_bytes_load, ih tail tailLoaded,
      List.cons_append, List.nil_append]
  | case3 bytes nonempty short =>
    cases bytes with
    | nil => exact (nonempty rfl).elim
    | cons a rest =>
      cases rest with
      | nil => simp [loadWords] at loaded
      | cons b rest =>
        cases rest with
        | nil => simp [loadWords] at loaded
        | cons c rest =>
          cases rest with
          | nil => simp [loadWords] at loaded
          | cons d rest => exact (short a b c d rest rfl).elim

theorem admitted_snapshot (verify : Bytes → Bytes → Bytes → Bool)
    (wasm native proof : Bytes) (image : Image)
    (accepted : admit verify wasm native proof = some image) :
    wasm.length = 132 ∧ native.length = 144 ∧ proof.length = 192 ∧
      verify wasm native proof = true ∧ image.wasm = wasm ∧
      loadWords (byteVectors native) = some image.words ∧
      image.words.flatMap wordBytes = byteVectors native := by
  unfold admit at accepted
  split at accepted
  · contradiction
  · rename_i lengths
    split at accepted
    · rename_i verified
      obtain ⟨words, loaded, same⟩ := Option.map_eq_some_iff.mp accepted
      subst image
      exact ⟨by omega, by omega, by omega, verified, rfl, loaded,
        copied_words_exact _ _ loaded⟩
    · contradiction

def CompilationRelation {F : Type} [Field F] (wasm native : Bytes) : Prop :=
  ∃ ctx : Lean.RArray F, ctx.get 0 = 1 ∧ PublicWasm ctx wasm ∧ PublicNative ctx native ∧
    Satisfied SlotShape.compileShape ctx.get

theorem admitted_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (verify : Bytes → Bytes → Bytes → Bool)
    (verifierSound : ∀ wasm native proof, verify wasm native proof = true →
      CompilationRelation (F := F) wasm native)
    (wasm native proof : Bytes) (image : Image)
    (accepted : admit verify wasm native proof = some image) (registers : Registers) :
    ∃ value : Word,
      WasmEncoding.runWasm (byteVectors image.wasm) (Rv32Compiler.inputLocals registers) = some [value] ∧
      invoke image registers = some value := by
  obtain ⟨wasmLength, nativeLength, _, verified, snapshot, loaded, _⟩ :=
    admitted_snapshot verify wasm native proof image accepted
  obtain ⟨ctx, one, wasmInputs, nativeInputs, holds⟩ := verifierSound wasm native proof verified
  obtain ⟨value, source, machine⟩ :=
    compilation_execution ctx wasm native wasmLength nativeLength one wasmInputs nativeInputs holds registers
  refine ⟨value, ?_, ?_⟩
  · simpa only [snapshot] using source
  · simpa only [runBytes, loaded, Option.bind_some, invoke] using machine

#print axioms copied_words_exact
#print axioms admitted_snapshot
#print axioms admitted_execution

end ZkBuild.NativeAdmission
