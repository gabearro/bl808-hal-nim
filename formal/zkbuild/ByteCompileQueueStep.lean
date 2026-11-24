import ByteCompileEvents

namespace ZkBuild.ByteCompileQueueStep

open Lean.Grind CircuitShape FullMatrix ByteCompileComposition
attribute [local instance] Ring.intCast Semiring.natCast

def queueAt {F : Type} [CommRing F] (values : Nat → F) (index : Nat) (slot : Fin 16) : F :=
  if index = 0 then 0 else values (17994+(index-1)*27+11+slot.val)

def queueList {F : Type} [CommRing F] (values : Nat → F) (index : Nat) : List F := List.ofFn (queueAt values index)

set_option maxRecDepth 100000 in
set_option maxHeartbeats 0 in
theorem queue_layout : ∀ (i : Fin 121) (slot : Fin 16),
    ByteCompileRow.rowMap i (24+slot.val) =
      (if i.val = 0 then constant 0 else ByteCompileRow.wire (17994+(i.val-1)*27+11+slot.val)) ∧
    ByteCompileRow.rowMap i (51+slot.val) = ByteCompileRow.wire (17994+i.val*27+11+slot.val) := by
  native_decide

theorem previous_queue {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (i : Fin 121) (slot : Fin 16) :
    ByteCompileRow.localValues values i (24+slot.val) = queueAt values i.val slot := by
  rw [ByteCompileRow.localValues, (queue_layout i slot).1]
  by_cases first : i.val = 0
  · simp [first, queueAt, ByteCompileRow.eval_constant values one, Ring.intCast_zero]
  · simp [first, queueAt, ByteCompileRow.eval_wire]

theorem next_queue {F : Type} [CommRing F] (values : Nat → F) (i : Fin 121) (slot : Fin 16) :
    ByteCompileRow.localValues values i (51+slot.val) = queueAt values (i.val+1) slot := by
  rw [ByteCompileRow.localValues, (queue_layout i slot).2, ByteCompileRow.eval_wire]
  simp [queueAt]

theorem initial_queue {F : Type} [CommRing F] (values : Nat → F) :
    queueList values 0 = List.replicate 16 (0 : F) := by rfl

theorem selected_input {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (i : Fin 121) (slot : Fin 16) :
    evalLinear (ByteCompileRow.localValues values i) (ByteCompileRow.queueYes slot.val) =
      if bound : slot.val+1 < 16 then queueAt values i.val ⟨slot.val+1, bound⟩
      else evalLinear (ByteCompileRow.localValues values i) ByteCompileRow.token := by
  unfold ByteCompileRow.queueYes
  split
  next bound =>
    rw [ByteCompileRow.eval_wire]
    have same : 25+slot.val = 24+(slot.val+1) := by omega
    rw [same, previous_queue values one i ⟨slot.val+1, bound⟩]
  next => rfl

theorem no_event {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : Satisfied ByteCompileShape.shape values) (i : Fin 121)
    (noEvent : evalLinear (ByteCompileRow.localValues values i) ByteCompileRow.event = 0) :
    queueList values (i.val+1) = queueList values i.val := by
  apply congrArg List.ofFn
  funext slot
  have eq := ByteCompileRow.queue_equation (ByteCompileRow.localValues values i)
    (ByteCompileRow.all_rows_hold values holds i) slot
  rw [noEvent, previous_queue values one i slot, next_queue values i slot] at eq
  simpa [Semiring.zero_mul, Semiring.add_zero] using eq

theorem event_head_zero {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : Satisfied ByteCompileShape.shape values) (i : Fin 121)
    (event : evalLinear (ByteCompileRow.localValues values i) ByteCompileRow.event = 1) :
    queueAt values i.val ⟨0, by decide⟩ = 0 := by
  have eq := ByteCompileRow.overflow_equation (ByteCompileRow.localValues values i)
    (ByteCompileRow.local_one values one i) (ByteCompileRow.all_rows_hold values holds i)
  rw [event] at eq
  simpa only [Semiring.one_mul, ← previous_queue values one i ⟨0, by decide⟩] using eq

theorem ofFn_shift {F : Type} (old : Fin 16 → F) (token : F) :
    (List.ofFn fun slot : Fin 16 => if bound : slot.val+1 < 16 then old ⟨slot.val+1, bound⟩ else token) =
      (List.ofFn old).drop 1 ++ [token] := by
  apply List.ext_getElem
  · simp
  · intro k left right
    have bound : k < 16 := by simpa using left
    by_cases more : k+1 < 16
    · have inDrop : k < ((List.ofFn old).drop 1).length := by simp; omega
      simp only [List.getElem_ofFn, more, dite_true, List.getElem_append_left inDrop, List.getElem_drop]
      exact congrArg old (Fin.ext (by change k+1 = 1+k; omega))
    · have last : k = 15 := by omega
      simp [last]

theorem event_shift {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (holds : Satisfied ByteCompileShape.shape values) (i : Fin 121)
    (event : evalLinear (ByteCompileRow.localValues values i) ByteCompileRow.event = 1) :
    queueList values (i.val+1) = (queueList values i.val).drop 1 ++
      [evalLinear (ByteCompileRow.localValues values i) ByteCompileRow.token] := by
  unfold queueList
  rw [← ofFn_shift]
  apply congrArg List.ofFn
  funext slot
  have eq := ByteCompileRow.queue_equation (ByteCompileRow.localValues values i)
    (ByteCompileRow.all_rows_hold values holds i) slot
  rw [event, previous_queue values one i slot, next_queue values i slot, selected_input values one i slot] at eq
  simp only [Semiring.one_mul] at eq
  grind

#print axioms no_event
#print axioms event_shift

end ZkBuild.ByteCompileQueueStep
