import ByteCompileQueueStep

/- A decoder trace tied to the actual byte stream and every queue transition.
   Successful compilation implies that no non-nop operation was discarded. -/
namespace ZkBuild.ByteCompileDecodeTrace

open Lean.Grind CircuitShape FullMatrix BodySoundness ByteCompileComposition
open ByteCompileTransition ByteCompileScalarStep ByteCompileEvents ByteCompileQueueStep
attribute [local instance] Ring.intCast Semiring.natCast

structure Configuration where
  parser : ByteStream.State
  immediate : Int
  operations : List Op

def initial : Configuration := ⟨(⟨0, by decide⟩, ⟨0, by decide⟩), 0, []⟩

def advance (cfg : Configuration) (byte : Fin 256) : Option Configuration := do
  let next ← ByteStream.boundRow ByteStream.referenceRow cfg.parser byte
  return ⟨next, nextImmediate cfg.parser.1 byte cfg.immediate,
    cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩

def runDecoder : Configuration → List (Fin 256) → Option Configuration
  | cfg, [] => some cfg
  | cfg, byte :: rest => (advance cfg byte).bind fun next => runDecoder next rest

def encodedQueue {F : Type} [CommRing F] (ops : List Op) : List F :=
  (ByteCompileQueue.padded 16 (ops.map ByteCompileQueue.token)).map fun n : Nat => (n : F)

structure Invariant {F : Type} [CommRing F] (values : Nat → F) (index : Nat) (cfg : Configuration) : Prop where
  parser : AtState (byteContext values) index cfg.parser
  nonnegative : 0 ≤ cfg.immediate
  limited : cfg.immediate < (limit cfg.parser.1.val : Int)
  accumulator : ByteCompileAccumulator.valueAt values index = (cfg.immediate : F)
  length : cfg.operations.length ≤ 16
  nonnop : ∀ op ∈ cfg.operations, op ≠ .nop
  queue : queueList values index = encodedQueue cfg.operations

theorem event_has_room {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (index : Nat) (ops : List Op)
    (length : ops.length ≤ 16) (nonnop : ∀ op ∈ ops, op ≠ .nop)
    (queue : queueList values index = encodedQueue ops)
    (zero : queueAt values index ⟨0, by decide⟩ = 0) : ops.length < 16 := by
  by_cases room : ops.length < 16
  · exact room
  next full =>
  have count : ops.length = 16 := by omega
  cases ops with
  | nil => simp at count
  | cons op rest =>
    have same := congrArg (fun xs : List F => (xs[0]?).getD 0) queue
    have restCount : rest.length = 15 := by simp only [List.length_cons] at count; omega
    have sameHead : queueAt values index ⟨0, by decide⟩ = (ByteCompileQueue.token op : F) := by
      simpa [encodedQueue, ByteCompileQueue.padded, restCount, queueList] using same
    have tokenZero : (ByteCompileQueue.token op : F) = 0 := sameHead.symm.trans zero
    exact False.elim (nonnop op (by simp) ((ByteCompileQueue.field_token_zero (F := F) op).mp tokenZero))

theorem append_queue {F : Type} [CommRing F] (ops : List Op) (op : Op) (room : ops.length < 16) :
    (encodedQueue (F := F) ops).drop 1 ++ [(ByteCompileQueue.token op : F)] = encodedQueue (ops ++ [op]) := by
  have shifted := ByteCompileQueue.shift_padded 16 (ops.map ByteCompileQueue.token)
    (ByteCompileQueue.token op) (by simpa using room)
  have mapped := congrArg (fun xs : List Nat => xs.map fun n : Nat => (n : F)) shifted
  simpa [ByteCompileQueue.shift, encodedQueue, List.map_append, List.map_drop] using mapped

theorem step_invariant {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (bytes : Fin 156 → Fin 256) (one : values 0 = 1)
    (bindings : ∀ position, R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get position) = ((bytes position).val : F))
    (holds : Satisfied ByteCompileShape.shape values)
    (index : Fin 121) (cfg : Configuration) (before : Invariant values index.val cfg) :
    ∃ next, advance cfg (bodyByte bytes index.val) = some next ∧ Invariant values (index.val+1) next := by
  let byte := bodyByte bytes index.val
  obtain ⟨state, stepped, afterState⟩ := boundary_step (byteContext values) bytes index.val index.isLt cfg.parser
    (projected_one values one).1 bindings (byte_context_satisfied values holds) before.parser
  have ref := BinaryCompleteness.bound_row_reference cfg.parser state byte stepped
  have binding : R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get (moduleByteIndex index)) = (byte.val : F) := by
    simpa [byte, bodyByte, index.isLt] using bindings (moduleByteIndex index)
  have prior : ByteCompileRow.localValues values index 23 = (cfg.immediate : F) :=
    (ByteCompileAccumulator.previous_value values one index).trans before.accumulator
  obtain ⟨newField, tokenField, eventField⟩ := integer_transition values index cfg.parser.1 cfg.parser.2 byte cfg.immediate
    one before.parser binding holds prior
  have range := preserves_interval cfg.parser.1 cfg.parser.2 byte state.1.val state.2.val cfg.immediate ref
    ⟨before.nonnegative, before.limited⟩
  have interpreted := event_operation cfg.parser.1 cfg.parser.2 byte state.1.val state.2.val cfg.immediate ref
    ⟨before.nonnegative, before.limited⟩
  let next : Configuration := ⟨state, nextImmediate cfg.parser.1 byte cfg.immediate,
    cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩
  refine ⟨next, by simp [advance, stepped, next, byte], ?_⟩
  have accumulator : ByteCompileAccumulator.valueAt values (index.val+1) = (next.immediate : F) := by
    rw [← ByteCompileAccumulator.current_value values index]
    exact newField
  cases eventValue : eventOp cfg.parser.1 byte cfg.immediate with
  | none =>
    simp only [eventValue] at interpreted
    have noEvent : evalLinear (ByteCompileRow.localValues values index) ByteCompileRow.event = 0 := by
      rw [eventField, interpreted.1, Ring.intCast_zero]
    have unchanged := no_event values one holds index noEvent
    refine ⟨afterState, range.1, range.2, accumulator, ?_, ?_, ?_⟩
    · simpa [next, eventValue] using before.length
    · simpa [next, eventValue] using before.nonnop
    · simpa [next, eventValue] using unchanged.trans before.queue
  | some op =>
    simp only [eventValue] at interpreted
    have event : evalLinear (ByteCompileRow.localValues values index) ByteCompileRow.event = 1 := by
      rw [eventField, interpreted.1, Ring.intCast_one]
    have emitted : evalLinear (ByteCompileRow.localValues values index) ByteCompileRow.token = (ByteCompileQueue.token op : F) := by
      rw [tokenField, interpreted.2.1, Ring.intCast_natCast]
    have room := event_has_room values index.val cfg.operations before.length before.nonnop before.queue
      (event_head_zero values one holds index event)
    refine ⟨afterState, range.1, range.2, accumulator, ?_, ?_, ?_⟩
    · simp only [next, eventValue, Option.toList_some, List.length_append, List.length_singleton]
      omega
    · intro chosen member
      have member' : chosen ∈ cfg.operations ++ [op] := by simpa [next, eventValue] using member
      rcases List.mem_append.mp member' with old | last
      · exact before.nonnop chosen old
      · have equal : chosen = op := by simpa using last
        simpa [equal] using interpreted.2.2
    · rw [event_shift values one holds index event, before.queue, emitted, append_queue cfg.operations op room]
      simp [next, eventValue]

theorem run_invariant {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (bytes : Fin 156 → Fin 256) (one : values 0 = 1)
    (bindings : ∀ position, R1CS.weightedValues (BitPacking.bitWeights 8)
      (globalBits (byteContext values).get position) = ((bytes position).val : F))
    (holds : Satisfied ByteCompileShape.shape values) (count : Nat) :
    ∀ start cfg, start+count ≤ 121 → Invariant values start cfg →
      ∃ next, runDecoder cfg (bodySuffix bytes start count) = some next ∧ Invariant values (start+count) next := by
  induction count with
  | zero => intro start cfg _ inv; exact ⟨cfg, rfl, by simpa using inv⟩
  | succ count ih =>
    intro start cfg bound inv
    obtain ⟨middle, first, middleInv⟩ := step_invariant values bytes one bindings holds ⟨start, by omega⟩ cfg inv
    obtain ⟨last, tail, lastInv⟩ := ih (start+1) middle (by omega) middleInv
    refine ⟨last, ?_, ?_⟩
    · simpa only [bodySuffix, runDecoder, first, Option.bind_some] using tail
    · simpa only [Nat.add_assoc, Nat.add_comm 1 count] using lastInv

theorem initial_invariant {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) : Invariant values 0 initial := by
  refine ⟨?_, by simp [initial], by decide, ?_, by simp [initial], by simp [initial], ?_⟩
  · simpa [initial, AtState] using initial_state (byteContext values) (projected_one values one).1
  · simp [ByteCompileAccumulator.valueAt, initial, Ring.intCast_zero]
  · rw [initial_queue]
    simp [initial, encodedQueue, ByteCompileQueue.padded, Semiring.natCast_zero]

theorem decoded_queue {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (wasm : List (Fin 256)) (one : values 0 = 1)
    (inputs : PublicRaw values wasm) (holds : Satisfied ByteCompileShape.shape values) :
    ∃ final, runDecoder initial (bodySuffix (BinarySoundness.paddedBytes wasm) 0 121) = some final ∧
      final.operations.length ≤ 16 ∧ (∀ op ∈ final.operations, op ≠ .nop) ∧
      queueList values 121 = encodedQueue final.operations := by
  have bindings := PublicBinding.public_bytes_bind_all_bits (byteContext values)
    (BinarySoundness.paddedBytes wasm) (projected_one values one).1
    (projected_raw values wasm inputs).2 (byte_context_satisfied values holds)
  obtain ⟨final, decoded, inv⟩ := run_invariant values (BinarySoundness.paddedBytes wasm) one bindings holds
    121 0 initial (by decide) (initial_invariant values one)
  exact ⟨final, decoded, inv.length, inv.nonnop, inv.queue⟩

#print axioms decoded_queue

end ZkBuild.ByteCompileDecodeTrace
