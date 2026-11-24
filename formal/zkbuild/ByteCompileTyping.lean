import ByteCompileSoundness

/- Accepted byte decoding produces a checked program without assuming that
   any compilation witness already exists. This is the completeness direction. -/
namespace ZkBuild.ByteCompileTyping

open ByteCompileEvents ByteCompileDecodeTrace ByteCompileSoundness

def eventTypeCertificate (p : Fin 8) (h : Fin 9) (b : Fin 256) : Bool :=
  match ByteStream.referenceRow p.val h.val b.val with
  | none => true
  | some (_, nextHeight) =>
    if kind p b = 0 then decide (nextHeight = h.val)
    else decide (checkStep (SlotProgram.operationKind ⟨kind p b, kind_bound p b⟩) h.val = some nextHeight)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem event_type_certificate : ∀ p h b, eventTypeCertificate p h b = true := by native_decide

theorem checked_event (p : Fin 8) (h : Fin 9) (b : Fin 256) (np nh : Nat) (previous : Int)
    (accepted : ByteStream.referenceRow p.val h.val b.val = some (np, nh)) :
    checkProgram (eventOp p b previous).toList h.val = some nh := by
  have certificate := event_type_certificate p h b
  by_cases empty : kind p b = 0
  · have same : nh = h.val := by simpa [eventTypeCertificate, accepted, empty] using certificate
    simp [eventOp, empty, checkProgram, same]
  · have step : checkStep (SlotProgram.operationKind ⟨kind p b, kind_bound p b⟩) h.val = some nh := by
      simpa [eventTypeCertificate, accepted, empty] using certificate
    simp only [eventOp, empty, ite_false, Option.toList_some, checkProgram,
      SlotNative.operation, SlotProgram.immediate_preserves_check, step, Option.bind_some]

theorem check_append (first second : List Op) (height : Nat) :
    checkProgram (first ++ second) height = (checkProgram first height).bind (checkProgram second) := by
  induction first generalizing height with
  | nil => rfl
  | cons op rest ih =>
    cases stepping : checkStep op height with
    | none => simp [checkProgram, stepping]
    | some next => simp [checkProgram, stepping, ih next]

theorem advance_typed (cfg next : Configuration) (byte : Fin 256)
    (typed : checkProgram cfg.operations 0 = some cfg.parser.2.val)
    (accepted : advance cfg byte = some next) : checkProgram next.operations 0 = some next.parser.2.val := by
  cases stepping : ByteStream.boundRow ByteStream.referenceRow cfg.parser byte with
  | none => simp [advance, stepping] at accepted
  | some state =>
    have ref := BinaryCompleteness.bound_row_reference cfg.parser state byte stepping
    have same : next = ⟨state, ByteCompileTransition.nextImmediate cfg.parser.1 byte cfg.immediate,
        cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩ := by
      simpa [advance, stepping] using accepted.symm
    rw [same]
    change checkProgram (cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList) 0 = some state.2.val
    rw [check_append, typed, Option.bind_some]
    exact checked_event cfg.parser.1 cfg.parser.2 byte state.1.val state.2.val cfg.immediate ref

theorem advance_parser (cfg next : Configuration) (byte : Fin 256)
    (accepted : advance cfg byte = some next) :
    ByteStream.boundRow ByteStream.referenceRow cfg.parser byte = some next.parser := by
  cases stepping : ByteStream.boundRow ByteStream.referenceRow cfg.parser byte with
  | none => simp [advance, stepping] at accepted
  | some state =>
    have same : next = ⟨state, ByteCompileTransition.nextImmediate cfg.parser.1 byte cfg.immediate,
        cfg.operations ++ (eventOp cfg.parser.1 byte cfg.immediate).toList⟩ := by
      simpa [advance, stepping] using accepted.symm
    rw [same]

theorem run_typed (bytes : List (Fin 256)) : ∀ cfg next,
    checkProgram cfg.operations 0 = some cfg.parser.2.val → runDecoder cfg bytes = some next →
    checkProgram next.operations 0 = some next.parser.2.val := by
  induction bytes with
  | nil =>
    intro cfg next typed accepted
    have same : cfg = next := by simpa [runDecoder] using accepted
    simpa only [← same] using typed
  | cons byte rest ih =>
    intro cfg next typed accepted
    cases stepping : advance cfg byte with
    | none => simp [runDecoder, stepping] at accepted
    | some middle =>
      exact ih middle next (advance_typed cfg middle byte typed stepping)
        (by simpa [runDecoder, stepping] using accepted)

theorem run_parser (bytes : List (Fin 256)) : ∀ cfg next, runDecoder cfg bytes = some next →
    ByteStream.runRows (ByteStream.boundRow ByteStream.referenceRow) cfg.parser bytes = some next.parser := by
  induction bytes with
  | nil =>
    intro cfg next accepted
    have same : cfg = next := by simpa [runDecoder] using accepted
    simp [ByteStream.runRows, same]
  | cons byte rest ih =>
    intro cfg next accepted
    cases stepping : advance cfg byte with
    | none => simp [runDecoder, stepping] at accepted
    | some middle =>
      have tail := ih middle next (by simpa [runDecoder, stepping] using accepted)
      simpa [ByteStream.runRows, advance_parser cfg middle byte stepping] using tail

theorem accepted_decoder (wasm : List (Fin 256)) (final : Configuration)
    (accepted : decodeBinary wasm = some final) :
    BinarySoundness.SupportedWasmBinary wasm ∧
      runDecoder initial (BodySoundness.bodySuffix (BinarySoundness.paddedBytes wasm) 0 121) = some final ∧
      final.operations.length ≤ 16 := by
  by_cases supported : BinarySoundness.SupportedWasmBinary wasm
  · cases running : runDecoder initial (BodySoundness.bodySuffix (BinarySoundness.paddedBytes wasm) 0 121) with
    | none => simp [decodeBinary, supported, running] at accepted
    | some actual =>
      by_cases fits : actual.operations.length ≤ 16
      · have same : actual = final := by simpa [decodeBinary, supported, running, fits] using accepted
        subst final
        exact ⟨supported, rfl, fits⟩
      · simp [decodeBinary, supported, running, fits] at accepted
  · simp [decodeBinary, supported] at accepted

theorem accepted_finished (wasm : List (Fin 256)) (final : Configuration)
    (accepted : decodeBinary wasm = some final) : final.parser.2.val = 1 := by
  obtain ⟨supported, decoded, _⟩ := accepted_decoder wasm final accepted
  have actual := run_parser _ initial final decoded
  have reference := ExactLength.run_count_projects _ _ _ _ (BinaryCompleteness.accepted_padded_count wasm supported)
  have same : final.parser = (⟨7, by decide⟩, ⟨1, by decide⟩) := Option.some.inj (actual.symm.trans reference)
  rw [same]

theorem checked_leading_nops (count : Nat) (ops : List Op) :
    checkProgram (List.replicate count .nop ++ ops) 0 = checkProgram ops 0 := by
  induction count with
  | zero => rfl
  | succ count ih => simpa [List.replicate_succ, checkProgram, checkStep] using ih

theorem decoded_program_checked (wasm : List (Fin 256)) (final : Configuration)
    (accepted : decodeBinary wasm = some final) :
    checkProgram (paddedProgram final.operations) 0 = some 1 := by
  have typed := run_typed _ initial final (by rfl) (accepted_decoder wasm final accepted).2.1
  rw [accepted_finished wasm final accepted] at typed
  simpa only [paddedProgram, checked_leading_nops] using typed

#print axioms decoded_program_checked

end ZkBuild.ByteCompileTyping
