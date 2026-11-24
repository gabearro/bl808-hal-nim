import FftInPlace

/- The reversed binary counter used by fft.nim: clear set bits from the
   highest position down, then set the first zero bit. -/
namespace ZkBuild.FftCounter

open Lean.Grind
open FftLayout FftSplit FftInPlace
attribute [local instance] Semiring.natCast

theorem low_and_mask (bits low : Nat) (bound : low < 2^bits) : low &&& 2^bits = 0 := by
  apply Nat.eq_of_testBit_eq
  intro i
  by_cases atBit : bits = i
  · subst i
    simp [Nat.testBit_and, Nat.testBit_lt_two_pow bound]
  · simp [Nat.testBit_and, atBit]

theorem low_xor_mask (bits low : Nat) (bound : low < 2^bits) : low ^^^ 2^bits = low+2^bits := by
  rw [← Nat.or_two_pow_eq_add_of_lt bound]
  apply Nat.eq_of_testBit_eq
  intro i
  by_cases atBit : bits = i
  · subst i
    simp [Nat.testBit_xor, Nat.testBit_or, Nat.testBit_lt_two_pow bound]
  · simp [Nat.testBit_xor, Nat.testBit_or, atBit]

theorem high_and_mask (bits low : Nat) (bound : low < 2^bits) :
    (low+2^bits) &&& 2^bits = 2^bits := by
  rw [← Nat.or_two_pow_eq_add_of_lt bound, Nat.and_or_distrib_right, low_and_mask bits low bound]
  simp

theorem high_xor_mask (bits low : Nat) (bound : low < 2^bits) :
    (low+2^bits) ^^^ 2^bits = low := by
  rw [← low_xor_mask bits low bound, Nat.xor_assoc, Nat.xor_self, Nat.xor_zero]

def advance : Nat → Nat → Nat
  | 0, value => value
  | bits+1, value =>
    let mask := 2^bits
    if value &&& mask = 0 then value ^^^ mask else advance bits (value ^^^ mask)

theorem advance_low (bits low : Nat) (bound : low < 2^bits) :
    advance (bits+1) low = low+2^bits := by
  simp only [advance, low_and_mask bits low bound, ite_true, low_xor_mask bits low bound]

theorem advance_high (bits low : Nat) (bound : low < 2^bits) :
    advance (bits+1) (low+2^bits) = advance bits low := by
  have positive : 2^bits ≠ 0 := Nat.ne_of_gt (Nat.two_pow_pos bits)
  simp only [advance, high_and_mask bits low bound, positive, ite_false, high_xor_mask bits low bound]

theorem reverse_even_odd (bits : Nat) (odd : Bool) (i : Fin (2^bits)) :
    reverseIndex (bits+1) (evenOddIndex bits odd i) = halfIndex bits odd (reverseIndex bits i) := by
  have previous := reverse_half_index bits odd (reverseIndex bits i)
  rw [reverse_index_involutive] at previous
  have reversed := congrArg (reverseIndex (bits+1)) previous
  rw [reverse_index_involutive] at reversed
  exact reversed.symm

theorem advance_even (bits : Nat) (i : Fin (2^bits)) :
    advance (bits+1) (reverseIndex (bits+1) (evenOddIndex bits false i)).val =
      (reverseIndex (bits+1) (evenOddIndex bits true i)).val := by
  rw [reverse_even_odd, reverse_even_odd]
  change advance (bits+1) (reverseIndex bits i).val = (reverseIndex bits i).val+2^bits
  exact advance_low bits _ (reverseIndex bits i).isLt

theorem advance_odd (bits : Nat) (i : Fin (2^bits)) :
    advance (bits+1) (reverseIndex (bits+1) (evenOddIndex bits true i)).val =
      advance bits (reverseIndex bits i).val := by
  rw [reverse_even_odd]
  change advance (bits+1) ((reverseIndex bits i).val+2^bits) = advance bits (reverseIndex bits i).val
  exact advance_high bits _ (reverseIndex bits i).isLt

theorem advance_correct (bits : Nat) (i next : Fin (2^bits)) (adjacent : next.val = i.val+1) :
    advance bits (reverseIndex bits i).val = (reverseIndex bits next).val := by
  induction bits with
  | zero => have := i.isLt; have := next.isLt; simp only [Nat.pow_zero] at *; omega
  | succ bits ih =>
    have size : i.val < 2^bits*2 := by simpa only [Nat.pow_succ] using i.isLt
    let q : Fin (2^bits) := ⟨i.val/2, by omega⟩
    have division := Nat.mod_add_div i.val 2
    have remainder := Nat.mod_lt i.val (by decide : 0 < 2)
    by_cases even : i.val%2 = 0
    · have input : i = evenOddIndex bits false q := by
        apply Fin.ext
        simp only [evenOddIndex, Bool.toNat_false, Nat.add_zero, q]
        omega
      have output : next = evenOddIndex bits true q := by
        apply Fin.ext
        simp only [evenOddIndex, Bool.toNat_true, q]
        omega
      rw [input, output, advance_even]
    · have odd : i.val%2 = 1 := by omega
      have nextSize : next.val < 2^bits*2 := by simpa only [Nat.pow_succ] using next.isLt
      let qNext : Fin (2^bits) := ⟨q.val+1, by dsimp [q]; omega⟩
      have input : i = evenOddIndex bits true q := by
        apply Fin.ext
        simp only [evenOddIndex, Bool.toNat_true, q]
        omega
      have output : next = evenOddIndex bits false qNext := by
        apply Fin.ext
        simp only [evenOddIndex, Bool.toNat_false, Nat.add_zero, qNext, q]
        omega
      rw [input, output, advance_odd, ih q qNext rfl, reverse_even_odd]
      rfl

def carryLoop : Nat → Nat → Nat → Nat × Nat
  | 0, value, mask => (value, mask)
  | fuel+1, value, mask =>
    if value &&& mask = 0 then (value, mask)
    else carryLoop fuel (value ^^^ mask) (mask >>> 1)

def counterTransition (bits value : Nat) : Nat :=
  let stopped := carryLoop bits value ((2^bits) >>> 1)
  stopped.1 ^^^ stopped.2

theorem mask_halving (bits : Nat) : (2^(bits+1)) >>> 1 = 2^bits := by
  simp [Nat.shiftRight_eq_div_pow, Nat.pow_succ]

theorem transition_eq_advance (bits value : Nat) : counterTransition bits value = advance bits value := by
  induction bits generalizing value with
  | zero => simp [counterTransition, carryLoop, advance]
  | succ bits ih =>
    simp only [counterTransition, mask_halving, carryLoop, advance]
    split
    · rfl
    · exact ih (value ^^^ 2^bits)

theorem carry_stops (bits value : Nat) :
    let stopped := carryLoop bits value ((2^bits) >>> 1)
    stopped.1 &&& stopped.2 = 0 := by
  induction bits generalizing value with
  | zero => simp [carryLoop]
  | succ bits ih =>
    simp only [mask_halving, carryLoop]
    split
    · assumption
    · exact ih _

theorem carry_bounds (limit fuel value mask : Nat)
    (valueBound : value < 2^limit) (maskBound : mask < 2^limit) :
    let stopped := carryLoop fuel value mask
    stopped.1 < 2^limit ∧ stopped.2 < 2^limit := by
  induction fuel generalizing value mask with
  | zero => exact ⟨valueBound, maskBound⟩
  | succ fuel ih =>
    simp only [carryLoop]
    split
    · exact ⟨valueBound, maskBound⟩
    · exact ih _ _ (Nat.xor_lt_two_pow valueBound maskBound)
        (Nat.lt_of_le_of_lt (Nat.shiftRight_le mask 1) maskBound)

theorem initial_mask_bound (bits : Nat) : (2^bits) >>> 1 < 2^bits := by
  cases bits with
  | zero => decide
  | succ bits => rw [mask_halving, Nat.pow_succ]; have := Nat.two_pow_pos bits; omega

theorem transition_bound (bits value : Nat) (bound : value < 2^bits) :
    counterTransition bits value < 2^bits := by
  have bounds := carry_bounds bits bits value ((2^bits) >>> 1) bound (initial_mask_bound bits)
  exact Nat.xor_lt_two_pow bounds.1 bounds.2

def carryWord {width : Nat} : Nat → BitVec width → BitVec width → BitVec width × BitVec width
  | 0, value, mask => (value, mask)
  | fuel+1, value, mask =>
    if value &&& mask = 0#width then (value, mask)
    else carryWord fuel (value ^^^ mask) (mask >>> 1)

theorem carry_word_to_nat {width : Nat} (fuel : Nat) (value mask : BitVec width) :
    let stopped := carryWord fuel value mask
    (stopped.1.toNat, stopped.2.toNat) = carryLoop fuel value.toNat mask.toNat := by
  induction fuel generalizing value mask with
  | zero => rfl
  | succ fuel ih =>
    simp only [carryWord, carryLoop, BitVec.toNat_eq, BitVec.toNat_and, BitVec.toNat_zero]
    split
    · rfl
    · simpa only [BitVec.toNat_xor, BitVec.toNat_ushiftRight] using ih (value ^^^ mask) (mask >>> 1)

def wordTransition {width : Nat} (bits : Nat) (value : BitVec width) : BitVec width :=
  let stopped := carryWord bits value ((BitVec.ofNat width (2^bits)) >>> 1)
  stopped.1 ^^^ stopped.2

theorem word_transition_to_nat {width : Nat} (bits : Nat) (fits : bits < width) (value : BitVec width) :
    (wordTransition bits value).toNat = counterTransition bits value.toNat := by
  have maskBound : 2^bits < 2^width := Nat.pow_lt_pow_right (by decide) fits
  have result := carry_word_to_nat bits value ((BitVec.ofNat width (2^bits)) >>> 1)
  have left := congrArg Prod.fst result
  have right := congrArg Prod.snd result
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.mod_eq_of_lt maskBound] at left right
  simp only [wordTransition, BitVec.toNat_xor, counterTransition, left, right]

theorem word_carry_stops {width : Nat} (bits : Nat) (fits : bits < width) (value : BitVec width) :
    let stopped := carryWord bits value ((BitVec.ofNat width (2^bits)) >>> 1)
    stopped.1 &&& stopped.2 = 0#width := by
  have maskBound : 2^bits < 2^width := Nat.pow_lt_pow_right (by decide) fits
  have result := carry_word_to_nat bits value ((BitVec.ofNat width (2^bits)) >>> 1)
  have left := congrArg Prod.fst result
  have right := congrArg Prod.snd result
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.mod_eq_of_lt maskBound] at left right
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_zero, left, right]
  exact carry_stops bits value.toNat

def counter (bits : Nat) : Nat → Nat
  | 0 => 0
  | count+1 => counterTransition bits (counter bits count)

theorem counter_correct (bits count : Nat) (bound : count < 2^bits) :
    counter bits count = (reverseIndex bits ⟨count, bound⟩).val := by
  induction count with
  | zero => rw [counter, reverse_zero]
  | succ count ih =>
    have previous : count < 2^bits := by omega
    rw [counter, ih previous, transition_eq_advance]
    exact advance_correct bits ⟨count, previous⟩ ⟨count+1, bound⟩ rfl

def wordCounter {width : Nat} (bits : Nat) : Nat → BitVec width
  | 0 => 0#width
  | count+1 => wordTransition bits (wordCounter bits count)

theorem word_counter_to_nat {width : Nat} (bits : Nat) (fits : bits < width) (count : Nat) :
    (wordCounter (width := width) bits count).toNat = counter bits count := by
  induction count with
  | zero => rfl
  | succ count ih => rw [wordCounter, word_transition_to_nat bits fits, ih, counter]

theorem word_counter_correct {width : Nat} (bits : Nat) (fits : bits < width)
    (count : Nat) (bound : count < 2^bits) :
    (wordCounter (width := width) bits count).toNat = (reverseIndex bits ⟨count, bound⟩).val := by
  rw [word_counter_to_nat bits fits, counter_correct bits count bound]

theorem shift_preserves_nonnegative {width : Nat} (value : BitVec width) (positive : value.msb = false) :
    (value >>> 1).msb = false := by
  apply BitVec.msb_eq_false_iff_two_mul_lt.mpr
  rw [BitVec.toNat_ushiftRight]
  have before := BitVec.msb_eq_false_iff_two_mul_lt.mp positive
  have smaller := Nat.shiftRight_le value.toNat 1
  omega

def carrySignedWord {width : Nat} : Nat → BitVec width → BitVec width → BitVec width × BitVec width
  | 0, value, mask => (value, mask)
  | fuel+1, value, mask =>
    if value &&& mask = 0#width then (value, mask)
    else carrySignedWord fuel (value ^^^ mask) (mask.sshiftRight 1)

theorem signed_carry_agrees {width : Nat} (fuel : Nat) (value mask : BitVec width)
    (positive : mask.msb = false) : carrySignedWord fuel value mask = carryWord fuel value mask := by
  induction fuel generalizing value mask with
  | zero => rfl
  | succ fuel ih =>
    simp only [carrySignedWord, carryWord]
    split
    · rfl
    · rw [BitVec.sshiftRight_eq_of_msb_false positive]
      exact ih _ _ (shift_preserves_nonnegative mask positive)

def signedWordTransition {width : Nat} (bits : Nat) (value : BitVec width) : BitVec width :=
  let stopped := carrySignedWord bits value ((BitVec.ofNat width (2^bits)).sshiftRight 1)
  stopped.1 ^^^ stopped.2

theorem signed_transition_agrees {width : Nat} (bits : Nat) (fits : bits+1 < width)
    (value : BitVec width) : signedWordTransition bits value = wordTransition bits value := by
  have sizeBound : 2^bits < 2^width := Nat.pow_lt_pow_right (by decide) (by omega)
  have nonnegative : (BitVec.ofNat width (2^bits)).msb = false := by
    apply BitVec.msb_eq_false_iff_two_mul_lt.mpr
    rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt sizeBound]
    have larger : 2^(bits+1) < 2^width := Nat.pow_lt_pow_right (by decide) fits
    simpa only [Nat.pow_succ, Nat.mul_comm] using larger
  simp only [signedWordTransition, wordTransition, BitVec.sshiftRight_eq_of_msb_false nonnegative,
    signed_carry_agrees bits value _ (shift_preserves_nonnegative _ nonnegative)]

theorem signed_word_transition_to_nat {width : Nat} (bits : Nat) (fits : bits+1 < width)
    (value : BitVec width) : (signedWordTransition bits value).toNat = counterTransition bits value.toNat := by
  rw [signed_transition_agrees bits fits, word_transition_to_nat bits (by omega)]

def counterIndex (bits : Nat) (i : Fin (2^bits)) : Fin (2^bits) :=
  ⟨counter bits i.val, by rw [counter_correct bits i.val i.isLt]; exact (reverseIndex bits i).isLt⟩

theorem counter_index_correct (bits : Nat) (i : Fin (2^bits)) : counterIndex bits i = reverseIndex bits i := by
  apply Fin.ext
  exact counter_correct bits i.val i.isLt

def counterPermutation {F : Type} (bits : Nat) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  permutationPrefix (counterIndex bits) a (2^bits)

theorem counter_permutation_correct {F : Type} (bits : Nat) (a : Fin (2^bits) → F) :
    counterPermutation bits a = FftStages.permute (reverseIndex bits) a := by
  have indices : counterIndex bits = reverseIndex bits := funext (counter_index_correct bits)
  rw [counterPermutation, indices, permutation_pass_correct _ (reverse_index_involutive bits)]

def wordCounterIndex {width : Nat} (bits : Nat) (fits : bits < width) (i : Fin (2^bits)) : Fin (2^bits) :=
  ⟨(wordCounter (width := width) bits i.val).toNat,
    by rw [word_counter_correct bits fits i.val i.isLt]; exact (reverseIndex bits i).isLt⟩

theorem word_counter_index_correct {width : Nat} (bits : Nat) (fits : bits < width) (i : Fin (2^bits)) :
    wordCounterIndex bits fits i = reverseIndex bits i := by
  apply Fin.ext
  exact word_counter_correct bits fits i.val i.isLt

def wordPermutation {F : Type} {width : Nat} (bits : Nat) (fits : bits < width)
    (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  permutationPrefix (wordCounterIndex bits fits) a (2^bits)

theorem word_permutation_correct {F : Type} {width : Nat} (bits : Nat) (fits : bits < width)
    (a : Fin (2^bits) → F) : wordPermutation bits fits a = FftStages.permute (reverseIndex bits) a := by
  have indices : wordCounterIndex bits fits = reverseIndex bits := funext (word_counter_index_correct bits fits)
  rw [wordPermutation, indices, permutation_pass_correct _ (reverse_index_involutive bits)]

def forwardWithCounter {F : Type} [Field F] (width bits : Nat) (fits : bits+1 < width)
    (roots : Fin bits → F) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  runIndices false roots (List.finRange bits) (wordPermutation bits (by omega : bits < width) a)

def backwardWithCounter {F : Type} [Field F] (width bits : Nat) (fits : bits+1 < width)
    (roots : Fin bits → F) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  FftStages.scale (((2^bits : Nat) : F)⁻¹) (wordPermutation bits (by omega : bits < width)
    (runIndices true roots (List.finRange bits).reverse a))

theorem forward_with_counter_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (width bits : Nat) (fits : bits+1 < width) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    forwardWithCounter width bits fits (FftRadix.scalarStageRoots bits) a =
      CosetQap.dft (ScalarRoots.evaluationRoots bits) a := by
  rw [forwardWithCounter, word_permutation_correct,
    run_forward_correct (FftRadix.scalarStageRoots bits) (FftRadix.scalar_stage_roots_nonzero bits)]
  exact ScalarRoots.forward_correct bits bound a

theorem backward_with_counter_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (width bits : Nat) (fits : bits+1 < width) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    backwardWithCounter width bits fits (FftRadix.scalarStageRoots bits)
      (CosetQap.dft (ScalarRoots.evaluationRoots bits) a) = a := by
  rw [backwardWithCounter, word_permutation_correct,
    run_backward_correct (FftRadix.scalarStageRoots bits) (FftRadix.scalar_stage_roots_nonzero bits)]
  exact ScalarRoots.inverse_correct bits bound a

def counterTransform {F : Type} [Field F] [IsCharP F scalarModulus]
    (width bits : Nat) (fits : bits+1 < width) (bound : bits ≤ 32) :
    CosetQap.InverseTransform (ScalarRoots.evaluationRoots (F := F) bits) where
  inverse := backwardWithCounter width bits fits (FftRadix.scalarStageRoots bits)
  leftInverse := backward_with_counter_correct width bits fits bound

theorem quotient_with_counter_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (width bits : Nat) (fits : bits+1 < width) (bound : bits ≤ 32) (low high : Fin (2^bits) → F)
    (satisfied : ∀ i, CosetQap.splitNumerator low high (ScalarRoots.evaluationRoots bits i) = 0) :
    CosetQap.recoverQuotient (ScalarRoots.evaluationRoots bits) (counterTransform width bits fits bound) 7 low high = high := by
  apply CosetQap.coset_quotient_correct
    (ScalarRoots.evaluationRoots bits) (counterTransform width bits fits bound) (ScalarRoots.evaluation_roots_unity bits bound) 7
  · simpa only [Semiring.natCast_eq_ofNat] using
      FftRadix.small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  · exact ScalarRoots.coset_disjoint bits bound
  · exact satisfied

#print axioms advance_correct
#print axioms carry_stops
#print axioms transition_eq_advance
#print axioms transition_bound
#print axioms word_transition_to_nat
#print axioms word_carry_stops
#print axioms counter_correct
#print axioms word_counter_correct
#print axioms signed_word_transition_to_nat
#print axioms counter_permutation_correct
#print axioms forward_with_counter_correct
#print axioms backward_with_counter_correct
#print axioms quotient_with_counter_correct

end ZkBuild.FftCounter
