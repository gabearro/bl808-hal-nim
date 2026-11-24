import InstructionSemanticSound
import OperandStackCertificate
set_option autoImplicit false
namespace ZkBuild.InstructionSemanticSource
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
      OperandStackCertificate.Trace rows := by
  obtain ⟨message,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch⟩ :=
    StructuredSource.source_bound matrix body splits tables context code locals catalog decoders instructions
      statics admission events signature indexed declaration typing structured sourceChecked instructionsChecked catalogsChecked
      eventsChecked typingChecked structuredChecked values one satisfied
  have facts := RuntimeContextSound.checked matrix body tables context instructions events runtime runtimeChecked values one satisfied
  obtain ⟨rows,ds,first,ops,images,lifo,schedule⟩ := InstructionSemanticSound.sound matrix statics admission instructions events
    catalogsChecked eventsChecked semanticChecked values one satisfied
  have cc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp
    (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp semanticChecked).1).1).1).1).1
  obtain ⟨stackRows,stackImages,stackTrace⟩ := OperandStackCertificate.sound matrix events cc values one satisfied
  have same := OperandRepresentationUnique.trace values _ stackRows rows stackImages images
  subst stackRows
  exact ⟨message,rows,ds,first,ops,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
    facts.1,facts.2.1,facts.2.2,images,lifo,schedule,stackTrace⟩
#print axioms source_bound
end ZkBuild.InstructionSemanticSource
