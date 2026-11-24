import FftCounter

/- Executable width and block-start loops from fft.nim. These definitions use
   the loop guards, including the final-width break before doubling. -/
namespace ZkBuild.FftSchedule

open Lean.Grind FftLayout FftRadix FftInPlace FftCounter
attribute [local instance] Semiring.natCast

def forwardWidths (limit width : Nat) : List Nat :=
  if width = 0 ∨ limit < width then []
  else width :: (if width = limit then [] else forwardWidths limit (width <<< 1))
termination_by limit-width
decreasing_by
  simp_all only [_root_.not_or, Nat.shiftLeft_eq, Nat.pow_one]
  omega

def backwardWidths (width : Nat) : List Nat :=
  if width ≤ 1 then [] else width :: backwardWidths (width >>> 1)
termination_by width
decreasing_by
  rw [Nat.shiftRight_eq_div_pow]
  simp only [Nat.pow_one]
  omega

def blockStarts (limit step current : Nat) : List Nat :=
  if step = 0 ∨ limit ≤ current then []
  else current :: blockStarts limit step (current+step)
termination_by limit-current
decreasing_by omega

def ascendingPowers (start count : Nat) : List Nat :=
  (List.finRange count).map fun i => 2^(start+i.val+1)

theorem ascending_powers_cons (start count : Nat) :
    ascendingPowers start (count+1) = 2^(start+1) :: ascendingPowers (start+1) count := by
  simp only [ascendingPowers, List.finRange_succ, List.map_cons, List.map_map]
  congr 1
  apply List.map_congr_left
  intro i _
  simp only [Function.comp_def, Fin.val_succ]
  congr 1
  omega

theorem double_power (exponent : Nat) : (2^exponent) <<< 1 = 2^(exponent+1) := by
  simp [Nat.shiftLeft_eq, Nat.pow_succ]

theorem forward_widths_correct (start count : Nat) :
    forwardWidths (2^(start+count)) (2^(start+1)) = ascendingPowers start count := by
  induction count generalizing start with
  | zero =>
    have greater : 2^start < 2^(start+1) := Nat.pow_lt_pow_right (by decide) (by omega)
    simp [forwardWidths, greater, ascendingPowers]
  | succ count ih =>
    rw [ascending_powers_cons, forwardWidths]
    have positive : 2^(start+1) ≠ 0 := Nat.ne_of_gt (Nat.two_pow_pos _)
    have within : ¬2^(start+(count+1)) < 2^(start+1) := by
      exact Nat.not_lt.mpr (Nat.pow_le_pow_right (by decide) (by omega))
    simp only [positive, within, false_or, ite_false]
    cases count with
    | zero => simp [ascendingPowers]
    | succ count =>
      have distinct : 2^(start+1) ≠ 2^(start+(count+1+1)) := by
        exact Nat.ne_of_lt (Nat.pow_lt_pow_right (by decide) (by omega))
      rw [ite_eq_right distinct, double_power]
      have same : start+(count+1+1) = (start+1)+(count+1) := by omega
      rw [same, ih]

theorem backward_widths_correct (bits : Nat) :
    backwardWidths (2^bits) = (ascendingPowers 0 bits).reverse := by
  induction bits with
  | zero => simp [backwardWidths, ascendingPowers]
  | succ bits ih =>
    have greater : ¬2^(bits+1) ≤ 1 := by
      have := Nat.pow_lt_pow_right (a := 2) (by decide) (show 0 < bits+1 by omega)
      simpa only [Nat.pow_zero] using Nat.not_le.mpr this
    rw [backwardWidths, ite_eq_right greater, mask_halving, ih]
    simp only [ascendingPowers, List.finRange_succ_last, List.map_append, List.map_map,
      List.map_cons, List.map_nil, List.reverse_append, List.reverse_cons, List.reverse_nil,
      List.nil_append, List.singleton_append, Function.comp_def, Fin.val_last, Fin.val_castSucc, Nat.zero_add]

theorem range_as_indices (start step count : Nat) :
    List.range' start count step = (List.finRange count).map fun i => start+i.val*step := by
  induction count generalizing start with
  | zero => rfl
  | succ count ih =>
    simp only [List.range'_succ, List.finRange_succ, List.map_cons, List.map_map,
      Fin.val_zero, Nat.zero_mul, Nat.add_zero]
    rw [ih]
    congr 1
    apply List.map_congr_left
    intro i _
    simp only [Function.comp_def, Fin.val_succ, Nat.add_mul, Nat.one_mul]
    omega

theorem block_starts_correct (start step count : Nat) (positive : 0 < step) :
    blockStarts (start+count*step) step start = List.range' start count step := by
  induction count generalizing start with
  | zero => simp [blockStarts]
  | succ count ih =>
    rw [blockStarts, List.range'_succ]
    have notZero : step ≠ 0 := Nat.ne_of_gt positive
    have after : ¬start+(count+1)*step ≤ start := by
      have := Nat.mul_pos (show 0 < count+1 by omega) positive
      omega
    simp only [notZero, after, false_or, ite_false]
    have same : start+(count+1)*step = (start+step)+count*step := by rw [Nat.add_mul]; omega
    rw [same, ih]

theorem stage_block_starts (bits : Nat) (index : Fin bits) :
    blockStarts (2^bits) (2^(index.val+1)) 0 =
      (List.finRange (2^(bits-index.val-1))).map fun block => block.val*(2^(index.val+1)) := by
  have size := stage_size bits index.val index.isLt
  rw [Nat.mul_comm 2 (2^index.val), ← Nat.pow_succ] at size
  rw [← size]
  simpa only [Nat.zero_add] using
    (block_starts_correct 0 (2^(index.val+1)) (2^(bits-index.val-1)) (Nat.two_pow_pos _)).trans
      (range_as_indices 0 (2^(index.val+1)) (2^(bits-index.val-1)))

def indexOfWidth (bits width : Nat) : Option (Fin bits) :=
  if bound : width.log2-1 < bits then some ⟨width.log2-1, bound⟩ else none

theorem index_of_power (bits : Nat) (index : Fin bits) :
    indexOfWidth bits (2^(index.val+1)) = some index := by
  simp [indexOfWidth, Nat.log2_two_pow, index.isLt]

theorem decode_ascending (bits : Nat) :
    (ascendingPowers 0 bits).filterMap (indexOfWidth bits) = List.finRange bits := by
  simp only [ascendingPowers, Nat.zero_add, List.filterMap_map, Function.comp_def, index_of_power, List.filterMap_some]

theorem forward_indices (bits : Nat) :
    (forwardWidths (2^bits) 2).filterMap (indexOfWidth bits) = List.finRange bits := by
  have correct := forward_widths_correct 0 bits
  simpa only [Nat.zero_add, show 2^(0+1) = 2 by decide] using congrArg (List.filterMap (indexOfWidth bits)) correct |>.trans (decode_ascending bits)

theorem backward_indices (bits : Nat) :
    (backwardWidths (2^bits)).filterMap (indexOfWidth bits) = (List.finRange bits).reverse := by
  rw [backward_widths_correct, List.filterMap_reverse, decode_ascending]

theorem stage_width_size (bits : Nat) (index : Fin bits) :
    2^(bits-index.val-1) * 2^(index.val+1) = 2^bits := by
  simpa only [Nat.pow_succ, Nat.mul_comm 2 (2^index.val)] using stage_size bits index.val index.isLt

theorem stage_half_width (index : Nat) : 2^(index+1)/2 = 2^index := by
  simp [Nat.pow_succ]

theorem stage_addresses_bounded (bits : Nat) (index : Fin bits)
    (block : Fin (2^(bits-index.val-1))) (offset : Fin (2^index.val)) :
    block.val*2^(index.val+1)+offset.val < 2^bits ∧
      block.val*2^(index.val+1)+offset.val+2^index.val < 2^bits := by
  have size := stage_size bits index.val index.isLt
  have left := (pack ((block, offset), true)).isLt
  have right := (pack ((block, offset), false)).isLt
  rw [left_index, size] at left
  rw [right_index, size] at right
  simpa only [Nat.pow_succ, Nat.mul_comm 2 (2^index.val)] using And.intro left right

theorem block_increment_bounded (bits : Nat) (index : Fin bits)
    (block : Fin (2^(bits-index.val-1))) :
    block.val*2^(index.val+1) + 2^(index.val+1) ≤ 2^bits := by
  have bound := Nat.mul_le_mul_right (2^(index.val+1)) (Nat.succ_le_of_lt block.isLt)
  simpa only [Nat.succ_mul, stage_width_size bits index] using bound

def stageAddresses (size width : Nat) : List (Nat × Nat) :=
  (blockStarts size width 0).flatMap fun start =>
    (List.range (width/2)).map fun offset => (start+offset, start+offset+width/2)

theorem offsets_as_indices (half : Nat) :
    List.range half = (List.finRange half).map Fin.val := by
  rw [List.range_eq_range']
  simpa only [Nat.zero_add, Nat.mul_one] using range_as_indices 0 1 half

theorem stage_addresses_correct (bits : Nat) (index : Fin bits) :
    stageAddresses (2^bits) (2^(index.val+1)) =
      (pairs (2^(bits-index.val-1)) (2^index.val)).map fun pair =>
        ((pack (pair, true)).val, (pack (pair, false)).val) := by
  rw [stageAddresses, stage_block_starts, stage_half_width, offsets_as_indices]
  simp only [pairs, List.map_flatMap, List.flatMap_map, List.map_map, Function.comp_def,
    left_index, right_index, Nat.pow_succ, Nat.mul_comm 2 (2^index.val)]

theorem stage_addresses_safe (bits : Nat) (index : Fin bits) (address : Nat × Nat)
    (present : address ∈ stageAddresses (2^bits) (2^(index.val+1))) :
    address.1 < 2^bits ∧ address.2 < 2^bits := by
  rw [stage_addresses_correct] at present
  obtain ⟨pair, _, rfl⟩ := List.mem_map.mp present
  obtain ⟨block, offset⟩ := pair
  simpa only [left_index, right_index, Nat.pow_succ, Nat.mul_comm 2 (2^index.val)] using
    stage_addresses_bounded bits index block offset

theorem positive_word_exact (wordBits bits value : Nat) (fits : bits+1 < wordBits)
    (bound : value ≤ 2^bits) :
    (BitVec.ofNat wordBits value).toNat = value ∧ (BitVec.ofNat wordBits value).toInt = (value : Int) := by
  have doubled : 2*value < 2^wordBits := by
    have larger : 2^(bits+1) < 2^wordBits := Nat.pow_lt_pow_right (by decide) fits
    rw [Nat.pow_succ] at larger
    omega
  have small : value < 2^wordBits := by omega
  have natural : (BitVec.ofNat wordBits value).toNat = value := by
    rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt small]
  refine ⟨natural, ?_⟩
  rw [BitVec.toInt_eq_toNat_of_lt (by simpa only [natural] using doubled), natural]

theorem positive_add_exact (wordBits bits x y : Nat) (fits : bits+1 < wordBits)
    (bound : x+y ≤ 2^bits) :
    ((BitVec.ofNat wordBits x) + (BitVec.ofNat wordBits y)).toNat = x+y ∧
      ((BitVec.ofNat wordBits x) + (BitVec.ofNat wordBits y)).toInt = ((x+y : Nat) : Int) := by
  rw [BitVec.ofNat_add_ofNat]
  exact positive_word_exact wordBits bits (x+y) fits bound

theorem initial_width_exact (wordBits : Nat) (wide : 2 < wordBits) :
    (BitVec.ofNat wordBits 2).toInt = (2 : Int) :=
  (positive_word_exact wordBits 1 2 wide (by decide)).2

theorem forward_shift_exact (wordBits bits : Nat) (fits : bits+1 < wordBits)
    (index : Fin bits) (beforeLast : index.val+1 < bits) :
    ((BitVec.ofNat wordBits (2^(index.val+1))) <<< 1).toNat = 2^(index.val+2) := by
  have currentBound : 2^(index.val+1) ≤ 2^bits := Nat.pow_le_pow_right (by decide) (by omega)
  have nextBound : 2^(index.val+2) ≤ 2^bits := Nat.pow_le_pow_right (by decide) (by omega)
  have current := (positive_word_exact wordBits bits _ fits currentBound).1
  have next := (positive_word_exact wordBits bits _ fits nextBound).1
  rw [BitVec.toNat_shiftLeft, current, double_power]
  exact next

theorem backward_shift_exact (wordBits bits : Nat) (fits : bits+1 < wordBits) (index : Fin bits) :
    ((BitVec.ofNat wordBits (2^(index.val+1))).sshiftRight 1).toNat = 2^index.val := by
  have bound : 2^(index.val+1) ≤ 2^bits := Nat.pow_le_pow_right (by decide) (by have := index.isLt; omega)
  have value := (positive_word_exact wordBits bits _ fits bound).1
  have nonnegative : (BitVec.ofNat wordBits (2^(index.val+1))).msb = false := by
    apply BitVec.msb_eq_false_iff_two_mul_lt.mpr
    rw [value]
    have big : 2^(bits+1) < 2^wordBits := Nat.pow_lt_pow_right (by decide) fits
    rw [Nat.pow_succ] at big
    omega
  rw [BitVec.sshiftRight_eq_of_msb_false nonnegative, BitVec.toNat_ushiftRight, value, mask_halving]

def forwardScheduled {F : Type} [Field F] (wordBits bits : Nat) (fits : bits+1 < wordBits)
    (roots : Fin bits → F) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  runIndices false roots ((forwardWidths (2^bits) 2).filterMap (indexOfWidth bits))
    (wordPermutation bits (by omega : bits < wordBits) a)

def backwardScheduled {F : Type} [Field F] (wordBits bits : Nat) (fits : bits+1 < wordBits)
    (roots : Fin bits → F) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  FftStages.scale (((2^bits : Nat) : F)⁻¹) (wordPermutation bits (by omega : bits < wordBits)
    (runIndices true roots ((backwardWidths (2^bits)).filterMap (indexOfWidth bits)) a))

theorem forward_scheduled_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (wordBits bits : Nat) (fits : bits+1 < wordBits) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    forwardScheduled wordBits bits fits (scalarStageRoots bits) a = CosetQap.dft (ScalarRoots.evaluationRoots bits) a := by
  rw [forwardScheduled, forward_indices]
  exact forward_with_counter_correct wordBits bits fits bound a

theorem backward_scheduled_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (wordBits bits : Nat) (fits : bits+1 < wordBits) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    backwardScheduled wordBits bits fits (scalarStageRoots bits)
      (CosetQap.dft (ScalarRoots.evaluationRoots bits) a) = a := by
  rw [backwardScheduled, backward_indices]
  exact backward_with_counter_correct wordBits bits fits bound a

def scheduledTransform {F : Type} [Field F] [IsCharP F scalarModulus]
    (wordBits bits : Nat) (fits : bits+1 < wordBits) (bound : bits ≤ 32) :
    CosetQap.InverseTransform (ScalarRoots.evaluationRoots (F := F) bits) where
  inverse := backwardScheduled wordBits bits fits (scalarStageRoots bits)
  leftInverse := backward_scheduled_correct wordBits bits fits bound

theorem quotient_scheduled_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (wordBits bits : Nat) (fits : bits+1 < wordBits) (bound : bits ≤ 32) (low high : Fin (2^bits) → F)
    (satisfied : ∀ i, CosetQap.splitNumerator low high (ScalarRoots.evaluationRoots bits i) = 0) :
    CosetQap.recoverQuotient (ScalarRoots.evaluationRoots bits) (scheduledTransform wordBits bits fits bound) 7 low high = high := by
  apply CosetQap.coset_quotient_correct
    (ScalarRoots.evaluationRoots bits) (scheduledTransform wordBits bits fits bound) (ScalarRoots.evaluation_roots_unity bits bound) 7
  · simpa only [Semiring.natCast_eq_ofNat] using
      small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  · exact ScalarRoots.coset_disjoint bits bound
  · exact satisfied

#print axioms forward_widths_correct
#print axioms backward_widths_correct
#print axioms stage_block_starts
#print axioms stage_addresses_bounded
#print axioms stage_addresses_correct
#print axioms stage_addresses_safe
#print axioms positive_word_exact
#print axioms positive_add_exact
#print axioms forward_shift_exact
#print axioms backward_shift_exact
#print axioms forward_scheduled_correct
#print axioms backward_scheduled_correct
#print axioms quotient_scheduled_correct

end ZkBuild.FftSchedule
