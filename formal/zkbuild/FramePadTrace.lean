import FrameBlockEncoding
set_option autoImplicit false
namespace ZkBuild.FramePadTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem carry (memory : MemoryEmbedded.Record) (s : DynamicTypingMatrix.Stage) (i : Nat) :
    f (record memory s (i+1)).before 2 = f (record memory s i).after 20 := by
  simp [record,f,DeclarationMatrix.get,List.getD,List.getElem?_map]

theorem step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (kind : Kind) (tags : FrameSelectors.Tags values r kind)
    (before : Fin (2^33)) (bi : E values (f r.before 2)=(before.val:F)) :
    ∃ pad : Fin (2^33), E values (f r.after 20)=(pad.val:F) := by
  obtain ⟨input,ib,ii⟩ := FrameRowImages.bounded matrix r checked values one satisfied 0 (by decide)
  change input<2^33 at ib
  change E values (f r.inputs 1)=(input:F) at ii
  have update := (FrameRowSound.meaning matrix r checked values one satisfied).select
    (reset r) (f r.inputs 1) (f r.before 2) 20 (by simp [selects])
  simp only [reset,eval_append,tags.functionBegin,tags.instructionBegin,bi,ii] at update
  by_cases starts : kind=.functionBegin ∨ kind=.instructionBegin
  · refine ⟨⟨input,ib⟩,?_⟩
    rcases starts with h | h <;> subst kind <;> simp only [flag,decide_true,decide_false,ite_true,ite_false] at update <;> grind only
  · refine ⟨before,?_⟩
    have a : kind≠.functionBegin := by intro h; exact starts (Or.inl h)
    have b : kind≠.instructionBegin := by intro h; exact starts (Or.inr h)
    simp only [flag,a,b,decide_false,ite_false] at update
    grind only

theorem held {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∀ i, i<rows.length → ∃ pad : Fin (2^33),
      E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 20)=(pad.val:F) := by
  intro i
  induction i with
  | zero =>
    intro ib
    have row := FrameCertificate.row matrix events r checked values rows ops images schedule 0 ib
    apply step matrix _ row.1 values one satisfied _ (FrameSelectors.tags values one _ _ _ row.2) 0
    change E values z = ((0:Nat):F)
    simp only [z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  | succ i ih =>
    intro ib
    obtain ⟨pad,pi⟩ := ih (by omega)
    have row := FrameCertificate.row matrix events r checked values rows ops images schedule (i+1) ib
    apply step matrix _ row.1 values one satisfied _ (FrameSelectors.tags values one _ _ _ row.2) pad
    rw [carry]
    exact pi

def Encoded {F : Type} [Field F] (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ∃ pad : Fin (2^33),
    E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 20)=(pad.val:F) ∧
    FrameBlockEncoding.Valid pad.val ∧
    FrameBlockEncoding.token (ops.getD i 0) pad.val < 2^36 ∧
    E values (f (record r.frames (StructuredMatrix.stage r 3) i).after 31)=
      (FrameBlockEncoding.token (ops.getD i 0) pad.val:F)

theorem encoded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Encoded values r rows ops := by
  intro i ib
  obtain ⟨pad,pi⟩ := held matrix events r checked values one satisfied rows ops images schedule i ib
  have row := FrameCertificate.row matrix events r checked values rows ops images schedule i ib
  have encoding := FrameBlockEncoding.scalar matrix _ row.1 values one satisfied pad pi _ (schedule.opcode i ib).1 row.2.opcode
  exact ⟨pad,pi,encoding.1,FrameBlockEncoding.bounded _ _ encoding.1,encoding.2⟩

#print axioms carry
#print axioms step
#print axioms held
#print axioms encoded
end ZkBuild.FramePadTrace
