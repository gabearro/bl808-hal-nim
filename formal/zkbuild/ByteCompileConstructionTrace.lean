import ByteCompileTyping

/- Constructive decoder facts, independent of any satisfying circuit witness.
   A bounded accepted result guarantees room at every operation emission. -/
namespace ZkBuild.ByteCompileConstructionTrace

open ByteCompileDecodeTrace ByteCompileEvents ByteCompileTyping

def after : Configuration → List (Fin 256) → Nat → Configuration
  | cfg, _, 0 => cfg
  | cfg, [], _+1 => cfg
  | cfg, byte :: rest, count+1 => after ((advance cfg byte).getD cfg) rest count

theorem advance_operations (cfg next : Configuration) (byte : Fin 256)
    (accepted : advance cfg byte = some next) :
    next.operations = cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList := by
  cases stepped : ByteStream.boundRow ByteStream.referenceRow cfg.parser byte with
  | none => simp [advance, stepped] at accepted
  | some state =>
    have equal : next = ⟨state, ByteCompileTransition.nextImmediate cfg.parser.1 byte cfg.immediate,
        cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩ := by
      simpa [advance, stepped] using accepted.symm
    rw [equal]

def InRange (cfg : Configuration) : Prop :=
  0 ≤ cfg.immediate ∧ cfg.immediate < (ByteCompileScalarStep.limit cfg.parser.1.val : Int)

theorem advance_immediate (cfg next : Configuration) (byte : Fin 256)
    (accepted : advance cfg byte = some next) :
    next.immediate = ByteCompileTransition.nextImmediate cfg.parser.1 byte cfg.immediate := by
  cases stepped : ByteStream.boundRow ByteStream.referenceRow cfg.parser byte with
  | none => simp [advance, stepped] at accepted
  | some state =>
    have equal : next = ⟨state, ByteCompileTransition.nextImmediate cfg.parser.1 byte cfg.immediate,
        cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩ := by
      simpa [advance, stepped] using accepted.symm
    rw [equal]

theorem advance_range (cfg next : Configuration) (byte : Fin 256)
    (range : InRange cfg) (accepted : advance cfg byte = some next) : InRange next := by
  have reference := BinaryCompleteness.bound_row_reference cfg.parser next.parser byte
    (advance_parser cfg next byte accepted)
  have limited := ByteCompileScalarStep.preserves_interval cfg.parser.1 cfg.parser.2 byte
    next.parser.1.val next.parser.2.val cfg.immediate reference range
  simpa only [InRange, advance_immediate cfg next byte accepted] using limited

theorem run_operations_suffix (bytes : List (Fin 256)) : ∀ cfg final,
    runDecoder cfg bytes = some final → ∃ suffix, final.operations = cfg.operations ++ suffix := by
  induction bytes with
  | nil =>
    intro cfg final accepted
    have same : cfg = final := by simpa [runDecoder] using accepted
    exact ⟨[], by simp [same]⟩
  | cons byte rest ih =>
    intro cfg final accepted
    cases stepped : advance cfg byte with
    | none => simp [runDecoder, stepped] at accepted
    | some next =>
      obtain ⟨suffix, tail⟩ := ih next final (by simpa [runDecoder, stepped] using accepted)
      exact ⟨(eventOp cfg.parser.1 byte cfg.immediate).toList ++ suffix,
        by rw [tail, advance_operations cfg next byte stepped, List.append_assoc]⟩

theorem run_length (bytes : List (Fin 256)) (cfg final : Configuration)
    (accepted : runDecoder cfg bytes = some final) : cfg.operations.length ≤ final.operations.length := by
  obtain ⟨suffix, equal⟩ := run_operations_suffix bytes cfg final accepted
  rw [equal, List.length_append]
  omega

theorem after_suffix (bytes : List (Fin 256)) : ∀ cfg final index,
    runDecoder cfg bytes = some final → runDecoder (after cfg bytes index) (bytes.drop index) = some final := by
  induction bytes with
  | nil =>
    intro cfg final index accepted
    cases index <;> simpa [after] using accepted
  | cons byte rest ih =>
    intro cfg final index accepted
    cases index with
    | zero => simpa [after] using accepted
    | succ index =>
      cases stepped : advance cfg byte with
      | none => simp [runDecoder, stepped] at accepted
      | some next =>
        simpa [after, stepped] using ih next final index (by simpa [runDecoder, stepped] using accepted)

theorem after_step (bytes : List (Fin 256)) : ∀ cfg final index (bound : index < bytes.length),
    runDecoder cfg bytes = some final →
      advance (after cfg bytes index) bytes[index] = some (after cfg bytes (index+1)) := by
  induction bytes with
  | nil => intro cfg final index bound; simp at bound
  | cons byte rest ih =>
    intro cfg final index bound accepted
    cases stepped : advance cfg byte with
    | none => simp [runDecoder, stepped] at accepted
    | some next =>
      have tail : runDecoder next rest = some final := by simpa [runDecoder, stepped] using accepted
      cases index with
      | zero => simp [after, stepped]
      | succ index =>
        simpa [after, stepped] using ih next final index (by simpa using bound) tail

theorem after_end (bytes : List (Fin 256)) : ∀ cfg final,
    runDecoder cfg bytes = some final → after cfg bytes bytes.length = final := by
  induction bytes with
  | nil => intro cfg final accepted; simpa [after, runDecoder] using accepted
  | cons byte rest ih =>
    intro cfg final accepted
    cases stepped : advance cfg byte with
    | none => simp [runDecoder, stepped] at accepted
    | some next =>
      simpa [after, stepped] using ih next final (by simpa [runDecoder, stepped] using accepted)

theorem after_parser (bytes : List (Fin 256)) : ∀ cfg final index,
    runDecoder cfg bytes = some final →
      (after cfg bytes index).parser = BinaryCompleteness.stateAfter cfg.parser bytes index := by
  induction bytes with
  | nil =>
    intro cfg final index accepted
    cases index <;> rfl
  | cons byte rest ih =>
    intro cfg final index accepted
    cases index with
    | zero => rfl
    | succ index =>
      cases stepped : advance cfg byte with
      | none => simp [runDecoder, stepped] at accepted
      | some next =>
        have parser := ByteCompileTyping.advance_parser cfg next byte stepped
        simpa [after, stepped, BinaryCompleteness.stateAfter, parser] using
          ih next final index (by simpa [runDecoder, stepped] using accepted)

theorem after_range (bytes : List (Fin 256)) (cfg final : Configuration)
    (accepted : runDecoder cfg bytes = some final) (range : InRange cfg)
    (index : Nat) (bound : index ≤ bytes.length) : InRange (after cfg bytes index) := by
  induction index with
  | zero => simpa only [after] using range
  | succ index ih =>
    exact advance_range _ _ _ (ih (by omega))
      (after_step bytes cfg final index (by omega) accepted)

theorem initial_range : InRange initial := by unfold InRange; decide

theorem emission_has_room (bytes : List (Fin 256)) (cfg final : Configuration)
    (accepted : runDecoder cfg bytes = some final) (fits : final.operations.length ≤ 16)
    (index : Nat) (bound : index < bytes.length) (op : Op)
    (event : eventOp (after cfg bytes index).parser.1 bytes[index] (after cfg bytes index).immediate = some op) :
    (after cfg bytes index).operations.length < 16 := by
  have step := after_step bytes cfg final index bound accepted
  have emitted := advance_operations _ _ _ step
  rw [event, Option.toList_some] at emitted
  have limited := run_length (bytes.drop (index+1)) (after cfg bytes (index+1)) final
    (after_suffix bytes cfg final (index+1) accepted)
  rw [emitted, List.length_append, List.length_singleton] at limited
  omega

theorem emission_head_zero (bytes : List (Fin 256)) (cfg final : Configuration)
    (accepted : runDecoder cfg bytes = some final) (fits : final.operations.length ≤ 16)
    (index : Nat) (bound : index < bytes.length) (op : Op)
    (event : eventOp (after cfg bytes index).parser.1 bytes[index] (after cfg bytes index).immediate = some op) :
    (ByteCompileQueue.padded 16 ((after cfg bytes index).operations.map ByteCompileQueue.token)).head? = some 0 := by
  apply ByteCompileQueue.padded_head_zero
  simpa using emission_has_room bytes cfg final accepted fits index bound op event

#print axioms emission_has_room
#print axioms emission_head_zero

end ZkBuild.ByteCompileConstructionTrace
