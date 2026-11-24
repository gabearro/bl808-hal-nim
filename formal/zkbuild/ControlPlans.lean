import CallEvents
import IndexedSignatures

namespace ZkBuild.ControlPlans

open Lean.Grind
attribute [local instance] Semiring.natCast

inductive Action where
  | pop (tag : Nat) | push (tag : Nat) | openFrame | closeFrame | clear
  deriving DecidableEq

def frameAction (opening : Bool) : Action := if opening then .openFrame else .closeFrame

def plan (inputs : List Nat) (frames : List Bool) (outputs : List Nat) (clears : Bool) : List Action :=
  inputs.map Action.pop ++ frames.map frameAction ++ outputs.map Action.push ++ if clears then [.clear] else []

inductive Matches : List Action → List Action → Prop where
  | nil : Matches [] []
  | pop {e a : Nat} {expected actual : List Action} : CallEvents.InputOk e a → Matches expected actual →
      Matches (.pop e :: expected) (.pop a :: actual)
  | push {tag : Nat} {expected actual : List Action} : Matches expected actual → Matches (.push tag :: expected) (.push tag :: actual)
  | openFrame {expected actual : List Action} : Matches expected actual → Matches (.openFrame :: expected) (.openFrame :: actual)
  | closeFrame {expected actual : List Action} : Matches expected actual → Matches (.closeFrame :: expected) (.closeFrame :: actual)
  | clear {expected actual : List Action} : Matches expected actual → Matches (.clear :: expected) (.clear :: actual)

inductive Body : List Nat → List Bool → List Nat → Bool → List Action → Prop where
  | done : Body [] [] [] false []
  | clear : Body [] [] [] true [.clear]
  | pop {tag actual : Nat} {inputs outputs : List Nat} {frames : List Bool} {clears : Bool} {rest : List Action} :
      CallEvents.InputOk tag actual → Body inputs frames outputs clears rest → Body (tag :: inputs) frames outputs clears (.pop actual :: rest)
  | openFrame {frames : List Bool} {outputs : List Nat} {clears : Bool} {rest : List Action} :
      Body [] frames outputs clears rest → Body [] (true :: frames) outputs clears (.openFrame :: rest)
  | closeFrame {frames : List Bool} {outputs : List Nat} {clears : Bool} {rest : List Action} :
      Body [] frames outputs clears rest → Body [] (false :: frames) outputs clears (.closeFrame :: rest)
  | push {tag : Nat} {outputs : List Nat} {clears : Bool} {rest : List Action} :
      Body [] [] outputs clears rest → Body [] [] (tag :: outputs) clears (.push tag :: rest)

theorem body_sound (inputs : List Nat) (frames : List Bool) (outputs : List Nat) (clears : Bool) (actual : List Action)
    (body : Body inputs frames outputs clears actual) : Matches (plan inputs frames outputs clears) actual := by
  induction body with
  | done => exact .nil
  | clear => exact .clear .nil
  | pop typed body ih => simpa [plan] using Matches.pop typed ih
  | openFrame body ih => simpa [plan, frameAction] using Matches.openFrame ih
  | closeFrame body ih => simpa [plan, frameAction] using Matches.closeFrame ih
  | push body ih => simpa [plan] using Matches.push ih

theorem body_complete (inputs : List Nat) (frames : List Bool) (outputs : List Nat) (clears : Bool) (actual : List Action)
    (matched : Matches (plan inputs frames outputs clears) actual) : Body inputs frames outputs clears actual := by
  induction inputs generalizing actual with
  | cons tag inputs ih =>
    simp only [plan, List.map_cons, List.cons_append] at matched
    cases matched with
    | pop typed rest => exact .pop typed (ih _ rest)
  | nil =>
    induction frames generalizing actual with
    | cons opening frames ih =>
      cases opening <;> simp only [plan, frameAction, List.map_nil, List.nil_append, List.map_cons, List.cons_append] at matched
      case false => cases matched with | closeFrame rest => exact .closeFrame (ih _ rest)
      case true => cases matched with | openFrame rest => exact .openFrame (ih _ rest)
    | nil =>
      induction outputs generalizing actual with
      | cons tag outputs ih =>
        simp only [plan, List.map_nil, List.nil_append, List.map_cons, List.cons_append] at matched
        cases matched with | push rest => exact .push (ih _ rest)
      | nil =>
        cases clears <;> simp only [plan, List.map_nil, List.nil_append] at matched
        case false => cases matched; exact .done
        case true => cases matched with | clear rest => cases rest; exact .clear

def check : List Action → List Action → Bool
  | [], [] => true
  | .pop e :: expected, .pop a :: actual => decide (a = e ∨ a = 7) && check expected actual
  | .push e :: expected, .push a :: actual => decide (a = e) && check expected actual
  | .openFrame :: expected, .openFrame :: actual => check expected actual
  | .closeFrame :: expected, .closeFrame :: actual => check expected actual
  | .clear :: expected, .clear :: actual => check expected actual
  | _, _ => false

theorem check_sound (expected actual : List Action) (accepted : check expected actual = true) : Matches expected actual := by
  induction expected generalizing actual with
  | nil => cases actual with
    | nil => exact .nil
    | cons action rest => simp [check] at accepted
  | cons action expected ih =>
    cases actual with
    | nil => cases action <;> simp [check] at accepted
    | cons other actual =>
      cases action <;> cases other <;> simp [check] at accepted
      case pop.pop e a => exact .pop accepted.1 (ih actual accepted.2)
      case push.push e a =>
        have same := accepted.1
        subst a
        exact .push (ih actual accepted.2)
      case openFrame.openFrame => exact .openFrame (ih actual accepted)
      case closeFrame.closeFrame => exact .closeFrame (ih actual accepted)
      case clear.clear => exact .clear (ih actual accepted)

theorem checked_body (inputs : List Nat) (frames : List Bool) (outputs : List Nat) (clears : Bool) (actual : List Action)
    (accepted : check (plan inputs frames outputs clears) actual = true) : Body inputs frames outputs clears actual :=
  body_complete inputs frames outputs clears actual (check_sound _ _ accepted)

inductive Mode where
  | blockOp | loopOp | ifOp | tryOp | elseOp | endOp | brOp | brIfOp | returnOp
  deriving DecidableEq

structure Layout where
  inputs : List Nat
  frames : List Bool
  outputs : List Nat
  clears : Bool

def layout (mode : Mode) (params results labels : List Nat) (root : Bool) : Layout :=
  match mode with
  | .blockOp | .loopOp | .tryOp => ⟨params.reverse, [true], params, false⟩
  | .ifOp => ⟨0 :: params.reverse, [true], params, false⟩
  | .elseOp => ⟨results.reverse, [false, true], params, false⟩
  | .endOp => ⟨results.reverse, [false], if root then [] else results, false⟩
  | .brOp => ⟨labels.reverse, [], [], true⟩
  | .brIfOp => ⟨0 :: labels.reverse, [], labels, false⟩
  | .returnOp => ⟨results.reverse, [], [], true⟩

theorem implicit_else_sound (params results : List Nat) (size : params.length = results.length)
    (same : ∀ i (pb : i < params.length) (rb : i < results.length),
      params.reverse[i]'(by simpa using pb) = results[results.length-1-i]'(by omega)) : params = results := by
  have reversed : params.reverse = results.reverse := by
    apply List.ext_getElem (by simpa using size)
    intro i pb rb
    simpa only [List.getElem_reverse] using same i (by simpa using pb) (by simpa using rb)
  have twice := congrArg List.reverse reversed
  simpa using twice

def flag {F : Type} [Field F] (b : Bool) : F := if b then 1 else 0

theorem zero_sum {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b c d e : Nat) (ab : a < 2^64) (bb : b < 2^64) (cb : c < 2^64) (db : d < 2^64) (eb : e < 2^64)
    (gate : (a : F)+(b : F)+(c : F)+(d : F)+(e : F) = 0) : a = 0 ∧ b = 0 ∧ c = 0 ∧ d = 0 ∧ e = 0 := by
  have bounded : a+b+c+d+e < scalarModulus := by
    have large : 2^128 < scalarModulus := by decide
    omega
  have eq : a+b+c+d+e = 0 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus bounded (by decide)).mp
    (by simp only [Semiring.natCast_add, Semiring.natCast_zero]; grind)
  omega

theorem condition_update {F : Type} [Field F] (pending pop : Bool) (after : F)
    (gate : after = flag pending-flag pop*flag pending) :
    after = flag (pending && !pop) := by
  cases pending <;> cases pop <;> simp [flag] at gate ⊢ <;> grind

theorem condition_conservation {F : Type} [Field F]
    (argsBefore argsAfter allBefore allAfter pendingBefore pendingAfter argumentPop indexPop : F)
    (args : argsAfter = argsBefore+argumentPop)
    (all : allAfter = allBefore+argumentPop+indexPop)
    (pending : pendingAfter = pendingBefore-indexPop) :
    allAfter+pendingAfter-argsAfter = allBefore+pendingBefore-argsBefore := by grind

structure Counts where
  args : Nat
  pushes : Nat
  opened : Nat
  closed : Nat
  cleared : Nat

def Bounded (state : Counts) : Prop := state.args < 2^64 ∧ state.pushes < 2^64 ∧
  state.opened < 2^64 ∧ state.closed < 2^64 ∧ state.cleared < 2^64

structure EndGates {F : Type} [Field F] (state : Counts) (inputs outputs : Nat)
    (opening closing clearing pending : Bool) : Prop where
  args : (state.args : F)-(inputs : F) = 0
  pushes : (state.pushes : F)-(outputs : F) = 0
  opened : (state.opened : F)-flag opening = 0
  closed : (state.closed : F)-flag closing = 0
  cleared : (state.cleared : F)-flag clearing = 0
  pending : flag pending = (0 : F)

theorem flag_cast {F : Type} [Field F] (b : Bool) : (b.toNat : F) = flag b := by
  cases b <;> simp [flag, Bool.toNat, Semiring.natCast_zero, Semiring.natCast_one]

theorem end_gates_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (state : Counts) (inputs outputs : Nat) (opening closing clearing pending : Bool)
    (sb : Bounded state) (ib : inputs < 2^32) (ob : outputs < 2^32)
    (gates : EndGates (F := F) state inputs outputs opening closing clearing pending) :
    state.args = inputs ∧ state.pushes = outputs ∧ state.opened = opening.toNat ∧
      state.closed = closing.toNat ∧ state.cleared = clearing.toNat ∧ pending = false := by
  have args := gates.args
  have pushes := gates.pushes
  have opened := gates.opened
  have closed := gates.closed
  have cleared := gates.cleared
  refine ⟨NumericEvents.nat_eq (F := F) _ _ sb.1 (by simp [NumericEvents.countBound]; omega) (by grind),
    NumericEvents.nat_eq (F := F) _ _ sb.2.1 (by simp [NumericEvents.countBound]; omega) (by grind),
    NumericEvents.nat_eq (F := F) _ _ sb.2.2.1 (by cases opening <;> decide) ?_,
    NumericEvents.nat_eq (F := F) _ _ sb.2.2.2.1 (by cases closing <;> decide) ?_,
    NumericEvents.nat_eq (F := F) _ _ sb.2.2.2.2 (by cases clearing <;> decide) ?_, ?_⟩
  · rw [flag_cast]; grind
  · rw [flag_cast]; grind
  · rw [flag_cast]; grind
  · cases pending with
    | false => rfl
    | true => exact False.elim (Field.zero_ne_one gates.pending.symm)

#print axioms body_sound
#print axioms body_complete
#print axioms check_sound
#print axioms implicit_else_sound
#print axioms zero_sum
#print axioms condition_update
#print axioms condition_conservation
#print axioms end_gates_sound

end ZkBuild.ControlPlans
