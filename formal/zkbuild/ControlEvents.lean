import OperandEvents
import ControlMemory

namespace ZkBuild.ControlEvents

open Lean.Grind OperandEvents
attribute [local instance] Semiring.natCast

def selected {F : Type} [CommRing F] (kind expected : Kind) : F := flag (decide (kind = expected))

structure Gates {F : Type} [Field F] (beforeDepth afterDepth : Nat) (row : Row)
    (empty reciprocal : F) : Prop where
  zero : (beforeDepth : F)*empty = 0
  inverse : (beforeDepth : F)*reciprocal = 1-empty
  context : empty*(2*(row.floor : F)+flag row.unreachable) = 0
  controlTop : (selected row.kind .controlPop + selected row.kind .clear)*empty = 0
  operandTop : (selected row.kind .push + selected row.kind .pop)*empty = 0
  depth : (afterDepth : F) = (beforeDepth : F)+selected row.kind .controlPush-selected row.kind .controlPop
  close : selected row.kind .controlPop*((row.height : F)-(row.floor : F)) = 0
  boundary : (selected row.kind .functionBegin+selected row.kind .functionEnd+selected row.kind .padding)*
    (afterDepth : F) = 0

theorem empty_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (depth : Nat) (small : depth < bound) (empty reciprocal : F)
    (zero : (depth : F)*empty = 0) (inverse : (depth : F)*reciprocal = 1-empty) :
    empty = if depth = 0 then 1 else 0 := by
  by_cases isZero : depth = 0
  · simp only [isZero, ↓reduceIte]
    simp only [isZero, Semiring.natCast_zero] at inverse
    grind
  · simp only [isZero, ↓reduceIte]
    rcases Field.of_mul_eq_zero zero with bad | good
    · have castZero : (depth : F) = ((0 : Nat) : F) := by simpa [Semiring.natCast_zero] using bad
      have natural := natural_eq (F := F) depth 0 (by omega) (by decide) castZero
      exact False.elim (isZero natural)
    · exact good

def needsTop (kind : Kind) : Bool :=
  decide (kind = .controlPop ∨ kind = .clear ∨ kind = .push ∨ kind = .pop)

def Spec (beforeDepth afterDepth : Nat) (row : Row) : Prop :=
  (beforeDepth = 0 → row.floor = 0 ∧ row.unreachable = false) ∧
  (needsTop row.kind = true → 0 < beforeDepth) ∧
  (match row.kind with
    | .controlPush => afterDepth = beforeDepth+1
    | .controlPop => afterDepth+1 = beforeDepth
    | _ => afterDepth = beforeDepth) ∧
  (row.kind = .controlPop → row.height = row.floor) ∧
  (row.kind = .functionBegin ∨ row.kind = .functionEnd ∨ row.kind = .padding → afterDepth = 0)

theorem step_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (beforeDepth afterDepth : Nat) (row : Row) (empty reciprocal : F)
    (beforeBound : beforeDepth < bound) (afterBound : afterDepth < bound)
    (floorBound : row.floor < bound) (heightBound : row.height < bound)
    (gates : Gates beforeDepth afterDepth row empty reciprocal) : Spec beforeDepth afterDepth row := by
  have indicator := empty_sound beforeDepth beforeBound empty reciprocal gates.zero gates.inverse
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · intro zero
    have emptyOne : empty = 1 := by simp [zero] at indicator; exact indicator
    have context := gates.context
    rw [emptyOne] at context
    have two : ((2 : Nat) : F) = (2 : F) := Semiring.natCast_eq_ofNat 2
    have bit : flag (F := F) row.unreachable = (row.unreachable.toNat : F) := by
      cases row.unreachable <;> simp [flag, Bool.toNat, Semiring.natCast_zero, Semiring.natCast_one]
    have encodedZero : 2*row.floor+row.unreachable.toNat = 0 := by
      apply natural_eq (F := F) _ _ (by cases row.unreachable <;> simp [Bool.toNat] <;> omega) (by decide)
      simp only [Semiring.natCast_add, Semiring.natCast_mul, Semiring.natCast_zero, two]
      grind
    cases r : row.unreachable <;> simp [r, Bool.toNat] at encodedZero ⊢ <;> omega
  · intro needs
    by_cases zero : beforeDepth = 0
    · have emptyOne : empty = 1 := by simp [zero] at indicator; exact indicator
      have control := gates.controlTop
      have operand := gates.operandTop
      cases k : row.kind <;> simp [needsTop, k] at needs
      all_goals
        have bad : (1 : F) = 0 := by
          simp [selected, flag, k, emptyOne] at control operand
          grind
        exact False.elim (Field.zero_ne_one bad.symm)
    · omega
  · have depth := gates.depth
    cases k : row.kind <;> simp [selected, flag, k] at depth ⊢
    case controlPush =>
      apply natural_eq (F := F) _ _ (by omega) (by omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]
      grind
    case controlPop =>
      apply natural_eq (F := F) _ _ (by omega) (by omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]
      grind
    all_goals exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)
  · intro closed
    have h := gates.close
    simp [selected, flag, closed] at h
    exact natural_eq (F := F) _ _ (by omega) (by omega) (by grind)
  · intro boundary
    have h := gates.boundary
    rcases boundary with begin | finish | padding <;> simp [selected, flag, *] at h
    all_goals
      apply natural_eq (F := F) afterDepth 0 (by omega) (by decide)
      simp only [Semiring.natCast_zero]
      grind

def readProject (beforeDepth : Nat) (row : Row) : Access :=
  if beforeDepth = 0 then ⟨false, false, 0, 0⟩ else
    ⟨true, false, row.functionIndex*bound+(beforeDepth-1),
      2*row.floor+row.unreachable.toNat⟩

def writeProject (beforeDepth beforeHeight : Nat) (row : Row) : Access :=
  match row.kind with
  | .controlPush => ⟨true, true, row.functionIndex*bound+beforeDepth, 2*beforeHeight⟩
  | .clear => ⟨true, true, row.functionIndex*bound+(beforeDepth-1), 2*row.floor+1⟩
  | _ => ⟨false, false, 0, 0⟩

structure AccessGates {F : Type} [Field F] (beforeDepth beforeHeight : Nat) (row : Row)
    (empty readActive readAddress readValue writeActive writeAddress writeValue : F) : Prop where
  readActiveEq : readActive = 1-empty
  readAddressEq : readAddress = readActive*((row.functionIndex : F)*(bound : F)+(beforeDepth : F)-1)
  readValueEq : readValue = readActive*(2*(row.floor : F)+flag row.unreachable)
  writeActiveEq : writeActive = selected row.kind .controlPush+selected row.kind .clear
  writeAddressEq : writeAddress = writeActive*((row.functionIndex : F)*(bound : F)+(beforeDepth : F)-
    selected row.kind .clear)
  writeValueEq : writeValue = 2*(selected row.kind .controlPush*(beforeHeight : F)+
    selected row.kind .clear*(row.floor : F))+selected row.kind .clear

theorem flag_nat {F : Type} [CommRing F] (bit : Bool) : flag (F := F) bit = (bit.toNat : F) := by
  cases bit <;> simp [flag, Bool.toNat, Semiring.natCast_zero, Semiring.natCast_one]

theorem projection_sound {F : Type} [Field F]
    (beforeDepth beforeHeight afterDepth : Nat) (row : Row)
    (empty readActive readAddress readValue writeActive writeAddress writeValue : F)
    (indicator : empty = if beforeDepth = 0 then 1 else 0)
    (step : Spec beforeDepth afterDepth row)
    (gates : AccessGates beforeDepth beforeHeight row empty readActive readAddress readValue
      writeActive writeAddress writeValue) :
    readActive = flag (readProject beforeDepth row).active ∧
      readAddress = ((readProject beforeDepth row).address : F) ∧
      readValue = ((readProject beforeDepth row).value : F) ∧
      writeActive = flag (writeProject beforeDepth beforeHeight row).active ∧
      writeAddress = ((writeProject beforeDepth beforeHeight row).address : F) ∧
      writeValue = ((writeProject beforeDepth beforeHeight row).value : F) := by
  have two : ((2 : Nat) : F) = (2 : F) := Semiring.natCast_eq_ofNat 2
  have readPart : readActive = flag (readProject beforeDepth row).active ∧
      readAddress = ((readProject beforeDepth row).address : F) ∧
      readValue = ((readProject beforeDepth row).value : F) := by
    by_cases zero : beforeDepth = 0
    · have inactive : empty = 1 := by simp [zero] at indicator; exact indicator
      simp [readProject, zero, flag, Semiring.natCast_zero]
      have a := gates.readActiveEq
      have b := gates.readAddressEq
      have v := gates.readValueEq
      grind
    · have nonempty : empty = 0 := by simp [zero] at indicator; exact indicator
      have pred := predecessor_field (F := F) beforeDepth (by omega)
      have bit := flag_nat (F := F) row.unreachable
      simp [readProject, zero, flag, Semiring.natCast_add, Semiring.natCast_mul]
      have a := gates.readActiveEq
      have b := gates.readAddressEq
      have v := gates.readValueEq
      rw [two]
      grind
  refine ⟨readPart.1, readPart.2.1, readPart.2.2, ?_⟩
  have a := gates.writeActiveEq
  have b := gates.writeAddressEq
  have v := gates.writeValueEq
  cases k : row.kind <;>
    simp [writeProject, selected, flag, k, Semiring.natCast_add, Semiring.natCast_mul,
      Semiring.natCast_zero, Semiring.natCast_one] at a b v ⊢
  case controlPush =>
    rw [two]
    grind
  case clear =>
    have positive := step.2.1 (by simp [needsTop, k])
    have pred := predecessor_field (F := F) beforeDepth positive
    rw [two]
    grind
  all_goals grind

#print axioms step_sound
#print axioms projection_sound

end ZkBuild.ControlEvents
