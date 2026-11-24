import CallEvents

namespace ZkBuild.ThrowEvents

open Lean.Grind SignatureLists StaticEvents CallEvents
attribute [local instance] Semiring.natCast

/- Lists are in source order at the tag boundary. The shared signature cursor
   stores parameters in reverse pop order. No result values are produced. -/
def signature (code : Nat) (tags : List (List Nat × List Nat)) (index : Nat) : Option (List Nat) :=
  if code = 10 then some [6] -- runtime's current opaque externref representation
  else if code = 8 then
    match tags[index]? with
    | some (params, []) => some params.reverse
    | _ => none
  else none

def run : List Nat → Bool → List Token → Bool
  | [], false, [.clear] => true
  | expected :: rest, false, .pop actual :: tokens =>
      decide (actual = expected ∨ actual = 7) && run rest false tokens
  | _, _, _ => false

theorem tagged_signature (tags : List (List Nat × List Nat)) (index : Nat) (params : List Nat)
    (found : tags[index]? = some (params, [])) : signature 8 tags index = some params.reverse := by
  simp [signature, found]

theorem resultful_tag_rejected (tags : List (List Nat × List Nat)) (index result : Nat)
    (params results : List Nat) (found : tags[index]? = some (params, result :: results)) :
    signature 8 tags index = none := by simp [signature, found]

theorem run_sound (params : List Nat) (tokens : List Token) (ok : run params false tokens = true) :
    Body params [] true tokens := by
  induction params generalizing tokens with
  | nil =>
    cases tokens with
    | nil => simp [run] at ok
    | cons token rest =>
      cases token <;> cases rest <;> simp_all [run]
      exact .clear []
  | cons expected params ih =>
    cases tokens with
    | nil => simp [run] at ok
    | cons token rest =>
      cases token <;> simp only [run, Bool.false_eq_true] at ok
      rename_i actual
      simp only [Bool.and_eq_true, decide_eq_true_eq] at ok
      exact .pop ok.1 (ih rest ok.2)

theorem run_shape (params : List Nat) (tokens : List Token) (ok : run params false tokens = true) :
    ∃ actuals, Aligned params actuals ∧ tokens = actuals.map Token.pop ++ [.clear] :=
  tail_shape params [] tokens (run_sound params tokens ok)

theorem run_complete (params actuals : List Nat) (typed : Aligned params actuals) :
    run params false (actuals.map Token.pop ++ [.clear]) = true := by
  induction typed with
  | nil => rfl
  | cons head tail ih => simp [run, InputOk] at head ⊢; exact ⟨head, ih⟩

theorem cursor_shape (table : Table) (head : Nat) (params : List Nat) (tokens : List Token)
    (walk : CursorBody table head 0 true tokens) (rep : Represents table head params) :
    ∃ actuals, Aligned params actuals ∧ tokens = actuals.map Token.pop ++ [.clear] :=
  tail_shape params [] tokens (cursor_refinement table head 0 true tokens walk params [] rep .nil)

theorem result_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (table : Table) (head : Nat) (results : List Nat) (bound : head < 2^32)
    (rep : Represents table head results) (gate : (head : F) = 0) : results = [] := by
  have zero : head = 0 := NumericEvents.nat_eq (F := F) head 0
    (by simp [NumericEvents.countBound]; omega) (by decide) (by simpa only [Semiring.natCast_zero] using gate)
  subst head
  exact represents_zero table results rep

#print axioms tagged_signature
#print axioms resultful_tag_rejected
#print axioms run_sound
#print axioms run_shape
#print axioms run_complete
#print axioms cursor_shape
#print axioms result_guard

end ZkBuild.ThrowEvents
