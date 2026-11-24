import SlotNative

namespace ZkBuild.SlotEmission

open Lean.Grind CircuitShape SlotTrace SlotMatrix SlotNative
open FullMatrix (evalLinear)
attribute [local instance] Ring.intCast Semiring.natCast

noncomputable def immediateAt {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) : Word :=
  if bound : index < 16 then SlotImmediate.immediate (rowContext ctx (infoAt ⟨index, bound⟩)).get else 0#32

noncomputable def nativeAt {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) : List F :=
  if bound : index < 16 then ((infoAt ⟨index, bound⟩).outputs.toList.drop 15).map (evalLinear ctx.get) else []

noncomputable def nativeSuffix {F : Type} [CommRing F] (ctx : Lean.RArray F) : Nat → Nat → List F
  | _, 0 => []
  | index, count+1 => nativeAt ctx index ++ nativeSuffix ctx (index+1) count

theorem row_native_outputs {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Fin 16)
    (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    nativeAt ctx index.val = SlotRow.nativeBytes.map (RowSoundness.evalField (rowContext ctx (infoAt index)).get) := by
  have equation := (full_row_equations ctx (infoAt index) (info_member index) one holds).2
  have dropped := congrArg (List.drop 15) equation
  have length : ((SlotRow.nextDepths ++ SlotRow.wasmBytes).map
      (RowSoundness.evalField (rowContext ctx (infoAt index)).get)).length = 15 := by
    simp [SlotRow.nextDepths, SlotRow.wasmBytes]
  rw [SlotRow.outputs, List.map_append, List.drop_left' length] at dropped
  simpa only [nativeAt, dite_eq_left index.isLt, List.map_drop] using dropped

theorem selected_advance {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (index : Fin 16) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) (kind : Fin 10) (height : Fin 9)
    (input : AtDepth ctx index.val height) (selected : SelectorAt ctx index.val kind) :
    SlotShape.valid kind.val height.val = true ∧
      ∃ next : Fin 9, next.val = SlotShape.nextDepth kind.val height.val ∧ AtDepth ctx (index.val+1) next := by
  have equations := (full_row_equations ctx (infoAt index) (info_member index) one holds).1
  have input' : inputDepths ctx (infoAt index) = depthVector height.val := by
    simpa only [AtDepth, dite_eq_left index.isLt] using input
  have prior := encoded_input ctx _ (instance_checked _ (info_member index)).1 height.val input'
  have picked : ∀ i, i < 10 → (rowContext ctx (infoAt index)).get (9+i) = if i = kind.val then 1 else 0 := by
    simpa only [SelectorAt, dite_eq_left index.isLt] using selected
  have valid := SlotRow.valid_transition (rowContext ctx (infoAt index)) kind height prior picked equations
  let next : Fin 9 := ⟨SlotShape.nextDepth kind.val height.val, next_depth_bounded kind height valid⟩
  refine ⟨valid, next, rfl, ?_⟩
  apply advance_depth ctx index.val index.isLt next
  rw [output_prefix ctx _ (full_row_equations ctx _ (info_member index) one holds).2,
    SlotRow.depths_determined _ kind height prior picked, depth_encoding kind height valid]

theorem selected_native_row {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (index : Fin 16) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) (kind : Fin 10) (height : Fin 9)
    (input : AtDepth ctx index.val height) (selected : SelectorAt ctx index.val kind)
    (valid : SlotShape.valid kind.val height.val = true) :
    nativeAt ctx index.val =
      (encodedOperation height.val (operation kind (immediateAt ctx index.val))).map
        (fun byte => (byte.toNat : F)) := by
  have equations := (full_row_equations ctx (infoAt index) (info_member index) one holds).1
  have input' : inputDepths ctx (infoAt index) = depthVector height.val := by
    simpa only [AtDepth, dite_eq_left index.isLt] using input
  have prior := encoded_input ctx _ (instance_checked _ (info_member index)).1 height.val input'
  have picked : ∀ i, i < 10 → (rowContext ctx (infoAt index)).get (9+i) = if i = kind.val then 1 else 0 := by
    simpa only [SelectorAt, dite_eq_left index.isLt] using selected
  rw [row_native_outputs ctx index one holds]
  simpa only [immediateAt, dite_eq_left index.isLt] using
    native_row_bytes (rowContext ctx (infoAt index)) equations kind height prior picked valid

theorem body_emission {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get)
    (kinds : List (Fin 10)) : ∀ (start : Nat) (height : Fin 9), start+kinds.length ≤ 16 →
      AtDepth ctx start height → SelectedProgram ctx start kinds →
      nativeSuffix ctx start kinds.length =
        ((Rv32Compiler.emitBody (SlotProgram.operations (immediateAt ctx) start kinds) height.val).flatMap
          (fun instruction => Rv32Encoding.wordBytes (Rv32Encoding.encode instruction))).map
            (fun byte => (byte.toNat : F)) := by
  induction kinds with
  | nil => intro start height _ _ _; rfl
  | cons kind rest ih =>
    intro start height bounded input selected
    have bound : start < 16 := by simp only [List.length_cons] at bounded; omega
    obtain ⟨valid, next, nextValue, nextInput⟩ :=
      selected_advance ctx ⟨start, bound⟩ one holds kind height input selected.1
    have stepChecked : checkStep (operation kind (immediateAt ctx start)) height.val = some next.val := by
      simp only [operation, SlotProgram.immediate_preserves_check, SlotProgram.kind_step_certificate,
        valid, ite_true, nextValue]
    have nextHeight := Rv32Compiler.checked_height _ _ _ stepChecked
    change Rv32Compiler.nextHeight height.val
      (SlotProgram.withImmediate (SlotProgram.operationKind kind) (immediateAt ctx start)) = next.val at nextHeight
    have head := selected_native_row ctx ⟨start, bound⟩ one holds kind height input selected.1 valid
    have tail := ih (start+1) next (by simp only [List.length_cons] at bounded; omega) nextInput selected.2
    simp only [List.length_cons, nativeSuffix, SlotProgram.operations, Rv32Compiler.emitBody,
      List.flatMap_append, List.map_append]
    change nativeAt ctx start ++ nativeSuffix ctx (start+1) rest.length =
      (encodedOperation height.val (operation kind (immediateAt ctx start))).map (fun byte => (byte.toNat : F)) ++ _
    rw [head, tail, nextHeight]

theorem full_body_emission {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ kinds : List (Fin 10), kinds.length = 16 ∧
      checkProgram (SlotProgram.operations (immediateAt ctx) 0 kinds) 0 = some 1 ∧
      nativeSuffix ctx 0 16 =
        ((Rv32Compiler.emitBody (SlotProgram.operations (immediateAt ctx) 0 kinds) 0).flatMap
          (fun instruction => Rv32Encoding.wordBytes (Rv32Encoding.encode instruction))).map
            (fun byte => (byte.toNat : F)) := by
  obtain ⟨kinds, length, checked, selected⟩ := full_stack_trace ctx one holds
  have initial : AtDepth ctx 0 ⟨0, by decide⟩ := by
    simpa [AtDepth] using initial_depth ctx one
  have body := body_emission ctx one holds kinds 0 ⟨0, by decide⟩ (by omega) initial selected
  exact ⟨kinds, length, SlotProgram.kind_program_refines (immediateAt ctx) kinds 0 ⟨0, by decide⟩ 1 checked,
    by simpa only [length] using body⟩

def nativeLinearAt (index : Nat) : List Linear :=
  if bound : index < 16 then (infoAt ⟨index, bound⟩).outputs.toList.drop 15 else []

def nativeLinearSuffix : Nat → Nat → List Linear
  | _, 0 => []
  | index, count+1 => nativeLinearAt index ++ nativeLinearSuffix (index+1) count

def nativeHeader : List Linear :=
  (SlotShape.wordBytes (SlotShape.addi 28 10) ++ SlotShape.wordBytes (SlotShape.addi 29 11)).toList

def nativeTrailer : List Linear :=
  (SlotShape.wordBytes (SlotShape.addi 10 (SlotShape.register 0)) ++ SlotShape.wordBytes 0x00008067).toList

def nativeLinears : List Linear := nativeHeader ++ nativeLinearSuffix 0 16 ++ nativeTrailer

theorem native_length : nativeLinears.length = 144 := by native_decide

theorem header_bytes : nativeHeader =
    (Rv32Compiler.prologue.flatMap (fun instruction => Rv32Encoding.wordBytes (Rv32Encoding.encode instruction))).map
      (fun byte => constant (Int.ofNat byte.toNat)) := by native_decide

theorem trailer_bytes : nativeTrailer =
    ((Rv32Compiler.epilogue.flatMap (fun instruction => Rv32Encoding.wordBytes (Rv32Encoding.encode instruction))) ++
      Rv32Encoding.wordBytes Rv32Encoding.returnWord).map (fun byte => constant (Int.ofNat byte.toNat)) := by native_decide

theorem eval_constant_bytes {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1)
    (bytes : List (BitVec 8)) :
    (bytes.map (fun byte => constant (Int.ofNat byte.toNat))).map (evalLinear ctx.get) =
      bytes.map (fun byte => (byte.toNat : F)) := by
  simp only [List.map_map, Function.comp_def, eval_constant ctx one,
    Int.ofNat_eq_natCast, Ring.intCast_natCast]

theorem eval_native_suffix {F : Type} [CommRing F] (ctx : Lean.RArray F) (count start : Nat) :
    (nativeLinearSuffix start count).map (evalLinear ctx.get) = nativeSuffix ctx start count := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih =>
    simp only [nativeLinearSuffix, List.map_append, nativeSuffix, ih]
    congr 1
    unfold nativeLinearAt nativeAt
    split <;> rfl

theorem native_emission_for {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get)
    (kinds : List (Fin 10)) (length : kinds.length = 16) (selected : SelectedProgram ctx 0 kinds) :
    nativeLinears.map (evalLinear ctx.get) =
      (Rv32Compiler.compileBytes (SlotProgram.operations (immediateAt ctx) 0 kinds)).map (fun byte => (byte.toNat : F)) := by
  have initial : AtDepth ctx 0 ⟨0, by decide⟩ := by simpa [AtDepth] using initial_depth ctx one
  have body := body_emission ctx one holds kinds 0 ⟨0, by decide⟩ (by omega) initial selected
  rw [length] at body
  simp only [nativeLinears, List.map_append, header_bytes, trailer_bytes, eval_constant_bytes ctx one,
    eval_native_suffix, body, Rv32Compiler.compileBytes, Rv32Compiler.compile,
    List.map_append, List.flatMap_append, List.flatMap_map]
  simp only [List.append_assoc, List.flatMap_cons, List.flatMap_nil, List.append_nil]

theorem full_native_emission {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ ops : List Op, ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      nativeLinears.map (evalLinear ctx.get) =
        (Rv32Compiler.compileBytes ops).map (fun byte => (byte.toNat : F)) := by
  obtain ⟨kinds, length, checked, body⟩ := full_body_emission ctx one holds
  let ops := SlotProgram.operations (immediateAt ctx) 0 kinds
  refine ⟨ops, ?_, checked, ?_⟩
  · simpa only [ops, SlotProgram.operations_length] using length
  · dsimp only [ops]
    simp only [nativeLinears, List.map_append, header_bytes, trailer_bytes, eval_constant_bytes ctx one,
      eval_native_suffix, body, Rv32Compiler.compileBytes, Rv32Compiler.compile,
      List.map_append, List.flatMap_append, List.flatMap_map]
    simp only [List.append_assoc, List.flatMap_cons, List.flatMap_nil, List.append_nil]

#print axioms full_body_emission
#print axioms full_native_emission

end ZkBuild.SlotEmission
