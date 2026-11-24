import InstructionStreamCheck
import OpcodeCatalogSound
set_option autoImplicit false
namespace ZkBuild.InstructionSourceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def ProgramFacts {F : Type} [Field F] (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits)
    (values : Nat → F) (message : List Sha256.Byte) (state : SourceProgram.State) : Prop :=
  BodySourceCommitted.ProgramFacts matrix body splits values message state ∧
  (∀ c ∈ state.contracts, c.kind = 0 → c.first = 7 → ∀ mode position expected actual,
    c.inputs = [mode,position,expected] → actual < 7 → E values mode = ((actual+1 : Nat) : F) →
    ∃ start length, start < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity actual ∧ start+length ≤ message.length ∧
      E values position = (start : F) ∧ E values (body.tokens.getD c.block.index default).length = (length : F) ∧
      E values expected = (TokenInteger.decode actual length (fun i => (message.getD (start+i) 0).toNat) : F))

theorem meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits)
    (values : Nat → F) (message : List Sha256.Byte) (state : SourceProgram.State)
    (checked : SourceProgram.auditState matrix body.tokens splits state = true)
    (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (decoded : ∀ t ∈ body.tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ProgramFacts matrix body splits values message state := by
  have facts := SourceProgramSound.state matrix body.tokens splits state checked values oneValue satisfied
  refine ⟨BodySourceCommitted.meaning matrix body splits values message state facts oneValue satisfied decoded,?_⟩
  intro c member kind format mode position expected actual inputs small enabled
  exact SourceProgramSound.active_variant matrix body.tokens splits c kind format (facts.2 c member)
    mode position expected inputs actual small values oneValue satisfied enabled message decoded

theorem decoder {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits)
    (catalog : InstructionDecodeMatrix.Catalog) (r : InstructionDecodeMatrix.Record)
    (checked : InstructionDecodeMatrix.check matrix body.tokens splits catalog r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ body.tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ∃ output state, (InstructionDecodeMatrix.replay matrix body.tokens splits catalog r).run (SourceProgram.init r.program) = .ok (output,state) ∧
      SourceProgram.finished r.program state ∧ ModuleProgram.sameInputs output r.outputs ∧
      ProgramFacts matrix body splits values message state := by
  unfold InstructionDecodeMatrix.check at checked
  cases h : (InstructionDecodeMatrix.replay matrix body.tokens splits catalog r).run (SourceProgram.init r.program) with
  | error error => simp [h] at checked
  | ok pair =>
    rcases pair with ⟨output,state⟩
    have rest := (Bool.and_eq_true_iff.mp checked).2
    rw [h] at rest
    have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp rest).1
    exact ⟨output,state,rfl,shape.1,shape.2,meaning matrix body splits values message state (Bool.and_eq_true_iff.mp rest).2 oneValue satisfied decoded⟩

theorem verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) (r : InstructionStreamMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (checked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      InstructionDecodeMatrix.catalogCheck catalog = true ∧
      (∀ d ∈ decoders, ∃ output state, (InstructionDecodeMatrix.replay matrix body.tokens splits catalog d).run (SourceProgram.init d.program) = .ok (output,state) ∧
        SourceProgram.finished d.program state ∧ ModuleProgram.sameInputs output d.outputs ∧ ProgramFacts matrix body splits values message state) ∧
      ∃ result state, InstructionStreamCheck.run matrix body.tokens splits tables catalog decoders r = .ok (result,state) ∧
        SourceProgram.finished r.program state ∧ InstructionStreamCheck.outputLinks tables r result = true ∧
        InstructionStreamMatrix.frameCheck matrix r result = true ∧ ProgramFacts matrix body splits values message state := by
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sourceChecked).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  obtain ⟨message,source,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  unfold InstructionStreamCheck.check InstructionStreamCheck.checkPayload at checked
  have checks := Bool.and_eq_true_iff.mp checked
  have payload := Bool.and_eq_true_iff.mp checks.2
  have allDecoders := (Bool.and_eq_true_iff.mp payload.1).2
  refine ⟨message,source,d0,d1,unique,checks.1,?_,?_⟩
  · intro d member
    exact decoder matrix body splits catalog d (List.all_eq_true.mp allDecoders d member) values oneValue satisfied message decoded
  · cases h : InstructionStreamCheck.run matrix body.tokens splits tables catalog decoders r with
    | error error => simp [h] at payload
    | ok pair =>
      rcases pair with ⟨result,state⟩
      have rest := payload.2
      rw [h] at rest
      have facts := Bool.and_eq_true_iff.mp rest
      have prior := Bool.and_eq_true_iff.mp facts.1
      have first := Bool.and_eq_true_iff.mp prior.1
      exact ⟨result,state,rfl,(_root_.of_decide_eq_true first.1).1,first.2,prior.2,
        meaning matrix body splits values message state facts.2 oneValue satisfied decoded⟩
#print axioms meaning
#print axioms decoder
#print axioms verified
end ZkBuild.InstructionSourceSound
