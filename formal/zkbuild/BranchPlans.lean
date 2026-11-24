import ControlPlans

namespace ZkBuild.BranchPlans

open Lean.Grind
attribute [local instance] Semiring.natCast

inductive Action where
  | pop (tag : Nat) | push (tag : Nat) | label | clear
  deriving DecidableEq

-- Tags are in pop order. Nondefault targets restore actual values, including
-- unknowns, rather than replacing them with declared label types.
def plan (actual : List Nat) : List (List Nat) → List Action
  | [] => []
  | [_] => .label :: actual.map Action.pop ++ [.clear]
  | _ :: next :: rest =>
    .label :: actual.map Action.pop ++ actual.reverse.map Action.push ++ plan actual (next :: rest)

def Compatible (expected actual : List Nat) : Prop :=
  expected.length = actual.length ∧
    ∀ pair ∈ expected.zip actual, CallEvents.InputOk pair.1 pair.2

def compatible (expected actual : List Nat) : Bool :=
  decide (expected.length = actual.length) &&
    (expected.zip actual).all (fun pair => decide (pair.2 = pair.1 ∨ pair.2 = 7))

theorem compatible_sound (expected actual : List Nat) (ok : compatible expected actual = true) :
    Compatible expected actual := by
  simp only [compatible, Bool.and_eq_true, decide_eq_true_eq] at ok
  refine ⟨ok.1, ?_⟩
  intro pair member
  have typed := List.all_eq_true.mp ok.2 pair member
  simpa [CallEvents.InputOk] using typed

theorem compatible_complete (expected actual : List Nat) (valid : Compatible expected actual) :
    compatible expected actual = true := by
  simp only [compatible, Bool.and_eq_true, decide_eq_true_eq]
  refine ⟨valid.1, List.all_eq_true.mpr ?_⟩
  intro pair member
  simpa [CallEvents.InputOk] using valid.2 pair member

def firstPops (length : Nat) (rest : List Action) : List Nat :=
  ((rest.drop 1).take length).filterMap (fun action => match action with
    | .pop tag => some tag | _ => none)

def check (targets : List (List Nat)) (actions : List Action) : Bool :=
  match targets, actions with
  | [], _ => false
  | first :: _, .pop condition :: rest =>
    let actual := firstPops first.length rest
    decide (condition = 0 ∨ condition = 7) && targets.all (compatible · actual) &&
      decide (rest = plan actual targets)
  | _, _ => false

theorem firstPops_plan (actual first : List Nat) (rest : List (List Nat))
    (size : first.length = actual.length) :
    firstPops first.length (plan actual (first :: rest)) = actual := by
  cases rest <;> simp [plan, firstPops, size, Function.comp_def]

theorem check_complete (targets : List (List Nat)) (condition : Nat) (actual : List Nat)
    (nonempty : targets ≠ []) (conditionType : CallEvents.InputOk 0 condition)
    (typed : ∀ target ∈ targets, Compatible target actual) :
    check targets (.pop condition :: plan actual targets) = true := by
  cases targets with
  | nil => simp at nonempty
  | cons first targets =>
    have firstSize := (typed first (by simp)).1
    have all : ((first :: targets).all (compatible · actual)) = true := by
      apply List.all_eq_true.mpr
      intro target member
      exact compatible_complete target actual (typed target member)
    simp only [check, firstPops_plan actual first targets firstSize]
    simpa [CallEvents.InputOk, all] using conditionType

theorem check_sound (targets : List (List Nat)) (actions : List Action)
    (accepted : check targets actions = true) :
    ∃ condition actual, targets ≠ [] ∧ CallEvents.InputOk 0 condition ∧
      (∀ target ∈ targets, Compatible target actual) ∧ actions = .pop condition :: plan actual targets := by
  cases targets with
  | nil => simp [check] at accepted
  | cons first targets =>
    cases actions with
    | nil => simp [check] at accepted
    | cons action actions =>
      cases action <;> simp only [check] at accepted
      case pop condition =>
        simp only [Bool.and_eq_true, decide_eq_true_eq] at accepted
        refine ⟨condition, firstPops first.length actions, by simp, accepted.1.1, ?_, ?_⟩
        · intro target member
          exact compatible_sound target _ (List.all_eq_true.mp accepted.1.2 _ member)
        · exact congrArg (List.cons (.pop condition)) accepted.2
      all_goals contradiction

theorem all_arities (targets : List (List Nat)) (actual : List Nat)
    (typed : ∀ target ∈ targets, Compatible target actual)
    (a b : List Nat) (ha : a ∈ targets) (hb : b ∈ targets) : a.length = b.length := by
  have left := (typed a ha).1
  have right := (typed b hb).1
  omega

theorem arity_field {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 2^32) (bb : b < 2^32) (same : (a : F) = (b : F)) : a = b := by
  have large : 2^32 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp same

theorem scratch_reverse (start length ordinal : Nat) (valid : ordinal < length)
    (bounded : start+length ≤ 2^32) :
    length-1-ordinal < length ∧ start+(length-1-ordinal) < 2^32 ∧
    length-1-(length-1-ordinal) = ordinal := by omega

theorem reverse_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (length pushed reverse : Nat) (lb : length < 2^32) (pb : pushed < 2^32) (rb : reverse < 2^32)
    (gate : (length : F)-1-(pushed : F) = (reverse : F)) :
    pushed < length ∧ reverse = length-1-pushed := by
  have small : pushed+reverse+1 < scalarModulus := by
    have large : 2^64 < scalarModulus := by decide
    omega
  have ls : length < scalarModulus := by
    have large : 2^32 < scalarModulus := by decide
    omega
  have fieldEq : (length : F) = ((pushed+reverse+1 : Nat) : F) := by
    simp only [Semiring.natCast_add, Semiring.natCast_one]
    grind
  have natural := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus ls small).mp fieldEq
  omega

-- A restored actual vector, including unknown tags, is a concrete stack
-- prefix. Rechecking another target therefore reads exactly the same tags.
def popMany : Nat → List Nat → Option (List Nat × List Nat)
  | 0, stack => some ([], stack)
  | n+1, [] => (popMany n []).map (fun (values, tail) => (7 :: values, tail))
  | n+1, value :: stack => (popMany n stack).map (fun (values, tail) => (value :: values, tail))

theorem restored_pops (actual tail : List Nat) :
    popMany actual.length (actual ++ tail) = some (actual, tail) := by
  induction actual with
  | nil => rfl
  | cons value actual ih => simp [popMany, ih]

theorem unknown_pops (length : Nat) : popMany length [] = some (List.replicate length 7, []) := by
  induction length with
  | zero => rfl
  | succ n ih => simp [popMany, ih, List.replicate_succ]

-- The added label marker neither changes operand height nor control depth.
theorem marker_heights {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (before after depth nextDepth : Nat)
    (bb : before < 2^32) (ab : after < 2^32) (db : depth < 2^32) (nb : nextDepth < 2^32)
    (height : (after : F) = (before : F)) (control : (nextDepth : F) = (depth : F)) :
    after = before ∧ nextDepth = depth :=
  ⟨arity_field after before ab bb height, arity_field nextDepth depth nb db control⟩

-- The two query streams occupy mutually exclusive event kinds. Both inactive
-- values must be canonicalized individually; constraining only their sum
-- would allow cancellation against an incorrect active query.
theorem merge_sound {F : Type} [Field F] (a b : Bool) (ak av bk bv : F)
    (disjoint : ControlPlans.flag a*ControlPlans.flag b = (0 : F))
    (addressA : (1-ControlPlans.flag a)*ak = 0)
    (addressB : (1-ControlPlans.flag b)*bk = 0)
    (valueA : (1-ControlPlans.flag a)*av = 0)
    (valueB : (1-ControlPlans.flag b)*bv = 0) :
    ControlPlans.flag (F := F) a+ControlPlans.flag b = ControlPlans.flag (a || b) ∧
    (a = true → ak+bk = ak ∧ av+bv = av) ∧
    (b = true → ak+bk = bk ∧ av+bv = bv) ∧
    (a = false → b = false → ak+bk = 0 ∧ av+bv = 0) := by
  cases a <;> cases b <;> simp [ControlPlans.flag] at * <;> grind

#print axioms check_sound
#print axioms check_complete
#print axioms all_arities
#print axioms scratch_reverse
#print axioms reverse_guard
#print axioms restored_pops
#print axioms unknown_pops
#print axioms marker_heights
#print axioms merge_sound

end ZkBuild.BranchPlans
