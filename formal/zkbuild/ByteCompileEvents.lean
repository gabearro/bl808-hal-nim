import ByteCompileAccumulator

/- Interpret a parser event as a concrete i32 operation. The operation token
   includes the complete 32-bit constant, not a probabilistic fingerprint. -/
namespace ZkBuild.ByteCompileEvents

open Lean.Grind RowSoundness ByteCompileTransition ByteCompileScalarStep
attribute [local instance] Ring.intCast Semiring.natCast

def kind (p : Fin 8) (b : Fin 256) : Nat :=
  if p.val = 1 then 1+b.val%2
  else if finishes p b then 3
  else if p.val = 0 then binaryCode b else 0

theorem kind_bound : ∀ p b, kind p b < 10 := by native_decide

theorem event_kind : ∀ p b, eventRule p b = if kind p b = 0 then 0 else 1 := by native_decide

def kindTokenRule (p : Fin 8) (b : Fin 256) : Expr :=
  .add (.literal (kind p b)) (if kind p b = 3 then .mul (.literal 16) (immediateRule p b) else .literal 0)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem kind_token_certificate : ∀ p b,
    RowMatrix.samePolynomial (specialize p b tokenExpr) (kindTokenRule p b) = true := by native_decide

theorem kind_token (p : Fin 8) (b : Fin 256) (previous : Int) :
    emittedToken p b previous = (kind p b : Int) +
      if kind p b = 3 then 16 * nextImmediate p b previous else 0 := by
  rw [emittedToken, ← specialize_eval p b previous tokenExpr,
    same_polynomial_int _ _ previous (kind_token_certificate p b)]
  simp only [kindTokenRule, evalInt, immediateRule, immediate_formula]
  split <;> rfl

theorem operation_token (k : Fin 10) (value : Word) :
    ByteCompileQueue.token (SlotNative.operation k value) =
      k.val + if k.val = 3 then 16*value.toNat else 0 := by
  rcases k with ⟨k, bound⟩
  have options : k = 0 ∨ k = 1 ∨ k = 2 ∨ k = 3 ∨ k = 4 ∨ k = 5 ∨ k = 6 ∨ k = 7 ∨ k = 8 ∨ k = 9 := by omega
  rcases options with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [SlotNative.operation, SlotProgram.withImmediate, SlotProgram.operationKind,
      ByteCompileQueue.token, ByteCompileQueue.binaryToken]

def eventOp (p : Fin 8) (b : Fin 256) (previous : Int) : Option Op :=
  if kind p b = 0 then none
  else some (SlotNative.operation ⟨kind p b, kind_bound p b⟩
    (BitVec.ofNat 32 (nextImmediate p b previous).toNat))

theorem event_operation (p : Fin 8) (h : Fin 9) (b : Fin 256) (np nh : Nat) (previous : Int)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (np, nh))
    (range : 0 ≤ previous ∧ previous < (limit p.val : Int)) :
    match eventOp p b previous with
    | none => emittedEvent p b = 0 ∧ emittedToken p b previous = 0
    | some op => emittedEvent p b = 1 ∧ emittedToken p b previous = (ByteCompileQueue.token op : Int) ∧ op ≠ .nop := by
  have event := event_certificate p b
  rw [event_kind] at event
  have token := kind_token p b previous
  have bounds := produces_word p h b np nh previous accepted range
  have wordNat : (BitVec.ofNat 32 (nextImmediate p b previous).toNat).toNat = (nextImmediate p b previous).toNat := by
    rw [BitVec.toNat_ofNat]
    apply Nat.mod_eq_of_lt
    omega
  have asInteger : ((nextImmediate p b previous).toNat : Int) = nextImmediate p b previous := Int.toNat_of_nonneg bounds.1
  by_cases zero : kind p b = 0
  · simp only [eventOp, zero, ite_true]
    exact ⟨by simpa [zero] using event, by simpa [zero] using token⟩
  · simp only [eventOp, zero, ite_false]
    let k : Fin 10 := ⟨kind p b, kind_bound p b⟩
    let value : Word := BitVec.ofNat 32 (nextImmediate p b previous).toNat
    have packed := operation_token k value
    have positive : ByteCompileQueue.token (SlotNative.operation k value) ≠ 0 := by
      rw [packed]
      dsimp [k]
      omega
    refine ⟨by simpa [zero] using event, ?_, ?_⟩
    · rw [operation_token, Int.natCast_add]
      by_cases constant : kind p b = 3
      · simp only [constant, ite_true, Int.natCast_mul, wordNat, asInteger] at *
        exact token
      · simp only [constant, ite_false, Int.natCast_zero, Int.add_zero] at *
        exact token
    · intro equal
      exact positive ((ByteCompileQueue.token_zero _).mpr equal)

#print axioms event_operation

end ZkBuild.ByteCompileEvents
