import BinaryVariantFormat

namespace ZkBuild.TokenInteger
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem packed_testBit (bits : List Bool) (i : Nat) :
    (BitPacking.packBits bits).testBit i = bits.getD i false := by
  induction bits generalizing i with
  | nil => simp [BitPacking.packBits]
  | cons bit rest ih =>
    cases i with
    | zero => cases bit <;> simp [BitPacking.packBits,Nat.testBit_zero,Nat.add_mod]
    | succ i =>
      rw [Nat.testBit_succ]
      have divided : BitPacking.packBits (bit::rest)/2 = BitPacking.packBits rest := by
        cases bit <;> simp [BitPacking.packBits,Nat.add_div]
      rw [divided,ih]
      rfl

theorem map_getD (f : α → β) (xs : List α) (fallback : α) (i : Nat) :
    (xs.map f).getD i (f fallback) = f (xs.getD i fallback) := by
  induction xs generalizing i with
  | nil => simp
  | cons x xs ih => cases i with
    | zero => rfl
    | succ i => simpa using ih i

/-- The field bits from a checked range are the exact binary digits of its
    unique bounded natural representation, including at zero padding. -/
theorem certificate_nat {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (word : Linear) (bits : List Linear) (width : Nat)
    (certificate : RangeReuse.Certificate width (E values word) (bits.map (E values))) :
    ∃ n : Nat, n < 2^width ∧ E values word = (n : F) ∧
      ∀ i, E values (BinaryTokenMatrix.atBit bits i) = (if n.testBit i then 1 else 0) := by
  obtain ⟨decoded,same⟩ := R1CS.constrained_bits_are_booleans (bits.map (E values)) certificate.2.1
  have size : decoded.length = width := by
    have sizes := congrArg List.length same
    simp only [List.length_map] at sizes
    have certSize := certificate.1
    simp only [List.length_map] at certSize
    omega
  have encoded : E values word = (BitPacking.packBits decoded : F) := by
    rw [← certificate.2.2,same,R1CS.weighted_booleans,← size,BitPacking.binary_weights_encode_bits]
  refine ⟨BitPacking.packBits decoded,by simpa [size] using BitPacking.packed_bits_bounded decoded,encoded,?_⟩
  intro i
  have equal := congrArg (fun xs : List F => xs.getD i 0) same
  have zero : E values BinaryTokenMatrix.zero = 0 := by simp [BinaryTokenMatrix.zero,eval_constant values oneValue]
  have boolZero : (R1CS.boolValue false : F) = 0 := rfl
  have left : (bits.map (E values)).getD i 0 = E values (BinaryTokenMatrix.atBit bits i) := by
    rw [← zero]
    exact map_getD (E values) bits BinaryTokenMatrix.zero i
  have right : (decoded.map (R1CS.boolValue (F := F))).getD i 0 = R1CS.boolValue (decoded.getD i false) := by
    rw [← boolZero]
    exact map_getD _ decoded false i
  rw [left,right] at equal
  simpa only [packed_testBit,R1CS.boolValue] using equal

theorem bool_image_injective {F : Type} [Field F] (a b : Bool)
    (same : (R1CS.boolValue a : F) = R1CS.boolValue b) : a = b := by
  cases a <;> cases b <;> simp_all [R1CS.boolValue]
  all_goals exact False.elim (by grind)

theorem known_byte_bits {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (oneValue : values 0 = 1) (word : Linear) (bits : List Linear)
    (byte : Nat) (small : byte < 256) (value : E values word = (byte : F))
    (certificate : RangeReuse.Certificate 8 (E values word) (bits.map (E values))) :
    ∀ i, E values (BinaryTokenMatrix.atBit bits i) = (if byte.testBit i then 1 else 0) := by
  obtain ⟨n,bound,image,bitImage⟩ := certificate_nat values oneValue word bits 8 certificate
  have big : 256 < scalarModulus := by decide
  have same : n = byte := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp
    (image.symm.trans value)
  simpa [same] using bitImage

#print axioms certificate_nat
#print axioms known_byte_bits
end ZkBuild.TokenInteger

namespace ZkBuild.TokenInteger
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix BinaryVariantFields
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def signBit (kind length : Nat) (bytes : Nat → Nat) : Bool :=
  if signed kind then (bytes (length-1)).testBit 6 else false

def decodedBit (kind length : Nat) (bytes : Nat → Nat) (i : Nat) : Bool :=
  if leb kind then
    if i < 7*length then (bytes (i/7)).testBit (i%7) else signBit kind length bytes
  else (bytes (i/8)).testBit (i%8)

def decode (kind length : Nat) (bytes : Nat → Nat) : Nat :=
  BitPacking.packBits ((List.range (width kind)).map (decodedBit kind length bytes))

theorem row_exists (r : Record) (i : Nat) (inside : i < r.rows.length) :
    ∃ present row, (i,present,row) ∈ rowInputs 0 (active r) r.rows := by
  have indexes : (rowInputs 0 (active r) r.rows).map Prod.fst = List.range r.rows.length := by
    simpa [List.range_eq_range'] using BinaryTokenSource.indexes 0 (active r) r.rows
  have member : i ∈ (rowInputs 0 (active r) r.rows).map Prod.fst := by rw [indexes]; exact List.mem_range.mpr inside
  obtain ⟨⟨j,p,row⟩,member,equal⟩ := List.mem_map.mp member
  simp only [Prod.fst] at equal
  subst j
  exact ⟨p,row,member⟩

theorem row_member (i : Nat) (present : Linear) (rows : List Row) (item : Nat × Linear × Row)
    (member : item ∈ rowInputs i present rows) : item.2.2 ∈ rows := by
  induction rows generalizing i present with
  | nil => simp [rowInputs] at member
  | cons row rest ih =>
    rcases List.mem_cons.mp member with rfl | later
    · simp
    · exact List.mem_cons_of_mem _ (ih (i+1) row.next later)

theorem decoded_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (oneValue : values 0 = 1) (r : Record) (kind length physicalWidth : Nat)
    (small : kind < 7) (positive : 0 < length) (lengthBound : length ≤ capacity kind)
    (rawLength : leb kind = false → length = capacity kind)
    (rows : capacity kind ≤ r.rows.length) (widthBound : width kind ≤ physicalWidth)
    (bytes : Nat → Nat)
    (valueRange : RangeReuse.Certificate physicalWidth (E values r.value) ((RangeUse.bits r.valueRange).map (E values)))
    (byteRanges : ∀ row ∈ r.rows, RangeReuse.Certificate 8 (E values row.value) ((RangeUse.bits row.byteRange).map (E values)))
    (source : ∀ item ∈ rowInputs 0 (active r) r.rows, item.1 < length →
      bytes item.1 < 256 ∧ E values item.2.2.value = (bytes item.1 : F))
    (rules : ∀ item ∈ rowInputs 0 (active r) r.rows, BinaryVariantBits.Rules values r kind length item)
    (upper : ∀ i, i < physicalWidth → width kind ≤ i → E values (atBit (RangeUse.bits r.valueRange) i) = 0) :
    E values r.value = (decode kind length bytes : F) := by
  obtain ⟨value,bound,valueImage,bitImage⟩ := certificate_nat values oneValue r.value (RangeUse.bits r.valueRange) physicalWidth valueRange
  have byteImage (item : Nat × Linear × Row) (member : item ∈ rowInputs 0 (active r) r.rows) (used : item.1 < length) :
      ∀ j, E values (atBit (RangeUse.bits item.2.2.byteRange) j) = (if (bytes item.1).testBit j then 1 else 0) := by
    have actual := source item member used
    exact known_byte_bits values oneValue item.2.2.value (RangeUse.bits item.2.2.byteRange) (bytes item.1) actual.1 actual.2
      (byteRanges item.2.2 (row_member 0 (active r) r.rows item member))
  have signImage : E values (kindSign r kind) = (if signBit kind length bytes then 1 else 0) := by
    by_cases isSigned : signed kind = true
    · obtain ⟨p,row,member⟩ := row_exists r (length-1) (by omega)
      have lebSigned : leb kind = true := by
        have kinds : kind = 2 ∨ kind = 3 ∨ kind = 4 := by simpa [signed] using isSigned
        have bounds : 1 ≤ kind ∧ kind ≤ 4 := by omega
        simpa [leb] using bounds
      have lastRule := (rules (length-1,p,row) member)
      simp only [BinaryVariantBits.Rules,lebSigned,↓reduceIte] at lastRule
      have terminal := lastRule.2.2.2 isSigned (by omega)
      have lastByte := byteImage (length-1,p,row) member (by omega) 6
      simp only [Prod.fst,Prod.snd] at terminal lastByte
      rw [← terminal,lastByte]
      simp only [signBit,isSigned,↓reduceIte]
    · have unsigned : signed kind = false := by cases h : signed kind <;> simp_all
      simp [kindSign,signBit,unsigned,zero,eval_constant values oneValue]
  have wordBits (i : Nat) (inside : i < width kind) : value.testBit i = decodedBit kind length bytes i := by
    by_cases encoded : leb kind = true
    · have kinds : width kind ≤ 7*capacity kind := by
        have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
        rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [width,capacity,leb] at *
      have rowBound : i/7 < r.rows.length := by omega
      obtain ⟨p,row,member⟩ := row_exists r (i/7) rowBound
      have digit : i%7 < 7 := Nat.mod_lt _ (by decide)
      have index : 7*(i/7)+i%7 = i := by omega
      have decodedRule := rules (i/7,p,row) member
      simp only [BinaryVariantBits.Rules,encoded,↓reduceIte,Prod.fst,Prod.snd] at decodedRule
      have route := decodedRule.2.1 (i%7) digit (by omega)
      rw [index,bitImage] at route
      apply bool_image_injective (F := F)
      change (if value.testBit i then (1 : F) else 0) = (if decodedBit kind length bytes i then 1 else 0)
      by_cases used : i/7 < length
      · have consumed : i < 7*length := by omega
        rw [ite_eq_left used,byteImage (i/7,p,row) member used (i%7)] at route
        simpa only [decodedBit,encoded,↓reduceIte,ite_eq_left consumed] using route
      · have remaining : ¬i < 7*length := by omega
        rw [ite_eq_right used,signImage] at route
        simpa only [decodedBit,encoded,↓reduceIte,ite_eq_right remaining] using route
    · have raw : leb kind = false := by cases h : leb kind <;> simp_all
      have widthCap : width kind = 8*capacity kind := by
        have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 ∨ kind = 4 ∨ kind = 5 ∨ kind = 6 := by omega
        rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [width,capacity,leb] at *
      have widthSmall : width kind ≤ 64 := by unfold width; grind
      have rowBound : i/8 < r.rows.length := by omega
      obtain ⟨p,row,member⟩ := row_exists r (i/8) rowBound
      have digit : i%8 < 8 := Nat.mod_lt _ (by decide)
      have index : 8*(i/8)+i%8 = i := by omega
      have used : i/8 < length := by have exact := rawLength raw; omega
      have decodedRule := rules (i/8,p,row) member
      simp only [BinaryVariantBits.Rules,raw,Bool.false_eq_true,↓reduceIte,Prod.fst,Prod.snd] at decodedRule
      have route := decodedRule (by omega) (i%8) digit
      rw [index,bitImage,ite_eq_left used,byteImage (i/8,p,row) member used (i%8)] at route
      apply bool_image_injective (F := F)
      simpa only [R1CS.boolValue,decodedBit,raw,Bool.false_eq_true,↓reduceIte] using route
  have equal : value = decode kind length bytes := by
    apply Nat.eq_of_testBit_eq
    intro i
    rw [decode,packed_testBit]
    by_cases inside : i < width kind
    · have lookup : ((List.range (width kind)).map (decodedBit kind length bytes)).getD i false = decodedBit kind length bytes i := by
        simp [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range inside]
      rw [lookup]
      exact wordBits i inside
    · have lookup : ((List.range (width kind)).map (decodedBit kind length bytes)).getD i false = false := by
        have missing : ((List.range (width kind)).map (decodedBit kind length bytes))[i]? = none :=
          List.getElem?_eq_none (by simp only [List.length_map,List.length_range]; omega)
        simp [List.getD_eq_getElem?_getD,missing]
      rw [lookup]
      by_cases physical : i < physicalWidth
      · have out := upper i physical (by omega)
        rw [bitImage] at out
        cases bit : value.testBit i <;> simp_all
        exact False.elim (Field.zero_ne_one out.symm)
      · apply Nat.testBit_lt_two_pow
        exact Nat.lt_of_lt_of_le bound (Nat.pow_le_pow_right (by decide) (by omega))
  simpa [equal] using valueImage

#print axioms decoded_value
end ZkBuild.TokenInteger

namespace ZkBuild.TokenInteger
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryTokenMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Semiring.natCast_zero

theorem zero_from_bits {F : Type} [Field F] (values : Nat → F) (oneValue : values 0 = 1)
    (word : Linear) (bits : List Linear) (width : Nat)
    (certificate : RangeReuse.Certificate width (E values word) (bits.map (E values)))
    (zeros : ∀ i, i < width → E values (atBit bits i) = 0) : E values word = 0 := by
  obtain ⟨n,bound,value,image⟩ := certificate_nat values oneValue word bits width certificate
  have nz : n = 0 := by
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.zero_testBit]
    by_cases inside : i < width
    · have bit := zeros i inside
      rw [image] at bit
      cases b : n.testBit i <;> simp_all
      exact False.elim (Field.zero_ne_one bit.symm)
    · exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le bound (Nat.pow_le_pow_right (by decide) (by omega)))
  simpa [nz] using value
end ZkBuild.TokenInteger
