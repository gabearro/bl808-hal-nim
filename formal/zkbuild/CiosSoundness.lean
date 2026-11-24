import CiosMontgomery

namespace ZkBuild.CiosSoundness

open WordArithmetic FipsMontgomery FipsSoundness CiosMontgomery

theorem column_chain (carry output input products : Nat → Nat) (low : Nat)
    (first : low+base*carry 0 = products 0+input 0)
    (columns : ∀ i, i < 7 → output i+base*carry (i+1) = products (i+1)+carry i+input (i+1))
    (last : output 7 = carry 7) :
    base*weighted output+low = weighted input+weighted products := by
  have h0 := columns 0 (by decide)
  have h1 := columns 1 (by decide)
  have h2 := columns 2 (by decide)
  have h3 := columns 3 (by decide)
  have h4 := columns 4 (by decide)
  have h5 := columns 5 (by decide)
  have h6 := columns 6 (by decide)
  simp only [Nat.reduceAdd, base] at first h0 h1 h2 h3 h4 h5 h6
  simp only [weighted, weightedAt, base]
  omega

theorem weighted_mul (radix m : Nat) (values : Nat → Nat) :
    weightedAt radix (fun i => m*values i) = m*weightedAt radix values := by
  simp only [weightedAt, Nat.mul_add]
  ac_rfl

theorem step_balance (input : Words) :
    base*wordsValue (CiosMontgomery.step input) = wordsValue input+(multiplier input).toNat*scalarModulus := by
  have h := column_chain (fun i => (inner input i).carry.toNat)
    (fun i => (get (CiosMontgomery.step input) i).toNat) (fun i => (get input i).toNat)
    (fun i => (multiplier input).toNat*(get modulus i).toNat) (firstPair input).lo.toNat
    (first_value input) (fun i bound => column_value input i bound)
    (congrArg BitVec.toNat (step_high input))
  have zero : (firstPair input).lo.toNat = 0 := by rw [first_cancels]; rfl
  rw [zero, Nat.add_zero, ←words_weighted, ←words_weighted] at h
  change base*wordsValue (CiosMontgomery.step input) = wordsValue input+
    weightedAt base (fun i => (multiplier input).toNat*(get modulus i).toNat) at h
  rw [weighted_mul] at h
  change base*wordsValue (CiosMontgomery.step input) = wordsValue input+
    (multiplier input).toNat*weighted (fun i => (get modulus i).toNat) at h
  rw [←words_weighted modulus, modulus_value] at h
  exact h

theorem outer_chain (states coefficients : Nat → Nat)
    (steps : ∀ i, i < 8 → base*states (i+1) = states i+coefficients i) :
    base^8*states 8 = states 0+weighted coefficients := by
  have h0 := steps 0 (by decide)
  have h1 := steps 1 (by decide)
  have h2 := steps 2 (by decide)
  have h3 := steps 3 (by decide)
  have h4 := steps 4 (by decide)
  have h5 := steps 5 (by decide)
  have h6 := steps 6 (by decide)
  have h7 := steps 7 (by decide)
  simp only [Nat.reduceAdd, base] at h0 h1 h2 h3 h4 h5 h6 h7
  simp only [weighted, weightedAt, base]
  omega

def corrections (input : Words) : Words := fun i => multiplier (outerPrefix input i.val)

theorem corrections_value (input : Words) : wordsValue (corrections input) =
    weighted (fun i => (multiplier (outerPrefix input i)).toNat) := by
  rw [words_weighted]
  simp [weighted, weightedAt, FipsMontgomery.get, corrections]

theorem weighted_mul_right (radix m : Nat) (values : Nat → Nat) :
    weightedAt radix (fun i => values i*m) = weightedAt radix values*m := by
  simp only [weightedAt, Nat.add_mul]
  ac_rfl

theorem full_balance (input : Words) :
    ScalarMontgomery.scalarRadix*wordsValue (outerPrefix input 8) =
      wordsValue input+wordsValue (corrections input)*scalarModulus := by
  have h := outer_chain (fun i => wordsValue (outerPrefix input i))
    (fun i => (multiplier (outerPrefix input i)).toNat*scalarModulus)
    (fun i _ => step_balance (outerPrefix input i))
  have conversion : base^8 = ScalarMontgomery.scalarRadix := by decide
  change base^8*wordsValue (outerPrefix input 8) = wordsValue input+
    weightedAt base (fun i => (multiplier (outerPrefix input i)).toNat*scalarModulus) at h
  rw [conversion, weighted_mul_right] at h
  change ScalarMontgomery.scalarRadix*wordsValue (outerPrefix input 8) =
    wordsValue input+weighted (fun i => (multiplier (outerPrefix input i)).toNat)*scalarModulus at h
  rw [←corrections_value] at h
  exact h

theorem reduced_bound (radix p input correction output : Nat)
    (_radix_pos : 0 < radix) (p_pos : 0 < p) (input_bound : input < radix)
    (correction_bound : correction < radix)
    (balance : radix*output = input+correction*p) : output < 2*p := by
  have product_bound := Nat.mul_lt_mul_of_pos_right correction_bound p_pos
  have total_bound := Nat.add_lt_add input_bound product_bound
  have h : radix*output < radix*(p+1) := by
    rw [balance]
    simpa [Nat.mul_add, Nat.add_comm] using total_bound
  have small := Nat.lt_of_mul_lt_mul_left h
  omega

theorem result_correct (input : Words) : wordsValue (CiosMontgomery.result input) =
    wordsValue input*ScalarMontgomery.scalarRadixInverse%scalarModulus := by
  have equation := full_balance input
  have bound := reduced_bound ScalarMontgomery.scalarRadix scalarModulus
    (wordsValue input) (wordsValue (corrections input)) (wordsValue (outerPrefix input 8))
    (by decide) ScalarMontgomery.scalar_constants.1 (words_bound _) (words_bound _) equation
  have residue := residue_of_balance ScalarMontgomery.scalarRadix scalarModulus
    ScalarMontgomery.scalarRadixInverse (wordsValue input) (wordsValue (corrections input))
    (wordsValue (outerPrefix input 8)) ScalarMontgomery.scalar_constants.2.2.2.1 equation
  rw [CiosMontgomery.result, finish_value _ (by rfl), ScalarMontgomery.reduceOnce_eq_mod _ _ bound]
  exact residue

theorem scalar_roundtrip (value : Nat) (bound : value < scalarModulus) :
    wordsValue (CiosMontgomery.result
      (FipsMontgomery.result (fromNat value) (fromNat ScalarMontgomery.scalarR2))) = value := by
  rw [result_correct, fromBig_correct value bound, Nat.mod_mul_mod, Nat.mul_assoc, Nat.mul_mod,
    ScalarMontgomery.scalar_constants.2.2.2.1, Nat.mul_one, Nat.mod_mod, Nat.mod_eq_of_lt bound]

#print axioms step_balance
#print axioms full_balance
#print axioms result_correct
#print axioms scalar_roundtrip

end ZkBuild.CiosSoundness
