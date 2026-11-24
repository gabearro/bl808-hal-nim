import SlotRowCompleteness
import BodyCompleteness

/- Assemble the local constructive witnesses in disjoint private-wire ranges.
   The shared input depths are checked against the preceding row's outputs. -/
namespace ZkBuild.SlotWitness

open Lean.Grind CircuitShape SlotTrace
open FullMatrix (evalLinear)
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Actions := Fin 16 → Fin 10 × Word
abbrev Heights := Fin 17 → Fin 9

def before (heights : Heights) (i : Fin 16) : Fin 9 := heights ⟨i.val, by have := i.isLt; omega⟩
def after (heights : Heights) (i : Fin 16) : Fin 9 := heights ⟨i.val+1, by have := i.isLt; omega⟩

def ValidTrace (actions : Actions) (heights : Heights) : Prop :=
  (heights ⟨0, by decide⟩).val = 0 ∧ (heights ⟨16, by decide⟩).val = 1 ∧
    ∀ i : Fin 16, SlotShape.valid (actions i).1.val (before heights i).val = true ∧
      (after heights i).val = SlotShape.nextDepth (actions i).1.val (before heights i).val

def localWitness (actions : Actions) (heights : Heights) (i : Fin 16) : List Int :=
  SlotRowCompleteness.canonicalRowWitness (actions i).1 (before heights i) (actions i).2

def witnessValue {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 16) (wire : Nat) : F :=
  ((localWitness actions heights i)[wire]?.getD 0 : F)

def moduleValues {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (wire : Nat) : F :=
  if wire = 0 then 1
  else if input : wire < 11 then inputs ⟨wire-1, by omega⟩
  else if auxiliary : wire < 11899 then
    let i : Fin 16 := ⟨(wire-11)/743, by omega⟩
    witnessValue actions heights i (10+(wire-11)%743)
  else 0

def rowCache (actions : Actions) (heights : Heights) : Array (List Int) :=
  Array.ofFn (fun i : Fin 16 => localWitness actions heights i)

def cachedValues {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (rows : Array (List Int)) (wire : Nat) : F :=
  if wire = 0 then 1
  else if input : wire < 11 then inputs ⟨wire-1, by omega⟩
  else if wire < 11899 then
    (((rows[(wire-11)/743]?.getD [])[10+(wire-11)%743]?.getD 0 : Int) : F)
  else 0

theorem cached_values_eq {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (wire : Nat) :
    cachedValues inputs (rowCache actions heights) wire = moduleValues inputs actions heights wire := by
  by_cases zero : wire = 0
  · simp only [cachedValues, moduleValues, zero, ite_true]
  · by_cases input : wire < 11
    · simp only [cachedValues, moduleValues, zero, ite_false, input, dite_true]
    · by_cases auxiliary : wire < 11899
      · have rowBound : (wire-11)/743 < 16 := by omega
        simp only [cachedValues, moduleValues, zero, ite_false, input, dite_false,
          auxiliary, dite_true, rowCache, Array.getElem?_ofFn, rowBound, dite_true,
          Option.getD_some, witnessValue, ite_true]
      · simp only [cachedValues, moduleValues, zero, ite_false, input, dite_false,
          auxiliary, dite_false]

noncomputable def moduleContext {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 11899 => moduleValues inputs actions heights i.val) (by decide)

theorem module_entry {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Nat) (bound : i < 11899) :
    (moduleContext inputs actions heights).get i = moduleValues inputs actions heights i :=
  Lean.RArray.get_ofFn (fun j : Fin 11899 => moduleValues inputs actions heights j.val) (by decide) ⟨i, bound⟩

theorem module_one {F : Type} [CommRing F] (inputs : Fin 10 → F) (actions : Actions) (heights : Heights) :
    (moduleContext inputs actions heights).get 0 = 1 := by
  rw [module_entry inputs actions heights 0 (by decide)]
  rfl

theorem module_public {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Fin 10) :
    (moduleContext inputs actions heights).get (1+i.val) = inputs i := by
  have bound : 1+i.val < 11 := by have := i.isLt; omega
  rw [module_entry inputs actions heights (1+i.val) (by omega)]
  simp [moduleValues, bound]

theorem module_auxiliary {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Fin 16) (j : Fin 743) :
    (moduleContext inputs actions heights).get (11+i.val*743+j.val) =
      witnessValue actions heights i (10+j.val) := by
  have hi := i.isLt
  have hj := j.isLt
  have nonzero : 11+i.val*743+j.val ≠ 0 := by omega
  have notInput : ¬11+i.val*743+j.val < 11 := by omega
  have bound : 11+i.val*743+j.val < 11899 := by omega
  have quotient : (11+i.val*743+j.val-11)/743 = i.val := by omega
  have remainder : (11+i.val*743+j.val-11)%743 = j.val := by omega
  rw [module_entry inputs actions heights _ bound]
  simp only [moduleValues, nonzero, ite_false, notInput, dite_false, bound, dite_true, quotient, remainder]

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem row_auxiliary_wires : ∀ (i : Fin 16) (j : Fin 743),
    SlotMatrix.rowWires (infoAt i) (10+j.val) = [(11+i.val*743+j.val, 1)] := by native_decide

theorem local_values_match {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Fin 16)
    (valid : SlotShape.valid (actions i).1.val (before heights i).val = true)
    (encoding : inputDepths (moduleContext inputs actions heights) (infoAt i) = depthVector (before heights i).val) :
    ∀ wire, wire < 753 → SlotMatrix.localValues (moduleContext inputs actions heights) (infoAt i) wire =
      witnessValue actions heights i wire := by
  have canonical := SlotRowCompleteness.canonical_row_holds (F := F) (actions i).1 (before heights i) (actions i).2 valid
  intro wire bound
  by_cases zero : wire = 0
  · subst wire
    have one : witnessValue (F := F) actions heights i 0 = 1 := canonical.1
    rw [one]
    simp [SlotMatrix.localValues, SlotMatrix.rowWires, constant, evalLinear, interpretLinear, R1CS.eval,
      module_one, Ring.intCast_one, Semiring.mul_one, Semiring.add_zero]
  · by_cases input : wire < 10
    · have indexBound : wire-1 < 9 := by omega
      have source : SlotRow.sourceWire (wire-1) = wire := by
        simp only [SlotRow.sourceWire, show wire-1 < 51 by omega, ite_true]
        omega
      have global := encoded_input (moduleContext inputs actions heights) (infoAt i)
        (SlotMatrix.instance_checked _ (info_member i)).1 (before heights i).val encoding (wire-1) indexBound
      rw [← SlotMatrix.context_sources _ _ (wire-1) (by omega), source] at global
      have canonicalInput := canonical.2.1 (wire-1) (by omega)
      rw [source, SlotRowCompleteness.prior_values _ _ _ (wire-1) indexBound] at canonicalInput
      exact global.trans canonicalInput.symm
    · let j : Fin 743 := ⟨wire-10, by omega⟩
      have same : 10+j.val = wire := by dsimp [j]; omega
      rw [SlotMatrix.localValues, ← same, row_auxiliary_wires]
      simp only [evalLinear, interpretLinear, R1CS.eval, List.map_cons, List.map_nil,
        Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
      rw [module_auxiliary, same]

theorem template_wires_bounded :
    SlotRow.rowBuild.2.gates.toList.all (BodyCompleteness.gateBounded 753) = true := by native_decide

theorem local_row_holds {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Fin 16)
    (valid : SlotShape.valid (actions i).1.val (before heights i).val = true)
    (encoding : inputDepths (moduleContext inputs actions heights) (infoAt i) = depthVector (before heights i).val) :
    Satisfied SlotRow.rowBuild.2 (SlotMatrix.localValues (moduleContext inputs actions heights) (infoAt i)) := by
  have canonical := SlotRowCompleteness.canonical_row_holds (F := F) (actions i).1 (before heights i) (actions i).2 valid
  intro gate member
  have bounded := List.all_eq_true.mp template_wires_bounded gate member
  have sides : gate.a.all (fun t => t.1 < 753) = true ∧
      gate.b.all (fun t => t.1 < 753) = true ∧ gate.c.all (fun t => t.1 < 753) = true := by
    simpa [BodyCompleteness.gateBounded, List.all_append, and_assoc] using bounded
  change evalLinear _ gate.a * evalLinear _ gate.b = evalLinear _ gate.c
  rw [BodyCompleteness.eval_linear_congr _ (witnessValue actions heights i) 753
      (local_values_match inputs actions heights i valid encoding) gate.a sides.1,
    BodyCompleteness.eval_linear_congr _ (witnessValue actions heights i) 753
      (local_values_match inputs actions heights i valid encoding) gate.b sides.2.1,
    BodyCompleteness.eval_linear_congr _ (witnessValue actions heights i) 753
      (local_values_match inputs actions heights i valid encoding) gate.c sides.2.2]
  exact canonical.2.2 gate member

theorem constructed_row_output {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (i : Fin 16)
    (valid : SlotShape.valid (actions i).1.val (before heights i).val = true)
    (encoding : inputDepths (moduleContext inputs actions heights) (infoAt i) = depthVector (before heights i).val) :
    outputDepths (moduleContext inputs actions heights) (infoAt i) =
      depthVector (SlotShape.nextDepth (actions i).1.val (before heights i).val) := by
  let ctx := moduleContext inputs actions heights
  let canonicalCtx : Lean.RArray F := SlotRowCompleteness.context (actions i).1 (before heights i) (actions i).2
  have canonical := SlotRowCompleteness.canonical_row_holds (F := F) (actions i).1 (before heights i) (actions i).2 valid
  have equations := SlotRow.matrix_implies_equations canonicalCtx (witnessValue actions heights i)
    canonical.1 canonical.2.1 canonical.2.2
  have combined : (infoAt i).outputs.toList.map (evalLinear ctx.get) = SlotRow.outputs.map (RowSoundness.evalField canonicalCtx.get) := by
    rw [← SlotMatrix.row_outputs ctx (infoAt i) (info_member i)]
    calc
      SlotRow.outputLinears.map (evalLinear (SlotMatrix.localValues ctx (infoAt i))) =
          SlotRow.outputLinears.map (evalLinear (witnessValue actions heights i)) := by
        apply List.map_congr_left
        intro linear member
        exact BodyCompleteness.eval_linear_congr _ _ 753 (local_values_match inputs actions heights i valid encoding)
          linear (List.all_eq_true.mp SlotRow.outputs_bounded linear member)
      _ = _ := equations.2
  have taken := congrArg (List.take 9) combined
  have count : (SlotRow.nextDepths.map (RowSoundness.evalField canonicalCtx.get)).length = 9 := by simp [SlotRow.nextDepths]
  have depthEq : outputDepths ctx (infoAt i) = SlotRow.nextDepths.map (RowSoundness.evalField canonicalCtx.get) := by
    simpa only [outputDepths, List.map_take, SlotRow.outputs, List.map_append, List.append_assoc,
      List.take_append_of_le_length (show 9 ≤ (SlotRow.nextDepths.map (RowSoundness.evalField canonicalCtx.get)).length by omega),
      List.take_of_length_le (show (SlotRow.nextDepths.map (RowSoundness.evalField canonicalCtx.get)).length ≤ 9 by omega)] using taken
  rw [depthEq, SlotRow.depths_determined canonicalCtx (actions i).1 (before heights i)
    (SlotRowCompleteness.prior_values _ _ _) (SlotRowCompleteness.selected_values _ _ _), depth_encoding _ _ valid]

def EmbeddedSatisfied {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 16) : Prop :=
  ∀ j : Fin 746, ∀ actual, SlotShape.compileShape.gates[(infoAt i).gateStart+j.val]? = some actual →
    R1CS.Holds ctx.get (interpretGate actual)

theorem embedded_row_holds {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 16)
    (localHolds : Satisfied SlotRow.rowBuild.2 (SlotMatrix.localValues ctx (infoAt i))) : EmbeddedSatisfied ctx i := by
  intro j actual found
  have bound : j.val < SlotRow.rowBuild.2.gates.size := by rw [SlotMatrix.template_sizes.1]; exact j.isLt
  let template := SlotRow.rowBuild.2.gates[j.val]
  have templateFound : SlotRow.rowBuild.2.gates[j.val]? = some template := Array.getElem?_eq_getElem bound
  have checked := List.all_eq_true.mp (SlotMatrix.instance_checked _ (info_member i)).2.2.1 j.val (List.mem_range.mpr j.isLt)
  unfold SlotMatrix.gateChecks at checked
  rw [templateFound, found] at checked
  apply BodyCompleteness.same_gate_complete ctx (FullMatrix.substituteGate (SlotMatrix.rowWires (infoAt i)) template) actual checked
  apply BodyCompleteness.gate_substitution_complete
  exact localHolds template (Array.getElem_mem_toList bound)

theorem constructed_all_rows {F : Type} [CommRing F] (inputs : Fin 10 → F)
    (actions : Actions) (heights : Heights) (trace : ValidTrace actions heights) :
    (∀ i : Fin 16, EmbeddedSatisfied (moduleContext inputs actions heights) i) ∧
      outputDepths (moduleContext inputs actions heights) (infoAt ⟨15, by decide⟩) = depthVector 1 ∧
      (∀ i : Fin 16, inputDepths (moduleContext inputs actions heights) (infoAt i) = depthVector (before heights i).val) := by
  have incoming : ∀ index (bound : index < 16), inputDepths (moduleContext inputs actions heights) (infoAt ⟨index, bound⟩) =
      depthVector (before heights ⟨index, bound⟩).val := by
    intro index
    induction index with
    | zero =>
      intro bound
      simpa only [before, trace.1] using initial_depth (moduleContext inputs actions heights) (module_one inputs actions heights)
    | succ index ih =>
      intro bound
      have prev : index < 16 := by omega
      have output := constructed_row_output inputs actions heights ⟨index, prev⟩ (trace.2.2 _).1 (ih prev)
      rw [← (trace.2.2 ⟨index, prev⟩).2] at output
      have adjacent : inputDepths (moduleContext inputs actions heights) (infoAt ⟨index+1, bound⟩) =
          outputDepths (moduleContext inputs actions heights) (infoAt ⟨index, prev⟩) := by
        unfold inputDepths outputDepths
        rw [adjacent_inputs ⟨index, by omega⟩]
      exact adjacent.trans output
  refine ⟨?_, ?_, fun i => incoming i.val i.isLt⟩
  · intro i
    apply embedded_row_holds
    exact local_row_holds inputs actions heights i (trace.2.2 i).1 (incoming i.val i.isLt)
  · have last := constructed_row_output inputs actions heights ⟨15, by decide⟩ (trace.2.2 _).1 (incoming 15 (by decide))
    rw [← (trace.2.2 ⟨15, by decide⟩).2] at last
    simpa only [after, trace.2.1] using last

#print axioms constructed_all_rows

end ZkBuild.SlotWitness
