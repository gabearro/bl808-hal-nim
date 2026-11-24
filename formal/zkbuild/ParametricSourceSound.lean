import CallRuntimeSource
import ParametricInstructionBody
import ParametricBodySpec
set_option autoImplicit false
namespace ZkBuild.ParametricSourceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- Parametric instruction bodies on the same canonical trace and source-bound
    opcode/immediate wires as the preceding instruction and call certificates. -/
def Complete {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∃ primary : Nat → Fin (2^32),
    ParametricTraceSound.Facts values events rows ops primary ∧
    ParametricSemanticSound.Trace rows ops primary ∧
    ∀ first, first < rows.length → (rows.getD first default).kind = .instructionBegin →
      ParametricMode.active (ops.getD first 0) = true →
      ∃ last, InstructionSpans.Span rows first last ∧
        E values (f (rowAt events.rows first) 10) = ((primary first).val : F) ∧
        ParametricEvents.check (ops.getD first 0) (primary first).val
          ((InstructionSpanState.body rows first last).map ParametricBodyRun.action) = true ∧
        ParametricBodySpec.Typed (ops.getD first 0) (primary first).val
          ((InstructionSpanState.body rows first last).map ParametricBodyRun.action) ∧
        (InstructionSpanState.body rows first last).length = last-first-1

theorem complete {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (checked : ParametricCertificate.check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Complete values events rows ops := by
  obtain ⟨primary,facts,trace⟩ := ParametricSemanticSound.sound matrix statics events checked values one satisfied rows ops images schedule
  refine ⟨primary,facts,trace,?_⟩
  intro first fb beginKind active
  obtain ⟨last,span⟩ := InstructionSpans.exists_span values events rows ops schedule first fb beginKind
  have accepted := ParametricInstructionBody.body_sound values events rows ops schedule primary trace first last span active ((facts first fb).2.2.2.2 beginKind)
  exact ⟨last,span,(facts first fb).2.1,accepted,ParametricBodySpec.sound _ _ _ accepted,
    ParametricInstructionBody.body_length values events rows ops schedule primary trace first last span active⟩

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (imports : ImportMatrix.Record) (typing : DynamicTypingMatrix.Record) (structured : StructuredMatrix.Record) (runtime : RuntimeContextMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (importsChecked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (structuredChecked : StructuredCheck.check matrix splits tables events instructions signature indexed declaration structured = true)
    (runtimeChecked : RuntimeContextCheck.check matrix body tables context instructions events runtime = true)
    (semanticChecked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (parametricChecked : ParametricCertificate.check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row) (ops : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧
      InstructionSemanticSound.Schedule values events rows ops ∧ OperandStackCertificate.Trace rows ∧
      InstructionPartition.Partition rows ops ∧ CallBodySource.Complete values body splits tables declaration indexed signature typing rows ops ∧
      CallBodySource.SourceBodies values declaration message rows ops ∧
      CallRuntimeSource.Bodies values declaration imports splits tables context signature typing message rows ops ∧
      Complete values events rows ops := by
  obtain ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls⟩ :=
    CallRuntimeSource.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature space indexed declaration imports typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked
      importsChecked typingChecked structuredChecked runtimeChecked semanticChecked values one satisfied
  exact ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls,
    complete matrix statics events parametricChecked values one satisfied rows ops images schedule⟩

#print axioms complete
#print axioms source_bound
end ZkBuild.ParametricSourceSound
