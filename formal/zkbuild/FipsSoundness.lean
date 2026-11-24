import FipsMontgomery

namespace ZkBuild.FipsSoundness

open WordArithmetic FipsMontgomery

def weightedAt (radix : Nat) (values : Nat → Nat) : Nat :=
  values 0 + radix*values 1 + radix^2*values 2 + radix^3*values 3 +
  radix^4*values 4 + radix^5*values 5 + radix^6*values 6 + radix^7*values 7

def weighted (values : Nat → Nat) : Nat := weightedAt base values

def lowerCoefficient (a b q : Words) (column : Nat) : Nat :=
  productSum (lowerProducts a b q column) + (get q column).toNat*(get modulus 0).toNat

def upperCoefficient (a b q : Words) (output : Nat) : Nat :=
  productSum (upperProducts a b q output)

theorem words_weighted (words : Words) : wordsValue words = weighted (fun i => (get words i).toNat) := by
  have indices : List.range 8 = [0,1,2,3,4,5,6,7] := by decide
  simp only [wordsValue, indices, List.map_cons, List.map_nil, ScalarWords.recombine]
  simp [weighted, weightedAt, Nat.mul_add, Nat.add_assoc, Nat.pow_succ, Nat.mul_assoc]

theorem lower_products_final (a b : Words) (column : Nat) (bound : column < 8) :
    lowerProducts a b (lowerPrefix a b column).z column =
      lowerProducts a b (lowerPrefix a b 8).z column := by
  unfold lowerProducts
  congr 1
  simp only [List.flatMap_def]
  apply congrArg List.flatten
  apply List.map_congr_left
  intro index member
  have index_bound := List.mem_range.mp member
  have stable := lower_stable a b 8 column index (by omega) index_bound
  rw [stable]

theorem upper_products_final (a b : Words) (output : Nat) :
    upperProducts a b (upperPrefix a b output).z output =
      upperProducts a b (lowerPrefix a b 8).z output := by
  unfold upperProducts
  simp only [List.flatMap_def]
  apply congrArg List.flatten
  apply List.map_congr_left
  intro offset member
  have stable := upper_live_corrections a b output (output+1+offset) (by omega)
  rw [stable]

theorem upper_stable (a b : Words) (count earlier index : Nat)
    (order : earlier ≤ count) (written : index < earlier) :
    get (upperPrefix a b count).z index = get (upperPrefix a b earlier).z index := by
  induction count with
  | zero =>
    have h : earlier = 0 := by omega
    subst h
    rfl
  | succ n ih =>
    by_cases same : earlier = n+1
    · subst same; rfl
    · rw [upperPrefix, upper_untouched a b n index _ (by omega)]
      exact ih (by omega)

theorem lower_step (a b : Words) (column : Nat) (bound : column < 8) :
    base*(lowerPrefix a b (column+1)).acc.value =
      (lowerPrefix a b column).acc.value + lowerCoefficient a b (lowerPrefix a b 8).z column := by
  have h := all_lower_steps a b column bound
  rw [lower_products_final a b column bound] at h
  simpa only [lowerCoefficient, Nat.add_assoc] using h

theorem upper_step (a b : Words) (output : Nat) (bound : output < 8) :
    base*(upperPrefix a b (output+1)).acc.value + (get (upperPrefix a b 8).z output).toNat =
      (upperPrefix a b output).acc.value + upperCoefficient a b (lowerPrefix a b 8).z output := by
  have h := all_upper_steps a b output bound
  have stable := upper_stable a b 8 (output+1) output (by omega) (by omega)
  rw [upper_products_final a b output, ←stable] at h
  exact h

theorem lower_total (a b : Words) :
    base^8*(lowerPrefix a b 8).acc.value = weighted (lowerCoefficient a b (lowerPrefix a b 8).z) := by
  have h0 := lower_step a b 0 (by decide)
  have h1 := lower_step a b 1 (by decide)
  have h2 := lower_step a b 2 (by decide)
  have h3 := lower_step a b 3 (by decide)
  have h4 := lower_step a b 4 (by decide)
  have h5 := lower_step a b 5 (by decide)
  have h6 := lower_step a b 6 (by decide)
  have h7 := lower_step a b 7 (by decide)
  have zero : (lowerPrefix a b 0).acc.value = 0 := by rfl
  simp only [Nat.reduceAdd, base] at h0 h1 h2 h3 h4 h5 h6 h7
  rw [zero] at h0
  simp only [weighted, weightedAt, base]
  omega

theorem upper_total (a b : Words) :
    base^8*(upperPrefix a b 8).acc.value + wordsValue (upperPrefix a b 8).z =
      (lowerPrefix a b 8).acc.value + weighted (upperCoefficient a b (lowerPrefix a b 8).z) := by
  have h0 := upper_step a b 0 (by decide)
  have h1 := upper_step a b 1 (by decide)
  have h2 := upper_step a b 2 (by decide)
  have h3 := upper_step a b 3 (by decide)
  have h4 := upper_step a b 4 (by decide)
  have h5 := upper_step a b 5 (by decide)
  have h6 := upper_step a b 6 (by decide)
  have h7 := upper_step a b 7 (by decide)
  have start : (upperPrefix a b 0).acc.value = (lowerPrefix a b 8).acc.value := rfl
  simp only [Nat.reduceAdd, base] at h0 h1 h2 h3 h4 h5 h6 h7
  rw [start] at h0
  rw [words_weighted]
  simp only [weighted, weightedAt, base]
  omega

def lowAt (a b q m : Nat → Nat) (column : Nat) : Nat :=
  ((List.range column).map fun j => a j*b (column-j)+q j*m (column-j)).sum +
    a column*b 0 + q column*m 0

def highAt (a b q m : Nat → Nat) (output : Nat) : Nat :=
  ((List.range (7-output)).map fun offset =>
    a (output+1+offset)*b (7-offset)+q (output+1+offset)*m (7-offset)).sum

theorem pair_sum (indices : List Nat) (f g : Nat → Word × Word) :
    productSum (indices.flatMap fun i => [f i, g i]) =
      (indices.map fun i => (f i).1.toNat*(f i).2.toNat+(g i).1.toNat*(g i).2.toNat).sum := by
  induction indices with
  | nil => rfl
  | cons i rest ih => simp [productSum, ih, Nat.add_assoc]

theorem lower_as_polynomial (a b q : Words) : lowerCoefficient a b q =
    lowAt (fun i => (get a i).toNat) (fun i => (get b i).toNat)
      (fun i => (get q i).toNat) (fun i => (get modulus i).toNat) := by
  funext column
  simp only [lowerCoefficient, lowerProducts, productSum_append, productSum, Nat.add_zero,
    pair_sum, lowAt]

theorem upper_as_polynomial (a b q : Words) : upperCoefficient a b q =
    highAt (fun i => (get a i).toNat) (fun i => (get b i).toNat)
      (fun i => (get q i).toNat) (fun i => (get modulus i).toNat) := by
  funext output
  simp only [upperCoefficient, upperProducts, highAt, pair_sum]

set_option maxRecDepth 10000 in
theorem polynomial_product (radix : Nat) (a b q m : Nat → Nat) :
    weightedAt radix (lowAt a b q m) + radix^8*weightedAt radix (highAt a b q m) =
      weightedAt radix a*weightedAt radix b + weightedAt radix q*weightedAt radix m := by
  simp [weightedAt, lowAt, highAt, List.range_succ]
  simp only [Nat.mul_add, Nat.add_mul, Nat.pow_succ, Nat.pow_zero, Nat.one_mul]
  ac_rfl

theorem coefficient_identity (a b q : Words) :
    weighted (lowerCoefficient a b q) + base^8*weighted (upperCoefficient a b q) =
      wordsValue a*wordsValue b + wordsValue q*wordsValue modulus := by
  rw [words_weighted, words_weighted, words_weighted, words_weighted]
  rw [lower_as_polynomial, upper_as_polynomial]
  exact polynomial_product base _ _ _ _

theorem combine_relations (radix carry finalCarry output lower upper total : Nat)
    (low : radix^8*carry = lower) (high : radix^8*finalCarry+output = carry+upper)
    (coefficients : lower+radix^8*upper = total) :
    radix^16*finalCarry+radix^8*output = total := by
  have hpow : radix^16 = radix^8*radix^8 := by exact Nat.pow_add radix 8 8
  calc
    _ = radix^8*(radix^8*finalCarry+output) := by
      rw [hpow, Nat.mul_add, Nat.mul_assoc]
    _ = radix^8*(carry+upper) := congrArg (fun x => radix^8*x) high
    _ = lower+radix^8*upper := by rw [Nat.mul_add, low]
    _ = _ := coefficients

theorem full_balance (a b : Words) :
    base^16*(upperPrefix a b 8).acc.value + base^8*wordsValue (upperPrefix a b 8).z =
      wordsValue a*wordsValue b + wordsValue (lowerPrefix a b 8).z*wordsValue modulus :=
  combine_relations base _ _ _ _ _ _ (lower_total a b) (upper_total a b)
    (coefficient_identity a b (lowerPrefix a b 8).z)

theorem words_bound (words : Words) : wordsValue words < ScalarMontgomery.scalarRadix := by
  have h0 := (get words 0).isLt
  have h1 := (get words 1).isLt
  have h2 := (get words 2).isLt
  have h3 := (get words 3).isLt
  have h4 := (get words 4).isLt
  have h5 := (get words 5).isLt
  have h6 := (get words 6).isLt
  have h7 := (get words 7).isLt
  rw [words_weighted]
  simp only [weighted, weightedAt, base, ScalarMontgomery.scalarRadix]
  omega

theorem split_value (value : Nat) :
    weighted (fun i => value/base^i % base) = value%ScalarMontgomery.scalarRadix := by
  have split (i : Nat) : value/base^i % base + base*(value/base^(i+1)) = value/base^i := by
    have h := Nat.mod_add_div (value/base^i) base
    rw [Nat.div_div_eq_div_mul, ←Nat.pow_succ] at h
    exact h
  have h0 := split 0
  have h1 := split 1
  have h2 := split 2
  have h3 := split 3
  have h4 := split 4
  have h5 := split 5
  have h6 := split 6
  have h7 := split 7
  have finish := Nat.mod_add_div value ScalarMontgomery.scalarRadix
  simp only [Nat.reduceAdd, Nat.pow_zero, Nat.div_one, base] at h0 h1 h2 h3 h4 h5 h6 h7
  simp only [weighted, weightedAt, base, ScalarMontgomery.scalarRadix] at *
  omega

theorem fromNat_value (value : Nat) : wordsValue (fromNat value) = value%ScalarMontgomery.scalarRadix := by
  rw [words_weighted]
  have indices (i : Nat) (bound : i < 8) :
      (get (fromNat value) i).toNat = value/base^i % base := by
    simp [FipsMontgomery.get, fromNat, bound, base]
  simp only [weighted, weightedAt]
  rw [indices 0 (by decide), indices 1 (by decide), indices 2 (by decide), indices 3 (by decide),
    indices 4 (by decide), indices 5 (by decide), indices 6 (by decide), indices 7 (by decide)]
  exact split_value value

theorem modulus_value : wordsValue modulus = scalarModulus := by
  change wordsValue (fromNat scalarModulus) = scalarModulus
  rw [fromNat_value, Nat.mod_eq_of_lt ScalarMontgomery.scalar_constants.2.1]

theorem bounded_balance (radix p x y q carry output : Nat)
    (radix_pos : 0 < radix) (p_pos : 0 < p) (spare : 2*p < radix)
    (x_bound : x < p) (y_bound : y < p) (q_bound : q < radix)
    (balance : radix^2*carry+radix*output = x*y+q*p) :
    carry = 0 ∧ output < 2*p ∧ radix*output = x*y+q*p := by
  have p_bound : p < radix := by omega
  have y_radix : y < radix := Nat.lt_trans y_bound p_bound
  have product_bound : x*y < p*radix :=
    Nat.lt_of_le_of_lt (Nat.mul_le_mul_left x (Nat.le_of_lt y_radix))
      (Nat.mul_lt_mul_of_pos_right x_bound radix_pos)
  have correction_bound : q*p < radix*p := Nat.mul_lt_mul_of_pos_right q_bound p_pos
  have total_bound : x*y+q*p < 2*p*radix := by
    have h := Nat.add_lt_add product_bound correction_bound
    simpa only [Nat.two_mul, Nat.add_mul, Nat.mul_comm radix p] using h
  have capacity_bound : 2*p*radix < radix^2 := by
    have h := Nat.mul_lt_mul_of_pos_right spare radix_pos
    simpa [Nat.pow_two] using h
  have high_bound : radix^2*carry < radix^2*1 := by
    calc
      _ ≤ radix^2*carry+radix*output := Nat.le_add_right _ _
      _ = x*y+q*p := balance
      _ < radix^2 := Nat.lt_trans total_bound capacity_bound
      _ = radix^2*1 := by simp
  have zero : carry = 0 := by have h := Nat.lt_of_mul_lt_mul_left high_bound; omega
  have exact_value : radix*output = x*y+q*p := by simpa [zero] using balance
  have low_bound : output < 2*p := by
    have h : radix*output < radix*(2*p) := by simpa [exact_value, Nat.mul_comm] using total_bound
    exact Nat.lt_of_mul_lt_mul_left h
  exact ⟨zero, low_bound, exact_value⟩

theorem residue_of_balance (radix p inverse input q output : Nat)
    (inverse_ok : radix*inverse%p = 1) (balance : radix*output = input+q*p) :
    output%p = input*inverse%p := by
  have residue : radix*output%p = input%p := by rw [balance, Nat.add_mod]; simp
  have multiplied := congrArg (fun x => x*inverse%p) residue
  have reorder : (radix*output)*inverse = output*(radix*inverse) := by
    simp [Nat.mul_comm, Nat.mul_left_comm]
  rw [Nat.mod_mul_mod, Nat.mod_mul_mod, reorder, Nat.mul_mod, inverse_ok,
    Nat.mul_one, Nat.mod_mod] at multiplied
  exact multiplied

theorem finish_value (state : State) (zero : state.acc.value = 0) :
    wordsValue (finish state) = ScalarMontgomery.reduceOnce scalarModulus (wordsValue state.z) := by
  have lo_value : state.acc.lo.toNat = 0 := by
    unfold Triple.value at zero
    omega
  have lo : state.acc.lo = 0 := by
    apply BitVec.eq_of_toNat_eq
    simpa using lo_value
  have capacity := words_bound state.z
  by_cases small : wordsValue state.z < scalarModulus
  · have ge : ¬ scalarModulus ≤ wordsValue state.z := by omega
    simp [finish, lo, ge, ScalarMontgomery.reduceOnce, small]
  · have ge : scalarModulus ≤ wordsValue state.z := by omega
    have subtraction : wordsValue state.z+ScalarMontgomery.scalarRadix-scalarModulus =
        ScalarMontgomery.scalarRadix+(wordsValue state.z-scalarModulus) := by omega
    simp [finish, lo, ge, fromNat_value, ScalarMontgomery.reduceOnce, small]
    rw [subtraction, Nat.add_mod_left, Nat.mod_eq_of_lt (by omega)]

theorem result_correct (a b : Words) (a_bound : wordsValue a < scalarModulus)
    (b_bound : wordsValue b < scalarModulus) :
    wordsValue (result a b) =
      wordsValue a*wordsValue b*ScalarMontgomery.scalarRadixInverse%scalarModulus := by
  have equation := full_balance a b
  have conversion : base^8 = ScalarMontgomery.scalarRadix := by decide
  have conversion2 : base^16 = ScalarMontgomery.scalarRadix^2 := by decide
  rw [conversion, conversion2, modulus_value] at equation
  have spare : 2*scalarModulus < ScalarMontgomery.scalarRadix := by decide
  have bounded := bounded_balance ScalarMontgomery.scalarRadix scalarModulus
    (wordsValue a) (wordsValue b) (wordsValue (lowerPrefix a b 8).z)
    (upperPrefix a b 8).acc.value (wordsValue (upperPrefix a b 8).z)
    (by decide) ScalarMontgomery.scalar_constants.1 spare a_bound b_bound
    (words_bound _) equation
  have residue := residue_of_balance ScalarMontgomery.scalarRadix scalarModulus
    ScalarMontgomery.scalarRadixInverse (wordsValue a*wordsValue b)
    (wordsValue (lowerPrefix a b 8).z) (wordsValue (upperPrefix a b 8).z)
    ScalarMontgomery.scalar_constants.2.2.2.1 bounded.2.2
  rw [result, finish_value _ bounded.1, ScalarMontgomery.reduceOnce_eq_mod _ _ bounded.2.1]
  exact residue

theorem fromBig_correct (value : Nat) (bound : value < scalarModulus) :
    wordsValue (result (fromNat value) (fromNat ScalarMontgomery.scalarR2)) =
      value*ScalarMontgomery.scalarRadix%scalarModulus := by
  have p_pos := ScalarMontgomery.scalar_constants.1
  have p_bound := ScalarMontgomery.scalar_constants.2.1
  have r2_bound : ScalarMontgomery.scalarR2 < scalarModulus := Nat.mod_lt _ p_pos
  have left : wordsValue (fromNat value) = value := by
    rw [fromNat_value, Nat.mod_eq_of_lt (Nat.lt_trans bound p_bound)]
  have right : wordsValue (fromNat ScalarMontgomery.scalarR2) = ScalarMontgomery.scalarR2 := by
    rw [fromNat_value, Nat.mod_eq_of_lt (Nat.lt_trans r2_bound p_bound)]
  rw [result_correct _ _ (by rwa [left]) (by rwa [right]), left, right]
  calc
    _ = ((value*ScalarMontgomery.scalarR2)%scalarModulus*ScalarMontgomery.scalarRadixInverse)%scalarModulus :=
      (Nat.mod_mul_mod _ _ _).symm
    _ = ((value*(ScalarMontgomery.scalarRadix*ScalarMontgomery.scalarRadix))%scalarModulus*
        ScalarMontgomery.scalarRadixInverse)%scalarModulus := by
      rw [ScalarMontgomery.scalarR2, Nat.mul_mod_mod]
    _ = (value*(ScalarMontgomery.scalarRadix*(ScalarMontgomery.scalarRadix*
        ScalarMontgomery.scalarRadixInverse)))%scalarModulus := by
      rw [Nat.mod_mul_mod, Nat.mul_assoc, Nat.mul_assoc]
    _ = _ := by
      simp only [Nat.mul_mod, ScalarMontgomery.scalar_constants.2.2.2.1, Nat.mul_one, Nat.mod_mod]

#print axioms full_balance
#print axioms result_correct
#print axioms fromBig_correct

end ZkBuild.FipsSoundness
