import RangeConstraints

/- Field soundness of the operand-event transition. The control floor and
   unreachable flag are inputs authenticated by ControlEvents/ControlRefinement.
   Opcode/event ordering and binary decoding are separate proof obligations. -/
namespace ZkBuild.OperandEvents

open Lean.Grind R1CS
attribute [local instance] Semiring.natCast

def bound : Nat := 2^32

inductive Kind where
  | functionBegin | instructionBegin | push | pop | controlPush | controlPop
  | clear | instructionEnd | functionEnd | labelCheck | padding
  deriving DecidableEq, Inhabited

def kindCode : Kind → Nat
  | .functionBegin => 0 | .instructionBegin => 1 | .push => 2 | .pop => 3
  | .controlPush => 4 | .controlPop => 5 | .clear => 6 | .instructionEnd => 7
  | .functionEnd => 8 | .labelCheck => 9 | .padding => 15

def codes : List Nat := [0, 1, 2, 3, 4, 5, 6, 7, 8, 15]

theorem selector_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (tag : Fin 256) (length : values.length = 10)
    (boolean : ∀ value ∈ values, value*(value-1) = 0)
    (total : sum values = 1) (binding : weightedValues codes values = (tag.val : F)) :
    tag.val ∈ codes ∧ values = (codes.map fun code => decide (code = tag.val)).map boolValue := by
  constructor
  · exact opcode_selection_sound values codes tag (by simp [codes, length]) (by omega)
      (by decide) boolean total binding
  · exact opcode_selectors_determined values codes tag (by simp [codes, length]) (by omega)
      (by decide) (by decide) boolean total binding

structure Row where
  kind : Kind
  functionIndex : Nat
  height : Nat
  floor : Nat
  valueType : Fin 8
  polymorphic : Bool
  unreachable : Bool
  deriving Inhabited

def flag {F : Type} [CommRing F] (value : Bool) : F := if value then 1 else 0
def isPush (row : Row) : Bool := decide (row.kind = .push)
def isPop (row : Row) : Bool := decide (row.kind = .pop)
def isClear (row : Row) : Bool := decide (row.kind = .clear)

def StepGates {F : Type} [Field F] (before : Nat) (row : Row) (available : Nat) : Prop :=
  let push : F := flag (isPush row)
  let pop : F := flag (isPop row)
  let clear : F := flag (isClear row)
  let poly : F := flag row.polymorphic
  poly*(1-pop) = 0 ∧
  poly*((row.valueType.val : F)-7) = 0 ∧
  (1-push-pop)*((row.valueType.val : F)-7) = 0 ∧
  poly*((before : F)-(row.floor : F)) = 0 ∧
  poly*(1-flag row.unreachable) = 0 ∧
  (available : F) = (pop+clear)*((before : F)-(row.floor : F))-(pop-poly) ∧
  (row.height : F) = (before : F)+push-(pop-poly)-clear*((before : F)-(row.floor : F))

def StepSpec (before : Nat) (row : Row) : Prop :=
  (row.polymorphic = true → row.kind = .pop ∧ row.valueType.val = 7 ∧
    before = row.floor ∧ row.unreachable = true) ∧
  (row.kind ≠ .push → row.kind ≠ .pop → row.valueType.val = 7) ∧
  match row.kind with
  | .push => row.height = before+1
  | .pop => if row.polymorphic then row.height = before else
      row.floor < before ∧ row.height+1 = before
  | .clear => row.floor ≤ before ∧ row.height = row.floor
  | _ => row.height = before

theorem natural_eq {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 3*bound) (bb : b < 3*bound) (same : (a : F) = (b : F)) : a = b := by
  have large : 3*bound < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans ab large) (Nat.lt_trans bb large)).mp same

theorem polymorphic_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (before : Nat) (row : Row) (available : Nat) (hb : before < bound) (fb : row.floor < bound)
    (gates : StepGates (F := F) before row available) (poly : row.polymorphic = true) :
    row.kind = .pop ∧ row.valueType.val = 7 ∧ before = row.floor ∧ row.unreachable = true := by
  have popGate := gates.1
  have typeGate := gates.2.1
  have floorGate := gates.2.2.2.1
  have reachGate := gates.2.2.2.2.1
  have kind : row.kind = .pop := by
    cases k : row.kind <;> try rfl
    all_goals have bad : (1 : F) = 0 := by simp [flag, isPop, poly, k] at popGate; grind
    all_goals exact False.elim (Field.zero_ne_one bad.symm)
  have valueField : (row.valueType.val : F) = (7 : F) := by simp [flag, poly] at typeGate; grind
  have floorField : (before : F) = (row.floor : F) := by simp [flag, poly] at floorGate; grind
  have unreachable : row.unreachable = true := by
    cases r : row.unreachable <;> try rfl
    have bad : (1 : F) = 0 := by simp [flag, poly, r] at reachGate; grind
    exact False.elim (Field.zero_ne_one bad.symm)
  exact ⟨kind, natural_eq (F := F) _ _ (by have := row.valueType.isLt; simp [bound]; omega) (by decide)
      (by simpa [Semiring.natCast_eq_ofNat] using valueField),
    natural_eq (F := F) _ _ (by omega) (by omega) floorField, unreachable⟩

theorem step_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (before : Nat) (row : Row) (available : Nat)
    (hb : before < bound) (fb : row.floor < bound) (afterBound : row.height < bound)
    (availableBound : available < bound) (gates : StepGates (F := F) before row available) :
    StepSpec before row := by
  have poly := polymorphic_guard before row available hb fb gates
  have canonical : row.kind ≠ .push → row.kind ≠ .pop → row.valueType.val = 7 := by
    intro noPush noPop
    have typed := gates.2.2.1
    simp [flag, isPush, isPop, noPush, noPop] at typed
    have seven : ((7 : Nat) : F) = (7 : F) := Semiring.natCast_eq_ofNat 7
    have same : (row.valueType.val : F) = ((7 : Nat) : F) := by rw [seven]; grind
    exact natural_eq (F := F) row.valueType.val 7
      (by have := row.valueType.isLt; simp [bound]; omega) (by decide) same
  refine ⟨poly, canonical, ?_⟩
  have avail := gates.2.2.2.2.2.1
  have height := gates.2.2.2.2.2.2
  cases k : row.kind <;> cases p : row.polymorphic <;>
    simp [k, p] <;>
    try { have bad := poly p; simp [k] at bad }
  all_goals simp [flag, isPush, isPop, isClear, k, p] at avail height
  case push.false =>
    apply natural_eq (F := F) _ _ (by omega) (by omega)
    simp only [Semiring.natCast_add, Semiring.natCast_one]
    grind
  case pop.false =>
    have predecessor : before = row.floor+available+1 := by
      apply natural_eq (F := F) _ _ (by omega) (by omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]
      grind
    constructor
    · omega
    · apply natural_eq (F := F) _ _ (by omega) (by omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]
      grind
  case pop.true =>
    apply natural_eq (F := F) _ _ (by omega) (by omega)
    grind
  case clear.false =>
    have predecessor : before = row.floor+available := by
      apply natural_eq (F := F) _ _ (by omega) (by omega)
      simp only [Semiring.natCast_add]
      grind
    constructor
    · omega
    · exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)
  all_goals exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)

structure Access where
  active : Bool
  write : Bool
  address : Nat
  value : Nat

def active (row : Row) : Bool := isPush row || (isPop row && !row.polymorphic)

def project (row : Row) : Access :=
  ⟨active row, isPush row,
    if active row then row.functionIndex*bound + (row.height-(isPush row).toNat) else 0,
    if active row then row.valueType.val else 0⟩

def AccessGates {F : Type} [Field F] (row : Row) (a w address value : F) : Prop :=
  let push : F := flag (isPush row)
  let pop : F := flag (isPop row)
  let poly : F := flag row.polymorphic
  a = push+pop-poly ∧ w = push ∧
  address = a*((row.functionIndex : F)*(bound : F)+(row.height : F)-push) ∧
  value = a*(row.valueType.val : F)

theorem predecessor_field {F : Type} [CommRing F] (n : Nat) (positive : 0 < n) :
    ((n-1 : Nat) : F) = (n : F)-1 := by
  have natural : n-1+1 = n := by omega
  have field := congrArg (fun k : Nat => (k : F)) natural
  simp only [Semiring.natCast_add, Semiring.natCast_one] at field
  grind

theorem access_sound {F : Type} [Field F] (before : Nat) (row : Row)
    (a w address value : F) (step : StepSpec before row)
    (gates : AccessGates row a w address value) :
    a = flag (project row).active ∧ w = flag (project row).write ∧
      address = ((project row).address : F) ∧ value = ((project row).value : F) := by
  have poly := step.1
  have positive : row.kind = .push → 0 < row.height := by
    intro k
    have pushed := step.2.2
    simp [k] at pushed
    omega
  cases k : row.kind <;> cases p : row.polymorphic <;>
    try { have bad := poly p; simp [k] at bad }
  all_goals simp [AccessGates, project, active, isPush, isPop, flag, k, p,
    Semiring.natCast_add, Semiring.natCast_mul, Semiring.natCast_zero] at gates ⊢
  all_goals try { have pred := predecessor_field (F := F) row.height (positive k); grind }
  all_goals grind

theorem projected_address_bound (row : Row)
    (functionBound : row.functionIndex < bound) (heightBound : row.height < bound) :
    (project row).address < bound*bound := by
  have basePositive : 0 < bound := by decide
  have slotBound : row.height-(isPush row).toNat < bound := by omega
  unfold project
  split
  · calc
      row.functionIndex*bound + (row.height-(isPush row).toNat) < row.functionIndex*bound + bound :=
        Nat.add_lt_add_left slotBound _
      _ = (row.functionIndex+1)*bound := by rw [Nat.add_mul, Nat.one_mul]
      _ ≤ bound*bound := Nat.mul_le_mul_right bound functionBound
  · exact Nat.mul_pos basePositive basePositive

def availableWitness (before : Nat) (row : Row) : Nat :=
  if isPop row || isClear row then
    before-row.floor-(isPop row && !row.polymorphic).toNat
  else 0

theorem difference_field {F : Type} [CommRing F] (a b : Nat) (le : b ≤ a) :
    ((a-b : Nat) : F) = (a : F)-(b : F) := by
  have natural := Nat.sub_add_cancel le
  have field := congrArg (fun k : Nat => (k : F)) natural
  simp only [Semiring.natCast_add] at field
  grind

theorem step_complete {F : Type} [Field F] (before : Nat) (row : Row)
    (beforeBound : before < bound) (step : StepSpec before row) :
    availableWitness before row < bound ∧
      StepGates (F := F) before row (availableWitness before row) := by
  constructor
  · unfold availableWitness
    split
    · have := Nat.sub_le before row.floor
      have := Nat.sub_le (before-row.floor) (isPop row && !row.polymorphic).toNat
      omega
    · exact (by decide : 0 < bound)
  · have poly := step.1
    have canonical := step.2.1
    have transition := step.2.2
    cases k : row.kind <;> cases p : row.polymorphic <;>
      try { have bad := poly p; simp [k] at bad }
    all_goals simp [k, p] at transition
    all_goals simp [StepGates, availableWitness, flag, isPush, isPop, isClear, k, p]
    case push.false =>
      have field := congrArg (fun n : Nat => (n : F)) transition
      simp only [Semiring.natCast_add, Semiring.natCast_one] at field
      grind
    case pop.false =>
      have gap := difference_field (F := F) before row.floor (by omega)
      have decrement := predecessor_field (F := F) (before-row.floor) (by omega)
      have field := congrArg (fun n : Nat => (n : F)) transition.2
      simp only [Semiring.natCast_add, Semiring.natCast_one] at field
      grind
    case pop.true =>
      have properties := poly p
      have tag : (row.valueType.val : F) = 7 := by
        rw [properties.2.1]; exact Semiring.natCast_eq_ofNat 7
      simp only [properties.2.2.1, properties.2.2.2, ↓reduceIte] at *
      grind
    case clear.false =>
      have gap := difference_field (F := F) before row.floor transition.1
      have field := congrArg (fun n : Nat => (n : F)) transition.2
      have tagNat := canonical (by simp [k]) (by simp [k])
      have tag : (row.valueType.val : F) = 7 := by rw [tagNat]; exact Semiring.natCast_eq_ofNat 7
      grind
    all_goals
      have tagNat := canonical (by simp [k]) (by simp [k])
      have tag : (row.valueType.val : F) = 7 := by rw [tagNat]; exact Semiring.natCast_eq_ofNat 7
      have field := congrArg (fun n : Nat => (n : F)) transition
      grind

#print axioms selector_sound
#print axioms step_sound
#print axioms access_sound
#print axioms projected_address_bound
#print axioms step_complete

end ZkBuild.OperandEvents
