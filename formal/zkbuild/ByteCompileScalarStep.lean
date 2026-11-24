import ByteCompileTransition

/- Closed integer interpretation of the constrained decoder. The interval
   certificate proves safety for every integer accumulator in its permitted
   range, rather than enumerating the 32-bit constant values. -/
namespace ZkBuild.ByteCompileScalarStep

open Lean.Grind RowSoundness ByteCompileTransition
attribute [local instance] Ring.intCast Semiring.natCast

def resetFactor (p : Fin 8) (b : Fin 256) : Int :=
  if p.val = 0 ∧ b.val = 65 then 0 else 1

def contribution (p : Fin 8) (b : Fin 256) : Nat :=
  if 2 ≤ p.val ∧ p.val < 7 then
    (b.val % (if p.val = 6 then 16 else 128))*2^(7*(p.val-2)) +
      if p.val < 6 ∧ 64 ≤ b.val ∧ b.val < 128 then 2^32 - 2^(7*(p.val-1)) else 0
  else 0

def binaryCode (b : Fin 256) : Nat :=
  match b.val with
  | 106 => 4 | 107 => 5 | 108 => 6 | 113 => 7 | 114 => 8 | 115 => 9 | _ => 0

def finishes (p : Fin 8) (b : Fin 256) : Bool := 2 ≤ p.val && p.val < 7 && b.val < 128

def immediateRule (p : Fin 8) (b : Fin 256) : Expr :=
  .add (.mul (.literal (resetFactor p b)) (.input 0)) (.literal (contribution p b))

def tokenRule (p : Fin 8) (b : Fin 256) : Expr :=
  .add (.literal ((if p.val = 1 then 1+b.val%2 else 0) + (if p.val = 0 then binaryCode b else 0)))
    (.mul (.literal (if finishes p b then 1 else 0))
      (.add (.literal 3) (.mul (.literal 16) (immediateRule p b))))

def eventRule (p : Fin 8) (b : Fin 256) : Nat :=
  if p.val = 1 ∨ finishes p b ∨ (p.val = 0 ∧ binaryCode b ≠ 0) then 1 else 0

def specialize (p : Fin 8) (b : Fin 256) : Expr → Expr
  | .literal n => .literal n
  | .input k => if k = 23 then .input 0 else .literal (ByteCompileDecodeRow.canonical p b k)
  | .add a c => .add (specialize p b a) (specialize p b c)
  | .sub a c => .sub (specialize p b a) (specialize p b c)
  | .mul a c => .mul (specialize p b a) (specialize p b c)

theorem specialize_eval (p : Fin 8) (b : Fin 256) (previous : Int) (expression : Expr) :
    evalInt (fun _ => previous) (specialize p b expression) = evalInt (integerInputs p b previous) expression := by
  induction expression with
  | literal n => rfl
  | input k => by_cases same : k = 23 <;> simp [specialize, evalInt, integerInputs, same]
  | add a c ha hc => simp [specialize, evalInt, ha, hc]
  | sub a c ha hc => simp [specialize, evalInt, ha, hc]
  | mul a c ha hc => simp [specialize, evalInt, ha, hc]

theorem eval_field_int (values : Nat → Int) (expression : Expr) :
    evalField values expression = evalInt values expression := by
  induction expression <;> simp_all [evalField, evalInt]

theorem same_polynomial_int (a b : Expr) (previous : Int) (same : RowMatrix.samePolynomial a b = true) :
    evalInt (fun _ => previous) a = evalInt (fun _ => previous) b := by
  have equality := RowMatrix.polynomial_certificate_sound (F := Int) (.leaf previous) a b same
  simpa only [eval_field_int] using equality

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem immediate_certificate : ∀ p b,
    RowMatrix.samePolynomial (specialize p b immediateExpr) (immediateRule p b) = true := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem token_certificate : ∀ p b,
    RowMatrix.samePolynomial (specialize p b tokenExpr) (tokenRule p b) = true := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem event_certificate : ∀ p b, emittedEvent p b = (eventRule p b : Int) := by native_decide

theorem immediate_formula (p : Fin 8) (b : Fin 256) (previous : Int) :
    nextImmediate p b previous = resetFactor p b * previous + (contribution p b : Int) := by
  rw [nextImmediate, ← specialize_eval p b previous immediateExpr,
    same_polynomial_int _ _ previous (immediate_certificate p b)]
  rfl

theorem token_formula (p : Fin 8) (b : Fin 256) (previous : Int) :
    emittedToken p b previous =
      ((if p.val = 1 then 1+b.val%2 else 0) + (if p.val = 0 then binaryCode b else 0) : Nat) +
      (if finishes p b then (3 + 16*nextImmediate p b previous) else 0) := by
  rw [emittedToken, ← specialize_eval p b previous tokenExpr,
    same_polynomial_int _ _ previous (token_certificate p b)]
  simp only [tokenRule, immediateRule, evalInt, immediate_formula]
  cases finishes p b <;> simp

def limit (phase : Nat) : Nat := if 2 ≤ phase ∧ phase < 7 then 2^(7*(phase-2)) else 2^32

def intervalCertificate (p : Fin 8) (h : Fin 9) (b : Fin 256) : Bool :=
  match ByteStream.referenceRow p.val h.val b.val with
  | none => true
  | some (np, _) => decide (
      (resetFactor p b = 0 ∨ resetFactor p b = 1) ∧
      0 ≤ (contribution p b : Int) ∧
      resetFactor p b * ((limit p.val : Int)-1) + (contribution p b : Int) < (limit np : Int))

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem interval_certificate : ∀ p h b, intervalCertificate p h b = true := by native_decide

theorem preserves_interval (p : Fin 8) (h : Fin 9) (b : Fin 256) (np nh : Nat) (previous : Int)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (np, nh))
    (range : 0 ≤ previous ∧ previous < (limit p.val : Int)) :
    0 ≤ nextImmediate p b previous ∧ nextImmediate p b previous < (limit np : Int) := by
  have certificate := interval_certificate p h b
  have bounds : (resetFactor p b = 0 ∨ resetFactor p b = 1) ∧
      0 ≤ (contribution p b : Int) ∧
      resetFactor p b * ((limit p.val : Int)-1) + (contribution p b : Int) < (limit np : Int) := by
    simpa [intervalCertificate, accepted] using certificate
  rw [immediate_formula]
  rcases bounds with ⟨factor, nonnegative, maximum⟩
  rcases factor with reset | keep
  · rw [reset] at maximum ⊢
    simp only [Int.zero_mul, Int.zero_add] at maximum ⊢
    exact ⟨nonnegative, maximum⟩
  · rw [keep] at maximum ⊢
    simp only [Int.one_mul] at maximum ⊢
    omega

theorem limit_word_bound (p : Nat) : limit p ≤ 2^32 := by
  unfold limit
  split
  next bound =>
    have exponents : p = 2 ∨ p = 3 ∨ p = 4 ∨ p = 5 ∨ p = 6 := by omega
    rcases exponents with rfl | rfl | rfl | rfl | rfl <;> decide
  next => omega

theorem produces_word (p : Fin 8) (h : Fin 9) (b : Fin 256) (np nh : Nat) (previous : Int)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (np, nh))
    (range : 0 ≤ previous ∧ previous < (limit p.val : Int)) :
    0 ≤ nextImmediate p b previous ∧ nextImmediate p b previous < (2^32 : Int) := by
  have next := preserves_interval p h b np nh previous accepted range
  have bound := limit_word_bound np
  constructor
  · exact next.1
  · omega

#print axioms immediate_formula
#print axioms token_formula
#print axioms preserves_interval

end ZkBuild.ByteCompileScalarStep
