import SlotCompilation
import RowCompleteness

/- Constructive completeness of a compilation row. Canonical primary values
   determine every auxiliary wire through the already checked elimination. -/
namespace ZkBuild.SlotRowCompleteness

open Lean.Grind RowSoundness SlotRow
attribute [local instance] Ring.intCast Semiring.natCast

theorem test_bit_value (value index : Nat) :
    (value.testBit index).toNat = value / 2^index % 2 := by
  rw [Nat.testBit_eq_decide_div_mod_eq]
  have bound := Nat.mod_lt (value/2^index) (by decide : 0 < 2)
  by_cases one : value/2^index%2 = 1
  · simp [one]
  · have zero : value/2^index%2 = 0 := by omega
    simp [zero]

theorem pack_test_bits (value start count : Nat) :
    SlotImmediate.packNat value.testBit start count = value/2^start % 2^count := by
  induction count with
  | zero => simp [SlotImmediate.packNat, Nat.mod_one]
  | succ count ih =>
    have expansion : SlotImmediate.packNat value.testBit start (count+1) =
        SlotImmediate.packNat value.testBit start count + (value.testBit (start+count)).toNat * 2^count := by
      simp [SlotImmediate.packNat, List.range_succ, List.map_append, List.sum_append]
    rw [expansion, ih, test_bit_value, Nat.mod_pow_succ, Nat.div_div_eq_div_mul, ← Nat.pow_add]
    rw [Nat.mul_comm]

theorem pack_word_bits {width : Nat} (value : BitVec width) (start count : Nat) :
    SlotImmediate.packNat value.getLsbD start count = (value.extractLsb' start count).toNat := by
  rw [BitVec.extractLsb', BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  exact pack_test_bits value.toNat start count

theorem word_bit_value {width : Nat} (value : BitVec width) (index : Nat) :
    (value.getLsbD index).toNat = value.toNat / 2^index % 2 :=
  test_bit_value value.toNat index

theorem rounded_equation (value : Word) :
    value.toNat + 2048 = (Rv32Compiler.upperImmediate value).toNat*4096 +
      ((value.extractLsb' 0 11).toNat + (1-(value.getLsbD 11).toNat)*2048) +
      ((value.toNat+2048)/4294967296)*4294967296 := by
  rw [SlotImmediate.emitted_upper_toNat, word_bit_value, BitVec.extractLsb',
    BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  simp only [Nat.pow_zero, Nat.div_one]
  omega

def primary (kind : Fin 10) (height : Fin 9) (value : Word) (i : Nat) : Nat :=
  if i < 9 then if i = height.val then 1 else 0
  else if i < 19 then if i-9 = kind.val then 1 else 0
  else if i < 51 then (value.getLsbD (i-19)).toNat
  else if i < 71 then ((Rv32Compiler.upperImmediate value).getLsbD (i-51)).toNat
  else if i = 71 then (value.toNat+2048)/4294967296 else 0

noncomputable def context {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 72 => (primary kind height value i.val : F)) (by decide)

theorem context_entry {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Nat) (bound : i < 72) :
    (context (F := F) kind height value).get i = (primary kind height value i : F) :=
  Lean.RArray.get_ofFn (fun j : Fin 72 => (primary kind height value j.val : F)) (by decide) ⟨i, bound⟩

theorem prior_values {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Nat) (bound : i < 9) :
    (context (F := F) kind height value).get i = if i = height.val then 1 else 0 := by
  rw [context_entry kind height value i (by omega)]
  simp only [primary, bound, ite_true]
  split <;> simp [Semiring.natCast_one, Semiring.natCast_zero]

theorem selected_values {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Nat) (bound : i < 10) :
    (context (F := F) kind height value).get (9+i) = if i = kind.val then 1 else 0 := by
  rw [context_entry kind height value (9+i) (by omega)]
  have lower : ¬9+i < 9 := by omega
  have upper : 9+i < 19 := by omega
  simp only [primary, lower, ite_false, upper, ite_true, Nat.add_sub_cancel_left]
  split <;> simp [Semiring.natCast_one, Semiring.natCast_zero]

theorem immediate_values {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Nat) (bound : i < 32) :
    (context (F := F) kind height value).get (19+i) = ((value.getLsbD i).toNat : F) := by
  rw [context_entry kind height value (19+i) (by omega)]
  have lo9 : ¬19+i < 9 := by omega
  have lo19 : ¬19+i < 19 := by omega
  have hi51 : 19+i < 51 := by omega
  simp only [primary, lo9, lo19, hi51, ite_false, ite_true, Nat.add_sub_cancel_left]

theorem upper_values {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Nat) (bound : i < 20) :
    (context (F := F) kind height value).get (51+i) = (((Rv32Compiler.upperImmediate value).getLsbD i).toNat : F) := by
  rw [context_entry kind height value (51+i) (by omega)]
  have lo9 : ¬51+i < 9 := by omega
  have lo19 : ¬51+i < 19 := by omega
  have lo51 : ¬51+i < 51 := by omega
  have hi71 : 51+i < 71 := by omega
  simp only [primary, lo9, lo19, lo51, hi71, ite_false, ite_true, Nat.add_sub_cancel_left]

theorem carry_value {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word) :
    (context (F := F) kind height value).get 71 = (((value.toNat+2048)/4294967296 : Nat) : F) := by
  rw [context_entry kind height value 71 (by decide)]
  rfl

theorem immediate_packed {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (start count : Nat) (bound : start+count ≤ 32) :
    evalField (context (F := F) kind height value).get (packed valueBit start count) =
      ((value.extractLsb' start count).toNat : F) := by
  rw [← pack_word_bits]
  apply SlotImmediate.eval_packed
  intro i before
  exact immediate_values kind height value (start+i) (by omega)

theorem upper_packed {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (start count : Nat) (bound : start+count ≤ 20) :
    evalField (context (F := F) kind height value).get (packed upperBit start count) =
      (((Rv32Compiler.upperImmediate value).extractLsb' start count).toNat : F) := by
  rw [← pack_word_bits]
  apply SlotImmediate.eval_packed
  intro i before
  exact upper_values kind height value (start+i) (by omega)

theorem primary_bounded (kind : Fin 10) (height : Fin 9) (value : Word) (i : Nat) :
    primary kind height value i ≤ 1 := by
  unfold primary
  split
  · split <;> decide
  · split
    · split <;> decide
    · split
      · cases value.getLsbD (i-19) <;> decide
      · split
        · cases (Rv32Compiler.upperImmediate value).getLsbD (i-51) <;> decide
        · split
          · have bound := value.isLt
            omega
          · decide

theorem primary_boolean {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (i : Fin 63) :
    evalField (context (F := F) kind height value).get (.input (9+i.val) * (.input (9+i.val)-1)) = 0 := by
  change (context kind height value).get (9+i.val) *
    ((context kind height value).get (9+i.val)-((1 : Int) : F)) = 0
  rw [context_entry kind height value (9+i.val) (by have := i.isLt; omega), Ring.intCast_one]
  rcases Nat.le_one_iff_eq_zero_or_eq_one.mp (primary_bounded kind height value (9+i.val)) with zero | one
  · simp only [zero, Semiring.natCast_zero, Semiring.zero_mul]
  · simp only [one, Semiring.natCast_one]
    grind

theorem selector_count : ∀ kind : Fin 10,
    ((List.range 10).map (fun i => if i = kind.val then (1 : Nat) else 0)).sum = 1 := by native_decide

theorem selector_total {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word) :
    evalField (context (F := F) kind height value).get (sumExpr ((List.range 10).map SlotRow.selected)) = 1 := by
  rw [eval_sum]
  have mapped : (((List.range 10).map SlotRow.selected).map (evalField (context (F := F) kind height value).get)) =
      ((List.range 10).map (fun i => if i = kind.val then (1 : Nat) else 0)).map (fun n : Nat => (n : F)) := by
    simp only [List.map_map, Function.comp_def]
    apply List.map_congr_left
    intro i member
    change (context kind height value).get (9+i) = _
    rw [selected_values kind height value i (List.mem_range.mp member)]
    split <;> simp [Semiring.natCast_one, Semiring.natCast_zero]
  rw [mapped, sum_natCast, selector_count, Semiring.natCast_one]

theorem one_sub_bit {F : Type} [CommRing F] (bit : Bool) :
    ((1-bit.toNat : Nat) : F) = 1-(bit.toNat : F) := by
  cases bit <;> simp only [Bool.toNat_false, Bool.toNat_true, Nat.sub_zero, Nat.sub_self,
    Semiring.natCast_one, Semiring.natCast_zero] <;> grind

theorem carry_residual {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word) :
    evalField (context (F := F) kind height value).get
      (packed valueBit 0 32 + 2048 -
        (packed upperBit 0 20 * 4096 + (packed valueBit 0 11 + (1-valueBit 11)*2048) + overflow*4294967296)) = 0 := by
  change evalField (context kind height value).get (packed valueBit 0 32) + ((2048 : Int) : F) -
    (evalField (context kind height value).get (packed upperBit 0 20) * ((4096 : Int) : F) +
      (evalField (context kind height value).get (packed valueBit 0 11) +
        (((1 : Int) : F)-(context kind height value).get (19+11)) * ((2048 : Int) : F)) +
      (context kind height value).get 71 * ((4294967296 : Int) : F)) = 0
  rw [immediate_packed kind height value 0 32 (by decide),
    upper_packed kind height value 0 20 (by decide), immediate_packed kind height value 0 11 (by decide),
    immediate_values kind height value 11 (by decide), carry_value]
  have entire : value.extractLsb' 0 32 = value := by bv_decide
  have upperEntire : (Rv32Compiler.upperImmediate value).extractLsb' 0 20 = Rv32Compiler.upperImmediate value := by
    bv_decide
  rw [entire, upperEntire]
  have equation := congrArg (fun n : Nat => (n : F)) (rounded_equation value)
  simp only [Semiring.natCast_add, Semiring.natCast_mul, one_sub_bit] at equation
  grind

theorem context_holds {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (valid : SlotShape.valid kind.val height.val = true) :
    SlotRow.FieldHolds (context (F := F) kind height value).get := by
  have depths := depths_determined (context (F := F) kind height value) kind height
    (prior_values kind height value) (selected_values kind height value)
  have nextTotal : evalField (context (F := F) kind height value).get (sumExpr nextDepths) = 1 := by
    rw [eval_sum, depths, sum_natCast, depth_count]
    simp only [valid, ite_true, Semiring.natCast_one]
  intro expression member
  simp only [SlotRow.residuals, List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with bit | rest
  · obtain ⟨i, bound, rfl⟩ := List.mem_map.mp bit
    exact primary_boolean kind height value ⟨i, List.mem_range.mp bound⟩
  · rcases rest with rfl | rfl | rfl
    · change evalField (context kind height value).get (sumExpr ((List.range 10).map SlotRow.selected)) - ((1 : Int) : F) = 0
      rw [selector_total, Ring.intCast_one]
      grind
    · exact carry_residual kind height value
    · change evalField (context kind height value).get (sumExpr nextDepths) - ((1 : Int) : F) = 0
      rw [nextTotal, Ring.intCast_one]
      grind

def canonicalRowWitness (kind : Fin 10) (height : Fin 9) (value : Word) : List Int :=
  match SlotRow.eliminated with
  | none => []
  | some result => result.environment.toList.map (evalInt (fun i => Int.ofNat (primary kind height value i)))

theorem environment_uses_inputs :
    (match SlotRow.eliminated with
    | none => false
    | some result => result.environment.toList.all (InputNormalization.UsesBelow 72)) = true := by native_decide

theorem source_entries : ∀ i : Fin 72,
    SlotRow.inputEnvironment[SlotRow.sourceWire i.val]? = some (.input i.val) := by native_decide

theorem source_bounds : ∀ i : Fin 72, SlotRow.sourceWire i.val < SlotRow.inputEnvironment.size := by native_decide

theorem input_size : SlotRow.inputEnvironment.size = 78 := by native_decide

theorem integer_environment_agrees {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (inputs : Nat → Int) (environment : Array Expr)
    (agree : ∀ i, i < 72 → ctx.get i = (inputs i : F))
    (bounded : environment.toList.all (InputNormalization.UsesBelow 72) = true) :
    RowMatrix.EnvironmentAgrees ctx
      (fun i => ((environment.toList.map (evalInt inputs))[i]?.getD 0 : F)) environment := by
  intro i bound
  have member : environment[i] ∈ environment.toList := Array.getElem_mem_toList bound
  have uses := List.all_eq_true.mp bounded _ member
  have same := InputNormalization.eval_congr_below ctx.get (fun j => (inputs j : F)) 72 agree
    environment[i] uses
  rw [Array.getElem?_eq_getElem bound]
  simp only [Option.getD_some]
  rw [same, integer_interpretation_commutes]
  have listBound : i < (environment.toList.map (evalInt inputs)).length := by simpa using bound
  rw [List.getElem?_eq_getElem listBound]
  simp only [Option.getD_some, List.getElem_map, Array.getElem_toList]

theorem canonical_row_holds {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9) (value : Word)
    (valid : SlotShape.valid kind.val height.val = true) :
    let values := fun i : Nat => ((canonicalRowWitness kind height value)[i]?.getD 0 : F)
    values 0 = 1 ∧
      (∀ i, i < 72 → values (SlotRow.sourceWire i) = (context kind height value).get i) ∧
      CircuitShape.Satisfied SlotRow.rowBuild.2 values := by
  dsimp only
  have certified := SlotRow.row_certificate
  cases found : SlotRow.eliminated with
  | none => simp [SlotRow.certificate, found] at certified
  | some result =>
    have facts : result.environment.size = 753 ∧ result.assertions.length = 71 ∧
        (0 :: SlotRow.residuals).all (fun expected => result.assertions.any (RowMatrix.samePolynomial expected)) = true ∧
        result.assertions.all (fun actual => (0 :: SlotRow.residuals).any (RowMatrix.samePolynomial actual)) = true ∧
        RowMatrix.polynomialListEqual (SlotRow.outputLinears.map (RowMatrix.linearExpr result.environment)) SlotRow.outputs = true := by
      simpa [SlotRow.certificate, found, Bool.and_eq_true_iff, and_assoc] using certified
    let ctx : Lean.RArray F := context kind height value
    let inputs : Nat → Int := fun i => Int.ofNat (primary kind height value i)
    have agrees : ∀ i, i < 72 → ctx.get i = (inputs i : F) := by
      intro i bound
      simpa only [inputs, Int.ofNat_eq_natCast, Ring.intCast_natCast] using context_entry kind height value i bound
    have bounded : result.environment.toList.all (InputNormalization.UsesBelow 72) = true := by
      simpa only [found] using environment_uses_inputs
    have finalAgree := integer_environment_agrees ctx inputs result.environment agrees bounded
    have assertions : ∀ e ∈ result.assertions, evalField ctx.get e = 0 := by
      intro e member
      obtain ⟨expected, expectedMember, equal⟩ := List.any_eq_true.mp
        (List.all_eq_true.mp facts.2.2.2.1 e member)
      rw [RowMatrix.polynomial_certificate_sound ctx e expected equal]
      rcases List.mem_cons.mp expectedMember with rfl | residual
      · simp [evalField, Ring.intCast_zero]
      · exact context_holds kind height value valid _ residual
    have elimination := RowCompleteness.elimination_complete ctx
      (fun i => ((result.environment.toList.map (evalInt inputs))[i]?.getD 0 : F))
      SlotRow.rowBuild.2.gates.toList SlotRow.inputEnvironment result found finalAgree assertions
    simp only [canonicalRowWitness, found]
    refine ⟨?_, ?_, elimination.2⟩
    · have zero := elimination.1 0 (by rw [input_size]; omega)
      rw [SlotRow.input_entries ⟨0, by decide⟩] at zero
      simpa [evalField, Ring.intCast_one, inputs] using zero.symm
    · intro i bound
      have entry := elimination.1 (SlotRow.sourceWire i) (source_bounds ⟨i, bound⟩)
      rw [source_entries ⟨i, bound⟩] at entry
      simpa only [Option.getD_some, evalField, inputs] using entry.symm

theorem canonical_row_length (kind : Fin 10) (height : Fin 9) (value : Word) :
    (canonicalRowWitness kind height value).length = 753 := by
  have certified := SlotRow.row_certificate
  cases found : SlotRow.eliminated with
  | none => simp [SlotRow.certificate, found] at certified
  | some result =>
    have size : result.environment.size = 753 := by
      simp only [SlotRow.certificate, found, Bool.and_eq_true_iff, beq_iff_eq, and_assoc] at certified
      exact certified.1
    simpa only [canonicalRowWitness, found, List.length_map, Array.length_toList] using size

#print axioms context_holds
#print axioms canonical_row_holds

end ZkBuild.SlotRowCompleteness
