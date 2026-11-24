import SlotRow
import SlotRowSemantics
import SlotImmediate
import FullMatrix

namespace ZkBuild.SlotMatrix

open Lean.Grind CircuitShape
open FullMatrix (evalLinear substitute substituteGate sameGate sameLinear)
attribute [local instance] Ring.intCast Semiring.natCast

def rowWires (info : RowInfo) (wire : Nat) : Linear :=
  if wire = 0 then constant 1
  else if wire < 10 then lookupLinear info.inputs (wire-1)
  else [(info.wireStart + wire - 10, 1)]

def gateChecks (info : RowInfo) : Bool :=
  (List.range 746).all fun j =>
    match SlotRow.rowBuild.2.gates[j]?, SlotShape.compileShape.gates[info.gateStart+j]? with
    | some template, some actual => sameGate (substituteGate (rowWires info) template) actual
    | _, _ => false

def outputChecks (info : RowInfo) : Bool :=
  (List.range 23).all fun j =>
    match SlotRow.outputLinears[j]?, info.outputs[j]? with
    | some template, some actual => sameLinear (substitute (rowWires info) template) actual
    | _, _ => false

def instanceChecks (info : RowInfo) : Bool :=
  info.inputs.size == 9 && info.outputs.size == 23 && gateChecks info && outputChecks info

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem all_instances : SlotShape.compileShape.rows.all instanceChecks = true := by native_decide

theorem template_sizes : SlotRow.rowBuild.2.gates.size = 746 ∧ SlotRow.outputLinears.length = 23 := by native_decide

theorem instance_checked (info : RowInfo) (member : info ∈ SlotShape.compileShape.rows.toList) :
    info.inputs.size = 9 ∧ info.outputs.size = 23 ∧ gateChecks info = true ∧ outputChecks info = true := by
  have checked := List.all_eq_true.mp (by simpa using all_instances) info member
  simpa [instanceChecks, Bool.and_eq_true_iff, and_assoc] using checked

noncomputable def localValues {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : Nat → F :=
  fun i => evalLinear ctx.get (rowWires info i)

noncomputable def rowContext {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 72 => localValues ctx info (SlotRow.sourceWire i.val)) (by decide)

theorem context_sources {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) :
    ∀ i, i < 72 → localValues ctx info (SlotRow.sourceWire i) = (rowContext ctx info).get i := by
  intro i bound
  exact (Lean.RArray.get_ofFn (fun j : Fin 72 => localValues ctx info (SlotRow.sourceWire j.val))
    (by decide) ⟨i, bound⟩).symm

theorem row_satisfied {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (member : info ∈ SlotShape.compileShape.rows.toList) (holds : Satisfied SlotShape.compileShape ctx.get) :
    Satisfied SlotRow.rowBuild.2 (localValues ctx info) := by
  intro gate gateMember
  have arrayMember : gate ∈ SlotRow.rowBuild.2.gates := by simpa using gateMember
  obtain ⟨j, found⟩ := Array.getElem?_of_mem arrayMember
  have bound := (Array.getElem?_eq_some_iff.mp found).1
  have small : j < 746 := by simpa [template_sizes.1] using bound
  have checked := List.all_eq_true.mp (instance_checked info member).2.2.1 j (List.mem_range.mpr small)
  unfold gateChecks at checked
  rw [found] at checked
  cases actualFound : SlotShape.compileShape.gates[info.gateStart+j]? with
  | none => simp [actualFound] at checked
  | some actual =>
    have same : sameGate (substituteGate (rowWires info) gate) actual = true := by simpa [actualFound] using checked
    apply FullMatrix.gate_substitution_sound
    apply FullMatrix.same_gate_sound ctx _ actual same
    exact holds actual (by simpa using Array.mem_of_getElem? actualFound)

theorem row_outputs {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (member : info ∈ SlotShape.compileShape.rows.toList) :
    SlotRow.outputLinears.map (evalLinear (localValues ctx info)) = info.outputs.toList.map (evalLinear ctx.get) := by
  have checked := instance_checked info member
  apply List.ext_getElem
  · simp [template_sizes.2, checked.2.1]
  · intro j leftBound rightBound
    have bound : j < 23 := by simpa [template_sizes.2] using leftBound
    have templateBound : j < SlotRow.outputLinears.length := by simpa [template_sizes.2] using bound
    have outputBound : j < info.outputs.size := by omega
    have comparison := List.all_eq_true.mp checked.2.2.2 j (List.mem_range.mpr bound)
    unfold outputChecks at comparison
    simp only [List.getElem?_eq_getElem templateBound, Array.getElem?_eq_getElem outputBound] at comparison
    simp only [List.getElem_map, Array.getElem_toList]
    unfold localValues
    rw [← FullMatrix.eval_substitute]
    exact FullMatrix.same_linear_sound ctx _ _ comparison

theorem full_row_equations {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (member : info ∈ SlotShape.compileShape.rows.toList) (one : ctx.get 0 = 1)
    (holds : Satisfied SlotShape.compileShape ctx.get) :
    SlotRow.FieldHolds (rowContext ctx info).get ∧
      info.outputs.toList.map (evalLinear ctx.get) = SlotRow.outputs.map (RowSoundness.evalField (rowContext ctx info).get) := by
  have localOne : localValues ctx info 0 = 1 := by
    simp [localValues, rowWires, constant, evalLinear, interpretLinear, R1CS.eval,
      one, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  obtain ⟨equations, outputs⟩ := SlotRow.matrix_implies_equations (rowContext ctx info) (localValues ctx info)
    localOne (context_sources ctx info) (row_satisfied ctx info member holds)
  exact ⟨equations, (row_outputs ctx info member).symm.trans outputs⟩

theorem full_row_transition {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (info : RowInfo) (member : info ∈ SlotShape.compileShape.rows.toList)
    (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) (depth : Fin 9)
    (prior : ∀ i, i < 9 → (rowContext ctx info).get i = if i = depth.val then 1 else 0) :
    ∃ kind : Fin 10,
      (∀ i, i < 10 → (rowContext ctx info).get (9+i) = if i = kind.val then 1 else 0) ∧
      SlotShape.valid kind.val depth.val = true ∧
      SlotRow.nextDepths.map (RowSoundness.evalField (rowContext ctx info).get) =
        (SlotRow.depthValues kind depth).map (fun value : Nat => (value : F)) := by
  have equations := (full_row_equations ctx info member one holds).1
  obtain ⟨kind, selected⟩ := SlotRow.selectors_determined (rowContext ctx info).get equations
  have selectedNat (i : Nat) (bound : i < 10) :
      (rowContext ctx info).get (9+i) = if i = kind.val then 1 else 0 := by
    simpa only [Fin.ext_iff] using selected ⟨i, bound⟩
  exact ⟨kind, selectedNat, SlotRow.valid_transition (rowContext ctx info) kind depth prior selectedNat equations,
    SlotRow.depths_determined (rowContext ctx info) kind depth prior selectedNat⟩

-- The recovered immediate is determined by the satisfying assignment, and
-- its LUI bits/carry are forced to agree with the verified RV32 emitter.
-- No assumption about the witness generator is used here.
theorem full_row_immediate {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (info : RowInfo) (member : info ∈ SlotShape.compileShape.rows.toList)
    (one : ctx.get 0 = 1) (holds : Satisfied SlotShape.compileShape ctx.get) :
    ∃ value : Word,
      (∀ i : Fin 32, (rowContext ctx info).get (19+i.val) = ((value.extractLsb' i.val 1).toNat : F)) ∧
      (∀ i : Fin 20, (rowContext ctx info).get (51+i.val) =
        (((Rv32Compiler.upperImmediate value).extractLsb' i.val 1).toNat : F)) ∧
      (rowContext ctx info).get 71 = (((value.toNat+2048)/4294967296 : Nat) : F) := by
  have equations := (full_row_equations ctx info member one holds).1
  exact ⟨SlotImmediate.immediate (rowContext ctx info).get,
    SlotImmediate.immediate_bit_field _ equations,
    SlotImmediate.upper_bit_field _ equations,
    SlotImmediate.overflow_field _ equations⟩

#print axioms all_instances
#print axioms full_row_equations
#print axioms full_row_transition
#print axioms full_row_immediate

end ZkBuild.SlotMatrix
