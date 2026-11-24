import ByteCompileBridgeWitness
import SlotCompleteness

/- Constructive completeness of the bounded ordinary-byte compilation
   relation. The sources and semantic bridge are independently constructed;
   only the final constant-product wires are added here. -/
namespace ZkBuild.ByteCompileCompleteness

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
open ByteCompileDecodeTrace ByteCompileSourceWitness SlotCheckedTrace
attribute [local instance] Ring.intCast Semiring.natCast

def slots {F : Type} [CommRing F] (ops : List Op) : Nat → F :=
  SlotWitness.moduleValues (SlotModuleCompleteness.publicValues (actionsFor ops) (heightsFor ops))
    (actionsFor ops) (heightsFor ops)

def binding {F : Type} [CommRing F] (ops : List Op) (index : Nat) : F :=
  if bound : index < 16 then
    let action := actionsFor ops ⟨index, bound⟩
    if action.1.val = 3 then (action.2.toNat : F) else 0
  else 0

def values {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) : Nat → F :=
  ByteCompileBridgeWitness.values wasm (slots ops) (binding ops)

theorem slots_one {F : Type} [CommRing F] (ops : List Op) : slots (F := F) ops 0 = 1 := by
  simp [slots, SlotWitness.moduleValues]

theorem slot_context {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) :
    slotContext (values (F := F) wasm ops) = SlotCompleteness.witnessContext ops := by
  rw [values, ByteCompileBridgeWitness.values, ByteCompileMerge.slot_context _ _ _ (slots_one ops)]
  rfl

theorem slots_hold {F : Type} [CommRing F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) : Satisfied SlotShape.compileShape (slots (F := F) ops) := by
  apply bounded_satisfied SlotShape.compileShape sources_bounded.2 (SlotCompleteness.witnessContext ops).get
    (slots ops) _ (SlotCheckedTrace.checked_program_matrix ops length checked)
  intro k bound
  have size := SlotShape.compile_dimensions.1
  exact SlotWitness.module_entry _ _ _ k (by omega)

theorem selected {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    SlotTrace.SelectorAt (slotContext (values (F := F) wasm ops)) i.val (actionsFor ops i).1 := by
  rw [slot_context]
  exact SlotCompleteness.selector_matches ops length checked i

theorem immediate {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    evalLinear (values (F := F) wasm ops) (ByteCompileSlotBinding.valueLinear i) =
      ((actionsFor ops i).2.toNat : F) := by
  have one : (slotContext (values (F := F) wasm ops)).get 0 = 1 := by
    rw [slot_context]
    exact SlotWitness.module_one _ _ _
  have holds : Satisfied SlotShape.compileShape (slotContext (values (F := F) wasm ops)).get := by
    rw [slot_context]
    exact SlotCheckedTrace.checked_program_matrix ops length checked
  rw [ByteCompileSlotBinding.immediate_value_from_slot _ one holds, slot_context,
    SlotCompleteness.immediate_matches ops length checked i]

theorem constant_selector {F : Type} [CommRing F]
    (wasm : List (Fin 256)) (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    evalLinear (values (F := F) wasm ops) (ByteCompileSlotBinding.booleanLinear i 3) =
      if 3 = (actionsFor ops i).1.val then 1 else 0 := by
  rw [ByteCompileSlotBinding.boolean_value _ i ⟨3, by decide⟩]
  have selectors := selected (F := F) wasm ops length checked i
  unfold SlotTrace.SelectorAt at selectors
  rw [dite_eq_left i.isLt] at selectors
  change ∀ j, j < 10 → (SlotMatrix.rowContext (slotContext (values (F := F) wasm ops))
    (ByteCompileSlotBinding.sourceInfo i)).get (9+j) = if j = (actionsFor ops i).1.val then 1 else 0 at selectors
  exact selectors 3 (by decide)

theorem product_wires {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    values (F := F) wasm ops (21261+i.val) =
      evalLinear (values wasm ops) (ByteCompileSlotBinding.booleanLinear i 3) *
        evalLinear (values wasm ops) (ByteCompileSlotBinding.valueLinear i) := by
  have assigned : values (F := F) wasm ops (21261+i.val) = binding ops i.val :=
    ByteCompileBridgeWitness.binding_value wasm (slots ops) (binding ops) i
  rw [assigned, constant_selector wasm ops length checked i, immediate wasm ops length checked i]
  by_cases constant : (actionsFor ops i).1.val = 3
  · simp [binding, i.isLt, constant, Semiring.one_mul]
  · simp [binding, i.isLt, constant, Ne.symm constant, Semiring.zero_mul]

theorem action_at (ops : List Op) (length : ops.length = 16) (i : Fin 16) :
    SlotNative.operation (actionsFor ops i).1 (actionsFor ops i).2 = ops[i.val]'(by omega) := by
  have bound : i.val < ops.length := by omega
  simp only [actionsFor, List.getElem?_eq_getElem bound, Option.getD_some]
  exact action_operation _

theorem token_wires {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (i : Fin 16) :
    let ops := ByteCompileSoundness.paddedProgram final.operations
    values (F := F) wasm ops (21245+i.val) =
      evalLinear (values wasm ops) (ByteCompileSlotBinding.kindLinear i) +
        (16 : F) * values wasm ops (21261+i.val) := by
  dsimp only
  let ops := ByteCompileSoundness.paddedProgram final.operations
  have length : ops.length = 16 := ByteCompileSoundness.padded_length _
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.2
  have checked : checkProgram ops 0 = some 1 := ByteCompileTyping.decoded_program_checked wasm final accepted
  have queued := ByteCompileBridgeWitness.final_token (F := F) wasm final accepted (slots ops) (binding ops) i
  change values wasm ops (21245+i.val) = (ByteCompileQueue.token (ops[i.val]'(by omega)) : F) at queued
  have product : values (F := F) wasm ops (21261+i.val) = binding ops i.val :=
    ByteCompileBridgeWitness.binding_value wasm (slots ops) (binding ops) i
  rw [queued, ByteCompileSlotBinding.selected_kind _ i (actionsFor ops i).1 (selected wasm ops length checked i), product,
    ← action_at ops length i, ByteCompileEvents.operation_token]
  have coefficient : ((16 : Nat) : F) = (16 : F) :=
    (Ring.intCast_natCast 16).symm.trans (Ring.intCast_ofNat 16)
  by_cases constant : (actionsFor ops i).1.val = 3
  · simp only [constant, ite_true, Semiring.natCast_add, Semiring.natCast_mul,
      binding, i.isLt, dite_true, coefficient]
  · simp only [constant, ite_false, binding, i.isLt, dite_true,
      Semiring.mul_zero, Semiring.add_zero]

theorem matrix_complete {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) :
    Satisfied ByteCompileShape.shape (values (F := F) wasm (ByteCompileSoundness.paddedProgram final.operations)) := by
  let ops := ByteCompileSoundness.paddedProgram final.operations
  have info := ByteCompileTyping.accepted_decoder wasm final accepted
  have length : ops.length = 16 := ByteCompileSoundness.padded_length _ info.2.2
  have checked : checkProgram ops 0 = some 1 := ByteCompileTyping.decoded_program_checked wasm final accepted
  exact ByteCompileAssembly.complete (source wasm) (slots ops) (ByteCompileBridgeWitness.tailValues wasm (binding ops))
    (source_one wasm) (slots_one ops) (source_holds wasm info.1) (slots_hold ops length checked)
    (ByteCompileBridgeWitness.rows_hold wasm final accepted (slots ops) (binding ops))
    (product_wires wasm ops length checked) (token_wires wasm final accepted)

theorem source_entry {F : Type} [CommRing F] (wasm : List (Fin 256)) (k : Nat) (bound : k < 6096) :
    (BinaryCompleteness.witnessContext (F := F) wasm).get k = source wasm k :=
  BodyCompleteness.module_context_entry _ _ _ k bound

theorem slot_entry {F : Type} [CommRing F] (ops : List Op) (k : Nat) (bound : k < 11899) :
    (SlotCompleteness.witnessContext (F := F) ops).get k = slots ops k :=
  SlotWitness.module_entry _ _ _ k bound

theorem public_raw {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) :
    PublicRaw (values (F := F) wasm ops) wasm := by
  have copied (i : Fin 7) : values (F := F) wasm ops (1+i.val) = source wasm (1+i.val) :=
    ByteCompileMerge.public_byte _ _ _ i
  constructor
  · have first : values (F := F) wasm ops 1 = source wasm 1 := copied ⟨0, by decide⟩
    rw [first, ← source_entry wasm 1 (by decide)]
    exact BinaryCompleteness.public_length wasm.length (BinarySoundness.paddedBytes wasm)
      (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm))
  · intro i
    have index : 1+(1+i.val) = 2+i.val := by omega
    have value := copied ⟨1+i.val, by omega⟩
    simp only [index] at value
    rw [value, ← source_entry wasm (2+i.val) (by omega)]
    exact BinaryCompleteness.public_bytes wasm.length (BinarySoundness.paddedBytes wasm)
      (BinaryCompleteness.statesFor (BinarySoundness.paddedBytes wasm)) i

theorem public_native {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) :
    PublicNative (values (F := F) wasm ops) ((Rv32Compiler.compileBytes ops).map SlotNativeBinding.asByte) := by
  intro i
  have copied : values (F := F) wasm ops (8+i.val) = slots ops (6+i.val) :=
    ByteCompileMerge.public_native _ _ _ i
  rw [copied, ← slot_entry ops (6+i.val) (by omega)]
  exact (SlotCompleteness.compilation_complete ops length checked).2.2.1 i

theorem binary_complete {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) :
    let ops := ByteCompileSoundness.paddedProgram final.operations
    let witness := values (F := F) wasm ops
    witness 0 = 1 ∧ PublicRaw witness wasm ∧
      PublicNative witness ((Rv32Compiler.compileBytes ops).map SlotNativeBinding.asByte) ∧
      Satisfied ByteCompileShape.shape witness := by
  dsimp only
  have length := ByteCompileSoundness.padded_length final.operations
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.2
  have checked := ByteCompileTyping.decoded_program_checked wasm final accepted
  have one : values (F := F) wasm (ByteCompileSoundness.paddedProgram final.operations) 0 = 1 :=
    ByteCompileMerge.one (source wasm) (slots (ByteCompileSoundness.paddedProgram final.operations))
      (ByteCompileBridgeWitness.tailValues wasm (binding (ByteCompileSoundness.paddedProgram final.operations)))
  exact ⟨one, public_raw wasm _, public_native wasm _ length checked, matrix_complete wasm final accepted⟩

theorem binary_witness_exists {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) :
    ∃ witness : Nat → F, witness 0 = 1 ∧ PublicRaw witness wasm ∧
      PublicNative witness ((Rv32Compiler.compileBytes (ByteCompileSoundness.paddedProgram final.operations)).map SlotNativeBinding.asByte) ∧
      Satisfied ByteCompileShape.shape witness :=
  ⟨values wasm (ByteCompileSoundness.paddedProgram final.operations), binary_complete wasm final accepted⟩

theorem binary_relation_iff {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm native : List (Fin 256)) (wasmLength : 36 ≤ wasm.length ∧ wasm.length ≤ 156)
    (nativeLength : native.length = 144) :
    (∃ witness : Nat → F, witness 0 = 1 ∧ PublicRaw witness wasm ∧ PublicNative witness native ∧
      Satisfied ByteCompileShape.shape witness) ↔
    (∃ final : Configuration, ByteCompileSoundness.decodeBinary wasm = some final ∧
      native = (Rv32Compiler.compileBytes (ByteCompileSoundness.paddedProgram final.operations)).map SlotNativeBinding.asByte) := by
  constructor
  · rintro ⟨witness, one, raw, emitted, holds⟩
    obtain ⟨final, decoded, _, equal⟩ :=
      ByteCompileSoundness.binary_compilation witness wasm native wasmLength nativeLength one raw emitted holds
    exact ⟨final, decoded, equal⟩
  · rintro ⟨final, decoded, rfl⟩
    exact binary_witness_exists wasm final decoded

#print axioms matrix_complete
#print axioms binary_complete
#print axioms binary_witness_exists
#print axioms binary_relation_iff

end ZkBuild.ByteCompileCompleteness
