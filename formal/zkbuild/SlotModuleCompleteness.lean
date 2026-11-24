import SlotWitness

namespace ZkBuild.SlotModuleCompleteness

open Lean.Grind CircuitShape FullMatrix SlotWitness SlotNativeBinding
attribute [local instance] Ring.intCast Semiring.natCast

def PrivateWire (wire : Nat) : Prop := wire = 0 ∨ (11 ≤ wire ∧ wire < 11899)
instance (wire : Nat) : Decidable (PrivateWire wire) := by unfold PrivateWire; infer_instance
def inputFree (linear : Linear) : Bool := linear.all (fun term => decide (PrivateWire term.1))

theorem wasm_inputs_free : SlotWasm.wasmLinears.all inputFree = true := by native_decide
theorem native_inputs_free : SlotEmission.nativeLinears.all inputFree = true := by native_decide

theorem private_value {F : Type} [CommRing F] (inputs : Fin 10 → F) (actions : Actions) (heights : Heights)
    (wire : Nat) (privateWire : PrivateWire wire) :
    (moduleContext inputs actions heights).get wire = moduleValues (fun _ => (0 : F)) actions heights wire := by
  rcases privateWire with zero | bounds
  · subst wire
    rw [module_one]
    rfl
  · rw [module_entry inputs actions heights wire bounds.2]
    have nonzero : wire ≠ 0 := by omega
    have notInput : ¬wire < 11 := by omega
    simp only [moduleValues, nonzero, ite_false, notInput, dite_false]

theorem private_linear {F : Type} [CommRing F] (inputs : Fin 10 → F) (actions : Actions) (heights : Heights)
    (linear : Linear) (bounded : inputFree linear = true) :
    evalLinear (moduleContext inputs actions heights).get linear =
      evalLinear (moduleValues (fun _ => (0 : F)) actions heights) linear := by
  induction linear with
  | nil => rfl
  | cons term rest ih =>
    have properties : PrivateWire term.1 ∧ inputFree rest = true := by simpa [inputFree] using bounded
    simp only [evalLinear, interpretLinear, R1CS.eval, List.map_cons]
    rw [private_value inputs actions heights term.1 properties.1]
    exact congrArg (fun restValue => (term.2 : F) * moduleValues (fun _ => (0 : F)) actions heights term.1 + restValue)
      (ih properties.2)

theorem artifact_values {F : Type} [CommRing F] (inputs : Fin 10 → F) (actions : Actions) (heights : Heights)
    (linears : List Linear) (bounded : linears.all inputFree = true) :
    linears.map (evalLinear (moduleContext inputs actions heights).get) =
      linears.map (evalLinear (moduleValues (fun _ => (0 : F)) actions heights)) := by
  apply List.map_congr_left
  intro linear member
  exact private_linear inputs actions heights linear (List.all_eq_true.mp bounded linear member)

def publicValues {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 10) : F :=
  if i.val < 5 then packFields (chunk (SlotWasm.wasmLinears.map (evalLinear (moduleValues (fun _ => (0 : F)) actions heights))) i.val)
  else packFields (chunk (SlotEmission.nativeLinears.map (evalLinear (moduleValues (fun _ => (0 : F)) actions heights))) (i.val-5))

def cachedPublicValues {F : Type} [CommRing F] (rows : Array (List Int)) (i : Fin 10) : F :=
  if i.val < 5 then packFields (chunk (SlotWasm.wasmLinears.map (evalLinear (cachedValues (fun _ => (0 : F)) rows))) i.val)
  else packFields (chunk (SlotEmission.nativeLinears.map (evalLinear (cachedValues (fun _ => (0 : F)) rows))) (i.val-5))

theorem cached_public_eq {F : Type} [CommRing F] (actions : Actions) (heights : Heights) :
    cachedPublicValues (F := F) (rowCache actions heights) = publicValues actions heights := by
  have valuesEq : cachedValues (fun _ => (0 : F)) (rowCache actions heights) = moduleValues (fun _ => (0 : F)) actions heights := by
    funext wire
    exact cached_values_eq _ actions heights wire
  funext i
  unfold cachedPublicValues publicValues
  rw [valuesEq]

noncomputable def context {F : Type} [CommRing F] (actions : Actions) (heights : Heights) : Lean.RArray F :=
  moduleContext (publicValues actions heights) actions heights

theorem wasm_packed {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 5) :
    evalLinear (context (F := F) actions heights).get (packLinear (chunk SlotWasm.wasmLinears i.val)) =
      (context actions heights).get (1+i.val) := by
  unfold context
  rw [pack_linear_value, chunk_map, artifact_values _ actions heights _ wasm_inputs_free]
  have value := module_public (publicValues (F := F) actions heights) actions heights ⟨i.val, by have := i.isLt; omega⟩
  simpa only [context, publicValues, dite_eq_left i.isLt, ite_true, i.isLt] using value.symm

theorem native_packed {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 5) :
    evalLinear (context (F := F) actions heights).get (packLinear (chunk SlotEmission.nativeLinears i.val)) =
      (context actions heights).get (6+i.val) := by
  unfold context
  rw [pack_linear_value, chunk_map, artifact_values _ actions heights _ native_inputs_free]
  have before : ¬5+i.val < 5 := by omega
  have value := module_public (publicValues (F := F) actions heights) actions heights ⟨5+i.val, by have := i.isLt; omega⟩
  simpa only [context, publicValues, before, ite_false, Nat.add_sub_cancel_left, show 1+(5+i.val) = 6+i.val by omega] using value.symm

theorem equal_gate {F : Type} [CommRing F] (ctx : Lean.RArray F) (a b : Linear)
    (one : ctx.get 0 = 1) (equal : evalLinear ctx.get a = evalLinear ctx.get b) :
    R1CS.Holds ctx.get (interpretGate ⟨sub a b, constant 1, constant 0⟩) := by
  change evalLinear ctx.get (sub a b) * evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0)
  simp only [sub, eval_append, eval_scale, SlotTrace.eval_constant ctx one,
    Ring.intCast_neg, Ring.intCast_one, Ring.intCast_zero]
  rw [equal]
  grind

theorem wasm_gate {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 5)
    (actual : Gate) (found : SlotShape.compileShape.gates[11937+i.val]? = some actual) :
    R1CS.Holds (context (F := F) actions heights).get (interpretGate actual) := by
  have matched := SlotCompilation.wasm_packing_gates_match i
  rw [found] at matched
  apply BodyCompleteness.same_gate_complete _ (SlotCompilation.wasmPackingGate i) actual matched
  apply equal_gate (context (F := F) actions heights) _ _ (module_one _ actions heights)
  have packed := wasm_packed (F := F) actions heights i
  have wireValue : evalLinear (context (F := F) actions heights).get [(1+i.val, 1)] = (context (F := F) actions heights).get (1+i.val) := by
    simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  rw [wireValue]
  exact packed

theorem native_gate {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (i : Fin 5)
    (actual : Gate) (found : SlotShape.compileShape.gates[11942+i.val]? = some actual) :
    R1CS.Holds (context (F := F) actions heights).get (interpretGate actual) := by
  have matched := packing_gates_match i
  rw [found] at matched
  apply BodyCompleteness.same_gate_complete _ (packingGate i) actual matched
  apply equal_gate (context (F := F) actions heights) _ _ (module_one _ actions heights)
  have packed := native_packed (F := F) actions heights i
  have wireValue : evalLinear (context (F := F) actions heights).get [(6+i.val, 1)] = (context (F := F) actions heights).get (6+i.val) := by
    simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  rw [wireValue]
  exact packed

theorem final_depth {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (trace : ValidTrace actions heights) :
    evalLinear (context (F := F) actions heights).get
      (lookupLinear (SlotTrace.infoAt ⟨15, by decide⟩).outputs 1) = 1 := by
  have last := (constructed_all_rows (publicValues (F := F) actions heights) actions heights trace).2.1
  have point := congrArg (fun xs : List F => (xs[1]?).getD 0) last
  have simplified : ((SlotTrace.infoAt ⟨15, by decide⟩).outputs[1]?.map (evalLinear (context (F := F) actions heights).get)).getD (0 : F) = 1 := by
    simpa [SlotTrace.outputDepths, SlotTrace.depthVector, context] using point
  have mapped (option : Option Linear) : (option.map (evalLinear (context (F := F) actions heights).get)).getD (0 : F) =
      evalLinear (context (F := F) actions heights).get (option.getD []) := by
    cases option <;> simp [evalLinear, interpretLinear, R1CS.eval]
  rw [mapped] at simplified
  exact simplified

theorem final_gate {F : Type} [CommRing F] (actions : Actions) (heights : Heights) (trace : ValidTrace actions heights)
    (actual : Gate) (found : SlotShape.compileShape.gates[11936]? = some actual) :
    R1CS.Holds (context (F := F) actions heights).get (interpretGate actual) := by
  have matched := SlotTrace.final_gate_checked
  rw [found] at matched
  apply BodyCompleteness.same_gate_complete _ SlotTrace.finalGate actual matched
  apply equal_gate (context (F := F) actions heights) _ _ (module_one _ actions heights)
  rw [SlotTrace.eval_constant (context (F := F) actions heights) (module_one _ actions heights) 1, Ring.intCast_one]
  exact final_depth actions heights trace

theorem row_positions : ∀ i : Fin 16, (SlotTrace.infoAt i).gateStart = i.val*746 := by native_decide

theorem constructed_matrix {F : Type} [CommRing F] (actions : Actions) (heights : Heights)
    (trace : ValidTrace actions heights) : Satisfied SlotShape.compileShape (context (F := F) actions heights).get := by
  have rows := (constructed_all_rows (publicValues (F := F) actions heights) actions heights trace).1
  intro gate member
  have arrayMember : gate ∈ SlotShape.compileShape.gates := by simpa using member
  obtain ⟨index, found⟩ := Array.getElem?_of_mem arrayMember
  have limit : index < 11947 := by
    have bound := (Array.getElem?_eq_some_iff.mp found).1
    simpa only [SlotShape.compile_dimensions.2.2.1] using bound
  by_cases row : index < 11936
  · let i : Fin 16 := ⟨index/746, by omega⟩
    let j : Fin 746 := ⟨index%746, Nat.mod_lt _ (by decide)⟩
    have position : (SlotTrace.infoAt i).gateStart+j.val = index := by rw [row_positions]; dsimp [i, j]; omega
    apply rows i j gate
    rw [position]
    exact found
  · by_cases final : index = 11936
    · exact final_gate actions heights trace gate (by simpa [final] using found)
    · by_cases wasm : index < 11942
      · let i : Fin 5 := ⟨index-11937, by omega⟩
        apply wasm_gate actions heights i gate
        have position : 11937+i.val = index := by dsimp [i]; omega
        simpa only [position] using found
      · let i : Fin 5 := ⟨index-11942, by omega⟩
        apply native_gate actions heights i gate
        have position : 11942+i.val = index := by dsimp [i]; omega
        simpa only [position] using found

#print axioms constructed_matrix

end ZkBuild.SlotModuleCompleteness
