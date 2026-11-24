import ByteCompileMerge
import ByteCompileRowComplete

/- The assembly theorem accounts for every gate in the combined matrix.
   It leaves explicit the two semantic obligations of a bridge constructor:
   no queue overflow and equality of the final queue to the emitter tokens. -/
namespace ZkBuild.ByteCompileAssembly

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
attribute [local instance] Ring.intCast Semiring.natCast

def bridgeGates : List Gate := (List.finRange 121).flatMap fun i =>
  (List.finRange 28).map fun j => substituteGate (ByteCompileRow.rowMap i) (ByteCompileRow.gate j.val)

def bindingGates : List Gate := (List.finRange 16).flatMap fun i =>
  [ByteCompileSlotBinding.productGate i, ByteCompileSlotBinding.bindingGate i]

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem partition : ByteCompileShape.shape.gates.toList =
    byteShape.gates.toList.map (substituteGate byteMap) ++
    SlotShape.compileShape.gates.toList.map (substituteGate slotMap) ++ bridgeGates ++ bindingGates := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem row_bounds : ∀ j : Fin 28,
    [(ByteCompileRow.gate j.val).a, (ByteCompileRow.gate j.val).b, (ByteCompileRow.gate j.val).c].all
      (fun side => side.all fun term => term.1 < 67) = true := by native_decide

def rowInputs {F : Type} [CommRing F] (values : Nat → F) (i : Fin 121) : Lean.RArray F :=
  Lean.RArray.ofFn (fun k : Fin 40 => ByteCompileRow.localValues values i k.val) (by decide)

theorem rows_complete {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (assigned : ∀ (i : Fin 121) (j : Fin 27),
      ByteCompileRow.localValues values i (40+j.val) =
        ByteCompileRowComplete.fieldWitness (rowInputs values i) (40+j.val))
    (overflow : ∀ i : Fin 121,
      RowSoundness.evalField (rowInputs values i).get ByteCompileRowComplete.overflowExpr = 0) :
    ∀ i : Fin 121, ByteCompileRow.Holds (ByteCompileRow.localValues values i) := by
  intro i j
  have inputOne : (rowInputs values i).get 0 = 1 := by
    rw [rowInputs, Lean.RArray.get_ofFn _ (by decide) ⟨0, by decide⟩]
    exact ByteCompileRow.local_one values one i
  have same (k : Nat) (bound : k < 67) :
      ByteCompileRow.localValues values i k = ByteCompileRowComplete.fieldWitness (rowInputs values i) k := by
    by_cases input : k < 40
    · rw [ByteCompileRowComplete.input_value _ inputOne k input]
      exact (Lean.RArray.get_ofFn (fun k : Fin 40 => ByteCompileRow.localValues values i k.val) (by decide) ⟨k, input⟩).symm
    · have index : 40+(k-40) = k := by omega
      simpa only [index] using assigned i ⟨k-40, by omega⟩
  have equalSide (side : Linear) (member : side ∈
      [(ByteCompileRow.gate j.val).a, (ByteCompileRow.gate j.val).b, (ByteCompileRow.gate j.val).c]) :
      evalLinear (ByteCompileRow.localValues values i) side =
        evalLinear (ByteCompileRowComplete.fieldWitness (rowInputs values i)) side := by
    apply eval_congr
    intro term termMember
    exact same term.1 (of_decide_eq_true
      (List.all_eq_true.mp (List.all_eq_true.mp (row_bounds j) side member) term termMember))
  have a := equalSide (ByteCompileRow.gate j.val).a (by simp)
  have b := equalSide (ByteCompileRow.gate j.val).b (by simp)
  have c := equalSide (ByteCompileRow.gate j.val).c (by simp)
  change evalLinear _ (ByteCompileRow.gate j.val).a * evalLinear _ (ByteCompileRow.gate j.val).b =
    evalLinear _ (ByteCompileRow.gate j.val).c
  rw [a, b, c]
  exact ByteCompileRowComplete.row_complete (rowInputs values i) (overflow i) j

theorem bindings_complete {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (products : ∀ i : Fin 16, values (21261+i.val) =
      evalLinear values (ByteCompileSlotBinding.booleanLinear i 3) *
        evalLinear values (ByteCompileSlotBinding.valueLinear i))
    (tokens : ∀ i : Fin 16, values (21245+i.val) =
      evalLinear values (ByteCompileSlotBinding.kindLinear i) +
        (16 : F) * values (21261+i.val)) :
    ∀ gate ∈ bindingGates, R1CS.Holds values (interpretGate gate) := by
  intro gate member
  obtain ⟨i, _, choice⟩ := List.mem_flatMap.mp member
  have cases : gate = ByteCompileSlotBinding.productGate i ∨ gate = ByteCompileSlotBinding.bindingGate i := by
    simpa using choice
  rcases cases with rfl | rfl
  · change evalLinear values (ByteCompileSlotBinding.booleanLinear i 3) *
      evalLinear values (ByteCompileSlotBinding.valueLinear i) = evalLinear values (ByteCompileSlotBinding.aux i)
    rw [ByteCompileSlotBinding.aux]
    exact (products i).symm.trans (ByteCompileRow.eval_wire values (21261+i.val)).symm
  · change evalLinear values (sub (ByteCompileSlotBinding.queueLinear i)
      (ByteCompileSlotBinding.kindLinear i ++ scale (ByteCompileSlotBinding.aux i) 16)) *
      evalLinear values (constant 1) = evalLinear values (constant 0)
    rw [ByteCompileRow.eval_sub, eval_append, eval_scale,
      ByteCompileRow.eval_constant values one, ByteCompileRow.eval_constant values one]
    simp only [ByteCompileSlotBinding.queueLinear, ByteCompileSlotBinding.aux,
      show [(21245+i.val, (1 : Int))] = ByteCompileRow.wire (21245+i.val) from rfl,
      show [(21261+i.val, (1 : Int))] = ByteCompileRow.wire (21261+i.val) from rfl,
      ByteCompileRow.eval_wire, Ring.intCast_one, Ring.intCast_zero, Semiring.mul_one]
    have coefficient : ((16 : Int) : F) = (16 : F) := Ring.intCast_ofNat 16
    rw [coefficient, tokens i]
    grind

theorem complete {F : Type} [CommRing F] (bytes slots tail : Nat → F)
    (byteOne : bytes 0 = 1) (slotOne : slots 0 = 1)
    (byteHolds : Satisfied byteShape bytes) (slotHolds : Satisfied SlotShape.compileShape slots)
    (rows : ∀ i : Fin 121, ByteCompileRow.Holds
      (ByteCompileRow.localValues (ByteCompileMerge.values bytes slots tail) i))
    (products : ∀ i : Fin 16, (ByteCompileMerge.values bytes slots tail) (21261+i.val) =
      evalLinear (ByteCompileMerge.values bytes slots tail) (ByteCompileSlotBinding.booleanLinear i 3) *
        evalLinear (ByteCompileMerge.values bytes slots tail) (ByteCompileSlotBinding.valueLinear i))
    (tokens : ∀ i : Fin 16, (ByteCompileMerge.values bytes slots tail) (21245+i.val) =
      evalLinear (ByteCompileMerge.values bytes slots tail) (ByteCompileSlotBinding.kindLinear i) +
        (16 : F) * (ByteCompileMerge.values bytes slots tail) (21261+i.val)) :
    Satisfied ByteCompileShape.shape (ByteCompileMerge.values bytes slots tail) := by
  intro gate member
  rw [partition] at member
  rcases List.mem_append.mp member with earlier | binding
  · rcases List.mem_append.mp earlier with components | bridge
    · rcases List.mem_append.mp components with byte | slot
      · obtain ⟨source, included, rfl⟩ := List.mem_map.mp byte
        exact ByteCompileMerge.byte_component_complete bytes slots tail byteOne byteHolds source included
      · obtain ⟨source, included, rfl⟩ := List.mem_map.mp slot
        exact ByteCompileMerge.slot_component_complete bytes slots tail slotOne slotHolds source included
    · obtain ⟨i, _, included⟩ := List.mem_flatMap.mp bridge
      obtain ⟨j, _, rfl⟩ := List.mem_map.mp included
      exact ByteCompileMerge.substitution_complete _ _ _ (rows i j)
  · exact bindings_complete _ (ByteCompileMerge.one bytes slots tail) products tokens gate binding

#print axioms rows_complete
#print axioms complete

end ZkBuild.ByteCompileAssembly
