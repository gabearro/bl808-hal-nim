import RowMatrix
import Lean.Data.RArray

namespace ZkBuild.FullMatrix

open Lean.Grind
open CircuitShape
attribute [local instance] Ring.intCast Semiring.natCast

def evalLinear {F : Type} [CommRing F] (values : Nat → F) (linear : Linear) : F :=
  R1CS.eval values (interpretLinear linear)

def substitute (wires : Nat → Linear) (linear : Linear) : Linear :=
  linear.flatMap fun (wire, coefficient) => scale (wires wire) coefficient

theorem eval_append {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    evalLinear values (a ++ b) = evalLinear values a + evalLinear values b := by
  simp [evalLinear, interpretLinear, List.map_append, R1CS.eval_append]

theorem eval_scale {F : Type} [CommRing F] (values : Nat → F) (linear : Linear) (n : Int) :
    evalLinear values (scale linear n) = (n : F) * evalLinear values linear := by
  induction linear with
  | nil => simp [evalLinear, scale, interpretLinear, R1CS.eval, Semiring.mul_zero]
  | cons term rest ih =>
    rcases term with ⟨wire, coefficient⟩
    simp only [evalLinear, scale, interpretLinear, List.map_cons, R1CS.eval] at *
    rw [Ring.intCast_mul]
    grind

theorem eval_substitute {F : Type} [CommRing F] (values : Nat → F)
    (wires : Nat → Linear) (linear : Linear) :
    evalLinear values (substitute wires linear) =
      evalLinear (fun i => evalLinear values (wires i)) linear := by
  induction linear with
  | nil => rfl
  | cons term rest ih =>
    rcases term with ⟨wire, coefficient⟩
    simp only [substitute, List.flatMap_cons, eval_append, eval_scale]
    change (coefficient : F) * evalLinear values (wires wire) +
      evalLinear values (substitute wires rest) = _
    rw [ih]
    rfl

def substituteGate (wires : Nat → Linear) (gate : Gate) : Gate :=
  ⟨substitute wires gate.a, substitute wires gate.b, substitute wires gate.c⟩

theorem gate_substitution_sound {F : Type} [CommRing F] (values : Nat → F)
    (wires : Nat → Linear) (gate : Gate)
    (holds : R1CS.Holds values (interpretGate (substituteGate wires gate))) :
    R1CS.Holds (fun i => evalLinear values (wires i)) (interpretGate gate) := by
  change evalLinear values (substitute wires gate.a) * evalLinear values (substitute wires gate.b) =
    evalLinear values (substitute wires gate.c) at holds
  rw [eval_substitute, eval_substitute, eval_substitute] at holds
  exact holds

def directExpression : Linear → RowSoundness.Expr
  | [] => .literal 0
  | (i, coefficient) :: rest =>
    .add (.mul (.literal coefficient) (.input i)) (directExpression rest)

theorem direct_expression_sound {F : Type} [CommRing F] (values : Nat → F) (linear : Linear) :
    RowSoundness.evalField values (directExpression linear) = evalLinear values linear := by
  induction linear with
  | nil => simp [directExpression, RowSoundness.evalField, evalLinear, interpretLinear, R1CS.eval, Ring.intCast_zero]
  | cons term rest ih =>
    rcases term with ⟨i, coefficient⟩
    simp only [directExpression, RowSoundness.evalField, evalLinear, interpretLinear, List.map_cons, R1CS.eval] at *
    rw [ih]

def sameLinear (a b : Linear) : Bool :=
  RowMatrix.samePolynomial (directExpression a) (directExpression b)

theorem same_linear_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : Linear) (same : sameLinear a b = true) :
    evalLinear ctx.get a = evalLinear ctx.get b := by
  have eq := RowMatrix.polynomial_certificate_sound ctx (directExpression a) (directExpression b) same
  simpa only [direct_expression_sound] using eq

def sameGate (a b : Gate) : Bool := sameLinear a.a b.a && sameLinear a.b b.b && sameLinear a.c b.c

theorem same_gate_sound {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : Gate) (same : sameGate a b = true)
    (holds : R1CS.Holds ctx.get (interpretGate b)) : R1CS.Holds ctx.get (interpretGate a) := by
  have sides : sameLinear a.a b.a = true ∧ sameLinear a.b b.b = true ∧ sameLinear a.c b.c = true := by
    simpa [sameGate, Bool.and_eq_true_iff, and_assoc] using same
  change evalLinear ctx.get a.a * evalLinear ctx.get a.b = evalLinear ctx.get a.c
  rw [same_linear_sound ctx _ _ sides.1, same_linear_sound ctx _ _ sides.2.1,
    same_linear_sound ctx _ _ sides.2.2]
  exact holds

def rowWires (info : RowInfo) (wire : Nat) : Linear :=
  if wire = 0 then constant 1
  else if wire < 26 then lookupLinear info.inputs (wire-1)
  else [(info.wireStart + wire - 26, 1)]

def templateOutputs : List Linear := RowMatrix.phasesLinear ++ RowMatrix.rowBuild.1.depths.toList

def gateChecks (info : RowInfo) : Bool :=
  (List.range 57).all (fun j =>
    match RowMatrix.rowBuild.2.gates[j]?, byteShape.gates[info.gateStart+j]? with
    | some template, some actual => sameGate (substituteGate (rowWires info) template) actual
    | _, _ => false)

def outputChecks (info : RowInfo) : Bool :=
  (List.range 17).all (fun j =>
    match templateOutputs[j]?, info.outputs[j]? with
    | some template, some actual => sameLinear (substitute (rowWires info) template) actual
    | _, _ => false)

def rowInstanceCertificate (info : RowInfo) : Bool :=
  info.inputs.size == 25 && info.outputs.size == 17 && gateChecks info && outputChecks info

def allRowsCertificate : Bool := byteShape.rows.size == 121 && byteShape.rows.all rowInstanceCertificate

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem all_row_instances_match : allRowsCertificate = true := by native_decide

theorem row_instance_checked (info : RowInfo) (member : info ∈ byteShape.rows.toList) :
    info.inputs.size = 25 ∧ info.outputs.size = 17 ∧ gateChecks info = true ∧ outputChecks info = true := by
  have all := all_row_instances_match
  have rows : byteShape.rows.all rowInstanceCertificate = true := by
    exact (Bool.and_eq_true_iff.mp all).2
  have checked := List.all_eq_true.mp (by simpa using rows) info member
  simpa [rowInstanceCertificate, Bool.and_eq_true_iff, and_assoc] using checked

theorem template_gate_count : RowMatrix.rowBuild.2.gates.size = 57 := by native_decide
theorem template_output_count : templateOutputs.length = 17 := by native_decide

theorem instantiated_row_holds {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (info : RowInfo) (member : info ∈ byteShape.rows.toList)
    (holds : Satisfied byteShape ctx.get) :
    ∀ gate ∈ RowMatrix.rowBuild.2.gates.toList,
      R1CS.Holds (fun i => evalLinear ctx.get (rowWires info i)) (interpretGate gate) := by
  intro gate gateMember
  have arrayMember : gate ∈ RowMatrix.rowBuild.2.gates := by simpa using gateMember
  obtain ⟨j, found⟩ := Array.getElem?_of_mem arrayMember
  have bound := (Array.getElem?_eq_some_iff.mp found).1
  have jBound : j < 57 := by simpa [template_gate_count] using bound
  have checked := List.all_eq_true.mp (row_instance_checked info member).2.2.1 j (List.mem_range.mpr jBound)
  unfold gateChecks at checked
  rw [found] at checked
  cases actualFound : byteShape.gates[info.gateStart+j]? with
  | none => simp [actualFound] at checked
  | some actual =>
    have equal : sameGate (substituteGate (rowWires info) gate) actual = true := by
      simpa [actualFound] using checked
    apply gate_substitution_sound
    apply same_gate_sound ctx _ actual equal
    apply holds
    have actualMember := Array.mem_of_getElem? actualFound
    simpa using actualMember

theorem instantiated_outputs {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (info : RowInfo) (member : info ∈ byteShape.rows.toList) :
    templateOutputs.map (fun linear => evalLinear (fun i => evalLinear ctx.get (rowWires info i)) linear) =
      info.outputs.toList.map (evalLinear ctx.get) := by
  have checked := row_instance_checked info member
  apply List.ext_getElem
  · simp [template_output_count, checked.2.1]
  · intro j leftBound rightBound
    have bound : j < 17 := by simpa [template_output_count] using leftBound
    have left : j < templateOutputs.length := by simpa [template_output_count] using bound
    have right : j < info.outputs.size := by simpa [checked.2.1] using bound
    have comparison := List.all_eq_true.mp checked.2.2.2 j (List.mem_range.mpr bound)
    unfold outputChecks at comparison
    simp only [List.getElem?_eq_getElem left, Array.getElem?_eq_getElem right] at comparison
    simp only [List.getElem_map, Array.getElem_toList]
    rw [← eval_substitute]
    exact same_linear_sound ctx _ _ comparison

noncomputable def localValues {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : Nat → F :=
  fun i => evalLinear ctx.get (rowWires info i)

noncomputable def rowContext {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : Lean.RArray F :=
  Lean.RArray.ofFn (fun i : Fin 35 => localValues ctx info (i.val+1)) (by decide)

theorem row_context_inputs {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) :
    ∀ i, i < 35 → localValues ctx info (i+1) = (rowContext ctx info).get i := by
  intro i bound
  exact (Lean.RArray.get_ofFn (fun j : Fin 35 => localValues ctx info (j.val+1)) (by decide) ⟨i, bound⟩).symm

def encodedState {F : Type} [CommRing F] (phase height : Nat) : List F :=
  (RowSoundness.oneHot 8 phase ++ RowSoundness.oneHot 9 height).map (fun n : Int => (n : F))

theorem full_matrix_row_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (info : RowInfo) (member : info ∈ byteShape.rows.toList)
    (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : ctx.get 0 = 1)
    (phases : ∀ i : Fin 8, (rowContext ctx info).get i.val = if i.val = p.val then 1 else 0)
    (depths : ∀ i : Fin 9, (rowContext ctx info).get (8+i.val) = if i.val = h.val then 1 else 0)
    (bitsBoolean : ∀ value ∈ InputNormalization.witnessBits (rowContext ctx info).get, value * (value - 1) = 0)
    (bitsBinding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (InputNormalization.witnessBits (rowContext ctx info).get) = (b.val : F))
    (holds : Satisfied byteShape ctx.get) :
    ∃ next : ByteStream.State,
      ByteStream.referenceRow p.val h.val b.val = some (next.1.val, next.2.val) ∧
      info.outputs.toList.map (evalLinear ctx.get) = encodedState next.1.val next.2.val := by
  have localOne : localValues ctx info 0 = 1 := by
    simp [localValues, rowWires, constant, evalLinear, interpretLinear, R1CS.eval,
      one, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]
  obtain ⟨nextPhase, nextHeight, ref, nextPhases, nextDepths⟩ := RowMatrix.matrix_row_sound
    (rowContext ctx info) (localValues ctx info) p h b localOne (row_context_inputs ctx info)
    phases depths bitsBoolean bitsBinding (instantiated_row_holds ctx info member holds)
  have bound : nextPhase < 8 ∧ nextHeight < 9 := by
    have check := ByteStream.successful_row_stays_bounded p h b
    simpa [ref] using check
  refine ⟨(⟨nextPhase, bound.1⟩, ⟨nextHeight, bound.2⟩), ref, ?_⟩
  have combined :
      (RowMatrix.phasesLinear ++ RowMatrix.rowBuild.1.depths.toList).map
        (fun linear => R1CS.eval (localValues ctx info) (interpretLinear linear)) =
      encodedState nextPhase nextHeight := by
    simp only [encodedState, List.map_append]
    rw [nextPhases, nextDepths]
  have transferred := instantiated_outputs ctx info member
  exact transferred.symm.trans combined

def infoAt (i : Fin 121) : RowInfo := byteShape.rows[i.val]?.getD default

def adjacencyCertificate : Bool :=
  ((infoAt ⟨0, by decide⟩).inputs.toList.take 17 ==
    ([initial.ready, initial.index] ++ initial.leb.toList ++ [initial.done] ++ initial.depths.toList)) &&
  (List.range 120).all (fun i =>
    (byteShape.rows[i+1]?.getD default).inputs.toList.take 17 ==
      (byteShape.rows[i]?.getD default).outputs.toList) &&
  (List.range 121).all (fun i =>
    let info := byteShape.rows[i]?.getD default
    info.wireStart == 1256 + i*40 && info.gateStart == 1289 + i*57 &&
    info.inputs.toList.drop 17 == (List.range 8).map (fun bit => [(8 + (35+i)*8 + bit, 1)]))

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem module_row_adjacency : adjacencyCertificate = true := by native_decide

theorem row_count : byteShape.rows.size = 121 := by
  have count := (Bool.and_eq_true_iff.mp all_row_instances_match).1
  simpa using count

theorem infoAt_member (i : Fin 121) : infoAt i ∈ byteShape.rows.toList := by
  have bound : i.val < byteShape.rows.size := by simp [row_count]
  unfold infoAt
  rw [Array.getElem?_eq_getElem bound]
  exact Array.getElem_mem_toList bound

def bitGate (i : Fin 1248) : Gate :=
  ⟨[(8+i.val, 1)], [(8+i.val, 1), (0, -1)], [(0, 0)]⟩

theorem global_bit_gates : ∀ i : Fin 1248, byteShape.gates[i.val]? = some (bitGate i) := by native_decide

def globalBits {F : Type} (values : Nat → F) (position : Fin 156) : List F :=
  List.ofFn fun bit : Fin 8 => values (8+position.val*8+bit.val)

theorem global_bits_boolean {F : Type} [CommRing F] (ctx : Lean.RArray F) (position : Fin 156)
    (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get) :
    ∀ value ∈ globalBits ctx.get position, value * (value - 1) = 0 := by
  intro value member
  obtain ⟨bit, rfl⟩ := List.mem_ofFn.mp member
  have bound : position.val*8+bit.val < 1248 := by have := position.isLt; have := bit.isLt; omega
  let i : Fin 1248 := ⟨position.val*8+bit.val, bound⟩
  have gateMember := Array.mem_of_getElem? (global_bit_gates i)
  have valid := holds (bitGate i) (by simpa using gateMember)
  simp [bitGate, i, interpretGate, interpretLinear, R1CS.Holds, R1CS.eval, one,
    Ring.intCast_one, Ring.intCast_neg, Ring.intCast_zero, Semiring.one_mul, Semiring.add_zero] at valid
  grind

def moduleByteIndex (i : Fin 121) : Fin 156 := ⟨35+i.val, by have := i.isLt; omega⟩

theorem row_bit_wires : ∀ (i : Fin 121) (bit : Fin 8),
    rowWires (infoAt i) (18+bit.val) = [(8+(35+i.val)*8+bit.val, 1)] := by native_decide

theorem row_bits_are_global {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 121) :
    InputNormalization.witnessBits (rowContext ctx (infoAt i)).get = globalBits ctx.get (moduleByteIndex i) := by
  unfold InputNormalization.witnessBits globalBits
  apply congrArg List.ofFn
  funext bit
  have bound : 17+bit.val < 35 := by have := bit.isLt; omega
  rw [← row_context_inputs ctx (infoAt i) (17+bit.val) bound]
  have index : 17+bit.val+1 = 18+bit.val := by omega
  rw [index]
  change evalLinear ctx.get (rowWires (infoAt i) (18+bit.val)) = _
  rw [row_bit_wires]
  simp [evalLinear, interpretLinear, R1CS.eval, moduleByteIndex,
    Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]

theorem full_row_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (i : Fin 121) (p : Fin 8) (h : Fin 9) (b : Fin 256)
    (one : ctx.get 0 = 1)
    (phases : ∀ j : Fin 8, (rowContext ctx (infoAt i)).get j.val = if j.val = p.val then 1 else 0)
    (depths : ∀ j : Fin 9, (rowContext ctx (infoAt i)).get (8+j.val) = if j.val = h.val then 1 else 0)
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get (moduleByteIndex i)) = (b.val : F))
    (holds : Satisfied byteShape ctx.get) :
    ∃ next : ByteStream.State,
      ByteStream.referenceRow p.val h.val b.val = some (next.1.val, next.2.val) ∧
      (infoAt i).outputs.toList.map (evalLinear ctx.get) = encodedState next.1.val next.2.val := by
  apply full_matrix_row_sound ctx (infoAt i) (infoAt_member i) p h b one phases depths
  · rw [row_bits_are_global]
    exact global_bits_boolean ctx (moduleByteIndex i) one holds
  · simpa [row_bits_are_global] using binding
  · exact holds

#print axioms eval_substitute
#print axioms gate_substitution_sound
#print axioms all_row_instances_match
#print axioms instantiated_row_holds
#print axioms instantiated_outputs
#print axioms full_matrix_row_sound
#print axioms module_row_adjacency
#print axioms full_row_sound

end ZkBuild.FullMatrix
