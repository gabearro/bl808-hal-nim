import SlotRowSchema

namespace ZkBuild.SlotRow

open Lean.Grind RowSoundness CircuitShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem base_agreement {F : Type} [CommRing F] (ctx : Lean.RArray F) (values : Nat → F)
    (one : values 0 = 1) (inputs : ∀ i, i < 72 → values (sourceWire i) = ctx.get i) :
    RowMatrix.EnvironmentAgrees ctx values baseEnvironment := by
  intro i bound
  have small : i < 52 := by simpa [baseEnvironment] using bound
  rw [base_entries ⟨i, small⟩]
  by_cases zero : i = 0
  · simp [zero, evalField, one, Ring.intCast_one]
  · have before : i-1 < 51 := by omega
    have same : i-1+1 = i := by omega
    simpa [zero, evalField, sourceWire, before, same] using (inputs (i-1) (by omega)).symm

theorem products_determined {F : Type} [CommRing F] (ctx : Lean.RArray F) (values : Nat → F)
    (one : values 0 = 1) (inputs : ∀ i, i < 72 → values (sourceWire i) = ctx.get i)
    (holds : Satisfied rowBuild.2 values) (j : Fin 5) :
    evalField ctx.get (productExpression j) = values (52+j.val) := by
  have facts := product_gates j
  have equation := holds _ facts.1
  have a := RowMatrix.linear_expression_sound ctx values baseEnvironment (productGate j).a
    (base_agreement ctx values one inputs) facts.2.2.1
  have b := RowMatrix.linear_expression_sound ctx values baseEnvironment (productGate j).b
    (base_agreement ctx values one inputs) facts.2.2.2
  change R1CS.eval values (interpretLinear (productGate j).a) *
    R1CS.eval values (interpretLinear (productGate j).b) = R1CS.eval values (interpretLinear (productGate j).c) at equation
  rw [facts.2.1] at equation
  simpa [productExpression, evalField, a, b, interpretLinear, R1CS.eval,
    Ring.intCast_one, Semiring.one_mul, Semiring.add_zero] using equation

theorem initial_agreement {F : Type} [CommRing F] (ctx : Lean.RArray F) (values : Nat → F)
    (one : values 0 = 1) (inputs : ∀ i, i < 72 → values (sourceWire i) = ctx.get i)
    (holds : Satisfied rowBuild.2 values) : RowMatrix.EnvironmentAgrees ctx values inputEnvironment := by
  intro i bound
  have small : i < 78 := by simpa [inputEnvironment, baseEnvironment] using bound
  rw [input_entries ⟨i, small⟩]
  by_cases zero : i = 0
  · simp [zero, evalField, one, Ring.intCast_one]
  · simp only [zero, ite_false]
    by_cases base : i < 52
    · have before : i-1 < 51 := by omega
      have same : i-1+1 = i := by omega
      simpa [base, evalField, sourceWire, before, same] using (inputs (i-1) (by omega)).symm
    · simp only [base, ite_false]
      by_cases product : i < 57
      · simp only [product, dite_true]
        have same : 52+(i-52) = i := by omega
        simpa only [Option.getD_some, same] using products_determined ctx values one inputs holds ⟨i-52, by omega⟩
      · have before : ¬i-6 < 51 := by omega
        have same : i-6+6 = i := by omega
        simpa [product, evalField, sourceWire, before, same] using (inputs (i-6) (by omega)).symm

theorem matrix_implies_equations {F : Type} [CommRing F] (ctx : Lean.RArray F) (values : Nat → F)
    (one : values 0 = 1) (inputs : ∀ i, i < 72 → values (sourceWire i) = ctx.get i)
    (holds : Satisfied rowBuild.2 values) :
    (∀ expression ∈ residuals, evalField ctx.get expression = 0) ∧
      outputLinears.map (fun linear => R1CS.eval values (interpretLinear linear)) = outputs.map (evalField ctx.get) := by
  have verified := row_certificate
  cases found : eliminated with
  | none => simp [certificate, found] at verified
  | some result =>
    have facts : result.environment.size = 753 ∧ result.assertions.length = 71 ∧
        (0 :: residuals).all (fun expected => result.assertions.any (RowMatrix.samePolynomial expected)) = true ∧
        result.assertions.all (fun actual => (0 :: residuals).any (RowMatrix.samePolynomial actual)) = true ∧
        RowMatrix.polynomialListEqual (outputLinears.map (RowMatrix.linearExpr result.environment)) outputs = true := by
      simpa [certificate, found, Bool.and_eq_true_iff, and_assoc] using verified
    obtain ⟨environment, assertions⟩ := RowMatrix.elimination_sound ctx values rowBuild.2.gates.toList
      inputEnvironment result (initial_agreement ctx values one inputs holds) holds found
    constructor
    · intro expression member
      have checked := List.all_eq_true.mp facts.2.2.1 expression (by simp [member])
      obtain ⟨actual, actualMember, same⟩ := List.any_eq_true.mp checked
      rw [RowMatrix.polynomial_certificate_sound ctx expression actual same]
      exact assertions actual actualMember
    · have converted : outputLinears.map (fun linear => R1CS.eval values (interpretLinear linear)) =
          (outputLinears.map (RowMatrix.linearExpr result.environment)).map (evalField ctx.get) := by
        simp only [List.map_map]
        apply List.map_congr_left
        intro linear member
        apply (RowMatrix.linear_expression_sound ctx values result.environment linear environment ?_).symm
        have bounded := List.all_eq_true.mp outputs_bounded linear member
        simpa only [RowMatrix.inBounds, facts.1] using bounded
      exact converted.trans (RowMatrix.polynomial_list_sound ctx _ _ facts.2.2.2.2)

#print axioms row_certificate
#print axioms matrix_implies_equations

end ZkBuild.SlotRow
