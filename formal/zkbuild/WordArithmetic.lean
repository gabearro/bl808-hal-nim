import ScalarMontgomery

/- Fixed-width expressions used by Constantine's portable RV32 primitives.
   All machine arithmetic below is BitVec arithmetic, including wraparound. -/
namespace ZkBuild.WordArithmetic

abbrev Word := BitVec 32
abbrev Wide := BitVec 64
def base : Nat := 2^32

structure Pair where
  hi : Word
  lo : Word
deriving Repr

def Pair.value (value : Pair) : Nat := value.lo.toNat + base * value.hi.toNat

def widen (value : Word) : Wide := value.setWidth 64
def split (value : Wide) : Pair := ⟨(value >>> 32).setWidth 32, value.setWidth 32⟩

theorem widen_value (value : Word) : (widen value).toNat = value.toNat := by
  exact BitVec.toNat_setWidth_of_le (by decide)

theorem split_value (value : Wide) : (split value).value = value.toNat := by
  have bound := value.isLt
  simp only [Pair.value, split, BitVec.toNat_setWidth, BitVec.toNat_ushiftRight, base]
  omega

def add (a b : Word) (carry : Nat) : Pair :=
  split (widen a + widen b + BitVec.ofNat 64 carry)

theorem add_value (a b : Word) (carry : Nat) (carry_bound : carry ≤ 1) :
    (add a b carry).value = a.toNat + b.toNat + carry := by
  have ha := a.isLt
  have hb := b.isLt
  rw [add, split_value]
  simp only [BitVec.toNat_add, widen_value, BitVec.toNat_ofNat]
  omega

theorem add_carry_bound (a b : Word) (carry : Nat) (carry_bound : carry ≤ 1) :
    (add a b carry).hi.toNat ≤ 1 := by
  have exact_value := add_value a b carry carry_bound
  have ha := a.isLt
  have hb := b.isLt
  unfold Pair.value base at exact_value
  omega

def multiplyAdd (a b c d : Word) : Pair :=
  split (widen a * widen b + widen c + widen d)

theorem multiplyAdd_value (a b c d : Word) :
    (multiplyAdd a b c d).value = a.toNat * b.toNat + c.toNat + d.toNat := by
  have ha : a.toNat ≤ 4294967295 := by have h := a.isLt; omega
  have hb : b.toNat ≤ 4294967295 := by have h := b.isLt; omega
  have hc := c.isLt
  have hd := d.isLt
  have product_bound := Nat.mul_le_mul ha hb
  rw [multiplyAdd, split_value]
  simp only [BitVec.toNat_add, BitVec.toNat_mul, widen_value]
  omega

structure Difference where
  borrow : Nat
  lo : Word
deriving Repr

def subtract (a b : Word) (borrow : Nat) : Difference :=
  let wide := widen a - widen b - BitVec.ofNat 64 borrow
  ⟨((wide >>> 32) &&& 1).toNat, wide.setWidth 32⟩

theorem subtract_value (a b : Word) (borrow : Nat) (borrow_bound : borrow ≤ 1) :
    a.toNat + base * (subtract a b borrow).borrow =
      b.toNat + borrow + (subtract a b borrow).lo.toNat := by
  have ha := a.isLt
  have hb := b.isLt
  simp [subtract, BitVec.toNat_and, BitVec.toNat_sub, widen_value,
    Nat.shiftRight_eq_div_pow, base]
  omega

theorem subtract_borrow_bound (a b : Word) (borrow : Nat) :
    (subtract a b borrow).borrow ≤ 1 := by
  simp [subtract, BitVec.toNat_and, Nat.shiftRight_eq_div_pow]
  omega

theorem subtract_borrow_iff (a b : Word) (borrow : Nat) (borrow_bound : borrow ≤ 1) :
    (subtract a b borrow).borrow = 1 ↔ a.toNat < b.toNat + borrow := by
  have value := subtract_value a b borrow borrow_bound
  have bounded := subtract_borrow_bound a b borrow
  have lo := (subtract a b borrow).lo.isLt
  have ha := a.isLt
  unfold base at value
  omega

def multiply (a b : Word) : Pair := split (widen a * widen b)
def multiplyAddOne (a b c : Word) : Pair := split (widen a * widen b + widen c)

theorem multiply_value (a b : Word) :
    (multiply a b).value = a.toNat * b.toNat := by
  simpa [multiplyAdd, multiply, widen] using multiplyAdd_value a b 0 0

theorem multiplyAddOne_value (a b c : Word) :
    (multiplyAddOne a b c).value = a.toNat * b.toNat + c.toNat := by
  simpa [multiplyAdd, multiplyAddOne, widen] using multiplyAdd_value a b c 0

theorem add_low (a b : Word) (carry : Nat) (carry_bound : carry ≤ 1) :
    (add a b carry).lo.toNat = (a.toNat + b.toNat + carry) % base := by
  have h := congrArg (fun n => n % base) (add_value a b carry carry_bound)
  have lo : (add a b carry).lo.toNat < base := (add a b carry).lo.isLt
  rw [Pair.value, Nat.add_mul_mod_self_left, Nat.mod_eq_of_lt lo] at h
  exact h

theorem multiply_low (a b : Word) :
    (multiply a b).lo.toNat = a.toNat * b.toNat % base := by
  have h := congrArg (fun n => n % base) (multiply_value a b)
  have lo : (multiply a b).lo.toNat < base := (multiply a b).lo.isLt
  rw [Pair.value, Nat.add_mul_mod_self_left, Nat.mod_eq_of_lt lo] at h
  exact h

structure Triple where
  hi : Word
  mid : Word
  lo : Word
deriving Repr

def Triple.value (value : Triple) : Nat :=
  value.lo.toNat + base * value.mid.toNat + base^2 * value.hi.toNat

def accumulate (t u v a b : Word) : Triple :=
  let product := multiply a b
  let low := add v product.lo 0
  let middle := add u product.hi low.hi.toNat
  ⟨t + BitVec.ofNat 32 middle.hi.toNat, middle.lo, low.lo⟩

theorem accumulate_low (t u v a b : Word) :
    (accumulate t u v a b).lo.toNat = (v.toNat + a.toNat*b.toNat) % base := by
  simp only [accumulate, add_low v _ 0 (by decide), Nat.add_zero, multiply_low,
    Nat.add_mod_mod]

theorem accumulate_cancels (t u v a b : Word) (cancelled : v + a*b = 0) :
    (accumulate t u v a b).lo = 0 := by
  apply BitVec.eq_of_toNat_eq
  have h := congrArg BitVec.toNat cancelled
  rw [accumulate_low]
  simpa only [BitVec.toNat_add, BitVec.toNat_mul, Nat.add_mod_mod, base] using h

theorem triple_bound (value : Triple) : value.value < base^3 := by
  have hi := value.hi.isLt
  have mid := value.mid.isLt
  have lo := value.lo.isLt
  unfold Triple.value base
  omega

theorem accumulate_correct (t u v a b : Word) :
    (accumulate t u v a b).value =
      (v.toNat + base*u.toNat + base^2*t.toNat + a.toNat*b.toNat) % base^3 := by
  let product := multiply a b
  let low := add v product.lo 0
  let middle := add u product.hi low.hi.toNat
  have product_value := multiply_value a b
  have low_value := add_value v product.lo 0 (by decide)
  have low_bound := add_carry_bound v product.lo 0 (by decide)
  have mid_value := add_value u product.hi low.hi.toNat low_bound
  have mid_bound := add_carry_bound u product.hi low.hi.toNat low_bound
  have top_value : (t + BitVec.ofNat 32 middle.hi.toNat).toNat =
      (t.toNat + middle.hi.toNat) % base := by
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat, base]
    have h : middle.hi.toNat < 2^32 := by change (add u product.hi low.hi.toNat).hi.toNat < _; omega
    rw [Nat.mod_eq_of_lt h]
  have top_split := Nat.mod_add_div (t.toNat + middle.hi.toNat) base
  have reconstructed : v.toNat + base*u.toNat + base^2*t.toNat + a.toNat*b.toNat =
      (accumulate t u v a b).value + base^3*((t.toNat + middle.hi.toNat)/base) := by
    change product.value = _ at product_value
    change low.value = _ at low_value
    change middle.value = _ at mid_value
    simp only [Pair.value, base] at product_value low_value mid_value top_value top_split
    simp only [accumulate, Triple.value]
    change _ = low.lo.toNat + base*middle.lo.toNat +
      base^2*(t + BitVec.ofNat 32 middle.hi.toNat).toNat + _
    rw [top_value]
    unfold base
    omega
  rw [reconstructed, Nat.add_mul_mod_self_left, Nat.mod_eq_of_lt (triple_bound _)]

theorem accumulate_no_overflow (t u v a b : Word)
    (bound : v.toNat + base*u.toNat + base^2*t.toNat + a.toNat*b.toNat < base^3) :
    (accumulate t u v a b).value =
      v.toNat + base*u.toNat + base^2*t.toNat + a.toNat*b.toNat := by
  rw [accumulate_correct, Nat.mod_eq_of_lt bound]

def productSum : List (Word × Word) → Nat
  | [] => 0
  | (a, b) :: rest => a.toNat*b.toNat + productSum rest

def accumulateProducts : Triple → List (Word × Word) → Triple
  | initial, [] => initial
  | initial, (a, b) :: rest =>
    accumulateProducts (accumulate initial.hi initial.mid initial.lo a b) rest

theorem accumulateProducts_exact (initial : Triple) (products : List (Word × Word))
    (bound : initial.value + productSum products < base^3) :
    (accumulateProducts initial products).value = initial.value + productSum products := by
  induction products generalizing initial with
  | nil => simp [accumulateProducts, productSum]
  | cons product rest ih =>
    obtain ⟨a, b⟩ := product
    have step_bound : initial.value + a.toNat*b.toNat < base^3 := by
      simp only [productSum] at bound
      omega
    have step := accumulate_no_overflow initial.hi initial.mid initial.lo a b step_bound
    change (accumulate initial.hi initial.mid initial.lo a b).value =
      initial.value + a.toNat*b.toNat at step
    have rest_bound : (accumulate initial.hi initial.mid initial.lo a b).value + productSum rest < base^3 := by
      rw [step]
      simpa [productSum, Nat.add_assoc] using bound
    rw [accumulateProducts, ih _ rest_bound, step]
    simp [productSum, Nat.add_assoc]

theorem productSum_bound (products : List (Word × Word)) :
    productSum products ≤ products.length * (4294967295 * 4294967295) := by
  induction products with
  | nil => simp [productSum]
  | cons product rest ih =>
    obtain ⟨a, b⟩ := product
    have ha : a.toNat ≤ 4294967295 := by have h := a.isLt; omega
    have hb : b.toNat ≤ 4294967295 := by have h := b.isLt; omega
    have product_bound := Nat.mul_le_mul ha hb
    simp only [productSum, List.length_cons, Nat.add_mul, Nat.one_mul]
    omega

-- Every FIPS column starts with t=0 after the previous right shift. Eight
-- RV32 scalar limbs contribute at most sixteen products to any one column.
theorem fips_column_exact (u v : Word) (products : List (Word × Word))
    (count : products.length ≤ 16) :
    (accumulateProducts ⟨0, u, v⟩ products).value =
      v.toNat + base*u.toNat + productSum products := by
  have hu := u.isLt
  have hv := v.isLt
  have sum_bound := productSum_bound products
  have h := Nat.mul_le_mul_right (4294967295 * 4294967295) count
  have bound : (Triple.mk 0 u v).value + productSum products < base^3 := by
    simp [Triple.value, base]
    omega
  simpa [Triple.value] using accumulateProducts_exact ⟨0, u, v⟩ products bound

def shiftColumn (value : Triple) : Triple := ⟨0, value.hi, value.mid⟩

theorem shiftColumn_value (value : Triple) : (shiftColumn value).value = value.value / base := by
  have lo := value.lo.isLt
  unfold shiftColumn Triple.value base
  simp
  omega

theorem shiftColumn_exact (value : Triple) (cancelled : value.lo = 0) :
    base * (shiftColumn value).value = value.value := by
  simp [shiftColumn, Triple.value, cancelled, Nat.mul_add, Nat.mul_assoc, Nat.pow_succ]

theorem fips_lower_indices (column index : Nat) (column_bound : column < 8)
    (index_bound : index < column) :
    index < 8 ∧ column-index < 8 ∧ 2*column+2 ≤ 16 := by omega

theorem fips_upper_indices (column index : Nat) (lower : 8 ≤ column)
    (upper : column < 16) (index_lower : column-8+1 ≤ index) (_index_upper : index < 8) :
    column-index < 8 ∧ 2*(15-column) ≤ 16 := by omega

-- The BLS12-381 scalar modulus has low limb 1 and negative inverse -1.
-- This is the exact low-word multiplication performed before the shift.
theorem fips_correction_cancels (t u v : Word) :
    (accumulate t u v (v * BitVec.ofNat 32 4294967295)
      (BitVec.ofNat 32 (scalarModulus % base))).lo = 0 := by
  apply accumulate_cancels
  have modulus_low : scalarModulus % base = 1 := by decide
  have inverse_word : BitVec.ofNat 32 4294967295 = -BitVec.ofNat 32 1 := by
    apply BitVec.eq_of_toNat_eq
    simp
  rw [modulus_low, inverse_word]
  rw [BitVec.mul_one, BitVec.mul_neg, BitVec.mul_one, BitVec.add_right_neg]
  simp

#print axioms add_value
#print axioms multiplyAdd_value
#print axioms subtract_value
#print axioms accumulate_correct
#print axioms fips_column_exact
#print axioms fips_correction_cancels

end ZkBuild.WordArithmetic
