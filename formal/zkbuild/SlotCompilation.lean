import SlotWasm

/- Soundness of the complete fixed-slot compilation matrix for the actual
   submitted WASM and native bytes. Both artifacts recover the same program. -/
namespace ZkBuild.SlotCompilation

open Lean.Grind CircuitShape FullMatrix SlotTrace SlotEmission SlotNativeBinding
attribute [local instance] Ring.intCast Semiring.natCast

def wasmPackingGate (index : Fin 5) : Gate :=
  ⟨sub (packLinear (chunk SlotWasm.wasmLinears index.val)) [(1+index.val, 1)], constant 1, constant 0⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem wasm_packing_gates_match : ∀ index : Fin 5,
    (match SlotShape.compileShape.gates[11937+index.val]? with
    | none => false
    | some actual => sameGate (wasmPackingGate index) actual) = true := by native_decide

def PublicWasm {F : Type} [CommRing F] (ctx : Lean.RArray F) (wasm : List (Fin 256)) : Prop :=
  ∀ index : Fin 5, ctx.get (1+index.val) = R1CS.packedField (chunk wasm index.val)

theorem wasm_packing_constraint {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (index : Fin 5) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    packFields (chunk (SlotWasm.wasmLinears.map (evalLinear ctx.get)) index.val) = ctx.get (1+index.val) := by
  have checked := wasm_packing_gates_match index
  cases found : SlotShape.compileShape.gates[11937+index.val]? with
  | none => simp [found] at checked
  | some actual =>
    have equation := same_gate_sound ctx (wasmPackingGate index) actual (by simpa [found] using checked)
      (holds actual (by simpa using Array.mem_of_getElem? found))
    change evalLinear ctx.get (sub (packLinear (chunk SlotWasm.wasmLinears index.val)) [(1+index.val, 1)]) *
      evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0) at equation
    simp only [sub, eval_append, eval_scale, SlotTrace.eval_constant ctx one,
      Ring.intCast_neg, Ring.intCast_one, Ring.intCast_zero] at equation
    have wire : evalLinear ctx.get [(1+index.val, 1)] = ctx.get (1+index.val) := by
      simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
    rw [wire, pack_linear_value, chunk_map] at equation
    grind

theorem artifact_binding {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (linears : List Linear) (encoded : List (BitVec 8)) (submitted : List (Fin 256))
    (length : submitted.length = encoded.length) (capacity : submitted.length ≤ 155)
    (emitted : linears.map (evalLinear ctx.get) = encoded.map (fun byte => (byte.toNat : F)))
    (packing : ∀ index : Fin 5, packFields (chunk (linears.map (evalLinear ctx.get)) index.val) =
      R1CS.packedField (chunk submitted index.val)) : submitted = encoded.map asByte := by
  symm
  apply chunks_determine_bounded (F := F) _ submitted (by simpa using length.symm)
    (by simp only [List.length_map]; omega)
  intro index
  have equation := packing index
  rw [emitted] at equation
  have mapped : encoded.map (fun byte => (byte.toNat : F)) =
      (encoded.map asByte).map (fun byte => (byte.val : F)) := by
    simp only [List.map_map, Function.comp_def, asByte]
  rw [mapped, ← chunk_map, pack_byte_fields] at equation
  exact equation

theorem compilation_artifacts {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (wasm native : List (Fin 256))
    (wasmLength : wasm.length = 132) (nativeLength : native.length = 144)
    (one : ctx.get 0 = 1) (wasmInputs : PublicWasm ctx wasm) (nativeInputs : PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ ops : List Op, ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      wasm = (WasmEncoding.encodeWasm ops).map asByte ∧
      native = (Rv32Compiler.compileBytes ops).map asByte := by
  obtain ⟨kinds, count, checkedKinds, selected⟩ := full_stack_trace ctx one holds
  let ops := SlotProgram.operations (immediateAt ctx) 0 kinds
  have opCount : ops.length = 16 := by simpa only [ops, SlotProgram.operations_length] using count
  have checked : checkProgram ops 0 = some 1 :=
    SlotProgram.kind_program_refines (immediateAt ctx) kinds 0 ⟨0, by decide⟩ 1 checkedKinds
  have wasmEmitted := SlotWasm.wasm_emission_for ctx one holds kinds count selected
  have nativeEmitted := native_emission_for ctx one holds kinds count selected
  have encodedWasmLength : (WasmEncoding.encodeWasm ops).length = 132 := by
    rw [WasmEncoding.binary_length, opCount]
  have encodedNativeLength : (Rv32Compiler.compileBytes ops).length = 144 := by
    have lengths := congrArg List.length nativeEmitted
    simpa only [List.length_map, SlotEmission.native_length, ops] using lengths.symm
  refine ⟨ops, opCount, checked, ?_, ?_⟩
  · apply artifact_binding ctx SlotWasm.wasmLinears (WasmEncoding.encodeWasm ops) wasm
      (by omega) (by omega) wasmEmitted
    intro index
    exact (wasm_packing_constraint ctx index one holds).trans (wasmInputs index)
  · apply artifact_binding ctx nativeLinears (Rv32Compiler.compileBytes ops) native
      (by omega) (by omega) nativeEmitted
    intro index
    exact (packing_constraint ctx index one holds).trans (nativeInputs index)

def byteVectors (bytes : List (Fin 256)) : List (BitVec 8) := bytes.map (fun byte => BitVec.ofNat 8 byte.val)

theorem byte_vectors_roundtrip (bytes : List (BitVec 8)) : byteVectors (bytes.map asByte) = bytes := by
  simp only [byteVectors, List.map_map, Function.comp_def, byte_roundtrip, List.map_id']

theorem compilation_soundness {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (wasm native : List (Fin 256))
    (wasmLength : wasm.length = 132) (nativeLength : native.length = 144)
    (one : ctx.get 0 = 1) (wasmInputs : PublicWasm ctx wasm) (nativeInputs : PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ ops : List Op, ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      WasmEncoding.decodeWasm (byteVectors wasm) = some ops ∧
      byteVectors native = Rv32Compiler.compileBytes ops := by
  obtain ⟨ops, count, checked, wasmEq, nativeEq⟩ :=
    compilation_artifacts ctx wasm native wasmLength nativeLength one wasmInputs nativeInputs holds
  refine ⟨ops, count, checked, ?_, ?_⟩
  · rw [wasmEq, byte_vectors_roundtrip]
    exact WasmEncoding.decoded_encoding ops count checked
  · rw [nativeEq, byte_vectors_roundtrip]

theorem compilation_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (wasm native : List (Fin 256))
    (wasmLength : wasm.length = 132) (nativeLength : native.length = 144)
    (one : ctx.get 0 = 1) (wasmInputs : PublicWasm ctx wasm) (nativeInputs : PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) (registers : Rv32Encoding.Registers) :
    ∃ value : Word,
      WasmEncoding.runWasm (byteVectors wasm) (Rv32Compiler.inputLocals registers) = some [value] ∧
      Rv32Encoding.runBytes (byteVectors native) registers = some value := by
  obtain ⟨ops, _, checked, decoded, nativeEq⟩ :=
    compilation_soundness ctx wasm native wasmLength nativeLength one wasmInputs nativeInputs holds
  obtain ⟨value, source, machine⟩ := Rv32Compiler.compiled_bytes_correct ops checked registers
  refine ⟨value, ?_, ?_⟩
  · rw [WasmEncoding.runWasm, decoded]
    exact source
  · rw [nativeEq]
    exact machine

#print axioms compilation_soundness
#print axioms compilation_execution

end ZkBuild.SlotCompilation
