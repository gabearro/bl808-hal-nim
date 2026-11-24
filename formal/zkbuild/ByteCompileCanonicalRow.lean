import ByteCompileRowComplete
import ByteCompileConstructionTrace

/- A bridge witness constructed from a real decoder state and byte. The
   overflow gate follows from acceptance of the remaining bounded program. -/
namespace ZkBuild.ByteCompileCanonicalRow

open Lean.Grind CircuitShape FullMatrix RowSoundness ByteCompileTransition
open ByteCompileDecodeTrace ByteCompileEvents ByteCompileConstructionTrace
attribute [local instance] Ring.intCast Semiring.natCast

def inputValue (cfg : Configuration) (byte : Fin 256) (k : Nat) : Int :=
  if k < 23 then ByteCompileDecodeRow.canonical cfg.parser.1 byte k
  else if k = 23 then cfg.immediate
  else ((encodedQueue (F := Int) cfg.operations)[k-24]?).getD 0

def inputs (cfg : Configuration) (byte : Fin 256) : Lean.RArray Int :=
  Lean.RArray.ofFn (fun k : Fin 40 => inputValue cfg byte k.val) (by decide)

def values (cfg : Configuration) (byte : Fin 256) : Nat → Int :=
  ByteCompileRowComplete.fieldWitness (inputs cfg byte)

theorem input_at (cfg : Configuration) (byte : Fin 256) (k : Nat) (bound : k < 40) :
    (inputs cfg byte).get k = inputValue cfg byte k :=
  Lean.RArray.get_ofFn (fun k : Fin 40 => inputValue cfg byte k.val) (by decide) ⟨k, bound⟩

theorem input_one (cfg : Configuration) (byte : Fin 256) : (inputs cfg byte).get 0 = 1 := by
  rw [input_at cfg byte 0 (by decide)]
  rfl

theorem value_input (cfg : Configuration) (byte : Fin 256) (k : Nat) (bound : k < 40) :
    values cfg byte k = inputValue cfg byte k := by
  rw [values, ByteCompileRowComplete.input_value _ (input_one cfg byte) k bound, input_at cfg byte k bound]

theorem queue_length (ops : List Op) (fits : ops.length ≤ 16) :
    (encodedQueue (F := Int) ops).length = 16 := by
  simp only [encodedQueue, ByteCompileQueue.padded, List.length_map,
    List.length_append, List.length_replicate]
  omega

theorem values_one (cfg : Configuration) (byte : Fin 256) : values cfg byte 0 = 1 := by
  rw [value_input cfg byte 0 (by decide)]
  rfl

theorem expression_below (cfg : Configuration) (byte : Fin 256) (expression : Expr)
    (bound : InputNormalization.UsesBelow 23 expression = true) :
    evalField (inputs cfg byte).get expression = evalInt (ByteCompileDecodeRow.canonical cfg.parser.1 byte) expression := by
  rw [InputNormalization.eval_congr_below (inputs cfg byte).get
    (ByteCompileDecodeRow.canonical cfg.parser.1 byte) 23 _ expression bound, ByteCompileScalarStep.eval_field_int]
  intro k small
  rw [input_at cfg byte k (by omega)]
  simp [inputValue, small]

theorem expression_immediate (cfg : Configuration) (byte : Fin 256) (expression : Expr)
    (bound : InputNormalization.UsesBelow 24 expression = true) :
    evalField (inputs cfg byte).get expression = evalInt (integerInputs cfg.parser.1 byte cfg.immediate) expression := by
  rw [InputNormalization.eval_congr_below (inputs cfg byte).get
    (integerInputs cfg.parser.1 byte cfg.immediate) 24 _ expression bound, ByteCompileScalarStep.eval_field_int]
  intro k small
  rw [input_at cfg byte k (by omega)]
  by_cases last : k = 23
  · simp [last, inputValue, integerInputs]
  · have before : k < 23 := by omega
    simp [inputValue, integerInputs, before, last]

theorem input_event (cfg : Configuration) (byte : Fin 256) :
    evalField (inputs cfg byte).get eventExpr = emittedEvent cfg.parser.1 byte :=
  expression_below cfg byte eventExpr transition_uses.2.2

theorem value_event (cfg : Configuration) (byte : Fin 256) :
    evalLinear (values cfg byte) ByteCompileRow.event = emittedEvent cfg.parser.1 byte := by
  rw [← direct_expression_sound]
  change evalField (values cfg byte) eventExpr = _
  rw [InputNormalization.eval_congr_below (values cfg byte) (inputs cfg byte).get 23 _ eventExpr transition_uses.2.2]
  · exact input_event cfg byte
  · intro k small
    exact ByteCompileRowComplete.input_value _ (input_one cfg byte) k (by omega)

theorem value_immediate (cfg : Configuration) (byte : Fin 256) :
    values cfg byte 48 = nextImmediate cfg.parser.1 byte cfg.immediate := by
  have output := ByteCompileRowComplete.output_value (inputs cfg byte) ⟨8, by decide⟩
  change values cfg byte 48 = evalField (inputs cfg byte).get immediateExpr at output
  exact output.trans (expression_immediate cfg byte immediateExpr transition_uses.1)

theorem no_overflow (cfg final : Configuration) (byte : Fin 256) (rest : List (Fin 256))
    (range : InRange cfg) (accepted : runDecoder cfg (byte :: rest) = some final)
    (fits : final.operations.length ≤ 16) :
    evalField (inputs cfg byte).get ByteCompileRowComplete.overflowExpr = 0 := by
  have stepped := after_step (byte :: rest) cfg final 0 (by simp) accepted
  have reference := BinaryCompleteness.bound_row_reference cfg.parser
    (after cfg (byte :: rest) 1).parser byte (ByteCompileTyping.advance_parser _ _ _ stepped)
  have interpreted := event_operation cfg.parser.1 cfg.parser.2 byte _ _ cfg.immediate reference range
  change evalField (inputs cfg byte).get eventExpr * (inputs cfg byte).get 24 = 0
  rw [input_event]
  cases event : eventOp cfg.parser.1 byte cfg.immediate with
  | none =>
    rw [event] at interpreted
    rw [interpreted.1]
    exact Int.zero_mul _
  | some op =>
    rw [event] at interpreted
    have room : cfg.operations.length < 16 := by
      simpa only [after] using emission_has_room (byte :: rest) cfg final accepted fits 0 (by simp) op event
    have head := ByteCompileQueue.padded_head_zero 16 (cfg.operations.map ByteCompileQueue.token)
      (by simpa using room)
    have zero : (inputs cfg byte).get 24 = 0 := by
      rw [input_at cfg byte 24 (by decide)]
      simp only [inputValue, show ¬24 < 23 by decide, ite_false, show ¬24 = 23 by decide,
        Nat.sub_self, encodedQueue]
      rw [List.getElem?_map]
      have first : (ByteCompileQueue.padded 16 (cfg.operations.map ByteCompileQueue.token))[0]? = some 0 := by
        simpa only [List.head?_eq_getElem?] using head
      simp [first]
    rw [zero]
    exact Int.mul_zero _

theorem complete (cfg final : Configuration) (byte : Fin 256) (rest : List (Fin 256))
    (range : InRange cfg) (accepted : runDecoder cfg (byte :: rest) = some final)
    (fits : final.operations.length ≤ 16) : ByteCompileRow.Holds (values cfg byte) :=
  ByteCompileRowComplete.row_complete (inputs cfg byte) (no_overflow cfg final byte rest range accepted fits)

def inputQueue (cfg : Configuration) (byte : Fin 256) : List Int :=
  List.ofFn fun j : Fin 16 => values cfg byte (24+j.val)

def outputQueue (cfg : Configuration) (byte : Fin 256) : List Int :=
  List.ofFn fun j : Fin 16 => values cfg byte (51+j.val)

theorem input_queue (cfg : Configuration) (byte : Fin 256) (fits : cfg.operations.length ≤ 16) :
    inputQueue cfg byte = encodedQueue cfg.operations := by
  apply List.ext_getElem
  · simp [inputQueue, queue_length cfg.operations fits]
  · intro k left right
    have small : k < 16 := by simpa [inputQueue] using left
    simp only [inputQueue, List.getElem_ofFn, value_input cfg byte (24+k) (by omega)]
    simp only [inputValue, show ¬24+k < 23 by omega, ite_false,
      show ¬24+k = 23 by omega, show 24+k-24 = k by omega,
      List.getElem?_eq_getElem right, Option.getD_some]

theorem value_token (cfg : Configuration) (byte : Fin 256)
    (holds : ByteCompileRow.Holds (values cfg byte)) :
    evalLinear (values cfg byte) ByteCompileRow.token = emittedToken cfg.parser.1 byte cfg.immediate := by
  rw [ByteCompileTransition.token_value (values cfg byte) (values_one cfg byte) holds]
  rw [InputNormalization.eval_congr_below (values cfg byte) (inputs cfg byte).get 24 _ tokenExpr transition_uses.2.1]
  · exact expression_immediate cfg byte tokenExpr transition_uses.2.1
  · intro k small
    exact ByteCompileRowComplete.input_value _ (input_one cfg byte) k (by omega)

theorem selected_queue (cfg : Configuration) (byte : Fin 256) (j : Fin 16) :
    evalLinear (values cfg byte) (ByteCompileRow.queueYes j.val) =
      if j.val+1 < 16 then values cfg byte (25+j.val) else evalLinear (values cfg byte) ByteCompileRow.token := by
  by_cases more : j.val+1 < 16 <;> simp [ByteCompileRow.queueYes, more, ByteCompileRow.eval_wire]

theorem queue_unchanged (cfg : Configuration) (byte : Fin 256)
    (holds : ByteCompileRow.Holds (values cfg byte)) (event : emittedEvent cfg.parser.1 byte = 0) :
    outputQueue cfg byte = inputQueue cfg byte := by
  apply congrArg List.ofFn
  funext j
  have equation := ByteCompileRow.queue_equation (values cfg byte) holds j
  rw [value_event, event] at equation
  simpa only [Int.zero_mul, Int.add_zero] using equation

theorem queue_shifted (cfg : Configuration) (byte : Fin 256)
    (holds : ByteCompileRow.Holds (values cfg byte)) (event : emittedEvent cfg.parser.1 byte = 1) :
    outputQueue cfg byte = (inputQueue cfg byte).drop 1 ++
      [evalLinear (values cfg byte) ByteCompileRow.token] := by
  rw [outputQueue, inputQueue, ← ByteCompileQueueStep.ofFn_shift]
  apply congrArg List.ofFn
  funext j
  have equation := ByteCompileRow.queue_equation (values cfg byte) holds j
  rw [value_event, event, selected_queue] at equation
  by_cases more : j.val+1 < 16
  · simp only [more, ite_true, dite_true, Int.one_mul] at equation ⊢
    have same : 25+j.val = 24+(j.val+1) := by omega
    rw [same] at equation
    omega
  · simp only [more, ite_false, dite_false, Int.one_mul] at equation ⊢
    omega

theorem next_queue (cfg next final : Configuration) (byte : Fin 256) (rest : List (Fin 256))
    (range : InRange cfg) (stepped : advance cfg byte = some next)
    (tail : runDecoder next rest = some final) (fits : final.operations.length ≤ 16) :
    outputQueue cfg byte = encodedQueue next.operations := by
  have accepted : runDecoder cfg (byte :: rest) = some final := by simp [runDecoder, stepped, tail]
  have prefixFits : cfg.operations.length ≤ 16 :=
    Nat.le_trans (run_length (byte :: rest) cfg final accepted) fits
  have holds := complete cfg final byte rest range accepted fits
  have reference := BinaryCompleteness.bound_row_reference cfg.parser next.parser byte
    (ByteCompileTyping.advance_parser cfg next byte stepped)
  have interpreted := event_operation cfg.parser.1 cfg.parser.2 byte _ _ cfg.immediate reference range
  have operations := advance_operations cfg next byte stepped
  cases event : eventOp cfg.parser.1 byte cfg.immediate with
  | none =>
    rw [event] at interpreted operations
    rw [queue_unchanged cfg byte holds interpreted.1, input_queue cfg byte prefixFits, operations]
    simp
  | some op =>
    rw [event] at interpreted operations
    have room : cfg.operations.length < 16 := by
      simpa only [after] using emission_has_room (byte :: rest) cfg final accepted fits 0 (by simp) op event
    rw [queue_shifted cfg byte holds interpreted.1, input_queue cfg byte prefixFits,
      value_token cfg byte holds, interpreted.2.1, ByteCompileDecodeTrace.append_queue cfg.operations op room,
      operations]
    rfl

theorem next_immediate (cfg next : Configuration) (byte : Fin 256)
    (stepped : advance cfg byte = some next) : values cfg byte 48 = next.immediate := by
  rw [value_immediate, advance_immediate cfg next byte stepped]

theorem linear_cast {F : Type} [CommRing F] (integers : Nat → Int) (linear : Linear) :
    evalLinear (fun k => (integers k : F)) linear = ((evalLinear (F := Int) integers linear : Int) : F) := by
  rw [← direct_expression_sound, integer_interpretation_commutes]
  have same : evalInt integers (directExpression linear) = evalLinear integers linear := by
    rw [← ByteCompileScalarStep.eval_field_int, direct_expression_sound]
  rw [same]

theorem complete_field {F : Type} [CommRing F] (cfg final : Configuration) (byte : Fin 256)
    (rest : List (Fin 256)) (range : InRange cfg) (accepted : runDecoder cfg (byte :: rest) = some final)
    (fits : final.operations.length ≤ 16) : ByteCompileRow.Holds (fun k => (values cfg byte k : F)) := by
  intro i
  have integerHolds := complete cfg final byte rest range accepted fits i
  change evalLinear (values cfg byte) (ByteCompileRow.gate i.val).a *
    evalLinear (values cfg byte) (ByteCompileRow.gate i.val).b =
      evalLinear (values cfg byte) (ByteCompileRow.gate i.val).c at integerHolds
  change evalLinear _ (ByteCompileRow.gate i.val).a * evalLinear _ (ByteCompileRow.gate i.val).b =
    evalLinear _ (ByteCompileRow.gate i.val).c
  rw [linear_cast, linear_cast, linear_cast, ← Ring.intCast_mul, integerHolds]

#print axioms complete_field
#print axioms next_queue
#print axioms next_immediate

end ZkBuild.ByteCompileCanonicalRow
