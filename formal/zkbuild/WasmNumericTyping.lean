import Std.Tactic

/- Declarative signatures of the 132 core numeric instructions and eight
   saturating conversions. Tags 0..3 are i32, i64, f32, and f64. -/
namespace ZkBuild.WasmNumericTyping

structure Rule where
  inputs : Nat
  inputType : Fin 4
  outputType : Fin 4
deriving DecidableEq, Repr

def enabled (code : Nat) : Bool :=
  decide (0x41 ≤ code ∧ code ≤ 0xc4 ∨ 0x100 ≤ code ∧ code ≤ 0x107)

def sourceType (code : Nat) : Fin 4 :=
  if code = 0x41 ∨ 0x45 ≤ code ∧ code ≤ 0x4f ∨ 0x67 ≤ code ∧ code ≤ 0x78 ∨
      code = 0xac ∨ code = 0xad ∨ code = 0xb2 ∨ code = 0xb3 ∨ code = 0xb7 ∨
      code = 0xb8 ∨ code = 0xbe ∨ code = 0xc0 ∨ code = 0xc1 then 0
  else if code = 0x42 ∨ 0x50 ≤ code ∧ code ≤ 0x5a ∨ 0x79 ≤ code ∧ code ≤ 0x8a ∨
      code = 0xa7 ∨ code = 0xb4 ∨ code = 0xb5 ∨ code = 0xb9 ∨ code = 0xba ∨
      code = 0xbf ∨ 0xc2 ≤ code ∧ code ≤ 0xc4 then 1
  else if code = 0x43 ∨ 0x5b ≤ code ∧ code ≤ 0x60 ∨ 0x8b ≤ code ∧ code ≤ 0x98 ∨
      code = 0xa8 ∨ code = 0xa9 ∨ code = 0xae ∨ code = 0xaf ∨ code = 0xbb ∨
      code = 0xbc ∨ code = 0x100 ∨ code = 0x101 ∨ code = 0x104 ∨ code = 0x105 then 2
  else 3

def targetType (code : Nat) : Fin 4 :=
  if code = 0x41 ∨ 0x45 ≤ code ∧ code ≤ 0x78 ∨ 0xa7 ≤ code ∧ code ≤ 0xab ∨
      code = 0xbc ∨ code = 0xc0 ∨ code = 0xc1 ∨ 0x100 ≤ code ∧ code ≤ 0x103 then 0
  else if code = 0x42 ∨ 0x79 ≤ code ∧ code ≤ 0x8a ∨ 0xac ≤ code ∧ code ≤ 0xb1 ∨
      code = 0xbd ∨ 0xc2 ≤ code ∧ code ≤ 0xc4 ∨ 0x104 ≤ code ∧ code ≤ 0x107 then 1
  else if code = 0x43 ∨ 0x8b ≤ code ∧ code ≤ 0x98 ∨ 0xb2 ≤ code ∧ code ≤ 0xb6 ∨ code = 0xbe then 2
  else 3

def arity (code : Nat) : Nat :=
  if 0x41 ≤ code ∧ code ≤ 0x44 then 0
  else if 0x46 ≤ code ∧ code ≤ 0x4f ∨ 0x51 ≤ code ∧ code ≤ 0x66 ∨
      0x6a ≤ code ∧ code ≤ 0x78 ∨ 0x7c ≤ code ∧ code ≤ 0x8a ∨
      0x92 ≤ code ∧ code ≤ 0x98 ∨ 0xa0 ≤ code ∧ code ≤ 0xa6 then 2
  else 1

def signature (code : Nat) : Option Rule :=
  if enabled code then some ⟨arity code, sourceType code, targetType code⟩ else none

theorem signature_present (code : Nat) : (signature code).isSome = enabled code := by
  simp [signature]; split <;> simp_all

theorem arity_bound (code : Nat) : arity code ≤ 2 := by
  unfold arity
  split
  · omega
  · split <;> omega

theorem constant_arity (code : Nat) : arity code = 0 ↔ 0x41 ≤ code ∧ code ≤ 0x44 := by
  unfold arity
  split
  · simp_all
  · split <;> simp_all

def Rule.inputTag (rule : Rule) : Fin 7 := ⟨rule.inputType.val, by have h := rule.inputType.isLt; omega⟩
def Rule.outputTag (rule : Rule) : Fin 7 := ⟨rule.outputType.val, by have h := rule.outputType.isLt; omega⟩

def applyRule (rule : Rule) (stack : List (Fin 7)) : Option (List (Fin 7)) :=
  if rule.inputs ≤ stack.length ∧ (stack.take rule.inputs).all (· == rule.inputTag) then
    some (rule.outputTag :: stack.drop rule.inputs)
  else none

theorem apply_complete (rule : Rule) (rest : List (Fin 7)) :
    applyRule rule (List.replicate rule.inputs rule.inputTag ++ rest) =
      some (rule.outputTag :: rest) := by
  simp [applyRule]

theorem apply_sound (rule : Rule) (stack output : List (Fin 7))
    (accepted : applyRule rule stack = some output) :
    rule.inputs ≤ stack.length ∧
    (∀ value ∈ stack.take rule.inputs, value = rule.inputTag) ∧
    output = rule.outputTag :: stack.drop rule.inputs := by
  simp only [applyRule] at accepted
  split at accepted
  next conditions =>
    simp only [Option.some.injEq] at accepted
    refine ⟨conditions.1, ?_, accepted.symm⟩
    intro value member
    have h := List.all_eq_true.mp conditions.2 value member
    simpa using h
  next => simp at accepted

abbrev Symbol := Option (Fin 7)

def popExpected (expected : Fin 7) (unreachable : Bool) : List Symbol → Option (List Symbol)
  | [] => if unreachable then some [] else none
  | none :: rest => some rest
  | some actual :: rest => if actual = expected then some rest else none

inductive PopOk (expected : Fin 7) (unreachable : Bool) : List Symbol → List Symbol → Prop
  | empty (allowed : unreachable = true) : PopOk expected unreachable [] []
  | unknown (rest) : PopOk expected unreachable (none :: rest) rest
  | concrete (rest) : PopOk expected unreachable (some expected :: rest) rest

theorem pop_sound (expected : Fin 7) (unreachable : Bool) (before after : List Symbol)
    (accepted : popExpected expected unreachable before = some after) :
    PopOk expected unreachable before after := by
  cases before with
  | nil =>
    cases unreachable <;> simp [popExpected] at accepted
    subst after
    exact .empty rfl
  | cons head rest =>
    cases head with
    | none =>
      simp [popExpected] at accepted
      subst after
      exact .unknown _
    | some actual =>
      by_cases same : actual = expected
      · subst actual
        simp [popExpected] at accepted
        subst after
        exact .concrete _
      · simp [popExpected, same] at accepted

theorem pop_complete {expected : Fin 7} {unreachable : Bool} {before after : List Symbol}
    (valid : PopOk expected unreachable before after) :
    popExpected expected unreachable before = some after := by
  cases valid with
  | empty allowed => simp [popExpected, allowed]
  | unknown rest => rfl
  | concrete rest => simp [popExpected]

def popMany (expected : Fin 7) (unreachable : Bool) : Nat → List Symbol → Option (List Symbol)
  | 0, stack => some stack
  | n+1, stack => match popExpected expected unreachable stack with
    | none => none
    | some rest => popMany expected unreachable n rest

inductive ManyPops (expected : Fin 7) (unreachable : Bool) : Nat → List Symbol → List Symbol → Prop
  | zero (stack) : ManyPops expected unreachable 0 stack stack
  | step {n before middle after} (head : PopOk expected unreachable before middle)
      (tail : ManyPops expected unreachable n middle after) :
      ManyPops expected unreachable (n+1) before after

theorem many_sound (expected : Fin 7) (unreachable : Bool) (count : Nat) (before after : List Symbol)
    (accepted : popMany expected unreachable count before = some after) :
    ManyPops expected unreachable count before after := by
  induction count generalizing before with
  | zero => simp [popMany] at accepted; subst after; exact .zero _
  | succ n ih =>
    cases first : popExpected expected unreachable before with
    | none => simp [popMany, first] at accepted
    | some middle =>
      simp only [popMany, first] at accepted
      exact .step (pop_sound _ _ _ _ first) (ih middle accepted)

theorem many_complete {expected : Fin 7} {unreachable : Bool} {count : Nat} {before after : List Symbol}
    (valid : ManyPops expected unreachable count before after) :
    popMany expected unreachable count before = some after := by
  induction valid with
  | zero stack => rfl
  | step head tail ih => simp [popMany, pop_complete head, ih]

def applyPolymorphic (rule : Rule) (unreachable : Bool) (stack : List Symbol) : Option (List Symbol) :=
  match popMany rule.inputTag unreachable rule.inputs stack with
  | none => none
  | some rest => some (some rule.outputTag :: rest)

theorem polymorphic_correct (rule : Rule) (unreachable : Bool) (before after : List Symbol) :
    applyPolymorphic rule unreachable before = some after ↔
      ∃ rest, ManyPops rule.inputTag unreachable rule.inputs before rest ∧
        after = some rule.outputTag :: rest := by
  constructor
  · intro accepted
    cases consumed : popMany rule.inputTag unreachable rule.inputs before with
    | none => simp [applyPolymorphic, consumed] at accepted
    | some rest =>
      simp [applyPolymorphic, consumed] at accepted
      exact ⟨rest, many_sound _ _ _ _ _ consumed, accepted.symm⟩
  · rintro ⟨rest, valid, rfl⟩
    simp [applyPolymorphic, many_complete valid]

set_option maxRecDepth 4096 in
theorem exact_numeric_count : ((List.range 1024).filter (enabled ·)).length = 140 := by decide

#print axioms apply_sound
#print axioms apply_complete
#print axioms exact_numeric_count
#print axioms polymorphic_correct

end ZkBuild.WasmNumericTyping
