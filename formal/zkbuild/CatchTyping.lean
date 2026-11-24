import TypeReversals
import ThrowEvents

namespace ZkBuild.CatchTyping

def payload (kind : Nat) (tag : Option (List Nat × List Nat)) : Option (List Nat) :=
  if kind ≥ 4 then none
  else
    let args := if kind < 2 then
      match tag with | some (params, []) => some params | _ => none
      else some []
    args.map (fun values => values ++ if kind % 2 = 1 then [6] else [])

def check (kind : Nat) (tag : Option (List Nat × List Nat)) (labels : List (List Nat)) (depth : Nat) : Bool :=
  match payload kind tag, labels[depth]? with
  | some p, some target => decide (p = target)
  | _, _ => false

theorem check_sound (kind : Nat) (tag : Option (List Nat × List Nat)) (labels : List (List Nat)) (depth : Nat)
    (accepted : check kind tag labels depth = true) :
    ∃ target, payload kind tag = some target ∧ labels[depth]? = some target := by
  unfold check at accepted
  cases p : payload kind tag with
  | none => simp [p] at accepted
  | some values =>
    cases label : labels[depth]? with
    | none => simp [p, label] at accepted
    | some target =>
      have same : values = target := by simpa [p, label] using accepted
      exact ⟨target, by simp [same], rfl⟩

theorem tagged (params : List Nat) : payload 0 (some (params, [])) = some params := by simp [payload]
theorem tagged_ref (params : List Nat) : payload 1 (some (params, [])) = some (params ++ [6]) := by simp [payload]
theorem all (tag : Option (List Nat × List Nat)) : payload 2 tag = some [] := by simp [payload]
theorem all_ref (tag : Option (List Nat × List Nat)) : payload 3 tag = some [6] := by simp [payload]

theorem outer_slot (handler depth : Nat) (bound : depth < handler) :
    handler-1-depth < handler ∧ (handler-1-depth)+1+depth = handler := by omega

theorem retained_loop (target : Nat) : target+1 > target := by omega

#print axioms check_sound
#print axioms tagged
#print axioms tagged_ref
#print axioms all
#print axioms all_ref
#print axioms outer_slot
#print axioms retained_loop

end ZkBuild.CatchTyping
