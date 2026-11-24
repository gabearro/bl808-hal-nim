import BranchListRead
import BranchTypeState
set_option autoImplicit false
namespace ZkBuild.BranchHeadOrigin
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def held (splits : Splits) (r : StructuredMatrix.Record) (i : Nat) :=
  f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 25
def address (splits : Splits) (r : StructuredMatrix.Record) (i : Nat) :=
  (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).size.address

/-- A nonzero held head comes from the most recent label in this instruction. -/
def Origin {F : Type} [Field F] (values : Nat → F) (splits : Splits)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) (i : Nat) : Prop :=
  E values (held splits r i)=0 ∨ ∃ j, j≤i ∧
    (rows.getD j default).kind=.labelCheck ∧ ops.getD j 0=14 ∧
    E values (held splits r i)=E values (address splits r j) ∧
    ∀ k, j<k → k≤i → BranchTypePending.reset (rows.getD k default).kind=false ∧
      BranchTypeState.mark (rows.getD k default).kind (ops.getD k 0)=false

theorem row_step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (kind : Kind) (code : Nat) (tags : BranchTypeCertificate.Tags values r kind code) :
    (BranchTypeState.mark kind code=true → E values (f r.after 25)=E values r.size.address) ∧
    (BranchTypeState.mark kind code=false → BranchTypePending.reset kind=true → E values (f r.after 25)=0) ∧
    (BranchTypeState.mark kind code=false → BranchTypePending.reset kind=false →
      E values (f r.after 25)=E values (f r.before 0)) := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have reset := facts.select (f r.flags 0++f r.flags 1) z (f r.before 0) 1 (by simp [BranchTypeRowCheck.selects])
  have update := facts.select (f r.flags 9) (f r.after 21) (f r.after 1) 25 (by simp [BranchTypeRowCheck.selects])
  have selected := facts.multiply (f r.flags 9) (f r.after 21) 22 (by simp [BranchTypeRowCheck.multiplies])
  have loc := (BranchTypeRowImages.interface matrix r checked values).sizeAddress
  have flag : E values (f r.flags 9)=OperandEvents.flag (BranchTypeState.mark kind code) := tags.label
  rw [flag] at update selected
  simp only [eval_append,tags.functionBegin,tags.instructionBegin,z,eval_constant values one,Ring.intCast_zero] at reset
  constructor
  · intro mark
    simp only [mark,OperandEvents.flag,ite_true] at update selected
    grind only
  constructor
  · intro mark active
    simp only [mark,OperandEvents.flag] at update
    cases kind <;> simp_all [BranchTypePending.reset,OperandEvents.flag] <;> grind only
  · intro mark inactive
    simp only [mark,OperandEvents.flag] at update
    cases kind <;> simp_all [BranchTypePending.reset,OperandEvents.flag] <;> grind only

theorem carry (splits : Splits) (r : StructuredMatrix.Record) (i : Nat) :
    f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) (i+1)).before 0=held splits r i := by
  simp [BranchTypeRowCheck.record,held,f,DeclarationMatrix.get]

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∀ i, i<rows.length → Origin values splits r rows ops i := by
  intro i
  induction i with
  | zero =>
    intro ib
    have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule 0 ib
    have step := row_step matrix _ row.1 values one satisfied _ _ row.2.1
    by_cases mark : BranchTypeState.mark (rows.getD 0 default).kind (ops.getD 0 0)=true
    · have selected := _root_.of_decide_eq_true mark
      exact Or.inr ⟨0,by omega,selected.1,selected.2,step.1 mark,by intro k h b; omega⟩
    have noMark : BranchTypeState.mark (rows.getD 0 default).kind (ops.getD 0 0)=false := by cases h : BranchTypeState.mark (rows.getD 0 default).kind (ops.getD 0 0) <;> simp_all
    by_cases reset : BranchTypePending.reset (rows.getD 0 default).kind=true
    · exact Or.inl (step.2.1 noMark reset)
    · have noReset : BranchTypePending.reset (rows.getD 0 default).kind=false := by cases h : BranchTypePending.reset (rows.getD 0 default).kind <;> simp_all
      have h := step.2.2 noMark noReset
      change E values (held splits r 0)=E values z at h
      exact Or.inl (by simpa only [z,eval_constant values one,Ring.intCast_zero] using h)
  | succ i ih =>
    intro ib
    have row := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule (i+1) ib
    have step := row_step matrix _ row.1 values one satisfied _ _ row.2.1
    by_cases mark : BranchTypeState.mark (rows.getD (i+1) default).kind (ops.getD (i+1) 0)=true
    · have selected := _root_.of_decide_eq_true mark
      exact Or.inr ⟨i+1,by omega,selected.1,selected.2,step.1 mark,by intro k h b; omega⟩
    have noMark : BranchTypeState.mark (rows.getD (i+1) default).kind (ops.getD (i+1) 0)=false := by cases h : BranchTypeState.mark (rows.getD (i+1) default).kind (ops.getD (i+1) 0) <;> simp_all
    by_cases reset : BranchTypePending.reset (rows.getD (i+1) default).kind=true
    · exact Or.inl (step.2.1 noMark reset)
    have noReset : BranchTypePending.reset (rows.getD (i+1) default).kind=false := by cases h : BranchTypePending.reset (rows.getD (i+1) default).kind <;> simp_all
    have carried := step.2.2 noMark noReset
    rw [carry] at carried
    change E values (held splits r (i+1))=E values (held splits r i) at carried
    rcases ih (by omega) with zero | ⟨j,ji,kind,code,value,between⟩
    · exact Or.inl (carried.trans zero)
    · refine Or.inr ⟨j,by omega,kind,code,carried.trans value,?_⟩
      intro k jk ki
      by_cases last : k=i+1
      · simpa only [last] using And.intro noReset noMark
      · exact between k jk (by omega)

#print axioms row_step
#print axioms trace
end ZkBuild.BranchHeadOrigin
