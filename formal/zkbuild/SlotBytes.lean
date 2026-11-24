import SlotImmediate

namespace ZkBuild.SlotBytes

open Lean.Grind RowSoundness
attribute [local instance] Ring.intCast Semiring.natCast

def chosenWasm (kind : Fin 10) : List Expr :=
  .literal (Int.ofNat (SlotShape.opcode kind.val)) ::
    (List.range 5).map fun j => if kind.val = 3 then SlotRow.constBytes[j]!
      else if kind.val = 1 ∧ j = 0 then 0 else 1

def chosenNative (kind : Fin 10) (depth : Fin 9) : List Expr :=
  if SlotShape.valid kind.val depth.val then (SlotRow.words kind.val depth.val).toList
    else List.replicate 8 0

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem wasm_certificate : ∀ kind depth,
    RowMatrix.polynomialListEqual
      (SlotRow.wasmBytes.map (SlotRow.specialize kind depth)) (chosenWasm kind) = true := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem native_certificate : ∀ kind depth,
    RowMatrix.polynomialListEqual
      (SlotRow.nativeBytes.map (SlotRow.specialize kind depth)) (chosenNative kind depth) = true := by
  native_decide

theorem wasm_selected {F : Type} [CommRing F] (ctx : Lean.RArray F) (kind : Fin 10) (depth : Fin 9)
    (prior : ∀ i, i < 9 → ctx.get i = if i = depth.val then 1 else 0)
    (selected : ∀ i, i < 10 → ctx.get (9+i) = if i = kind.val then 1 else 0) :
    SlotRow.wasmBytes.map (evalField ctx.get) = (chosenWasm kind).map (evalField ctx.get) := by
  have result := RowMatrix.polynomial_list_sound ctx _ _ (wasm_certificate kind depth)
  simpa only [List.map_map, Function.comp_def,
    SlotRow.specialize_eval ctx.get kind depth prior selected] using result

theorem native_selected {F : Type} [CommRing F] (ctx : Lean.RArray F) (kind : Fin 10) (depth : Fin 9)
    (prior : ∀ i, i < 9 → ctx.get i = if i = depth.val then 1 else 0)
    (selected : ∀ i, i < 10 → ctx.get (9+i) = if i = kind.val then 1 else 0)
    (valid : SlotShape.valid kind.val depth.val = true) :
    SlotRow.nativeBytes.map (evalField ctx.get) =
      (SlotRow.words kind.val depth.val).toList.map (evalField ctx.get) := by
  have result := RowMatrix.polynomial_list_sound ctx _ _ (native_certificate kind depth)
  simpa only [List.map_map, Function.comp_def,
    SlotRow.specialize_eval ctx.get kind depth prior selected, chosenNative, valid, ite_true] using result

def constantPayload (value : Word) : List Nat :=
  (List.range 4).map (fun i => 128+(value.extractLsb' (7*i) 7).toNat) ++
    [(value.extractLsb' 28 4).toNat + (if value.getLsbD 31 then 112 else 0)]

def lebPayload (value : Word) : List (BitVec 8) :=
  let encoded := leb5 value
  [encoded.1, encoded.2.1, encoded.2.2.1, encoded.2.2.2.1, encoded.2.2.2.2]

theorem leb_payload_fields (value : Word) : lebPayload value =
    [(value.extractLsb' 0 7).setWidth 8 + 128,
     (value.extractLsb' 7 7).setWidth 8 + 128,
     (value.extractLsb' 14 7).setWidth 8 + 128,
     (value.extractLsb' 21 7).setWidth 8 + 128,
     (value.extractLsb' 28 4).setWidth 8 + (if value.getLsbD 31 then 112 else 0)] := by
  unfold lebPayload leb5
  simp only [List.cons.injEq, and_true]
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> bv_decide

theorem continuation_byte (value : BitVec 7) :
    (value.setWidth 8 + 128).toNat = 128 + value.toNat := by
  rw [BitVec.toNat_add, BitVec.toNat_setWidth_of_le (by decide)]
  change (value.toNat+128)%256 = 128+value.toNat
  have bound := value.isLt
  omega

theorem final_byte (value : BitVec 4) (sign : Bool) :
    (value.setWidth 8 + (if sign then 112 else 0)).toNat =
      value.toNat + (if sign then 112 else 0) := by
  rw [BitVec.toNat_add, BitVec.toNat_setWidth_of_le (by decide)]
  have bound := value.isLt
  cases sign
  · change (value.toNat+0)%256 = value.toNat+0
    omega
  · change (value.toNat+112)%256 = value.toNat+112
    omega

theorem constant_payload_is_leb (value : Word) :
    (lebPayload value).map BitVec.toNat = constantPayload value := by
  rw [leb_payload_fields]
  simp only [List.map_cons, List.map_nil, continuation_byte, final_byte]
  rfl

theorem constant_payload {F : Type} [Field F] (values : Nat → F) (holds : SlotRow.FieldHolds values) :
    SlotRow.constBytes.toList.map (evalField values) =
      (constantPayload (SlotImmediate.immediate values)).map (fun value : Nat => (value : F)) := by
  have slices (i : Fin 4) := SlotImmediate.immediate_slice_field values holds (7*i.val) 7 (by have := i.isLt; omega)
  have lastSlice := SlotImmediate.immediate_slice_field values holds 28 4 (by decide)
  have sign := SlotImmediate.immediate_bit_value values holds ⟨31, by decide⟩
  change values (19+31) = ((SlotImmediate.immediateBits values 31).toNat : F) at sign
  rw [← SlotImmediate.immediate_sign] at sign
  unfold SlotRow.constBytes constantPayload
  simp only [Array.toList_push, List.map_append, List.map_map,
    Function.comp_def, List.map_cons, List.map_nil]
  congr 1
  · apply List.map_congr_left
    intro i member
    have bound := List.mem_range.mp member
    have slice := slices ⟨i, bound⟩
    change ((128 : Int) : F) + evalField values (SlotRow.packed SlotRow.valueBit (7*i) 7) = _
    rw [slice, Semiring.natCast_add]
    exact congrArg (fun x : F => x + (((SlotImmediate.immediate values).extractLsb' (7*i) 7).toNat : F))
      (Ring.intCast_natCast 128)
  · change [evalField values (SlotRow.packed SlotRow.valueBit 28 4) +
      values (19+31)*((112 : Int) : F)] = _
    rw [lastSlice, sign, Semiring.natCast_add]
    rw [show ((112 : Int) : F) = ((112 : Nat) : F) from Ring.intCast_natCast 112]
    cases (SlotImmediate.immediate values).getLsbD 31 <;>
      simp only [Bool.toNat_false, Bool.toNat_true, Bool.false_eq_true, ite_false, ite_true,
        Semiring.natCast_zero, Semiring.natCast_one, Semiring.zero_mul, Semiring.one_mul,
        Semiring.add_zero]

#print axioms wasm_selected
#print axioms native_selected
#print axioms constant_payload_is_leb
#print axioms constant_payload

end ZkBuild.SlotBytes
