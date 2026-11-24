import BranchOperandSource
import FrameSelectors
set_option autoImplicit false
namespace ZkBuild.BranchLabelCarry
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def token (r : StructuredMatrix.Record) (i : Nat) :=
  f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 36

theorem row_step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : FrameRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : FrameSelectors.Tags values r kind)
    (reset : BranchTypePending.reset kind=false) (label : kind≠.labelCheck) :
    E values (f r.after 36)=E values (f r.before 3) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have carry := facts.select (FrameRowCheck.reset r) (f r.after 34) (f r.before 3) 35 (by simp [FrameRowCheck.selects])
  have select := facts.select (f r.flags 9) r.read.value (f r.after 35) 36 (by simp [FrameRowCheck.selects])
  simp only [FrameRowCheck.reset,eval_append,tags.functionBegin,tags.instructionBegin] at carry
  rw [tags.label] at select
  cases kind <;> simp_all [BranchTypePending.reset,flag] <;> grind only

theorem token_carry (r : StructuredMatrix.Record) (i : Nat) :
    f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) (i+1)).before 3=token r i := by
  simp [FrameRowCheck.record,token,f,DeclarationMatrix.get]

/-- No branch-label update and no reset also preserve the selected frame.
    The schedule excludes a label from another opcode in this interval. -/
theorem frame {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (j distance : Nat) (bound : j+distance<rows.length)
    (label : (rows.getD j default).kind=.labelCheck) (code : ops.getD j 0=14)
    (between : ∀ k, j<k → k≤j+distance → BranchTypePending.reset (rows.getD k default).kind=false ∧
      BranchTypeState.mark (rows.getD k default).kind (ops.getD k 0)=false) :
    E values (token r (j+distance))=E values (token r j) ∧
      (InstructionTraceSound.state rows ops (j+distance+1)).opcode=14 := by
  induction distance with
  | zero =>
    obtain ⟨_,_,_,binding⟩ := schedule.binding j (by omega)
    have opcode : (InstructionTraceSound.state rows ops j).opcode=14 := by
      symm
      simpa only [label,InstructionSchedule.chosenOpcode,reduceCtorEq,or_self,ite_false,code] using binding.2.1
    exact ⟨rfl,by simpa only [Nat.add_zero,InstructionTraceSound.state,InstructionSchedule.chosenOpcode,label,reduceCtorEq,or_self,ite_false] using opcode⟩
  | succ distance ih =>
    rw [show j+(distance+1)=j+distance+1 from by omega] at between ⊢
    have prior := ih (by omega) (by intro k lo hi; exact between k lo (by omega))
    have flags := between (j+distance+1) (by omega) (by omega)
    have noReset := flags.1
    have resetProp : ¬((rows.getD (j+distance+1) default).kind=.functionBegin ∨
        (rows.getD (j+distance+1) default).kind=.instructionBegin) := by
      simpa only [BranchTypePending.reset,decide_eq_false_iff_not] using noReset
    have noLabel : (rows.getD (j+distance+1) default).kind≠.labelCheck := by
      intro label
      obtain ⟨_,_,_,binding⟩ := schedule.binding (j+distance+1) (by omega)
      have code : ops.getD (j+distance+1) 0=14 := by
        simpa only [label,InstructionSchedule.chosenOpcode,reduceCtorEq,or_self,ite_false,prior.2] using binding.2.1
      have bad := flags.2
      simp only [BranchTypeState.mark,label,code,and_self,decide_true] at bad
      contradiction
    have row := FrameCertificate.row matrix events r checked values rows ops images schedule (j+distance+1) (by omega)
    have step := row_step matrix _ row.1 values one satisfied _ (FrameSelectors.tags values one _ _ _ row.2) noReset noLabel
    rw [token_carry] at step
    constructor
    · exact step.trans prior.1
    · change InstructionSchedule.chosenOpcode _ _ _=14
      simpa only [InstructionSchedule.chosenOpcode,resetProp,ite_false] using prior.2

/-- The selected length and start offset persist until the next label/reset. -/
theorem state (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data)
    (j distance : Nat) (label : BranchTypeState.mark (rows.getD j default).kind (ops.getD j 0)=true)
    (between : ∀ k, j<k → k≤j+distance → BranchTypePending.reset (rows.getD k default).kind=false ∧
      BranchTypeState.mark (rows.getD k default).kind (ops.getD k 0)=false) :
    (BranchTypeTrace.chosen rows ops data (j+distance)).length=(data j).size.val ∧
    (BranchTypeTrace.chosen rows ops data (j+distance)).start=j+1 := by
  induction distance with
  | zero => simp only [Nat.add_zero,BranchTypeTrace.chosen,BranchTypeState.select,label,ite_true,and_self]
  | succ distance ih =>
    rw [show j+(distance+1)=j+distance+1 from by omega] at between ⊢
    have prior := ih (by intro k lo hi; exact between k lo (by omega))
    have flags := between (j+distance+1) (by omega) (by omega)
    have unchanged : BranchTypeTrace.chosen rows ops data (j+distance+1)=BranchTypeTrace.state rows ops data (j+distance+1) := by
      simp only [BranchTypeTrace.chosen,BranchTypeState.select,flags.2,Bool.false_eq_true,ite_false,
        BranchTypeTrace.ready,BranchTypeState.prepare,flags.1]
    rw [unchanged]
    exact prior

#print axioms row_step
#print axioms frame
#print axioms state
end ZkBuild.BranchLabelCarry
