import ByteCompileRow

namespace ZkBuild.ByteCompileDecodeRow

open Lean.Grind CircuitShape FullMatrix BodySoundness ByteCompileComposition
open ByteCompileRow (rowMap localValues)
attribute [local instance] Ring.intCast Semiring.natCast

def inputIndex (k : Nat) : Nat :=
  if k < 7 then k else if k < 15 then k+10 else if k = 15 then 27 else k+11

def canonical (phase : Fin 8) (byte : Fin 256) (k : Nat) : Int :=
  if k = 0 then 1
  else if k = 16 then RowSoundness.flag (2 ≤ phase.val ∧ phase.val < 7 ∧ byte.val < 128)
  else RowSoundness.canonicalInputs phase ⟨0, by decide⟩ byte (inputIndex k)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem canonical_height_independent : ∀ (phase : Fin 8) (height : Fin 9) (byte : Fin 256) (k : Fin 22),
    k.val+1 ≠ 16 → canonical phase byte (k.val+1) =
      RowSoundness.canonicalInputs phase height byte (inputIndex (k.val+1)) := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem source_links : ∀ (i : Fin 121) (k : Fin 22), k.val+1 ≠ 16 →
    rowMap i (k.val+1) = substitute byteMap (rowWires (infoAt i) (inputIndex (k.val+1)+1)) ∧
    (rowWires (infoAt i) (inputIndex (k.val+1)+1)).all (fun term => term.1 < 6096) = true := by
  native_decide

theorem source_eval {F : Type} [CommRing F] (values : Nat → F) (linear : Linear)
    (bound : linear.all (fun term => term.1 < 6096) = true) :
    evalLinear values (substitute byteMap linear) = evalLinear (byteContext values).get linear := by
  rw [eval_substitute]
  apply ByteCompileComposition.eval_congr
  intro term member
  have small : term.1 < 6096 := of_decide_eq_true (List.all_eq_true.mp bound term member)
  exact (projection_value values byteMap 6096 (by decide) term.1 small).symm

theorem bridge_input_from_parser {F : Type} [CommRing F] (values : Nat → F)
    (i : Fin 121) (k : Fin 22) (notFinish : k.val+1 ≠ 16) :
    localValues values i (k.val+1) =
      (rowContext (byteContext values) (infoAt i)).get (inputIndex (k.val+1)) := by
  have links := source_links i k notFinish
  have small : inputIndex (k.val+1) < 35 := by
    unfold inputIndex
    split <;> (try split) <;> (try split) <;> omega
  rw [ByteCompileRow.localValues, links.1, source_eval values _ links.2,
    ← row_context_inputs (byteContext values) (infoAt i) (inputIndex (k.val+1)) small]
  rfl

theorem parser_inputs_normalized {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (i : Fin 121) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : ctx.get 0 = 1)
    (before : AtState ctx i.val (p, h))
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get (moduleByteIndex i)) = (b.val : F))
    (holds : Satisfied byteShape ctx.get) :
    ∀ k, k < 35 → (rowContext ctx (infoAt i)).get k = (RowSoundness.canonicalInputs p h b k : F) := by
  let rc := rowContext ctx (infoAt i)
  let lv := FullMatrix.localValues ctx (infoAt i)
  have localOne : lv 0 = 1 := by
    simp [lv, FullMatrix.localValues, rowWires, constant, evalLinear, interpretLinear, R1CS.eval,
      one, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  have localHolds := instantiated_row_holds ctx (infoAt i) (infoAt_member i) holds
  obtain ⟨equations, _, _⟩ := RowMatrix.matrix_row_implies_equations rc lv localOne
    (row_context_inputs ctx (infoAt i)) localHolds
  have encoding : inputState ctx (infoAt i) = encodedState p.val h.val := by
    simpa [AtState, i.isLt] using before
  have phases := encoding_phases ctx (infoAt i) p.val h.val encoding
  have depths := encoding_depths ctx (infoAt i) p.val h.val encoding
  have bitsBoolean : ∀ value ∈ InputNormalization.witnessBits rc.get, value*(value-1) = 0 := by
    simpa only [rc, row_bits_are_global] using global_bits_boolean ctx (moduleByteIndex i) one holds
  have bitsBinding : R1CS.weightedValues (BitPacking.bitWeights 8) (InputNormalization.witnessBits rc.get) = (b.val : F) := by
    simpa only [rc, row_bits_are_global] using binding
  have selectors := RowMatrix.matrix_selectors_boolean rc lv localOne (row_context_inputs ctx (infoAt i)) localHolds
  obtain ⟨selectorSum, selectorWeight⟩ := RowMatrix.field_selector_equations rc.get equations
  have ready : rc.get 0 = if p.val = 0 then 1 else 0 := by simpa [rc, eq_comm] using phases ⟨0, by decide⟩
  exact InputNormalization.constrained_inputs_normalize rc.get p h b phases depths bitsBoolean bitsBinding selectors
    (by simpa only [ready] using selectorSum)
    (by simpa only [ready, bitsBinding] using selectorWeight)

def finishGate : Gate := ⟨((List.range 5).map fun i => ByteCompileRow.wire (2+i)).flatten,
  sub (constant 1) (ByteCompileRow.wire 14), ByteCompileRow.wire 16⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem finish_gates : ∀ i : Fin 121,
    ByteCompileShape.shape.gates[1289+i.val*57+24]? = some (substituteGate (rowMap i) finishGate) := by
  native_decide

def finishSource (i : Fin 121) : Gate := byteShape.gates[1289+i.val*57+24]!

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem finish_sources : ∀ i : Fin 121,
    byteShape.gates[1289+i.val*57+24]? = some (finishSource i) ∧
      substituteGate byteMap (finishSource i) = substituteGate (rowMap i) finishGate := by
  native_decide

theorem byte_context_embeds {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied byteShape (byteContext values).get) :
    ∀ gate ∈ byteShape.gates.toList, R1CS.Holds values (interpretGate (substituteGate byteMap gate)) := by
  have projected : Satisfied byteShape (fun i => evalLinear values (byteMap i)) := by
    apply bounded_satisfied byteShape sources_bounded.1 (byteContext values).get _ _ holds
    intro i bound
    have size : byteShape.wires = 6096 := by native_decide
    exact projection_value values byteMap 6096 (by decide) i (by omega)
  intro gate member
  change evalLinear values (substitute byteMap gate.a) * evalLinear values (substitute byteMap gate.b) =
    evalLinear values (substitute byteMap gate.c)
  rw [eval_substitute, eval_substitute, eval_substitute]
  exact projected gate member

def finishExpr : RowSoundness.Expr :=
  RowSoundness.sumExpr ((List.range 5).map fun i => .input (2+i)) * (1 - .input 14)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem canonical_finish : ∀ (p : Fin 8) (b : Fin 256),
    RowSoundness.evalInt (canonical p b) finishExpr = canonical p b 16 := by native_decide

theorem finish_expression {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : R1CS.Holds values (interpretGate finishGate)) :
    values 16 = RowSoundness.evalField values finishExpr := by
  change evalLinear values (((List.range 5).map fun i => ByteCompileRow.wire (2+i)).flatten) *
    evalLinear values (sub (constant 1) (ByteCompileRow.wire 14)) =
    evalLinear values (ByteCompileRow.wire 16) at holds
  rw [ByteCompileRow.eval_sub, ByteCompileRow.eval_constant values one,
    ByteCompileRow.eval_wire, ByteCompileRow.eval_wire, Ring.intCast_one] at holds
  have sum : evalLinear values (((List.range 5).map fun i => ByteCompileRow.wire (2+i)).flatten) =
      values 2 + (values 3 + (values 4 + (values 5 + values 6))) := by
    simp [List.range_succ, ByteCompileRow.wire, evalLinear, interpretLinear, R1CS.eval,
      Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  rw [sum] at holds
  change values 16 = (values 2 + (values 3 + (values 4 + (values 5 + (values 6 + (0 : Int)))))) *
    ((1 : Int) - values 14)
  simpa only [Ring.intCast_zero, Ring.intCast_one, Semiring.add_zero] using holds.symm

theorem canonical_bridge_inputs_from_bytes {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (i : Fin 121) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : values 0 = 1) (before : AtState (byteContext values) i.val (p, h))
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get (moduleByteIndex i)) = (b.val : F))
    (holds : Satisfied byteShape (byteContext values).get) :
    ∀ k, k < 23 → localValues values i k = (canonical p b k : F) := by
  have normalized := parser_inputs_normalized (byteContext values) i p h b
    (projected_one values one).1 before binding holds
  have ordinary (k : Fin 22) (notFinish : k.val+1 ≠ 16) :
      localValues values i (k.val+1) = (canonical p b (k.val+1) : F) := by
    rw [bridge_input_from_parser values i k notFinish,
      canonical_height_independent p h b k notFinish]
    apply normalized
    unfold inputIndex
    split <;> (try split) <;> (try split) <;> omega
  have zero : localValues values i 0 = (canonical p b 0 : F) := by
    rw [ByteCompileRow.local_one values one i]
    simp [canonical, Ring.intCast_one]
  have first (k : Nat) (bound : k < 15) : localValues values i k = (canonical p b k : F) := by
    by_cases isZero : k = 0
    · simpa [isZero] using zero
    · have index : k-1+1 = k := by omega
      simpa only [index] using ordinary ⟨k-1, by omega⟩ (by change (k-1)+1 ≠ 16; omega)
  have finish : localValues values i 16 = (canonical p b 16 : F) := by
    have equation : R1CS.Holds (localValues values i) (interpretGate finishGate) := by
      apply gate_substitution_sound values (rowMap i) finishGate
      rw [← (finish_sources i).2]
      exact byte_context_embeds values holds (finishSource i)
        (by simpa using Array.mem_of_getElem? (finish_sources i).1)
    rw [finish_expression (localValues values i) (ByteCompileRow.local_one values one i) equation]
    rw [InputNormalization.eval_congr_below (localValues values i) (fun k => (canonical p b k : F)) 15 first finishExpr (by decide)]
    rw [RowSoundness.integer_interpretation_commutes, canonical_finish]
  intro k bound
  by_cases isZero : k = 0
  · simpa [isZero] using zero
  · by_cases isFinish : k = 16
    · simpa [isFinish] using finish
    · have index : k-1+1 = k := by omega
      simpa only [index] using ordinary ⟨k-1, by omega⟩ (by change (k-1)+1 ≠ 16; omega)

theorem canonical_bridge_inputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (i : Fin 121) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : values 0 = 1) (before : AtState (byteContext values) i.val (p, h))
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get (moduleByteIndex i)) = (b.val : F))
    (holds : Satisfied ByteCompileShape.shape values) :
    ∀ k, k < 23 → localValues values i k = (canonical p b k : F) :=
  canonical_bridge_inputs_from_bytes values i p h b one before binding (byte_context_satisfied values holds)

#print axioms canonical_bridge_inputs_from_bytes
#print axioms canonical_bridge_inputs

end ZkBuild.ByteCompileDecodeRow
