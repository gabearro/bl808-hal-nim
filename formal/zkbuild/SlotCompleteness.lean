import SlotCheckedTrace

namespace ZkBuild.SlotCompleteness

open Lean.Grind SlotWitness SlotCheckedTrace SlotTrace SlotNativeBinding
attribute [local instance] Ring.intCast Semiring.natCast

noncomputable def witnessContext {F : Type} [CommRing F] (ops : List Op) : Lean.RArray F :=
  SlotModuleCompleteness.context (actionsFor ops) (heightsFor ops)

theorem primary_matches {F : Type} [CommRing F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) (k : Nat) (bound : k < 72) :
    (SlotMatrix.rowContext (witnessContext (F := F) ops) (infoAt i)).get k =
      (SlotRowCompleteness.context (actionsFor ops i).1 (before (heightsFor ops) i) (actionsFor ops i).2).get k := by
  have trace := checked_trace ops length checked
  have valid := (trace.2.2 i).1
  have incoming := (constructed_all_rows
    (SlotModuleCompleteness.publicValues (F := F) (actionsFor ops) (heightsFor ops))
    (actionsFor ops) (heightsFor ops) trace).2.2 i
  have sourceBound : SlotRow.sourceWire k < 753 := by
    have bound78 := SlotRowCompleteness.source_bounds ⟨k, bound⟩
    rw [SlotRowCompleteness.input_size] at bound78
    change SlotRow.sourceWire k < 78 at bound78
    omega
  unfold witnessContext SlotModuleCompleteness.context
  rw [← SlotMatrix.context_sources _ _ k bound]
  rw [local_values_match _ _ _ i valid incoming (SlotRow.sourceWire k) sourceBound]
  exact (SlotRowCompleteness.canonical_row_holds (F := F) (actionsFor ops i).1
    (before (heightsFor ops) i) (actionsFor ops i).2 valid).2.1 k bound

theorem immediate_congr {F : Type} [CommRing F] (a b : Nat → F)
    (same : ∀ i, i < 32 → a (19+i) = b (19+i)) : SlotImmediate.immediate a = SlotImmediate.immediate b := by
  apply congrArg (BitVec.ofNat 32)
  unfold SlotImmediate.packNat
  apply congrArg List.sum
  apply List.map_congr_left
  intro i member
  dsimp only [SlotImmediate.immediateBits]
  unfold SlotImmediate.decodedBit
  rw [same (0+i) (by have := List.mem_range.mp member; omega)]

theorem canonical_immediate {F : Type} [Field F] (kind : Fin 10) (height : Fin 9) (value : Word) :
    SlotImmediate.immediate (SlotRowCompleteness.context (F := F) kind height value).get = value := by
  have bits (i : Nat) (bound : i < 32) :
      SlotImmediate.decodedBit (SlotRowCompleteness.context (F := F) kind height value).get (19+i) = value.getLsbD i := by
    unfold SlotImmediate.decodedBit
    rw [SlotRowCompleteness.immediate_values kind height value i bound]
    cases value.getLsbD i <;> simp [Semiring.natCast_zero, Semiring.natCast_one, Field.zero_ne_one]
  apply BitVec.eq_of_toNat_eq
  rw [SlotImmediate.immediate_toNat]
  have packed : SlotImmediate.packNat
      (SlotImmediate.immediateBits (SlotRowCompleteness.context (F := F) kind height value).get) 0 32 =
      SlotImmediate.packNat value.getLsbD 0 32 := by
    unfold SlotImmediate.packNat
    apply congrArg List.sum
    apply List.map_congr_left
    intro i member
    simp only [Nat.zero_add, SlotImmediate.immediateBits, bits i (List.mem_range.mp member)]
  rw [packed, SlotRowCompleteness.pack_word_bits]
  have whole : value.extractLsb' 0 32 = value := by bv_decide
  rw [whole]

theorem immediate_matches {F : Type} [Field F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    SlotEmission.immediateAt (witnessContext (F := F) ops) i.val = (actionsFor ops i).2 := by
  change (if bound : i.val < 16 then SlotImmediate.immediate
    (SlotMatrix.rowContext (witnessContext ops) (infoAt ⟨i.val, bound⟩)).get else 0#32) = _
  rw [dite_eq_left i.isLt]
  rw [immediate_congr _ (SlotRowCompleteness.context (actionsFor ops i).1 (before (heightsFor ops) i) (actionsFor ops i).2).get
    (fun j bound => primary_matches ops length checked i (19+j) (by omega))]
  exact canonical_immediate _ _ _

theorem selector_matches {F : Type} [CommRing F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) (i : Fin 16) :
    SelectorAt (witnessContext (F := F) ops) i.val (actionsFor ops i).1 := by
  unfold SelectorAt
  rw [dite_eq_left i.isLt]
  intro j bound
  rw [primary_matches ops length checked i (9+j) (by omega)]
  exact SlotRowCompleteness.selected_values _ _ _ j bound

theorem selected_list {F : Type} [CommRing F] (ctx : Lean.RArray F) (kinds : List (Fin 10)) :
    ∀ start, (∀ i (bound : i < kinds.length), SelectorAt ctx (start+i) kinds[i]) → SelectedProgram ctx start kinds := by
  induction kinds with
  | nil => intro start selected; trivial
  | cons kind rest ih =>
    intro start selected
    constructor
    · have head := selected 0 (by simp)
      change SelectorAt ctx (start+0) kind at head
      simpa only [Nat.add_zero] using head
    · apply ih (start+1)
      intro i bound
      have head := selected (i+1) (by simp only [List.length_cons]; omega)
      simpa only [List.getElem_cons_succ, show start+1+i = start+(i+1) by omega] using head

def kindsFor (ops : List Op) : List (Fin 10) := ops.map (fun op => (actionFor op).1)

theorem program_selected {F : Type} [CommRing F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) : SelectedProgram (witnessContext (F := F) ops) 0 (kindsFor ops) := by
  apply selected_list
  intro i bound
  have opBound : i < ops.length := by simpa [kindsFor] using bound
  have small : i < 16 := by omega
  have selected := selector_matches (F := F) ops length checked ⟨i, small⟩
  simpa only [kindsFor, List.getElem_map, Nat.zero_add, actionsFor,
    List.getElem?_eq_getElem opBound, Option.getD_some] using selected

theorem operations_get (values : Nat → Word) (kinds : List (Fin 10)) : ∀ start i (bound : i < kinds.length),
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

theorem program_recovered {F : Type} [Field F] (ops : List Op) (length : ops.length = 16)
    (checked : checkProgram ops 0 = some 1) :
    SlotProgram.operations (SlotEmission.immediateAt (witnessContext (F := F) ops)) 0 (kindsFor ops) = ops := by
  apply List.ext_getElem
  · simp [SlotProgram.operations_length, kindsFor]
  · intro i left right
    have small : i < 16 := by omega
    rw [operations_get _ _ 0 i (by simpa only [kindsFor, List.length_map] using right)]
    simp only [kindsFor, List.getElem_map, Nat.zero_add]
    rw [immediate_matches ops length checked ⟨i, small⟩]
    have action : actionsFor ops ⟨i, small⟩ = actionFor ops[i] := by
      simp only [actionsFor, List.getElem?_eq_getElem right, Option.getD_some]
    rw [action, action_operation]

theorem compilation_complete {F : Type} [Field F] [IsCharP F scalarModulus]
    (ops : List Op) (length : ops.length = 16) (checked : checkProgram ops 0 = some 1) :
    let ctx := witnessContext (F := F) ops
    ctx.get 0 = 1 ∧
      SlotCompilation.PublicWasm ctx ((WasmEncoding.encodeWasm ops).map asByte) ∧
      PublicNative ctx ((Rv32Compiler.compileBytes ops).map asByte) ∧
      CircuitShape.Satisfied SlotShape.compileShape ctx.get := by
  dsimp only
  let ctx := witnessContext (F := F) ops
  have one : ctx.get 0 = 1 := module_one _ _ _
  have holds : CircuitShape.Satisfied SlotShape.compileShape ctx.get := checked_program_matrix ops length checked
  have count : (kindsFor ops).length = 16 := by simpa [kindsFor] using length
  have selected := program_selected (F := F) ops length checked
  have recovered := program_recovered (F := F) ops length checked
  have wasm := SlotWasm.wasm_emission_for ctx one holds (kindsFor ops) count selected
  have native := SlotEmission.native_emission_for ctx one holds (kindsFor ops) count selected
  rw [recovered] at wasm native
  have mapped (bytes : List (BitVec 8)) : bytes.map (fun b => (b.toNat : F)) =
      (bytes.map asByte).map (fun b => (b.val : F)) := by
    simp only [List.map_map, Function.comp_def, asByte]
  refine ⟨one, ?_, ?_, holds⟩
  · intro index
    have packing := SlotCompilation.wasm_packing_constraint ctx index one holds
    rw [wasm, mapped, ← chunk_map, pack_byte_fields] at packing
    exact packing.symm
  · intro index
    have packing := packing_constraint ctx index one holds
    rw [native, mapped, ← chunk_map, pack_byte_fields] at packing
    exact packing.symm

#print axioms compilation_complete

end ZkBuild.SlotCompleteness
