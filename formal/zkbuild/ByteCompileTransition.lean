import ByteCompileDecodeRow

/- Eliminate each bridge row's arithmetic temporaries, then interpret its
   immediate/token outputs as exact integer transitions of the parsed byte. -/
namespace ZkBuild.ByteCompileTransition

open Lean.Grind CircuitShape FullMatrix RowSoundness ByteCompileComposition
open ByteCompileRow (localValues)
attribute [local instance] Ring.intCast Semiring.natCast

def payloadExpr : Expr := sumExpr ((List.range 5).map fun j =>
  .literal (Int.ofNat (2^(7*j))) * (.input (2+j) * directExpression (ByteCompileRow.payloadBits j)))

def immediateExpr : Expr :=
  (.sub (.literal 1) (.input 15)) * .input 23 + payloadExpr +
    ((.sub (.literal 1) (.input 14)) * .input 13) * directExpression ByteCompileRow.signExtension

def tokenExpr : Expr :=
  .input 1 * (.add (.literal 1) (.input 7)) + .input 16 * (.add (.literal 3) (.mul (.literal 16) immediateExpr)) +
    directExpression ByteCompileRow.binaryToken

def eventExpr : Expr := directExpression ByteCompileRow.event

theorem payload_value {F : Type} [CommRing F] (values : Nat → F) (holds : ByteCompileRow.Holds values) :
    evalLinear values ByteCompileRow.payload = evalField values payloadExpr := by
  have first := ByteCompileRow.payload_equations values holds ⟨0, by decide⟩
  have second := ByteCompileRow.payload_equations values holds ⟨1, by decide⟩
  have third := ByteCompileRow.payload_equations values holds ⟨2, by decide⟩
  have fourth := ByteCompileRow.payload_equations values holds ⟨3, by decide⟩
  have fifth := ByteCompileRow.payload_equations values holds ⟨4, by decide⟩
  simp only [ByteCompileRow.payload, payloadExpr, List.range_succ, List.range_zero, List.map_cons,
    List.map_nil, List.flatten_cons, List.flatten_nil,
    List.append_nil, List.nil_append, List.cons_append, sumExpr, evalField, direct_expression_sound]
  simp only [eval_append, eval_scale, ByteCompileRow.eval_wire, first, second, third, fourth, fifth]
  simp only [Semiring.add_zero]
  grind

theorem immediate_value {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : ByteCompileRow.Holds values) : values 48 = evalField values immediateExpr := by
  rw [ByteCompileRow.immediate_equation values one holds,
    ByteCompileRow.reset_equation values one holds, payload_value values holds,
    ByteCompileRow.sign_equation values holds, ByteCompileRow.negative_equation values one holds]
  simp only [immediateExpr, evalField, Ring.intCast_one, direct_expression_sound]

theorem token_value {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : ByteCompileRow.Holds values) :
    evalLinear values ByteCompileRow.token = evalField values tokenExpr := by
  rw [ByteCompileRow.token, eval_append, eval_append, ByteCompileRow.eval_wire,
    ByteCompileRow.eval_wire, ByteCompileRow.get_equation values one holds,
    ByteCompileRow.constant_equation values one holds, immediate_value values one holds]
  simp only [tokenExpr, evalField, Ring.intCast_one, direct_expression_sound]

def integerInputs (p : Fin 8) (b : Fin 256) (previous : Int) (k : Nat) : Int :=
  if k = 23 then previous else ByteCompileDecodeRow.canonical p b k

def nextImmediate (p : Fin 8) (b : Fin 256) (previous : Int) : Int :=
  evalInt (integerInputs p b previous) immediateExpr

def emittedToken (p : Fin 8) (b : Fin 256) (previous : Int) : Int :=
  evalInt (integerInputs p b previous) tokenExpr

def emittedEvent (p : Fin 8) (b : Fin 256) : Int :=
  evalInt (ByteCompileDecodeRow.canonical p b) eventExpr

theorem transition_uses : InputNormalization.UsesBelow 24 immediateExpr = true ∧
    InputNormalization.UsesBelow 24 tokenExpr = true ∧ InputNormalization.UsesBelow 23 eventExpr = true := by native_decide

theorem integer_transition {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (i : Fin 121) (p : Fin 8) (h : Fin 9) (b : Fin 256) (previous : Int)
    (one : values 0 = 1) (before : BodySoundness.AtState (byteContext values) i.val (p, h))
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get (moduleByteIndex i)) = (b.val : F))
    (holds : Satisfied ByteCompileShape.shape values) (prior : localValues values i 23 = (previous : F)) :
    localValues values i 48 = (nextImmediate p b previous : F) ∧
      evalLinear (localValues values i) ByteCompileRow.token = (emittedToken p b previous : F) ∧
      evalLinear (localValues values i) ByteCompileRow.event = (emittedEvent p b : F) := by
  have normalized := ByteCompileDecodeRow.canonical_bridge_inputs values i p h b one before binding holds
  have rowOne := ByteCompileRow.local_one values one i
  have rowHolds := ByteCompileRow.all_rows_hold values holds i
  have inputs (k : Nat) (bound : k < 24) :
      localValues values i k = (integerInputs p b previous k : F) := by
    by_cases last : k = 23
    · simpa [integerInputs, last] using prior
    · simpa [integerInputs, last] using normalized k (by omega)
  constructor
  · rw [immediate_value (localValues values i) rowOne rowHolds,
      InputNormalization.eval_congr_below (localValues values i)
        (fun k => (integerInputs p b previous k : F)) 24 inputs immediateExpr transition_uses.1,
      integer_interpretation_commutes]
    rfl
  · constructor
    · rw [token_value (localValues values i) rowOne rowHolds,
        InputNormalization.eval_congr_below (localValues values i)
          (fun k => (integerInputs p b previous k : F)) 24 inputs tokenExpr transition_uses.2.1,
        integer_interpretation_commutes]
      rfl
    · rw [← direct_expression_sound (localValues values i) ByteCompileRow.event]
      change evalField (localValues values i) eventExpr = _
      rw [InputNormalization.eval_congr_below (localValues values i)
          (fun k => (ByteCompileDecodeRow.canonical p b k : F)) 23 normalized eventExpr transition_uses.2.2,
        integer_interpretation_commutes]
      rfl

#print axioms immediate_value
#print axioms token_value
#print axioms integer_transition

end ZkBuild.ByteCompileTransition
