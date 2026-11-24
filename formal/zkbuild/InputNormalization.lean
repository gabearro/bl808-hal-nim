import RowSoundness

namespace ZkBuild.InputNormalization

open Lean.Grind R1CS RowSoundness
attribute [local instance] Ring.intCast Semiring.natCast

def byteBits (b : Fin 256) : List Bool :=
  List.ofFn fun i : Fin 8 => decide ((b.val / 2^i.val) % 2 = 1)

def opcodeCodes : List Nat := List.ofFn fun i : Fin 10 => ByteStream.opcode i.val

def witnessBits {F : Type} (values : Nat → F) : List F :=
  List.ofFn fun i : Fin 8 => values (17+i.val)

def witnessSelectors {F : Type} (values : Nat → F) : List F :=
  List.ofFn fun i : Fin 10 => values (25+i.val)

theorem opcode_codes_unique : opcodeCodes.Nodup := by decide
theorem opcode_codes_small : ∀ code ∈ opcodeCodes, code < 256 := by decide

set_option maxRecDepth 100000 in
theorem canonical_byte_value : ∀ b : Fin 256,
    BitPacking.packBits (byteBits b) = b.val := by native_decide

theorem canonical_byte_field_value {F : Type} [CommRing F] (b : Fin 256) :
    weightedValues (BitPacking.bitWeights 8) ((byteBits b).map (boolValue (F := F))) = (b.val : F) := by
  rw [weighted_booleans]
  have length : (byteBits b).length = 8 := by simp [byteBits]
  rw [← length, BitPacking.binary_weights_encode_bits, canonical_byte_value]

theorem canonical_byte_boolean {F : Type} [Field F] (b : Fin 256) :
    ∀ value ∈ (byteBits b).map (boolValue (F := F)), value * (value - 1) = 0 := by
  intro value member
  obtain ⟨bit, _, rfl⟩ := List.mem_map.mp member
  cases bit <;> simp [boolValue] <;> grind

theorem witness_bits_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (b : Fin 256)
    (boolean : ∀ value ∈ witnessBits values, value * (value - 1) = 0)
    (binding : weightedValues (BitPacking.bitWeights 8) (witnessBits values) = (b.val : F)) :
    witnessBits values = (byteBits b).map boolValue := by
  apply BitPacking.byte_decomposition_unique (witnessBits values) ((byteBits b).map boolValue)
    (by simp [witnessBits]) (by simp [byteBits]) boolean (canonical_byte_boolean b)
  rw [canonical_byte_field_value, binding]

def canonicalSelectors (p : Fin 8) (b : Fin 256) : List Bool :=
  List.ofFn fun i : Fin 10 => decide (p.val = 0 ∧ b.val = ByteStream.opcode i.val)

theorem witness_selectors_determined {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (p : Fin 8) (b : Fin 256)
    (boolean : ∀ value ∈ witnessSelectors values, value * (value - 1) = 0)
    (total : sum (witnessSelectors values) = if p.val = 0 then 1 else 0)
    (binding : weightedValues opcodeCodes (witnessSelectors values) =
      (if p.val = 0 then 1 else 0) * (b.val : F)) :
    witnessSelectors values = (canonicalSelectors p b).map boolValue := by
  by_cases isReady : p.val = 0
  · have result := opcode_selectors_determined (witnessSelectors values) opcodeCodes b
      (by simp [opcodeCodes, witnessSelectors]) (by simp [witnessSelectors])
      opcode_codes_unique opcode_codes_small boolean
      (by simpa [isReady] using total) (by simpa [isReady, Semiring.one_mul] using binding)
    simpa [opcodeCodes, canonicalSelectors, List.map_ofFn, isReady, eq_comm] using result
  · have result := zero_sum_selectors_determined (witnessSelectors values)
      (by simp [witnessSelectors]) boolean (by simpa [isReady] using total)
    simpa [witnessSelectors, canonicalSelectors, isReady, List.map_ofFn, boolValue] using result

def UsesBelow (bound : Nat) : Expr → Bool
  | .literal _ => true
  | .input i => i < bound
  | .add a b | .sub a b | .mul a b => UsesBelow bound a && UsesBelow bound b

theorem eval_congr_below {F : Type} [CommRing F] (a b : Nat → F) (bound : Nat)
    (agree : ∀ i, i < bound → a i = b i) (e : Expr) (uses : UsesBelow bound e = true) :
    evalField a e = evalField b e := by
  induction e with
  | literal n => rfl
  | input i => exact agree i (by simpa [UsesBelow] using uses)
  | add a b ia ib =>
    have both : UsesBelow bound a = true ∧ UsesBelow bound b = true := by simpa [UsesBelow] using uses
    simp only [evalField, ia both.1, ib both.2]
  | sub a b ia ib =>
    have both : UsesBelow bound a = true ∧ UsesBelow bound b = true := by simpa [UsesBelow] using uses
    simp only [evalField, ia both.1, ib both.2]
  | mul a b ia ib =>
    have both : UsesBelow bound a = true ∧ UsesBelow bound b = true := by simpa [UsesBelow] using uses
    simp only [evalField, ia both.1, ib both.2]

theorem row_uses_only_inputs :
    (row.residuals ++ row.nextPhases ++ row.nextDepths).all (UsesBelow 35) = true := by decide

theorem cast_flag {F : Type} [CommRing F] (q : Prop) [Decidable q] :
    (flag q : F) = if q then 1 else 0 := by
  by_cases h : q <;> simp [flag, h, Ring.intCast_zero, Ring.intCast_one]

theorem constrained_inputs_normalize {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (phases : ∀ i : Fin 8, values i.val = if i.val = p.val then 1 else 0)
    (depths : ∀ i : Fin 9, values (8+i.val) = if i.val = h.val then 1 else 0)
    (bitsBoolean : ∀ value ∈ witnessBits values, value * (value - 1) = 0)
    (bitsBinding : weightedValues (BitPacking.bitWeights 8) (witnessBits values) = (b.val : F))
    (selectorsBoolean : ∀ value ∈ witnessSelectors values, value * (value - 1) = 0)
    (selectorsTotal : sum (witnessSelectors values) = if p.val = 0 then 1 else 0)
    (selectorsBinding : weightedValues opcodeCodes (witnessSelectors values) =
      (if p.val = 0 then 1 else 0) * (b.val : F)) :
    ∀ i, i < 35 → values i = (canonicalInputs p h b i : F) := by
  have bits := witness_bits_determined values b bitsBoolean bitsBinding
  have selectors := witness_selectors_determined values p b selectorsBoolean selectorsTotal selectorsBinding
  intro i range
  by_cases hp : i < 8
  · have state := phases ⟨i, hp⟩
    simpa only [canonicalInputs, ite_eq_left hp, cast_flag] using state
  · by_cases hd : i < 17
    · have ix : i-8 < 9 := by omega
      have state := depths ⟨i-8, ix⟩
      have add : 8+(i-8) = i := by omega
      simp only [canonicalInputs, ite_eq_right hp, ite_eq_left hd, cast_flag]
      simpa only [add] using state
    · by_cases hb : i < 25
      · have ix : i-17 < 8 := by omega
        have add : 17+(i-17) = i := by omega
        have point := congrArg (fun xs : List F => (xs[i-17]?).getD 0) bits
        simp only [witnessBits, byteBits, List.map_ofFn, List.getElem?_ofFn,
          dite_eq_left ix, Option.getD_some] at point
        simpa only [add, Function.comp_def, boolValue, decide_eq_true_eq, canonicalInputs,
          ite_eq_right hp, ite_eq_right hd, ite_eq_left hb, cast_flag] using point
      · have ix : i-25 < 10 := by omega
        have add : 25+(i-25) = i := by omega
        have point := congrArg (fun xs : List F => (xs[i-25]?).getD 0) selectors
        simp only [witnessSelectors, canonicalSelectors, List.map_ofFn, List.getElem?_ofFn,
          dite_eq_left ix, Option.getD_some] at point
        simpa only [add, Function.comp_def, boolValue, decide_eq_true_eq, canonicalInputs,
          ite_eq_right hp, ite_eq_right hd, ite_eq_right hb, ite_eq_left range, cast_flag] using point

theorem constrained_field_row_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (phases : ∀ i : Fin 8, values i.val = if i.val = p.val then 1 else 0)
    (depths : ∀ i : Fin 9, values (8+i.val) = if i.val = h.val then 1 else 0)
    (bitsBoolean : ∀ value ∈ witnessBits values, value * (value - 1) = 0)
    (bitsBinding : weightedValues (BitPacking.bitWeights 8) (witnessBits values) = (b.val : F))
    (selectorsBoolean : ∀ value ∈ witnessSelectors values, value * (value - 1) = 0)
    (selectorsTotal : sum (witnessSelectors values) = if p.val = 0 then 1 else 0)
    (selectorsBinding : weightedValues opcodeCodes (witnessSelectors values) =
      (if p.val = 0 then 1 else 0) * (b.val : F))
    (holds : FieldHolds values) :
    ∃ nextPhase nextDepth,
      ByteStream.referenceRow p.val h.val b.val = some (nextPhase, nextDepth) ∧
      row.nextPhases.map (evalField values) = (oneHot 8 nextPhase).map (fun n : Int => (n : F)) ∧
      row.nextDepths.map (evalField values) = (oneHot 9 nextDepth).map (fun n : Int => (n : F)) := by
  have agree := constrained_inputs_normalize values p h b phases depths bitsBoolean bitsBinding
    selectorsBoolean selectorsTotal selectorsBinding
  have sameEval (e : Expr) (member : e ∈ row.residuals ++ row.nextPhases ++ row.nextDepths) :
      evalField values e = evalField (fun i => (canonicalInputs p h b i : F)) e := by
    apply eval_congr_below values (fun i => (canonicalInputs p h b i : F)) 35 agree e
    exact List.all_eq_true.mp row_uses_only_inputs e member
  have canonicalHolds : FieldHolds (fun i => (canonicalInputs p h b i : F)) := by
    intro e member
    rw [← sameEval e (by simp [member])]
    exact holds e member
  obtain ⟨nextPhase, nextDepth, ref, phasesEq, depthsEq⟩ := canonical_field_row_sound p h b canonicalHolds
  refine ⟨nextPhase, nextDepth, ref, ?_, ?_⟩
  · have same : row.nextPhases.map (evalField values) =
        row.nextPhases.map (evalField (fun i => (canonicalInputs p h b i : F))) := by
      apply List.map_congr_left
      intro e member
      exact sameEval e (by simp [member])
    exact same.trans phasesEq
  · have same : row.nextDepths.map (evalField values) =
        row.nextDepths.map (evalField (fun i => (canonicalInputs p h b i : F))) := by
      apply List.map_congr_left
      intro e member
      exact sameEval e (by simp [member])
    exact same.trans depthsEq

#print axioms constrained_inputs_normalize
#print axioms constrained_field_row_sound

end ZkBuild.InputNormalization
