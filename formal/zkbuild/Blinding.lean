import ZkBuild

/- Scalar/exponent model of the prover's bounded candidate selection. The
   correspondence between group identity and zero exponent remains a group
   implementation obligation; this does not verify the OS random source. -/
namespace ZkBuild.Blinding

open Lean.Grind
attribute [local instance] Semiring.natCast

abbrev Admissible {F : Type} [Field F] (base delta nonce : F) : Prop :=
  nonce ≠ 0 ∧ base + nonce*delta ≠ 0

def selectCandidate {F : Type} [Field F] [DecidableEq F]
    (base delta : F) : List F → Option F
  | [] => none
  | nonce :: rest => if Admissible base delta nonce then some nonce else selectCandidate base delta rest

theorem cancellation_unique {F : Type} [Field F] (base delta a b : F)
    (nonzero : delta ≠ 0) (left : base + a*delta = 0) (right : base + b*delta = 0) : a = b := by
  have product : (a-b)*delta = 0 := by grind
  rcases Field.of_mul_eq_zero product with equal | zero
  · grind
  · exact False.elim (nonzero zero)

theorem one_or_two_admissible {F : Type} [Field F] (base delta : F)
    (nonzero : delta ≠ 0) (twoNonzero : (2 : F) ≠ 0) :
    Admissible base delta 1 ∨ Admissible base delta 2 := by
  by_cases one : base + delta = 0
  · right
    refine ⟨twoNonzero, ?_⟩
    intro two
    have zero : delta = 0 := by grind
    exact nonzero zero
  · left
    exact ⟨Ne.symm Field.zero_ne_one, by simpa [Semiring.one_mul] using one⟩

theorem selection_sound {F : Type} [Field F] [DecidableEq F]
    (base delta : F) (candidates : List F) (nonce : F)
    (selected : selectCandidate base delta candidates = some nonce) :
    Admissible base delta nonce ∧ nonce ∈ candidates := by
  induction candidates with
  | nil => simp [selectCandidate] at selected
  | cons head rest ih =>
    unfold selectCandidate at selected
    split at selected
    next valid => cases selected; exact ⟨valid, by simp⟩
    next =>
      obtain ⟨valid, member⟩ := ih selected
      exact ⟨valid, List.mem_cons_of_mem _ member⟩

theorem selection_none {F : Type} [Field F] [DecidableEq F]
    (base delta : F) (candidates : List F) :
    selectCandidate base delta candidates = none ↔ ∀ nonce ∈ candidates, ¬Admissible base delta nonce := by
  induction candidates with
  | nil => simp [selectCandidate]
  | cons head rest ih =>
    constructor
    · intro rejected nonce member
      by_cases valid : Admissible base delta head
      · rw [selectCandidate, ite_eq_left valid] at rejected
        contradiction
      · have tail : selectCandidate base delta rest = none := by
          simpa only [selectCandidate, ite_eq_right valid] using rejected
        rcases List.mem_cons.mp member with rfl | member
        · exact valid
        · exact ih.mp tail nonce member
    · intro rejected
      have headBad := rejected head (by simp)
      rw [selectCandidate, ite_eq_right headBad]
      exact ih.mpr (fun nonce member => rejected nonce (List.mem_cons_of_mem _ member))

theorem candidate_present_suffices {F : Type} [Field F] [DecidableEq F]
    (base delta : F) (candidates : List F) (nonce : F)
    (member : nonce ∈ candidates) (valid : Admissible base delta nonce) :
    ∃ selected, selectCandidate base delta candidates = some selected := by
  cases outcome : selectCandidate base delta candidates with
  | none => exact False.elim (((selection_none base delta candidates).mp outcome nonce member) valid)
  | some selected => exact ⟨selected, rfl⟩

theorem two_candidates_suffice {F : Type} [Field F] [DecidableEq F]
    (base delta : F) (nonzero : delta ≠ 0) (twoNonzero : (2 : F) ≠ 0) :
    ∃ selected, selectCandidate base delta [1, 2] = some selected := by
  rcases one_or_two_admissible base delta nonzero twoNonzero with first | second
  · exact candidate_present_suffices base delta [1, 2] 1 (by simp) first
  · exact candidate_present_suffices base delta [1, 2] 2 (by simp) second

theorem scalar_two_nonzero {F : Type} [Field F] [IsCharP F scalarModulus] : (2 : F) ≠ 0 := by
  intro zero
  have equal : (2 : Nat) = 0 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (by decide : 2 < scalarModulus) (by decide : 0 < scalarModulus)).mp
      (by simpa only [Semiring.natCast_eq_ofNat] using zero)
  omega

theorem scalar_candidates_suffice {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (base delta : F) (nonzero : delta ≠ 0) :
    ∃ selected, selectCandidate base delta [1, 2] = some selected :=
  two_candidates_suffice base delta nonzero scalar_two_nonzero

#print axioms cancellation_unique
#print axioms selection_sound
#print axioms two_candidates_suffice
#print axioms scalar_candidates_suffice

end ZkBuild.Blinding
