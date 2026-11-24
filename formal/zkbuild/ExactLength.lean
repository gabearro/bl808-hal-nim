import HeaderSoundness

namespace ZkBuild.ExactLength

open Lean.Grind CircuitShape FullMatrix BodySoundness PublicBinding HeaderSoundness
attribute [local instance] Ring.intCast Semiring.natCast

def active (state : ByteStream.State) : Nat := if state.1.val = 7 then 0 else 1

def runCount : ByteStream.State → List (Fin 256) → Option (ByteStream.State × Nat)
  | state, [] => some (state, 0)
  | state, byte :: rest =>
    match ByteStream.boundRow ByteStream.referenceRow state byte with
    | none => none
    | some next =>
      match runCount next rest with
      | none => none
      | some (finalState, count) => some (finalState, active state + count)

def runExact : ByteStream.State → List (Fin 256) → Option ByteStream.State
  | state, [] => if state.1.val = 7 then some state else none
  | state, byte :: rest =>
    if state.1.val = 7 then none else
      (ByteStream.boundRow ByteStream.referenceRow state byte).bind (fun next => runExact next rest)

def doneLinear (index : Nat) : Linear :=
  lookupLinear (byteShape.rows[index]?.getD default).inputs 7

def counterLinear : Nat → Nat → Linear
  | _, 0 => constant 0
  | index, count+1 => sub (constant 1) (doneLinear index) ++ counterLinear (index+1) count

def lengthGate : Gate :=
  ⟨sub (counterLinear 0 121) (sub [(1, 1)] (constant 35)), constant 1, constant 0⟩

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem length_gate_matches :
    (match byteShape.gates[8187]? with
    | none => false
    | some actual => sameGate lengthGate actual) = true := by native_decide

noncomputable def fieldCount {F : Type} [CommRing F] (ctx : Lean.RArray F) : Nat → Nat → F
  | _, 0 => 0
  | index, count+1 => (1 - evalLinear ctx.get (doneLinear index)) + fieldCount ctx (index+1) count

theorem counter_linear_value {F : Type} [CommRing F] (ctx : Lean.RArray F) (one : ctx.get 0 = 1)
    (count : Nat) : ∀ index, evalLinear ctx.get (counterLinear index count) = fieldCount ctx index count := by
  induction count with
  | zero => intro index; simp [counterLinear, fieldCount, BodySoundness.eval_constant ctx.get one, Ring.intCast_zero]
  | succ count ih =>
    intro index
    simp only [counterLinear, fieldCount, eval_append, BodySoundness.eval_sub,
      BodySoundness.eval_constant ctx.get one, Ring.intCast_one, ih]

theorem active_matches_state {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (index : Nat) (bound : index < 121) (state : ByteStream.State)
    (atState : AtState ctx index state) :
    1 - evalLinear ctx.get (doneLinear index) = (active state : F) := by
  have encoding : inputState ctx (infoAt ⟨index, bound⟩) = encodedState state.1.val state.2.val := by
    simpa [AtState, bound] using atState
  have phase := encoding_phases ctx _ _ _ encoding (⟨7, by decide⟩ : Fin 8)
  rw [row_context_slot ctx _ 7 (by decide)] at phase
  change evalLinear ctx.get (doneLinear index) = (if 7 = state.1.val then 1 else 0) at phase
  rw [phase]
  by_cases finished : state.1.val = 7 <;>
    simp [active, finished, eq_comm, Semiring.natCast_zero, Semiring.natCast_one] <;> grind

theorem suffix_count_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (one : ctx.get 0 = 1)
    (bindings : ∀ pos, R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get pos) = (bytes pos).val)
    (holds : Satisfied byteShape ctx.get) (count : Nat) :
    ∀ index state, index+count = 121 → AtState ctx index state →
      ∃ finalState consumed,
        runCount state (bodySuffix bytes index count) = some (finalState, consumed) ∧
        fieldCount ctx index count = (consumed : F) := by
  induction count with
  | zero =>
    intro index state _ _
    exact ⟨state, 0, rfl, by simp [fieldCount, Semiring.natCast_zero]⟩
  | succ count ih =>
    intro index state endAt before
    have bound : index < 121 := by omega
    obtain ⟨next, step, nextState⟩ := boundary_step ctx bytes index bound state one bindings holds before
    obtain ⟨finalState, consumed, tail, countEq⟩ := ih (index+1) next (by omega) nextState
    refine ⟨finalState, active state + consumed, ?_, ?_⟩
    · simp [runCount, bodySuffix, step, tail]
    · simp only [fieldCount, countEq, active_matches_state ctx index bound state before, Semiring.natCast_add]

theorem run_count_projects (bytes : List (Fin 256)) : ∀ state finalState count,
    runCount state bytes = some (finalState, count) →
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) state bytes = some finalState := by
  induction bytes with
  | nil => intro state finalState count run; simp_all [runCount, ByteStream.runRows]
  | cons byte rest ih =>
    intro state finalState count run
    cases step : ByteStream.boundRow ByteStream.referenceRow state byte with
    | none => simp [runCount, step] at run
    | some next =>
      cases tail : runCount next rest with
      | none => simp [runCount, step, tail] at run
      | some pair =>
        rcases pair with ⟨last, n⟩
        rw [runCount, step] at run
        dsimp only at run
        rw [tail] at run
        simp only [Option.some.injEq, Prod.mk.injEq] at run
        rcases run with ⟨rfl, rfl⟩
        simpa [ByteStream.runRows, step] using ih next last n tail

theorem run_count_bound (bytes : List (Fin 256)) : ∀ state finalState count,
    runCount state bytes = some (finalState, count) → count ≤ bytes.length := by
  induction bytes with
  | nil => intro state finalState count run; simp_all [runCount]
  | cons byte rest ih =>
    intro state finalState count run
    cases step : ByteStream.boundRow ByteStream.referenceRow state byte with
    | none => simp [runCount, step] at run
    | some next =>
      cases tail : runCount next rest with
      | none => simp [runCount, step, tail] at run
      | some pair =>
        rcases pair with ⟨last, n⟩
        rw [runCount, step] at run
        dsimp only at run
        rw [tail] at run
        simp only [Option.some.injEq, Prod.mk.injEq] at run
        rcases run with ⟨rfl, rfl⟩
        have tailBound := ih next last n tail
        have deltaBound : active state ≤ 1 := by simp [active]; split <;> omega
        simp only [List.length_cons]
        omega

theorem body_suffix_length (bytes : Fin 156 → Fin 256) (count : Nat) :
    ∀ start, (bodySuffix bytes start count).length = count := by
  induction count with
  | zero => intro start; rfl
  | succ count ih => intro start; simp [bodySuffix, ih]

theorem public_length_counts_active {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (length : Nat)
    (lengthBound : 36 ≤ length ∧ length ≤ 156) (one : ctx.get 0 = 1)
    (publicInputs : PublicBytesMatch ctx bytes) (publicLength : ctx.get 1 = (length : F))
    (holds : Satisfied byteShape ctx.get) :
    ∃ finalState, runCount (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 121) =
      some (finalState, length-35) := by
  have bindings := public_bytes_bind_all_bits ctx bytes one publicInputs holds
  obtain ⟨finalState, consumed, run, countEq⟩ := suffix_count_sound ctx bytes one bindings holds 121 0
    (⟨0, by decide⟩, ⟨0, by decide⟩) rfl (by simpa [AtState] using initial_state ctx one)
  have certificate := length_gate_matches
  have lengthHolds : R1CS.Holds ctx.get (interpretGate lengthGate) := by
    cases found : byteShape.gates[8187]? with
    | none => simp [found] at certificate
    | some actual =>
      apply same_gate_sound ctx _ actual (by simpa [found] using certificate)
      exact holds actual (by simpa using Array.mem_of_getElem? found)
  have equal := equality_gate ctx (counterLinear 0 121) (sub [(1, 1)] (constant 35)) one lengthHolds
  rw [counter_linear_value ctx one, countEq, BodySoundness.eval_sub, wire_value, publicLength,
    BodySoundness.eval_constant ctx.get one 35] at equal
  have lenEq : length = length-35+35 := by omega
  have fieldEq : (consumed : F) = ((length-35 : Nat) : F) := by
    rw [lenEq, Semiring.natCast_add] at equal
    grind
  have consumedBound := run_count_bound (bodySuffix bytes 0 121) _ _ _ run
  rw [body_suffix_length] at consumedBound
  have exactCount := bounded_nat_equal (F := F) consumed (length-35) (by omega) (by omega) fieldEq
  exact ⟨finalState, by simpa [exactCount] using run⟩

theorem finished_row_stays_finished (state next : ByteStream.State) (byte : Fin 256)
    (finished : state.1.val = 7)
    (step : ByteStream.boundRow ByteStream.referenceRow state byte = some next) :
    next = state ∧ byte.val = 0 := by
  rcases state with ⟨phase, height⟩
  have phaseEq : phase = (⟨7, by decide⟩ : Fin 8) := Fin.ext finished
  subst phase
  by_cases zero : byte.val = 0
  · have same : ((⟨7, by decide⟩ : Fin 8), height) = next := by
      simpa [ByteStream.boundRow, ByteStream.referenceRow, zero, height.isLt] using step
    exact ⟨same.symm, zero⟩
  · simp [ByteStream.boundRow, ByteStream.referenceRow, zero] at step

theorem run_count_finished (bytes : List (Fin 256)) : ∀ state finalState count,
    state.1.val = 7 → runCount state bytes = some (finalState, count) →
    finalState = state ∧ count = 0 := by
  induction bytes with
  | nil => intro state finalState count _ run; simp_all [runCount]
  | cons byte rest ih =>
    intro state finalState count finished run
    cases step : ByteStream.boundRow ByteStream.referenceRow state byte with
    | none => simp [runCount, step] at run
    | some next =>
      have same := (finished_row_stays_finished state next byte finished step).1
      subst next
      cases tail : runCount state rest with
      | none => simp [runCount, step, tail] at run
      | some pair =>
        rcases pair with ⟨last, n⟩
        rw [runCount, step] at run
        dsimp only at run
        rw [tail] at run
        simp only [Option.some.injEq, Prod.mk.injEq] at run
        rcases run with ⟨rfl, rfl⟩
        obtain ⟨same, zero⟩ := ih state last n finished tail
        exact ⟨same, by simp [active, finished, zero]⟩

theorem run_count_exact_prefix (bytes : List (Fin 256)) : ∀ state finalState count,
    runCount state bytes = some (finalState, count) → finalState.1.val = 7 →
    runExact state (bytes.take count) = some finalState := by
  induction bytes with
  | nil =>
    intro state finalState count run finished
    simp only [runCount, Option.some.injEq, Prod.mk.injEq] at run
    rcases run with ⟨rfl, rfl⟩
    simp [runExact, finished]
  | cons byte rest ih =>
    intro state finalState count run finished
    by_cases already : state.1.val = 7
    · obtain ⟨same, zero⟩ := run_count_finished (byte :: rest) state finalState count already run
      simp [zero, same, runExact, already]
    · cases step : ByteStream.boundRow ByteStream.referenceRow state byte with
      | none => simp [runCount, step] at run
      | some next =>
        cases tail : runCount next rest with
        | none => simp [runCount, step, tail] at run
        | some pair =>
          rcases pair with ⟨last, n⟩
          rw [runCount, step] at run
          dsimp only at run
          rw [tail] at run
          simp only [Option.some.injEq, Prod.mk.injEq] at run
          rcases run with ⟨rfl, rfl⟩
          have exactTail := ih next last n tail finished
          simpa [active, already, runExact, step, Nat.add_comm] using exactTail

theorem take_body_suffix (bytes : Fin 156 → Fin 256) (amount : Nat) :
    ∀ start capacity, amount ≤ capacity →
      (bodySuffix bytes start capacity).take amount = bodySuffix bytes start amount := by
  induction amount with
  | zero => intro start capacity _; simp [bodySuffix]
  | succ amount ih =>
    intro start capacity bound
    cases capacity with
    | zero => omega
    | succ capacity =>
      simp only [bodySuffix, List.take_succ_cons]
      rw [ih (start+1) capacity (by omega)]

theorem certified_binary_profile {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (length : Nat)
    (lengthBound : 36 ≤ length ∧ length ≤ 156) (one : ctx.get 0 = 1)
    (publicInputs : PublicBytesMatch ctx bytes) (publicLength : ctx.get 1 = (length : F))
    (holds : Satisfied byteShape ctx.get) :
    HeaderValid bytes length ∧
      runExact (⟨0, by decide⟩, ⟨0, by decide⟩) (bodySuffix bytes 0 (length-35)) =
        some (⟨7, by decide⟩, ⟨1, by decide⟩) := by
  refine ⟨header_valid ctx bytes length lengthBound one publicInputs publicLength holds, ?_⟩
  obtain ⟨finalState, countRun⟩ := public_length_counts_active ctx bytes length lengthBound one publicInputs publicLength holds
  have projected := run_count_projects (bodySuffix bytes 0 121) _ _ _ countRun
  have completed := public_bytes_imply_body ctx bytes one publicInputs holds
  have stateEq : finalState = ((⟨7, by decide⟩ : Fin 8), (⟨1, by decide⟩ : Fin 9)) := by
    exact Option.some.inj (projected.symm.trans completed)
  have exactPrefix := run_count_exact_prefix (bodySuffix bytes 0 121) _ _ _ countRun (by rw [stateEq])
  rw [take_body_suffix bytes (length-35) 0 121 (by omega)] at exactPrefix
  simpa [stateEq] using exactPrefix

#print axioms public_length_counts_active
#print axioms certified_binary_profile

end ZkBuild.ExactLength
