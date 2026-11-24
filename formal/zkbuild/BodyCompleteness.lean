import RowCompleteness
import BodySoundness

/- One assignment for all rows: fixed byte bits followed by each row's 40
   selector/product wires. No per-row witnesses are allowed to disagree about
   the shared state expressions or the byte inputs. -/
namespace ZkBuild.BodyCompleteness

open Lean.Grind CircuitShape FullMatrix BodySoundness RowMatrix RowCompleteness
attribute [local instance] Ring.intCast Semiring.natCast

abbrev States := Fin 122 → ByteStream.State

def before (states : States) (i : Fin 121) : ByteStream.State :=
  states ⟨i.val, by have := i.isLt; omega⟩

def after (states : States) (i : Fin 121) : ByteStream.State :=
  states ⟨i.val+1, by have := i.isLt; omega⟩

def localWitness (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121) : List Int :=
  canonicalRowWitness (before states i).1 (before states i).2 (bytes (moduleByteIndex i))

def moduleValues {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (wire : Nat) : F :=
  if zero : wire = 0 then 1
  else if input : wire < 8 then inputs ⟨wire-1, by omega⟩
  else if bits : wire < 1256 then
    let position : Fin 156 := ⟨(wire-8)/8, by omega⟩
    (RowSoundness.flag (((bytes position).val / 2^((wire-8)%8)) % 2 = 1) : F)
  else if auxiliary : wire < 6096 then
    let i : Fin 121 := ⟨(wire-1256)/40, by omega⟩
    ((localWitness bytes states i)[26+(wire-1256)%40]?.getD 0 : F)
  else 0

noncomputable def moduleContext {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 6096 => moduleValues inputs bytes states i.val) (by decide)

theorem module_context_entry {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Nat) (bound : i < 6096) :
    (moduleContext inputs bytes states).get i = moduleValues inputs bytes states i :=
  Lean.RArray.get_ofFn (fun j : Fin 6096 => moduleValues inputs bytes states j.val) (by decide) ⟨i, bound⟩

theorem module_one {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) :
    (moduleContext inputs bytes states).get 0 = 1 := by
  rw [module_context_entry inputs bytes states 0 (by decide)]
  simp [moduleValues]

theorem module_public {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 7) :
    (moduleContext inputs bytes states).get (1+i.val) = inputs i := by
  have bound : 1+i.val < 8 := by have := i.isLt; omega
  rw [module_context_entry inputs bytes states (1+i.val) (by omega)]
  simp [moduleValues, bound]

theorem module_bit {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (position : Fin 156) (bit : Fin 8) :
    (moduleContext inputs bytes states).get (8+position.val*8+bit.val) =
      (RowSoundness.flag (((bytes position).val / 2^bit.val) % 2 = 1) : F) := by
  have p := position.isLt
  have b := bit.isLt
  have nonzero : 8+position.val*8+bit.val ≠ 0 := by omega
  have notInput : ¬8+position.val*8+bit.val < 8 := by omega
  have bound : 8+position.val*8+bit.val < 1256 := by omega
  have quotient : (8+position.val*8+bit.val-8)/8 = position.val := by omega
  have remainder : (8+position.val*8+bit.val-8)%8 = bit.val := by omega
  rw [module_context_entry inputs bytes states (8+position.val*8+bit.val) (by omega)]
  simp only [moduleValues, dite_eq_right nonzero, dite_eq_right notInput, dite_eq_left bound, quotient, remainder]

theorem module_auxiliary {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121) (j : Fin 40) :
    (moduleContext inputs bytes states).get (1256+i.val*40+j.val) =
      ((localWitness bytes states i)[26+j.val]?.getD 0 : F) := by
  have hi := i.isLt
  have hj := j.isLt
  have nonzero : 1256+i.val*40+j.val ≠ 0 := by omega
  have notInput : ¬1256+i.val*40+j.val < 8 := by omega
  have notBit : ¬1256+i.val*40+j.val < 1256 := by omega
  have bound : 1256+i.val*40+j.val < 6096 := by omega
  have quotient : (1256+i.val*40+j.val-1256)/40 = i.val := by omega
  have remainder : (1256+i.val*40+j.val-1256)%40 = j.val := by omega
  rw [module_context_entry inputs bytes states (1256+i.val*40+j.val) bound]
  simp only [moduleValues, dite_eq_right nonzero, dite_eq_right notInput, dite_eq_right notBit,
    dite_eq_left bound, quotient, remainder]

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem row_auxiliary_wires : ∀ (i : Fin 121) (j : Fin 40),
    rowWires (infoAt i) (26+j.val) = [(1256+i.val*40+j.val, 1)] := by native_decide

theorem module_byte_bits {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (position : Fin 156) :
    globalBits (moduleContext inputs bytes states).get position =
      (InputNormalization.byteBits (bytes position)).map R1CS.boolValue := by
  simp only [globalBits, InputNormalization.byteBits, List.map_ofFn]
  apply congrArg List.ofFn
  funext bit
  rw [module_bit]
  simp only [Function.comp_def, R1CS.boolValue, decide_eq_true_eq, InputNormalization.cast_flag]

theorem local_input_encoding {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121)
    (encoding : inputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (before states i).1.val (before states i).2.val) :
    ∀ k, k < 25 → (rowContext (moduleContext inputs bytes states) (infoAt i)).get k =
      (RowSoundness.canonicalInputs (before states i).1 (before states i).2
        (bytes (moduleByteIndex i)) k : F) := by
  intro k bound
  by_cases phase : k < 8
  · have value := encoding_phases (moduleContext inputs bytes states) (infoAt i) _ _ encoding ⟨k, phase⟩
    simpa only [RowSoundness.canonicalInputs, ite_eq_left phase, InputNormalization.cast_flag] using value
  · by_cases depth : k < 17
    · have index : k-8 < 9 := by omega
      have value := encoding_depths (moduleContext inputs bytes states) (infoAt i) _ _ encoding ⟨k-8, index⟩
      have add : 8+(k-8) = k := by omega
      simpa only [add, RowSoundness.canonicalInputs, ite_eq_right phase, ite_eq_left depth,
        InputNormalization.cast_flag] using value
    · have index : k-17 < 8 := by omega
      have add : 17+(k-17) = k := by omega
      have bits := row_bits_are_global (moduleContext inputs bytes states) i
      rw [module_byte_bits] at bits
      have value := congrArg (fun xs : List F => (xs[k-17]?).getD 0) bits
      simp only [InputNormalization.witnessBits, InputNormalization.byteBits, List.map_ofFn,
        List.getElem?_ofFn, dite_eq_left index, Option.getD_some] at value
      simpa only [add, Function.comp_def, R1CS.boolValue, decide_eq_true_eq,
        RowSoundness.canonicalInputs, ite_eq_right phase, ite_eq_right depth, ite_eq_left bound,
        InputNormalization.cast_flag] using value

def witnessValue {F : Type} [CommRing F] (bytes : Fin 156 → Fin 256)
    (states : States) (i : Fin 121) (wire : Nat) : F :=
  ((localWitness bytes states i)[wire]?.getD 0 : F)

theorem local_values_match {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121)
    (accepted : ByteStream.referenceRow (before states i).1.val (before states i).2.val
      (bytes (moduleByteIndex i)).val = some ((after states i).1.val, (after states i).2.val))
    (encoding : inputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (before states i).1.val (before states i).2.val) :
    ∀ wire, wire < 66 → localValues (moduleContext inputs bytes states) (infoAt i) wire =
      witnessValue bytes states i wire := by
  have canonical := canonical_row_witness_holds (F := F) (before states i).1 (before states i).2
    (bytes (moduleByteIndex i)) (after states i).1.val (after states i).2.val accepted
  intro wire bound
  by_cases zero : wire = 0
  · subst wire
    have one : witnessValue (F := F) bytes states i 0 = 1 := canonical.1
    rw [one]
    simp [localValues, rowWires, constant, evalLinear, interpretLinear, R1CS.eval,
      module_one, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  · by_cases input : wire < 26
    · have below : wire-1 < 25 := by omega
      have add : wire-1+1 = wire := by omega
      have slot := row_context_inputs (moduleContext inputs bytes states) (infoAt i) (wire-1) (by omega)
      rw [add] at slot
      rw [slot, local_input_encoding inputs bytes states i encoding (wire-1) below]
      have exactInput := canonical.2.1 (wire-1) (by omega)
      simpa [witnessValue, localWitness, add] using exactInput.symm
    · have auxBound : wire-26 < 40 := by omega
      let j : Fin 40 := ⟨wire-26, auxBound⟩
      have add : 26+j.val = wire := by dsimp [j]; omega
      have wires : rowWires (infoAt i) wire = [(1256+i.val*40+j.val, 1)] := by
        rw [← add, row_auxiliary_wires]
      simp only [localValues, wires, evalLinear, interpretLinear, R1CS.eval,
        List.map_cons, List.map_nil, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
      rw [module_auxiliary]
      simp only [witnessValue, add]

theorem eval_linear_congr {F : Type} [CommRing F] (a b : Nat → F) (bound : Nat)
    (agree : ∀ i, i < bound → a i = b i) (linear : Linear)
    (bounded : linear.all (fun term => term.1 < bound) = true) :
    evalLinear a linear = evalLinear b linear := by
  induction linear with
  | nil => rfl
  | cons term rest ih =>
    have bounds : term.1 < bound ∧ rest.all (fun term => term.1 < bound) = true := by
      simpa using bounded
    simp only [evalLinear, interpretLinear, R1CS.eval, List.map_cons]
    rw [agree term.1 bounds.1]
    exact congrArg (fun tail => (term.2 : F) * b term.1 + tail) (ih bounds.2)

def gateBounded (bound : Nat) (gate : Gate) : Bool :=
  (gate.a ++ gate.b ++ gate.c).all (fun term => term.1 < bound)

theorem template_wires_bounded : rowBuild.2.gates.toList.all (gateBounded 66) = true := by
  native_decide

theorem local_row_holds {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121)
    (accepted : ByteStream.referenceRow (before states i).1.val (before states i).2.val
      (bytes (moduleByteIndex i)).val = some ((after states i).1.val, (after states i).2.val))
    (encoding : inputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (before states i).1.val (before states i).2.val) :
    ∀ gate ∈ rowBuild.2.gates.toList,
      R1CS.Holds (localValues (moduleContext inputs bytes states) (infoAt i)) (interpretGate gate) := by
  have canonical := canonical_row_witness_holds (F := F) (before states i).1 (before states i).2
    (bytes (moduleByteIndex i)) (after states i).1.val (after states i).2.val accepted
  intro gate member
  have bounded := List.all_eq_true.mp template_wires_bounded gate member
  have sides : gate.a.all (fun t => t.1 < 66) = true ∧
      gate.b.all (fun t => t.1 < 66) = true ∧ gate.c.all (fun t => t.1 < 66) = true := by
    simpa [gateBounded, List.all_append, and_assoc] using bounded
  change evalLinear _ gate.a * evalLinear _ gate.b = evalLinear _ gate.c
  rw [eval_linear_congr _ (witnessValue bytes states i) 66
    (local_values_match inputs bytes states i accepted encoding) gate.a sides.1,
    eval_linear_congr _ (witnessValue bytes states i) 66
    (local_values_match inputs bytes states i accepted encoding) gate.b sides.2.1,
    eval_linear_congr _ (witnessValue bytes states i) 66
    (local_values_match inputs bytes states i accepted encoding) gate.c sides.2.2]
  exact canonical.2.2 gate member

theorem same_gate_complete {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : Gate) (same : sameGate a b = true)
    (holds : R1CS.Holds ctx.get (interpretGate a)) : R1CS.Holds ctx.get (interpretGate b) := by
  have sides : sameLinear a.a b.a = true ∧ sameLinear a.b b.b = true ∧ sameLinear a.c b.c = true := by
    simpa [sameGate, Bool.and_eq_true_iff, and_assoc] using same
  change evalLinear ctx.get b.a * evalLinear ctx.get b.b = evalLinear ctx.get b.c
  rw [← same_linear_sound ctx _ _ sides.1, ← same_linear_sound ctx _ _ sides.2.1,
    ← same_linear_sound ctx _ _ sides.2.2]
  exact holds

theorem gate_substitution_complete {F : Type} [CommRing F] (values : Nat → F)
    (wires : Nat → Linear) (gate : Gate)
    (holds : R1CS.Holds (fun i => evalLinear values (wires i)) (interpretGate gate)) :
    R1CS.Holds values (interpretGate (substituteGate wires gate)) := by
  change evalLinear values (substitute wires gate.a) * evalLinear values (substitute wires gate.b) =
    evalLinear values (substitute wires gate.c)
  rw [eval_substitute, eval_substitute, eval_substitute]
  exact holds

def EmbeddedSatisfied {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 121) : Prop :=
  ∀ j : Fin 57, ∀ actual, byteShape.gates[(infoAt i).gateStart+j.val]? = some actual →
    R1CS.Holds ctx.get (interpretGate actual)

theorem embedded_row_holds {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 121)
    (localHolds : ∀ gate ∈ rowBuild.2.gates.toList,
      R1CS.Holds (localValues ctx (infoAt i)) (interpretGate gate)) : EmbeddedSatisfied ctx i := by
  intro j actual found
  have bound : j.val < rowBuild.2.gates.size := by simp [template_gate_count]
  let template := rowBuild.2.gates[j.val]
  have templateFound : rowBuild.2.gates[j.val]? = some template := Array.getElem?_eq_getElem bound
  have check := List.all_eq_true.mp (row_instance_checked _ (infoAt_member i)).2.2.1 j.val (List.mem_range.mpr j.isLt)
  simp only [templateFound, found] at check
  apply same_gate_complete ctx (substituteGate (rowWires (infoAt i)) template) actual check
  apply gate_substitution_complete
  exact localHolds template (Array.getElem_mem_toList bound)

theorem constructed_row_output {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 121)
    (accepted : ByteStream.referenceRow (before states i).1.val (before states i).2.val
      (bytes (moduleByteIndex i)).val = some ((after states i).1.val, (after states i).2.val))
    (encoding : inputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (before states i).1.val (before states i).2.val) :
    outputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (after states i).1.val (after states i).2.val := by
  let ctx := moduleContext inputs bytes states
  have localHolds := local_row_holds inputs bytes states i accepted encoding
  have canonical := canonical_row_witness_holds (F := F) (before states i).1 (before states i).2
    (bytes (moduleByteIndex i)) (after states i).1.val (after states i).2.val accepted
  have one : localValues ctx (infoAt i) 0 = 1 := by
    rw [local_values_match inputs bytes states i accepted encoding 0 (by decide)]
    exact canonical.1
  have inputEq : ∀ k, k < 35 → localValues ctx (infoAt i) (k+1) =
      (canonicalContext (before states i).1 (before states i).2 (bytes (moduleByteIndex i))).get k := by
    intro k bound
    rw [local_values_match inputs bytes states i accepted encoding (k+1) (by omega),
      canonical_context_inputs _ _ _ k bound]
    exact canonical.2.1 k bound
  obtain ⟨_, phases, depths⟩ := RowMatrix.matrix_row_implies_equations
    (canonicalContext (before states i).1 (before states i).2 (bytes (moduleByteIndex i)))
    (localValues ctx (infoAt i)) one inputEq localHolds
  obtain ⟨nextPhases, nextDepths⟩ := canonical_context_outputs (F := F) (before states i).1 (before states i).2
    (bytes (moduleByteIndex i)) (after states i).1.val (after states i).2.val accepted
  rw [nextPhases] at phases
  rw [nextDepths] at depths
  have combined : templateOutputs.map (fun linear => evalLinear (localValues ctx (infoAt i)) linear) =
      encodedState (after states i).1.val (after states i).2.val := by
    simp only [templateOutputs, List.map_append, encodedState, evalLinear]
    rw [phases, depths]
  exact (instantiated_outputs ctx (infoAt i) (infoAt_member i)).symm.trans combined

def ValidTrace (bytes : Fin 156 → Fin 256) (states : States) : Prop :=
  states ⟨0, by decide⟩ = (⟨0, by decide⟩, ⟨0, by decide⟩) ∧
  ∀ i : Fin 121, ByteStream.referenceRow (before states i).1.val (before states i).2.val
    (bytes (moduleByteIndex i)).val = some ((after states i).1.val, (after states i).2.val)

theorem constructed_all_rows {F : Type} [CommRing F] (inputs : Fin 7 → F)
    (bytes : Fin 156 → Fin 256) (states : States) (trace : ValidTrace bytes states) :
    (∀ i : Fin 121, EmbeddedSatisfied (moduleContext inputs bytes states) i) ∧
    outputState (moduleContext inputs bytes states) (infoAt ⟨120, by decide⟩) =
      encodedState (states ⟨121, by decide⟩).1.val (states ⟨121, by decide⟩).2.val ∧
    (∀ i : Fin 121, inputState (moduleContext inputs bytes states) (infoAt i) =
      encodedState (before states i).1.val (before states i).2.val) := by
  have incoming : ∀ index (bound : index < 121),
      inputState (moduleContext inputs bytes states) (infoAt ⟨index, bound⟩) =
        encodedState (before states ⟨index, bound⟩).1.val (before states ⟨index, bound⟩).2.val := by
    intro index
    induction index with
    | zero =>
      intro bound
      change _ = encodedState (states ⟨0, by decide⟩).1.val (states ⟨0, by decide⟩).2.val
      rw [trace.1]
      exact initial_state (moduleContext inputs bytes states) (module_one inputs bytes states)
    | succ index ih =>
      intro bound
      have prevBound : index < 121 := by omega
      have out := constructed_row_output inputs bytes states ⟨index, prevBound⟩ (trace.2 _) (ih prevBound)
      have adjacent := adjacent_states (moduleContext inputs bytes states) ⟨index, by omega⟩
      exact adjacent.trans out
  refine ⟨?_, ?_, fun i => incoming i.val i.isLt⟩
  · intro i
    apply embedded_row_holds
    exact local_row_holds inputs bytes states i (trace.2 i) (incoming i.val i.isLt)
  · exact constructed_row_output inputs bytes states ⟨120, by decide⟩
      (trace.2 _) (incoming 120 (by decide))

#print axioms constructed_all_rows

end ZkBuild.BodyCompleteness
