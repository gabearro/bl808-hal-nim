import ByteCompileCompleteness

/- Integer reference witnesses and scalar-field witnesses agree wire by
   wire. This includes public packing and both cached component sources. -/
namespace ZkBuild.ByteCompileCast

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem packed_bytes {F : Type} [CommRing F] (bytes : List (Fin 256)) :
    R1CS.packedField (F := F) bytes = ((R1CS.packedField (F := Int) bytes : Int) : F) := by
  rw [R1CS.packedField_is_natCast, R1CS.packedField_is_natCast, Ring.intCast_natCast]

theorem packed_fields {F : Type} [CommRing F] (integers : List Int) :
    SlotNativeBinding.packFields (integers.map fun n : Int => (n : F)) =
      ((SlotNativeBinding.packFields integers : Int) : F) := by
  induction integers with
  | nil => simp [SlotNativeBinding.packFields, Ring.intCast_zero]
  | cons first rest ih =>
    simp only [List.map_cons, SlotNativeBinding.packFields, ih, Ring.intCast_add, Ring.intCast_mul]
    rw [show ((256 : Int) : F) = (256 : F) from Ring.intCast_ofNat 256]

theorem byte_inputs {F : Type} [CommRing F] (length : Nat) (bytes : Fin 156 → Fin 256) (i : Fin 7) :
    BinaryCompleteness.publicValues (F := F) length bytes i =
      ((BinaryCompleteness.publicValues (F := Int) length bytes i : Int) : F) := by
  by_cases first : i.val = 0
  · simp [BinaryCompleteness.publicValues, first, Ring.intCast_natCast]
  · simp only [BinaryCompleteness.publicValues, first, dite_false]
    exact packed_bytes _

theorem byte_module {F : Type} [CommRing F] (integerInputs : Fin 7 → Int) (fieldInputs : Fin 7 → F)
    (same : ∀ i, fieldInputs i = (integerInputs i : F))
    (bytes : Fin 156 → Fin 256) (states : BodyCompleteness.States) (wire : Nat) :
    BodyCompleteness.moduleValues fieldInputs bytes states wire =
      ((BodyCompleteness.moduleValues integerInputs bytes states wire : Int) : F) := by
  by_cases zero : wire = 0
  · simp [BodyCompleteness.moduleValues, zero, Ring.intCast_one]
  · by_cases publicInput : wire < 8
    · simp only [BodyCompleteness.moduleValues, zero, dite_false, publicInput, dite_true]
      exact same _
    · by_cases bit : wire < 1256
      · simp [BodyCompleteness.moduleValues, zero, publicInput, bit]
      · by_cases auxiliary : wire < 6096
        · simp [BodyCompleteness.moduleValues, zero, publicInput, bit, auxiliary]
        · simp [BodyCompleteness.moduleValues, zero, publicInput, bit, auxiliary, Ring.intCast_zero]

theorem byte_source {F : Type} [CommRing F] (wasm : List (Fin 256)) (wire : Nat) :
    ByteCompileSourceWitness.source (F := F) wasm wire =
      ((ByteCompileSourceWitness.source (F := Int) wasm wire : Int) : F) :=
  byte_module _ _ (byte_inputs wasm.length (BinarySoundness.paddedBytes wasm)) _ _ wire

theorem slot_module {F : Type} [CommRing F] (integerInputs : Fin 10 → Int) (fieldInputs : Fin 10 → F)
    (same : ∀ i, fieldInputs i = (integerInputs i : F))
    (actions : SlotWitness.Actions) (heights : SlotWitness.Heights) (wire : Nat) :
    SlotWitness.moduleValues fieldInputs actions heights wire =
      ((SlotWitness.moduleValues integerInputs actions heights wire : Int) : F) := by
  by_cases zero : wire = 0
  · simp [SlotWitness.moduleValues, zero, Ring.intCast_one]
  · by_cases publicInput : wire < 11
    · simp only [SlotWitness.moduleValues, zero, ite_false, publicInput, dite_true]
      exact same _
    · by_cases auxiliary : wire < 11899
      · simp [SlotWitness.moduleValues, SlotWitness.witnessValue, zero, publicInput, auxiliary]
      · simp [SlotWitness.moduleValues, zero, publicInput, auxiliary, Ring.intCast_zero]

theorem packed_linears {F : Type} [CommRing F] (integers : Nat → Int) (fields : Nat → F)
    (same : ∀ k, fields k = (integers k : F)) (linears : List Linear) (index : Nat) :
    SlotNativeBinding.packFields (SlotNativeBinding.chunk (linears.map (evalLinear fields)) index) =
      ((SlotNativeBinding.packFields (SlotNativeBinding.chunk (linears.map (evalLinear integers)) index) : Int) : F) := by
  have equality : fields = fun k => (integers k : F) := funext same
  have mapped : linears.map (evalLinear fields) = (linears.map (evalLinear integers)).map (fun n : Int => (n : F)) := by
    rw [equality, List.map_map]
    apply List.map_congr_left
    intro linear _
    exact ByteCompileCanonicalRow.linear_cast integers linear
  rw [mapped, ← SlotNativeBinding.chunk_map, packed_fields]

theorem slot_inputs {F : Type} [CommRing F] (actions : SlotWitness.Actions) (heights : SlotWitness.Heights)
    (i : Fin 10) : SlotModuleCompleteness.publicValues (F := F) actions heights i =
      ((SlotModuleCompleteness.publicValues (F := Int) actions heights i : Int) : F) := by
  have same : ∀ k, SlotWitness.moduleValues (fun _ => (0 : F)) actions heights k =
      ((SlotWitness.moduleValues (fun _ => (0 : Int)) actions heights k : Int) : F) :=
    slot_module _ _ (fun _ => (Ring.intCast_zero).symm) actions heights
  by_cases wasm : i.val < 5
  · simp only [SlotModuleCompleteness.publicValues, wasm, ite_true]
    exact packed_linears _ _ same _ _
  · simp only [SlotModuleCompleteness.publicValues, wasm, ite_false]
    exact packed_linears _ _ same _ _

theorem slot_source {F : Type} [CommRing F] (ops : List Op) (wire : Nat) :
    ByteCompileCompleteness.slots (F := F) ops wire =
      ((ByteCompileCompleteness.slots (F := Int) ops wire : Int) : F) :=
  slot_module _ _ (slot_inputs (SlotCheckedTrace.actionsFor ops) (SlotCheckedTrace.heightsFor ops)) _ _ wire

theorem binding_source {F : Type} [CommRing F] (ops : List Op) (wire : Nat) :
    ByteCompileCompleteness.binding (F := F) ops wire =
      ((ByteCompileCompleteness.binding (F := Int) ops wire : Int) : F) := by
  unfold ByteCompileCompleteness.binding
  split
  · dsimp only
    split
    · exact (Ring.intCast_natCast _).symm
    · exact Ring.intCast_zero.symm
  · exact Ring.intCast_zero.symm

theorem merge {F : Type} [CommRing F] (integerBytes integerSlots integerTail : Nat → Int)
    (fieldBytes fieldSlots fieldTail : Nat → F)
    (bytes : ∀ k, fieldBytes k = (integerBytes k : F))
    (slots : ∀ k, fieldSlots k = (integerSlots k : F))
    (tail : ∀ k, fieldTail k = (integerTail k : F)) (wire : Nat) :
    ByteCompileMerge.values fieldBytes fieldSlots fieldTail wire =
      ((ByteCompileMerge.values integerBytes integerSlots integerTail wire : Int) : F) := by
  unfold ByteCompileMerge.values
  split
  · exact Ring.intCast_one.symm
  · split
    · exact bytes _
    · split
      · exact slots _
      · split
        · exact bytes _
        · split
          · exact slots _
          · split
            · exact slots _
            · exact tail _

theorem tail_source {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) :
    ByteCompileBridgeWitness.tailValues (ByteCompileCompleteness.binding (F := F) ops) (wasm := wasm) wire =
      ((ByteCompileBridgeWitness.tailValues (ByteCompileCompleteness.binding (F := Int) ops) (wasm := wasm) wire : Int) : F) := by
  unfold ByteCompileBridgeWitness.tailValues
  split
  · rfl
  · exact binding_source ops _

theorem witness {F : Type} [CommRing F] (wasm : List (Fin 256)) (ops : List Op) (wire : Nat) :
    ByteCompileCompleteness.values (F := F) wasm ops wire =
      ((ByteCompileCompleteness.values (F := Int) wasm ops wire : Int) : F) :=
  merge _ _ _ _ _ _ (byte_source wasm) (slot_source ops) (tail_source wasm ops) wire

#print axioms witness

end ZkBuild.ByteCompileCast
