import InputNormalization

namespace ZkBuild.RowMatrix

open Lean.Grind
open RowSoundness
attribute [local instance] Ring.intCast Semiring.natCast

abbrev RingExpr := Lean.Grind.CommRing.Expr

def ringExpr : Expr → RingExpr
  | .literal n => .intCast n
  | .input i => .var i
  | .add a b => .add (ringExpr a) (ringExpr b)
  | .sub a b => .sub (ringExpr a) (ringExpr b)
  | .mul a b => .mul (ringExpr a) (ringExpr b)

theorem ring_interpretation {F : Type} [CommRing F] (ctx : Lean.RArray F) (e : Expr) :
    (ringExpr e).denote ctx = evalField ctx.get e := by
  induction e <;> simp_all [ringExpr, Lean.Grind.CommRing.Expr.denote,
    Lean.Grind.CommRing.Var.denote, evalField]

def samePolynomial (a b : Expr) : Bool := (ringExpr a).toPoly == (ringExpr b).toPoly

theorem polynomial_certificate_sound {F : Type} [CommRing F]
    (ctx : Lean.RArray F) (a b : Expr) (same : samePolynomial a b = true) :
    evalField ctx.get a = evalField ctx.get b := by
  have equal := Lean.Grind.CommRing.Expr.eq_of_toPoly_eq ctx (ringExpr a) (ringExpr b) same
  simpa only [ring_interpretation] using equal

def wire (i : Nat) : CircuitShape.Linear := [(i, 1)]

def inputParser : CircuitShape.Parser := {
  ready := wire 1, index := wire 2, done := wire 8,
  leb := (List.range 5).toArray.map fun i => wire (i+3),
  depths := (List.range 9).toArray.map fun i => wire (i+9)
}

def rowBuild : CircuitShape.Parser × CircuitShape.Shape :=
  (CircuitShape.row inputParser ((List.range 8).toArray.map fun i => wire (i+18))).run
    { wires := 26 }

def inputEnvironment : Array Expr :=
  #[.literal 1] ++ (List.range 35).toArray.map Expr.input

def linearExpr (environment : Array Expr) : CircuitShape.Linear → Expr
  | [] => .literal 0
  | (i, coefficient) :: rest =>
    .literal coefficient * environment[i]?.getD (.literal 0) + linearExpr environment rest

def inBounds (environment : Array Expr) (linear : CircuitShape.Linear) : Bool :=
  linear.all fun term => term.1 < environment.size

structure Eliminated where
  environment : Array Expr
  assertions : List Expr := []

inductive Action where
  | define : Expr → Action
  | assertZero : Expr → Action

def actionOf (environment : Array Expr) (gate : CircuitShape.Gate) : Option Action :=
  if inBounds environment gate.a && inBounds environment gate.b then
    let a := linearExpr environment gate.a
    let b := linearExpr environment gate.b
    if gate.c = [(environment.size, 1)] then some (.define (a*b))
    else if inBounds environment gate.c then some (.assertZero (a*b - linearExpr environment gate.c))
    else none
  else none

-- A multiplication gate defining the next fresh wire can be substituted
-- symbolically. Every other gate remains an assertion. The soundness theorem
-- below for polynomial comparison is independent of concrete witness values.
def eliminate (environment : Array Expr) : List CircuitShape.Gate → Option Eliminated
  | [] => some ⟨environment, []⟩
  | gate :: rest => do
    match ← actionOf environment gate with
    | .define expression => eliminate (environment.push expression) rest
    | .assertZero expression =>
      let next ← eliminate environment rest
      return { next with assertions := expression :: next.assertions }

def EnvironmentAgrees {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) : Prop :=
  ∀ i, i < environment.size → evalField ctx.get (environment[i]?.getD (.literal 0)) = values i

theorem linear_expression_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) (linear : CircuitShape.Linear)
    (agree : EnvironmentAgrees ctx values environment) (bounded : inBounds environment linear = true) :
    evalField ctx.get (linearExpr environment linear) =
      R1CS.eval values (CircuitShape.interpretLinear linear) := by
  induction linear with
  | nil => simp [linearExpr, evalField, CircuitShape.interpretLinear, R1CS.eval, Ring.intCast_zero]
  | cons term rest ih =>
    rcases term with ⟨i, coefficient⟩
    have bounds : i < environment.size ∧ inBounds environment rest = true := by
      simpa [inBounds] using bounded
    have head := agree i bounds.1
    simp only [linearExpr, evalField, CircuitShape.interpretLinear, List.map_cons, R1CS.eval]
    rw [head, ih bounds.2]
    rfl

def ActionHolds {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) : Action → Prop
  | .define expression => evalField ctx.get expression = values environment.size
  | .assertZero expression => evalField ctx.get expression = 0

theorem action_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) (gate : CircuitShape.Gate) (action : Action)
    (agree : EnvironmentAgrees ctx values environment)
    (holds : R1CS.Holds values (CircuitShape.interpretGate gate))
    (found : actionOf environment gate = some action) : ActionHolds ctx values environment action := by
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
      simp only [ActionHolds, evalField, a, b]
      simpa [CircuitShape.interpretGate, definition, R1CS.Holds,
        CircuitShape.interpretLinear, R1CS.eval, Ring.intCast_one,
        Semiring.one_mul, Semiring.add_zero] using holds
    next =>
      split at found
      next boundC =>
        cases found
        have c := linear_expression_sound ctx values environment gate.c agree boundC
        change evalField ctx.get (linearExpr environment gate.a) *
          evalField ctx.get (linearExpr environment gate.b) -
          evalField ctx.get (linearExpr environment gate.c) = 0
        rw [a, b, c]
        change R1CS.eval values (CircuitShape.interpretLinear gate.a) *
          R1CS.eval values (CircuitShape.interpretLinear gate.b) =
          R1CS.eval values (CircuitShape.interpretLinear gate.c) at holds
        grind
      next => simp at found
  next => simp at found

theorem environment_push {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (environment : Array Expr) (expression : Expr)
    (agree : EnvironmentAgrees ctx values environment)
    (definition : evalField ctx.get expression = values environment.size) :
    EnvironmentAgrees ctx values (environment.push expression) := by
  intro i bounded
  by_cases last : i = environment.size
  · subst i
    simpa using definition
  · have before : i < environment.size := by
      have limit : i < environment.size + 1 := by simpa using bounded
      omega
    simpa [Array.getElem?_push, last] using agree i before

theorem elimination_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (gates : List CircuitShape.Gate) :
    ∀ environment result,
      EnvironmentAgrees ctx values environment →
      (∀ gate ∈ gates, R1CS.Holds values (CircuitShape.interpretGate gate)) →
      eliminate environment gates = some result →
      EnvironmentAgrees ctx values result.environment ∧
        ∀ e ∈ result.assertions, evalField ctx.get e = 0 := by
  induction gates with
  | nil =>
    intro environment result agree _ run
    simp only [eliminate, Option.some.injEq] at run
    cases run
    exact ⟨agree, by simp⟩
  | cons gate rest ih =>
    intro environment result agree holds run
    have head := holds gate (by simp)
    have tail : ∀ g ∈ rest, R1CS.Holds values (CircuitShape.interpretGate g) := by
      intro g member; exact holds g (by simp [member])
    cases actionEq : actionOf environment gate with
    | none => simp [eliminate, actionEq] at run
    | some action =>
      have valid := action_sound ctx values environment gate action agree head actionEq
      cases action with
      | define expression =>
        have extended := environment_push ctx values environment expression agree valid
        apply ih (environment.push expression) result extended tail
        simpa [eliminate, actionEq] using run
      | assertZero expression =>
        cases nextEq : eliminate environment rest with
        | none => simp [eliminate, actionEq, nextEq] at run
        | some next =>
          simp only [eliminate, actionEq, nextEq] at run
          cases run
          obtain ⟨same, assertions⟩ := ih environment next agree tail nextEq
          refine ⟨same, ?_⟩
          intro e member
          rcases List.mem_cons.mp member with rfl | member
          · exact valid
          · exact assertions e member

def eliminatedRow := eliminate inputEnvironment rowBuild.2.gates.toList

def expectedAssertions : List Expr :=
  ((List.range 10).map fun i => selected i * (selected i - 1)) ++ row.residuals

def phasesLinear : List CircuitShape.Linear :=
  [rowBuild.1.ready, rowBuild.1.index] ++ rowBuild.1.leb.toList ++ [rowBuild.1.done]

def polynomialListEqual (a b : List Expr) : Bool :=
  a.length == b.length && (a.zip b).all fun pair => samePolynomial pair.1 pair.2

def rowPolynomialCertificate : Bool :=
  match eliminatedRow with
  | none => false
  | some result =>
    result.environment.size == 66 && result.assertions.length == 27 &&
    expectedAssertions.all (fun expected => result.assertions.any (samePolynomial expected)) &&
    result.assertions.all (fun actual => expectedAssertions.any (samePolynomial actual)) &&
    polynomialListEqual (phasesLinear.map (linearExpr result.environment)) row.nextPhases &&
    polynomialListEqual (rowBuild.1.depths.toList.map (linearExpr result.environment)) row.nextDepths

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem row_polynomial_certificate : rowPolynomialCertificate = true := by native_decide

theorem input_environment_entry : ∀ i : Fin 36,
    inputEnvironment[i.val]? = some (if i.val = 0 then .literal 1 else .input (i.val-1)) := by native_decide

theorem initial_environment_agrees {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (one : values 0 = 1)
    (inputs : ∀ i, i < 35 → values (i+1) = ctx.get i) :
    EnvironmentAgrees ctx values inputEnvironment := by
  intro i bound
  have range : i < 36 := by simpa [inputEnvironment] using bound
  rw [input_environment_entry ⟨i, range⟩]
  by_cases zero : i = 0
  · simp [zero, evalField, one, Ring.intCast_one]
  · have small : i-1 < 35 := by omega
    have prev : i-1+1 = i := by omega
    simpa [zero, evalField, prev] using (inputs (i-1) small).symm

theorem polynomial_list_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : List Expr) (same : polynomialListEqual a b = true) :
    a.map (evalField ctx.get) = b.map (evalField ctx.get) := by
  induction a generalizing b with
  | nil => cases b <;> simp_all [polynomialListEqual]
  | cons x xs ih =>
    cases b with
    | nil => simp [polynomialListEqual] at same
    | cons y ys =>
      have facts : xs.length = ys.length ∧ samePolynomial x y = true ∧
          (xs.zip ys).all (fun pair => samePolynomial pair.1 pair.2) = true := by
        simpa [polynomialListEqual] using same
      have head := polynomial_certificate_sound ctx x y facts.2.1
      have tail := ih ys (by simpa [polynomialListEqual] using And.intro facts.1 facts.2.2)
      simp [head, tail]

theorem row_output_bounds :
    (phasesLinear ++ rowBuild.1.depths.toList).all
      (fun linear => linear.all fun term => term.1 < 66) = true := by native_decide

theorem matrix_row_implies_equations {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (one : values 0 = 1)
    (inputs : ∀ i, i < 35 → values (i+1) = ctx.get i)
    (holds : ∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate)) :
    FieldHolds ctx.get ∧
    phasesLinear.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
      row.nextPhases.map (evalField ctx.get) ∧
    rowBuild.1.depths.toList.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
      row.nextDepths.map (evalField ctx.get) := by
  have certificate := row_polynomial_certificate
  cases found : eliminatedRow with
  | none => simp [rowPolynomialCertificate, found] at certificate
  | some result =>
    have checked : result.environment.size = 66 ∧ result.assertions.length = 27 ∧
        expectedAssertions.all (fun expected => result.assertions.any (samePolynomial expected)) = true ∧
        result.assertions.all (fun actual => expectedAssertions.any (samePolynomial actual)) = true ∧
        polynomialListEqual (phasesLinear.map (linearExpr result.environment)) row.nextPhases = true ∧
        polynomialListEqual (rowBuild.1.depths.toList.map (linearExpr result.environment)) row.nextDepths = true := by
      simpa [rowPolynomialCertificate, found, Bool.and_eq_true_iff, and_assoc] using certificate
    have run : eliminate inputEnvironment rowBuild.2.gates.toList = some result := found
    obtain ⟨environment, assertions⟩ := elimination_sound ctx values rowBuild.2.gates.toList
      inputEnvironment result (initial_environment_agrees ctx values one inputs) holds run
    have required (e : Expr) (member : e ∈ expectedAssertions) : evalField ctx.get e = 0 := by
      have matching := List.all_eq_true.mp checked.2.2.1 e member
      obtain ⟨actual, actualMember, equal⟩ := List.any_eq_true.mp matching
      rw [polynomial_certificate_sound ctx e actual equal]
      exact assertions actual actualMember
    have expressionSound (linear : CircuitShape.Linear)
        (member : linear ∈ phasesLinear ++ rowBuild.1.depths.toList) :
        R1CS.eval values (CircuitShape.interpretLinear linear) =
          evalField ctx.get (linearExpr result.environment linear) := by
      apply (linear_expression_sound ctx values result.environment linear environment ?_).symm
      have bound := List.all_eq_true.mp row_output_bounds linear member
      simpa only [inBounds, checked.1] using bound
    refine ⟨?_, ?_, ?_⟩
    · intro e member
      exact required e (by simp [expectedAssertions, member])
    · have converted : phasesLinear.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
          (phasesLinear.map (linearExpr result.environment)).map (evalField ctx.get) := by
        simp only [List.map_map]
        apply List.map_congr_left
        intro linear member
        exact expressionSound linear (by simp [member])
      exact converted.trans (polynomial_list_sound ctx _ _ checked.2.2.2.2.1)
    · have converted : rowBuild.1.depths.toList.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
          (rowBuild.1.depths.toList.map (linearExpr result.environment)).map (evalField ctx.get) := by
        simp only [List.map_map]
        apply List.map_congr_left
        intro linear member
        exact expressionSound linear (by simp [member])
      exact converted.trans (polynomial_list_sound ctx _ _ checked.2.2.2.2.2)

def selectorGate (i : Fin 10) : CircuitShape.Gate :=
  ⟨[(26+i.val, 1)], [(26+i.val, 1), (0, -1)], [(0, 0)]⟩

theorem selector_gate_present : ∀ i, selectorGate i ∈ rowBuild.2.gates.toList := by native_decide

theorem matrix_selectors_boolean {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (values : Nat → F) (one : values 0 = 1)
    (inputs : ∀ i, i < 35 → values (i+1) = ctx.get i)
    (holds : ∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate)) :
    ∀ value ∈ InputNormalization.witnessSelectors ctx.get, value * (value - 1) = 0 := by
  intro value member
  obtain ⟨i, rfl⟩ := List.mem_ofFn.mp member
  have valid := holds (selectorGate i) (selector_gate_present i)
  have input := inputs (25+i.val) (by have := i.isLt; omega)
  have index : 25+i.val+1 = 26+i.val := by omega
  rw [index] at input
  simp [selectorGate, CircuitShape.interpretGate, CircuitShape.interpretLinear, R1CS.Holds, R1CS.eval,
    one, Ring.intCast_one, Ring.intCast_neg, Ring.intCast_zero, Semiring.one_mul, Semiring.add_zero] at valid
  grind

def selectorSumExpr : Expr := sumExpr ((List.range 10).map selected)
def byteExpr : Expr := sumExpr ((List.range 8).map fun i => bit i * .literal (Int.ofNat (2^i)))
def selectorWeightExpr : Expr := sumExpr ((List.range 10).map fun i =>
  selected i * .literal (Int.ofNat (ByteStream.opcode i)))

theorem selector_residuals_present :
    selectorSumExpr - phase 0 ∈ row.residuals ∧
    phase 0 * byteExpr - selectorWeightExpr ∈ row.residuals := by native_decide

theorem selector_sum_semantics {F : Type} [CommRing F] (values : Nat → F) :
    evalField values selectorSumExpr = R1CS.sum (InputNormalization.witnessSelectors values) := by
  simp [selectorSumExpr, sumExpr, evalField, selected, InputNormalization.witnessSelectors,
    R1CS.sum, Ring.intCast_zero, List.range_succ]

theorem byte_value_semantics {F : Type} [CommRing F] (values : Nat → F) :
    evalField values byteExpr = R1CS.weightedValues (BitPacking.bitWeights 8)
      (InputNormalization.witnessBits values) := by
  simp [byteExpr, sumExpr, evalField, bit, InputNormalization.witnessBits,
    BitPacking.byte_weights_exact, R1CS.weightedValues, Ring.intCast_zero, List.range_succ]
  grind

theorem selector_weight_semantics {F : Type} [CommRing F] (values : Nat → F) :
    evalField values selectorWeightExpr = R1CS.weightedValues InputNormalization.opcodeCodes
      (InputNormalization.witnessSelectors values) := by
  simp [selectorWeightExpr, sumExpr, evalField, selected, InputNormalization.witnessSelectors,
    InputNormalization.opcodeCodes, ByteStream.opcode, R1CS.weightedValues, Ring.intCast_zero, List.range_succ]
  grind

theorem field_selector_equations {F : Type} [CommRing F] (values : Nat → F)
    (holds : FieldHolds values) :
    R1CS.sum (InputNormalization.witnessSelectors values) = values 0 ∧
    R1CS.weightedValues InputNormalization.opcodeCodes (InputNormalization.witnessSelectors values) =
      values 0 * R1CS.weightedValues (BitPacking.bitWeights 8) (InputNormalization.witnessBits values) := by
  have sumZero := holds _ selector_residuals_present.1
  have weightedZero := holds _ selector_residuals_present.2
  change evalField values selectorSumExpr - values 0 = 0 at sumZero
  change values 0 * evalField values byteExpr - evalField values selectorWeightExpr = 0 at weightedZero
  rw [selector_sum_semantics] at sumZero
  rw [byte_value_semantics, selector_weight_semantics] at weightedZero
  constructor <;> grind

theorem matrix_row_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (values : Nat → F) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : values 0 = 1) (inputs : ∀ i, i < 35 → values (i+1) = ctx.get i)
    (phases : ∀ i : Fin 8, ctx.get i.val = if i.val = p.val then 1 else 0)
    (depths : ∀ i : Fin 9, ctx.get (8+i.val) = if i.val = h.val then 1 else 0)
    (bitsBoolean : ∀ value ∈ InputNormalization.witnessBits ctx.get, value * (value - 1) = 0)
    (bitsBinding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (InputNormalization.witnessBits ctx.get) = (b.val : F))
    (holds : ∀ gate ∈ rowBuild.2.gates.toList, R1CS.Holds values (CircuitShape.interpretGate gate)) :
    ∃ nextPhase nextDepth,
      ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth) ∧
      phasesLinear.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
        (oneHot 8 nextPhase).map (fun n : Int => (n : F)) ∧
      rowBuild.1.depths.toList.map (fun linear => R1CS.eval values (CircuitShape.interpretLinear linear)) =
        (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
  obtain ⟨equations, phaseEquations, depthEquations⟩ := matrix_row_implies_equations ctx values one inputs holds
  have selectorsBoolean := matrix_selectors_boolean ctx values one inputs holds
  obtain ⟨selectorsTotal, selectorsBinding⟩ := field_selector_equations ctx.get equations
  have ready : ctx.get 0 = if p.val = 0 then 1 else 0 := by simpa [eq_comm] using phases ⟨0, by decide⟩
  obtain ⟨nextPhase, nextDepth, ref, nextPhases, nextDepths⟩ :=
    InputNormalization.constrained_field_row_sound ctx.get p h b phases depths bitsBoolean bitsBinding selectorsBoolean
      (by simpa [ready] using selectorsTotal) (by simpa [ready, bitsBinding] using selectorsBinding) equations
  exact ⟨nextPhase, nextDepth, ref, phaseEquations.trans nextPhases, depthEquations.trans nextDepths⟩

#print axioms polynomial_certificate_sound
#print axioms elimination_sound
#print axioms matrix_row_implies_equations
#print axioms matrix_row_sound
#print axioms row_polynomial_certificate

end ZkBuild.RowMatrix
