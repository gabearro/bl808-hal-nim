import ControlListArity
import FrameSelectors
set_option autoImplicit false
namespace ZkBuild.ControlSignatureSpan
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem heads {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (distance : Nat) (bound : first+distance≤last) :
    ControlHeadTrace.held values splits r (first+distance)=ControlHeadTrace.held values splits r first := by
  induction distance with
  | zero => rfl
  | succ distance ih =>
    let i := first+distance+1
    have ib : i<rows.length := by have := span.bounded; dsimp [i]; omega
    have kinds := InstructionSpanState.interior rows first last span i (by dsimp [i]; omega) (by dsimp [i]; omega)
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
    have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
    have reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=0 := by
      simpa only [ControlTypeMasks.reset,kinds.1,kinds.2.1,or_self,decide_false,flag,Bool.false_eq_true,ite_false] using masks.2.1.reset
    have same := ControlHeadTrace.unchanged values _ (ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied) reset
    have carry := ControlHeadTrace.carry values splits r (first+distance)
    change ControlHeadTrace.held values splits r i=_
    exact same.trans (carry.trans (ih (by omega)))

theorem frame_step {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (frame : FrameRowCheck.Record) (m : FrameRowSound.Meaning values frame)
    (kind : Kind) (tags : FrameSelectors.Tags values frame kind)
    (noFunction : kind≠.functionBegin) (noInstruction : kind≠.instructionBegin) (noLabel : kind≠.labelCheck) :
    E values (f frame.after 36)=E values (f frame.before 3) := by
  have held := m.select (FrameRowCheck.reset frame) (f frame.after 34) (f frame.before 3) 35 (by simp [FrameRowCheck.selects])
  have source := m.select (f frame.flags 9) frame.read.value (f frame.after 35) 36 (by simp [FrameRowCheck.selects])
  simp only [FrameRowCheck.reset,eval_append,tags.functionBegin,tags.instructionBegin,tags.label,
    noFunction,noInstruction,noLabel,decide_false,flag,Bool.false_eq_true,ite_false] at held source
  grind only

theorem frame_carry {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record) (i : Nat) :
    E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) (i+1)).before 3)=
      E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 36) := by
  simp [FrameRowCheck.record,f,DeclarationMatrix.get,List.getD,List.getElem?_map]

theorem frame {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true) (noTry : ops.getD first 0≠31)
    (distance : Nat) (bound : first+distance≤last) :
    E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) (first+distance)).after 36)=
      E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) first).after 36) := by
  induction distance with
  | zero => rfl
  | succ distance ih =>
    let i := first+distance+1
    have ib : i<rows.length := by have := span.bounded; dsimp [i]; omega
    have lo : first<i := by dsimp [i]; omega
    have hi : i≤last := by dsimp [i]; omega
    have kinds := InstructionSpanState.interior rows first last span i lo hi
    have noLabel : (rows.getD i default).kind≠.labelCheck := by
      intro label
      by_cases lastRow : i=last
      · rw [lastRow,span.endKind] at label; contradiction
      · have allowed := ControlActionGuards.alphabet values events rows ops schedule first last span active i lo (by omega)
        simp only [label,ControlActionGuards.Allowed,reduceCtorEq,false_or,true_and] at allowed
        exact noTry allowed
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
    have same := frame_step values _ (FrameRowSound.meaning matrix _ rc.2.2.1 values one satisfied)
      _ (FrameSelectors.tags values one _ _ _ rc.2.2.2) kinds.1 kinds.2.1 noLabel
    have carry := frame_carry values r (first+distance)
    change E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 36)=_
    exact same.trans (carry.trans (ih (by omega)))

theorem modes {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true)
    (i : Nat) (lo : first≤i) (hi : i≤last) (start current : Fin (2^36))
    (startImage : FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) first) start.val)
    (currentImage : FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) current.val) :
    ControlMemberSource.inputMode (ops.getD i 0) current.val=ControlMemberSource.inputMode (ops.getD first 0) start.val ∧
    ControlMemberSource.outputMode (ops.getD i 0) current.val=ControlMemberSource.outputMode (ops.getD first 0) start.val ∧
    ControlListArity.resultMode (ops.getD i 0) current.val=ControlListArity.resultMode (ops.getD first 0) start.val := by
  have code := InstructionSpanState.opcodes values events rows ops schedule first last span i lo hi
  rw [code]
  by_cases isTry : ops.getD first 0=31
  · rw [isTry]
    simp [ControlMemberSource.inputMode,ControlMemberSource.outputMode,ControlListArity.resultMode,
      ControlMemberRouting.inputParams,ControlMemberRouting.outputParams,FrameOpcodes.opens]
  · have field := frame matrix splits events r checked values one satisfied rows ops images schedule first last span active isTry (i-first) (by omega)
    rw [show first+(i-first)=i from by omega] at field
    have same := DeclarationLocations.natural_equal (F:=F) current.val start.val
      (by have := current.isLt; omega) (by have := start.isLt; omega)
      (currentImage.value.symm.trans (field.trans startImage.value))
    simp only [same,and_self]

#print axioms heads
#print axioms frame_step
#print axioms frame_carry
#print axioms frame
#print axioms modes
end ZkBuild.ControlSignatureSpan
