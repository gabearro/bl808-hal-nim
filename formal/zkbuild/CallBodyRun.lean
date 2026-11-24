import CallEvents
set_option autoImplicit false
namespace ZkBuild.CallBodyRun
open CallEvents StaticEvents

/-- List-level execution of a whole call, including the indirect index and
    the tail-call clear. All constructors consume a real event. -/
inductive Run : List Nat → List Nat → Bool → Bool → Bool → List Token → Prop where
  | done : Run [] [] false false false []
  | returned (results : List Nat) : Run [] results false true true []
  | index {params results : List Nat} {tail : Bool} {actual : Nat} {rest : List Token} :
      InputOk 0 actual → Run params results false false tail rest →
      Run params results true false tail (.pop actual :: rest)
  | pop {expected actual : Nat} {params results : List Nat} {tail : Bool} {rest : List Token} :
      InputOk expected actual → Run params results false false tail rest →
      Run (expected :: params) results false false tail (.pop actual :: rest)
  | push {value : Nat} {results : List Nat} {rest : List Token} :
      Run [] results false false false rest → Run [] (value :: results) false false false (.push value :: rest)
  | clear {results : List Nat} {rest : List Token} :
      Run [] results false true true rest → Run [] results false false true (.clear :: rest)

theorem cleared (params results : List Nat) (pending tail : Bool) (tokens : List Token)
    (run : Run params results pending true tail tokens) : tokens = [] := by
  cases run
  rfl

theorem body_aux (params results : List Nat) (pending clearFlag tail : Bool) (tokens : List Token)
    (run : Run params results pending clearFlag tail tokens) :
    pending = false → clearFlag = false → Body params results tail tokens := by
  induction run with
  | done => exact fun _ _ => .done
  | returned results => simp
  | index typed run ih => simp
  | pop typed run ih => exact fun _ _ => .pop typed (ih rfl rfl)
  | push run ih => exact fun _ _ => .push (ih rfl rfl)
  | clear run ih =>
    intro _ _
    have empty := cleared _ _ _ _ _ run
    rw [empty]
    exact .clear _

theorem body (params results : List Nat) (tail : Bool) (tokens : List Token)
    (run : Run params results false false tail tokens) : Body params results tail tokens :=
  body_aux params results false false tail tokens run rfl rfl

/-- The pending index is exactly one leading i32/unknown pop. -/
theorem refinement (params results : List Nat) (pending tail : Bool) (tokens : List Token)
    (run : Run params results pending false tail tokens) :
    ∃ indexTokens rest, tokens = indexTokens ++ rest ∧
      (if pending then ∃ actual, InputOk 0 actual ∧ indexTokens = [.pop actual] else indexTokens = []) ∧
      Body params results tail rest := by
  cases pending with
  | false => exact ⟨[],tokens,rfl,rfl,body params results tail tokens run⟩
  | true =>
    cases run with
    | index typed next => exact ⟨_,_,rfl,⟨_,typed,rfl⟩,body _ _ _ _ next⟩

#print axioms body
#print axioms refinement
end ZkBuild.CallBodyRun
