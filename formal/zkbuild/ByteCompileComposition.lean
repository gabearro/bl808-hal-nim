import ByteCompileShape
import BinarySoundness
import SlotNativeBinding

namespace ZkBuild.ByteCompileComposition

open Lean.Grind CircuitShape FullMatrix ByteCompileShape
attribute [local instance] Ring.intCast Semiring.natCast

def byteMap (i : Nat) : Linear := lookupLinear built.1.bytes i
def slotMap (i : Nat) : Linear := lookupLinear built.1.slots i

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem byte_prefix : shape.gates.toList.take 8188 =
    byteShape.gates.toList.map (substituteGate byteMap) := by native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem slot_prefix : (shape.gates.toList.drop 8188).take 11947 =
    SlotShape.compileShape.gates.toList.map (substituteGate slotMap) := by native_decide

def bounded (source : Shape) : Bool := source.gates.all fun gate =>
  [gate.a, gate.b, gate.c].all fun side => side.all fun term => term.1 < source.wires

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem sources_bounded : bounded byteShape = true ∧ bounded SlotShape.compileShape = true := by
  native_decide

theorem substituted_satisfied {F : Type} [CommRing F] (source target : Shape)
    (mapping : Nat → Linear) (values : Nat → F)
    (included : ∀ gate ∈ source.gates.toList, substituteGate mapping gate ∈ target.gates.toList)
    (holds : Satisfied target values) :
    Satisfied source (fun i => evalLinear values (mapping i)) := by
  intro gate member
  exact gate_substitution_sound values mapping gate (holds _ (included gate member))

theorem byte_component {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied shape values) :
    Satisfied byteShape (fun i => evalLinear values (byteMap i)) := by
  apply substituted_satisfied byteShape shape byteMap values _ holds
  intro gate member
  apply List.mem_of_mem_take
  rw [byte_prefix]
  exact List.mem_map.mpr ⟨gate, member, rfl⟩

theorem slot_component {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied shape values) :
    Satisfied SlotShape.compileShape (fun i => evalLinear values (slotMap i)) := by
  apply substituted_satisfied SlotShape.compileShape shape slotMap values _ holds
  intro gate member
  apply List.mem_of_mem_drop
  apply List.mem_of_mem_take
  rw [slot_prefix]
  exact List.mem_map.mpr ⟨gate, member, rfl⟩

noncomputable def projection {F : Type} [CommRing F] (values : Nat → F)
    (mapping : Nat → Linear) (size : Nat) (positive : 0 < size) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin size => evalLinear values (mapping i.val)) positive

theorem projection_value {F : Type} [CommRing F] (values : Nat → F)
    (mapping : Nat → Linear) (size : Nat) (positive : 0 < size) (i : Nat) (bound : i < size) :
    (projection values mapping size positive).get i = evalLinear values (mapping i) :=
  Lean.RArray.get_ofFn _ positive ⟨i, bound⟩

theorem eval_congr {F : Type} [CommRing F] (a b : Nat → F) (linear : Linear)
    (same : ∀ term ∈ linear, a term.1 = b term.1) : evalLinear a linear = evalLinear b linear := by
  induction linear with
  | nil => rfl
  | cons term rest ih =>
    rcases term with ⟨wire, coefficient⟩
    have first := same (wire, coefficient) (by simp)
    have tail := ih (fun term member => same term (by simp [member]))
    change (coefficient : F) * a wire + evalLinear a rest =
      (coefficient : F) * b wire + evalLinear b rest
    rw [first, tail]

theorem bounded_satisfied {F : Type} [CommRing F] (source : Shape)
    (checked : bounded source = true) (a b : Nat → F)
    (same : ∀ i, i < source.wires → a i = b i) (holds : Satisfied source a) : Satisfied source b := by
  intro gate member
  unfold bounded at checked
  rw [← Array.all_toList] at checked
  have sides := List.all_eq_true.mp checked gate member
  have equalSide (side : Linear) (inside : side ∈ [gate.a, gate.b, gate.c]) :
      evalLinear a side = evalLinear b side := by
    apply eval_congr
    intro term termMember
    have terms := List.all_eq_true.mp sides side inside
    exact same term.1 (of_decide_eq_true (List.all_eq_true.mp terms term termMember))
  have ha := equalSide gate.a (by simp)
  have hb := equalSide gate.b (by simp)
  have hc := equalSide gate.c (by simp)
  have equation := holds gate member
  change evalLinear a gate.a * evalLinear a gate.b = evalLinear a gate.c at equation
  change evalLinear b gate.a * evalLinear b gate.b = evalLinear b gate.c
  rw [← ha, ← hb, ← hc]
  exact equation

noncomputable def byteContext {F : Type} [CommRing F] (values : Nat → F) : Lean.RArray F :=
  projection values byteMap 6096 (by decide)

noncomputable def slotContext {F : Type} [CommRing F] (values : Nat → F) : Lean.RArray F :=
  projection values slotMap 11899 (by decide)

theorem byte_context_satisfied {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied shape values) : Satisfied byteShape (byteContext values).get := by
  apply bounded_satisfied byteShape sources_bounded.1 _ _ _ (byte_component values holds)
  intro i bound
  have size : byteShape.wires = 6096 := by native_decide
  exact (projection_value values byteMap 6096 (by decide) i (by omega)).symm

theorem slot_context_satisfied {F : Type} [CommRing F] (values : Nat → F)
    (holds : Satisfied shape values) : Satisfied SlotShape.compileShape (slotContext values).get := by
  apply bounded_satisfied SlotShape.compileShape sources_bounded.2 _ _ _ (slot_component values holds)
  intro i bound
  have size := SlotShape.compile_dimensions.1
  exact (projection_value values slotMap 11899 (by decide) i (by omega)).symm

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem public_maps : byteMap 0 = constant 1 ∧ slotMap 0 = constant 1 ∧
    (∀ i : Fin 7, byteMap (1+i.val) = [(1+i.val, 1)]) ∧
    (∀ i : Fin 5, slotMap (6+i.val) = [(8+i.val, 1)]) := by native_decide

theorem projected_one {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) :
    (byteContext values).get 0 = 1 ∧ (slotContext values).get 0 = 1 := by
  have value : evalLinear values (constant 1) = 1 := by
    simp [evalLinear, constant, interpretLinear, R1CS.eval, one, Ring.intCast_one,
      Semiring.one_mul, Semiring.add_zero]
  constructor
  · rw [byteContext, projection_value values byteMap 6096 (by decide) 0 (by decide), public_maps.1]
    exact value
  · rw [slotContext, projection_value values slotMap 11899 (by decide) 0 (by decide), public_maps.2.1]
    exact value

def PublicRaw {F : Type} [CommRing F] (values : Nat → F) (wasm : List (Fin 256)) : Prop :=
  values 1 = (wasm.length : F) ∧ ∀ i : Fin 6,
    values (2+i.val) = R1CS.packedField (PublicBinding.chunkBytes (BinarySoundness.paddedBytes wasm) i)

def PublicNative {F : Type} [CommRing F] (values : Nat → F) (native : List (Fin 256)) : Prop :=
  ∀ i : Fin 5, values (8+i.val) = R1CS.packedField (SlotNativeBinding.chunk native i.val)

theorem projected_raw {F : Type} [CommRing F] (values : Nat → F) (wasm : List (Fin 256))
    (inputs : PublicRaw values wasm) : BinarySoundness.PublicInputsFor (byteContext values) wasm := by
  have get (i : Fin 7) : (byteContext values).get (1+i.val) = values (1+i.val) := by
    rw [byteContext, projection_value values byteMap 6096 (by decide) (1+i.val) (by omega), public_maps.2.2.1 i]
    simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  constructor
  · exact (get ⟨0, by decide⟩).trans inputs.1
  · intro i
    have value := get ⟨1+i.val, by omega⟩
    have same : (byteContext values).get (2+i.val) = values (2+i.val) := by
      simpa only [show 1+(1+i.val) = 2+i.val by omega] using value
    exact same.trans (inputs.2 i)

theorem projected_native {F : Type} [CommRing F] (values : Nat → F) (native : List (Fin 256))
    (inputs : PublicNative values native) : SlotNativeBinding.PublicNative (slotContext values) native := by
  intro i
  rw [slotContext, projection_value values slotMap 11899 (by decide) (6+i.val) (by omega), public_maps.2.2.2 i]
  simpa [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one,
    Semiring.one_mul, Semiring.add_zero] using inputs i

theorem raw_binary_valid {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm : List (Fin 256)) (length : 36 ≤ wasm.length ∧ wasm.length ≤ 156)
    (one : values 0 = 1) (inputs : PublicRaw values wasm) (holds : Satisfied shape values) :
    BinarySoundness.SupportedWasmBinary wasm :=
  BinarySoundness.binary_soundness (byteContext values) wasm length (projected_one values one).1
    (projected_raw values wasm inputs) (byte_context_satisfied values holds)

theorem native_is_checked_compilation {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (native : List (Fin 256)) (length : native.length = 144)
    (one : values 0 = 1) (inputs : PublicNative values native) (holds : Satisfied shape values) :
    ∃ ops : List Op, ops.length = 16 ∧ checkProgram ops 0 = some 1 ∧
      native = (Rv32Compiler.compileBytes ops).map SlotNativeBinding.asByte :=
  SlotNativeBinding.native_artifact_sound (slotContext values) native length (projected_one values one).2
    (projected_native values native inputs) (slot_context_satisfied values holds)

#print axioms raw_binary_valid
#print axioms native_is_checked_compilation

end ZkBuild.ByteCompileComposition
