import WordArithmetic

/- RV32, eight-limb FIPS schedule used by the pinned field conversion.
   The same z array holds correction words and is then overwritten by output. -/
namespace ZkBuild.FipsMontgomery

open WordArithmetic

abbrev Words := Fin 8 → Word
def get (words : Words) (index : Nat) : Word :=
  if h : index < 8 then words ⟨index, h⟩ else 0
def put (words : Words) (index : Nat) (value : Word) : Words :=
  fun i => if i.val = index then value else words i

def zeroWords : Words := fun _ => 0
def modulus : Words := fun i => BitVec.ofNat 32 (scalarModulus / base^i.val)
def inverseWord : Word := BitVec.ofNat 32 4294967295

structure State where
  acc : Triple
  z : Words

def initial : State := ⟨⟨0, 0, 0⟩, zeroWords⟩

def lowerProducts (a b z : Words) (column : Nat) : List (Word × Word) :=
  (List.range column).flatMap (fun j =>
    [(get a j, get b (column-j)), (get z j, get modulus (column-j))]) ++
  [(get a column, get b 0)]

def lowerRow (a b : Words) (column : Nat) (state : State) : State :=
  let pending := accumulateProducts state.acc (lowerProducts a b state.z column)
  let correction := pending.lo * inverseWord
  ⟨accumulate pending.hi pending.mid pending.lo correction (get modulus 0),
    put state.z column correction⟩

def advance (state : State) : State := ⟨shiftColumn state.acc, state.z⟩
def lowerStep (a b : Words) (column : Nat) (state : State) : State :=
  advance (lowerRow a b column state)

def upperProducts (a b z : Words) (output : Nat) : List (Word × Word) :=
  (List.range (7-output)).flatMap fun offset =>
    let j := output+1+offset
    [(get a j, get b (7-offset)), (get z j, get modulus (7-offset))]

def upperRow (a b : Words) (output : Nat) (state : State) : State :=
  let pending := accumulateProducts state.acc (upperProducts a b state.z output)
  ⟨pending, put state.z output pending.lo⟩

def upperStep (a b : Words) (output : Nat) (state : State) : State :=
  advance (upperRow a b output state)

theorem accumulateProducts_append (state : Triple) (left right : List (Word × Word)) :
    accumulateProducts state (left ++ right) =
      accumulateProducts (accumulateProducts state left) right := by
  induction left generalizing state with
  | nil => rfl
  | cons product rest ih =>
    obtain ⟨a, b⟩ := product
    simpa [accumulateProducts] using ih (accumulate state.hi state.mid state.lo a b)

theorem productSum_append (left right : List (Word × Word)) :
    productSum (left ++ right) = productSum left + productSum right := by
  induction left with
  | nil => simp [productSum]
  | cons product rest ih =>
    obtain ⟨a, b⟩ := product
    simp [productSum, ih, Nat.add_assoc]

theorem paired_length (indices : List Nat) (pairs : Nat → (Word × Word) × (Word × Word)) :
    (indices.flatMap fun i => [(pairs i).1, (pairs i).2]).length = 2*indices.length := by
  induction indices with
  | nil => simp
  | cons i rest ih => simp [ih, Nat.mul_add, Nat.add_assoc]

theorem lower_length (a b z : Words) (column : Nat) :
    (lowerProducts a b z column).length = 2*column+1 := by
  simp only [lowerProducts, List.length_append, List.length_cons, List.length_nil]
  have h := paired_length (List.range column) (fun j =>
    ((get a j, get b (column-j)), (get z j, get modulus (column-j))))
  simp only [List.length_range] at h
  omega

theorem upper_length (a b z : Words) (output : Nat) :
    (upperProducts a b z output).length = 2*(7-output) := by
  have h := paired_length (List.range (7-output)) (fun offset =>
    ((get a (output+1+offset), get b (7-offset)),
      (get z (output+1+offset), get modulus (7-offset))))
  simpa [upperProducts] using h

theorem modulus_low : get modulus 0 = BitVec.ofNat 32 (scalarModulus % base) := by
  apply BitVec.eq_of_toNat_eq
  simp [get, modulus, base]

theorem get_put (words : Words) (index : Nat) (bound : index < 8) (value : Word) :
    get (put words index value) index = value := by
  simp [get, put, bound]

theorem get_put_other (words : Words) (index other : Nat) (value : Word)
    (different : other ≠ index) : get (put words index value) other = get words other := by
  by_cases bound : other < 8 <;> simp [get, put, bound, different]

theorem lower_cancels (a b : Words) (column : Nat) (state : State) :
    (lowerRow a b column state).acc.lo = 0 := by
  unfold lowerRow
  rw [modulus_low]
  exact fips_correction_cancels _ _ _

theorem corrected_value (state : Triple) (products : List (Word × Word)) (correction m0 : Word)
    (high_zero : state.hi = 0) (count : products.length+1 ≤ 16) :
    let pending := accumulateProducts state products
    (accumulate pending.hi pending.mid pending.lo correction m0).value =
      state.value + productSum products + correction.toNat*m0.toNat := by
  have bound : (products ++ [(correction, m0)]).length ≤ 16 := by simpa using count
  have full := fips_column_exact state.mid state.lo (products ++ [(correction, m0)]) bound
  have init_eq : (Triple.mk 0 state.mid state.lo) = state := by cases state; simp_all
  rw [init_eq, accumulateProducts_append] at full
  simpa [accumulateProducts, productSum_append, productSum, Triple.value,
    high_zero, Nat.add_assoc] using full

theorem lower_row_value (a b : Words) (column : Nat) (state : State)
    (column_bound : column < 8) (high_zero : state.acc.hi = 0) :
    (lowerRow a b column state).acc.value =
      state.acc.value + productSum (lowerProducts a b state.z column) +
      ((accumulateProducts state.acc (lowerProducts a b state.z column)).lo * inverseWord).toNat *
        (get modulus 0).toNat := by
  have count : (lowerProducts a b state.z column).length+1 ≤ 16 := by
    rw [lower_length]; omega
  exact corrected_value state.acc _ _ _ high_zero count

theorem lower_value (a b : Words) (column : Nat) (state : State)
    (column_bound : column < 8) (high_zero : state.acc.hi = 0) :
    base*(lowerStep a b column state).acc.value =
      state.acc.value + productSum (lowerProducts a b state.z column) +
      (get (lowerRow a b column state).z column).toNat * (get modulus 0).toNat := by
  have shift := shiftColumn_exact (lowerRow a b column state).acc (lower_cancels a b column state)
  change base*(lowerStep a b column state).acc.value = (lowerRow a b column state).acc.value at shift
  rw [shift]
  have stored : get (lowerRow a b column state).z column =
      (accumulateProducts state.acc (lowerProducts a b state.z column)).lo * inverseWord :=
    get_put _ _ column_bound _
  rw [stored]
  exact lower_row_value a b column state column_bound high_zero

theorem upper_value (a b : Words) (output : Nat) (state : State)
    (high_zero : state.acc.hi = 0) :
    (upperRow a b output state).acc.value =
      state.acc.value + productSum (upperProducts a b state.z output) := by
  have count : (upperProducts a b state.z output).length ≤ 16 := by
    rw [upper_length]
    omega
  have full := fips_column_exact state.acc.mid state.acc.lo
    (upperProducts a b state.z output) count
  have init_eq : (Triple.mk 0 state.acc.mid state.acc.lo) = state.acc := by
    cases state with | mk acc z => cases acc; simp_all
  rw [init_eq] at full
  simpa [upperRow, Triple.value, high_zero] using full

theorem shift_decomposition (acc : Triple) :
    base*(shiftColumn acc).value + acc.lo.toNat = acc.value := by
  simp [shiftColumn, Triple.value, base]
  omega

theorem upper_step_value (a b : Words) (output : Nat) (state : State)
    (output_bound : output < 8) (high_zero : state.acc.hi = 0) :
    base*(upperStep a b output state).acc.value +
      (get (upperRow a b output state).z output).toNat =
      state.acc.value + productSum (upperProducts a b state.z output) := by
  have shift := shift_decomposition (upperRow a b output state).acc
  have stored : get (upperRow a b output state).z output = (upperRow a b output state).acc.lo :=
    get_put _ _ output_bound _
  rw [stored]
  change base*(shiftColumn (upperRow a b output state).acc).value + _ = _
  rw [shift]
  exact upper_value a b output state high_zero

theorem upper_indices (output offset : Nat) (bound : output < 8) (included : offset < 7-output) :
    output+1+offset < 8 ∧ 7-offset < 8 ∧
    8+output-(output+1+offset) = 7-offset ∧ output < output+1+offset := by omega

theorem lower_untouched (a b : Words) (column index : Nat) (state : State)
    (different : index ≠ column) :
    get (lowerStep a b column state).z index = get state.z index :=
  get_put_other _ _ _ _ different

theorem upper_untouched (a b : Words) (output index : Nat) (state : State)
    (different : index ≠ output) :
    get (upperStep a b output state).z index = get state.z index :=
  get_put_other _ _ _ _ different

def lowerPrefix (a b : Words) : Nat → State
  | 0 => initial
  | n+1 => lowerStep a b n (lowerPrefix a b n)

def upperPrefix (a b : Words) : Nat → State
  | 0 => lowerPrefix a b 8
  | n+1 => upperStep a b n (upperPrefix a b n)

theorem lower_high_zero (a b : Words) (count : Nat) : (lowerPrefix a b count).acc.hi = 0 := by
  cases count <;> rfl

theorem upper_high_zero (a b : Words) (count : Nat) : (upperPrefix a b count).acc.hi = 0 := by
  cases count with
  | zero => exact lower_high_zero a b 8
  | succ n => rfl

theorem upper_live_corrections (a b : Words) (count index : Nat) (live : count ≤ index) :
    get (upperPrefix a b count).z index = get (lowerPrefix a b 8).z index := by
  induction count with
  | zero => rfl
  | succ n ih =>
    rw [upperPrefix, upper_untouched a b n index _ (by omega)]
    exact ih (by omega)

theorem lower_stable (a b : Words) (count earlier index : Nat)
    (order : earlier ≤ count) (written : index < earlier) :
    get (lowerPrefix a b count).z index = get (lowerPrefix a b earlier).z index := by
  induction count with
  | zero =>
    have h : earlier = 0 := by omega
    subst h
    rfl
  | succ n ih =>
    by_cases same : earlier = n+1
    · subst same; rfl
    · rw [lowerPrefix, lower_untouched a b n index _ (by omega)]
      exact ih (by omega)

theorem all_lower_steps (a b : Words) (column : Nat) (bound : column < 8) :
    base*(lowerPrefix a b (column+1)).acc.value =
      (lowerPrefix a b column).acc.value +
      productSum (lowerProducts a b (lowerPrefix a b column).z column) +
      (get (lowerPrefix a b 8).z column).toNat * (get modulus 0).toNat := by
  have h := lower_value a b column (lowerPrefix a b column) bound (lower_high_zero a b column)
  have stable := lower_stable a b 8 (column+1) column (by omega) (by omega)
  change get (lowerPrefix a b 8).z column = get (lowerRow a b column (lowerPrefix a b column)).z column at stable
  rw [stable]
  exact h

theorem all_upper_steps (a b : Words) (output : Nat) (bound : output < 8) :
    base*(upperPrefix a b (output+1)).acc.value +
      (get (upperPrefix a b (output+1)).z output).toNat =
      (upperPrefix a b output).acc.value +
      productSum (upperProducts a b (upperPrefix a b output).z output) :=
  upper_step_value a b output (upperPrefix a b output) bound (upper_high_zero a b output)

structure Row where
  stage : Nat
  column : Nat
  state : State

def rows (a b : Words) : List Row :=
  (List.range 8).map (fun i => ⟨0, i, lowerRow a b i (lowerPrefix a b i)⟩) ++
  (List.range 8).map (fun i => ⟨1, i+8, upperRow a b i (upperPrefix a b i)⟩)

def wordsValue (words : Words) : Nat :=
  ScalarWords.recombine base ((List.range 8).map fun i => (get words i).toNat)

def fromNat (value : Nat) : Words := fun i => BitVec.ofNat 32 (value / base^i.val)

def finish (state : State) : Words :=
  if state.acc.lo != 0 || wordsValue state.z ≥ scalarModulus then
    fromNat (wordsValue state.z + ScalarMontgomery.scalarRadix - scalarModulus)
  else state.z

def result (a b : Words) : Words := finish (upperPrefix a b 8)

#print axioms all_lower_steps
#print axioms all_upper_steps
#print axioms upper_live_corrections

end ZkBuild.FipsMontgomery
