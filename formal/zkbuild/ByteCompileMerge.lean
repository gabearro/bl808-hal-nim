import ByteCompileRow

/- Component witness embedding into the combined matrix. Its private ranges
   are disjoint, and the chosen public inputs retain each source relation. -/
namespace ZkBuild.ByteCompileMerge

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
attribute [local instance] Ring.intCast Semiring.natCast

def values {F : Type} [CommRing F] (bytes slots tail : Nat → F) (index : Nat) : F :=
  if index = 0 then 1
  else if index < 8 then bytes index
  else if index < 13 then slots (index-2)
  else if index < 6101 then bytes (index-5)
  else if index < 6106 then slots (index-6100)
  else if index < 17994 then slots (index-6095)
  else tail (index-17994)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem byte_map : ∀ i : Fin 6096, byteMap i.val =
    (if i.val = 0 then constant 1 else if i.val < 8 then [(i.val, 1)] else [(i.val+5, 1)]) := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem slot_map : ∀ i : Fin 11899, slotMap i.val =
    (if i.val = 0 then constant 1 else if i.val < 6 then [(6100+i.val, 1)]
    else if i.val < 11 then [(i.val+2, 1)] else [(6095+i.val, 1)]) := by native_decide

theorem one {F : Type} [CommRing F] (bytes slots tail : Nat → F) : values bytes slots tail 0 = 1 := by
  simp [values]

theorem public_byte {F : Type} [CommRing F] (bytes slots tail : Nat → F) (i : Fin 7) :
    values bytes slots tail (1+i.val) = bytes (1+i.val) := by
  have nonzero : 1+i.val ≠ 0 := by omega
  have small : 1+i.val < 8 := by omega
  simp only [values, nonzero, ite_false, small, ite_true]

theorem public_native {F : Type} [CommRing F] (bytes slots tail : Nat → F) (i : Fin 5) :
    values bytes slots tail (8+i.val) = slots (6+i.val) := by
  have nonzero : 8+i.val ≠ 0 := by omega
  have large : ¬8+i.val < 8 := by omega
  have small : 8+i.val < 13 := by omega
  have index : 8+i.val-2 = 6+i.val := by omega
  simp only [values, nonzero, ite_false, large, small, ite_true, index]

theorem byte_values {F : Type} [CommRing F] (bytes slots tail : Nat → F) (zero : bytes 0 = 1) (i : Fin 6096) :
    evalLinear (values bytes slots tail) (byteMap i.val) = bytes i.val := by
  rw [byte_map]
  by_cases first : i.val = 0
  · simp [first, ByteCompileRow.eval_constant _ (one bytes slots tail), zero, Ring.intCast_one]
  · simp only [first, ite_false]
    by_cases input : i.val < 8
    · simp [input, values, first,
        evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
    · simp only [input, ite_false]
      have notByteInput : ¬i.val+5 < 8 := by omega
      have notSlotInput : ¬i.val+5 < 13 := by omega
      have privateBound : i.val+5 < 6101 := by omega
      simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero,
        values, notByteInput, notSlotInput, privateBound]

theorem slot_values {F : Type} [CommRing F] (bytes slots tail : Nat → F) (zero : slots 0 = 1) (i : Fin 11899) :
    evalLinear (values bytes slots tail) (slotMap i.val) = slots i.val := by
  rw [slot_map]
  by_cases first : i.val = 0
  · simp [first, ByteCompileRow.eval_constant _ (one bytes slots tail), zero, Ring.intCast_one]
  · simp only [first, ite_false]
    by_cases input : i.val < 6
    · have notByte : ¬6100+i.val < 8 := by omega
      have notNative : ¬6100+i.val < 13 := by omega
      have notPrivate : ¬6100+i.val < 6101 := by omega
      have canonical : 6100+i.val < 6106 := by omega
      simp [input, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul,
        Semiring.add_zero, values, notByte, notNative, notPrivate, canonical]
    · simp only [input, ite_false]
      by_cases publicNative : i.val < 11
      · have notByte : ¬i.val+2 < 8 := by omega
        have native : i.val+2 < 13 := by omega
        simp [publicNative, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul,
          Semiring.add_zero, values, notByte, native]
      · have notByte : ¬6095+i.val < 8 := by omega
        have notNative : ¬6095+i.val < 13 := by omega
        have notBytePrivate : ¬6095+i.val < 6101 := by omega
        have notCanonical : ¬6095+i.val < 6106 := by omega
        have privateBound : 6095+i.val < 17994 := by omega
        simp [publicNative, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul,
          Semiring.add_zero, values, notByte, notNative, notBytePrivate, notCanonical, privateBound]

theorem byte_context {F : Type} [CommRing F] (bytes slots tail : Nat → F) (zero : bytes 0 = 1) :
    byteContext (values bytes slots tail) =
      Lean.RArray.ofFn (fun i : Fin 6096 => bytes i.val) (by decide) := by
  unfold byteContext projection
  have same : (fun i : Fin 6096 => evalLinear (values bytes slots tail) (byteMap i.val)) =
      (fun i : Fin 6096 => bytes i.val) := funext (byte_values bytes slots tail zero)
  rw [same]

theorem slot_context {F : Type} [CommRing F] (bytes slots tail : Nat → F) (zero : slots 0 = 1) :
    slotContext (values bytes slots tail) =
      Lean.RArray.ofFn (fun i : Fin 11899 => slots i.val) (by decide) := by
  unfold slotContext projection
  have same : (fun i : Fin 11899 => evalLinear (values bytes slots tail) (slotMap i.val)) =
      (fun i : Fin 11899 => slots i.val) := funext (slot_values bytes slots tail zero)
  rw [same]

theorem substitution_complete {F : Type} [CommRing F] (values : Nat → F) (mapping : Nat → Linear) (gate : Gate)
    (holds : R1CS.Holds (fun i => evalLinear values (mapping i)) (interpretGate gate)) :
    R1CS.Holds values (interpretGate (substituteGate mapping gate)) := by
  change evalLinear values (substitute mapping gate.a) * evalLinear values (substitute mapping gate.b) =
    evalLinear values (substitute mapping gate.c)
  rw [eval_substitute, eval_substitute, eval_substitute]
  exact holds

theorem byte_component_complete {F : Type} [CommRing F] (bytes slots tail : Nat → F)
    (zero : bytes 0 = 1) (holds : Satisfied byteShape bytes) :
    ∀ gate ∈ byteShape.gates.toList,
      R1CS.Holds (values bytes slots tail) (interpretGate (substituteGate byteMap gate)) := by
  have copied : Satisfied byteShape (fun i => evalLinear (values bytes slots tail) (byteMap i)) := by
    apply bounded_satisfied byteShape sources_bounded.1 bytes _ _ holds
    intro i bound
    have size : byteShape.wires = 6096 := by native_decide
    exact (byte_values bytes slots tail zero ⟨i, by omega⟩).symm
  intro gate member
  exact substitution_complete _ _ _ (copied gate member)

theorem slot_component_complete {F : Type} [CommRing F] (bytes slots tail : Nat → F)
    (zero : slots 0 = 1) (holds : Satisfied SlotShape.compileShape slots) :
    ∀ gate ∈ SlotShape.compileShape.gates.toList,
      R1CS.Holds (values bytes slots tail) (interpretGate (substituteGate slotMap gate)) := by
  have copied : Satisfied SlotShape.compileShape (fun i => evalLinear (values bytes slots tail) (slotMap i)) := by
    apply bounded_satisfied SlotShape.compileShape sources_bounded.2 slots _ _ holds
    intro i bound
    have size := SlotShape.compile_dimensions.1
    exact (slot_values bytes slots tail zero ⟨i, by omega⟩).symm
  intro gate member
  exact substitution_complete _ _ _ (copied gate member)

#print axioms byte_component_complete
#print axioms slot_component_complete

end ZkBuild.ByteCompileMerge
