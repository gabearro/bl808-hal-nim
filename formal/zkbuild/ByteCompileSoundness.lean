import ByteCompileSlotBinding
import SlotCompilation

/- Soundness for the ordinary-byte compilation relation: decoded operations
   and the emitted RV32 artifact are bound to the same padded program. -/
namespace ZkBuild.ByteCompileSoundness

open Lean.Grind CircuitShape FullMatrix BodySoundness ByteCompileComposition ByteCompileDecodeTrace
attribute [local instance] Ring.intCast Semiring.natCast

def paddedProgram (ops : List Op) : List Op := List.replicate (16-ops.length) .nop ++ ops

instance (wasm : List (Fin 256)) : Decidable (BinarySoundness.SupportedWasmBinary wasm) := by
  unfold BinarySoundness.SupportedWasmBinary HeaderSoundness.HeaderValid
  infer_instance

def decodeBinary (wasm : List (Fin 256)) : Option Configuration := do
  if !decide (BinarySoundness.SupportedWasmBinary wasm) then none else
    let final ← runDecoder initial (bodySuffix (BinarySoundness.paddedBytes wasm) 0 121)
    if final.operations.length ≤ 16 then some final else none

def runBinary (wasm : List (Fin 256)) (locals : Fin 2 → Word) : Option (List Word) :=
  (decodeBinary wasm).bind fun final => ZkBuild.run locals final.operations []

theorem padded_length (ops : List Op) (bound : ops.length ≤ 16) : (paddedProgram ops).length = 16 := by
  simp only [paddedProgram, List.length_append, List.length_replicate]
  omega

theorem encoded_padded {F : Type} [CommRing F] (ops : List Op) :
    encodedQueue (F := F) ops = (paddedProgram ops).map (fun op => (ByteCompileQueue.token op : F)) := by
  simp [encodedQueue, paddedProgram, ByteCompileQueue.padded, List.map_append, List.map_replicate,
    ByteCompileQueue.token, Semiring.natCast_zero, List.map_map]

theorem selected_at {F : Type} [CommRing F] (ctx : Lean.RArray F) (kinds : List (Fin 10)) :
    ∀ start i (bound : i < kinds.length), SlotTrace.SelectedProgram ctx start kinds →
      SlotTrace.SelectorAt ctx (start+i) kinds[i] := by
  induction kinds with
  | nil => intro start i bound; simp at bound
  | cons kind rest ih =>
    intro start i bound selected
    cases i with
    | zero => simpa using selected.1
    | succ i =>
      simpa only [List.getElem_cons_succ, Nat.add_assoc, Nat.add_comm 1 i] using
        ih (start+1) i (by simp only [List.length_cons] at bound; omega) selected.2

theorem operations_at (values : Nat → Word) (kinds : List (Fin 10)) : ∀ start i (bound : i < kinds.length),
    (SlotProgram.operations values start kinds)[i]'(by simp only [SlotProgram.operations_length]; exact bound) =
      SlotNative.operation kinds[i] (values (start+i)) := by
  induction kinds with
  | nil => intro start i bound; simp at bound
  | cons kind rest ih =>
    intro start i bound
    cases i with
    | zero => rfl
    | succ i =>
      simpa only [SlotProgram.operations, List.getElem_cons_succ, show start+1+i = start+(i+1) by omega] using
        ih (start+1) i (by simp only [List.length_cons] at bound; omega)

theorem selected_program_tokens {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (holds : Satisfied ByteCompileShape.shape values)
    (kinds : List (Fin 10)) (length : kinds.length = 16)
    (selected : SlotTrace.SelectedProgram (slotContext values) 0 kinds) :
    ByteCompileQueueStep.queueList values 121 =
      (SlotProgram.operations (SlotEmission.immediateAt (slotContext values)) 0 kinds).map
        (fun op => (ByteCompileQueue.token op : F)) := by
  apply List.ext_getElem
  · simp [ByteCompileQueueStep.queueList, SlotProgram.operations_length, length]
  · intro i left right
    have bound : i < 16 := by simpa [ByteCompileQueueStep.queueList] using left
    have inKinds : i < kinds.length := by omega
    have chosen := selected_at (slotContext values) kinds 0 i inKinds selected
    have matched := ByteCompileSlotBinding.queue_token values one holds ⟨i, bound⟩ kinds[i]
      (by simpa using chosen)
    simp only [ByteCompileQueueStep.queueList, List.getElem_ofFn, List.getElem_map,
      operations_at _ _ 0 i inKinds, Nat.zero_add]
    exact matched

theorem mapped_tokens_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List Op)
    (same : a.map (fun op => (ByteCompileQueue.token op : F)) = b.map (fun op => (ByteCompileQueue.token op : F))) :
    a = b := by
  have length : a.length = b.length := by simpa using congrArg List.length same
  apply List.ext_getElem length
  intro i left right
  apply ByteCompileQueue.field_token_injective (F := F)
  have point := congrArg (fun xs : List F => (xs[i]?).getD 0) same
  have leftMap : i < (a.map (fun op => (ByteCompileQueue.token op : F))).length := by simpa using left
  have rightMap : i < (b.map (fun op => (ByteCompileQueue.token op : F))).length := by simpa using right
  simpa only [List.getElem?_eq_getElem leftMap, List.getElem?_eq_getElem rightMap,
    List.getElem_map, Option.getD_some] using point

theorem native_for_selected {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (native : List (Fin 256)) (length : native.length = 144)
    (one : ctx.get 0 = 1) (inputs : SlotNativeBinding.PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) (kinds : List (Fin 10))
    (count : kinds.length = 16) (selected : SlotTrace.SelectedProgram ctx 0 kinds) :
    native = (Rv32Compiler.compileBytes (SlotProgram.operations (SlotEmission.immediateAt ctx) 0 kinds)).map SlotNativeBinding.asByte := by
  let ops := SlotProgram.operations (SlotEmission.immediateAt ctx) 0 kinds
  have emitted := SlotEmission.native_emission_for ctx one holds kinds count selected
  have encodedLength : (Rv32Compiler.compileBytes ops).length = 144 := by
    have sizes := congrArg List.length emitted
    simpa only [List.length_map, SlotEmission.native_length, ops] using sizes.symm
  apply SlotCompilation.artifact_binding ctx SlotEmission.nativeLinears (Rv32Compiler.compileBytes ops) native
    (by omega) (by omega) emitted
  intro index
  exact (SlotNativeBinding.packing_constraint ctx index one holds).trans (inputs index)

theorem decoded_compilation {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm native : List (Fin 256)) (nativeLength : native.length = 144)
    (one : values 0 = 1) (rawInputs : PublicRaw values wasm) (nativeInputs : PublicNative values native)
    (holds : Satisfied ByteCompileShape.shape values) :
    ∃ final : Configuration,
      runDecoder initial (bodySuffix (BinarySoundness.paddedBytes wasm) 0 121) = some final ∧
      final.operations.length ≤ 16 ∧ checkProgram (paddedProgram final.operations) 0 = some 1 ∧
      native = (Rv32Compiler.compileBytes (paddedProgram final.operations)).map SlotNativeBinding.asByte := by
  obtain ⟨final, decoded, bound, _, queued⟩ := decoded_queue values wasm one rawInputs holds
  let ctx := slotContext values
  have ctxOne := (projected_one values one).2
  have ctxHolds := slot_context_satisfied values holds
  obtain ⟨kinds, length, checked, selected⟩ := SlotTrace.full_stack_trace ctx ctxOne ctxHolds
  let ops := SlotProgram.operations (SlotEmission.immediateAt ctx) 0 kinds
  have tokens := selected_program_tokens values one holds kinds length selected
  have programs : paddedProgram final.operations = ops := by
    apply mapped_tokens_injective (F := F)
    rw [← encoded_padded]
    exact queued.symm.trans tokens
  have programChecked : checkProgram ops 0 = some 1 :=
    SlotProgram.kind_program_refines (SlotEmission.immediateAt ctx) kinds 0 ⟨0, by decide⟩ 1 checked
  have nativeMatch := native_for_selected ctx native nativeLength ctxOne (projected_native values native nativeInputs)
    ctxHolds kinds length selected
  exact ⟨final, decoded, bound, programs ▸ programChecked, programs ▸ nativeMatch⟩

theorem decoded_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm native : List (Fin 256)) (nativeLength : native.length = 144)
    (one : values 0 = 1) (rawInputs : PublicRaw values wasm) (nativeInputs : PublicNative values native)
    (holds : Satisfied ByteCompileShape.shape values) (registers : Rv32Encoding.Registers) :
    ∃ (final : Configuration) (value : Word),
      runDecoder initial (bodySuffix (BinarySoundness.paddedBytes wasm) 0 121) = some final ∧
      ZkBuild.run (Rv32Compiler.inputLocals registers) final.operations [] = some [value] ∧
      Rv32Encoding.runBytes (SlotCompilation.byteVectors native) registers = some value := by
  obtain ⟨final, decoded, _, checked, nativeMatch⟩ := decoded_compilation values wasm native nativeLength one rawInputs nativeInputs holds
  obtain ⟨value, source, machine⟩ := Rv32Compiler.compiled_bytes_correct (paddedProgram final.operations) checked registers
  refine ⟨final, value, decoded, ?_, ?_⟩
  · simpa only [paddedProgram, ByteCompileQueue.leading_nops] using source
  · rw [nativeMatch, SlotCompilation.byte_vectors_roundtrip]
    exact machine

theorem binary_compilation {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm native : List (Fin 256))
    (wasmLength : 36 ≤ wasm.length ∧ wasm.length ≤ 156) (nativeLength : native.length = 144)
    (one : values 0 = 1) (rawInputs : PublicRaw values wasm) (nativeInputs : PublicNative values native)
    (holds : Satisfied ByteCompileShape.shape values) :
    ∃ final : Configuration, decodeBinary wasm = some final ∧
      checkProgram (paddedProgram final.operations) 0 = some 1 ∧
      native = (Rv32Compiler.compileBytes (paddedProgram final.operations)).map SlotNativeBinding.asByte := by
  have supported := raw_binary_valid values wasm wasmLength one rawInputs holds
  obtain ⟨final, decoded, bound, checked, nativeMatch⟩ :=
    decoded_compilation values wasm native nativeLength one rawInputs nativeInputs holds
  refine ⟨final, ?_, checked, nativeMatch⟩
  simp [decodeBinary, supported, decoded, bound]

theorem binary_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm native : List (Fin 256))
    (wasmLength : 36 ≤ wasm.length ∧ wasm.length ≤ 156) (nativeLength : native.length = 144)
    (one : values 0 = 1) (rawInputs : PublicRaw values wasm) (nativeInputs : PublicNative values native)
    (holds : Satisfied ByteCompileShape.shape values) (registers : Rv32Encoding.Registers) :
    ∃ value : Word, runBinary wasm (Rv32Compiler.inputLocals registers) = some [value] ∧
      Rv32Encoding.runBytes (SlotCompilation.byteVectors native) registers = some value := by
  obtain ⟨final, decoded, checked, nativeMatch⟩ :=
    binary_compilation values wasm native wasmLength nativeLength one rawInputs nativeInputs holds
  obtain ⟨value, source, machine⟩ := Rv32Compiler.compiled_bytes_correct (paddedProgram final.operations) checked registers
  refine ⟨value, ?_, ?_⟩
  · simpa only [runBinary, decoded, Option.bind_some, paddedProgram, ByteCompileQueue.leading_nops] using source
  · rw [nativeMatch, SlotCompilation.byte_vectors_roundtrip]
    exact machine

#print axioms decoded_compilation
#print axioms decoded_execution
#print axioms binary_execution

end ZkBuild.ByteCompileSoundness
