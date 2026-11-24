import BodySourceTheorems
set_option autoImplicit false
namespace ZkBuild.BodySourceCommitted
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def ProgramFacts {F : Type} [Field F] (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits)
    (values : Nat → F) (message : List Sha256.Byte) (state : SourceProgram.State) : Prop :=
  BodySourceTheorems.StateMeaning matrix body.tokens splits values state ∧
  (∀ c ∈ state.contracts, c.kind = 0 → c.first < 7 → ∀ active position expected,
    c.inputs = [active,position,expected] → E values active = 1 →
    ∃ start length, start < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity c.first ∧ start+length ≤ message.length ∧
      E values position = (start : F) ∧ E values (body.tokens.getD c.block.index default).length = (length : F) ∧
      E values expected = (TokenInteger.decode c.first length (fun i => (message.getD (start+i) 0).toNat) : F)) ∧
  (∀ c ∈ state.contracts, c.kind = 0 → c.first = 0 → ∀ (active position value : Linear) (expected : Nat),
    c.inputs = [active,position,value] → expected < 256 → E values active = 1 → E values value = (expected : F) →
    ∃ start, start < 2^32 ∧ start < message.length ∧ (message.getD start 0).toNat = expected ∧
      E values position = (start : F) ∧ E values (body.tokens.getD c.block.index default).length = 1) ∧
  (∀ c ∈ state.contracts, c.kind = 1 → ∀ value, c.inputs = [value] →
    ∃ whole low high : Nat, whole < 2^(c.first+c.second) ∧ low < 2^c.first ∧ high < 2^c.second ∧
      E values value = (whole : F) ∧ E values (splits.getD c.block.index default).low = (low : F) ∧
      E values (splits.getD c.block.index default).high = (high : F) ∧ whole = low+2^c.first*high)

theorem meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits)
    (values : Nat → F) (message : List Sha256.Byte) (state : SourceProgram.State)
    (facts : BodySourceTheorems.StateMeaning matrix body.tokens splits values state)
    (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (decoded : ∀ t ∈ body.tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ProgramFacts matrix body splits values message state := by
  refine ⟨facts,?_,?_,?_⟩
  · intro c member kind small active position expected inputs enabled
    exact SourceProgramSound.active_read matrix body.tokens splits c kind small (facts.2 c member)
      active position expected inputs values oneValue satisfied enabled message decoded
  · intro c member kind format active position value expected inputs bounded enabled image
    exact SourceProgramSound.active_byte matrix body.tokens splits c kind format (facts.2 c member)
      active position value inputs expected bounded values oneValue satisfied enabled image message decoded
  · intro c member kind value inputs
    exact SourceProgramSound.packed_split matrix body.tokens splits c kind (facts.2 c member)
      value inputs values oneValue satisfied

theorem verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (context : ModuleContextMatrix.Record)
    (locals : LocalDeclarationMatrix.Record) (ranges : LocalRangeMatrix.Record) (code : BodySourceMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (checked : BodySourceSound.check matrix body splits tables space indexed context locals ranges code = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      (∀ t ∈ body.tokens, t.kind = 1 → E values t.activeMode = 1 →
        ∃ start length, start < 2^32 ∧ start+length ≤ message.length ∧ E values t.position = (start : F) ∧ E values t.length = (length : F) ∧
          BinaryTokenSyntax.U32 length (fun i => (message.getD (start+i) 0).toNat)) ∧
      ∃ codeResult codeState localResult localState rangeResult rangeState,
        BodySourceMatrix.replay matrix body.tokens splits tables body code = .ok (codeResult,codeState) ∧
        (LocalDeclarationMatrix.replayProgram matrix body.tokens splits tables locals).run (SourceProgram.init locals.program) = .ok (localResult,localState) ∧
        (LocalRangeMatrix.replayProgram matrix body.tokens splits tables ranges).run (SourceProgram.init ranges.program) = .ok (rangeResult,rangeState) ∧
        SourceProgram.finished code.program codeState ∧ SourceProgram.finished locals.program localState ∧ SourceProgram.finished ranges.program rangeState ∧
        BodySourceSound.outputLinks tables code codeResult = true ∧
        ProgramFacts matrix body splits values message codeState ∧ ProgramFacts matrix body splits values message localState ∧ ProgramFacts matrix body splits values message rangeState := by
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sourceChecked).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  obtain ⟨message,source,d0,d1,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  obtain ⟨other,otherSource,_,_,grammar⟩ := BinaryTokenSyntax.checked_u32 matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique other otherSource
  subst other
  have checks := Bool.and_eq_true_iff.mp checked
  have earlier := Bool.and_eq_true_iff.mp checks.1
  obtain ⟨codeResult,codeState,codeRun,codeDone,outputs,codeFacts⟩ := BodySourceTheorems.code matrix body splits tables space indexed locals code checks.2 values oneValue satisfied
  obtain ⟨localResult,localState,localRun,localDone,localFacts⟩ := BodySourceTheorems.declarations matrix body splits tables space indexed context locals earlier.2 values oneValue satisfied
  obtain ⟨rangeResult,rangeState,rangeRun,rangeDone,rangeFacts⟩ := BodySourceTheorems.ranges matrix body splits tables locals ranges earlier.1 values oneValue satisfied
  exact ⟨message,source,d0,d1,unique,grammar,codeResult,codeState,localResult,localState,rangeResult,rangeState,
    codeRun,localRun,rangeRun,codeDone,localDone,rangeDone,outputs,
    meaning matrix body splits values message codeState codeFacts oneValue satisfied decoded,
    meaning matrix body splits values message localState localFacts oneValue satisfied decoded,
    meaning matrix body splits values message rangeState rangeFacts oneValue satisfied decoded⟩

#print axioms meaning
#print axioms verified
end ZkBuild.BodySourceCommitted
