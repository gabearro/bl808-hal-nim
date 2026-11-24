import FullMatrix

namespace ZkBuild.BodySoundness

open Lean.Grind CircuitShape FullMatrix
attribute [local instance] Ring.intCast Semiring.natCast

noncomputable def inputState {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : List F :=
  List.ofFn fun i : Fin 17 => (rowContext ctx info).get i.val

noncomputable def outputState {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) : List F :=
  info.outputs.toList.map (evalLinear ctx.get)

theorem row_context_slot {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (i : Nat) (bound : i < 25) :
    (rowContext ctx info).get i = evalLinear ctx.get (lookupLinear info.inputs i) := by
  rw [← row_context_inputs ctx info i (by omega)]
  have small : i+1 < 26 := by omega
  simp [localValues, rowWires, small]

theorem input_state_as_values {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (size : info.inputs.size = 25) :
    inputState ctx info = (info.inputs.toList.take 17).map (evalLinear ctx.get) := by
  apply List.ext_getElem
  · simp [inputState, size]
  · intro i left right
    have bound : i < 17 := by simpa [inputState] using left
    have inputBound : i < info.inputs.size := by omega
    have slot := row_context_slot ctx info i (by omega)
    simp only [inputState, List.getElem_ofFn, List.getElem_map, List.getElem_take, Array.getElem_toList]
    simpa only [lookupLinear, Array.getElem?_eq_getElem inputBound, Option.getD_some] using slot

theorem encoded_state_fields {F : Type} [CommRing F] (phase height : Nat) :
    encodedState (F := F) phase height =
      (List.ofFn fun i : Fin 8 => if i.val = phase then 1 else 0) ++
      (List.ofFn fun i : Fin 9 => if i.val = height then 1 else 0) := by
  simp [encodedState, RowSoundness.oneHot, List.range_succ, InputNormalization.cast_flag]

theorem encoding_phases {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (phase height : Nat) (encoding : inputState ctx info = encodedState phase height) :
    ∀ i : Fin 8, (rowContext ctx info).get i.val = if i.val = phase then 1 else 0 := by
  intro i
  rw [encoded_state_fields] at encoding
  have slot := congrArg (fun xs : List F => (xs[i.val]?).getD 0) encoding
  have inputBound : i.val < 17 := by have := i.isLt; omega
  have phaseBound : i.val < (List.ofFn fun j : Fin 8 => if j.val = phase then (1 : F) else 0).length := by simp
  simpa only [inputState, List.getElem?_ofFn, dite_eq_left inputBound,
    List.getElem?_append_left phaseBound, dite_eq_left i.isLt, Option.getD_some] using slot

theorem encoding_depths {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo)
    (phase height : Nat) (encoding : inputState ctx info = encodedState phase height) :
    ∀ i : Fin 9, (rowContext ctx info).get (8+i.val) = if i.val = height then 1 else 0 := by
  intro i
  rw [encoded_state_fields] at encoding
  have slot := congrArg (fun xs : List F => (xs[8+i.val]?).getD 0) encoding
  have inputBound : 8+i.val < 17 := by have := i.isLt; omega
  have afterPhases : (List.ofFn fun j : Fin 8 => if j.val = phase then (1 : F) else 0).length ≤ 8+i.val := by simp
  simpa only [inputState, List.getElem?_ofFn, dite_eq_left inputBound,
    List.getElem?_append_right afterPhases, List.length_ofFn, Nat.add_sub_cancel_left,
    dite_eq_left i.isLt, Option.getD_some] using slot

theorem first_row_inputs : (infoAt ⟨0, by decide⟩).inputs.toList.take 17 =
    [initial.ready, initial.index] ++ initial.leb.toList ++ [initial.done] ++ initial.depths.toList := by
  have first := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp module_row_adjacency).1).1
  exact eq_of_beq first

theorem adjacent_row_inputs (i : Fin 120) :
    (infoAt ⟨i.val+1, by have := i.isLt; omega⟩).inputs.toList.take 17 =
      (infoAt ⟨i.val, by have := i.isLt; omega⟩).outputs.toList := by
  have all := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp module_row_adjacency).1).2
  have checked := List.all_eq_true.mp all i.val (List.mem_range.mpr i.isLt)
  simpa [infoAt] using (eq_of_beq checked)

theorem adjacent_states {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 120) :
    inputState ctx (infoAt ⟨i.val+1, by have := i.isLt; omega⟩) =
      outputState ctx (infoAt ⟨i.val, by have := i.isLt; omega⟩) := by
  rw [input_state_as_values ctx _ (row_instance_checked _ (infoAt_member _)).1, adjacent_row_inputs]
  rfl

theorem initial_state {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1) :
    inputState ctx (infoAt ⟨0, by decide⟩) = encodedState 0 0 := by
  rw [input_state_as_values ctx _ (row_instance_checked _ (infoAt_member _)).1, first_row_inputs]
  simp [encodedState, initial, constant, evalLinear, interpretLinear, R1CS.eval, one,
    RowSoundness.oneHot, RowSoundness.flag, List.range_succ, Ring.intCast_zero, Ring.intCast_one,
    Semiring.zero_mul, Semiring.one_mul, Semiring.add_zero]

noncomputable def AtState {F : Type} [CommRing F] (ctx : Lean.RArray F) (index : Nat)
    (state : ByteStream.State) : Prop :=
  if bound : index < 121 then inputState ctx (infoAt ⟨index, bound⟩) = encodedState state.1.val state.2.val
  else outputState ctx (infoAt ⟨120, by decide⟩) = encodedState state.1.val state.2.val

def bodyByte (bytes : Fin 156 → Fin 256) (index : Nat) : Fin 256 :=
  if bound : index < 121 then bytes (moduleByteIndex ⟨index, bound⟩) else ⟨0, by decide⟩

def bodySuffix (bytes : Fin 156 → Fin 256) : Nat → Nat → List (Fin 256)
  | _, 0 => []
  | start, count+1 => bodyByte bytes start :: bodySuffix bytes (start+1) count

theorem boundary_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (index : Nat) (bound : index < 121)
    (state : ByteStream.State) (one : ctx.get 0 = 1)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (holds : Satisfied byteShape ctx.get) (before : AtState ctx index state) :
    ∃ next : ByteStream.State,
      ByteStream.boundRow ByteStream.referenceRow state (bodyByte bytes index) = some next ∧
      AtState ctx (index+1) next := by
  have inputEncoding : inputState ctx (infoAt ⟨index, bound⟩) = encodedState state.1.val state.2.val := by
    simpa [AtState, bound] using before
  obtain ⟨next, step, output⟩ := full_row_sound ctx ⟨index, bound⟩ state.1 state.2
    (bytes (moduleByteIndex ⟨index, bound⟩)) one
    (encoding_phases ctx _ _ _ inputEncoding) (encoding_depths ctx _ _ _ inputEncoding)
    (bindings (moduleByteIndex ⟨index, bound⟩)) holds
  refine ⟨next, ?_, ?_⟩
  · simp [bodyByte, bound, ByteStream.boundRow, step, next.1.isLt, next.2.isLt]
  · by_cases more : index+1 < 121
    · have adjacentBound : index < 120 := by omega
      simp only [AtState, dite_eq_left more]
      exact (adjacent_states ctx ⟨index, adjacentBound⟩).trans output
    · have last : index = 120 := by omega
      simpa [AtState, more, last, outputState] using output

theorem suffix_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (one : ctx.get 0 = 1)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (holds : Satisfied byteShape ctx.get) (count : Nat) :
    ∀ index state, index+count = 121 → AtState ctx index state →
      ∃ finalState, ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) state
        (bodySuffix bytes index count) = some finalState ∧ AtState ctx 121 finalState := by
  induction count with
  | zero =>
    intro index state endAt before
    have last : index = 121 := by omega
    subst index
    exact ⟨state, rfl, before⟩
  | succ count ih =>
    intro index state endAt before
    have bound : index < 121 := by omega
    obtain ⟨next, step, nextState⟩ := boundary_step ctx bytes index bound state one bindings holds before
    obtain ⟨finalState, rest, finalEncoding⟩ := ih (index+1) next (by omega) nextState
    refine ⟨finalState, ?_, finalEncoding⟩
    simpa [bodySuffix, ByteStream.runRows, step] using rest

theorem full_body_trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (one : ctx.get 0 = 1)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (holds : Satisfied byteShape ctx.get) :
    ∃ finalState, ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow)
      (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 121) = some finalState ∧
      outputState ctx (infoAt ⟨120, by decide⟩) = encodedState finalState.1.val finalState.2.val := by
  obtain ⟨finalState, run, finalEncoding⟩ := suffix_sound ctx bytes one bindings holds 121 0
    (⟨0, by decide⟩, ⟨0, by decide⟩) rfl (by simpa [AtState] using initial_state ctx one)
  exact ⟨finalState, run, by simpa [AtState] using finalEncoding⟩

def finalDone : Linear := lookupLinear (infoAt ⟨120, by decide⟩).outputs 7
def finalDoneGate : Gate := ⟨sub finalDone (constant 1), constant 1, constant 0⟩

theorem final_done_gate : byteShape.gates[8186]? = some finalDoneGate := by native_decide

theorem eval_constant {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) (n : Int) :
    evalLinear values (constant n) = (n : F) := by
  simp [evalLinear, constant, interpretLinear, R1CS.eval, one, Semiring.mul_one, Semiring.add_zero]

theorem eval_sub {F : Type} [CommRing F] (values : Nat → F) (a b : Linear) :
    evalLinear values (sub a b) = evalLinear values a - evalLinear values b := by
  rw [sub, eval_append, eval_scale]
  grind

theorem final_done_is_one {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get) : evalLinear ctx.get finalDone = 1 := by
  have member := Array.mem_of_getElem? final_done_gate
  have constraint := holds finalDoneGate (by simpa using member)
  change evalLinear ctx.get (sub finalDone (constant 1)) * evalLinear ctx.get (constant 1) =
    evalLinear ctx.get (constant 0) at constraint
  rw [eval_sub, eval_constant ctx.get one 1, eval_constant ctx.get one 0] at constraint
  grind

theorem output_slot {F : Type} [CommRing F] (ctx : Lean.RArray F) (info : RowInfo) (i : Nat) :
    ((outputState ctx info)[i]?).getD 0 = evalLinear ctx.get (lookupLinear info.outputs i) := by
  simp only [outputState, List.getElem?_map, Array.getElem?_toList, lookupLinear]
  cases info.outputs[i]? with
  | none => simp [evalLinear, interpretLinear, R1CS.eval]
  | some linear => simp

theorem encoded_final_phase {F : Type} [CommRing F] (phase height : Nat) :
    ((encodedState (F := F) phase height)[7]?).getD 0 = if 7 = phase then 1 else 0 := by
  rw [encoded_state_fields]
  have bound : 7 < (List.ofFn fun i : Fin 8 => if i.val = phase then (1 : F) else 0).length := by simp
  simp only [List.getElem?_append_left bound, List.getElem?_ofFn, dite_eq_left (by decide : 7 < 8), Option.getD_some]

theorem final_phase_is_done {F : Type} [Field F] (ctx : Lean.RArray F) (state : ByteStream.State)
    (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get)
    (encoding : outputState ctx (infoAt ⟨120, by decide⟩) = encodedState state.1.val state.2.val) :
    state.1.val = 7 := by
  have slot := congrArg (fun xs : List F => (xs[7]?).getD 0) encoding
  rw [output_slot, encoded_final_phase] at slot
  have done := final_done_is_one ctx one holds
  change evalLinear ctx.get finalDone = _ at slot
  rw [done] at slot
  split at slot
  next equal => exact equal.symm
  next => exact False.elim (Field.zero_ne_one slot.symm)

theorem full_body_ends_with_one_result {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (one : ctx.get 0 = 1)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (holds : Satisfied byteShape ctx.get) :
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow)
      (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 121) =
        some (⟨7, by decide⟩, ⟨1, by decide⟩) := by
  obtain ⟨finalState, run, encoding⟩ := full_body_trace ctx bytes one bindings holds
  have phase := final_phase_is_done ctx finalState one holds encoding
  have height : finalState.2.val = 1 := by
    apply ByteStream.run_preserves_finished_height (bodySuffix bytes 0 121)
      (⟨0, by decide⟩, ⟨0, by decide⟩) finalState run (by simp) phase
  have stateEq : finalState = (⟨7, by decide⟩, ⟨1, by decide⟩) := by
    apply Prod.ext
    · exact Fin.ext phase
    · exact Fin.ext height
  simpa [stateEq] using run

#print axioms initial_state
#print axioms adjacent_states
#print axioms full_body_trace
#print axioms full_body_ends_with_one_result

end ZkBuild.BodySoundness
