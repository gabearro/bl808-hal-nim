import ScalarWords

/- Integer specification for Montgomery conversion. This proves the reduction
   relation and its bounds, not the external library's limb/carry implementation. -/
namespace ZkBuild.ScalarMontgomery

def correction (radix _modulus inverse input : Nat) : Nat :=
  input * inverse % radix

def quotient (radix modulus inverse input : Nat) : Nat :=
  (input + correction radix modulus inverse input * modulus) / radix

def reduceOnce (modulus value : Nat) : Nat :=
  if value < modulus then value else value - modulus

def reduce (radix modulus inverse input : Nat) : Nat :=
  reduceOnce modulus (quotient radix modulus inverse input)

theorem correction_cancels (radix modulus inverse input : Nat)
    (inverse_ok : (modulus * inverse + 1) % radix = 0) :
    (input + correction radix modulus inverse input * modulus) % radix = 0 := by
  calc
    _ = (input + input * inverse * modulus) % radix := by
      simp [correction, Nat.add_mod, Nat.mul_mod]
    _ = (input * (modulus * inverse + 1)) % radix := by
      congr 1
      simp [Nat.mul_add, Nat.mul_comm, Nat.mul_left_comm, Nat.add_comm]
    _ = 0 := by rw [Nat.mul_mod, inverse_ok]; simp

theorem quotient_exact (radix modulus inverse input : Nat)
    (inverse_ok : (modulus * inverse + 1) % radix = 0) :
    radix * quotient radix modulus inverse input =
      input + correction radix modulus inverse input * modulus := by
  have h := Nat.mod_add_div
    (input + correction radix modulus inverse input * modulus) radix
  rw [correction_cancels radix modulus inverse input inverse_ok] at h
  simpa [quotient] using h

theorem quotient_bound (radix modulus inverse input : Nat)
    (radix_pos : 0 < radix) (modulus_pos : 0 < modulus)
    (input_bound : input < modulus * radix) :
    quotient radix modulus inverse input < 2 * modulus := by
  have h := Nat.mul_lt_mul_of_pos_right
    (Nat.mod_lt (input * inverse) radix_pos) modulus_pos
  apply (Nat.div_lt_iff_lt_mul radix_pos).mpr
  have bound := Nat.add_lt_add input_bound h
  calc
    _ < modulus * radix + radix * modulus := bound
    _ = 2 * modulus * radix := by
      rw [Nat.two_mul, Nat.add_mul, Nat.mul_comm radix modulus]

theorem reduceOnce_eq_mod (modulus value : Nat) (bound : value < 2 * modulus) :
    reduceOnce modulus value = value % modulus := by
  unfold reduceOnce
  split
  next small => exact (Nat.mod_eq_of_lt small).symm
  next large =>
    rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]

theorem reduce_correct (radix modulus inverse radixInverse input : Nat)
    (radix_pos : 0 < radix) (modulus_pos : 0 < modulus)
    (inverse_ok : (modulus * inverse + 1) % radix = 0)
    (radix_inverse_ok : (radix * radixInverse) % modulus = 1)
    (input_bound : input < modulus * radix) :
    reduce radix modulus inverse input = (input * radixInverse) % modulus := by
  have exact_value := quotient_exact radix modulus inverse input inverse_ok
  have mod_value :
      (radix * quotient radix modulus inverse input) % modulus = input % modulus := by
    rw [exact_value, Nat.add_mod]
    simp
  have multiplied := congrArg (fun value => (value * radixInverse) % modulus) mod_value
  have reorder :
      (radix * quotient radix modulus inverse input) * radixInverse =
      quotient radix modulus inverse input * (radix * radixInverse) := by
    simp [Nat.mul_assoc, Nat.mul_comm, Nat.mul_left_comm]
  rw [Nat.mod_mul_mod, Nat.mod_mul_mod, reorder, Nat.mul_mod,
    radix_inverse_ok, Nat.mul_one, Nat.mod_mod] at multiplied
  exact (reduceOnce_eq_mod modulus _
    (quotient_bound radix modulus inverse input radix_pos modulus_pos input_bound)).trans multiplied

def scalarRadix : Nat := 2^256
def scalarNegativeInverse : Nat :=
  27711634432943687283656245953990505159342029877880134060146103271536583507967
def scalarRadixInverse : Nat :=
  12549076656233958353659347336803947287922716146853412054870763148006372261952
def scalarR2 : Nat := scalarRadix * scalarRadix % scalarModulus

-- These are kernel-checked concrete arithmetic facts, not native_decide axioms.
theorem scalar_constants :
    0 < scalarModulus ∧ scalarModulus < scalarRadix ∧
    (scalarModulus * scalarNegativeInverse + 1) % scalarRadix = 0 ∧
    (scalarRadix * scalarRadixInverse) % scalarModulus = 1 ∧
    scalarR2 = 3294906474794265442129797520630710739278575682199800681788903916070560242797 := by
  decide

theorem native_radices : (2^32)^8 = scalarRadix ∧ (2^64)^4 = scalarRadix := by decide

theorem native_negative_inverses :
    scalarNegativeInverse % 2^32 = 4294967295 ∧
    scalarNegativeInverse % 2^64 = 18446744069414584319 := by decide

def toMontgomery (value : Nat) : Nat :=
  reduce scalarRadix scalarModulus scalarNegativeInverse (value * scalarR2)

def fromMontgomery (value : Nat) : Nat :=
  reduce scalarRadix scalarModulus scalarNegativeInverse value

theorem toMontgomery_correct (value : Nat) (bound : value < scalarModulus) :
    toMontgomery value = value * scalarRadix % scalarModulus := by
  obtain ⟨modulus_pos, modulus_bound, negative_inverse, radix_inverse, _⟩ := scalar_constants
  have radix_pos : 0 < scalarRadix := by omega
  have r2_bound : scalarR2 < scalarRadix :=
    Nat.lt_trans (Nat.mod_lt _ modulus_pos) modulus_bound
  have input_bound : value * scalarR2 < scalarModulus * scalarRadix :=
    Nat.lt_of_le_of_lt (Nat.mul_le_mul_left value (Nat.le_of_lt r2_bound))
      (Nat.mul_lt_mul_of_pos_right bound radix_pos)
  unfold toMontgomery
  rw [reduce_correct _ _ _ scalarRadixInverse _ radix_pos modulus_pos
    negative_inverse radix_inverse input_bound]
  calc
    _ = ((value * scalarR2) % scalarModulus * scalarRadixInverse) % scalarModulus :=
      (Nat.mod_mul_mod _ _ _).symm
    _ = ((value * (scalarRadix * scalarRadix)) % scalarModulus * scalarRadixInverse) % scalarModulus := by
      rw [scalarR2, Nat.mul_mod_mod]
    _ = (value * (scalarRadix * (scalarRadix * scalarRadixInverse))) % scalarModulus := by
      rw [Nat.mod_mul_mod, Nat.mul_assoc, Nat.mul_assoc]
    _ = value * scalarRadix % scalarModulus := by
      simp only [Nat.mul_mod, radix_inverse, Nat.mul_one, Nat.mod_mod]

theorem fromMontgomery_correct (value : Nat) (bound : value < scalarModulus) :
    fromMontgomery value = value * scalarRadixInverse % scalarModulus := by
  obtain ⟨modulus_pos, modulus_bound, negative_inverse, radix_inverse, _⟩ := scalar_constants
  have radix_pos : 0 < scalarRadix := by omega
  have input_bound : value < scalarModulus * scalarRadix :=
    Nat.lt_of_lt_of_le bound (Nat.le_mul_of_pos_right _ radix_pos)
  exact reduce_correct _ _ _ _ _ radix_pos modulus_pos negative_inverse radix_inverse input_bound

theorem conversion_roundtrip (value : Nat) (bound : value < scalarModulus) :
    fromMontgomery (toMontgomery value) = value := by
  have modulus_pos := scalar_constants.1
  have radix_inverse := scalar_constants.2.2.2.1
  rw [toMontgomery_correct value bound, fromMontgomery_correct _ (Nat.mod_lt _ modulus_pos)]
  rw [Nat.mod_mul_mod, Nat.mul_assoc, Nat.mul_mod, radix_inverse]
  simp [Nat.mod_eq_of_lt bound]

theorem canonical_conversion (bytes : List (Fin 256))
    (accepted : ScalarEncoding.canonical bytes = true) :
    toMontgomery (ScalarEncoding.valueBE bytes) =
      ScalarEncoding.valueBE bytes * scalarRadix % scalarModulus ∧
    fromMontgomery (toMontgomery (ScalarEncoding.valueBE bytes)) = ScalarEncoding.valueBE bytes := by
  have bound := (ScalarEncoding.canonical_iff bytes).mp accepted
  exact ⟨toMontgomery_correct _ bound.2, conversion_roundtrip _ bound.2⟩

#print axioms reduce_correct
#print axioms toMontgomery_correct
#print axioms conversion_roundtrip

end ZkBuild.ScalarMontgomery
