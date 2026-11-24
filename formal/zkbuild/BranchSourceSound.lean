import BranchOrigins
import ParametricSourceSound
set_option autoImplicit false
namespace ZkBuild.BranchSourceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- Source-bound certificates share one canonical operand trace. The new result
    proves complete br_table target consumption, not yet branch operand typing. -/
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
    (branchChecked : BranchCertificate.check matrix splits tables statics events structured = true)
    (listsChecked : BranchListCheck.check matrix splits tables (StructuredMatrix.stage structured 2) = true)
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
      ParametricSourceSound.Complete values events rows ops ∧
      BranchOrigins.Origins values tables instructions structured ∧
      BranchComplete.Complete values splits tables (StructuredMatrix.stage structured 2) events rows ops := by
  obtain ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls,parametric⟩ :=
    ParametricSourceSound.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature space indexed declaration imports typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked
      importsChecked typingChecked structuredChecked runtimeChecked semanticChecked parametricChecked values one satisfied
  exact ⟨message,rows,ops,source,d0,d1,unique,decoded,stream,images,schedule,stackTrace,partition,calls,matched,runtimeCalls,parametric,
    BranchOrigins.sound matrix splits tables events instructions signature indexed declaration structured structuredChecked values one satisfied,
    BranchComplete.sound matrix splits tables statics events structured branchChecked listsChecked values one satisfied rows ops images schedule⟩

#print axioms source_bound
end ZkBuild.BranchSourceSound
