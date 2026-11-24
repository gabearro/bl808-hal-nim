import FipsSoundness

/- The eight-word RV32 CIOS conversion back to a natural integer. Each inner
   iteration reads a still-unmodified word and writes the preceding word. -/
namespace ZkBuild.CiosMontgomery

open WordArithmetic FipsMontgomery

def multiplier (input : Words) : Word := get input 0 * inverseWord
def firstPair (input : Words) : Pair := multiplyAddOne (multiplier input) (get modulus 0) (get input 0)

structure State where
  words : Words
  carry : Word

def columnPair (input : Words) (column : Nat) (state : State) : Pair :=
  multiplyAdd (multiplier input) (get modulus column) state.carry (get state.words column)

def columnStep (input : Words) (index : Nat) (state : State) : State :=
  let pair := columnPair input (index+1) state
  ⟨put state.words index pair.lo, pair.hi⟩

def inner (input : Words) : Nat → State
  | 0 => ⟨input, (firstPair input).hi⟩
  | n+1 => columnStep input n (inner input n)

def step (input : Words) : Words :=
  let finalState := inner input 7
  put finalState.words 7 finalState.carry

def outerPrefix (input : Words) : Nat → Words
  | 0 => input
  | n+1 => step (outerPrefix input n)

def result (input : Words) : Words :=
  finish ⟨⟨0, 0, 0⟩, outerPrefix input 8⟩

theorem first_value (input : Words) :
    (firstPair input).lo.toNat + base*(inner input 0).carry.toNat =
      (multiplier input).toNat*(get modulus 0).toNat+(get input 0).toNat :=
  multiplyAddOne_value _ _ _

theorem inner_future (input : Words) (count index : Nat) (future : count ≤ index) :
    get (inner input count).words index = get input index := by
  induction count with
  | zero => rfl
  | succ n ih =>
    rw [inner]
    change get (put _ n _) index = _
    rw [get_put_other _ _ _ _ (by omega)]
    exact ih (by omega)

theorem inner_stable (input : Words) (count earlier index : Nat)
    (order : earlier ≤ count) (written : index < earlier) :
    get (inner input count).words index = get (inner input earlier).words index := by
  induction count with
  | zero =>
    have h : earlier = 0 := by omega
    subst h
    rfl
  | succ n ih =>
    by_cases same : earlier = n+1
    · subst same; rfl
    · rw [inner]
      change get (put _ n _) index = _
      rw [get_put_other _ _ _ _ (by omega)]
      exact ih (by omega)

theorem step_low (input : Words) (index : Nat) (bound : index < 7) :
    get (step input) index = (columnPair input (index+1) (inner input index)).lo := by
  unfold step
  rw [get_put_other _ _ _ _ (by omega), inner_stable input 7 (index+1) index (by omega) (by omega)]
  change get (put _ index _) index = _
  exact get_put _ _ (by omega) _

theorem step_high (input : Words) : get (step input) 7 = (inner input 7).carry :=
  get_put _ _ (by decide) _

theorem column_value (input : Words) (index : Nat) (bound : index < 7) :
    (get (step input) index).toNat+base*(inner input (index+1)).carry.toNat =
      (multiplier input).toNat*(get modulus (index+1)).toNat+
      (inner input index).carry.toNat+(get input (index+1)).toNat := by
  rw [step_low input index bound]
  have live := inner_future input index (index+1) (by omega)
  have h := multiplyAdd_value (multiplier input) (get modulus (index+1))
    (inner input index).carry (get (inner input index).words (index+1))
  rw [live] at h
  change (columnPair input (index+1) (inner input index)).value = _
  unfold columnPair
  rw [live]
  exact h

theorem multiplyAddOne_cancels (a b c : Word) (cancelled : c+a*b = 0) :
    (multiplyAddOne a b c).lo = 0 := by
  have low := multiplyAddOne_value a b c
  have relation := congrArg (fun value => value%base) low
  have bound : (multiplyAddOne a b c).lo.toNat < base := (multiplyAddOne a b c).lo.isLt
  rw [Pair.value, Nat.add_mul_mod_self_left, Nat.mod_eq_of_lt bound] at relation
  have zero := congrArg BitVec.toNat cancelled
  simp only [BitVec.toNat_add, BitVec.toNat_mul, Nat.add_mod_mod] at zero
  apply BitVec.eq_of_toNat_eq
  rw [relation]
  simpa only [base, Nat.add_comm] using zero

theorem first_cancels (input : Words) : (firstPair input).lo = 0 := by
  apply multiplyAddOne_cancels
  have modulusOne : get modulus 0 = BitVec.ofNat 32 1 := by
    rw [modulus_low]
    congr 1
  have inverse : inverseWord = -BitVec.ofNat 32 1 := by
    apply BitVec.eq_of_toNat_eq
    simp [inverseWord]
  rw [modulusOne, multiplier, inverse, BitVec.mul_one, BitVec.mul_neg, BitVec.mul_one,
    BitVec.add_right_neg]
  simp

theorem inner_indices (index : Nat) (bound : index < 7) : index+1 < 8 ∧ index < index+1 := by omega

structure Row where
  outer : Nat
  column : Nat
  words : Words
  multiplier : Word
  carry : Word
  low : Word

def stepRows (input : Words) (outer : Nat) : List Row :=
  [⟨outer, 0, input, multiplier input, (firstPair input).hi, (firstPair input).lo⟩] ++
  (List.range 7).map (fun index =>
    let next := inner input (index+1)
    ⟨outer, index+1, next.words, multiplier input, next.carry, get next.words index⟩) ++
  [⟨outer, 8, step input, multiplier input, (inner input 7).carry, 0⟩]

def rows (input : Words) : List Row :=
  (List.range 8).flatMap fun outer => stepRows (outerPrefix input outer) outer

#print axioms column_value
#print axioms first_cancels

end ZkBuild.CiosMontgomery
