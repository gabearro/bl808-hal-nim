import ControlPlans

namespace ZkBuild.ParametricEvents

open Lean.Grind
attribute [local instance] Semiring.natCast

def typeForCode : Nat → Option Nat
  | 127 => some 0 | 126 => some 1 | 125 => some 2 | 124 => some 3
  | 123 => some 4 | 112 => some 5 | 111 => some 6 | _ => none

def referenceForCode : Nat → Option Nat
  | 112 => some 5 | 111 => some 6 | _ => none

theorem type_bound (code tag : Nat) (found : typeForCode code = some tag) : tag < 7 := by
  unfold typeForCode at found
  split at found <;> simp_all <;> omega

theorem reference_bound (code tag : Nat) (found : referenceForCode code = some tag) :
    (code = 112 ∧ tag = 5) ∨ (code = 111 ∧ tag = 6) := by
  unfold referenceForCode at found
  split at found <;> simp_all

theorem immediate_equality {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (encoded code : Nat) (eb : encoded < 2^32) (cb : code < 2^32) :
    (encoded : F)-(code : F) = 0 ↔ encoded = code := by
  constructor
  · intro eq
    exact NumericEvents.nat_eq (F := F) encoded code
      (by simp [NumericEvents.countBound]; omega) (by simp [NumericEvents.countBound]; omega) (by grind)
  · intro eq; subst encoded; grind

def Inferred (first second result : Nat) : Prop :=
  first < 8 ∧ second < 8 ∧ first ≠ 5 ∧ first ≠ 6 ∧ second ≠ 5 ∧ second ≠ 6 ∧
    (first = second ∨ first = 7 ∨ second = 7) ∧ result = if first = 7 then second else first

def infer (first second : Nat) : Option Nat :=
  if first < 8 ∧ second < 8 ∧ first ≠ 5 ∧ first ≠ 6 ∧ second ≠ 5 ∧ second ≠ 6 ∧
      (first = second ∨ first = 7 ∨ second = 7) then
    some (if first = 7 then second else first)
  else none

theorem infer_sound (first second result : Nat) (found : infer first second = some result) :
    Inferred first second result := by
  unfold infer at found
  split at found
  · rename_i valid
    simp only [Option.some.injEq] at found
    exact ⟨valid.1, valid.2.1, valid.2.2.1, valid.2.2.2.1,
      valid.2.2.2.2.1, valid.2.2.2.2.2.1, valid.2.2.2.2.2.2, found.symm⟩
  · contradiction

theorem infer_complete (first second result : Nat) (valid : Inferred first second result) :
    infer first second = some result := by
  simp only [infer]
  have allowed := And.intro valid.1 (And.intro valid.2.1 (And.intro valid.2.2.1
    (And.intro valid.2.2.2.1 (And.intro valid.2.2.2.2.1
      (And.intro valid.2.2.2.2.2.1 valid.2.2.2.2.2.2.1)))))
  simp [allowed, valid.2.2.2.2.2.2.2]

def check : Nat → Nat → List ControlPlans.Action → Bool
  | 27, immediate, [.pop condition, .pop first, .pop second, .push result] =>
    decide (immediate = 0 ∧ (condition = 0 ∨ condition = 7) ∧ infer first second = some result)
  | 28, immediate, [.pop condition, .pop first, .pop second, .push result] =>
    match typeForCode immediate with
    | none => false
    | some tag => decide ((condition = 0 ∨ condition = 7) ∧ (first = tag ∨ first = 7) ∧
        (second = tag ∨ second = 7) ∧ result = tag)
  | 208, immediate, [.push result] => decide (referenceForCode immediate = some result)
  | _, _, _ => false

theorem untyped_checked (immediate condition first second result : Nat)
    (ok : check 27 immediate [.pop condition, .pop first, .pop second, .push result] = true) :
    immediate = 0 ∧ (condition = 0 ∨ condition = 7) ∧ Inferred first second result := by
  simp only [check, decide_eq_true_eq] at ok
  exact ⟨ok.1, ok.2.1, infer_sound first second result ok.2.2⟩

theorem typed_checked (immediate condition first second result : Nat)
    (ok : check 28 immediate [.pop condition, .pop first, .pop second, .push result] = true) :
    ∃ tag, typeForCode immediate = some tag ∧ (condition = 0 ∨ condition = 7) ∧
      CallEvents.InputOk tag first ∧ CallEvents.InputOk tag second ∧ result = tag := by
  cases found : typeForCode immediate with
  | none => simp [check, found] at ok
  | some tag =>
    simp only [check, found, decide_eq_true_eq] at ok
    exact ⟨tag, rfl, ok⟩

theorem reference_checked (immediate result : Nat)
    (ok : check 208 immediate [.push result] = true) : referenceForCode immediate = some result := by
  simpa only [check, decide_eq_true_eq] using ok

theorem input_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual expected : Fin 8)
    (gate : (1-ControlPlans.flag (F := F) (decide (actual.val = 7)))*
      ((actual.val : F)-(expected.val : F)) = 0) : actual.val = expected.val ∨ actual.val = 7 := by
  by_cases unknown : actual.val = 7
  · exact Or.inr unknown
  · left
    simp [ControlPlans.flag, unknown] at gate
    exact NumericEvents.nat_eq (F := F) actual.val expected.val
      (by have := actual.isLt; simp [NumericEvents.countBound]; omega)
      (by have := expected.isLt; simp [NumericEvents.countBound]; omega) (by grind)

theorem match_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (first second : Fin 8)
    (gate : (1-ControlPlans.flag (F := F) (decide (first.val = 7)))*
      (1-ControlPlans.flag (F := F) (decide (second.val = 7)))*
      ((first.val : F)-(second.val : F)) = 0) :
    first.val = second.val ∨ first.val = 7 ∨ second.val = 7 := by
  by_cases a : first.val = 7
  · exact Or.inr (Or.inl a)
  · by_cases b : second.val = 7
    · exact Or.inr (Or.inr b)
    · left
      simp [ControlPlans.flag, a, b] at gate
      exact NumericEvents.nat_eq (F := F) first.val second.val
        (by have := first.isLt; simp [NumericEvents.countBound]; omega)
        (by have := second.isLt; simp [NumericEvents.countBound]; omega) (by grind)

theorem reference_exclusion {F : Type} [Field F] (actual : Nat)
    (gate : ControlPlans.flag (F := F) (decide (actual = 5))+
      ControlPlans.flag (F := F) (decide (actual = 6)) = 0) : actual ≠ 5 ∧ actual ≠ 6 := by
  by_cases five : actual = 5
  · subst actual; simp [ControlPlans.flag] at gate; grind
  · by_cases six : actual = 6
    · subst actual; simp [ControlPlans.flag] at gate; grind
    · exact ⟨five, six⟩

theorem inference_output {F : Type} [Field F] [IsCharP F scalarModulus]
    (first second result : Fin 8)
    (gate : (result.val : F) = (first.val : F)+
      ControlPlans.flag (F := F) (decide (first.val = 7))*((second.val : F)-(first.val : F))) :
    result.val = if first.val = 7 then second.val else first.val := by
  by_cases unknown : first.val = 7
  · simp [ControlPlans.flag, unknown] at gate ⊢
    apply NumericEvents.nat_eq (F := F) result.val second.val
      (by have := result.isLt; simp [NumericEvents.countBound]; omega)
      (by have := second.isLt; simp [NumericEvents.countBound]; omega)
    grind
  · simp [ControlPlans.flag, unknown] at gate ⊢
    apply NumericEvents.nat_eq (F := F) result.val first.val
      (by have := result.isLt; simp [NumericEvents.countBound]; omega)
      (by have := first.isLt; simp [NumericEvents.countBound]; omega)
    grind

theorem pop_index {F : Type} [Field F] (pops : Nat)
    (gate : (1 : F)-ControlPlans.flag (F := F) (decide (pops = 0))-
      ControlPlans.flag (F := F) (decide (pops = 1))-
      ControlPlans.flag (F := F) (decide (pops = 2)) = 0) : pops < 3 := by
  by_cases a : pops = 0
  · omega
  · by_cases b : pops = 1
    · omega
    · by_cases c : pops = 2
      · omega
      · simp [ControlPlans.flag, a, b, c] at gate
        grind

#print axioms infer_sound
#print axioms type_bound
#print axioms reference_bound
#print axioms immediate_equality
#print axioms infer_complete
#print axioms untyped_checked
#print axioms typed_checked
#print axioms input_guard
#print axioms match_guard
#print axioms reference_exclusion
#print axioms inference_output
#print axioms pop_index

end ZkBuild.ParametricEvents
