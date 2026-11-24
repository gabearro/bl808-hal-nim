import ByteCompileTyping

/- Construct all 27 bridge-row auxiliary values as polynomials in its inputs.
   Every gate is then satisfied, provided the overflow guard is satisfied. -/
namespace ZkBuild.ByteCompileRowComplete

open Lean.Grind CircuitShape FullMatrix RowSoundness ByteCompileTransition
attribute [local instance] Ring.intCast Semiring.natCast

def negativeExpr : Expr := (.sub (.literal 1) (.input 14)) * .input 13
def freshExpr (i : Nat) : Expr :=
  if i < 5 then .input (2+i) * directExpression (ByteCompileRow.payloadBits i)
  else if i = 5 then negativeExpr
  else if i = 6 then negativeExpr * directExpression ByteCompileRow.signExtension
  else if i = 7 then (.sub (.literal 1) (.input 15)) * .input 23
  else if i = 8 then immediateExpr
  else if i = 9 then .input 1 * (.add (.literal 1) (.input 7))
  else if i = 10 then .input 16 * (.add (.literal 3) (.mul (.literal 16) immediateExpr))
  else
    let j := i-11
    .input (24+j) + eventExpr *
      ((if j+1 < 16 then .input (25+j) else tokenExpr) - .input (24+j))

def environment : Array Expr :=
  #[.literal 1] ++ (List.range 39).toArray.map (fun i => .input (i+1)) ++
    (List.range 27).toArray.map freshExpr

def residual (i : Nat) : Expr :=
  let gate := ByteCompileRow.gate i
  RowMatrix.linearExpr environment gate.a * RowMatrix.linearExpr environment gate.b -
    RowMatrix.linearExpr environment gate.c

def overflowExpr : Expr := eventExpr * .input 24

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem complete_certificate : ∀ i : Fin 28,
    RowMatrix.samePolynomial (residual i.val) (if i.val = 11 then overflowExpr else .literal 0) = true := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem bounds_certificate : environment.size = 67 ∧ ∀ i : Fin 28,
    RowMatrix.inBounds environment (ByteCompileRow.gate i.val).a = true ∧
    RowMatrix.inBounds environment (ByteCompileRow.gate i.val).b = true ∧
    RowMatrix.inBounds environment (ByteCompileRow.gate i.val).c = true := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem entries : ∀ i : Fin 67, environment[i.val]? =
    some (if i.val = 0 then .literal 1 else if i.val < 40 then .input i.val else freshExpr (i.val-40)) := by
  native_decide

def witness (inputs : Lean.RArray Int) (index : Nat) : Int :=
  evalInt inputs.get (environment[index]?.getD (.literal 0))

def fieldWitness {F : Type} [CommRing F] (inputs : Lean.RArray F) (index : Nat) : F :=
  evalField inputs.get (environment[index]?.getD (.literal 0))

theorem input_value {F : Type} [CommRing F] (inputs : Lean.RArray F) (one : inputs.get 0 = 1)
    (index : Nat) (bound : index < 40) : fieldWitness inputs index = inputs.get index := by
  rw [fieldWitness, entries ⟨index, by omega⟩]
  by_cases zero : index = 0
  · simp [zero, evalField, one, Ring.intCast_one]
  · simp [zero, bound, evalField]

theorem output_value {F : Type} [CommRing F] (inputs : Lean.RArray F) (i : Fin 27) :
    fieldWitness inputs (40+i.val) = evalField inputs.get (freshExpr i.val) := by
  rw [fieldWitness, entries ⟨40+i.val, by omega⟩]
  simp [show ¬40+i.val < 40 by omega]

theorem row_complete {F : Type} [CommRing F] (inputs : Lean.RArray F)
    (overflow : evalField inputs.get overflowExpr = 0) : ByteCompileRow.Holds (fieldWitness inputs) := by
  intro i
  have agreement : RowMatrix.EnvironmentAgrees inputs (fieldWitness inputs) environment := by
    intro index bound
    rfl
  have a := RowMatrix.linear_expression_sound inputs (fieldWitness inputs) environment (ByteCompileRow.gate i.val).a
    agreement (bounds_certificate.2 i).1
  have b := RowMatrix.linear_expression_sound inputs (fieldWitness inputs) environment (ByteCompileRow.gate i.val).b
    agreement (bounds_certificate.2 i).2.1
  have c := RowMatrix.linear_expression_sound inputs (fieldWitness inputs) environment (ByteCompileRow.gate i.val).c
    agreement (bounds_certificate.2 i).2.2
  have equation := RowMatrix.polynomial_certificate_sound inputs _ _ (complete_certificate i)
  have zero : evalField inputs.get (residual i.val) = 0 := by
    rw [equation]
    by_cases guard : i.val = 11
    · simpa [guard] using overflow
    · simp [guard, evalField, Ring.intCast_zero]
  change evalField inputs.get (RowMatrix.linearExpr environment (ByteCompileRow.gate i.val).a) *
    evalField inputs.get (RowMatrix.linearExpr environment (ByteCompileRow.gate i.val).b) -
    evalField inputs.get (RowMatrix.linearExpr environment (ByteCompileRow.gate i.val).c) = 0 at zero
  rw [a, b, c] at zero
  change R1CS.eval (fieldWitness inputs) (interpretLinear (ByteCompileRow.gate i.val).a) *
    R1CS.eval (fieldWitness inputs) (interpretLinear (ByteCompileRow.gate i.val).b) =
    R1CS.eval (fieldWitness inputs) (interpretLinear (ByteCompileRow.gate i.val).c)
  grind

theorem witness_cast {F : Type} [CommRing F] (inputs : Lean.RArray Int) (fieldInputs : Lean.RArray F)
    (same : ∀ i, fieldInputs.get i = (inputs.get i : F)) (index : Nat) :
    fieldWitness fieldInputs index = (witness inputs index : F) := by
  unfold fieldWitness witness
  have values : fieldInputs.get = fun i => (inputs.get i : F) := funext same
  rw [values, integer_interpretation_commutes]

#print axioms row_complete

end ZkBuild.ByteCompileRowComplete
