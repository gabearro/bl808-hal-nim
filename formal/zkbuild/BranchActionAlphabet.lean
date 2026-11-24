import FrameWriteValue
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.BranchActionAlphabet
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Allowed (kind : Kind) : Prop := kind=.pop ∨ kind=.push ∨ kind=.labelCheck ∨ kind=.clear

theorem row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : FrameRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (event : Row) (image : FrameCertificate.Images values r event 14)
    (prior : E values (f r.before 1)=0) : event.kind≠.controlPush ∧ event.kind≠.controlPop := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have tags := FrameSelectors.tags values one r event 14 image
  have cats := FrameOpcodes.categories matrix r checked values one satisfied 14 (by decide) image.opcode
  have other := FrameOpcodes.selectors matrix r checked values one satisfied 14 (by decide) image.opcode 3 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ,flag,decide_false,ite_false] at other
  have root := facts.multiply (f r.before 1) (f r.flags 4) 11 (by simp [FrameRowCheck.multiplies])
  rw [prior] at root
  have push := facts.guard (sub (f r.flags 4) (f r.after 11))
    (sub (sub o (FrameRowCheck.opening r)) (f r.after 3)) (by simp [FrameRowCheck.guards])
  have pop := facts.guard (f r.flags 5) (sub o (FrameRowCheck.closing r)) (by simp [FrameRowCheck.guards])
  simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,cats.isOpening,cats.isClosing,other,root,tags.controlPush,tags.controlPop] at push pop
  simp only [FrameOpcodes.opens,FrameOpcodes.closes,flag,decide_false,ite_false] at push pop
  constructor
  · intro kind
    simp only [kind,decide_true,ite_true] at push
    exact False.elim (Field.zero_ne_one (α:=F) (by grind only))
  · intro kind
    simp only [kind,decide_true,ite_true] at pop
    exact False.elim (Field.zero_ne_one (α:=F) (by grind only))

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ops.getD first 0=14 →
    ∀ i, first<i → i<last → Allowed (rows.getD i default).kind

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete rows ops := by
  intro first last span active i lo hi
  have ib : i<rows.length := by have := span.bounded; omega
  have code := (InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)).trans active
  have rc := FrameCertificate.row matrix events r checked values rows ops images schedule i ib
  have prior := FrameWriteValue.prior matrix events r checked values one rows ops images schedule i ib
  have noRoot : (rows.getD (i-1) default).kind≠.functionBegin := by
    by_cases initial : i-1=first
    · rw [initial,span.beginKind]; decide
    · exact (span.middle (i-1) (by omega) (by omega)).1
  have root : E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).before 1)=0 := by
    simpa only [FrameWriteValue.rootAt,show i≠0 from by omega,ite_false,noRoot,decide_false,flag,Bool.false_eq_true] using prior
  have allowed := row matrix _ rc.1 values one satisfied _ (by simpa only [code] using rc.2) root
  have middle := span.middle i lo hi
  cases kind : (rows.getD i default).kind <;> simp_all [Allowed,InstructionSpans.Middle]

#print axioms row
#print axioms sound
end ZkBuild.BranchActionAlphabet
