import BodyCompleteness
import BinarySoundness

namespace ZkBuild.BinaryCompleteness

open Lean.Grind CircuitShape FullMatrix BodySoundness BodyCompleteness PublicBinding
open HeaderSoundness ExactLength BinarySoundness
attribute [local instance] Ring.intCast Semiring.natCast

def publicValues {F : Type} [CommRing F] (length : Nat) (bytes : Fin 156 → Fin 256) (i : Fin 7) : F :=
  if first : i.val = 0 then (length : F)
  else R1CS.packedField (chunkBytes bytes ⟨i.val-1, by have := i.isLt; omega⟩)

noncomputable def context {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) : Lean.RArray F :=
  moduleContext (publicValues length bytes) bytes states

theorem public_length {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) :
    (context (F := F) length bytes states).get 1 = (length : F) := by
  exact module_public (publicValues length bytes) bytes states ⟨0, by decide⟩

theorem public_bytes {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) : PublicBytesMatch (context (F := F) length bytes states) bytes := by
  intro chunk
  have bound : 1+chunk.val < 7 := by have := chunk.isLt; omega
  have input := module_public (publicValues (F := F) length bytes) bytes states ⟨1+chunk.val, bound⟩
  have index : 1+(1+chunk.val) = 2+chunk.val := by omega
  change (moduleContext _ _ _).get (1+(1+chunk.val)) = _ at input
  rw [index] at input
  simpa [context, publicValues] using input

theorem bindings {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) :
    ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits (context (F := F) length bytes states).get pos) =
      ((bytes pos).val : F) := by
  intro pos
  rw [context, module_byte_bits, InputNormalization.canonical_byte_field_value]

theorem equality_gate_complete {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : Linear) (one : ctx.get 0 = 1) (equal : evalLinear ctx.get a = evalLinear ctx.get b) :
    R1CS.Holds ctx.get (interpretGate ⟨sub a b, constant 1, constant 0⟩) := by
  change evalLinear ctx.get (sub a b) * evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0)
  rw [eval_sub, eval_constant ctx.get one 1, eval_constant ctx.get one 0, equal]
  grind

theorem bit_gate_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (i : Fin 1248) :
    R1CS.Holds (context (F := F) length bytes states).get (interpretGate (bitGate i)) := by
  have ib := i.isLt
  let pos : Fin 156 := ⟨i.val/8, by omega⟩
  let bit : Fin 8 := ⟨i.val%8, by omega⟩
  have index : 8+pos.val*8+bit.val = 8+i.val := by dsimp [pos, bit]; omega
  have value := module_bit (publicValues (F := F) length bytes) bytes states pos bit
  rw [index] at value
  have one := module_one (publicValues (F := F) length bytes) bytes states
  simp only [bitGate, interpretGate, interpretLinear, R1CS.Holds, R1CS.eval, List.map_cons, List.map_nil,
    Ring.intCast_one, Ring.intCast_neg, Ring.intCast_zero, Semiring.one_mul,
    Semiring.zero_mul, Semiring.add_zero, context, one, value, InputNormalization.cast_flag]
  split <;> grind

theorem packing_gate_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (chunk : Fin 6) :
    R1CS.Holds (context (F := F) length bytes states).get (interpretGate (packingGate chunk)) := by
  apply equality_gate_complete _ _ _ (module_one _ _ _)
  change evalLinear (context length bytes states).get (packLinear ((positions chunk).map Fin.val)) = _
  rw [packing_linear_value _ bytes (bindings length bytes states), wire_value]
  exact (public_bytes length bytes states chunk).symm

theorem header_gate_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (lengthBound : 36 ≤ length)
    (header : HeaderValid bytes length) (i : Fin 35) :
    R1CS.Holds (context (F := F) length bytes states).get (interpretGate (headerGate i)) := by
  let ctx : Lean.RArray F := context length bytes states
  have one : ctx.get 0 = 1 := module_one _ _ _
  have byteEq : evalLinear ctx.get (byteLinear i.val) = ((bytes (headerPosition i)).val : F) :=
    (byte_linear_value ctx (headerPosition i)).trans (bindings length bytes states _)
  have value := header i
  by_cases ascii : 25 ≤ i.val ∧ i.val ≤ 27
  · have small : (bytes (headerPosition i)).val < 128 := by simpa [HeaderValid, ascii] using value
    have notSet : ¬((bytes (headerPosition i)).val / 2^7) % 2 = 1 := by change ¬((bytes (headerPosition i)).val / 128) % 2 = 1; omega
    simp only [headerGate, ite_eq_left ascii]
    apply equality_gate_complete _ _ _ one
    rw [wire_value, eval_constant _ one 0]
    have value := module_bit (publicValues (F := F) length bytes) bytes states (headerPosition i) ⟨7, by decide⟩
    rw [InputNormalization.cast_flag, ite_eq_right notSet] at value
    simpa [headerPosition, ctx, context, Ring.intCast_zero] using value
  · by_cases codeLength : i.val = 31
    · have equal : (bytes (headerPosition i)).val = length-32 := by simpa [HeaderValid, ascii, codeLength] using value
      simp only [headerGate, ite_eq_right ascii, ite_eq_left codeLength]
      apply equality_gate_complete _ _ _ one
      change evalLinear ctx.get (byteLinear i.val) = evalLinear ctx.get (sub [(1, 1)] (constant 32))
      have len : ctx.get 1 = (length : F) := public_length length bytes states
      rw [byteEq, equal, eval_sub, wire_value, len, eval_constant ctx.get one 32]
      have add : length = length-32+32 := by omega
      rw [add, Semiring.natCast_add]
      grind
    · by_cases bodyLength : i.val = 33
      · have equal : (bytes (headerPosition i)).val = length-34 := by simpa [HeaderValid, ascii, codeLength, bodyLength] using value
        simp only [headerGate, ite_eq_right ascii, ite_eq_right codeLength, ite_eq_left bodyLength]
        apply equality_gate_complete _ _ _ one
        change evalLinear ctx.get (byteLinear i.val) = evalLinear ctx.get (sub [(1, 1)] (constant 34))
        have len : ctx.get 1 = (length : F) := public_length length bytes states
        rw [byteEq, equal, eval_sub, wire_value, len, eval_constant ctx.get one 34]
        have add : length = length-34+34 := by omega
        rw [add, Semiring.natCast_add]
        grind
      · have equal : (bytes (headerPosition i)).val = prefixByte i := by
          simpa [HeaderValid, ascii, codeLength, bodyLength] using value
        simp only [headerGate, ite_eq_right ascii, ite_eq_right codeLength, ite_eq_right bodyLength]
        apply equality_gate_complete _ _ _ one
        change evalLinear ctx.get (byteLinear i.val) = evalLinear ctx.get (constant (Int.ofNat (prefixByte i)))
        rw [byteEq, equal, eval_constant ctx.get one]
        simp [Ring.intCast_natCast]

def stateAt (states : States) (index : Nat) : ByteStream.State :=
  if bound : index < 122 then states ⟨index, bound⟩ else (⟨0, by decide⟩, ⟨0, by decide⟩)

def traceCount (states : States) : Nat → Nat → Nat
  | _, 0 => 0
  | start, count+1 => active (stateAt states start) + traceCount states (start+1) count

theorem constructed_count {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (trace : ValidTrace bytes states) (count : Nat) :
    ∀ start, start+count ≤ 121 →
      fieldCount (context (F := F) length bytes states) start count = (traceCount states start count : F) := by
  have incoming := (constructed_all_rows (publicValues (F := F) length bytes) bytes states trace).2.2
  induction count with
  | zero => intro start _; simp [fieldCount, traceCount, Semiring.natCast_zero]
  | succ count ih =>
    intro start bound
    have small : start < 121 := by omega
    have state : AtState (context (F := F) length bytes states) start (stateAt states start) := by
      simp only [AtState, dite_eq_left small]
      simpa [context, stateAt, before, show start < 122 by omega] using incoming ⟨start, small⟩
    rw [fieldCount, traceCount, active_matches_state _ start small _ state,
      ih (start+1) (by omega), Semiring.natCast_add]

theorem final_gate_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (trace : ValidTrace bytes states)
    (finished : (states ⟨121, by decide⟩).1.val = 7) :
    R1CS.Holds (context (F := F) length bytes states).get (interpretGate finalDoneGate) := by
  have output := (constructed_all_rows (publicValues (F := F) length bytes) bytes states trace).2.1
  have slot := congrArg (fun xs : List F => (xs[7]?).getD 0) output
  rw [output_slot, encoded_final_phase, finished] at slot
  apply equality_gate_complete _ _ _ (module_one _ _ _)
  change evalLinear _ finalDone = evalLinear _ (constant 1)
  rw [eval_constant _ (module_one _ _ _) 1]
  simpa [finalDone, Ring.intCast_one] using slot

theorem length_gate_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (trace : ValidTrace bytes states)
    (lengthBound : 36 ≤ length) (consumed : traceCount states 0 121 = length-35) :
    R1CS.Holds (context (F := F) length bytes states).get (interpretGate lengthGate) := by
  let ctx : Lean.RArray F := context length bytes states
  have one : ctx.get 0 = 1 := module_one _ _ _
  have len : ctx.get 1 = (length : F) := public_length length bytes states
  apply equality_gate_complete _ _ _ one
  change evalLinear ctx.get (counterLinear 0 121) = evalLinear ctx.get (sub [(1, 1)] (constant 35))
  rw [counter_linear_value ctx one, constructed_count length bytes states trace 121 0 (by decide),
    consumed, eval_sub, wire_value, len, eval_constant ctx.get one 35]
  have add : length = length-35+35 := by omega
  rw [add, Semiring.natCast_add]
  grind

theorem row_gate_starts : ∀ i : Fin 121, (infoAt i).gateStart = 1289+i.val*57 := by native_decide
theorem module_gate_count : byteShape.gates.size = 8188 := by native_decide

theorem matrix_complete {F : Type} [CommRing F] (length : Nat)
    (bytes : Fin 156 → Fin 256) (states : States) (trace : ValidTrace bytes states)
    (lengthBound : 36 ≤ length) (header : HeaderValid bytes length)
    (finished : (states ⟨121, by decide⟩).1.val = 7)
    (consumed : traceCount states 0 121 = length-35) :
    Satisfied byteShape (context (F := F) length bytes states).get := by
  intro actual member
  obtain ⟨k, found⟩ := Array.getElem?_of_mem (show actual ∈ byteShape.gates from by simpa using member)
  have bound : k < 8188 := by
    have size := (Array.getElem?_eq_some_iff.mp found).1
    simpa [module_gate_count] using size
  by_cases bit : k < 1248
  · have eq : actual = bitGate ⟨k, bit⟩ := Option.some.inj (found.symm.trans (global_bit_gates ⟨k, bit⟩))
    rw [eq]
    exact bit_gate_complete length bytes states ⟨k, bit⟩
  · by_cases packed : k < 1254
    · let chunk : Fin 6 := ⟨k-1248, by omega⟩
      have index : 1248+chunk.val = k := by dsimp [chunk]; omega
      have same := packing_gates_match chunk
      rw [index, found] at same
      exact same_gate_complete _ _ actual same (packing_gate_complete length bytes states chunk)
    · by_cases head : k < 1289
      · let i : Fin 35 := ⟨k-1254, by omega⟩
        have index : 1254+i.val = k := by dsimp [i]; omega
        have same := header_gates_match i
        rw [index, found] at same
        exact same_gate_complete _ _ actual same (header_gate_complete length bytes states lengthBound header i)
      · by_cases body : k < 8186
        · let i : Fin 121 := ⟨(k-1289)/57, by omega⟩
          let j : Fin 57 := ⟨(k-1289)%57, by omega⟩
          have index : (infoAt i).gateStart+j.val = k := by rw [row_gate_starts]; dsimp [i, j]; omega
          have rows := (constructed_all_rows (publicValues (F := F) length bytes) bytes states trace).1
          exact rows i j actual (by rw [index]; exact found)
        · by_cases done : k = 8186
          · have eq : actual = finalDoneGate := Option.some.inj (found.symm.trans (by simpa [done] using final_done_gate))
            rw [eq]
            exact final_gate_complete length bytes states trace finished
          · have last : k = 8187 := by omega
            have same := length_gate_matches
            rw [← last, found] at same
            exact same_gate_complete _ _ actual same (length_gate_complete length bytes states trace lengthBound consumed)

theorem exact_counts (bytes : List (Fin 256)) : ∀ initial finalState,
    runExact initial bytes = some finalState → runCount initial bytes = some (finalState, bytes.length) := by
  induction bytes with
  | nil =>
    intro initial finalState accepted
    simp only [runExact] at accepted
    split at accepted
    next => cases accepted; rfl
    next => simp at accepted
  | cons byte rest ih =>
    intro initial finalState accepted
    by_cases finished : initial.1.val = 7
    · simp [runExact, finished] at accepted
    · cases step : ByteStream.boundRow ByteStream.referenceRow initial byte with
      | none => simp [runExact, finished, step] at accepted
      | some next =>
        have tail : runExact next rest = some finalState := by simpa [runExact, finished, step] using accepted
        simp [runCount, step, ih next finalState tail, active, finished, Nat.add_comm]

theorem count_append (left right : List (Fin 256)) : ∀ initial middle finalState a b,
    runCount initial left = some (middle, a) → runCount middle right = some (finalState, b) →
    runCount initial (left ++ right) = some (finalState, a+b) := by
  induction left with
  | nil =>
    intro initial middle finalState a b first last
    simp only [runCount, Option.some.injEq, Prod.mk.injEq] at first
    rcases first with ⟨rfl, rfl⟩
    simpa using last
  | cons byte rest ih =>
    intro initial middle finalState a b first last
    cases step : ByteStream.boundRow ByteStream.referenceRow initial byte with
    | none => simp [runCount, step] at first
    | some next =>
      cases tail : runCount next rest with
      | none => simp [runCount, step, tail] at first
      | some pair =>
        rcases pair with ⟨tailState, count⟩
        rw [runCount, step] at first
        dsimp only at first
        rw [tail] at first
        simp only [Option.some.injEq, Prod.mk.injEq] at first
        rcases first with ⟨rfl, rfl⟩
        simp only [List.cons_append, runCount, step]
        rw [ih next tailState finalState count b tail last]
        simp only [Nat.add_assoc]

theorem finished_zero_step (height : Fin 9) :
    ByteStream.boundRow ByteStream.referenceRow (⟨7, by decide⟩, height) ⟨0, by decide⟩ =
      some (⟨7, by decide⟩, height) := by
  simp [ByteStream.boundRow, ByteStream.referenceRow, height.isLt]

theorem zero_padding_count (height : Fin 9) (count : Nat) :
    runCount (⟨7, by decide⟩, height) (List.replicate count ⟨0, by decide⟩) =
      some ((⟨7, by decide⟩, height), 0) := by
  induction count with
  | zero => rfl
  | succ count ih =>
    rw [List.replicate_succ, runCount, finished_zero_step]
    dsimp only
    rw [ih]
    rfl

theorem padded_body (wasm : List (Fin 256)) (lower : 35 ≤ wasm.length) (upper : wasm.length ≤ 156) :
    bodySuffix (paddedBytes wasm) 0 121 =
      wasm.drop 35 ++ List.replicate (156-wasm.length) ⟨0, by decide⟩ := by
  apply List.ext_getElem
  · simp only [body_suffix_length, List.length_append, List.length_drop, List.length_replicate]
    omega
  · intro i left right
    have inBody : i < 121 := by simpa only [body_suffix_length] using left
    rw [body_suffix_get (paddedBytes wasm) 121 0 i inBody]
    simp only [bodyByte, Nat.zero_add, dite_eq_left inBody, moduleByteIndex, paddedBytes]
    by_cases present : 35+i < wasm.length
    · have inRaw : i < (wasm.drop 35).length := by simp only [List.length_drop]; omega
      rw [List.getElem?_eq_getElem present, Option.getD_some, List.getElem_append_left inRaw, List.getElem_drop]
    · have afterRaw : (wasm.drop 35).length ≤ i := by simp only [List.length_drop]; omega
      rw [List.getElem?_eq_none (by omega), Option.getD_none, List.getElem_append_right afterRaw, List.getElem_replicate]

theorem accepted_padded_count (wasm : List (Fin 256)) (supported : SupportedWasmBinary wasm) :
    runCount (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix (paddedBytes wasm) 0 121) =
      some ((⟨7, by decide⟩, ⟨1, by decide⟩), wasm.length-35) := by
  have exactBody := exact_counts (wasm.drop 35) _ _ supported.2.2.2
  rw [padded_body wasm (by have := supported.1; omega) supported.2.1]
  have joined := count_append (wasm.drop 35) (List.replicate (156-wasm.length) ⟨0, by decide⟩)
    _ _ _ _ _ exactBody (zero_padding_count ⟨1, by decide⟩ (156-wasm.length))
  simpa only [List.length_drop, Nat.add_zero] using joined

def stateAfter : ByteStream.State → List (Fin 256) → Nat → ByteStream.State
  | initial, _, 0 => initial
  | initial, [], _+1 => initial
  | initial, byte :: rest, count+1 =>
    stateAfter ((ByteStream.boundRow ByteStream.referenceRow initial byte).getD initial) rest count

theorem state_after_step (bytes : List (Fin 256)) : ∀ initial finalState index (bound : index < bytes.length),
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) initial bytes = some finalState →
    ByteStream.boundRow ByteStream.referenceRow (stateAfter initial bytes index) bytes[index] =
      some (stateAfter initial bytes (index+1)) := by
  induction bytes with
  | nil => intro initial finalState index bound; simp at bound
  | cons byte rest ih =>
    intro initial finalState index bound accepted
    cases step : ByteStream.boundRow ByteStream.referenceRow initial byte with
    | none => simp [ByteStream.runRows, step] at accepted
    | some next =>
      have tail : ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) next rest = some finalState := by
        simpa [ByteStream.runRows, step] using accepted
      cases index with
      | zero => simp [stateAfter, step]
      | succ index =>
        have tailBound : index < rest.length := by simp only [List.length_cons] at bound; omega
        simpa [stateAfter, step] using ih next finalState index tailBound tail

theorem state_after_end (bytes : List (Fin 256)) : ∀ initial finalState,
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) initial bytes = some finalState →
    stateAfter initial bytes bytes.length = finalState := by
  induction bytes with
  | nil => intro initial finalState accepted; simpa [ByteStream.runRows, stateAfter] using accepted
  | cons byte rest ih =>
    intro initial finalState accepted
    cases step : ByteStream.boundRow ByteStream.referenceRow initial byte with
    | none => simp [ByteStream.runRows, step] at accepted
    | some next =>
      have tail : ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) next rest = some finalState := by
        simpa [ByteStream.runRows, step] using accepted
      simpa [stateAfter, step] using ih next finalState tail

def statesFor (bytes : Fin 156 → Fin 256) : States :=
  fun i => stateAfter (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 121) i.val

theorem bound_row_reference (initial finalState : ByteStream.State) (byte : Fin 256)
    (step : ByteStream.boundRow ByteStream.referenceRow initial byte = some finalState) :
    ByteStream.referenceRow initial.1.val initial.2.val byte.val = some (finalState.1.val, finalState.2.val) := by
  unfold ByteStream.boundRow at step
  cases row : ByteStream.referenceRow initial.1.val initial.2.val byte.val with
  | none => simp [row] at step
  | some pair =>
    rcases pair with ⟨phase, height⟩
    simp only [row] at step
    split at step
    next bounds => cases step; rfl
    next => simp at step

theorem states_for_valid (bytes : Fin 156 → Fin 256) (finalState : ByteStream.State)
    (accepted : ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow)
      (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 121) = some finalState) :
    ValidTrace bytes (statesFor bytes) ∧ statesFor bytes ⟨121, by decide⟩ = finalState := by
  refine ⟨⟨rfl, ?_⟩, ?_⟩
  · intro i
    have bound : i.val < (bodySuffix bytes 0 121).length := by simp [body_suffix_length]
    have step := state_after_step (bodySuffix bytes 0 121) _ finalState i.val bound accepted
    rw [body_suffix_get bytes 121 0 i.val i.isLt] at step
    simpa [statesFor, before, after, bodyByte, i.isLt] using bound_row_reference _ _ _ step
  · have ending := state_after_end (bodySuffix bytes 0 121) _ finalState accepted
    simpa only [body_suffix_length, statesFor] using ending

theorem trace_count_run (bytes : Fin 156 → Fin 256) (states : States)
    (trace : ValidTrace bytes states) (count : Nat) : ∀ start, start+count ≤ 121 →
    runCount (stateAt states start) (bodySuffix bytes start count) =
      some (stateAt states (start+count), traceCount states start count) := by
  induction count with
  | zero => intro start _; simp [bodySuffix, runCount, traceCount]
  | succ count ih =>
    intro start bound
    have small : start < 121 := by omega
    let i : Fin 121 := ⟨start, small⟩
    have reference := trace.2 i
    have step : ByteStream.boundRow ByteStream.referenceRow (before states i) (bytes (moduleByteIndex i)) =
        some (after states i) := by
      simp [ByteStream.boundRow, reference, (after states i).1.isLt, (after states i).2.isLt]
    have step' : ByteStream.boundRow ByteStream.referenceRow (stateAt states start) (bodyByte bytes start) =
        some (stateAt states (start+1)) := by
      simpa [i, before, after, stateAt, bodyByte, small, show start < 122 by omega,
        show start+1 < 122 by omega] using step
    rw [bodySuffix, runCount, step']
    dsimp only
    rw [ih (start+1) (by omega)]
    simp [traceCount, Nat.add_left_comm, Nat.add_comm]

noncomputable def witnessContext {F : Type} [CommRing F] (wasm : List (Fin 256)) : Lean.RArray F :=
  context wasm.length (paddedBytes wasm) (statesFor (paddedBytes wasm))

theorem count_component_equal (left right : ByteStream.State) (a b : Nat)
    (same : some (left, a) = some (right, b)) : a = b :=
  congrArg (fun pair : ByteStream.State × Nat => pair.2) (Option.some.inj same)

theorem binary_complete {F : Type} [CommRing F] (wasm : List (Fin 256))
    (supported : SupportedWasmBinary wasm) :
    (witnessContext (F := F) wasm).get 0 = 1 ∧
      PublicInputsFor (witnessContext (F := F) wasm) wasm ∧
      Satisfied byteShape (witnessContext (F := F) wasm).get := by
  have accepted := accepted_padded_count wasm supported
  have projected := run_count_projects (bodySuffix (paddedBytes wasm) 0 121) _ _ _ accepted
  obtain ⟨trace, finalState⟩ := states_for_valid (paddedBytes wasm) _ projected
  have counted := trace_count_run (paddedBytes wasm) (statesFor (paddedBytes wasm)) trace 121 0 (by decide)
  have first : stateAt (statesFor (paddedBytes wasm)) 0 = (⟨0, by decide⟩, ⟨0, by decide⟩) := rfl
  rw [first] at counted
  have count := count_component_equal (stateAt (statesFor (paddedBytes wasm)) 121)
    (⟨7, by decide⟩, ⟨1, by decide⟩) (traceCount (statesFor (paddedBytes wasm)) 0 121)
    (wasm.length-35) (counted.symm.trans accepted)
  have finished : (statesFor (paddedBytes wasm) ⟨121, by decide⟩).1.val = 7 := by rw [finalState]
  refine ⟨?_, ?_, ?_⟩
  · exact module_one (publicValues (F := F) wasm.length (paddedBytes wasm))
      (paddedBytes wasm) (statesFor (paddedBytes wasm))
  · exact ⟨public_length (F := F) wasm.length (paddedBytes wasm) (statesFor (paddedBytes wasm)),
      public_bytes (F := F) wasm.length (paddedBytes wasm) (statesFor (paddedBytes wasm))⟩
  · exact matrix_complete (F := F) wasm.length (paddedBytes wasm) (statesFor (paddedBytes wasm)) trace
      supported.1 supported.2.2.1 finished count

theorem binary_relation_iff {F : Type} [Field F] [IsCharP F scalarModulus]
    (wasm : List (Fin 256)) (lengthBound : 36 ≤ wasm.length ∧ wasm.length ≤ 156) :
    SupportedWasmBinary wasm ↔
      ∃ ctx : Lean.RArray F, ctx.get 0 = 1 ∧ PublicInputsFor ctx wasm ∧ Satisfied byteShape ctx.get := by
  constructor
  · intro supported
    exact ⟨witnessContext wasm, binary_complete wasm supported⟩
  · rintro ⟨ctx, one, publicInputs, satisfied⟩
    exact binary_soundness ctx wasm lengthBound one publicInputs satisfied

#print axioms matrix_complete
#print axioms binary_complete
#print axioms binary_relation_iff

end ZkBuild.BinaryCompleteness
