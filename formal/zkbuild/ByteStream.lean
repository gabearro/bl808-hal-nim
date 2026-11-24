import ZkBuild

/- The byte-parser row is checked in two independent forms: a direct state
   machine and the one-hot arithmetic equations used by the circuit. This
   proves their equality for every bounded phase, height and byte. It does
   not assume that a host parser accepts the input. -/
namespace ZkBuild.ByteStream

-- Phase 0: opcode; 1: local index; 2..6: LEB byte 1..5; 7: finished.
def opcode (action : Nat) : Nat :=
  match action with
  | 0 => 1 | 1 => 32 | 2 => 65 | 3 => 106 | 4 => 107
  | 5 => 108 | 6 => 113 | 7 => 114 | 8 => 115 | 9 => 11
  | _ => 0

def referenceRow (phase height byte : Nat) : Option (Nat × Nat) :=
  if phase = 0 then
    if byte = 1 then some (0, height)
    else if byte = 32 then some (1, height)
    else if byte = 65 then some (2, height)
    else if byte = 11 then
      if height = 1 then some (7, height) else none
    else if byte ∈ [106, 107, 108, 113, 114, 115] then
      if 2 ≤ height then some (0, height - 1) else none
    else none
  else if phase = 1 then
    if byte < 2 ∧ height < 8 then some (0, height + 1) else none
  else if phase < 7 then
    if phase = 6 ∧ (128 ≤ byte ∨ (byte &&& 120 ≠ 0 ∧ byte &&& 120 ≠ 120)) then none
    else if 128 ≤ byte then some (phase + 1, height)
    else if height < 8 then some (0, height + 1) else none
  else if byte = 0 then some (7, height) else none

private def flag (condition : Prop) [Decidable condition] : Nat :=
  if condition then 1 else 0

private def sumTo (n : Nat) (f : Nat → Nat) : Nat := ((List.range n).map f).sum

def arithmeticRow (phase height byte : Nat) : Option (Nat × Nat) := Id.run do
  let ready := flag (phase = 0)
  let index := flag (phase = 1)
  let leb := fun i => flag (phase = i+2)
  let done := flag (phase = 7)
  let selected := fun i => flag (phase = 0 ∧ byte = opcode i)
  let continuation := byte / 128
  if done * byte ≠ 0 then return none
  if sumTo 10 selected ≠ ready then return none
  if ready * byte ≠ sumTo 10 (fun i => selected i * opcode i) then return none
  if index = 1 ∧ byte ≥ 2 then return none
  if leb 4 * continuation ≠ 0 then return none
  if leb 4 = 1 ∧ ((byte / 16) % 2 ≠ (byte / 8) % 2 ∨
                   (byte / 32) % 2 ≠ (byte / 8) % 2 ∨
                   (byte / 64) % 2 ≠ (byte / 8) % 2) then return none
  let finish := sumTo 5 leb * (1 - continuation)
  let push := index + finish
  let binary := sumTo 6 (fun i => selected (i+3))
  if binary = 1 ∧ height < 2 then return none
  let keep := 1 - push - binary
  let nextDepth := fun d =>
    flag (height = d) * keep +
    (if 0 < d then flag (height = d-1) * push else 0) +
    (if d < 8 then flag (height = d+1) * binary else 0)
  if sumTo 9 nextDepth ≠ 1 then return none
  if selected 9 = 1 ∧ height ≠ 1 then return none
  let nextLeb := fun i => if i = 0 then selected 2 else leb (i-1) * continuation
  let nextReady := selected 0 + binary + index + finish
  let nextIndex := selected 1
  let nextDone := done + selected 9
  if nextReady + nextIndex + sumTo 5 nextLeb + nextDone ≠ 1 then return none
  let outPhase := nextIndex + sumTo 5 (fun i => (i+2) * nextLeb i) + 7 * nextDone
  let outHeight := sumTo 9 (fun i => i * nextDepth i)
  return some (outPhase, outHeight)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem arithmetic_row_refines_parser :
    ∀ (phase : Fin 8) (height : Fin 9) (byte : Fin 256),
      arithmeticRow phase.val height.val byte.val =
      referenceRow phase.val height.val byte.val := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem successful_row_stays_bounded :
    ∀ (phase : Fin 8) (height : Fin 9) (byte : Fin 256),
      (match referenceRow phase.val height.val byte.val with
      | none => true
      | some (nextPhase, nextHeight) => decide (nextPhase < 8 ∧ nextHeight < 9)) = true := by
  native_decide

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem opcode_values_unique :
    ∀ (a b : Fin 10), opcode a.val = opcode b.val → a = b := by
  decide

abbrev State := Fin 8 × Fin 9

def boundRow (row : Nat → Nat → Nat → Option (Nat × Nat))
    (state : State) (byte : Fin 256) : Option State :=
  match row state.1.val state.2.val byte.val with
  | none => none
  | some (phase, height) =>
    if h : phase < 8 ∧ height < 9 then some (⟨phase, h.1⟩, ⟨height, h.2⟩) else none

def runRows (row : State → Fin 256 → Option State) : State → List (Fin 256) → Option State
  | state, [] => some state
  | state, byte :: rest => (row state byte).bind (fun next => runRows row next rest)

theorem byte_stream_refinement (state : State) (bytes : List (Fin 256)) :
    runRows (boundRow arithmeticRow) state bytes =
    runRows (boundRow referenceRow) state bytes := by
  have rowsEqual : boundRow arithmeticRow = boundRow referenceRow := by
    funext s b
    simp only [boundRow, arithmetic_row_refines_parser s.1 s.2 b]
  rw [rowsEqual]

def event (phase byte : Nat) : Op :=
  if phase = 1 then .get ⟨0, by decide⟩
  else if 2 ≤ phase ∧ phase ≤ 6 ∧ byte < 128 then .const 0
  else if phase = 0 ∧ byte ∈ [106, 107, 108, 113, 114, 115] then .binary .add
  else .nop

-- Values and binary operator identities do not affect i32 type transitions.
-- The representative events here certify operand availability, not evaluation
-- equivalence of different constants or binary operators.
set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem reference_row_type_transition :
    ∀ (phase : Fin 8) (height : Fin 9) (byte : Fin 256),
      (match referenceRow phase.val height.val byte.val with
       | none => true
       | some (_, nextHeight) =>
         decide (checkStep (event phase.val byte.val) height.val = some nextHeight)) = true := by
  native_decide

theorem bounded_row_type_transition (s next : State) (b : Fin 256)
    (ok : boundRow referenceRow s b = some next) :
    checkStep (event s.1.val b.val) s.2.val = some next.2.val := by
  have valid := reference_row_type_transition s.1 s.2 b
  unfold boundRow at ok
  cases h : referenceRow s.1.val s.2.val b.val with
  | none => simp [h] at ok
  | some pair =>
    rcases pair with ⟨p, depth⟩
    simp only [h] at ok
    split at ok
    next bound =>
      cases ok
      simpa [h] using valid
    next => simp at ok

def typeTrace : State → List (Fin 256) → Option (State × List Op)
  | state, [] => some (state, [])
  | state, byte :: rest =>
    match boundRow referenceRow state byte with
    | none => none
    | some next =>
      match typeTrace next rest with
      | none => none
      | some (finalState, events) => some (finalState, event state.1.val byte.val :: events)

theorem type_trace_checked (bytes : List (Fin 256)) :
    ∀ initial finalState events,
      typeTrace initial bytes = some (finalState, events) →
      checkProgram events initial.2.val = some finalState.2.val := by
  induction bytes with
  | nil =>
    intro initial finalState events h
    simp only [typeTrace, Option.some.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    rfl
  | cons b rest ih =>
    intro initial finalState events h
    cases nextOk : boundRow referenceRow initial b with
    | none => simp [typeTrace, nextOk] at h
    | some next =>
      cases tailOk : typeTrace next rest with
      | none => simp [typeTrace, nextOk, tailOk] at h
      | some tailState =>
        rcases tailState with ⟨last, tailEvents⟩
        simp only [typeTrace, nextOk, tailOk, Option.some.injEq, Prod.mk.injEq] at h
        rcases h with ⟨rfl, rfl⟩
        have stepOk := bounded_row_type_transition initial next b nextOk
        simp only [checkProgram, stepOk, Option.bind_some]
        exact ih next last tailEvents tailOk

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem finished_height_certificate :
    ∀ (phase : Fin 8) (height : Fin 9) (byte : Fin 256),
      (match referenceRow phase.val height.val byte.val with
      | none => true
      | some (nextPhase, nextHeight) =>
        decide ((phase.val = 7 → height.val = 1) → (nextPhase = 7 → nextHeight = 1))) = true := by
  native_decide

theorem bounded_row_finished_height (state next : State) (byte : Fin 256)
    (step : boundRow referenceRow state byte = some next)
    (initial : state.1.val = 7 → state.2.val = 1) :
    next.1.val = 7 → next.2.val = 1 := by
  have fact := finished_height_certificate state.1 state.2 byte
  unfold boundRow at step
  cases row : referenceRow state.1.val state.2.val byte.val with
  | none => simp [row] at step
  | some pair =>
    rcases pair with ⟨phase, height⟩
    simp only [row] at step
    split at step
    next bounded =>
      cases step
      have implication : (state.1.val = 7 → state.2.val = 1) → (phase = 7 → height = 1) := by
        simpa only [row, decide_eq_true_eq] using fact
      exact implication initial
    next => simp at step

theorem run_preserves_finished_height (bytes : List (Fin 256)) :
    ∀ initial finalState,
      runRows (boundRow referenceRow) initial bytes = some finalState →
      (initial.1.val = 7 → initial.2.val = 1) →
      (finalState.1.val = 7 → finalState.2.val = 1) := by
  induction bytes with
  | nil =>
    intro initial finalState run property
    simp only [runRows, Option.some.injEq] at run
    cases run
    exact property
  | cons byte rest ih =>
    intro initial finalState run property
    simp only [runRows, Option.bind_eq_some_iff] at run
    obtain ⟨next, step, tail⟩ := run
    exact ih next finalState tail (bounded_row_finished_height initial next byte step property)

#print axioms arithmetic_row_refines_parser
#print axioms successful_row_stays_bounded
#print axioms opcode_values_unique
#print axioms byte_stream_refinement
#print axioms type_trace_checked
#print axioms run_preserves_finished_height

end ZkBuild.ByteStream
