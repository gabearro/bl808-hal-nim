import RowMatrix
import Lean.Data.RArray

/- Constructing a witness is the converse of extracting equations from one.
   This module proves that the fresh-wire elimination used for row soundness
   preserves satisfiability in both directions. -/
namespace ZkBuild.RowCompleteness

open Lean.Grind RowSoundness RowMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem environment_pop {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) (expression : Expr)
    (agree : EnvironmentAgrees ctx values (environment.push expression)) :
    EnvironmentAgrees ctx values environment ∧
      evalField ctx.get expression = values environment.size := by
  constructor
  · intro i bound
    have entry := agree i (by simpa using Nat.lt_succ_of_lt bound)
    have different : i ≠ environment.size := Nat.ne_of_lt bound
    simpa [Array.getElem?_push, different] using entry
  · have entry := agree environment.size (by simp)
    simpa using entry

theorem action_complete {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) (gate : CircuitShape.Gate) (action : Action)
    (agree : EnvironmentAgrees ctx values environment)
    (valid : ActionHolds ctx values environment action)
    (found : actionOf environment gate = some action) :
    R1CS.Holds values (CircuitShape.interpretGate gate) := by
  unfold actionOf at found
  split at found
  next bounds =>
    have bounds' : inBounds environment gate.a = true ∧ inBounds environment gate.b = true := by
      simpa using bounds
    have a := linear_expression_sound ctx values environment gate.a agree bounds'.1
    have b := linear_expression_sound ctx values environment gate.b agree bounds'.2
    split at found
    next definition =>
      cases found
      change evalField ctx.get (linearExpr environment gate.a) *
        evalField ctx.get (linearExpr environment gate.b) = values environment.size at valid
      rw [a, b] at valid
      simpa [CircuitShape.interpretGate, definition, R1CS.Holds,
        CircuitShape.interpretLinear, R1CS.eval, Ring.intCast_one,
        Semiring.one_mul, Semiring.add_zero] using valid
    next =>
      split at found
      next boundC =>
        cases found
        have c := linear_expression_sound ctx values environment gate.c agree boundC
        change evalField ctx.get (linearExpr environment gate.a) *
          evalField ctx.get (linearExpr environment gate.b) -
          evalField ctx.get (linearExpr environment gate.c) = 0 at valid
        rw [a, b, c] at valid
        change R1CS.eval values (CircuitShape.interpretLinear gate.a) *
          R1CS.eval values (CircuitShape.interpretLinear gate.b) =
          R1CS.eval values (CircuitShape.interpretLinear gate.c)
        grind
      next => simp at found
  next => simp at found

theorem elimination_complete {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (gates : List CircuitShape.Gate) :
    ∀ environment result,
      eliminate environment gates = some result →
      EnvironmentAgrees ctx values result.environment →
      (∀ e ∈ result.assertions, evalField ctx.get e = 0) →
      EnvironmentAgrees ctx values environment ∧
        ∀ gate ∈ gates, R1CS.Holds values (CircuitShape.interpretGate gate) := by
  induction gates with
  | nil =>
    intro environment result run agree _
    simp only [eliminate, Option.some.injEq] at run
    cases run
    exact ⟨agree, by simp⟩
  | cons gate rest ih =>
    intro environment result run agree assertions
    cases actionEq : actionOf environment gate with
    | none => simp [eliminate, actionEq] at run
    | some action =>
      cases action with
      | define expression =>
        have run' : eliminate (environment.push expression) rest = some result := by
          simpa [eliminate, actionEq] using run
        obtain ⟨extended, tail⟩ := ih (environment.push expression) result run' agree assertions
        obtain ⟨initial, definition⟩ := environment_pop ctx values environment expression extended
        have head := action_complete ctx values environment gate (.define expression)
          initial definition actionEq
        exact ⟨initial, by simpa only [List.mem_cons, forall_eq_or_imp] using And.intro head tail⟩
      | assertZero expression =>
        cases nextEq : eliminate environment rest with
        | none => simp [eliminate, actionEq, nextEq] at run
        | some next =>
          simp only [eliminate, actionEq, nextEq] at run
          cases run
          obtain ⟨initial, tail⟩ := ih environment next nextEq agree
            (fun e member => assertions e (List.mem_cons_of_mem _ member))
          have head := action_complete ctx values environment gate (.assertZero expression)
            initial (assertions expression (by simp)) actionEq
          exact ⟨initial, by simpa only [List.mem_cons, forall_eq_or_imp] using And.intro head tail⟩

theorem eliminated_witness_exists {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (environment : Array Expr) (gates : List CircuitShape.Gate) (result : Eliminated)
    (run : eliminate environment gates = some result)
    (assertions : ∀ e ∈ result.assertions, evalField ctx.get e = 0) :
    ∃ values : Nat → F, EnvironmentAgrees ctx values environment ∧
      ∀ gate ∈ gates, R1CS.Holds values (CircuitShape.interpretGate gate) := by
  let values := fun i : Nat => evalField ctx.get (result.environment[i]?.getD (.literal 0))
  exact ⟨values, elimination_complete ctx values gates environment result run
    (by intro i bound; rfl) assertions⟩

theorem canonical_field_row_complete {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    FieldHolds (fun i => (canonicalInputs p h b i : F)) := by
  have certified := finite_row_certificate p h b
  have facts : integerHolds p h b = true ∧
      row.nextPhases.map (evalInt (canonicalInputs p h b)) = oneHot 8 nextPhase ∧
      row.nextDepths.map (evalInt (canonicalInputs p h b)) = oneHot 9 nextDepth := by
    simpa [finiteCertificate, accepted, Bool.and_eq_true_iff, and_assoc] using certified
  have intHolds := facts.1
  intro e member
  have zero := List.all_eq_true.mp intHolds (evalInt (canonicalInputs p h b) e)
    (List.mem_map.mpr ⟨e, member, rfl⟩)
  have zero' : evalInt (canonicalInputs p h b) e = 0 := by simpa using zero
  rw [integer_interpretation_commutes, zero', Ring.intCast_zero]

theorem canonical_selector_boolean {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (i : Fin 10) :
    evalField (fun j => (canonicalInputs p h b j : F))
      (selected i.val * (selected i.val - 1)) = 0 := by
  have lo8 : ¬25+i.val < 8 := by omega
  have lo17 : ¬25+i.val < 17 := by omega
  have lo25 : ¬25+i.val < 25 := by omega
  have hi35 : 25+i.val < 35 := by have := i.isLt; omega
  change (canonicalInputs p h b (25+i.val) : F) *
    ((canonicalInputs p h b (25+i.val) : F) - (1 : Int)) = 0
  simp only [canonicalInputs, ite_eq_right lo8, ite_eq_right lo17,
    ite_eq_right lo25, ite_eq_left hi35, InputNormalization.cast_flag]
  split <;> simp [Ring.intCast_one, Semiring.one_mul, Semiring.zero_mul] <;> grind

theorem expected_assertions_bounded : expectedAssertions.all (InputNormalization.UsesBelow 35) = true := by
  decide

theorem canonical_assertions_zero {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    ∀ e ∈ expectedAssertions, evalField (fun i => (canonicalInputs p h b i : F)) e = 0 := by
  intro e member
  simp only [expectedAssertions, List.mem_append] at member
  rcases member with selector | residual
  · obtain ⟨i, member, rfl⟩ := List.mem_map.mp selector
    exact canonical_selector_boolean p h b ⟨i, List.mem_range.mp member⟩
  · exact canonical_field_row_complete p h b nextPhase nextDepth accepted e residual

noncomputable def canonicalContext {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 35 => (canonicalInputs p h b i.val : F)) (by decide)

theorem canonical_context_inputs {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (i : Nat) (bound : i < 35) :
    (canonicalContext (F := F) p h b).get i = (canonicalInputs p h b i : F) :=
  Lean.RArray.get_ofFn (fun j : Fin 35 => (canonicalInputs p h b j.val : F)) (by decide) ⟨i, bound⟩

theorem canonical_context_assertions_zero {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    ∀ e ∈ expectedAssertions, evalField (canonicalContext (F := F) p h b).get e = 0 := by
  intro e member
  rw [InputNormalization.eval_congr_below _ _ 35 (canonical_context_inputs p h b) e
    (List.all_eq_true.mp expected_assertions_bounded e member)]
  exact canonical_assertions_zero p h b nextPhase nextDepth accepted e member

theorem eliminated_row_assertions_zero {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat) (result : Eliminated)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth))
    (found : eliminatedRow = some result) :
    ∀ e ∈ result.assertions, evalField (canonicalContext (F := F) p h b).get e = 0 := by
  have certificate := row_polynomial_certificate
  have checked : result.environment.size = 66 ∧ result.assertions.length = 27 ∧
      expectedAssertions.all (fun expected => result.assertions.any (samePolynomial expected)) = true ∧
      result.assertions.all (fun actual => expectedAssertions.any (samePolynomial actual)) = true ∧
      polynomialListEqual (phasesLinear.map (linearExpr result.environment)) row.nextPhases = true ∧
      polynomialListEqual (rowBuild.1.depths.toList.map (linearExpr result.environment)) row.nextDepths = true := by
    simpa [rowPolynomialCertificate, found, Bool.and_eq_true_iff, and_assoc] using certificate
  intro e member
  obtain ⟨expected, expectedMember, equal⟩ := List.any_eq_true.mp
    (List.all_eq_true.mp checked.2.2.2.1 e member)
  rw [polynomial_certificate_sound (canonicalContext p h b) e expected equal]
  exact canonical_context_assertions_zero p h b nextPhase nextDepth accepted expected expectedMember

def canonicalRowWitness (p : Fin 8) (h : Fin 9) (b : Fin 256) : List Int :=
  match eliminatedRow with
  | none => []
  | some result => result.environment.toList.map (evalInt (canonicalInputs p h b))

theorem eliminated_environment_bounded :
    (match eliminatedRow with
      | none => false
      | some result => result.environment.toList.all (InputNormalization.UsesBelow 35)) = true := by
  native_decide

theorem integer_assignment_agrees {F : Type} [CommRing F]
    (ctx : Lean.RArray F) (inputs : Nat → Int) (environment : Array Expr)
    (agree : ∀ i, i < 35 → ctx.get i = (inputs i : F))
    (bounded : environment.toList.all (InputNormalization.UsesBelow 35) = true) :
    EnvironmentAgrees ctx
      (fun i => ((environment.toList.map (evalInt inputs))[i]?.getD 0 : F)) environment := by
  intro i bound
  have member : environment[i] ∈ environment.toList := Array.getElem_mem_toList bound
  have uses := List.all_eq_true.mp bounded _ member
  have same := InputNormalization.eval_congr_below ctx.get (fun j => (inputs j : F)) 35 agree
    environment[i] uses
  rw [Array.getElem?_eq_getElem bound]
  simp only [Option.getD_some]
  rw [same, integer_interpretation_commutes]
  have listBound : i < (environment.toList.map (evalInt inputs)).length := by simpa using bound
  rw [List.getElem?_eq_getElem listBound]
  simp only [Option.getD_some, List.getElem_map, Array.getElem_toList]

theorem canonical_row_witness_holds {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    let values := fun i : Nat => ((canonicalRowWitness p h b)[i]?.getD 0 : F)
    values 0 = 1 ∧
      (∀ i, i < 35 → values (i+1) = (canonicalInputs p h b i : F)) ∧
      ∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate) := by
  dsimp only
  have certificate := row_polynomial_certificate
  cases found : eliminatedRow with
  | none => simp [rowPolynomialCertificate, found] at certificate
  | some result =>
    have bounded : result.environment.toList.all (InputNormalization.UsesBelow 35) = true := by
      simpa only [found] using eliminated_environment_bounded
    let ctx : Lean.RArray F := canonicalContext p h b
    have finalAgree := integer_assignment_agrees ctx (canonicalInputs p h b) result.environment
      (canonical_context_inputs p h b) bounded
    have assertions := eliminated_row_assertions_zero (F := F) p h b nextPhase nextDepth result accepted found
    obtain ⟨environment, holds⟩ := elimination_complete ctx
      (fun i => ((result.environment.toList.map (evalInt (canonicalInputs p h b)))[i]?.getD 0 : F))
      rowBuild.2.gates.toList inputEnvironment result found finalAgree assertions
    simp only [canonicalRowWitness, found]
    refine ⟨?_, ?_, holds⟩
    · have zero := environment 0 (by simp [inputEnvironment])
      simpa [inputEnvironment, evalField, Ring.intCast_one] using zero.symm
    · intro i bound
      have indexBound : i+1 < inputEnvironment.size := by simpa [inputEnvironment] using Nat.add_lt_add_right bound 1
      have entry := environment (i+1) indexBound
      rw [input_environment_entry ⟨i+1, by omega⟩] at entry
      have nonzero : i+1 ≠ 0 := by omega
      simpa [nonzero, evalField, ctx, canonical_context_inputs p h b i bound] using entry.symm

theorem matrix_row_witness_exists {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    ∃ values : Nat → F, values 0 = 1 ∧
      (∀ i, i < 35 → values (i+1) = (canonicalInputs p h b i : F)) ∧
      ∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate) :=
  ⟨(fun i : Nat => ((canonicalRowWitness p h b)[i]?.getD 0 : F)),
    canonical_row_witness_holds (F := F) p h b nextPhase nextDepth accepted⟩

theorem canonical_context_outputs {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    row.nextPhases.map (evalField (canonicalContext (F := F) p h b).get) =
      (oneHot 8 nextPhase).map (fun n : Int => (n : F)) ∧
    row.nextDepths.map (evalField (canonicalContext (F := F) p h b).get) =
      (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
  have facts : integerHolds p h b = true ∧
      row.nextPhases.map (evalInt (canonicalInputs p h b)) = oneHot 8 nextPhase ∧
      row.nextDepths.map (evalInt (canonicalInputs p h b)) = oneHot 9 nextDepth := by
    simpa [finiteCertificate, accepted, Bool.and_eq_true_iff, and_assoc]
      using finite_row_certificate p h b
  have sameEval (e : Expr) (member : e ∈ row.nextPhases ++ row.nextDepths) :
      evalField (canonicalContext (F := F) p h b).get e =
        evalField (fun i => (canonicalInputs p h b i : F)) e := by
    apply InputNormalization.eval_congr_below _ _ 35 (canonical_context_inputs p h b) e
    exact List.all_eq_true.mp InputNormalization.row_uses_only_inputs e
      (by simpa only [List.append_assoc] using List.mem_append_right row.residuals member)
  constructor
  · have mapped := congrArg (List.map (fun n : Int => (n : F))) facts.2.1
    have canonical : row.nextPhases.map (evalField (fun i => (canonicalInputs p h b i : F))) =
        (oneHot 8 nextPhase).map (fun n : Int => (n : F)) := by
      simpa only [List.map_map, Function.comp_def, ← integer_interpretation_commutes] using mapped
    rw [← canonical]
    apply List.map_congr_left
    intro e member
    exact sameEval e (List.mem_append_left _ member)
  · have mapped := congrArg (List.map (fun n : Int => (n : F))) facts.2.2
    have canonical : row.nextDepths.map (evalField (fun i => (canonicalInputs p h b i : F))) =
        (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
      simpa only [List.map_map, Function.comp_def, ← integer_interpretation_commutes] using mapped
    rw [← canonical]
    apply List.map_congr_left
    intro e member
    exact sameEval e (List.mem_append_right _ member)

theorem matrix_row_complete {F : Type} [CommRing F]
    (p : Fin 8) (h : Fin 9) (b : Fin 256) (nextPhase nextDepth : Nat)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth)) :
    ∃ values : Nat → F, values 0 = 1 ∧
      (∀ i, i < 35 → values (i+1) = (canonicalInputs p h b i : F)) ∧
      (∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate)) ∧
      phasesLinear.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
        (oneHot 8 nextPhase).map (fun n : Int => (n : F)) ∧
      rowBuild.1.depths.toList.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
        (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
  obtain ⟨values, one, inputs, holds⟩ :=
    matrix_row_witness_exists (F := F) p h b nextPhase nextDepth accepted
  have inputs' : ∀ i, i < 35 → values (i+1) = (canonicalContext (F := F) p h b).get i := by
    intro i bound
    rw [inputs i bound, canonical_context_inputs p h b i bound]
  obtain ⟨_, phaseEq, depthEq⟩ := matrix_row_implies_equations (canonicalContext p h b) values one inputs' holds
  obtain ⟨phases, depths⟩ := canonical_context_outputs (F := F) p h b nextPhase nextDepth accepted
  exact ⟨values, one, inputs, holds, phaseEq.trans phases, depthEq.trans depths⟩

#print axioms elimination_complete
#print axioms canonical_field_row_complete
#print axioms matrix_row_witness_exists
#print axioms matrix_row_complete
#print axioms canonical_row_witness_holds

end ZkBuild.RowCompleteness
