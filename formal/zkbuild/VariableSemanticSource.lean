import VariableSignatureTrace
import EnvironmentOriginSound
set_option autoImplicit false
namespace ZkBuild.VariableSemanticSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast
def Authenticated {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (rows : List OperandEvents.Row) (ops : List Nat) (tags : Nat → Fin 7) : Prop :=
  ∀ i, i < rows.length → (rows.getD i default).kind = .instructionBegin → ∃ mutable : Bool,
    EnvironmentAccessSound.Spec values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i)
      (ops.getD i 0) (tags i) mutable ∧
    EnvironmentOriginSound.Origins values locals.locals (ModuleContextMatrix.bank tables context 0).entries
      (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i) (ops.getD i 0) (tags i) mutable

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
    (semanticChecked : VariableSemanticCheck.check matrix tables statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat) (ops : List Nat) (tags : Nat → Fin 7),
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
      OperandStackCertificate.Trace rows ∧ VariableSemanticSound.Schedule values tables typing rows ops tags ∧
      Authenticated values tables context locals typing rows ops tags ∧
      VariableSignatureTrace.Complete rows ops tags := by
  have parts := semanticChecked
  simp only [VariableSemanticCheck.check,VariableCertificate.check,Bool.and_eq_true_iff] at parts
  have instructionCheck : InstructionSemanticSound.check matrix statics events = true := by grind only
  obtain ⟨message,rows,ds,first,ops,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
      runtimeFacts,runtimeBanks,runtimeCatalog,images,lifo,schedule,stackTrace⟩ :=
    InstructionSemanticSource.source_bound matrix body splits tables context code locals catalog decoders instructions statics admission events
      signature indexed declaration typing structured runtime sourceChecked instructionsChecked catalogsChecked eventsChecked typingChecked
      structuredChecked runtimeChecked instructionCheck values one satisfied
  obtain ⟨tags,variables⟩ := VariableSemanticSound.trace matrix tables statics events typing semanticChecked values one satisfied rows ops images schedule
  have envChecked : EnvironmentRowCheck.checkStage matrix tables (DynamicTypingCheck.stage typing 1) = true := by grind only
  have links : VariableSemanticCheck.linked tables events typing = true := by grind only
  simp only [VariableSemanticCheck.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have authenticated : Authenticated values tables context locals typing rows ops tags := by
    intro i ib kind
    obtain ⟨mutable,access,packed⟩ := variables.access i ib kind
    have eb : i < (DynamicTypingCheck.stage typing 1).rows.length := by have := schedule.length; omega
    exact ⟨mutable,access,EnvironmentOriginSound.row matrix splits tables signature context locals events typing typingChecked envChecked
      values one satisfied i eb _ _ mutable access packed⟩
  exact ⟨message,rows,ds,first,ops,tags,source,d0,d1,unique,decoded,stream,linked,stages,dynamic,controls,banks,frames,scratch,
    runtimeFacts,runtimeBanks,runtimeCatalog,images,lifo,schedule,stackTrace,variables,authenticated,VariableSignatureTrace.complete values tables events typing rows ops tags schedule variables⟩
#print axioms source_bound
end ZkBuild.VariableSemanticSource
