import SlotEmission

namespace ZkBuild.SlotNativeBinding

open Lean.Grind CircuitShape FullMatrix SlotEmission
attribute [local instance] Ring.intCast Semiring.natCast

def chunk {α : Type} (values : List α) (index : Nat) : List α :=
  (values.drop (index*31)).take 31

def packLinear : List Linear → Linear
  | [] => []
  | first :: rest => first ++ scale (packLinear rest) 256

def packingGate (index : Fin 5) : Gate :=
  ⟨sub (packLinear (chunk nativeLinears index.val)) [(6+index.val, 1)], constant 1, constant 0⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem packing_gates_match : ∀ index : Fin 5,
    (match SlotShape.compileShape.gates[11942+index.val]? with
    | none => false
    | some actual => sameGate (packingGate index) actual) = true := by native_decide

def packFields {F : Type} [CommRing F] : List F → F
  | [] => 0
  | first :: rest => first + 256 * packFields rest

theorem pack_linear_value {F : Type} [CommRing F] (values : Nat → F) (linears : List Linear) :
    evalLinear values (packLinear linears) = packFields (linears.map (evalLinear values)) := by
  induction linears with
  | nil => rfl
  | cons first rest ih =>
    simp only [packLinear, eval_append, eval_scale, List.map_cons, packFields, ih]
    rw [Ring.intCast_ofNat]

theorem pack_byte_fields {F : Type} [CommRing F] (bytes : List (Fin 256)) :
    packFields (bytes.map (fun byte => (byte.val : F))) = R1CS.packedField bytes := by
  induction bytes with
  | nil => rfl
  | cons first rest ih => simp only [List.map_cons, packFields, R1CS.packedField, ih]

theorem chunk_map {α β : Type} (f : α → β) (values : List α) (index : Nat) :
    (chunk values index).map f = chunk (values.map f) index := by
  simp only [chunk, List.map_take, List.map_drop]

theorem packing_constraint {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (index : Fin 5) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    packFields (chunk (nativeLinears.map (evalLinear ctx.get)) index.val) = ctx.get (6+index.val) := by
  have checked := packing_gates_match index
  cases found : SlotShape.compileShape.gates[11942+index.val]? with
  | none => simp [found] at checked
  | some actual =>
    have equation := same_gate_sound ctx (packingGate index) actual (by simpa [found] using checked)
      (holds actual (by simpa using Array.mem_of_getElem? found))
    change evalLinear ctx.get (sub (packLinear (chunk nativeLinears index.val)) [(6+index.val, 1)]) *
      evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0) at equation
    simp only [sub, eval_append, eval_scale, SlotTrace.eval_constant ctx one,
      Ring.intCast_neg, Ring.intCast_one, Ring.intCast_zero] at equation
    have wire : evalLinear ctx.get [(6+index.val, 1)] = ctx.get (6+index.val) := by
      simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
    rw [wire, pack_linear_value, chunk_map] at equation
    grind

def asByte (value : BitVec 8) : Fin 256 := ⟨value.toNat, value.isLt⟩

def PublicNative {F : Type} [CommRing F] (ctx : Lean.RArray F) (native : List (Fin 256)) : Prop :=
  ∀ index : Fin 5, ctx.get (6+index.val) = R1CS.packedField (chunk native index.val)

theorem chunks_determine_bounded {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Fin 256)) (sameLength : a.length = b.length) (capacity : a.length ≤ 155)
    (same : ∀ index : Fin 5, R1CS.packedField (F := F) (chunk a index.val) =
      R1CS.packedField (chunk b index.val)) : a = b := by
  have chunks (index : Fin 5) : chunk a index.val = chunk b index.val := by
    apply R1CS.packed_field_injective (F := F) _ _ _ (List.length_take_le _ _) (same index)
    simp [chunk, sameLength]
  apply List.ext_getElem
  · omega
  · intro i aBound bBound
    have bound : i < 155 := by omega
    let index : Fin 5 := ⟨i/31, by omega⟩
    have offsetBound : i%31 < 31 := Nat.mod_lt i (by decide)
    have position : index.val*31 + i%31 = i := by dsimp [index]; omega
    have point := congrArg (fun xs : List (Fin 256) => xs[i%31]?) (chunks index)
    simp only [chunk, List.getElem?_take_of_lt offsetBound, List.getElem?_drop, position,
      List.getElem?_eq_getElem aBound, List.getElem?_eq_getElem bBound, Option.some.injEq] at point
    exact point

theorem chunks_determine {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Fin 256)) (aLength : a.length = 144) (bLength : b.length = 144)
    (same : ∀ index : Fin 5, R1CS.packedField (F := F) (chunk a index.val) =
      R1CS.packedField (chunk b index.val)) : a = b :=
  chunks_determine_bounded a b (by omega) (by omega) same

theorem native_artifact_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (native : List (Fin 256)) (length : native.length = 144)
    (one : ctx.get 0 = 1) (inputs : PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ ops : List Op, ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      native = (Rv32Compiler.compileBytes ops).map asByte := by
  obtain ⟨ops, count, checked, emitted⟩ := full_native_emission ctx one holds
  have nativeLength : ((Rv32Compiler.compileBytes ops).map asByte).length = 144 := by
    have sizes := congrArg List.length emitted
    simpa only [List.length_map, native_length] using sizes.symm
  refine ⟨ops, count, checked, ?_⟩
  symm
  apply chunks_determine (F := F) _ native nativeLength length
  intro index
  have equation := packing_constraint ctx index one holds
  rw [emitted] at equation
  have mapped : (Rv32Compiler.compileBytes ops).map (fun byte => (byte.toNat : F)) =
      ((Rv32Compiler.compileBytes ops).map asByte).map (fun byte => (byte.val : F)) := by
    simp only [List.map_map, Function.comp_def, asByte]
  rw [mapped, ← chunk_map, pack_byte_fields] at equation
  exact equation.trans (inputs index)

theorem byte_roundtrip (value : BitVec 8) : BitVec.ofNat 8 (asByte value).val = value := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_ofNat]
  exact Nat.mod_eq_of_lt value.isLt

theorem native_execution {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (native : List (Fin 256)) (length : native.length = 144)
    (one : ctx.get 0 = 1) (inputs : PublicNative ctx native)
    (holds : Satisfied SlotShape.compileShape ctx.get) (registers : Rv32Encoding.Registers) :
    ∃ (ops : List Op) (value : Word), ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      ZkBuild.run (Rv32Compiler.inputLocals registers) ops [] = some [value] ∧
      Rv32Encoding.runBytes (native.map (fun byte => BitVec.ofNat 8 byte.val)) registers = some value := by
  obtain ⟨ops, count, checked, same⟩ := native_artifact_sound ctx native length one inputs holds
  obtain ⟨value, source, machine⟩ := Rv32Compiler.compiled_bytes_correct ops checked registers
  refine ⟨ops, value, count, checked, source, ?_⟩
  rw [same, List.map_map]
  simpa only [Function.comp_def, byte_roundtrip, List.map_id'] using machine

#print axioms packing_gates_match
#print axioms native_artifact_sound
#print axioms native_execution

end ZkBuild.SlotNativeBinding
