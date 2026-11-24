import ControlEvents

namespace ZkBuild.InstructionSchedule

open Lean.Grind OperandEvents ControlEvents
attribute [local instance] Semiring.natCast

def allowed (opened pending : Bool) (kind : Kind) : Bool :=
  if pending then decide (kind = .controlPush) && !opened else
    match kind with
    | .functionBegin | .functionEnd | .padding | .instructionBegin => !opened
    | _ => opened

def afterOpen (opened : Bool) (kind : Kind) : Bool := match kind with
  | .instructionBegin => true
  | .instructionEnd => false
  | _ => opened

structure ModeGates {F : Type} [Field F] (opened pending : Bool) (kind : Kind) (nextOpen : F) : Prop where
  root : flag pending*(1-selected kind .controlPush) = (0 : F)
  rootClosed : flag pending*flag opened = (0 : F)
  start : selected kind .instructionBegin*flag opened = (0 : F)
  finish : selected kind .instructionEnd*(1-flag opened) = (0 : F)
  outside : (selected kind .functionBegin+selected kind .functionEnd+selected kind .padding)*flag opened = (0 : F)
  middle : (selected kind .push+selected kind .pop+selected kind .controlPush+
    selected kind .controlPop+selected kind .clear+selected kind .labelCheck-flag pending)*(1-flag opened) = (0 : F)
  update : nextOpen = flag opened+selected kind .instructionBegin-selected kind .instructionEnd

theorem mode_sound {F : Type} [Field F] (opened pending : Bool) (kind : Kind) (nextOpen : F)
    (gates : ModeGates opened pending kind nextOpen) :
    allowed opened pending kind = true ∧ nextOpen = flag (afterOpen opened kind) := by
  have root := gates.root
  have rootClosed := gates.rootClosed
  have start := gates.start
  have finish := gates.finish
  have outside := gates.outside
  have middle := gates.middle
  have update := gates.update
  cases k : kind <;> cases o : opened <;> cases p : pending <;>
    simp [allowed, afterOpen, selected, flag, k, o, p] at root rootClosed start finish outside middle update ⊢
  all_goals try grind
  all_goals have bad : (1 : F) = 0 := by grind
  all_goals exact False.elim (Field.zero_ne_one bad.symm)

theorem mode_complete {F : Type} [Field F] (opened pending : Bool) (kind : Kind)
    (ok : allowed opened pending kind = true) :
    ModeGates opened pending kind (flag (F := F) (afterOpen opened kind)) := by
  cases k : kind <;> cases o : opened <;> cases p : pending <;> simp [allowed, k, o, p] at ok
  all_goals constructor <;> simp [afterOpen, selected, flag, k, o, p] <;> grind

def pcBase (previous : Nat) (kind : Kind) : Nat := if kind = .functionBegin then 0 else previous
def nextPc (previous : Nat) (kind : Kind) : Nat := pcBase previous kind + if kind = .instructionEnd then 1 else 0
def chosenOpcode (previous row : Nat) (kind : Kind) : Nat :=
  if kind = .functionBegin ∨ kind = .instructionBegin then row else previous

structure BindingGates {F : Type} [Field F] (previousPc previousOpcode rowPc rowOpcode : Nat) (kind : Kind)
    (base opcode afterPc : F) : Prop where
  baseEq : base = (previousPc : F)+selected kind .functionBegin*(0-(previousPc : F))
  pcEq : (1-selected kind .padding)*((rowPc : F)-base+selected kind .functionEnd) = 0
  paddingPc : selected kind .padding*(rowPc : F) = 0
  pcUpdate : afterPc = base+selected kind .instructionEnd
  opcodeEq : opcode = (previousOpcode : F)+(selected kind .functionBegin+selected kind .instructionBegin)*
    ((rowOpcode : F)-(previousOpcode : F))
  opcodeMatch : (1-selected kind .padding)*((rowOpcode : F)-opcode) = 0
  functionStart : selected kind .functionBegin*((rowOpcode : F)-2) = 0
  functionEnd : selected kind .functionEnd*((rowOpcode : F)-11) = 0
  paddingOpcode : selected kind .padding*(rowOpcode : F) = 0

def BindingSpec (previousPc previousOpcode rowPc rowOpcode : Nat) (kind : Kind) : Prop :=
  (if kind = .padding then rowPc = 0 else if kind = .functionEnd then
    rowPc+1 = pcBase previousPc kind else rowPc = pcBase previousPc kind) ∧
  (if kind = .padding then rowOpcode = 0 else rowOpcode = chosenOpcode previousOpcode rowOpcode kind) ∧
  (kind = .functionBegin → rowOpcode = 2) ∧ (kind = .functionEnd → rowOpcode = 11)

theorem chosen_field {F : Type} [Field F] (previousPc previousOpcode rowPc rowOpcode : Nat) (kind : Kind)
    (base opcode afterPc : F) (gates : BindingGates previousPc previousOpcode rowPc rowOpcode kind base opcode afterPc) :
    base = (pcBase previousPc kind : F) ∧ opcode = (chosenOpcode previousOpcode rowOpcode kind : F) ∧
      afterPc = (nextPc previousPc kind : F) := by
  have baseEq := gates.baseEq
  have opcodeEq := gates.opcodeEq
  have pcUpdate := gates.pcUpdate
  cases k : kind <;> simp [pcBase, chosenOpcode, nextPc, selected, flag, k,
    Semiring.natCast_zero, Semiring.natCast_add, Semiring.natCast_one] at baseEq opcodeEq pcUpdate ⊢ <;> grind

theorem binding_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (previousPc previousOpcode rowPc rowOpcode : Nat) (kind : Kind) (base opcode afterPc : F)
    (pcBound : previousPc ≤ bound) (rowPcBound : rowPc < bound)
    (opcodeBound : previousOpcode < 2^16) (rowOpcodeBound : rowOpcode < 2^16)
    (gates : BindingGates previousPc previousOpcode rowPc rowOpcode kind base opcode afterPc) :
    BindingSpec previousPc previousOpcode rowPc rowOpcode kind ∧ nextPc previousPc kind ≤ bound := by
  obtain ⟨baseEq, opcodeEq, afterEq⟩ := chosen_field previousPc previousOpcode rowPc rowOpcode kind base opcode afterPc gates
  have pcMatch := gates.pcEq
  have padPc := gates.paddingPc
  have opMatch := gates.opcodeMatch
  have start := gates.functionStart
  have finish := gates.functionEnd
  have padOp := gates.paddingOpcode
  have two : ((2 : Nat) : F) = (2 : F) := Semiring.natCast_eq_ofNat 2
  have eleven : ((11 : Nat) : F) = (11 : F) := Semiring.natCast_eq_ofNat 11
  have spec : BindingSpec previousPc previousOpcode rowPc rowOpcode kind := by
    constructor
    · cases k : kind <;> simp [selected, flag, k, baseEq, pcBase] at pcMatch padPc ⊢
      case functionEnd =>
        apply natural_eq (F := F) _ _ (by omega) (by omega)
        simp only [Semiring.natCast_add, Semiring.natCast_one]
        grind
      case padding =>
        exact natural_eq (F := F) _ _ (by omega) (by decide) (by simp only [Semiring.natCast_zero]; grind)
      all_goals exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)
    · constructor
      · cases k : kind <;> simp [selected, flag, k, opcodeEq, chosenOpcode] at opMatch padOp ⊢
        case padding =>
          exact natural_eq (F := F) _ _ (by simp [bound]; omega) (by decide)
            (by simp only [Semiring.natCast_zero]; grind)
        all_goals exact natural_eq (F := F) _ _ (by simp [bound]; omega) (by simp [bound]; omega) (by grind)
      · constructor
        · intro k
          simp [selected, flag, k] at start
          apply natural_eq (F := F) _ _ (by simp [bound]; omega) (by decide)
          rw [two]; grind
        · intro k
          simp [selected, flag, k] at finish
          apply natural_eq (F := F) _ _ (by simp [bound]; omega) (by decide)
          rw [eleven]; grind
  refine ⟨spec, ?_⟩
  by_cases ending : kind = .instructionEnd
  · have rowPcEq : rowPc = previousPc := by simpa [ending, pcBase] using spec.1
    simp [nextPc, pcBase, ending]
    omega
  · by_cases beginning : kind = .functionBegin
    · simp [nextPc, pcBase, beginning]
    · simp [nextPc, pcBase, beginning, ending]
      exact pcBound

#print axioms mode_sound
#print axioms mode_complete
#print axioms binding_sound

theorem binding_complete {F : Type} [Field F]
    (previousPc previousOpcode rowPc rowOpcode : Nat) (kind : Kind)
    (spec : BindingSpec previousPc previousOpcode rowPc rowOpcode kind) :
    BindingGates previousPc previousOpcode rowPc rowOpcode kind
      (pcBase previousPc kind : F) (chosenOpcode previousOpcode rowOpcode kind : F)
      (nextPc previousPc kind : F) := by
  have pc := spec.1
  have op := spec.2.1
  have start := spec.2.2.1
  have finish := spec.2.2.2
  have two : ((2 : Nat) : F) = (2 : F) := Semiring.natCast_eq_ofNat 2
  have eleven : ((11 : Nat) : F) = (11 : F) := Semiring.natCast_eq_ofNat 11
  constructor
  · cases k : kind <;> simp [pcBase, selected, flag, k, Semiring.natCast_zero] <;> grind
  · cases k : kind <;> simp [pcBase, selected, flag, k] at pc ⊢
    case functionEnd =>
      have field := congrArg (fun n : Nat => (n : F)) pc
      simp only [Semiring.natCast_add, Semiring.natCast_one] at field
      grind
    all_goals have field := congrArg (fun n : Nat => (n : F)) pc
    all_goals grind
  · by_cases padding : kind = .padding
    · have rowZero : rowPc = 0 := by simpa [padding] using pc
      simp [selected, flag, padding, rowZero, Semiring.natCast_zero]; grind
    · simp [selected, flag, padding]; grind
  · cases k : kind <;> simp [nextPc, pcBase, selected, flag, k,
      Semiring.natCast_add, Semiring.natCast_one, Semiring.natCast_zero] <;> grind
  · cases k : kind <;> simp [chosenOpcode, selected, flag, k] <;> grind
  · cases k : kind <;> simp [chosenOpcode, selected, flag, k] at op ⊢
    all_goals try grind
    all_goals have field := congrArg (fun n : Nat => (n : F)) op
    all_goals grind
  · by_cases beginning : kind = .functionBegin
    · have rowTwo := start beginning
      simp [selected, flag, beginning, rowTwo, two]; grind
    · simp [selected, flag, beginning]; grind
  · by_cases ending : kind = .functionEnd
    · have rowEleven := finish ending
      simp [selected, flag, ending, rowEleven, eleven]; grind
    · simp [selected, flag, ending]; grind
  · by_cases padding : kind = .padding
    · have rowZero : rowOpcode = 0 := by simpa [padding] using op
      simp [selected, flag, padding, rowZero, Semiring.natCast_zero]; grind
    · simp [selected, flag, padding]; grind

#print axioms binding_complete

end ZkBuild.InstructionSchedule
