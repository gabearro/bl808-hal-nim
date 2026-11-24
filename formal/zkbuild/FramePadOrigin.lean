import FrameInstructionSource
set_option autoImplicit false
namespace ZkBuild.FramePadOrigin
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def held (r : StructuredMatrix.Record) (i : Nat) := f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).after 20

def Origin {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (i : Nat) : Prop :=
  E values (held r i)=0 ∨ ∃ j, j≤i ∧ (rows.getD j default).kind=.instructionBegin ∧
    E values (held r i)=E values (held r j) ∧
    ∀ k, j<k → k≤i → (rows.getD k default).kind≠.functionBegin ∧ (rows.getD k default).kind≠.instructionBegin

theorem row_step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : FrameRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : FrameSelectors.Tags values r kind) :
    (kind=.functionBegin → E values (f r.after 20)=0) ∧
    (kind≠.functionBegin → kind≠.instructionBegin → E values (f r.after 20)=E values (f r.before 2)) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have update := facts.select (FrameRowCheck.reset r) (f r.inputs 1) (f r.before 2) 20 (by simp [FrameRowCheck.selects])
  have zero := facts.guard (sub o (f r.flags 1)) (f r.inputs 1) (by simp [FrameRowCheck.guards])
  simp only [FrameRowCheck.reset,eval_append,tags.functionBegin,tags.instructionBegin] at update
  constructor
  · intro begin
    simp only [begin,flag,reduceCtorEq,decide_true,decide_false,ite_true,ite_false] at update
    simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,tags.instructionBegin,begin,flag,reduceCtorEq,decide_false,ite_false] at zero
    grind only
  · intro fn instruction
    simp only [fn,instruction,flag,decide_false,ite_false] at update
    grind only

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∀ i, i<rows.length → Origin values r rows i := by
  intro i
  induction i with
  | zero =>
    intro ib
    have row := FrameCertificate.row matrix events r checked values rows ops images schedule 0 ib
    have step := row_step matrix _ row.1 values one satisfied _ (FrameSelectors.tags values one _ _ _ row.2)
    by_cases fn : (rows.getD 0 default).kind=.functionBegin
    · exact Or.inl (step.1 fn)
    by_cases instruction : (rows.getD 0 default).kind=.instructionBegin
    · exact Or.inr ⟨0,by omega,instruction,rfl,by intro k h b; omega⟩
    · apply Or.inl
      have h := step.2 fn instruction
      change E values (held r 0)=E values z at h
      simpa only [z,eval_constant values one,Ring.intCast_zero] using h
  | succ i ih =>
    intro ib
    have row := FrameCertificate.row matrix events r checked values rows ops images schedule (i+1) ib
    have step := row_step matrix _ row.1 values one satisfied _ (FrameSelectors.tags values one _ _ _ row.2)
    by_cases fn : (rows.getD (i+1) default).kind=.functionBegin
    · exact Or.inl (step.1 fn)
    by_cases instruction : (rows.getD (i+1) default).kind=.instructionBegin
    · exact Or.inr ⟨i+1,by omega,instruction,rfl,by intro k h b; omega⟩
    have carried := step.2 fn instruction
    rw [FramePadTrace.carry] at carried
    change E values (held r (i+1))=E values (held r i) at carried
    rcases ih (by omega) with zero | ⟨j,ji,begin,value,between⟩
    · exact Or.inl (carried.trans zero)
    · refine Or.inr ⟨j,by omega,begin,carried.trans value,?_⟩
      intro k jk ki
      by_cases last : k=i+1
      · simpa only [last] using And.intro fn instruction
      · exact between k jk (by omega)

def Resolved {F : Type} [Field F] (values : Nat → F) (s : InstructionStreamMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) : Prop :=
  ∀ i, i<rows.length → E values (held r i)=0 ∨
    ∃ j, j≤i ∧ (rows.getD j default).kind=.instructionBegin ∧
      ∃ (d : InstructionEventSound.Data) (source : InstructionStreamMatrix.Row), source ∈ s.rows ∧
        InstructionInfoSound.Matches values source d ∧ FrameBlockEncoding.Valid d.pad.val ∧
        E values (held r i)=(d.pad.val:F) ∧
        ∀ k, j<k → k≤i → (rows.getD k default).kind≠.functionBegin ∧ (rows.getD k default).kind≠.instructionBegin

theorem resolved {F : Type} [Field F]
    (values : Nat → F) (s : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (origins : ∀ i, i<rows.length → Origin values r rows i)
    (source : FrameInstructionSource.Complete values s r rows ops) : Resolved values s r rows := by
  intro i ib
  rcases origins i ib with zero | ⟨j,ji,kind,same,between⟩
  · exact Or.inl zero
  · obtain ⟨d,row,member,_,_,matched,valid,image,_⟩ := source j (by omega) kind
    exact Or.inr ⟨j,ji,kind,d,row,member,matched,valid,same.trans image,between⟩

#print axioms row_step
#print axioms trace
#print axioms resolved
end ZkBuild.FramePadOrigin
