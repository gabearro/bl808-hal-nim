import SlotRowSemantics
import Rv32Compiler

/- Recover the integer represented by arbitrary satisfying bit wires.  The
   carry equation is interpreted in Nat only after bounding both field sides;
   in particular, field wraparound cannot supply a false rounded immediate. -/
namespace ZkBuild.SlotImmediate

open Lean.Grind RowSoundness
attribute [local instance] Ring.intCast Semiring.natCast

noncomputable def decodedBit {F : Type} [CommRing F] (values : Nat → F) (i : Nat) : Bool :=
  @decide (values i = 1) (Classical.propDecidable _)

theorem decoded_bit_value {F : Type} [Field F] (values : Nat → F) (i : Nat)
    (bit : values i * (values i - 1) = 0) :
    values i = ((decodedBit values i).toNat : F) := by
  rcases r1cs_boolean_sound (values i) bit with zero | one
  · simp [decodedBit, zero, Field.zero_ne_one, Semiring.natCast_zero]
  · simp [decodedBit, one, Semiring.natCast_one]

def packNat (bits : Nat → Bool) (start count : Nat) : Nat :=
  ((List.range count).map fun i => (bits (start+i)).toNat * 2^i).sum

theorem pack_nat_bound (bits : Nat → Bool) (start count : Nat) :
    packNat bits start count < 2^count := by
  induction count with
  | zero => simp [packNat]
  | succ count ih =>
    have bitBound : (bits (start+count)).toNat ≤ 1 := by cases bits (start+count) <;> decide
    have top := Nat.mul_le_mul_right (2^count) bitBound
    simp only [Nat.one_mul] at top
    simp only [packNat, List.range_succ, List.map_append, List.sum_append,
      List.map_cons, List.map_nil, List.sum_cons, List.sum_nil, Nat.add_zero]
    change packNat bits start count + (bits (start+count)).toNat * 2^count < 2^(count+1)
    rw [Nat.pow_succ]
    omega

theorem sum_scale (factor : Nat) (values : List Nat) :
    (values.map fun value => factor*value).sum = factor*values.sum := by
  induction values with
  | nil => simp
  | cons value rest ih => simp [ih, Nat.mul_add]

theorem pack_nat_split (bits : Nat → Bool) (start low high : Nat) :
    packNat bits start (low+high) =
      packNat bits start low + 2^low * packNat bits (start+low) high := by
  unfold packNat
  rw [List.range_add, List.map_append, List.sum_append]
  congr 1
  rw [← sum_scale]
  simp only [List.map_map, Function.comp_def]
  congr 1
  apply List.map_congr_left
  intro i _
  simp [Nat.pow_add, Nat.add_assoc, Nat.mul_left_comm]

theorem pack_nat_slice (bits : Nat → Bool) (start count rest : Nat) :
    packNat bits 0 (start+count+rest) / 2^start % 2^count = packNat bits start count := by
  rw [show start+count+rest = start+(count+rest) by omega, pack_nat_split,
    Nat.add_mul_div_left _ _ (Nat.two_pow_pos start),
    Nat.div_eq_of_lt (pack_nat_bound bits 0 start), Nat.zero_add]
  rw [show 0+start = start by omega, pack_nat_split, Nat.add_mul_mod_self_left,
    Nat.mod_eq_of_lt (pack_nat_bound bits start count)]

theorem eval_packed {F : Type} [CommRing F] (values : Nat → F)
    (bits : Nat → Bool) (source start count : Nat)
    (binding : ∀ i, i < count → values (source+(start+i)) = ((bits (start+i)).toNat : F)) :
    evalField values (SlotRow.packed (fun i => .input (source+i)) start count) =
      (packNat bits start count : F) := by
  unfold SlotRow.packed packNat
  rw [SlotRow.eval_sum, ← SlotRow.sum_natCast]
  congr 1
  simp only [List.map_map, Function.comp_def]
  apply List.map_congr_left
  intro i member
  have bound := List.mem_range.mp member
  simp only [evalField, Int.ofNat_eq_natCast, Ring.intCast_natCast, binding i bound,
    Semiring.natCast_mul]

theorem immediate_bit_value {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (i : Fin 32) :
    values (19+i.val) = ((decodedBit values (19+i.val)).toNat : F) := by
  apply decoded_bit_value
  have bit := SlotRow.bit_constraint values holds ⟨10+i.val, by have := i.isLt; omega⟩
  simpa only [← Nat.add_assoc] using bit

theorem upper_bit_value {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (i : Fin 20) :
    values (51+i.val) = ((decodedBit values (51+i.val)).toNat : F) := by
  apply decoded_bit_value
  have bit := SlotRow.bit_constraint values holds ⟨42+i.val, by have := i.isLt; omega⟩
  simpa only [← Nat.add_assoc] using bit

theorem overflow_bit_value {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) : values 71 = ((decodedBit values 71).toNat : F) := by
  exact decoded_bit_value values 71 (SlotRow.bit_constraint values holds ⟨62, by decide⟩)

noncomputable def immediateBits {F : Type} [CommRing F] (values : Nat → F) (i : Nat) : Bool :=
  decodedBit values (19+i)

noncomputable def upperBits {F : Type} [CommRing F] (values : Nat → F) (i : Nat) : Bool :=
  decodedBit values (51+i)

theorem immediate_pack_value {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (start count : Nat) (bound : start+count ≤ 32) :
    evalField values (SlotRow.packed SlotRow.valueBit start count) =
      (packNat (immediateBits values) start count : F) := by
  apply eval_packed
  intro i before
  exact immediate_bit_value values holds ⟨start+i, by omega⟩

theorem upper_pack_value {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (start count : Nat) (bound : start+count ≤ 20) :
    evalField values (SlotRow.packed SlotRow.upperBit start count) =
      (packNat (upperBits values) start count : F) := by
  apply eval_packed
  intro i before
  exact upper_bit_value values holds ⟨start+i, by omega⟩

theorem carry_equation {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values) :
    packNat (immediateBits values) 0 32 + 2048 =
      packNat (upperBits values) 0 20 * 4096 +
      (packNat (immediateBits values) 0 11 + (1-(immediateBits values 11).toNat)*2048) +
      (decodedBit values 71).toNat * 4294967296 := by
  have member : SlotRow.packed SlotRow.valueBit 0 32 + 2048 -
      (SlotRow.packed SlotRow.upperBit 0 20 * 4096 +
       (SlotRow.packed SlotRow.valueBit 0 11 + (1-SlotRow.valueBit 11)*2048) +
       SlotRow.overflow*4294967296) ∈ SlotRow.residuals := by
    simp [SlotRow.residuals]
  have equation := holds _ member
  change evalField values (SlotRow.packed SlotRow.valueBit 0 32) + ((2048 : Int) : F) -
    (evalField values (SlotRow.packed SlotRow.upperBit 0 20) * ((4096 : Int) : F) +
    (evalField values (SlotRow.packed SlotRow.valueBit 0 11) +
      (((1 : Int) : F)-values (19+11))*((2048 : Int) : F)) +
    values 71*((4294967296 : Int) : F)) = 0 at equation
  rw [immediate_pack_value values holds 0 32 (by decide),
    upper_pack_value values holds 0 20 (by decide),
    immediate_pack_value values holds 0 11 (by decide)] at equation
  have bit11 := immediate_bit_value values holds ⟨11, by decide⟩
  have carry := overflow_bit_value values holds
  change values (19+11) = ((immediateBits values 11).toNat : F) at bit11
  change values 71 = ((decodedBit values 71).toNat : F) at carry
  rw [bit11, carry] at equation
  let value := packNat (immediateBits values) 0 32
  let upper := packNat (upperBits values) 0 20
  let low := packNat (immediateBits values) 0 11
  let sign := (immediateBits values 11).toNat
  let overflow := (decodedBit values 71).toNat
  have signBound : sign ≤ 1 := by dsimp [sign]; cases immediateBits values 11 <;> decide
  have carryBound : overflow ≤ 1 := by dsimp [overflow]; cases decodedBit values 71 <;> decide
  have subtraction : ((1-sign : Nat) : F) = 1 - (sign : F) := by
    rcases Nat.le_one_iff_eq_zero_or_eq_one.mp signBound with zero | one
    · simp only [zero, Nat.sub_zero, Semiring.natCast_one, Semiring.natCast_zero]
      grind
    · simp only [one, Nat.sub_self, Semiring.natCast_one, Semiring.natCast_zero]
      grind
  have lifted : ((value+2048 : Nat) : F) =
      ((upper*4096 + (low+(1-sign)*2048) + overflow*4294967296 : Nat) : F) := by
    simp only [Semiring.natCast_add, Semiring.natCast_mul, subtraction]
    change (value : F) + ((2048 : Int) : F) -
      ((upper : F)*((4096 : Int) : F) + ((low : F)+(((1 : Int) : F)-(sign : F))*((2048 : Int) : F)) +
       (overflow : F)*((4294967296 : Int) : F)) = 0 at equation
    grind
  have valueBound := pack_nat_bound (immediateBits values) 0 32
  have upperBound := pack_nat_bound (upperBits values) 0 20
  have lowBound := pack_nat_bound (immediateBits values) 0 11
  have leftBound : value+2048 < scalarModulus := by dsimp [value]; unfold scalarModulus; omega
  have rightBound : upper*4096 + (low+(1-sign)*2048) + overflow*4294967296 < scalarModulus := by
    dsimp [upper, low]; unfold scalarModulus; omega
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus leftBound rightBound).mp lifted

theorem rounded_quotient (value upper low sign carry : Nat)
    (upperBound : upper < 1048576) (lowBound : low < 2048) (signBound : sign ≤ 1)
    (equation : value+2048 = upper*4096 + (low+(1-sign)*2048) + carry*4294967296) :
    upper = (value+2048)/4096 % 1048576 ∧ carry = (value+2048)/4294967296 := by
  have remainderBound : low+(1-sign)*2048 < 4096 := by omega
  have regroup : upper*4096 + (low+(1-sign)*2048) + carry*4294967296 =
      (low+(1-sign)*2048) + 4096*(upper+carry*1048576) := by omega
  constructor
  · rw [equation, regroup, Nat.add_mul_div_left _ _ (by decide),
      Nat.div_eq_of_lt remainderBound, Nat.zero_add, Nat.add_mul_mod_self_right,
      Nat.mod_eq_of_lt upperBound]
  · have bound : upper*4096 + (low+(1-sign)*2048) < 4294967296 := by omega
    rw [equation, Nat.add_mul_div_right _ _ (by decide), Nat.div_eq_of_lt bound, Nat.zero_add]

noncomputable def immediate {F : Type} [CommRing F] (values : Nat → F) : Word :=
  BitVec.ofNat 32 (packNat (immediateBits values) 0 32)

noncomputable def upper {F : Type} [CommRing F] (values : Nat → F) : BitVec 20 :=
  BitVec.ofNat 20 (packNat (upperBits values) 0 20)

theorem immediate_toNat {F : Type} [CommRing F] (values : Nat → F) :
    (immediate values).toNat = packNat (immediateBits values) 0 32 := by
  rw [immediate, BitVec.toNat_ofNat]
  exact Nat.mod_eq_of_lt (pack_nat_bound (immediateBits values) 0 32)

theorem upper_toNat {F : Type} [CommRing F] (values : Nat → F) :
    (upper values).toNat = packNat (upperBits values) 0 20 := by
  rw [upper, BitVec.toNat_ofNat]
  exact Nat.mod_eq_of_lt (pack_nat_bound (upperBits values) 0 20)

theorem emitted_upper_toNat (value : Word) :
    (Rv32Compiler.upperImmediate value).toNat = (value.toNat+2048)/4096 % 1048576 := by
  change ((value+(0x800 : Word)).toNat >>> 12) % 1048576 = _
  rw [Nat.shiftRight_eq_div_pow, BitVec.toNat_add]
  have constantValue : (0x800 : Word).toNat = 2048 := rfl
  rw [constantValue]
  change ((value.toNat+2048) % (4096*1048576) / 4096) % 1048576 = _
  rw [Nat.mod_mul_right_div_self, Nat.mod_mod]

theorem upper_immediate_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values) :
    upper values = Rv32Compiler.upperImmediate (immediate values) ∧
    (decodedBit values 71).toNat = ((immediate values).toNat+2048)/4294967296 := by
  have signBound : (immediateBits values 11).toNat ≤ 1 := by cases immediateBits values 11 <;> decide
  have rounded := rounded_quotient _ _ _ _ _ (pack_nat_bound (upperBits values) 0 20)
    (pack_nat_bound (immediateBits values) 0 11) signBound (carry_equation values holds)
  constructor
  · apply BitVec.eq_of_toNat_eq
    rw [upper_toNat, emitted_upper_toNat, immediate_toNat]
    exact rounded.1
  · rw [immediate_toNat]
    exact rounded.2

theorem immediate_slice {F : Type} [CommRing F] (values : Nat → F)
    (start count : Nat) (bound : start+count ≤ 32) :
    ((immediate values).extractLsb' start count).toNat =
      packNat (immediateBits values) start count := by
  rw [BitVec.extractLsb', BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow, immediate_toNat]
  have width : start+count+(32-start-count) = 32 := by omega
  have result := pack_nat_slice (immediateBits values) start count (32-start-count)
  simpa only [width] using result

theorem upper_slice {F : Type} [CommRing F] (values : Nat → F)
    (start count : Nat) (bound : start+count ≤ 20) :
    ((upper values).extractLsb' start count).toNat =
      packNat (upperBits values) start count := by
  rw [BitVec.extractLsb', BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow, upper_toNat]
  have width : start+count+(20-start-count) = 20 := by omega
  have result := pack_nat_slice (upperBits values) start count (20-start-count)
  simpa only [width] using result

theorem sign_slice (value : Word) :
    value.extractLsb' 31 1 = if value.getLsbD 31 then 1#1 else 0#1 := by
  bv_decide

theorem immediate_sign {F : Type} [CommRing F] (values : Nat → F) :
    (immediate values).getLsbD 31 = immediateBits values 31 := by
  have bit := immediate_slice values 31 1 (by decide)
  rw [sign_slice] at bit
  simp only [packNat, List.range_succ, List.range_zero, List.map_nil,
    List.nil_append, List.map_cons, List.sum_cons, List.sum_nil, Nat.add_zero,
    Nat.pow_zero, Nat.mul_one] at bit
  cases emitted : (immediate values).getLsbD 31 <;>
    cases decoded : immediateBits values 31 <;> simp_all

theorem immediate_slice_field {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (start count : Nat) (bound : start+count ≤ 32) :
    evalField values (SlotRow.packed SlotRow.valueBit start count) =
      (((immediate values).extractLsb' start count).toNat : F) := by
  rw [immediate_pack_value values holds start count bound, immediate_slice values start count bound]

theorem upper_slice_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values)
    (start count : Nat) (bound : start+count ≤ 20) :
    evalField values (SlotRow.packed SlotRow.upperBit start count) =
      (((Rv32Compiler.upperImmediate (immediate values)).extractLsb' start count).toNat : F) := by
  rw [upper_pack_value values holds start count bound,
    ← upper_slice values start count bound, (upper_immediate_determined values holds).1]

theorem single_packed {F : Type} [CommRing F] (values : Nat → F)
    (source index : Nat) :
    evalField values (SlotRow.packed (fun i => .input (source+i)) index 1) = values (source+index) := by
  simp [SlotRow.packed, sumExpr, evalField, Ring.intCast_one, Ring.intCast_zero,
    Semiring.mul_one, Semiring.add_zero]

theorem immediate_bit_field {F : Type} [Field F] (values : Nat → F)
    (holds : SlotRow.FieldHolds values) (i : Fin 32) :
    values (19+i.val) = (((immediate values).extractLsb' i.val 1).toNat : F) := by
  have binding := immediate_slice_field values holds i.val 1 (by have := i.isLt; omega)
  change evalField values (SlotRow.packed (fun j => .input (19+j)) i.val 1) = _ at binding
  rw [single_packed] at binding
  exact binding

theorem upper_bit_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values) (i : Fin 20) :
    values (51+i.val) = (((Rv32Compiler.upperImmediate (immediate values)).extractLsb' i.val 1).toNat : F) := by
  have binding := upper_slice_field values holds i.val 1 (by have := i.isLt; omega)
  change evalField values (SlotRow.packed (fun j => .input (51+j)) i.val 1) = _ at binding
  rw [single_packed] at binding
  exact binding

theorem overflow_field {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (holds : SlotRow.FieldHolds values) :
    values 71 = ((((immediate values).toNat+2048)/4294967296 : Nat) : F) := by
  rw [overflow_bit_value values holds, (upper_immediate_determined values holds).2]

#print axioms immediate_slice
#print axioms upper_slice
#print axioms immediate_sign

#print axioms carry_equation
#print axioms upper_immediate_determined

end ZkBuild.SlotImmediate
