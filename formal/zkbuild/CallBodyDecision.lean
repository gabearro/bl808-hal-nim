import CallBodyRun
set_option autoImplicit false
namespace ZkBuild.CallBodyDecision
open CallBodyRun CallEvents StaticEvents

def check (params results : List Nat) (pending cleared tail : Bool) : List Token → Bool
  | [] => params.isEmpty && !pending && (if tail then cleared else !cleared && results.isEmpty)
  | .pop actual :: rest => !cleared &&
      (if pending then (actual == 0 || actual == 7) && check params results false false tail rest
       else match params with
         | [] => false
         | expected :: ps => (actual == expected || actual == 7) && check ps results false false tail rest)
  | .push actual :: rest => !pending && !cleared && !tail && params.isEmpty &&
      (match results with
       | [] => false
       | expected :: rs => actual == expected && check [] rs false false false rest)
  | .clear :: rest => !pending && !cleared && tail && params.isEmpty && check [] results false true true rest

theorem nil_iff (params results : List Nat) (pending cleared tail : Bool) :
    Run params results pending cleared tail [] ↔
      params = [] ∧ pending = false ∧ cleared = tail ∧ (tail = false → results = []) := by
  constructor
  · intro run; cases run <;> simp
  · rintro ⟨rfl,rfl,rfl,empty⟩
    cases cleared with
    | false => rw [empty rfl]; exact .done
    | true => exact .returned results

theorem pop_iff (params results : List Nat) (pending cleared tail : Bool) (actual : Nat) (rest : List Token) :
    Run params results pending cleared tail (.pop actual :: rest) ↔
      cleared = false ∧ ((pending = true ∧ InputOk 0 actual ∧ Run params results false false tail rest) ∨
        (pending = false ∧ ∃ expected ps, params = expected :: ps ∧ InputOk expected actual ∧ Run ps results false false tail rest)) := by
  constructor
  · intro run
    cases run with
    | index typed next => exact ⟨rfl,Or.inl ⟨rfl,typed,next⟩⟩
    | pop typed next => exact ⟨rfl,Or.inr ⟨rfl,_,_,rfl,typed,next⟩⟩
  · rintro ⟨rfl,branch⟩
    rcases branch with ⟨rfl,typed,next⟩ | ⟨rfl,e,ps,rfl,typed,next⟩
    · exact .index typed next
    · exact .pop typed next

theorem push_iff (params results : List Nat) (pending cleared tail : Bool) (actual : Nat) (rest : List Token) :
    Run params results pending cleared tail (.push actual :: rest) ↔
      pending = false ∧ cleared = false ∧ tail = false ∧ params = [] ∧
        ∃ rs, results = actual :: rs ∧ Run [] rs false false false rest := by
  constructor
  · intro run; cases run with
    | push next => exact ⟨rfl,rfl,rfl,rfl,_,rfl,next⟩
  · rintro ⟨rfl,rfl,rfl,rfl,rs,rfl,next⟩; exact .push next

theorem clear_iff (params results : List Nat) (pending cleared tail : Bool) (rest : List Token) :
    Run params results pending cleared tail (.clear :: rest) ↔
      pending = false ∧ cleared = false ∧ tail = true ∧ params = [] ∧ Run [] results false true true rest := by
  constructor
  · intro run; cases run with
    | clear next => exact ⟨rfl,rfl,rfl,rfl,next⟩
  · rintro ⟨rfl,rfl,rfl,rfl,next⟩; exact .clear next

/-- The executable oracle decides the same complete call relation used in
    the source-bound circuit theorem; it is not an independent specification. -/
theorem correct (params results : List Nat) (pending cleared tail : Bool) (tokens : List Token) :
    check params results pending cleared tail tokens = true ↔ Run params results pending cleared tail tokens := by
  induction tokens generalizing params results pending cleared tail with
  | nil =>
    rw [nil_iff]
    cases params <;> cases results <;> cases pending <;> cases cleared <;> cases tail <;> simp [check]
  | cons token rest ih =>
    cases token with
    | pop actual =>
      rw [pop_iff]
      cases params <;> cases pending <;> cases cleared <;> simp [check,InputOk,ih]
      all_goals grind only
    | push actual =>
      rw [push_iff]
      cases params <;> cases results <;> cases pending <;> cases cleared <;> cases tail <;> simp [check,ih]
      all_goals grind only
    | clear =>
      rw [clear_iff]
      cases params <;> cases pending <;> cases cleared <;> cases tail <;> simp [check,ih]

#print axioms correct
end ZkBuild.CallBodyDecision
