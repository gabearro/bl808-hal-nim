import SlotMatrix

namespace ZkBuild.SlotTrace

open Lean.Grind CircuitShape SlotMatrix
open FullMatrix (evalLinear sameGate)
attribute [local instance] Ring.intCast Semiring.natCast

def infoAt (index : Fin 16) : RowInfo := SlotShape.compileShape.rows[index.val]?.getD default

def adjacencyCertificate : Bool :=
  (infoAt ⟨0, by decide⟩).inputs.toList ==
    (List.range 9).map (fun i => constant (if i = 0 then 1 else 0)) &&
  (List.range 15).all (fun i =>
    (SlotShape.compileShape.rows[i+1]?.getD default).inputs.toList ==
      (SlotShape.compileShape.rows[i]?.getD default).outputs.toList.take 9)

theorem adjacency_checked : adjacencyCertificate = true := by native_decide

theorem info_member (index : Fin 16) : infoAt index ∈ SlotShape.compileShape.rows.toList := by
  have bound : index.val < SlotShape.compileShape.rows.size := by
    rw [SlotShape.compile_dimensions.2.2.2]
    exact index.isLt
  unfold infoAt
  rw [Array.getElem?_eq_getElem bound]
  exact Array.getElem_mem_toList bound

theorem first_inputs : (infoAt ⟨0, by decide⟩).inputs.toList =
    (List.range 9).map (fun i => constant (if i = 0 then 1 else 0)) := by
  exact eq_of_beq (Bool.and_eq_true_iff.mp adjacency_checked).1

theorem adjacent_inputs (index : Fin 15) :
    (infoAt ⟨index.val+1, by have := index.isLt; omega⟩).inputs.toList =
      (infoAt ⟨index.val, by have := index.isLt; omega⟩).outputs.toList.take 9 := by
  have checked := List.all_eq_true.mp (Bool.and_eq_true_iff.mp adjacency_checked).2
    index.val (List.mem_range.mpr index.isLt)
  exact eq_of_beq checked

def depthVector {F : Type} [CommRing F] (height : Nat) : List F :=
  (List.finRange 9).map fun i => if i.val = height then 1 else 0

def inputDepths {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : List F :=
  info.inputs.toList.map (evalLinear ctx.get)

def outputDepths {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : List F :=
  (info.outputs.toList.take 9).map (evalLinear ctx.get)

theorem context_depth {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (i : Nat) (bound : i < 9) :
    (rowContext ctx info).get i = evalLinear ctx.get (lookupLinear info.inputs i) := by
  rw [← context_sources ctx info i (by omega)]
  have lower : i < 51 := by omega
  have nonzero : i+1 ≠ 0 := by omega
  have upper : i+1 < 10 := by omega
  simp only [localValues, SlotRow.sourceWire, lower, ite_true, rowWires, nonzero, ite_false,
    upper, Nat.add_sub_cancel]

theorem input_context {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (size : info.inputs.size = 9) :
    inputDepths ctx info = (List.finRange 9).map fun i => (rowContext ctx info).get i.val := by
  apply List.ext_getElem
  · simp [inputDepths, size]
  · intro i left right
    have bound : i < 9 := by simpa [inputDepths, size] using left
    have arrayBound : i < info.inputs.size := by omega
    simp only [inputDepths, List.getElem_map, Array.getElem_toList, List.getElem_finRange, Fin.val_cast]
    rw [context_depth ctx info i bound]
    simp only [lookupLinear, Array.getElem?_eq_getElem arrayBound, Option.getD_some]

theorem encoded_input {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (size : info.inputs.size = 9) (height : Nat) (encoded : inputDepths ctx info = depthVector height) :
    ∀ i, i < 9 → (rowContext ctx info).get i = if i = height then 1 else 0 := by
  rw [input_context ctx info size] at encoded
  intro i bound
  have point := congrArg (fun xs : List F => xs[i]?) encoded
  simpa [depthVector, List.getElem?_eq_getElem, bound] using point

theorem depth_encoding {F : Type} [CommRing F] (kind : Fin 10) (height : Fin 9)
    (valid : SlotShape.valid kind.val height.val = true) :
    (SlotRow.depthValues kind height).map (fun value : Nat => (value : F)) =
      depthVector (SlotShape.nextDepth kind.val height.val) := by
  rw [SlotRow.depthValues, List.map_map, SlotRow.range_values]
  unfold depthVector
  apply List.map_congr_left
  intro i _
  by_cases same : SlotShape.nextDepth kind.val height.val = i.val
  · simp [valid, same, Semiring.natCast_one]
  · have reverse : i.val ≠ SlotShape.nextDepth kind.val height.val := Ne.symm same
    simp [valid, same, reverse, Semiring.natCast_zero]

theorem output_prefix {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (equations : info.outputs.toList.map (evalLinear ctx.get) =
      SlotRow.outputs.map (RowSoundness.evalField (rowContext ctx info).get)) :
    outputDepths ctx info = SlotRow.nextDepths.map (RowSoundness.evalField (rowContext ctx info).get) := by
  have taken := congrArg (List.take 9) equations
  have count : (SlotRow.nextDepths.map (RowSoundness.evalField (rowContext ctx info).get)).length = 9 := by
    simp [SlotRow.nextDepths]
  simpa only [outputDepths, List.map_take, SlotRow.outputs, List.map_append, List.append_assoc,
    List.take_append_of_le_length (show 9 ≤ (SlotRow.nextDepths.map (RowSoundness.evalField (rowContext ctx info).get)).length by omega),
    List.take_of_length_le (show (SlotRow.nextDepths.map (RowSoundness.evalField (rowContext ctx info).get)).length ≤ 9 by omega)] using taken

theorem next_depth_bounded : ∀ (kind : Fin 10) (height : Fin 9),
    SlotShape.valid kind.val height.val = true → SlotShape.nextDepth kind.val height.val < 9 := by native_decide

theorem step_trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (index : Fin 16) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) (height : Fin 9)
    (encoded : inputDepths ctx (infoAt index) = depthVector height.val) :
    ∃ (kind : Fin 10) (next : Fin 9),
      (∀ i, i < 10 → (rowContext ctx (infoAt index)).get (9+i) = if i = kind.val then 1 else 0) ∧
      SlotShape.valid kind.val height.val = true ∧ next.val = SlotShape.nextDepth kind.val height.val ∧
      outputDepths ctx (infoAt index) = depthVector next.val := by
  obtain ⟨kind, selected, valid, nextValues⟩ := full_row_transition ctx (infoAt index) (info_member index)
    one holds height (encoded_input ctx _ (instance_checked _ (info_member index)).1 height.val encoded)
  let next : Fin 9 := ⟨SlotShape.nextDepth kind.val height.val, next_depth_bounded kind height valid⟩
  refine ⟨kind, next, selected, valid, rfl, ?_⟩
  rw [output_prefix ctx _ (full_row_equations ctx _ (info_member index) one holds).2, nextValues, depth_encoding kind height valid]

theorem initial_depth {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1) :
    inputDepths ctx (infoAt ⟨0, by decide⟩) = depthVector 0 := by
  rw [inputDepths, first_inputs]
  simp [depthVector, List.map_map, evalLinear, interpretLinear, R1CS.eval, constant, one,
    SlotRow.range_values]
  intro i
  split <;> simp_all [Ring.intCast_one, Ring.intCast_zero, Semiring.mul_one, Semiring.add_zero]

def finalGate : Gate :=
  ⟨sub (lookupLinear (infoAt ⟨15, by decide⟩).outputs 1) (constant 1), constant 1, constant 0⟩

theorem final_gate_checked :
    (match SlotShape.compileShape.gates[11936]? with
    | some actual => sameGate finalGate actual
    | none => false) = true := by native_decide

theorem eval_constant {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (value : Int) :
    evalLinear ctx.get (constant value) = (value : F) := by
  simp [evalLinear, interpretLinear, R1CS.eval, constant, one, Semiring.mul_one, Semiring.add_zero]

theorem final_depth_value {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) :
    evalLinear ctx.get (lookupLinear (infoAt ⟨15, by decide⟩).outputs 1) = 1 := by
  have checked := final_gate_checked
  cases found : SlotShape.compileShape.gates[11936]? with
  | none => simp [found] at checked
  | some actual =>
    have actualHolds := holds actual (by simpa using Array.mem_of_getElem? found)
    have equation := FullMatrix.same_gate_sound ctx finalGate actual (by simpa [found] using checked) actualHolds
    change evalLinear ctx.get (sub (lookupLinear (infoAt ⟨15, by decide⟩).outputs 1) (constant 1)) *
      evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0) at equation
    simp only [sub, FullMatrix.eval_append, FullMatrix.eval_scale, eval_constant ctx one,
      Ring.intCast_one, Ring.intCast_zero, Ring.intCast_neg] at equation
    grind

theorem final_height_one {F : Type} [Field F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) (height : Fin 9)
    (encoded : outputDepths ctx (infoAt ⟨15, by decide⟩) = depthVector height.val) : height.val = 1 := by
  have point := congrArg (fun xs : List F => (xs[1]?).getD 0) encoded
  have value : evalLinear ctx.get (lookupLinear (infoAt ⟨15, by decide⟩).outputs 1) =
      if (1 : Nat) = height.val then 1 else 0 := by
    have simplified : ((infoAt ⟨15, by decide⟩).outputs[1]?.map (evalLinear ctx.get)).getD 0 =
        if (1 : Nat) = height.val then 1 else 0 := by
      simpa [outputDepths, depthVector] using point
    have mapped (option : Option Linear) : (option.map (evalLinear ctx.get)).getD 0 =
        evalLinear ctx.get (option.getD []) := by
      cases option <;> simp [evalLinear, interpretLinear, R1CS.eval]
    rw [mapped] at simplified
    exact simplified
  rw [final_depth_value ctx one holds] at value
  by_cases same : height.val = 1
  · exact same
  · have reverse : ¬(1 : Nat) = height.val := Ne.symm same
    simp only [reverse, ite_false] at value
    exact False.elim (Field.zero_ne_one value.symm)

noncomputable def AtDepth {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) (height : Fin 9) : Prop :=
  if bound : index < 16 then inputDepths ctx (infoAt ⟨index, bound⟩) = depthVector height.val
  else outputDepths ctx (infoAt ⟨15, by decide⟩) = depthVector height.val

noncomputable def SelectorAt {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) (kind : Fin 10) : Prop :=
  if bound : index < 16 then
    ∀ i, i < 10 → (rowContext ctx (infoAt ⟨index, bound⟩)).get (9+i) = if i = kind.val then 1 else 0
  else False

noncomputable def SelectedProgram {F : Type} [CommRing F] (ctx : Lean.RArray F) : Nat → List (Fin 10) → Prop
  | _, [] => True
  | index, kind :: rest => SelectorAt ctx index kind ∧ SelectedProgram ctx (index+1) rest

def checkKinds : List (Fin 10) → Nat → Option Nat
  | [], height => some height
  | kind :: rest, height =>
    if SlotShape.valid kind.val height then checkKinds rest (SlotShape.nextDepth kind.val height) else none

theorem advance_depth {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat) (bound : index < 16)
    (height : Fin 9) (output : outputDepths ctx (infoAt ⟨index, bound⟩) = depthVector height.val) :
    AtDepth ctx (index+1) height := by
  by_cases next : index+1 < 16
  · have before : index < 15 := by omega
    have same : inputDepths ctx (infoAt ⟨index+1, next⟩) = outputDepths ctx (infoAt ⟨index, bound⟩) := by
      unfold inputDepths outputDepths
      rw [adjacent_inputs ⟨index, before⟩]
    simpa only [AtDepth, dite_eq_left next] using same.trans output
  · have last : index = 15 := by omega
    subst index
    simpa only [AtDepth, dite_eq_right (by decide : ¬16 < 16)] using output

theorem walk_trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get)
    (remaining : Nat) : ∀ (start : Nat) (_range : start+remaining = 16) (height : Fin 9), AtDepth ctx start height →
    ∃ (kinds : List (Fin 10)) (final : Fin 9), kinds.length = remaining ∧
      checkKinds kinds height.val = some final.val ∧ AtDepth ctx 16 final ∧ SelectedProgram ctx start kinds := by
  induction remaining with
  | zero =>
    intro start range height encoded
    have same : start = 16 := by omega
    exact ⟨[], height, rfl, rfl, by simpa [same] using encoded, trivial⟩
  | succ remaining ih =>
    intro start range height encoded
    have bound : start < 16 := by omega
    have input : inputDepths ctx (infoAt ⟨start, bound⟩) = depthVector height.val := by
      simpa only [AtDepth, dite_eq_left bound] using encoded
    obtain ⟨kind, next, selected, valid, nextValue, output⟩ := step_trace ctx ⟨start, bound⟩ one holds height input
    obtain ⟨kinds, final, length, checked, last, selectedTail⟩ :=
      ih (start+1) (by omega) next (advance_depth ctx start bound next output)
    refine ⟨kind :: kinds, final, by simp [length], ?_, last, ?_⟩
    · simpa only [checkKinds, valid, ite_true, ← nextValue] using checked
    · exact ⟨by simpa only [SelectorAt, dite_eq_left bound] using selected, selectedTail⟩

theorem full_stack_trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ kinds : List (Fin 10), kinds.length = 16 ∧ checkKinds kinds 0 = some 1 ∧ SelectedProgram ctx 0 kinds := by
  have initial : AtDepth ctx 0 ⟨0, by decide⟩ := by
    simpa [AtDepth] using initial_depth ctx one
  obtain ⟨kinds, final, length, checked, last, selected⟩ := walk_trace ctx one holds 16 0 rfl ⟨0, by decide⟩ initial
  have finalEncoding : outputDepths ctx (infoAt ⟨15, by decide⟩) = depthVector final.val := by
    simpa [AtDepth] using last
  have finished := final_height_one ctx one holds final finalEncoding
  exact ⟨kinds, length, by simpa only [finished] using checked, selected⟩

#print axioms step_trace
#print axioms initial_depth
#print axioms full_stack_trace

end ZkBuild.SlotTrace
