import ControlEvents
import WasmNumericTyping

namespace ZkBuild.NumericEvents

open Lean.Grind OperandEvents ControlEvents WasmNumericTyping
attribute [local instance] Semiring.natCast

def countBound : Nat := 2^64

theorem nat_eq {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < countBound) (bb : b < countBound) (same : (a : F) = (b : F)) : a = b := by
  have large : countBound < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans ab large) (Nat.lt_trans bb large)).mp same

structure Gates {F : Type} [Field F] (rule : Rule) (kind : Kind) (value : Fin 8)
    (pops pushes : Nat) : Prop where
  popType : selected kind .pop * (((value.val : F)-(rule.inputType.val : F))*((value.val : F)-7)) = 0
  popOrder : selected kind .pop * (pushes : F) = 0
  pushType : selected kind .push * ((value.val : F)-(rule.outputType.val : F)) = 0
  pushArity : selected kind .push * ((pops : F)-(rule.inputs : F)) = 0
  pushOnce : selected kind .push * (pushes : F) = 0
  noControl : selected kind .controlPush+selected kind .controlPop+selected kind .clear = (0 : F)
  endArity : selected kind .instructionEnd * ((pops : F)-(rule.inputs : F)) = 0
  endPush : selected kind .instructionEnd * ((pushes : F)-1) = 0

def InputOk (rule : Rule) (value : Fin 8) : Prop := value.val = rule.inputType.val ∨ value.val = 7

theorem pop_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (pops pushes : Nat) (pushBound : pushes < countBound)
    (gates : Gates (F := F) rule .pop value pops pushes) : InputOk rule value ∧ pushes = 0 := by
  have typed := gates.popType
  have ordered := gates.popOrder
  simp [selected, flag] at typed ordered
  constructor
  · have product : ((value.val : F)-(rule.inputType.val : F))*((value.val : F)-7) = 0 := by grind
    rcases Field.of_mul_eq_zero product with input | unknown
    · left
      apply nat_eq (F := F) _ _ (by have := value.isLt; simp [countBound]; omega)
        (by have := rule.inputType.isLt; simp [countBound]; omega)
      grind
    · right
      have seven : ((7 : Nat) : F) = (7 : F) := Semiring.natCast_eq_ofNat 7
      apply nat_eq (F := F) _ _ (by have := value.isLt; simp [countBound]; omega) (by decide)
      rw [seven]
      grind
  · apply nat_eq (F := F) _ _ pushBound (by decide)
    simp only [Semiring.natCast_zero]
    grind

theorem push_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (pops pushes : Nat)
    (arityBound : rule.inputs < countBound) (popBound : pops < countBound) (pushBound : pushes < countBound)
    (gates : Gates (F := F) rule .push value pops pushes) :
    value.val = rule.outputType.val ∧ pops = rule.inputs ∧ pushes = 0 := by
  have typed := gates.pushType
  have count := gates.pushArity
  have once := gates.pushOnce
  simp [selected, flag] at typed count once
  constructor
  · exact nat_eq (F := F) _ _ (by have := value.isLt; simp [countBound]; omega)
      (by have := rule.outputType.isLt; simp [countBound]; omega) (by grind)
  · constructor
    · exact nat_eq (F := F) _ _ popBound arityBound (by grind)
    · exact nat_eq (F := F) _ _ pushBound (by decide) (by simp only [Semiring.natCast_zero]; grind)

theorem end_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (rule : Rule) (value : Fin 8) (pops pushes : Nat)
    (arityBound : rule.inputs < countBound) (popBound : pops < countBound) (pushBound : pushes < countBound)
    (gates : Gates (F := F) rule .instructionEnd value pops pushes) : pops = rule.inputs ∧ pushes = 1 := by
  have count := gates.endArity
  have result := gates.endPush
  simp [selected, flag] at count result
  constructor
  · exact nat_eq (F := F) _ _ popBound arityBound (by grind)
  · exact nat_eq (F := F) _ _ pushBound (by decide) (by simp only [Semiring.natCast_one]; grind)

theorem no_control {F : Type} [Field F] (rule : Rule) (kind : Kind) (value : Fin 8) (pops pushes : Nat)
    (gates : Gates (F := F) rule kind value pops pushes) :
    kind ≠ .controlPush ∧ kind ≠ .controlPop ∧ kind ≠ .clear := by
  have h := gates.noControl
  cases kind <;> simp [selected, flag] at h ⊢ <;>
    have bad : (1 : F) = 0 := by grind
  all_goals exact False.elim (Field.zero_ne_one bad.symm)

def counterBase (count : Nat) (kind : Kind) : Nat :=
  if kind = .functionBegin ∨ kind = .instructionBegin then 0 else count

def nextCounter (count : Nat) (kind target : Kind) : Nat :=
  counterBase count kind + if kind = target then 1 else 0

theorem counter_refinement {F : Type} [Field F] (count : Nat) (kind target : Kind) (base after : F)
    (baseEq : base = (count : F)+(selected kind .functionBegin+selected kind .instructionBegin)*(0-(count : F)))
    (afterEq : after = base+selected kind target) : after = (nextCounter count kind target : F) := by
  cases k : kind <;> by_cases same : kind = target
  all_goals simp only [k] at same
  all_goals simp [counterBase, nextCounter, selected, flag, k, same,
    Semiring.natCast_zero, Semiring.natCast_one, Semiring.natCast_add] at baseEq afterEq ⊢ <;> grind

theorem nextCounter_bound (count : Nat) (kind target : Kind) : nextCounter count kind target ≤ count+1 := by
  unfold nextCounter counterBase
  split <;> split <;> omega

def tally (target : Kind) (count : Nat) : List Kind → Nat
  | [] => count
  | kind :: rest => tally target (nextCounter count kind target) rest

theorem tally_bound (target : Kind) (events : List Kind) (count : Nat) :
    tally target count events ≤ count+events.length := by
  induction events generalizing count with
  | nil => simp [tally]
  | cons kind rest ih =>
    have step := nextCounter_bound count kind target
    have tail := ih (nextCounter count kind target)
    simp only [tally, List.length_cons]
    omega

theorem bounded_counters (target : Kind) (events : List Kind) (size : events.length < countBound) :
    tally target 0 events < countBound := by
  have bound := tally_bound target events 0
  omega

inductive Token where
  | pop (value : Fin 8)
  | push (value : Fin 8)
  deriving DecidableEq

def output (rule : Rule) : Fin 8 := ⟨rule.outputType.val, by have := rule.outputType.isLt; omega⟩

def Body (rule : Rule) (pops pushes : Nat) : List Token → Prop
  | [] => pops = rule.inputs ∧ pushes = 1
  | .pop value :: rest => pushes = 0 ∧ InputOk rule value ∧ Body rule (pops+1) pushes rest
  | .push value :: rest => pushes = 0 ∧ pops = rule.inputs ∧ value = output rule ∧ Body rule pops (pushes+1) rest

theorem after_push_empty (rule : Rule) (tokens : List Token) (pops pushes : Nat)
    (positive : 0 < pushes) (ok : Body rule pops pushes tokens) : tokens = [] := by
  cases tokens with
  | nil => rfl
  | cons token rest => cases token <;> simp [Body] at ok <;> omega

theorem body_shape (rule : Rule) (tokens : List Token) (pops : Nat) (ok : Body rule pops 0 tokens) :
    ∃ inputs : List (Fin 8), pops+inputs.length = rule.inputs ∧
      (∀ value ∈ inputs, InputOk rule value) ∧
      tokens = inputs.map Token.pop ++ [Token.push (output rule)] := by
  induction tokens generalizing pops with
  | nil => simp [Body] at ok
  | cons token rest ih =>
    cases token with
    | pop value =>
      obtain ⟨inputs, count, typed, same⟩ := ih (pops+1) ok.2.2
      refine ⟨value :: inputs, ?_, ?_, ?_⟩
      · simp; omega
      · intro x hx
        rcases List.mem_cons.mp hx with rfl | member
        · exact ok.2.1
        · exact typed x member
      · simp [same]
    | push value =>
      have empty := after_push_empty rule rest pops 1 (by decide) ok.2.2.2
      refine ⟨[], ?_, ?_, ?_⟩
      · simp; exact ok.2.1
      · simp
      · simp [empty, ok.2.2.1]

theorem body_complete (rule : Rule) (inputs : List (Fin 8)) (pops : Nat)
    (count : pops+inputs.length = rule.inputs) (typed : ∀ value ∈ inputs, InputOk rule value) :
    Body rule pops 0 (inputs.map Token.pop ++ [Token.push (output rule)]) := by
  induction inputs generalizing pops with
  | nil => simp [Body] at *; exact count
  | cons value rest ih =>
    simp only [List.map_cons, List.cons_append, Body]
    refine ⟨trivial, typed value (by simp), ?_⟩
    apply ih (pops+1) (by simp at count; omega)
    intro x hx
    exact typed x (by simp [hx])

#print axioms pop_sound
#print axioms push_sound
#print axioms end_sound
#print axioms counter_refinement
#print axioms bounded_counters
#print axioms body_shape
#print axioms body_complete

end ZkBuild.NumericEvents
