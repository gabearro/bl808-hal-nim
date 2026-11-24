import StructuredSound
set_option autoImplicit false
namespace ZkBuild.StructuredSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast
theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (structured : StructuredMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (structuredChecked : StructuredCheck.check matrix splits tables events instructions signature indexed declaration structured = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
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
      ValidationEventSound.MemoryFacts values structured.scratch := by
  obtain ⟨message,source,d0,d1,unique,decoders,stream,linked,stages,dynamic,_⟩ :=
    DynamicTypingSource.source_bound matrix body splits tables context code locals catalog decoders instructions
      statics admission events signature typing sourceChecked instructionsChecked catalogsChecked eventsChecked typingChecked values one satisfied
  have facts := StructuredSound.checked matrix splits tables events instructions signature indexed declaration structured structuredChecked values one satisfied
  exact ⟨message,source,d0,d1,unique,decoders,stream,linked,stages,dynamic,facts⟩
#print axioms source_bound
end ZkBuild.StructuredSource
