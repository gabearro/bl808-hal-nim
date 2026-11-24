import InstructionSemanticSource
import OperandStackCertificate
import ControlTypeSemanticSound
set_option autoImplicit false
namespace ZkBuild.ControlTypeSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast
theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (structured : StructuredMatrix.Record) (runtime : RuntimeContextMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (structuredChecked : StructuredCheck.check matrix splits tables events instructions signature indexed declaration structured = true)
    (runtimeChecked : RuntimeContextCheck.check matrix body tables context instructions events runtime = true)
    (semanticChecked : InstructionSemanticSound.check matrix statics events = true)
    (controlChecked : ControlTypeCertificate.check matrix splits events structured = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat) (ops : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      (ValidationSourceSound.projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) ∧
      (∀ s ∈ events.stages, ValidationEventSound.StageFacts matrix statics admission values s) ∧
      (∀ s ∈ typing.stages, DynamicTypingSound.StageFacts matrix splits tables signature values s) ∧
      (∀ s ∈ structured.stages, StructuredSound.StageFacts matrix splits tables indexed structured values s) ∧
      (∀ s ∈ structured.stages, ∀ i ∈ s.banks, DynamicTypingSound.TableFacts values (tables.getD i default)) ∧
      ValidationEventSound.MemoryFacts values structured.frames ∧
      ValidationEventSound.MemoryFacts values structured.scratch ∧
      (∀ s ∈ runtime.stages, RuntimeContextSound.StageFacts matrix tables runtime values s) ∧
      (∀ s ∈ runtime.stages, ∀ i ∈ s.banks, DynamicTypingSound.TableFacts values (tables.getD i default)) ∧
      (∀ item ∈ runtime.catalog, LookupEmbedded.check matrix item.2 = true) ∧
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧
      EventSemanticLifo.Trace rows ds first ∧ InstructionSemanticSound.Schedule values events rows ops ∧
      OperandStackCertificate.Trace rows ∧ ControlTypeSemanticSound.Complete values splits structured rows ops := by
  obtain ⟨message,rows,ds,first,ops,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
      runtimes,runtimeBanks,runtimeCatalog,images,lifo,schedule,stackTrace⟩ :=
    InstructionSemanticSource.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature indexed declaration typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked typingChecked
      structuredChecked runtimeChecked semanticChecked values one satisfied
  exact ⟨message,rows,ds,first,ops,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
    runtimes,runtimeBanks,runtimeCatalog,images,lifo,schedule,stackTrace,
    ControlTypeSemanticSound.sound matrix splits events structured controlChecked values one satisfied rows ops images schedule⟩

#print axioms source_bound
end ZkBuild.ControlTypeSource
