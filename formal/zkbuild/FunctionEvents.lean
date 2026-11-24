import ControlEvents
import NumericEvents

/- Function-body schedule and namespace continuity in wasm_control_events.
   The module composition binds the first index and final function count. -/
namespace ZkBuild.FunctionEvents

open Lean.Grind OperandEvents ControlEvents
attribute [local instance] Semiring.natCast

def nextOpen (opened : Bool) (kind : Kind) : Bool := match kind with
  | .functionBegin => true
  | .functionEnd => false
  | _ => opened

def nextIndex (index : Nat) (kind : Kind) : Nat := index + (if kind = .functionEnd then 1 else 0)

def ScheduleOk (opened : Bool) (kind : Kind) : Prop :=
  if kind = .functionBegin ∨ kind = .padding then opened = false else opened = true

structure Gates {F : Type} [Field F] (opened : Bool) (kind : Kind) (index rowIndex : Nat)
    (afterOpen afterIndex : F) : Prop where
  closed : (selected kind .functionBegin+selected kind .padding) * flag opened = (0 : F)
  bodyOpen : (1-selected kind .functionBegin-selected kind .padding)*(1-flag opened) = (0 : F)
  sameFunction : (1-selected kind .padding)*((rowIndex : F)-(index : F)) = 0
  openUpdate : afterOpen = flag opened+selected kind .functionBegin-selected kind .functionEnd
  indexUpdate : afterIndex = (index : F)+selected kind .functionEnd

theorem schedule_sound {F : Type} [Field F] (opened : Bool) (kind : Kind)
    (index rowIndex : Nat) (afterOpen afterIndex : F)
    (gates : Gates opened kind index rowIndex afterOpen afterIndex) : ScheduleOk opened kind := by
  have closed := gates.closed
  have bodyOpen := gates.bodyOpen
  cases k : kind <;> cases o : opened <;> simp [ScheduleOk, k, o]
  all_goals
    have bad : (1 : F) = 0 := by
      simp [selected, flag, k, o] at closed bodyOpen
      grind
    exact False.elim (Field.zero_ne_one bad.symm)

theorem step_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (opened : Bool) (kind : Kind) (index rowIndex : Nat) (afterOpen afterIndex : F)
    (indexBound : index ≤ bound) (rowBound : rowIndex < bound)
    (gates : Gates opened kind index rowIndex afterOpen afterIndex) :
    ScheduleOk opened kind ∧ (kind ≠ .padding → rowIndex = index) ∧
      afterOpen = flag (nextOpen opened kind) ∧ afterIndex = (nextIndex index kind : F) ∧
      nextIndex index kind ≤ bound := by
  have schedule := schedule_sound opened kind index rowIndex afterOpen afterIndex gates
  have sameBody : kind ≠ .padding → rowIndex = index := by
    intro notPadding
    have gate := gates.sameFunction
    simp [selected, flag, notPadding] at gate
    exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)
  refine ⟨schedule, sameBody, ?_, ?_, ?_⟩
  · have update := gates.openUpdate
    cases k : kind <;> cases o : opened <;> simp [ScheduleOk, k, o] at schedule
    all_goals simp [nextOpen, selected, flag, k, o] at update ⊢ <;> grind
  · have update := gates.indexUpdate
    cases k : kind <;>
      simp [nextIndex, selected, flag, k, Semiring.natCast_add, Semiring.natCast_one,
        Semiring.natCast_zero] at update ⊢ <;> grind
  · by_cases ending : kind = .functionEnd
    · have same := sameBody (by simp [ending])
      simp [nextIndex, ending]
      omega
    · simp [nextIndex, ending]
      exact indexBound

theorem step_complete {F : Type} [Field F] (opened : Bool) (kind : Kind) (index rowIndex : Nat)
    (schedule : ScheduleOk opened kind) (sameBody : kind ≠ .padding → rowIndex = index) :
    Gates opened kind index rowIndex (flag (F := F) (nextOpen opened kind)) (nextIndex index kind : F) := by
  constructor
  · cases k : kind <;> cases o : opened <;> simp [ScheduleOk, k, o] at schedule
    all_goals simp [selected, flag, k, o] <;> grind
  · cases k : kind <;> cases o : opened <;> simp [ScheduleOk, k, o] at schedule
    all_goals simp [selected, flag, k, o] <;> grind
  · by_cases padding : kind = .padding
    · simp [selected, flag, padding]; grind
    · have same := sameBody padding
      simp [selected, flag, padding, same]; grind
  · cases k : kind <;> cases o : opened <;> simp [ScheduleOk, k, o] at schedule
    all_goals simp [selected, flag, nextOpen, k, o] <;> grind
  · cases k : kind <;> simp [selected, flag, nextIndex, k,
      Semiring.natCast_add, Semiring.natCast_one, Semiring.natCast_zero] <;> grind

def endCount : List Kind → Nat
  | [] => 0
  | kind :: rest => (if kind = .functionEnd then 1 else 0) + endCount rest

def runIndex (first : Nat) : List Kind → Nat
  | [] => first
  | kind :: rest => runIndex (nextIndex first kind) rest

theorem end_count_bound (events : List Kind) : endCount events ≤ events.length := by
  induction events with
  | nil => simp [endCount]
  | cons kind rest ih => simp only [endCount, List.length_cons]; split <;> omega

theorem final_index (events : List Kind) (first : Nat) : runIndex first events = first+endCount events := by
  induction events generalizing first with
  | nil => rfl
  | cons kind rest ih => simp only [runIndex, ih, nextIndex, endCount]; omega

theorem all_bodies_counted {F : Type} [Field F] [IsCharP F scalarModulus]
    (events : List Kind) (first functions : Nat) (fb : first < 2^32)
    (nb : functions < 2^32) (eb : events.length < 2^32)
    (gate : (endCount events : F) = (functions : F)-(first : F)) :
    runIndex first events = functions := by
  rw [final_index]
  have count := end_count_bound events
  apply NumericEvents.nat_eq (F := F)
  · simp [NumericEvents.countBound]; omega
  · simp [NumericEvents.countBound]; omega
  · push_cast
    grind

#print axioms step_sound
#print axioms step_complete
#print axioms final_index
#print axioms all_bodies_counted

end ZkBuild.FunctionEvents
