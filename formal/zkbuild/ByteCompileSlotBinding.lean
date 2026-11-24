import ByteCompileDecodeTrace

/- Bind the final queue to the exact program recovered by the already proved
   RV32 emitter. Every link is a checked gate or wire substitution. -/
namespace ZkBuild.ByteCompileSlotBinding

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
attribute [local instance] Ring.intCast Semiring.natCast

def sourceInfo (i : Fin 16) : RowInfo := SlotTrace.infoAt i
def booleanLinear (i : Fin 16) (j : Nat) : Linear :=
  substitute slotMap [( (sourceInfo i).wireStart+j, 1)]
def weightedLines (items : List Nat) (lines : Nat → Linear) (weight : Nat → Int) : Linear :=
  items.flatMap fun j => scale (lines j) (weight j)
def kindLinear (i : Fin 16) : Linear := weightedLines (List.range 10) (booleanLinear i) Int.ofNat
def valueLinear (i : Fin 16) : Linear := weightedLines (List.range 32) (fun j => booleanLinear i (10+j)) (fun j => Int.ofNat (2^j))
def aux (i : Fin 16) : Linear := [(21261+i.val, 1)]
def queueLinear (i : Fin 16) : Linear := [(21245+i.val, 1)]
def productGate (i : Fin 16) : Gate := ⟨booleanLinear i 3, valueLinear i, aux i⟩
def bindingGate (i : Fin 16) : Gate := ⟨sub (queueLinear i) (kindLinear i ++ scale (aux i) 16), constant 1, constant 0⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem final_gates : ∀ i : Fin 16,
    ByteCompileShape.shape.gates[23523+i.val*2]? = some (productGate i) ∧
    ByteCompileShape.shape.gates[23524+i.val*2]? = some (bindingGate i) := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem boolean_links : ∀ (i : Fin 16) (j : Fin 42),
    booleanLinear i j.val = substitute slotMap
      (SlotMatrix.rowWires (sourceInfo i) (SlotRow.sourceWire (9+j.val))) ∧
    (SlotMatrix.rowWires (sourceInfo i) (SlotRow.sourceWire (9+j.val))).all (fun term => term.1 < 11899) = true := by
  native_decide

theorem slot_source_eval {F : Type} [CommRing F] (values : Nat → F) (linear : Linear)
    (bound : linear.all (fun term => term.1 < 11899) = true) :
    evalLinear values (substitute slotMap linear) = evalLinear (slotContext values).get linear := by
  rw [eval_substitute]
  apply ByteCompileComposition.eval_congr
  intro term member
  have small : term.1 < 11899 := of_decide_eq_true (List.all_eq_true.mp bound term member)
  exact (projection_value values slotMap 11899 (by decide) term.1 small).symm

theorem boolean_value {F : Type} [CommRing F] (values : Nat → F) (i : Fin 16) (j : Fin 42) :
    evalLinear values (booleanLinear i j.val) =
      (SlotMatrix.rowContext (slotContext values) (sourceInfo i)).get (9+j.val) := by
  rw [(boolean_links i j).1, slot_source_eval values _ (boolean_links i j).2]
  exact SlotMatrix.context_sources (slotContext values) (sourceInfo i) (9+j.val) (by omega)

theorem weighted_congr {F : Type} [CommRing F] (a b : Nat → F) (left right : Nat → Linear)
    (weight : Nat → Int) (items : List Nat)
    (point : ∀ j ∈ items, evalLinear a (left j) = evalLinear b (right j)) :
    evalLinear a (weightedLines items left weight) = evalLinear b (weightedLines items right weight) := by
  induction items with
  | nil => rfl
  | cons first rest ih =>
    simp only [weightedLines, List.flatMap_cons, eval_append, eval_scale]
    rw [point first (by simp)]
    have tail := ih (fun j member => point j (by simp [member]))
    exact congrArg (fun value => (weight first : F) * evalLinear b (right first) + value) tail

def localValue : Linear := weightedLines (List.range 32) (fun j => [(19+j, 1)]) (fun j => Int.ofNat (2^j))
def localKind : Linear := weightedLines (List.range 10) (fun j => [(9+j, 1)]) Int.ofNat

theorem packed_certificate : RowMatrix.samePolynomial (directExpression localValue)
    (SlotRow.packed SlotRow.valueBit 0 32) = true := by native_decide

theorem immediate_value_from_slot {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : (slotContext values).get 0 = 1)
    (holds : Satisfied SlotShape.compileShape (slotContext values).get) (i : Fin 16) :
    evalLinear values (valueLinear i) = (SlotEmission.immediateAt (slotContext values) i.val).toNat := by
  let ctx := slotContext values
  let rc := SlotMatrix.rowContext ctx (sourceInfo i)
  have eq : evalLinear values (valueLinear i) = evalLinear rc.get localValue := by
    apply weighted_congr
    intro j member
    have bound : j < 32 := List.mem_range.mp member
    have point := boolean_value values i ⟨10+j, by omega⟩
    simp only [show 9+(10+j) = 19+j by omega] at point
    simpa [rc, ctx, sourceInfo, evalLinear, interpretLinear, R1CS.eval,
      Ring.intCast_one, Semiring.one_mul, Semiring.add_zero] using point
  rw [eq]
  have packed := RowMatrix.polynomial_certificate_sound rc _ _ packed_certificate
  rw [direct_expression_sound] at packed
  rw [packed]
  have equations := (SlotMatrix.full_row_equations ctx (sourceInfo i) (SlotTrace.info_member i)
    one holds).1
  have exactValue := SlotImmediate.immediate_slice_field rc.get equations 0 32 (by decide)
  have full : (SlotImmediate.immediate rc.get).extractLsb' 0 32 = SlotImmediate.immediate rc.get := by bv_decide
  rw [full] at exactValue
  simpa [SlotEmission.immediateAt, i.isLt, rc, ctx, sourceInfo] using exactValue

theorem immediate_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (holds : Satisfied ByteCompileShape.shape values) (i : Fin 16) :
    evalLinear values (valueLinear i) = (SlotEmission.immediateAt (slotContext values) i.val).toNat :=
  immediate_value_from_slot values (projected_one values one).2 (slot_context_satisfied values holds) i

theorem ordinal_value {F : Type} [CommRing F] (values : Nat → F) (kind : Fin 10)
    (picked : ∀ j, j < 10 → values (9+j) = if j = kind.val then 1 else 0) :
    evalLinear values localKind = (kind.val : F) := by
  have p0 := picked 0 (by decide)
  have p1 := picked 1 (by decide)
  have p2 := picked 2 (by decide)
  have p3 := picked 3 (by decide)
  have p4 := picked 4 (by decide)
  have p5 := picked 5 (by decide)
  have p6 := picked 6 (by decide)
  have p7 := picked 7 (by decide)
  have p8 := picked 8 (by decide)
  have p9 := picked 9 (by decide)
  rcases kind with ⟨k, bound⟩
  have options : k = 0 ∨ k = 1 ∨ k = 2 ∨ k = 3 ∨ k = 4 ∨ k = 5 ∨ k = 6 ∨ k = 7 ∨ k = 8 ∨ k = 9 := by omega
  rcases options with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [localKind, weightedLines, List.range_succ, scale, evalLinear, interpretLinear, R1CS.eval,
      p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, Ring.intCast_zero, Ring.intCast_one,
       Semiring.mul_zero, Semiring.one_mul, Semiring.mul_one, Semiring.add_zero,
      Semiring.natCast_zero, Semiring.natCast_one, Int.ofNat_eq_natCast] <;> grind

theorem selected_kind {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (i : Fin 16) (kind : Fin 10)
    (selected : SlotTrace.SelectorAt (slotContext values) i.val kind) :
    evalLinear values (kindLinear i) = (kind.val : F) := by
  let rc := SlotMatrix.rowContext (slotContext values) (sourceInfo i)
  have eq : evalLinear values (kindLinear i) = evalLinear rc.get localKind := by
    apply weighted_congr
    intro j member
    have bound : j < 10 := List.mem_range.mp member
    have point := boolean_value values i ⟨j, by omega⟩
    simpa [rc, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one,
      Semiring.one_mul, Semiring.add_zero] using point
  rw [eq]
  have picked : ∀ j, j < 10 → rc.get (9+j) = if j = kind.val then 1 else 0 := by
    simpa [rc, sourceInfo, SlotTrace.SelectorAt, i.isLt] using selected
  exact ordinal_value rc.get kind picked

theorem queue_token {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (holds : Satisfied ByteCompileShape.shape values)
    (i : Fin 16) (kind : Fin 10) (selected : SlotTrace.SelectorAt (slotContext values) i.val kind) :
    ByteCompileQueueStep.queueAt values 121 i =
      (ByteCompileQueue.token (SlotNative.operation kind (SlotEmission.immediateAt (slotContext values) i.val)) : F) := by
  have product := holds _ (by simpa using Array.mem_of_getElem? (final_gates i).1)
  have binding := holds _ (by simpa using Array.mem_of_getElem? (final_gates i).2)
  change evalLinear values (booleanLinear i 3) * evalLinear values (valueLinear i) = evalLinear values (aux i) at product
  have selector := boolean_value values i ⟨3, by decide⟩
  have selectedValues : ∀ j, j < 10 →
      (SlotMatrix.rowContext (slotContext values) (sourceInfo i)).get (9+j) = if j = kind.val then 1 else 0 := by
    simpa [SlotTrace.SelectorAt, i.isLt, sourceInfo] using selected
  have picked : evalLinear values (booleanLinear i 3) = if 3 = kind.val then 1 else 0 := by
    rw [selector]
    exact selectedValues 3 (by decide)
  rw [picked, immediate_value values one holds i] at product
  change evalLinear values (sub (queueLinear i) (kindLinear i ++ scale (aux i) 16)) *
    evalLinear values (constant 1) = evalLinear values (constant 0) at binding
  rw [ByteCompileRow.eval_sub, eval_append, eval_scale, ByteCompileRow.eval_constant values one,
    ByteCompileRow.eval_constant values one, Ring.intCast_one, Ring.intCast_zero,
    selected_kind values i kind selected] at binding
  have queue : evalLinear values (queueLinear i) = ByteCompileQueueStep.queueAt values 121 i := by
    simp [queueLinear, ByteCompileQueueStep.queueAt, evalLinear, interpretLinear, R1CS.eval,
      Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  rw [queue] at binding
  rw [ByteCompileEvents.operation_token, Semiring.natCast_add]
  by_cases constant : kind.val = 3
  · simp only [constant, ite_true, Semiring.one_mul, Semiring.natCast_mul] at product binding ⊢
    have coefficient : ((16 : Nat) : F) = ((16 : Int) : F) := (Ring.intCast_natCast 16).symm
    rw [coefficient]
    grind
  · have different : ¬3 = kind.val := Ne.symm constant
    simp only [constant, different, ite_false, Semiring.zero_mul,
      Semiring.natCast_zero, Semiring.add_zero] at *
    grind

#print axioms queue_token

end ZkBuild.ByteCompileSlotBinding
