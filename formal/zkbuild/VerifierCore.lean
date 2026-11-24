import ZkBuild

/- The allocation-free verifier core: public coefficient accumulation and
   the four-pairing schedule. Group elements are represented by exponents;
   actual curve operations and pairing correctness remain explicit assumptions. -/
namespace ZkBuild.VerifierCore

open Lean.Grind
attribute [local instance] Ring.intCast Semiring.natCast

def schedule (count : Nat) : List (Nat × Nat) :=
  (List.range count).map fun i => (i+1, i)

structure PairSpec where
  sign : Int
  left : Nat
  right : Nat
  deriving DecidableEq, Repr

-- Left sources: A, alpha, accumulated public term, C.
-- Right sources: B, beta, gamma, delta.
def pairingSchedule : List PairSpec := [⟨-1, 0, 0⟩, ⟨1, 1, 1⟩, ⟨1, 2, 2⟩, ⟨1, 3, 3⟩]

def dot {F : Type} [CommRing F] : List F → List F → F
  | coefficient :: rest, input :: inputs => coefficient * input + dot rest inputs
  | _, _ => 0

def accumulate {F : Type} [CommRing F] (coefficients inputs : List F) : Option F :=
  if coefficients.length = 0 then none
  else if coefficients.length-1 ≠ inputs.length then none
  else some ((coefficients.tail.zip inputs).foldl
    (fun total pair => total + pair.1 * pair.2) (coefficients.headD 0))

theorem folded_dot {F : Type} [CommRing F] (coefficients inputs : List F) (seed : F) :
    (coefficients.zip inputs).foldl (fun total pair => total + pair.1 * pair.2) seed =
      seed + dot coefficients inputs := by
  induction coefficients generalizing inputs seed with
  | nil => simp [dot, Semiring.add_zero]
  | cons coefficient rest ih =>
    cases inputs with
    | nil => simp [dot, Semiring.add_zero]
    | cons input inputs =>
      simp only [List.zip_cons_cons, List.foldl_cons, ih, dot]
      grind

theorem accumulate_nil {F : Type} [CommRing F] (inputs : List F) : accumulate [] inputs = none := by
  simp [accumulate]

theorem accumulate_cons {F : Type} [CommRing F] (constant : F) (coefficients inputs : List F) :
    accumulate (constant :: coefficients) inputs =
      if coefficients.length = inputs.length then some (constant + dot coefficients inputs) else none := by
  by_cases same : coefficients.length = inputs.length
  · simp [accumulate, same, folded_dot]
  · simp [accumulate, same]

theorem rejects_bad_arity {F : Type} [CommRing F] (coefficients inputs : List F)
    (bad : coefficients.length ≠ inputs.length+1) : accumulate coefficients inputs = none := by
  cases coefficients with
  | nil => exact accumulate_nil inputs
  | cons first rest =>
    have different : rest.length ≠ inputs.length := by simp only [List.length_cons] at bad; omega
    simp [accumulate_cons, different]

theorem input_index_safe (coefficientCount inputCount index : Nat)
    (_positive : coefficientCount ≠ 0) (arity : coefficientCount-1 = inputCount)
    (bound : index < inputCount) : index+1 < coefficientCount := by omega

theorem schedule_count (count : Nat) : (schedule count).length = count := by simp [schedule]

theorem schedule_input (count index : Nat) (bound : index < count) :
    (schedule count)[index]'(by simpa [schedule] using bound) = (index+1, index) := by
  simp [schedule]

theorem every_input_once (count : Nat) : (schedule count).map Prod.snd = List.range count := by
  simp [schedule, List.map_map, Function.comp_def]

theorem scheduled_terms {F : Type} [CommRing F] (coefficients inputs : List F)
    (arity : coefficients.length = inputs.length+1) :
    coefficients.tail.zip inputs = (schedule inputs.length).map
      (fun indices => ((coefficients[indices.1]?).getD 0, (inputs[indices.2]?).getD 0)) := by
  apply List.ext_getElem
  · simp [schedule, arity]
  · intro i left right
    have inputBound : i < inputs.length := by
      simpa only [List.length_map, schedule_count] using right
    have coefficientBound : i+1 < coefficients.length := by omega
    simp only [List.getElem_zip, List.getElem_tail, List.getElem_map,
      schedule_input inputs.length i inputBound, List.getElem?_eq_getElem inputBound,
      List.getElem?_eq_getElem coefficientBound, Option.getD_some]

theorem accumulate_scheduled {F : Type} [CommRing F] (coefficients inputs : List F)
    (arity : coefficients.length = inputs.length+1) :
    accumulate coefficients inputs = some ((schedule inputs.length).foldl
      (fun total indices => total + (coefficients[indices.1]?).getD 0 * (inputs[indices.2]?).getD 0)
      (coefficients.headD 0)) := by
  have nonzero : coefficients.length ≠ 0 := by omega
  have remaining : coefficients.length-1 = inputs.length := by omega
  simp only [accumulate, nonzero, ite_false, remaining, ne_eq, not_true_eq_false]
  rw [scheduled_terms coefficients inputs arity, List.foldl_map]

def pairingExponent {F : Type} [CommRing F] (left right : Nat → F) : F :=
  pairingSchedule.foldl (fun total pair => total + (pair.sign : F) * left pair.left * right pair.right) 0

theorem pairing_expression {F : Type} [CommRing F] (a alpha publicTerm c b beta gamma delta : F) :
    pairingExponent
      (fun i => if i = 0 then a else if i = 1 then alpha else if i = 2 then publicTerm else c)
      (fun i => if i = 0 then b else if i = 1 then beta else if i = 2 then gamma else delta) =
      -(a*b) + alpha*beta + publicTerm*gamma + c*delta := by
  simp only [pairingExponent, pairingSchedule, List.foldl_cons, List.foldl_nil]
  simp only [ite_true, show ¬(1 : Nat) = 0 by decide, show ¬(2 : Nat) = 0 by decide,
    show ¬(2 : Nat) = 1 by decide, show ¬(3 : Nat) = 0 by decide, show ¬(3 : Nat) = 1 by decide,
    show ¬(3 : Nat) = 2 by decide, ite_false, Ring.intCast_neg, Ring.intCast_one]
  grind

def Verifies {F : Type} [CommRing F] (alpha beta gamma delta a b c : F) (coefficients inputs : List F) : Prop :=
  match accumulate coefficients inputs with
  | none => False
  | some publicTerm => -(a*b) + alpha*beta + publicTerm*gamma + c*delta = 0

def ScheduledVerifies {F : Type} [CommRing F] (alpha beta gamma delta a b c : F)
    (coefficients inputs : List F) : Prop :=
  match accumulate coefficients inputs with
  | none => False
  | some publicTerm => pairingExponent
      (fun i => if i = 0 then a else if i = 1 then alpha else if i = 2 then publicTerm else c)
      (fun i => if i = 0 then b else if i = 1 then beta else if i = 2 then gamma else delta) = 0

theorem scheduled_iff {F : Type} [CommRing F] (alpha beta gamma delta a b c : F)
    (coefficients inputs : List F) :
    ScheduledVerifies alpha beta gamma delta a b c coefficients inputs ↔
      Verifies alpha beta gamma delta a b c coefficients inputs := by
  cases accumulated : accumulate coefficients inputs with
  | none => simp [ScheduledVerifies, Verifies, accumulated]
  | some publicTerm => simp [ScheduledVerifies, Verifies, accumulated, pairing_expression]

theorem rejects_mismatch {F : Type} [CommRing F] (alpha beta gamma delta a b c : F)
    (coefficients inputs : List F) (bad : coefficients.length ≠ inputs.length+1) :
    ¬ScheduledVerifies alpha beta gamma delta a b c coefficients inputs := by
  simp [ScheduledVerifies, rejects_bad_arity coefficients inputs bad]

theorem verifies_iff {F : Type} [CommRing F] (alpha beta gamma delta a b c : F) (coefficients inputs : List F) :
    Verifies alpha beta gamma delta a b c coefficients inputs ↔
      ∃ constant rest, coefficients = constant :: rest ∧ rest.length = inputs.length ∧
        a*b = alpha*beta + gamma*(constant + dot rest inputs) + delta*c := by
  cases coefficients with
  | nil => simp [Verifies, accumulate_nil]
  | cons constant rest =>
    rw [Verifies, accumulate_cons]
    by_cases same : rest.length = inputs.length
    · simp only [same, ite_true, List.cons.injEq]
      grind
    · simp [same]

theorem honest_proof_verifies {F : Type} [CommRing F]
    (alpha beta gamma delta a b c publicTerm privateTerm quotient r s : F) (coefficients inputs : List F)
    (accumulated : accumulate coefficients inputs = some publicTerm)
    (keyRelation : gamma*publicTerm + delta*privateTerm = beta*a + alpha*b + c)
    (qap : delta*quotient = a*b-c) :
    Verifies alpha beta gamma delta (alpha+a+r*delta) (beta+b+s*delta)
      (privateTerm+quotient+s*(alpha+a+r*delta)+r*(beta+b+s*delta)-r*s*delta) coefficients inputs := by
  rw [Verifies, accumulated]
  have equation := groth16_exponent_completeness alpha beta gamma delta a b c publicTerm privateTerm quotient r s
    keyRelation qap
  dsimp only at equation
  grind

#print axioms verifies_iff
#print axioms scheduled_iff
#print axioms honest_proof_verifies
#print axioms every_input_once
#print axioms accumulate_scheduled

end ZkBuild.VerifierCore
