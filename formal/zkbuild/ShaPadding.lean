import ShaBoundary

namespace ZkBuild.ShaPadding

open Lean.Grind
attribute [local simp] AddCommMonoid.zero_add Semiring.add_zero

def lastBlock (length : Nat) : Nat := length/64 + if length%64 < 56 then 0 else 1
def totalBytes (length : Nat) : Nat := 64*Sha256.blockCount length

theorem last_block (length : Nat) : lastBlock length+1 = Sha256.blockCount length := by
  unfold lastBlock Sha256.blockCount
  split <;> omega

theorem last_block_fits (length capacity : Nat) (fits : length ≤ capacity) :
    lastBlock length < Sha256.blockCount capacity := by
  have bound := Sha256.block_count_monotone length capacity fits
  have last := last_block length
  omega

theorem length_region (length position : Nat) :
    position/64 = lastBlock length ∧ 56 ≤ position%64 ↔
      totalBytes length-8 ≤ position ∧ position < totalBytes length := by
  have last := last_block length
  have remainder := Nat.mod_lt position (by decide : 0 < 64)
  have division := Nat.mod_add_div position 64
  unfold totalBytes
  omega

private theorem getD_append (xs ys : List α) (i : Nat) (fallback : α) :
    (xs++ys).getD i fallback =
      if i < xs.length then xs.getD i fallback else ys.getD (i-xs.length) fallback := by
  simp only [List.getD_eq_getElem?_getD,List.getElem?_append]
  split <;> rfl

private theorem getD_replicate (n i : Nat) (value fallback : α) :
    (List.replicate n value).getD i fallback = if i < n then value else fallback := by
  simp only [List.getD_eq_getElem?_getD,List.getElem?_replicate]
  split <;> rfl

private theorem getD_map_range (n i : Nat) (f : Nat → α) (fallback : α) (inside : i < n) :
    ((List.range n).map f).getD i fallback = f i := by
  simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range inside,
    Option.map_some,Option.getD_some]

def specifiedByte (bytes : List Sha256.Byte) (position : Nat) : Sha256.Byte :=
  if position < bytes.length then bytes.getD position 0 else
  if position = bytes.length then 128 else
  if position < totalBytes bytes.length-8 then 0 else
  if position < totalBytes bytes.length then
    BitVec.ofNat 8 (bytes.length*8 / 256^(totalBytes bytes.length-1-position)) else 0

theorem padded_lookup (bytes : List Sha256.Byte) (position : Nat) :
    (Sha256.pad bytes).getD position 0 = specifiedByte bytes position := by
  have sized := Sha256.padding_length bytes.length
  have start : bytes.length+1+Sha256.zeroCount bytes.length = totalBytes bytes.length-8 := by
    unfold totalBytes; omega
  have marker := Sha256.marker_precedes_length_field bytes.length
  by_cases message : position < bytes.length
  · simp only [Sha256.pad,getD_append,List.length_append,List.length_cons,List.length_nil,List.length_replicate,
      specifiedByte,ite_eq_left message]
    simp [show position < bytes.length+1+Sha256.zeroCount bytes.length by omega,
      show position < bytes.length+1 by omega,message]
  · by_cases mark : position = bytes.length
    · subst position
      simp only [Sha256.pad,getD_append,List.length_append,List.length_cons,List.length_nil,List.length_replicate]
      simp [specifiedByte,show bytes.length < bytes.length+1+Sha256.zeroCount bytes.length by omega]
    · by_cases zeros : position < totalBytes bytes.length-8
      · have inside : position-bytes.length-1 < Sha256.zeroCount bytes.length := by omega
        simp only [Sha256.pad,getD_append,List.length_append,List.length_cons,List.length_nil,List.length_replicate,
          specifiedByte,ite_eq_right message,ite_eq_right mark,ite_eq_left zeros]
        simp [show position < bytes.length+1+Sha256.zeroCount bytes.length by omega,
          show ¬position < bytes.length+1 by omega]
        simp [List.getElem?_replicate]
        split <;> rfl
      · by_cases inside : position < totalBytes bytes.length
        · have index : position-(bytes.length+1+Sha256.zeroCount bytes.length) < 8 := by omega
          have reverseIndex : 7-(position-(bytes.length+1+Sha256.zeroCount bytes.length)) = totalBytes bytes.length-1-position := by omega
          simp only [Sha256.pad,getD_append,List.length_append,List.length_cons,List.length_nil,List.length_replicate,
            specifiedByte,ite_eq_right message,ite_eq_right mark,ite_eq_right zeros,ite_eq_left inside]
          rw [ite_eq_right (by omega),getD_map_range _ _ _ _ index,reverseIndex]
        · have beyond : (Sha256.pad bytes).length ≤ position := by rw [Sha256.padded_length]; unfold totalBytes at inside; omega
          simp only [specifiedByte,ite_eq_right message,ite_eq_right mark,ite_eq_right zeros,ite_eq_right inside]
          simp [List.getD_eq_getElem?_getD,List.getElem?_eq_none_iff.mpr beyond]

def circuitByte (bytes : List Sha256.Byte) (position : Nat) : Sha256.Byte :=
  BitVec.ofNat 8 ((bytes.getD position 0).toNat + (if position = bytes.length then 128 else 0) +
    (if position/64 = lastBlock bytes.length ∧ 56 ≤ position%64 then
      (BitVec.ofNat 8 (bytes.length*8/256^(63-position%64))).toNat else 0))

def rawValue (bytes : List Sha256.Byte) (position : Nat) : Nat :=
  (bytes.getD position 0).toNat + (if position = bytes.length then 128 else 0) +
    (if position/64 = lastBlock bytes.length ∧ 56 ≤ position%64 then
      (BitVec.ofNat 8 (bytes.length*8/256^(63-position%64))).toNat else 0)

theorem rawValue_bound (bytes : List Sha256.Byte) (position : Nat) : rawValue bytes position < 256 := by
  have marker := Sha256.marker_precedes_length_field bytes.length
  have field := length_region bytes.length position
  by_cases message : position < bytes.length
  · have noField : ¬(position/64 = lastBlock bytes.length ∧ 56 ≤ position%64) := by
      rw [field]; unfold totalBytes; omega
    simpa [rawValue,noField,show position ≠ bytes.length by omega] using (bytes.getD position 0).isLt
  · have zero : bytes.getD position 0 = 0 := by
      simp [List.getD_eq_getElem?_getD,List.getElem?_eq_none_iff.mpr (by omega : bytes.length ≤ position)]
    by_cases mark : position = bytes.length
    · have noField : ¬(position/64 = lastBlock bytes.length ∧ 56 ≤ position%64) := by
        rw [field]; unfold totalBytes; omega
      simp only [rawValue,zero,ite_eq_left mark,ite_eq_right noField]
      decide
    · by_cases tail : position/64 = lastBlock bytes.length ∧ 56 ≤ position%64
      · simp only [rawValue,zero,ite_eq_right mark,ite_eq_left tail]
        simpa using (BitVec.ofNat 8 (bytes.length*8/256^(63-position%64))).isLt
      · simp only [rawValue,zero,ite_eq_right mark,ite_eq_right tail]
        decide

theorem circuit_value (bytes : List Sha256.Byte) (position : Nat) :
    (circuitByte bytes position).toNat = rawValue bytes position := by
  exact Nat.mod_eq_of_lt (rawValue_bound bytes position)

theorem block_value (bytes : List Sha256.Byte) (block : Nat) (offset : Fin 64)
    (bounded : bytes.length < 2^32) :
    rawValue bytes (block*64+offset.val) =
      (bytes.getD (block*64+offset.val) 0).toNat +
      (if block*64+offset.val = bytes.length then 128 else 0) +
      (if block = lastBlock bytes.length then
        (ShaBoundary.lengthByte (BitVec.ofNat 32 bytes.length) offset).toNat else 0) := by
  have div : (block*64+offset.val)/64 = block := by have := offset.isLt; omega
  have mod : (block*64+offset.val)%64 = offset.val := by have := offset.isLt; omega
  simp only [rawValue,div,mod]
  by_cases last : block = lastBlock bytes.length
  · by_cases beforeField : offset.val < 56
    · simp [last,ShaBoundary.lengthByte,beforeField,show ¬56 ≤ offset.val by omega]
    · rw [ShaBoundary.length_byte_value _ _ (by omega)]
      simp [last,beforeField,Nat.mod_eq_of_lt bounded]
  · simp [last]

theorem circuit_padding (bytes : List Sha256.Byte) (position : Nat) :
    circuitByte bytes position = (Sha256.pad bytes).getD position 0 := by
  rw [padded_lookup]
  have marker := Sha256.marker_precedes_length_field bytes.length
  have field := length_region bytes.length position
  have total := last_block bytes.length
  have division := Nat.mod_add_div position 64
  have remainder := Nat.mod_lt position (by decide : 0 < 64)
  by_cases message : position < bytes.length
  · have noField : ¬(position/64 = lastBlock bytes.length ∧ 56 ≤ position%64) := by
      rw [field]; unfold totalBytes; omega
    simp [circuitByte,specifiedByte,message,show position ≠ bytes.length by omega,noField]
  · have zero : bytes.getD position 0 = 0 := by
      simp [List.getD_eq_getElem?_getD,List.getElem?_eq_none_iff.mpr (by omega : bytes.length ≤ position)]
    by_cases mark : position = bytes.length
    · have noField : ¬(position/64 = lastBlock bytes.length ∧ 56 ≤ position%64) := by
        rw [field]; unfold totalBytes; omega
      have actualNoField : ¬(bytes.length/64 = lastBlock bytes.length ∧ 56 ≤ bytes.length%64) := by simpa [mark] using noField
      simp [circuitByte,specifiedByte,mark,actualNoField]
    · by_cases inField : totalBytes bytes.length-8 ≤ position ∧ position < totalBytes bytes.length
      · have exp : 63-position%64 = totalBytes bytes.length-1-position := by
          have h := field.mpr inField
          unfold totalBytes
          omega
        simp [circuitByte,specifiedByte,message,mark,field,inField.1,inField.2,
          show ¬ position < totalBytes bytes.length-8 by omega,exp]
        apply BitVec.eq_of_toNat_eq
        simp
      · have noField := mt field.mp inField
        by_cases zeroRegion : position < totalBytes bytes.length-8
        · simp [specifiedByte,circuitByte,message,mark,noField,zeroRegion]
        · have beyond : ¬ position < totalBytes bytes.length := by omega
          simp [specifiedByte,circuitByte,message,mark,noField,zeroRegion,beyond]

private theorem append_zeros_getD (bytes : List Sha256.Byte) (padding position : Nat) :
    (bytes++List.replicate padding 0).getD position 0 = bytes.getD position 0 := by
  rw [getD_append]
  split
  · rfl
  · rename_i outside
    have zero : bytes.getD position 0 = 0 := by
      simp [List.getD_eq_getElem?_getD,List.getElem?_eq_none_iff.mpr (by omega : bytes.length ≤ position)]
    rw [zero,getD_replicate]
    split <;> rfl

theorem padded_stream (bytes : List Sha256.Byte) (capacity : Nat) (fits : bytes.length ≤ capacity) :
    (List.range (totalBytes capacity)).map (circuitByte bytes) =
      Sha256.pad bytes ++ List.replicate (totalBytes capacity-totalBytes bytes.length) 0 := by
  have small := Sha256.block_count_monotone bytes.length capacity fits
  have sizes : totalBytes bytes.length ≤ totalBytes capacity := Nat.mul_le_mul_left 64 small
  apply List.ext_getElem
  · simp only [List.length_map,List.length_range,List.length_append,Sha256.padded_length,List.length_replicate]
    change totalBytes capacity = totalBytes bytes.length+(totalBytes capacity-totalBytes bytes.length)
    omega
  · intro i left right
    rw [List.getElem_map,List.getElem_range,circuit_padding]
    rw [List.getElem_eq_getD (0 : Sha256.Byte)]
    exact (append_zeros_getD (Sha256.pad bytes) _ i).symm

private theorem sum_append {F : Type} [CommRing F] (xs ys : List F) :
    (xs++ys).sum = xs.sum+ys.sum := by
  induction xs with
  | nil => simp [AddCommMonoid.zero_add]
  | cons x xs ih =>
    simp only [List.cons_append,List.sum_cons,ih]
    grind

def select {F : Type} [CommRing F] (count last : Nat) (values : Nat → F) : F :=
  ((List.range count).map (fun i => if i = last then values i else 0)).sum

theorem select_value {F : Type} [CommRing F] (count last : Nat) (values : Nat → F) :
    select count last values = if last < count then values last else 0 := by
  induction count with
  | zero => simp [select]
  | succ count ih =>
    simp only [select,List.range_succ,List.map_append,sum_append,List.map_cons,List.map_nil,List.sum_cons,List.sum_nil]
    change select count last values + ((if count = last then values count else 0)+0) = _
    rw [ih]
    by_cases before : last < count
    · simp [before,show count ≠ last by omega,show last < count+1 by omega]
    · by_cases equal : count = last
      · simp [equal]
      · simp [before,equal,show ¬ last < count+1 by omega]

theorem selected_final {F : Type} [CommRing F] (length capacity : Nat) (fits : length ≤ capacity) (values : Nat → F) :
    select (Sha256.blockCount capacity) (lastBlock length) values = values (lastBlock length) := by
  rw [select_value,ite_eq_left (last_block_fits length capacity fits)]

#print axioms padded_lookup
#print axioms circuit_padding
#print axioms padded_stream
#print axioms selected_final

end ZkBuild.ShaPadding
