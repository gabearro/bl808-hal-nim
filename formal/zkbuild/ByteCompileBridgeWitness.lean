import ByteCompileSourceWitness
import ByteCompileAssembly

/- Embed the semantic bridge rows in their actual global wire positions.
   The resulting rows are valid for every accepted binary, independently of
   the emitter witness and the final sixteen product wires. -/
namespace ZkBuild.ByteCompileBridgeWitness

open Lean.Grind CircuitShape FullMatrix ByteCompileSourceWitness
open ByteCompileDecodeTrace ByteCompileConstructionTrace
attribute [local instance] Ring.intCast Semiring.natCast

def tailValues {F : Type} [CommRing F] (wasm : List (Fin 256)) (binding : Nat → F) (k : Nat) : F :=
  if bound : k < 3267 then
    let i : Fin 121 := ⟨k/27, by omega⟩
    (ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) (40+k%27) : F)
  else binding (k-3267)

def values {F : Type} [CommRing F] (wasm : List (Fin 256)) (slots binding : Nat → F) : Nat → F :=
  ByteCompileMerge.values (source wasm) slots (tailValues wasm binding)

theorem binding_value {F : Type} [CommRing F] (wasm : List (Fin 256)) (slots binding : Nat → F)
    (i : Fin 16) : values wasm slots binding (21261+i.val) = binding i.val := by
  have nonzero : 21261+i.val ≠ 0 := by omega
  have b8 : ¬21261+i.val < 8 := by omega
  have b13 : ¬21261+i.val < 13 := by omega
  have b6101 : ¬21261+i.val < 6101 := by omega
  have b6106 : ¬21261+i.val < 6106 := by omega
  have b17994 : ¬21261+i.val < 17994 := by omega
  have offset : 21261+i.val-17994 = 3267+i.val := by omega
  have afterRows : ¬3267+i.val < 3267 := by omega
  simp only [values, ByteCompileMerge.values, nonzero, ite_false, b8, b13, b6101, b6106, b17994,
    offset, tailValues, afterRows, dite_false, Nat.add_sub_cancel_left]

theorem stored_row {F : Type} [CommRing F] (wasm : List (Fin 256)) (slots binding : Nat → F)
    (i : Fin 121) (j : Fin 27) :
    values wasm slots binding (17994+i.val*27+j.val) =
      (ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) (40+j.val) : F) := by
  have lower : ¬17994+i.val*27+j.val < 17994 := by omega
  have notCanonical : ¬17994+i.val*27+j.val < 6106 := by omega
  have notByte : ¬17994+i.val*27+j.val < 6101 := by omega
  have notInput : ¬17994+i.val*27+j.val < 13 := by omega
  have notSmall : ¬17994+i.val*27+j.val < 8 := by omega
  have nonzero : 17994+i.val*27+j.val ≠ 0 := by omega
  have offset : 17994+i.val*27+j.val-17994 = i.val*27+j.val := by omega
  have bound : i.val*27+j.val < 3267 := by omega
  have quotient : (i.val*27+j.val)/27 = i.val := by omega
  have remainder : (i.val*27+j.val)%27 = j.val := by omega
  simp only [values, ByteCompileMerge.values, nonzero, ite_false, notSmall, notInput,
    notByte, notCanonical, lower, offset, tailValues, dite_eq_left bound, quotient, remainder]

theorem stored_immediate {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F) (i : Fin 121) :
    values wasm slots binding (17994+i.val*27+8) = ((cfgAt wasm (i.val+1)).immediate : F) := by
  rw [stored_row wasm slots binding i ⟨8, by decide⟩]
  change (ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) 48 : F) = _
  rw [ByteCompileCanonicalRow.next_immediate _ _ _ (row_step wasm final accepted i)]

theorem stored_queue {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F)
    (i : Fin 121) (j : Fin 16) :
    values wasm slots binding (17994+i.val*27+11+j.val) =
      (((encodedQueue (F := Int) (cfgAt wasm (i.val+1)).operations)[j.val]?).getD 0 : F) := by
  have queue := ByteCompileCanonicalRow.next_queue (cfgAt wasm i.val) (cfgAt wasm (i.val+1)) final
    (byteAt wasm i) ((body wasm).drop (i.val+1)) (row_range wasm final accepted i)
    (row_step wasm final accepted i) (row_suffix wasm final accepted (i.val+1))
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.2
  have point := congrArg (fun xs : List Int => (xs[j.val]?).getD 0) queue
  have localValue : ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) (51+j.val) =
      ((encodedQueue (F := Int) (cfgAt wasm (i.val+1)).operations)[j.val]?).getD 0 := by
    simpa only [ByteCompileCanonicalRow.outputQueue, List.getElem?_ofFn, j.isLt, dite_true, Option.getD_some] using point
  have index : 17994+i.val*27+11+j.val = 17994+i.val*27+(11+j.val) := by omega
  rw [index, stored_row wasm slots binding i ⟨11+j.val, by omega⟩]
  simpa only [show 40+(11+j.val) = 51+j.val by omega] using congrArg (fun n : Int => (n : F)) localValue

theorem final_token {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F) (i : Fin 16) :
    values wasm slots binding (21245+i.val) =
      (ByteCompileQueue.token ((ByteCompileSoundness.paddedProgram final.operations)[i.val]'(by
        rw [ByteCompileSoundness.padded_length _ (ByteCompileTyping.accepted_decoder wasm final accepted).2.2]
        exact i.isLt)) : F) := by
  have point := stored_queue wasm final accepted slots binding ⟨120, by decide⟩ i
  have index : 17994+120*27+11+i.val = 21245+i.val := by omega
  change values wasm slots binding (17994+120*27+11+i.val) = _ at point
  rw [index, show 120+1 = 121 from rfl, decoder_final wasm final accepted,
    ByteCompileSoundness.encoded_padded] at point
  have bound : i.val < (ByteCompileSoundness.paddedProgram final.operations).length := by
    rw [ByteCompileSoundness.padded_length _ (ByteCompileTyping.accepted_decoder wasm final accepted).2.2]
    exact i.isLt
  simpa only [List.getElem?_map, List.getElem?_eq_getElem bound, Option.map_some,
    Option.getD_some, Ring.intCast_natCast] using point

theorem input_immediate {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F) (i : Fin 121) :
    ByteCompileRow.localValues (values wasm slots binding) i 23 = ((cfgAt wasm i.val).immediate : F) := by
  have one : values wasm slots binding 0 = 1 := ByteCompileMerge.one _ _ _
  rw [ByteCompileAccumulator.previous_value (values wasm slots binding) one i]
  by_cases first : i.val = 0
  · simp [ByteCompileAccumulator.valueAt, first, cfgAt, after, ByteCompileDecodeTrace.initial, Ring.intCast_zero]
  · have previous : i.val-1 < 121 := by omega
    have index : (i.val-1)+1 = i.val := by omega
    simp only [ByteCompileAccumulator.valueAt, first, ite_false]
    simpa only [index] using stored_immediate wasm final accepted slots binding ⟨i.val-1, previous⟩

theorem input_queue {F : Type} [CommRing F] (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F)
    (i : Fin 121) (j : Fin 16) :
    ByteCompileRow.localValues (values wasm slots binding) i (24+j.val) =
      (((encodedQueue (F := Int) (cfgAt wasm i.val).operations)[j.val]?).getD 0 : F) := by
  have one : values wasm slots binding 0 = 1 := ByteCompileMerge.one _ _ _
  rw [ByteCompileQueueStep.previous_queue (values wasm slots binding) one i j]
  by_cases first : i.val = 0
  · have empty : (cfgAt wasm i.val).operations = [] := by
      simp [cfgAt, first, after, ByteCompileDecodeTrace.initial]
    have encoded : encodedQueue (F := Int) [] = List.replicate 16 (0 : Int) := by
      simp [encodedQueue, ByteCompileQueue.padded]
    rw [empty, encoded]
    have point : ((List.replicate 16 (0 : Int))[j.val]?).getD 0 = 0 := by
      rw [List.getElem?_eq_getElem (by simpa using j.isLt), List.getElem_replicate]
      rfl
    simp only [ByteCompileQueueStep.queueAt, first, ite_true, point, Ring.intCast_zero]
  · have previous : i.val-1 < 121 := by omega
    have index : (i.val-1)+1 = i.val := by omega
    simp only [ByteCompileQueueStep.queueAt, first, ite_false]
    simpa only [index] using stored_queue wasm final accepted slots binding ⟨i.val-1, previous⟩ j

theorem local_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F)
    (i : Fin 121) (k : Nat) (bound : k < 67) :
    ByteCompileRow.localValues (values wasm slots binding) i k =
      (ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) k : F) := by
  by_cases sourceInput : k < 23
  · rw [ByteCompileCanonicalRow.value_input _ _ k (by omega)]
    exact source_inputs wasm final accepted slots (tailValues wasm binding) i k sourceInput
  · by_cases immediate : k = 23
    · subst k
      rw [input_immediate wasm final accepted slots binding i, ByteCompileCanonicalRow.value_input _ _ 23 (by decide)]
      rfl
    · by_cases queue : k < 40
      · have index : 24+(k-24) = k := by omega
        have small : k-24 < 16 := by omega
        rw [ByteCompileCanonicalRow.value_input _ _ k queue]
        have localValue := input_queue wasm final accepted slots binding i ⟨k-24, small⟩
        simpa only [index, ByteCompileCanonicalRow.inputValue, sourceInput, immediate, ite_false] using localValue
      · have nonzero : k ≠ 0 := by omega
        have notOne : k ≠ 1 := by omega
        have not7 : ¬k < 7 := by omega
        have not15 : ¬k < 15 := by omega
        have not15eq : k ≠ 15 := by omega
        have not16 : k ≠ 16 := by omega
        have not23 : ¬k < 23 := by omega
        rw [ByteCompileRow.localValues, ByteCompileRow.rowMap]
        simp only [nonzero, notOne, not7, not15, not15eq, not16, not23, immediate, queue, ite_false,
          ByteCompileRow.eval_wire]
        have index : 40+(k-40) = k := by omega
        simpa only [index] using stored_row wasm slots binding i ⟨k-40, by omega⟩

theorem rows_hold {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (final : Configuration)
    (accepted : ByteCompileSoundness.decodeBinary wasm = some final) (slots binding : Nat → F) :
    ∀ i : Fin 121, ByteCompileRow.Holds (ByteCompileRow.localValues (values wasm slots binding) i) := by
  intro i j
  have canonical := ByteCompileCanonicalRow.complete_field (F := F) (cfgAt wasm i.val) final (byteAt wasm i)
    ((body wasm).drop (i.val+1)) (row_range wasm final accepted i) (row_remaining wasm final accepted i)
    (ByteCompileTyping.accepted_decoder wasm final accepted).2.2 j
  have same (side : Linear) (member : side ∈
      [(ByteCompileRow.gate j.val).a, (ByteCompileRow.gate j.val).b, (ByteCompileRow.gate j.val).c]) :
      evalLinear (ByteCompileRow.localValues (values wasm slots binding) i) side =
      evalLinear (fun k => (ByteCompileCanonicalRow.values (cfgAt wasm i.val) (byteAt wasm i) k : F)) side := by
    apply ByteCompileComposition.eval_congr
    intro term included
    exact local_values wasm final accepted slots binding i term.1 (of_decide_eq_true
      (List.all_eq_true.mp (List.all_eq_true.mp (ByteCompileAssembly.row_bounds j) side member) term included))
  change evalLinear _ (ByteCompileRow.gate j.val).a * evalLinear _ (ByteCompileRow.gate j.val).b =
    evalLinear _ (ByteCompileRow.gate j.val).c
  rw [same _ (by simp), same _ (by simp), same _ (by simp)]
  exact canonical

#print axioms rows_hold

end ZkBuild.ByteCompileBridgeWitness
