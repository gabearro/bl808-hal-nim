import WasmEncoding
import SlotNativeBinding

namespace ZkBuild.SlotWasm

open Lean.Grind CircuitShape SlotTrace SlotMatrix SlotEmission SlotNative RowSoundness
open FullMatrix (evalLinear)
attribute [local instance] Ring.intCast Semiring.natCast

theorem chosen_constant : SlotBytes.chosenWasm ⟨3, by decide⟩ = literal 65 :: SlotRow.constBytes.toList := by
  native_decide

theorem other_wasm_certificate : ∀ kind : Fin 10, kind.val ≠ 3 →
    RowMatrix.polynomialListEqual (SlotBytes.chosenWasm kind)
      (literalBytes (WasmEncoding.encodeOp (operation kind (0#32)))) = true := by native_decide

theorem chosen_wasm {F : Type} [Field F] (ctx : Lean.RArray F) (holds : SlotRow.FieldHolds ctx.get)
    (kind : Fin 10) :
    (SlotBytes.chosenWasm kind).map (evalField ctx.get) =
      (WasmEncoding.encodeOp (operation kind (SlotImmediate.immediate ctx.get))).map
        (fun byte => (byte.toNat : F)) := by
  by_cases constant : kind.val = 3
  · have sameKind : kind = (⟨3, by decide⟩ : Fin 10) := Fin.ext constant
    rw [sameKind, chosen_constant]
    have payload := SlotBytes.constant_payload ctx.get holds
    rw [← SlotBytes.constant_payload_is_leb] at payload
    simp only [List.map_map, Function.comp_def] at payload
    change evalField ctx.get (literal 65) :: _ = ((0x41 : BitVec 8).toNat : F) :: _
    rw [eval_literal]
    exact congrArg (List.cons ((65 : Nat) : F)) payload
  · have result := RowMatrix.polynomial_list_sound ctx _ _ (other_wasm_certificate kind constant)
    rw [result, other_operation kind constant (SlotImmediate.immediate ctx.get)]
    simp only [literalBytes, List.map_map, Function.comp_def, eval_literal]

noncomputable def wasmAt {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) : List F :=
  if bound : index < 16 then ((infoAt ⟨index, bound⟩).outputs.toList.drop 9 |>.take 6).map (evalLinear ctx.get) else []

noncomputable def wasmSuffix {F : Type} [CommRing F] (ctx : Lean.RArray F) : Nat → Nat → List F
  | _, 0 => []
  | index, count+1 => wasmAt ctx index ++ wasmSuffix ctx (index+1) count

theorem row_wasm_outputs {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Fin 16)
    (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    wasmAt ctx index.val = SlotRow.wasmBytes.map (evalField (rowContext ctx (infoAt index)).get) := by
  have equation := (full_row_equations ctx (infoAt index) (info_member index) one holds).2
  have selected := congrArg (fun xs : List F => (xs.drop 9).take 6) equation
  have depths : (SlotRow.nextDepths.map (evalField (rowContext ctx (infoAt index)).get)).length = 9 := by
    simp [SlotRow.nextDepths]
  have wasm : (SlotRow.wasmBytes.map (evalField (rowContext ctx (infoAt index)).get)).length = 6 := by
    simp [SlotRow.wasmBytes]
  rw [SlotRow.outputs, List.append_assoc, List.map_append, List.drop_left' depths,
    List.map_append, List.take_left' wasm] at selected
  simpa only [wasmAt, dite_eq_left index.isLt, List.map_take, List.map_drop] using selected

theorem selected_wasm_row {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (index : Fin 16) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) (kind : Fin 10) (height : Fin 9)
    (input : AtDepth ctx index.val height) (selected : SelectorAt ctx index.val kind) :
    wasmAt ctx index.val =
      (WasmEncoding.encodeOp (operation kind (immediateAt ctx index.val))).map (fun byte => (byte.toNat : F)) := by
  have equations := (full_row_equations ctx (infoAt index) (info_member index) one holds).1
  have input' : inputDepths ctx (infoAt index) = depthVector height.val := by
    simpa only [AtDepth, dite_eq_left index.isLt] using input
  have prior := encoded_input ctx _ (instance_checked _ (info_member index)).1 height.val input'
  have picked : ∀ i, i < 10 → (rowContext ctx (infoAt index)).get (9+i) = if i = kind.val then 1 else 0 := by
    simpa only [SelectorAt, dite_eq_left index.isLt] using selected
  rw [row_wasm_outputs ctx index one holds, SlotBytes.wasm_selected _ kind height prior picked]
  simpa only [immediateAt, dite_eq_left index.isLt] using chosen_wasm (rowContext ctx (infoAt index)) equations kind

theorem body_emission {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get)
    (kinds : List (Fin 10)) : ∀ (start : Nat) (height : Fin 9), start+kinds.length ≤ 16 →
      AtDepth ctx start height → SelectedProgram ctx start kinds →
      wasmSuffix ctx start kinds.length =
        ((SlotProgram.operations (immediateAt ctx) start kinds).flatMap WasmEncoding.encodeOp).map
          (fun byte => (byte.toNat : F)) := by
  induction kinds with
  | nil => intro start height _ _ _; rfl
  | cons kind rest ih =>
    intro start height bounded input selected
    have bound : start < 16 := by simp only [List.length_cons] at bounded; omega
    obtain ⟨_, next, _, nextInput⟩ :=
      selected_advance ctx ⟨start, bound⟩ one holds kind height input selected.1
    have head := selected_wasm_row ctx ⟨start, bound⟩ one holds kind height input selected.1
    have tail := ih (start+1) next (by simp only [List.length_cons] at bounded; omega) nextInput selected.2
    simp only [List.length_cons, wasmSuffix, SlotProgram.operations, List.flatMap_cons, List.map_append]
    change wasmAt ctx start ++ wasmSuffix ctx (start+1) rest.length =
      (WasmEncoding.encodeOp (operation kind (immediateAt ctx start))).map (fun byte => (byte.toNat : F)) ++ _
    rw [head, tail]

def wasmLinearAt (index : Nat) : List Linear :=
  if bound : index < 16 then (infoAt ⟨index, bound⟩).outputs.toList.drop 9 |>.take 6 else []

def wasmLinearSuffix : Nat → Nat → List Linear
  | _, 0 => []
  | index, count+1 => wasmLinearAt index ++ wasmLinearSuffix (index+1) count

def wasmHeader : List Linear := modulePrefix.toList.map (fun byte => constant (Int.ofNat byte))
def wasmLinears : List Linear := wasmHeader ++ wasmLinearSuffix 0 16 ++ [constant 11]

theorem wasm_length : wasmLinears.length = 132 := by native_decide

theorem header_bytes : wasmHeader =
    WasmEncoding.header.map (fun byte => constant (Int.ofNat byte.toNat)) := by native_decide

theorem eval_wasm_suffix {F : Type} [CommRing F] (ctx : Lean.RArray F) (count start : Nat) :
    (wasmLinearSuffix start count).map (evalLinear ctx.get) = wasmSuffix ctx start count := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih =>
    simp only [wasmLinearSuffix, List.map_append, wasmSuffix, ih]
    congr 1
    unfold wasmLinearAt wasmAt
    split <;> rfl

theorem wasm_emission_for {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get)
    (kinds : List (Fin 10)) (length : kinds.length = 16) (selected : SelectedProgram ctx 0 kinds) :
    wasmLinears.map (evalLinear ctx.get) =
      (WasmEncoding.encodeWasm (SlotProgram.operations (immediateAt ctx) 0 kinds)).map (fun byte => (byte.toNat : F)) := by
  have initial : AtDepth ctx 0 ⟨0, by decide⟩ := by simpa [AtDepth] using initial_depth ctx one
  have body := body_emission ctx one holds kinds 0 ⟨0, by decide⟩ (by omega) initial selected
  rw [length] at body
  simp only [wasmLinears, List.map_append, header_bytes, eval_constant_bytes ctx one, eval_wasm_suffix,
    body, WasmEncoding.encodeWasm, List.map_append, List.map_cons, List.map_nil, SlotTrace.eval_constant ctx one]
  rw [show ((11 : Int) : F) = ((11 : Nat) : F) from Ring.intCast_natCast 11]
  rfl

#print axioms wasm_emission_for

end ZkBuild.SlotWasm
